import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

// MARK: - Transcript Collector

private actor TranscriptCollector {
    private var finals: [String] = []
    private var interim: String = ""

    func addFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            finals.append(trimmed)
        }
        interim = ""
    }

    func setInterim(_ text: String) {
        interim = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func currentText() -> String {
        var parts = finals
        if !interim.isEmpty {
            parts.append(interim)
        }
        return parts.joined(separator: " ")
    }

    func finalResult() -> String {
        finals.joined(separator: " ")
    }
}

// MARK: - Plugin Entry Point

@objc(SpeechmaticsPlugin)
final class SpeechmaticsPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.speechmatics"
    static let pluginName = "Speechmatics"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _selectedRegion: String?

    private let logger = Logger(subsystem: "com.typewhisper.speechmatics", category: "Plugin")

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? transcriptionModels.first?.id
        _selectedRegion = host.userDefault(forKey: "selectedRegion") as? String ?? "eu"
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "speechmatics" }
    var providerDisplayName: String { "Speechmatics" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "enhanced", displayName: "Enhanced"),
            PluginModelInfo(id: "standard", displayName: "Standard"),
        ]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }

    var supportedLanguages: [String] {
        [
            "ar", "bg", "ca", "cmn", "cs", "cy", "da", "de", "el", "en",
            "es", "et", "eu", "fa", "fi", "fr", "ga", "gl", "gu", "he",
            "hi", "hr", "hu", "id", "is", "it", "ja", "ka", "kk", "ko",
            "lt", "lv", "mk", "ml", "ms", "mt", "nl", "no", "pa", "pl",
            "pt", "ro", "ru", "sk", "sl", "sq", "sr", "sv", "sw", "ta",
            "te", "th", "tr", "uk", "ur", "vi", "yue", "zh",
        ]
    }

    // MARK: - Region Helpers

    fileprivate var wsHost: String {
        switch _selectedRegion {
        case "us": return "usa.rt.speechmatics.com"
        default: return "eu2.rt.speechmatics.com"
        }
    }

    // MARK: - Transcription (REST Fallback)

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        return try await transcribeREST(audio: audio, language: language, modelId: modelId, apiKey: apiKey)
    }

    // MARK: - Transcription (WebSocket Streaming)

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        do {
            return try await transcribeWebSocket(
                audio: audio, language: language, modelId: modelId,
                apiKey: apiKey, onProgress: onProgress
            )
        } catch {
            logger.warning("WebSocket streaming failed, falling back to REST: \(error.localizedDescription)")
            return try await transcribeREST(audio: audio, language: language, modelId: modelId, apiKey: apiKey)
        }
    }

    // MARK: - REST Implementation (Batch API)

    private func transcribeREST(audio: AudioData, language: String?, modelId: String, apiKey: String) async throws -> PluginTranscriptionResult {
        let jobId = try await submitJob(wavData: audio.wavData, language: language, modelId: modelId, apiKey: apiKey)
        return try await pollJob(jobId: jobId, apiKey: apiKey)
    }

    private func submitJob(wavData: Data, language: String?, modelId: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://asr.api.speechmatics.com/v2/jobs") else {
            throw PluginTranscriptionError.apiError("Invalid jobs URL")
        }

        let boundary = UUID().uuidString

        let lang = (language?.isEmpty == false) ? language! : "auto"
        let config: [String: Any] = [
            "type": "transcription",
            "transcription_config": [
                "language": lang,
                "operating_point": modelId,
            ] as [String: Any],
        ]

        let configData = try JSONSerialization.data(withJSONObject: config)

        var body = Data()
        // Config part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"config\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(configData)
        body.append("\r\n".data(using: .utf8)!)
        // Audio part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"data_file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 201: break
        case 401: throw PluginTranscriptionError.invalidApiKey
        case 429: throw PluginTranscriptionError.rateLimited
        default:
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Submit failed HTTP \(httpResponse.statusCode): \(responseBody)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobId = json["id"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid submit response")
        }

        return jobId
    }

    private func pollJob(jobId: String, apiKey: String) async throws -> PluginTranscriptionResult {
        guard let statusURL = URL(string: "https://asr.api.speechmatics.com/v2/jobs/\(jobId)") else {
            throw PluginTranscriptionError.apiError("Invalid job URL")
        }

        var statusRequest = URLRequest(url: statusURL)
        statusRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        statusRequest.timeoutInterval = 15

        for _ in 0..<300 {
            try await Task.sleep(for: .seconds(1))

            let (data, response) = try await PluginHTTPClient.data(for: statusRequest)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                continue
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let job = json["job"] as? [String: Any],
                  let status = job["status"] as? String else {
                continue
            }

            switch status {
            case "done":
                return try await fetchTranscript(jobId: jobId, apiKey: apiKey)
            case "rejected":
                let errors = job["errors"] as? [[String: Any]]
                let errorMsg = errors?.first?["message"] as? String ?? "Job rejected"
                throw PluginTranscriptionError.apiError(errorMsg)
            default:
                // running, waiting - keep polling
                continue
            }
        }

        throw PluginTranscriptionError.apiError("Transcription timed out after 5 minutes")
    }

    private func fetchTranscript(jobId: String, apiKey: String) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: "https://asr.api.speechmatics.com/v2/jobs/\(jobId)/transcript?format=json-v2") else {
            throw PluginTranscriptionError.apiError("Invalid transcript URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw PluginTranscriptionError.apiError("Failed to fetch transcript")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw PluginTranscriptionError.apiError("Invalid transcript response")
        }

        let text = results.compactMap { result -> String? in
            guard let alternatives = result["alternatives"] as? [[String: Any]],
                  let first = alternatives.first,
                  let content = first["content"] as? String else {
                return nil
            }
            return content
        }.joined(separator: " ")

        let detectedLanguage = (json["metadata"] as? [String: Any])?["language"] as? String
        return PluginTranscriptionResult(text: text, detectedLanguage: detectedLanguage)
    }

    // MARK: - WebSocket Implementation (Real-Time v2)

    private func transcribeWebSocket(
        audio: AudioData,
        language: String?,
        modelId: String,
        apiKey: String,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        let urlString = "wss://\(wsHost)/v2"

        guard let url = URL(string: urlString) else {
            throw PluginTranscriptionError.apiError("Invalid streaming URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let wsTask = URLSession.shared.webSocketTask(with: request)
        wsTask.resume()

        // Send StartRecognition message
        let lang = (language?.isEmpty == false) ? language! : "en"
        let startMessage: [String: Any] = [
            "message": "StartRecognition",
            "audio_format": [
                "type": "raw",
                "encoding": "pcm_s16le",
                "sample_rate": 16000,
            ] as [String: Any],
            "transcription_config": [
                "language": lang,
                "operating_point": modelId,
                "enable_partials": true,
                "max_delay": 2.0,
            ] as [String: Any],
        ]

        let startData = try JSONSerialization.data(withJSONObject: startMessage)
        let startString = String(data: startData, encoding: .utf8)!
        try await wsTask.send(.string(startString))

        // Wait for RecognitionStarted
        let ackMessage = try await wsTask.receive()
        if case .string(let text) = ackMessage,
           let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messageType = json["message"] as? String {
            if messageType == "Error" {
                let reason = json["reason"] as? String ?? "Unknown error"
                wsTask.cancel(with: .normalClosure, reason: nil)
                throw PluginTranscriptionError.apiError("Speechmatics error: \(reason)")
            }
            if messageType != "RecognitionStarted" {
                wsTask.cancel(with: .normalClosure, reason: nil)
                throw PluginTranscriptionError.apiError("Unexpected response: \(messageType)")
            }
        }

        let collector = TranscriptCollector()
        let chunkSize = 8192
        let pcmData = Self.floatToPCM16(audio.samples)

        // Receive loop in background
        let loggerRef = self.logger
        let receiveTask = Task {
            do {
                while !Task.isCancelled {
                    let message = try await wsTask.receive()

                    guard case .string(let text) = message else { continue }

                    guard let data = text.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let messageType = json["message"] as? String else {
                        continue
                    }

                    if messageType == "EndOfTranscript" { break }

                    if messageType == "Error" {
                        let reason = json["reason"] as? String ?? "Unknown error"
                        loggerRef.error("Speechmatics server error: \(reason)")
                        break
                    }

                    if messageType == "AddTranscript" {
                        let transcript = json["transcript"] as? String ?? ""
                        await collector.addFinal(transcript)
                    } else if messageType == "AddPartialTranscript" {
                        let transcript = json["transcript"] as? String ?? ""
                        await collector.setInterim(transcript)
                    } else {
                        continue
                    }

                    let currentText = await collector.currentText()
                    if !currentText.isEmpty {
                        _ = onProgress(currentText)
                    }
                }
            } catch {
                loggerRef.error("WebSocket receive error: \(error.localizedDescription)")
            }
        }

        // Send audio as binary frames
        var offset = 0
        var seqNo = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            if chunk.count >= 1600 || end == pcmData.count {
                try await wsTask.send(.data(chunk))
                seqNo += 1
            }
            offset = end
        }

        // Signal end of audio
        let endMessage: [String: Any] = [
            "message": "EndOfStream",
            "last_seq_no": seqNo,
        ]
        let endData = try JSONSerialization.data(withJSONObject: endMessage)
        let endString = String(data: endData, encoding: .utf8)!
        try await wsTask.send(.string(endString))

        // Wait for server to finish sending results
        _ = await receiveTask.result

        wsTask.cancel(with: .normalClosure, reason: nil)

        let finalText = await collector.finalResult()
        return PluginTranscriptionResult(text: finalText, detectedLanguage: language)
    }

    // MARK: - Audio Conversion

    private static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - API Key Validation

    fileprivate func validateApiKey(_ key: String) async -> Bool {
        guard let url = URL(string: "https://asr.api.speechmatics.com/v2/jobs?limit=1") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(SpeechmaticsSettingsView(plugin: self))
    }

    // MARK: - Internal Methods for Settings

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[SpeechmaticsPlugin] Failed to store API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func removeApiKey() {
        _apiKey = nil
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: "")
            } catch {
                print("[SpeechmaticsPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func setRegion(_ region: String) {
        _selectedRegion = region
        host?.setUserDefault(region, forKey: "selectedRegion")
    }
}

