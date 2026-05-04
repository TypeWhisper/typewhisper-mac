import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

private let elevenLabsSupportedLanguages = [
    "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
    "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
    "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
    "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
    "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
    "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
    "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
    "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
    "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
    "tr", "tt", "uk", "ur", "uz", "vi", "vo", "yi", "yo", "yue",
    "zh",
]

private actor ElevenLabsTranscriptCollector {
    private var finals: [String] = []
    private var interim = ""
    private var detectedLanguage: String?

    func addFinal(_ text: String, language: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, finals.last != trimmed {
            finals.append(trimmed)
        }
        if let language, !language.isEmpty {
            detectedLanguage = language
        }
        interim = ""
    }

    func setInterim(_ text: String, language: String? = nil) {
        interim = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let language, !language.isEmpty {
            detectedLanguage = language
        }
    }

    func currentText() -> String {
        var parts = finals
        if !interim.isEmpty {
            parts.append(interim)
        }
        return parts.joined(separator: " ")
    }

    func finalizedText() -> String {
        let final = finals.joined(separator: " ")
        if !final.isEmpty {
            return final
        }
        return currentText()
    }

    func finalLanguage(fallback: String?) -> String? {
        detectedLanguage ?? fallback
    }
}

private enum ElevenLabsReceivePayload: Sendable {
    case text(String)
    case data(Data)
    case timedOut
}

