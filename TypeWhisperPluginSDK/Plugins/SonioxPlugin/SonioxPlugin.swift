import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

// MARK: - Supported Languages

private let sonioxSupportedLanguages = [
    "af", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs",
    "cy", "da", "de", "el", "en", "es", "et", "fa", "fi", "fr",
    "gl", "gu", "ha", "he", "hi", "hr", "hu", "hy", "id", "is",
    "it", "ja", "ka", "kk", "km", "kn", "ko", "lo", "lt", "lv",
    "mk", "ml", "mn", "mr", "ms", "my", "ne", "nl", "no", "pa",
    "pl", "pt", "ro", "ru", "sk", "sl", "so", "sq", "sr", "sv",
    "sw", "ta", "te", "th", "tr", "uk", "ur", "uz", "vi", "zh",
]

// MARK: - Transcript Collector

private actor TranscriptCollector {
    private var finals: [String] = []
    private var interim: String = ""
    private var _detectedLanguage: String?
    private var _error: String?

    func addFinal(_ text: String, language: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            finals.append(trimmed)
        }
        interim = ""
        if let language, !language.isEmpty {
            _detectedLanguage = language
        }
    }

    func setInterim(_ text: String, language: String? = nil) {
        interim = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let language, !language.isEmpty {
            _detectedLanguage = language
        }
    }

    func setError(_ message: String) {
        _error = message
    }

    var error: String? { _error }

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

    func detectedLanguage(fallback: String?) -> String? {
        _detectedLanguage ?? fallback
    }
}

// MARK: - Plugin Entry Point