// MARK: - Settings View

private struct SpeechmaticsSettingsView: View {
    let plugin: SpeechmaticsPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var selectedRegion: String = "eu"
    private let bundle = Bundle(for: SpeechmaticsPlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // API Key Section
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 8) {
                    if showApiKey {
                        TextField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    if plugin.isConfigured {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            validationResult = nil
                            plugin.removeApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    } else {
                        Button(String(localized: "Save", bundle: bundle)) {
                            saveApiKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating...", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let result = validationResult {
                    HStack(spacing: 4) {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result ? .green : .red)
                        Text(result ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle))
                            .font(.caption)
                            .foregroundStyle(result ? .green : .red)
                    }
                }
            }

            if plugin.isConfigured {
                Divider()

                // Model Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model", bundle: bundle)
                        .font(.headline)

                    Picker("Model", selection: $selectedModel) {
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectModel(selectedModel)
                    }

                    Text("Enhanced provides the best accuracy. Standard is faster and more cost-effective.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Region Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Region", bundle: bundle)
                        .font(.headline)

                    Picker("Region", selection: $selectedRegion) {
                        Text("EU", bundle: bundle).tag("eu")
                        Text("US", bundle: bundle).tag("us")
                    }
                    .labelsHidden()
                    .onChange(of: selectedRegion) {
                        plugin.setRegion(selectedRegion)
                    }

                    Text("Select the server region closest to you for lower latency.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("API keys are stored securely in the Keychain", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            if let key = plugin._apiKey, !key.isEmpty {
                apiKeyInput = key
            }
            selectedModel = plugin.selectedModelId ?? plugin.transcriptionModels.first?.id ?? ""
            selectedRegion = plugin._selectedRegion ?? "eu"
        }
    }

    private func saveApiKey() {
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        plugin.setApiKey(trimmedKey)

        isValidating = true
        validationResult = nil
        Task {
            let isValid = await plugin.validateApiKey(trimmedKey)
            await MainActor.run {
                isValidating = false
                validationResult = isValid
            }
        }
    }
}
