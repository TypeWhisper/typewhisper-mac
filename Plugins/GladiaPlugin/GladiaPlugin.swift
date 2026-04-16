import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

private let gladiaSupportedLanguages = [
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

private actor GladiaTranscriptCollector {
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

private enum GladiaReceivePayload: Sendable {
    case text(String)
    case data(Data)
    case timedOut
}

private struct GladiaLiveSession: Sendable {
    let id: String
    let url: URL
}

@objc(GladiaPlugin)
final class GladiaPlugin: NSObject, TranscriptionEnginePlugin, LanguageHintTranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.gladia"
    static let pluginName = "Gladia"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?

    private let logger = Logger(subsystem: "com.typewhisper.gladia", category: "Plugin")

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

    var providerId: String { "gladia" }
    var providerDisplayName: String { "Gladia" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "solaria-1", displayName: "Solaria-1"),
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
    var supportedLanguages: [String] { gladiaSupportedLanguages }

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
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        return try await transcribeREST(
            audio: audio,
            language: languageSelection.requestedLanguage,
            languageHints: resolvedLanguageHints(
                requestedLanguage: languageSelection.requestedLanguage,
                languageHints: languageSelection.languageHints
            ),
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

        do {
            return try await transcribeWebSocket(
                audio: audio,
                language: language,
                modelId: modelId,
                prompt: prompt,
                apiKey: apiKey,
                onProgress: onProgress
            )
        } catch {
            logger.warning("Live transcription failed, falling back to REST: \(error.localizedDescription)")
            return try await transcribeREST(
                audio: audio,
                language: language,
                modelId: modelId,
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
                modelId: modelId,
                prompt: prompt,
                apiKey: apiKey,
                onProgress: onProgress
            )
        } catch {
            logger.warning("Live transcription failed, falling back to REST: \(error.localizedDescription)")
            return try await transcribeREST(
                audio: audio,
                language: languageSelection.requestedLanguage,
                languageHints: effectiveHints,
                modelId: modelId,
                apiKey: apiKey,
                prompt: prompt
            )
        }
    }

    private func transcribeREST(
        audio: AudioData,
        language: String?,
        languageHints: [String] = [],
        modelId: String,
        apiKey: String,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        let audioURL = try await uploadAudio(audio.wavData, apiKey: apiKey)
        let resultURL = try await submitPreRecorded(
            audioURL: audioURL,
            language: language,
            languageHints: languageHints,
            modelId: modelId,
            apiKey: apiKey,
            prompt: prompt
        )
        return try await pollResult(url: resultURL, apiKey: apiKey, fallbackLanguage: language)
    }

    private func uploadAudio(_ wavData: Data, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.gladia.io/v2/upload") else {
            throw PluginTranscriptionError.apiError("Invalid Gladia upload URL")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        body.appendMultipartFile(
            boundary: boundary,
            name: "audio",
            filename: "audio.wav",
            contentType: "audio/wav",
            data: wavData
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200, 201:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let audioURL = json["audio_url"] as? String,
                  !audioURL.isEmpty else {
                throw PluginTranscriptionError.apiError("Invalid upload response")
            }
            return audioURL
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Upload failed HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    private func submitPreRecorded(
        audioURL: String,
        language: String?,
        languageHints: [String] = [],
        modelId: String,
        apiKey: String,
        prompt: String?
    ) async throws -> URL {
        guard let url = URL(string: "https://api.gladia.io/v2/pre-recorded") else {
            throw PluginTranscriptionError.apiError("Invalid Gladia pre-recorded URL")
        }

        var body: [String: Any] = [
            "audio_url": audioURL,
        ]

        if modelId == "solaria-1" {
            body["model"] = modelId
        }

        let effectiveHints = resolvedLanguageHints(requestedLanguage: language, languageHints: languageHints)
        if !effectiveHints.isEmpty {
            body["language_config"] = [
                "languages": effectiveHints,
                "code_switching": effectiveHints.count > 1,
            ]
        }
        if let customVocabulary = Self.customVocabularyConfig(prompt: prompt) {
            body["custom_vocabulary"] = true
            body["custom_vocabulary_config"] = customVocabulary
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200, 201, 202:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PluginTranscriptionError.apiError("Invalid pre-recorded response")
            }

            if let resultURLString = json["result_url"] as? String,
               let resultURL = URL(string: resultURLString) {
                return resultURL
            }

            if let id = json["id"] as? String,
               let resultURL = URL(string: "https://api.gladia.io/v2/pre-recorded/\(id)") {
                return resultURL
            }

            throw PluginTranscriptionError.apiError("Missing result URL in Gladia response")
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Pre-recorded request failed HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    private func pollResult(
        url: URL,
        apiKey: String,
        fallbackLanguage: String?
    ) async throws -> PluginTranscriptionResult {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
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
            case "done":
                return Self.parseResultPayload(json, fallbackLanguage: fallbackLanguage)
            case "error":
                throw PluginTranscriptionError.apiError(Self.errorMessage(from: json) ?? "Gladia pre-recorded transcription failed")
            default:
                continue
            }
        }

        throw PluginTranscriptionError.apiError("Gladia pre-recorded transcription timed out")
    }

    private func transcribeWebSocket(
        audio: AudioData,
        language: String?,
        languageHints: [String] = [],
        modelId: String,
        prompt: String?,
        apiKey: String,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        let liveSession = try await createLiveSession(
            language: language,
            languageHints: languageHints,
            modelId: modelId,
            apiKey: apiKey,
            prompt: prompt
        )
        let wsTask = URLSession.shared.webSocketTask(with: liveSession.url)
        wsTask.resume()

        let collector = GladiaTranscriptCollector()
        let loggerRef = logger

        let receiveTask = Task {
            do {
                while !Task.isCancelled {
                    let payload = try await Self.receivePayload(from: wsTask, timeout: .seconds(20))

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
                          let type = json["type"] as? String else {
                        continue
                    }

                    switch type {
                    case "transcript":
                        let payload = json["data"] as? [String: Any]
                        let isFinal = payload?["is_final"] as? Bool ?? false
                        let text = Self.extractNestedString(payload, path: ["utterance", "text"]) ?? ""
                        let detectedLanguage = Self.extractNestedString(payload, path: ["utterance", "language"])
                            ?? payload?["language"] as? String

                        if isFinal {
                            await collector.addFinal(text, language: detectedLanguage)
                        } else {
                            await collector.setInterim(text, language: detectedLanguage)
                        }

                        let currentText = await collector.currentText()
                        if !currentText.isEmpty {
                            _ = onProgress(currentText)
                        }
                    case "error":
                        throw PluginTranscriptionError.apiError(Self.errorMessage(from: json) ?? rawText)
                    default:
                        continue
                    }
                }
            } catch {
                loggerRef.warning("Gladia WebSocket receive loop ended: \(error.localizedDescription)")
            }
        }

        let pcmData = Self.floatToPCM16(audio.samples)
        guard !pcmData.isEmpty else {
            wsTask.cancel(with: .normalClosure, reason: nil)
            throw PluginTranscriptionError.apiError("No audio available for live transcription")
        }

        let chunkSize = 8192
        var offset = 0

        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)

            let payload: [String: Any] = [
                "type": "audio_chunk",
                "data": [
                    "chunk": chunk.base64EncodedString(),
                ],
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: payload)
            guard let jsonText = String(data: jsonData, encoding: .utf8) else {
                throw PluginTranscriptionError.apiError("Failed to encode audio chunk")
            }

            try await wsTask.send(.string(jsonText))
            offset = end
        }

        try await wsTask.send(.string("{\"type\":\"stop_recording\"}"))
        _ = await receiveTask.result
        wsTask.cancel(with: .normalClosure, reason: nil)

        let finalText = await collector.finalizedText()
        if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let detectedLanguage = await collector.finalLanguage(fallback: language)
            return PluginTranscriptionResult(text: finalText, detectedLanguage: detectedLanguage)
        }

        return try await fetchLiveResult(
            sessionId: liveSession.id,
            apiKey: apiKey,
            fallbackLanguage: language
        )
    }

    private func createLiveSession(
        language: String?,
        languageHints: [String] = [],
        modelId: String,
        apiKey: String,
        prompt: String?
    ) async throws -> GladiaLiveSession {
        guard let url = URL(string: "https://api.gladia.io/v2/live") else {
            throw PluginTranscriptionError.apiError("Invalid Gladia live URL")
        }

        var body: [String: Any] = [
            "encoding": "wav/pcm",
            "sample_rate": 16000,
            "bit_depth": 16,
            "channels": 1,
            "model": modelId,
            "messages_config": [
                "receive_partial_transcripts": true,
                "receive_final_transcripts": true,
                "receive_errors": true,
            ],
        ]

        let effectiveHints = resolvedLanguageHints(requestedLanguage: language, languageHints: languageHints)
        if !effectiveHints.isEmpty {
            body["language_config"] = [
                "languages": effectiveHints,
                "code_switching": effectiveHints.count > 1,
            ]
        }
        if let customVocabulary = Self.customVocabularyConfig(prompt: prompt) {
            body["realtime_processing"] = [
                "custom_vocabulary": true,
                "custom_vocabulary_config": customVocabulary,
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await PluginHTTPClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200, 201:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  let urlString = json["url"] as? String,
                  let wsURL = URL(string: urlString) else {
                throw PluginTranscriptionError.apiError("Invalid live session response")
            }
            return GladiaLiveSession(id: id, url: wsURL)
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Live session creation failed HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    private func fetchLiveResult(
        sessionId: String,
        apiKey: String,
        fallbackLanguage: String?
    ) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: "https://api.gladia.io/v2/live/\(sessionId)") else {
            throw PluginTranscriptionError.apiError("Invalid Gladia live result URL")
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        request.timeoutInterval = 15

        for _ in 0..<90 {
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
            case "done":
                return Self.parseResultPayload(json, fallbackLanguage: fallbackLanguage)
            case "error":
                throw PluginTranscriptionError.apiError(Self.errorMessage(from: json) ?? "Gladia live transcription failed")
            default:
                continue
            }
        }

        throw PluginTranscriptionError.apiError("Gladia live transcription timed out")
    }

    private static func parseResultPayload(
        _ json: [String: Any],
        fallbackLanguage: String?
    ) -> PluginTranscriptionResult {
        let fullTranscript = (
            extractNestedString(json, path: ["result", "transcription", "full_transcript"])
                ?? extractNestedString(json, path: ["transcription", "full_transcript"])
                ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let detectedLanguage =
            extractFirstString(json, path: ["result", "transcription", "languages"])
            ?? extractFirstString(json, path: ["transcription", "languages"])
            ?? fallbackLanguage

        if !fullTranscript.isEmpty {
            return PluginTranscriptionResult(text: fullTranscript, detectedLanguage: detectedLanguage)
        }

        let utterances = (extractNestedValue(json, path: ["result", "transcription", "utterances"]) as? [[String: Any]])
            ?? (extractNestedValue(json, path: ["transcription", "utterances"]) as? [[String: Any]])
            ?? []

        let text = utterances
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return PluginTranscriptionResult(text: text, detectedLanguage: detectedLanguage)
    }

    private static func extractNestedString(_ json: [String: Any]?, path: [String]) -> String? {
        extractNestedValue(json, path: path) as? String
    }

    private static func extractFirstString(_ json: [String: Any]?, path: [String]) -> String? {
        if let values = extractNestedValue(json, path: path) as? [String] {
            return values.first
        }
        return nil
    }

    private static func extractNestedValue(_ json: [String: Any]?, path: [String]) -> Any? {
        guard let json else { return nil }

        var current: Any = json
        for key in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else {
                return nil
            }
            current = next
        }

        return current
    }

    private static func receivePayload(
        from task: URLSessionWebSocketTask,
        timeout: Duration
    ) async throws -> GladiaReceivePayload {
        try await withThrowingTaskGroup(of: GladiaReceivePayload.self) { group in
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

    private static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func errorMessage(from json: [String: Any]) -> String? {
        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = json["error"] as? String, !error.isEmpty {
            return error
        }
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let exception = error["exception"] as? String, !exception.isEmpty {
                return exception
            }
        }
        return nil
    }

    private static func customVocabularyConfig(prompt: String?) -> [String: Any]? {
        let vocabulary = PluginDictionaryTerms.terms(fromPrompt: prompt)
        guard !vocabulary.isEmpty else { return nil }
        return [
            "vocabulary": vocabulary,
            "default_intensity": 0.7,
        ]
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

    fileprivate func validateApiKey(_ key: String) async -> Bool {
        guard let url = URL(string: "https://api.gladia.io/v2/live") else { return false }

        let body: [String: Any] = [
            "encoding": "wav/pcm",
            "sample_rate": 16000,
            "bit_depth": 16,
            "channels": 1,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-gladia-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200 || httpResponse.statusCode == 201
        } catch {
            return false
        }
    }

    var settingsView: AnyView? {
        AnyView(GladiaSettingsView(plugin: self))
    }

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[GladiaPlugin] Failed to store API key: \(error)")
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
                print("[GladiaPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }
}

private struct GladiaSettingsView: View {
    let plugin: GladiaPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel = ""
    private let bundle = Bundle(for: GladiaPlugin.self)

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

private extension Data {
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
