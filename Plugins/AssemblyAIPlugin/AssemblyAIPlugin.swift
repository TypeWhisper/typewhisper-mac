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

@objc(AssemblyAIPlugin)
final class AssemblyAIPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, DictionaryTermsBudgetProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.assemblyai"
    static let pluginName = "AssemblyAI"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?

    private let logger = Logger(subsystem: "com.typewhisper.assemblyai", category: "Plugin")

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? transcriptionModels.first?.id
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "assemblyai" }
    var providerDisplayName: String { "AssemblyAI" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "universal-3-pro", displayName: "Universal-3 Pro"),
            PluginModelInfo(id: "universal-2", displayName: "Universal-2"),
        ]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }
    var dictionaryTermsBudget: DictionaryTermsBudget { Self.dictionaryTermsBudget(for: _selectedModelId) }

    var supportedLanguages: [String] {
        if _selectedModelId == "universal-2" {
            return [
                "bg", "ca", "cs", "da", "de", "el", "en", "es", "et", "fi",
                "fr", "hi", "hr", "hu", "id", "it", "ja", "ko", "lt", "lv",
                "ms", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sl", "sq",
                "sr", "sv", "th", "tr", "uk", "vi", "zh",
            ]
        }
        // Universal-3 Pro: 6 languages
        return ["de", "en", "es", "fr", "it", "pt"]
    }

    // MARK: - Transcription (REST Fallback)

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        return try await transcribeREST(
            audio: audio,
            language: language,
            modelId: modelId,
            apiKey: apiKey,
            prompt: prompt
        )
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
                prompt: prompt,
                apiKey: apiKey, onProgress: onProgress
            )
        } catch {
            logger.warning("WebSocket streaming failed, falling back to REST: \(error.localizedDescription)")
            return try await transcribeREST(
                audio: audio,
                language: language,
                modelId: modelId,
                apiKey: apiKey,
                prompt: prompt
            )
        }
    }

    // MARK: - REST Implementation (3-Step Async)

    private func transcribeREST(
        audio: AudioData,
        language: String?,
        modelId: String,
        apiKey: String,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        let uploadURL = try await uploadAudio(wavData: audio.wavData, apiKey: apiKey)
        let transcriptId = try await submitTranscription(
            audioURL: uploadURL,
            modelId: modelId,
            language: language,
            apiKey: apiKey,
            prompt: prompt
        )
        return try await pollTranscription(transcriptId: transcriptId, apiKey: apiKey)
    }

    private func uploadAudio(wavData: Data, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.assemblyai.com/v2/upload") else {
            throw PluginTranscriptionError.apiError("Invalid upload URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = wavData
        request.timeoutInterval = 120

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw PluginTranscriptionError.invalidApiKey
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Upload failed HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uploadUrl = json["upload_url"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid upload response")
        }

        return uploadUrl
    }

    private func submitTranscription(
        audioURL: String,
        modelId: String,
        language: String?,
        apiKey: String,
        prompt: String?
    ) async throws -> String {
        guard let url = URL(string: "https://api.assemblyai.com/v2/transcript") else {
            throw PluginTranscriptionError.apiError("Invalid transcript URL")
        }

        var body: [String: Any] = [
            "audio_url": audioURL,
            "speech_models": [modelId],
        ]

        if let lang = language, !lang.isEmpty {
            body["language_code"] = lang
        } else {
            body["language_detection"] = true
        }
        Self.applyDictionaryTerms(prompt: prompt, modelId: modelId, to: &body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw PluginTranscriptionError.invalidApiKey
        case 429: throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Submit failed HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcriptId = json["id"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid submit response")
        }

        return transcriptId
    }

    private static func dictionaryTermsBudget(for modelId: String?) -> DictionaryTermsBudget {
        if modelId == "universal-3-pro" {
            return DictionaryTermsBudget(maxTerms: 1_000, maxWordsPerTerm: 6)
        }
        return DictionaryTermsBudget(maxTerms: 100, maxCharsPerTerm: 50)
    }

    private static func applyDictionaryTerms(prompt: String?, modelId: String, to body: inout [String: Any]) {
        let terms = PluginDictionaryTerms.clippedTerms(
            from: PluginDictionaryTerms.terms(fromPrompt: prompt),
            budget: dictionaryTermsBudget(for: modelId)
        )
        guard !terms.isEmpty else { return }

        if modelId == "universal-3-pro" {
            body["keyterms_prompt"] = terms
        } else {
            body["word_boost"] = terms
            body["boost_param"] = "high"
        }
    }

    private func pollTranscription(transcriptId: String, apiKey: String) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: "https://api.assemblyai.com/v2/transcript/\(transcriptId)") else {
            throw PluginTranscriptionError.apiError("Invalid poll URL")
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        for _ in 0..<300 {
            try await Task.sleep(for: .seconds(1))

            let (data, response) = try await PluginHTTPClient.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                continue
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else {
                continue
            }

            switch status {
            case "completed":
                let text = json["text"] as? String ?? ""
                let detectedLanguage = json["language_code"] as? String
                return PluginTranscriptionResult(text: text, detectedLanguage: detectedLanguage)
            case "error":
                let errorMsg = json["error"] as? String ?? "Unknown transcription error"
                throw PluginTranscriptionError.apiError(errorMsg)
            default:
                continue
            }
        }

        throw PluginTranscriptionError.apiError("Transcription timed out after 5 minutes")
    }

    // MARK: - WebSocket Implementation (v3 Streaming)
    // Uses URLSessionWebSocketTask (AssemblyAI's server doesn't have Deepgram's ALPN/h2 issue)

    private func transcribeWebSocket(
        audio: AudioData,
        language: String?,
        modelId: String,
        prompt: String?,
        apiKey: String,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        var queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "format_turns", value: "true"),
        ]

        if let lang = language, !lang.isEmpty, lang != "en" {
            queryItems.append(URLQueryItem(name: "speech_model", value: "universal-streaming-multilingual"))
        }

        if let keytermsPrompt = streamingKeytermsPromptJSON(from: prompt, modelId: modelId) {
            queryItems.append(URLQueryItem(name: "keyterms_prompt", value: keytermsPrompt))
        }

        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw PluginTranscriptionError.apiError("Invalid streaming URL")
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let wsTask = URLSession.shared.webSocketTask(with: request)
        wsTask.resume()

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
                          let type = json["type"] as? String else {
                        continue
                    }

                    if type == "Termination" { break }
                    guard type == "Turn" else { continue }

                    let transcript = json["transcript"] as? String ?? ""
                    let endOfTurn = json["end_of_turn"] as? Bool ?? false

                    if endOfTurn {
                        await collector.addFinal(transcript)
                    } else {
                        await collector.setInterim(transcript)
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
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            if chunk.count >= 1600 || end == pcmData.count {
                try await wsTask.send(.data(chunk))
            }
            offset = end
        }

        // Signal end of audio (v3 protocol)
        try await wsTask.send(.string("{\"type\":\"Terminate\"}"))

        // Wait for server to finish sending results
        _ = await receiveTask.result

        wsTask.cancel(with: .normalClosure, reason: nil)

        let finalText = await collector.finalResult()
        return PluginTranscriptionResult(text: finalText, detectedLanguage: language)
    }

    private func streamingKeytermsPromptJSON(from prompt: String?, modelId: String) -> String? {
        let rawTerms = PluginDictionaryTerms.clippedTerms(
            from: PluginDictionaryTerms.terms(fromPrompt: prompt),
            budget: Self.dictionaryTermsBudget(for: modelId)
        )
        guard !rawTerms.isEmpty else { return nil }

        let maxTerms = 100
        let maxCharactersPerTerm = 50
        let filteredTerms = rawTerms.filter { $0.count <= maxCharactersPerTerm }
        let limitedTerms = Array(filteredTerms.prefix(maxTerms))

        if filteredTerms.count < rawTerms.count {
            logger.warning(
                "AssemblyAI streaming dropped \(rawTerms.count - filteredTerms.count) dictionary term(s) longer than \(maxCharactersPerTerm) characters"
            )
        }

        if limitedTerms.count < filteredTerms.count {
            logger.warning(
                "AssemblyAI streaming limited dictionary terms to \(maxTerms) entries for model \(modelId, privacy: .public)"
            )
        }

        guard !limitedTerms.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: limitedTerms),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }

        return json
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
        guard let url = URL(string: "https://api.assemblyai.com/v2/transcript?limit=1") else { return false }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "Authorization")
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
        AnyView(AssemblyAISettingsView(plugin: self))
    }

    // MARK: - Internal Methods for Settings

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[AssemblyAIPlugin] Failed to store API key: \(error)")
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
                print("[AssemblyAIPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }
}

// MARK: - Settings View

private struct AssemblyAISettingsView: View {
    let plugin: AssemblyAIPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    private let bundle = Bundle(for: AssemblyAIPlugin.self)

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
