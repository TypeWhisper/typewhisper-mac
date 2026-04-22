import Foundation
import os

// MARK: - Host Services

public protocol HostServices: Sendable {
    // Keychain
    func storeSecret(key: String, value: String) throws
    func loadSecret(key: String) -> String?

    // UserDefaults (plugin-scoped)
    func userDefault(forKey: String) -> Any?
    func setUserDefault(_ value: Any?, forKey: String)

    // Plugin data directory
    var pluginDataDirectory: URL { get }

    // App context
    var activeAppBundleId: String? { get }
    var activeAppName: String? { get }

    // Event bus
    var eventBus: EventBusProtocol { get }

    // Available rule names
    var availableRuleNames: [String] { get }

    // Notify host that plugin capabilities changed (e.g. model loaded/unloaded)
    func notifyCapabilitiesChanged()

    // Streaming display: call with true when the plugin provides its own streaming text UI,
    // so the built-in indicator suppresses its streaming text display.
    func setStreamingDisplayActive(_ active: Bool)
}

public extension HostServices {
    @available(*, deprecated, renamed: "availableRuleNames")
    var availableProfileNames: [String] { availableRuleNames }
}

// MARK: - HTTP Client (Ephemeral Sessions)

/// Drop-in replacement for `URLSession.shared.data(for:)` that creates a fresh ephemeral
/// session per call. This prevents stale HTTP/2 connections after sleep/wake or network changes
/// from hanging indefinitely.
public enum PluginHTTPClient {
    private static let logger = Logger(subsystem: "com.typewhisper.sdk", category: "HTTP")

    public static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let config = URLSessionConfiguration.ephemeral
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 30
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout * 2, 90)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "unknown"
        logger.info("\(method) \(url)")
        let start = ContinuousClock.now

        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = ContinuousClock.now - start
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("\(method) \(url) -> \(status) (\(elapsed))")
            return (data, response)
        } catch {
            let elapsed = ContinuousClock.now - start
            logger.error("\(method) \(url) failed after \(elapsed): \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - WAV Encoder Utility

public struct PluginWavEncoder {
    public static func encode(_ samples: [Float], sampleRate: Int = 16000) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * Int(blockAlign))
        let fileSize = 36 + dataSize

        var data = Data(capacity: 44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * 32767)
            data.append(contentsOf: withUnsafeBytes(of: int16Value.littleEndian) { Array($0) })
        }

        return data
    }
}

// MARK: - OpenAI-Compatible Transcription Helper

public enum PluginTranscriptionError: LocalizedError, Sendable {
    case notConfigured
    case noModelSelected
    case invalidApiKey
    case rateLimited
    case fileTooLarge
    case apiError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Cloud provider not configured. Please set an API key."
        case .noModelSelected:
            "No cloud model selected."
        case .invalidApiKey:
            "Invalid API key. Please check your API key and try again."
        case .rateLimited:
            "Rate limit exceeded. Please wait and try again."
        case .fileTooLarge:
            "Audio file too large for the API."
        case .apiError(let message):
            "API error: \(message)"
        case .networkError(let message):
            "Network error: \(message)"
        }
    }
}

public struct PluginOpenAITranscriptionHelper: Sendable {
    public let baseURL: String
    public let responseFormat: String
    static let minimumUploadDuration: TimeInterval = 1.0
    static let uploadSampleRate = 16000

    public init(baseURL: String, responseFormat: String = "verbose_json") {
        self.baseURL = baseURL
        self.responseFormat = responseFormat
    }

    func normalizedAudioForUpload(_ audio: AudioData) -> AudioData {
        guard audio.duration < Self.minimumUploadDuration else { return audio }

        let paddedSamples = PluginAudioUtils.paddedSamples(
            audio.samples,
            minimumDuration: Self.minimumUploadDuration,
            sampleRate: Self.uploadSampleRate
        )
        guard paddedSamples.count != audio.samples.count else { return audio }

        return AudioData(
            samples: paddedSamples,
            wavData: PluginWavEncoder.encode(paddedSamples, sampleRate: Self.uploadSampleRate),
            duration: Double(paddedSamples.count) / Double(Self.uploadSampleRate)
        )
    }