@objc(ElevenLabsPlugin)
final class ElevenLabsPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.elevenlabs"
    static let pluginName = "ElevenLabs"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?

    private let logger = Logger(subsystem: "com.typewhisper.elevenlabs", category: "Plugin")

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

    var providerId: String { "elevenlabs" }
    var providerDisplayName: String { "ElevenLabs" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "scribe_v2", displayName: "Scribe v2"),
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
    var supportedLanguages: [String] { elevenLabsSupportedLanguages }

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

        if !PluginDictionaryTerms.terms(fromPrompt: prompt).isEmpty {
            let result = try await transcribeREST(
                audio: audio,
                language: language,
                modelId: modelId,
                apiKey: apiKey,
                prompt: prompt
            )
            _ = onProgress(result.text)
            return result
        }

        do {
            return try await transcribeWebSocket(
                audio: audio,
                language: language,
                modelId: modelId,
                apiKey: apiKey,
                onProgress: onProgress
            )
        } catch {
            logger.warning("Realtime transcription failed, falling back to REST: \(error.localizedDescription)")
            return try await transcribeREST(
                audio: audio,
                language: language,
                modelId: modelId,
                apiKey: apiKey,
                prompt: prompt
            )
        }
    }

    private func transcribeREST(
        audio: AudioData,
        language: String?,
        modelId: String,
        apiKey: String,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text") else {
            throw PluginTranscriptionError.apiError("Invalid ElevenLabs REST URL")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        body.appendMultipartFile(
            boundary: boundary,
            name: "file",
            filename: "audio.wav",
            contentType: "audio/wav",
            data: audio.wavData
        )
        body.appendMultipartField(boundary: boundary, name: "model_id", value: modelId)
        if let language, !language.isEmpty {
            body.appendMultipartField(boundary: boundary, name: "language_code", value: language)
        }
        if modelId == "scribe_v2" {
            for term in PluginDictionaryTerms.terms(fromPrompt: prompt) {
                body.appendMultipartField(boundary: boundary, name: "keyterms", value: term)
            }
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseRESTResponse(data, fallbackLanguage: language)
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    private func transcribeWebSocket(
        audio: AudioData,
        language: String?,
        modelId: String,
        apiKey: String,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        let url = try Self.realtimeURL(language: language, modelId: modelId)

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let wsTask = URLSession.shared.webSocketTask(with: request)
        wsTask.resume()

        let collector = ElevenLabsTranscriptCollector()

        let receiveTask = Task {
            var receivedCommittedTranscript = false

            while !Task.isCancelled {
                let timeout: Duration = receivedCommittedTranscript ? .seconds(1) : .seconds(8)
                let payload = try await Self.receivePayload(from: wsTask, timeout: timeout)

                let rawText: String
                switch payload {
                case .text(let text):
                    rawText = text
                case .data(let data):
                    guard let text = String(data: data, encoding: .utf8) else { continue }
                    rawText = text
                case .timedOut:
                    return
                }

                guard let data = rawText.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let messageType = json["message_type"] as? String else {
                    continue
                }

                switch messageType {
                case "session_started":
                    continue
                case "partial_transcript":
                    let text = json["text"] as? String ?? ""
                    await collector.setInterim(text)
                    let currentText = await collector.currentText()
                    if !currentText.isEmpty {
                        _ = onProgress(currentText)
                    }
                case "committed_transcript", "committed_transcript_with_timestamps":
                    receivedCommittedTranscript = true
                    let text = json["text"] as? String ?? ""
                    let detectedLanguage = json["language_code"] as? String
                    await collector.addFinal(text, language: detectedLanguage)
                    let currentText = await collector.currentText()
                    if !currentText.isEmpty {
                        _ = onProgress(currentText)
                    }
                default:
                    if messageType.localizedCaseInsensitiveContains("error") {
                        throw PluginTranscriptionError.apiError(Self.errorMessage(from: json) ?? rawText)
                    }
                }
            }
        }

        let pcmData = Self.floatToPCM16(audio.samples)
        guard !pcmData.isEmpty else {
            wsTask.cancel(with: .normalClosure, reason: nil)
            throw PluginTranscriptionError.apiError("No audio available for realtime transcription")
        }

        let chunkSize = 8192
        var offset = 0

        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            let isFinalChunk = end == pcmData.count

            var payload: [String: Any] = [
                "message_type": "input_audio_chunk",
                "audio_base_64": chunk.base64EncodedString(),
                "sample_rate": 16000,
            ]
            if isFinalChunk {
                payload["commit"] = true
            }

            let jsonData = try JSONSerialization.data(withJSONObject: payload)
            guard let jsonText = String(data: jsonData, encoding: .utf8) else {
                throw PluginTranscriptionError.apiError("Failed to encode realtime payload")
            }

            try await wsTask.send(.string(jsonText))
            offset = end
        }

        do {
            try await receiveTask.value
        } catch {
            wsTask.cancel(with: .goingAway, reason: nil)
            throw error
        }

        wsTask.cancel(with: .normalClosure, reason: nil)

        let finalText = await collector.finalizedText()
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginTranscriptionError.apiError("Realtime API returned no transcript")
        }

        let detectedLanguage = await collector.finalLanguage(fallback: language)
        return PluginTranscriptionResult(text: finalText, detectedLanguage: detectedLanguage)
    }

    private static func realtimeURL(language: String?, modelId: String) throws -> URL {
        guard var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime") else {
            throw PluginTranscriptionError.apiError("Invalid realtime URL")
        }

        var queryItems = [
            URLQueryItem(name: "model_id", value: realtimeModelId(for: modelId)),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
        ]

        if let language, !language.isEmpty {
            queryItems.append(URLQueryItem(name: "language_code", value: language))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PluginTranscriptionError.apiError("Invalid realtime query parameters")
        }

        return url
    }

    private static func realtimeModelId(for modelId: String) -> String {
        switch modelId {
        case "scribe_v1":
            return "scribe_v2_realtime"
        default:
            return "scribe_v2_realtime"
        }
    }

    private static func parseRESTResponse(_ data: Data, fallbackLanguage: String?) throws -> PluginTranscriptionResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginTranscriptionError.apiError("Invalid ElevenLabs response")
        }

        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLanguage = json["language_code"] as? String ?? fallbackLanguage
        return PluginTranscriptionResult(text: text, detectedLanguage: detectedLanguage)
    }

    private static func receivePayload(
        from task: URLSessionWebSocketTask,
        timeout: Duration
    ) async throws -> ElevenLabsReceivePayload {
        try await withThrowingTaskGroup(of: ElevenLabsReceivePayload.self) { group in
            group.addTask {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    return .text(text)
                case .data(let data):
                    return .data(data)
                @unknown default:
                    return .timedOut
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }

            let result = try await group.next() ?? .timedOut
            group.cancelAll()
            return result
        }
    }

    private static func errorMessage(from json: [String: Any]) -> String? {
        if let error = json["error"] as? String, !error.isEmpty {
            return error
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        if let details = json["details"] as? String, !details.isEmpty {
            return details
        }
        return nil
    }

    private static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    fileprivate func validateApiKey(_ key: String) async -> Bool {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/user") else { return false }

        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    var settingsView: AnyView? {
        AnyView(ElevenLabsSettingsView(plugin: self))
    }

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[ElevenLabsPlugin] Failed to store API key: \(error)")
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
                print("[ElevenLabsPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }
}

private struct ElevenLabsSettingsView: View {
    let plugin: ElevenLabsPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel = ""
    private let bundle = Bundle(for: ElevenLabsPlugin.self)
    private var trimmedInputKey: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var storedKey: String {
        plugin._apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private var hasStoredKey: Bool {
        !storedKey.isEmpty
    }
    private var isEditingStoredKey: Bool {
        hasStoredKey && trimmedInputKey == storedKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

                    if hasStoredKey && isEditingStoredKey && validationResult != false {
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
                        .disabled(trimmedInputKey.isEmpty || isValidating)
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
                        Text(
                            result
                                ? String(localized: "Valid API Key", bundle: bundle)
                                : String(localized: "Invalid API Key", bundle: bundle)
                        )
                        .font(.caption)
                        .foregroundStyle(result ? .green : .red)
                    }
                }
            }

            if plugin.isConfigured {
                Divider()

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
                isValidating = true
                Task {
                    let isValid = await plugin.validateApiKey(key)
                    await MainActor.run {
                        isValidating = false
                        validationResult = isValid
                    }
                }
            }
            selectedModel = plugin.selectedModelId ?? plugin.transcriptionModels.first?.id ?? ""
        }
    }

    private func saveApiKey() {
        let trimmedKey = trimmedInputKey
        guard !trimmedKey.isEmpty else { return }

        isValidating = true
        validationResult = nil

        Task {
            let isValid = await plugin.validateApiKey(trimmedKey)
            await MainActor.run {
                if isValid {
                    plugin.setApiKey(trimmedKey)
                }
                isValidating = false
                validationResult = isValid
            }
        }
    }
}

private extension Data {
    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(
        boundary: String,
        name: String,
        filename: String,
        contentType: String,
        data: Data
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