@objc(SonioxPlugin)
final class SonioxPlugin: NSObject, TranscriptionEnginePlugin, LanguageHintTranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, DictionaryTermsBudgetProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.soniox"
    static let pluginName = "Soniox"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?

    private let logger = Logger(subsystem: "com.typewhisper.soniox", category: "Plugin")

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

    var providerId: String { "soniox" }
    var providerDisplayName: String { "Soniox" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "stt-rt-v4", displayName: "STT RT v4"),
            PluginModelInfo(id: "stt-rt-preview", displayName: "STT RT Preview"),
        ]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { true }
    var supportsStreaming: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }
    var dictionaryTermsBudget: DictionaryTermsBudget { DictionaryTermsBudget(maxTotalChars: 10_000) }

    var supportedLanguages: [String] { sonioxSupportedLanguages }

    // MARK: - Transcription (REST Fallback)

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }

        return try await transcribeREST(
            audio: audio,
            language: language,
            translate: translate,
            apiKey: apiKey,
            prompt: prompt
        )
    }

    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }

        let effectiveHints = resolvedLanguageHints(
            requestedLanguage: languageSelection.requestedLanguage,
            languageHints: languageSelection.languageHints
        )

        return try await transcribeREST(
            audio: audio,
            language: languageSelection.requestedLanguage,
            languageHints: effectiveHints,
            translate: translate,
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
                audio: audio, language: language, translate: translate,
                modelId: modelId, prompt: prompt, apiKey: apiKey, onProgress: onProgress
            )
        } catch {
            logger.warning("WebSocket streaming failed, falling back to REST: \(error.localizedDescription)")
            return try await transcribeREST(
                audio: audio,
                language: language,
                translate: translate,
                apiKey: apiKey,
                prompt: prompt
            )
        }
    }

    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
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

        let effectiveHints = resolvedLanguageHints(
            requestedLanguage: languageSelection.requestedLanguage,
            languageHints: languageSelection.languageHints
        )

        do {
            return try await transcribeWebSocket(
                audio: audio,
                language: languageSelection.requestedLanguage,
                languageHints: effectiveHints,
                translate: translate,
                modelId: modelId,
                prompt: prompt,
                apiKey: apiKey,
                onProgress: onProgress
            )
        } catch {
            logger.warning("WebSocket streaming failed, falling back to REST: \(error.localizedDescription)")
            return try await transcribeREST(
                audio: audio,
                language: languageSelection.requestedLanguage,
                languageHints: effectiveHints,
                translate: translate,
                apiKey: apiKey,
                prompt: prompt
            )
        }
    }

    // MARK: - WebSocket Implementation

    private func transcribeWebSocket(
        audio: AudioData,
        language: String?,
        languageHints: [String] = [],
        translate: Bool,
        modelId: String,
        prompt: String?,
        apiKey: String,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket") else {
            throw PluginTranscriptionError.apiError("Invalid Soniox WebSocket URL")
        }

        let wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask.resume()

        // Send config message with API key (Soniox auth is in the first message)
        var config: [String: Any] = [
            "api_key": apiKey,
            "model": modelId,
            "audio_format": "s16le",
            "sample_rate": 16000,
            "num_channels": 1,
            "enable_endpoint_detection": true,
        ]

        let effectiveHints = resolvedLanguageHints(requestedLanguage: language, languageHints: languageHints)
        if !effectiveHints.isEmpty {
            config["language_hints"] = effectiveHints
        }

        if translate {
            config["translation"] = [
                "type": "one_way",
                "target_language": "en",
            ]
        }
        if let context = Self.contextPayload(prompt: prompt) {
            config["context"] = context
        }

        let configData = try JSONSerialization.data(withJSONObject: config)
        guard let configString = String(data: configData, encoding: .utf8) else {
            throw PluginTranscriptionError.apiError("Failed to encode config")
        }
        try await wsTask.send(.string(configString))

        // Receive loop
        let collector = TranscriptCollector()
        let loggerRef = self.logger
        let isTranslating = translate

        let receiveTask = Task {
            do {
                while !Task.isCancelled {
                    let message = try await wsTask.receive()

                    guard case .string(let text) = message else { continue }

                    guard let data = text.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }

                    // Check for finished signal
                    if json["finished"] as? Bool == true { break }

                    // Check for error
                    if let errorObj = json["error"] as? [String: Any] {
                        let msg = errorObj["message"] as? String ?? "Unknown Soniox error"
                        loggerRef.error("Soniox error: \(msg)")
                        await collector.setError(msg)
                        break
                    }

                    // Parse tokens
                    guard let tokens = json["tokens"] as? [[String: Any]] else { continue }

                    var finalText: [String] = []
                    var interimText: [String] = []
                    var tokenLanguage: String?

                    for token in tokens {
                        guard let tokenStr = token["text"] as? String else { continue }

                        // When translating, skip original tokens
                        if isTranslating {
                            let status = token["translation_status"] as? String
                            if status == "original" { continue }
                        }

                        let isFinal = token["is_final"] as? Bool ?? false
                        if let lang = token["language"] as? String, !lang.isEmpty {
                            tokenLanguage = lang
                        }

                        if isFinal {
                            finalText.append(tokenStr)
                        } else {
                            interimText.append(tokenStr)
                        }
                    }

                    let joinedFinal = finalText.joined()
                    let joinedInterim = interimText.joined()

                    if !joinedFinal.isEmpty {
                        await collector.addFinal(joinedFinal, language: tokenLanguage)
                    }
                    if !joinedInterim.isEmpty {
                        await collector.setInterim(joinedInterim, language: tokenLanguage)
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
        let pcmData = Self.floatToPCM16(audio.samples)
        let chunkSize = 8192
        var offset = 0

        defer { receiveTask.cancel() }

        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            try await wsTask.send(.data(chunk))
            offset = end
        }

        // Finalize pending tokens and signal end of audio
        try await wsTask.send(.string("{\"type\":\"finalize\"}"))
        try await wsTask.send(.data(Data()))

        // Wait for server to finish
        _ = await receiveTask.result

        wsTask.cancel(with: .normalClosure, reason: nil)

        // Check for server-side errors (e.g. invalid API key)
        if let error = await collector.error {
            throw PluginTranscriptionError.apiError(error)
        }

        let finalText = await collector.finalResult()
        let detectedLanguage = await collector.detectedLanguage(fallback: language)
        return PluginTranscriptionResult(text: finalText, detectedLanguage: detectedLanguage)
    }

    // MARK: - REST Implementation (4-Step Async)

    private func transcribeREST(
        audio: AudioData,
        language: String?,
        languageHints: [String] = [],
        translate: Bool,
        apiKey: String,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        let fileId = try await uploadFile(wavData: audio.wavData, apiKey: apiKey)
        let transcriptionId = try await createTranscription(
            fileId: fileId,
            language: language,
            languageHints: languageHints,
            translate: translate,
            apiKey: apiKey,
            prompt: prompt
        )
        try await pollUntilCompleted(id: transcriptionId, apiKey: apiKey)
        return try await fetchTranscript(id: transcriptionId, apiKey: apiKey, language: language)
    }

    private func uploadFile(wavData: Data, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.soniox.com/v1/files") else {
            throw PluginTranscriptionError.apiError("Invalid upload URL")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200, 201: break
        case 401: throw PluginTranscriptionError.invalidApiKey
        case 413: throw PluginTranscriptionError.fileTooLarge
        case 429: throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Upload failed HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileId = json["id"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid upload response")
        }

        return fileId
    }

    private func createTranscription(
        fileId: String,
        language: String?,
        languageHints: [String] = [],
        translate: Bool,
        apiKey: String,
        prompt: String?
    ) async throws -> String {
        guard let url = URL(string: "https://api.soniox.com/v1/transcriptions") else {
            throw PluginTranscriptionError.apiError("Invalid transcriptions URL")
        }

        var body: [String: Any] = [
            "file_id": fileId,
            "model": "stt-async-v4",
        ]

        let effectiveHints = resolvedLanguageHints(requestedLanguage: language, languageHints: languageHints)
        if !effectiveHints.isEmpty {
            body["language_hints"] = effectiveHints
        }

        if translate {
            body["translation"] = [
                "type": "one_way",
                "target_language": "en",
            ]
        }
        if let context = Self.contextPayload(prompt: prompt) {
            body["context"] = context
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200, 201: break
        case 401: throw PluginTranscriptionError.invalidApiKey
        case 429: throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Create transcription failed HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid transcription creation response")
        }

        return id
    }

    private static func contextPayload(prompt: String?) -> [String: Any]? {
        let terms = PluginDictionaryTerms.terms(fromPrompt: prompt)
        guard !terms.isEmpty else { return nil }
        return ["terms": terms]
    }

    private func resolvedLanguageHints(requestedLanguage: String?, languageHints: [String]) -> [String] {
        if !languageHints.isEmpty {
            return languageHints
        }
        if let requestedLanguage, !requestedLanguage.isEmpty {
            return [requestedLanguage]
        }
        return []
    }

    private func pollUntilCompleted(id: String, apiKey: String) async throws {
        guard let url = URL(string: "https://api.soniox.com/v1/transcriptions/\(id)") else {
            throw PluginTranscriptionError.apiError("Invalid poll URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
                return
            case "error", "failed":
                // Try multiple error field formats
                let errorMsg: String
                if let errStr = json["error"] as? String {
                    errorMsg = errStr
                } else if let errObj = json["error"] as? [String: Any], let msg = errObj["message"] as? String {
                    errorMsg = msg
                } else if let errMsg = json["error_message"] as? String {
                    errorMsg = errMsg
                } else {
                    // Log full response for debugging
                    let responseStr = String(data: data, encoding: .utf8) ?? ""
                    logger.error("Soniox transcription failed, full response: \(responseStr)")
                    errorMsg = "Transcription failed (status: \(status))"
                }
                throw PluginTranscriptionError.apiError(errorMsg)
            default:
                continue
            }
        }

        throw PluginTranscriptionError.apiError("Transcription timed out after 5 minutes")
    }

    private func fetchTranscript(id: String, apiKey: String, language: String?) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: "https://api.soniox.com/v1/transcriptions/\(id)/transcript") else {
            throw PluginTranscriptionError.apiError("Invalid transcript URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Fetch transcript failed HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginTranscriptionError.apiError("Invalid transcript response")
        }

        // Extract full text from tokens or top-level text field
        let text: String
        if let tokens = json["tokens"] as? [[String: Any]] {
            text = tokens.compactMap { $0["text"] as? String }.joined()
        } else {
            text = json["text"] as? String ?? ""
        }

        return PluginTranscriptionResult(text: text, detectedLanguage: language)
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
        guard let url = URL(string: "https://api.soniox.com/v1/files") else { return false }
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
        AnyView(SonioxSettingsView(plugin: self))
    }

    // MARK: - Internal Methods for Settings

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[SonioxPlugin] Failed to store API key: \(error)")
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
                print("[SonioxPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }
}

// MARK: - Settings View

private struct SonioxSettingsView: View {
    let plugin: SonioxPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    private let bundle = Bundle(for: SonioxPlugin.self)

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