    public func transcribe(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        responseFormat: String? = nil
    ) async throws -> PluginTranscriptionResult {
        let endpoint: String
        if translate {
            endpoint = "\(baseURL)/v1/audio/translations"
        } else {
            endpoint = "\(baseURL)/v1/audio/transcriptions"
        }

        guard let url = URL(string: endpoint) else {
            throw PluginTranscriptionError.apiError("Invalid URL: \(endpoint)")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let uploadAudio = normalizedAudioForUpload(audio)
        var body = Data()

        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(uploadAudio.wavData)
        body.append("\r\n".data(using: .utf8)!)

        // model field
        body.appendFormField(boundary: boundary, name: "model", value: modelName)

        // response_format field
        let format = responseFormat ?? self.responseFormat
        body.appendFormField(boundary: boundary, name: "response_format", value: format)

        // language field (only for transcription)
        if !translate, let language, !language.isEmpty {
            body.appendFormField(boundary: boundary, name: "language", value: language)
        }

        // prompt field
        if let prompt, !prompt.isEmpty {
            body.appendFormField(boundary: boundary, name: "prompt", value: prompt)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 429:
            throw PluginTranscriptionError.rateLimited
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        default:
            let errorMessage = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        return try parseResponse(responseData)
    }

    public func validateApiKey(_ apiKey: String) async -> Bool {
        guard !apiKey.isEmpty else { return false }
        guard let url = URL(string: "\(baseURL)/v1/models") else { return false }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    private struct APISegment: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    private struct APIResponse: Decodable {
        let text: String
        let language: String?
        let segments: [APISegment]?
    }

    private func parseResponse(_ data: Data) throws -> PluginTranscriptionResult {
        do {
            let response = try JSONDecoder().decode(APIResponse.self, from: data)
            let segments = (response.segments ?? []).map {
                PluginTranscriptionSegment(text: $0.text, start: $0.start, end: $0.end)
            }
            return PluginTranscriptionResult(text: response.text, detectedLanguage: response.language, segments: segments)
        } catch {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return PluginTranscriptionResult(text: text, detectedLanguage: json["language"] as? String)
            }
            throw PluginTranscriptionError.apiError("Failed to parse response: \(error.localizedDescription)")
        }
    }
}

// MARK: - OpenAI-Compatible Chat Completion Helper

public enum PluginChatError: LocalizedError, Sendable {
    case notConfigured
    case noModelSelected
    case invalidApiKey
    case rateLimited
    case apiError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "LLM provider not configured. Please set an API key."
        case .noModelSelected:
            "No LLM model selected."
        case .invalidApiKey:
            "Invalid API key. Please check your API key and try again."
        case .rateLimited:
            "Rate limit exceeded. Please wait and try again."
        case .apiError(let message):
            "API error: \(message)"
        case .networkError(let message):
            "Network error: \(message)"
        }
    }
}

public struct PluginOpenAIChatHelper: Sendable {
    public let baseURL: String
    public let chatEndpoint: String

    public init(baseURL: String, chatEndpoint: String = "/v1/chat/completions") {
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint
    }

    // Keep the pre-ac10ea9 symbol available so already-installed plugin bundles
    // continue to load after the helper grew token-parameter customization.
    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: 4096,
            maxOutputTokenParameter: "max_tokens"
        )
    }

    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int? = 4096,
        maxOutputTokenParameter: String = "max_tokens",
        reasoningEffort: String? = nil
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: reasoningEffort,
            temperature: 0.3
        )
    }

    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int? = 4096,
        maxOutputTokenParameter: String = "max_tokens",
        reasoningEffort: String? = nil,
        temperature: Double?
    ) async throws -> String {
        let endpoint = "\(baseURL)\(chatEndpoint)"
        guard let url = URL(string: endpoint) else {
            throw PluginChatError.apiError("Invalid URL: \(endpoint)")
        }

        let requestBody = requestBody(
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: reasoningEffort,
            temperature: temperature
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginChatError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw PluginChatError.invalidApiKey
        case 429:
            throw PluginChatError.rateLimited
        default:
            var displayMessage = "HTTP \(httpResponse.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                displayMessage = message
            }
            throw PluginChatError.apiError(displayMessage)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PluginChatError.apiError("Failed to parse response")
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int? = 4096,
        maxOutputTokenParameter: String = "max_tokens"
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: nil
        )
    }

    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int? = 4096,
        maxOutputTokenParameter: String = "max_tokens",
        temperature: Double?
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: nil,
            temperature: temperature
        )
    }

    func requestBody(
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int?,
        maxOutputTokenParameter: String,
        reasoningEffort: String?,
        temperature: Double?
    ) -> [String: Any] {
        var requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]

        if let temperature {
            requestBody["temperature"] = temperature
        }

        if let maxOutputTokens {
            requestBody[maxOutputTokenParameter] = maxOutputTokens
        }

        if let reasoningEffort, !reasoningEffort.isEmpty {
            requestBody["reasoning_effort"] = reasoningEffort
        }

        return requestBody
    }
}

private extension Data {
    mutating func appendFormField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
