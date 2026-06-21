import AVFoundation
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

    // Available user workflows
    var availableWorkflows: [PluginWorkflowInfo] { get }

    // Notify host that plugin capabilities changed (e.g. model loaded/unloaded)
    func notifyCapabilitiesChanged()

    // Streaming display: call with true when the plugin provides its own streaming text UI,
    // so the built-in indicator suppresses its streaming text display.
    func setStreamingDisplayActive(_ active: Bool)
}

public extension HostServices {
    var availableWorkflows: [PluginWorkflowInfo] { [] }

    @available(*, deprecated, renamed: "availableRuleNames")
    var availableProfileNames: [String] { availableRuleNames }
}

// MARK: - HTTP Client (Reusable Ephemeral Session)

@_spi(Testing) public protocol PluginHTTPClientSession: AnyObject {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func finishTasksAndInvalidate()
}

@_spi(Testing) extension URLSession: PluginHTTPClientSession {}

/// Drop-in replacement for `URLSession.shared.data(for:)` that reuses one ephemeral
/// session so fast plugin requests can keep DNS/TLS/HTTP connections warm.
public enum PluginHTTPClient {
    private static let logger = Logger(subsystem: "com.typewhisper.sdk", category: "HTTP")
    private static let defaultRequestTimeout: TimeInterval = 30
    private static let longRunningResourceTimeout: TimeInterval = 600
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sharedSession: (any PluginHTTPClientSession)?
    nonisolated(unsafe) private static var sessionFactory: (URLSessionConfiguration) -> any PluginHTTPClientSession = {
        URLSession(configuration: $0)
    }

    public static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, allowsRetry: true)
    }

    public static func data(
        for request: URLRequest,
        resourceTimeout: TimeInterval?
    ) async throws -> (Data, URLResponse) {
        guard let resourceTimeout, resourceTimeout > longRunningResourceTimeout else {
            return try await data(for: request, allowsRetry: true)
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = resourceTimeout
        config.timeoutIntervalForResource = resourceTimeout
        let session = sessionFactory(config)
        defer { session.finishTasksAndInvalidate() }

        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "unknown"
        logger.info("\(method) \(url) (dedicated session, resourceTimeout=\(resourceTimeout))")
        return try await session.data(for: request)
    }

    public static func resetSharedSession(reason: String? = nil) {
        let session = lock.withLock {
            let existing = sharedSession
            sharedSession = nil
            return existing
        }

        session?.finishTasksAndInvalidate()
        if let reason {
            logger.info("Reset shared plugin HTTP session: \(reason)")
        } else {
            logger.info("Reset shared plugin HTTP session")
        }
    }

    @_spi(Testing) public static func configureForTesting(
        _ factory: @escaping (URLSessionConfiguration) -> any PluginHTTPClientSession
    ) {
        resetSharedSession(reason: "test reconfiguration")
        lock.withLock {
            sessionFactory = factory
        }
    }

    @_spi(Testing) public static func resetTestingHooks() {
        resetSharedSession(reason: "test cleanup")
        lock.withLock {
            sessionFactory = { URLSession(configuration: $0) }
        }
    }

    private static func data(
        for request: URLRequest,
        allowsRetry: Bool
    ) async throws -> (Data, URLResponse) {
        let session = sharedOrCreateSession()
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
            if allowsRetry, isTransientNetworkError(error) {
                logger.warning("\(method) \(url) transient failure after \(elapsed), resetting session and retrying once: \(error.localizedDescription)")
                resetSharedSession(matching: session, reason: "transient network error")
                return try await data(for: request, allowsRetry: false)
            }

            logger.error("\(method) \(url) failed after \(elapsed): \(error.localizedDescription)")
            throw error
        }
    }

    private static func sharedOrCreateSession() -> any PluginHTTPClientSession {
        lock.withLock {
            if let sharedSession {
                return sharedSession
            }

            let session = sessionFactory(makeConfiguration())
            sharedSession = session
            return session
        }
    }

    private static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = defaultRequestTimeout
        config.timeoutIntervalForResource = longRunningResourceTimeout
        return config
    }

    private static func resetSharedSession(matching session: any PluginHTTPClientSession, reason: String) {
        let didRemoveSharedSession = lock.withLock {
            guard let current = sharedSession, current === session else {
                return false
            }
            sharedSession = nil
            return true
        }

        session.finishTasksAndInvalidate()
        if didRemoveSharedSession {
            logger.info("Reset shared plugin HTTP session: \(reason)")
        } else {
            logger.info("Invalidated plugin HTTP session after \(reason)")
        }
    }

    private static func isTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .networkConnectionLost,
             .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet:
            return true
        default:
            return false
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
    private static let defaultRequestTimeout: TimeInterval = 30
    static let minimumUploadDuration: TimeInterval = 1.0
    static let uploadSampleRate = 16000
    private static let compressedUploadChunkFrames = 16_000 * 30

    private struct UploadFile {
        let data: Data
        let filename: String
        let contentType: String
    }

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
        try await performTranscribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            responseFormat: responseFormat,
            requestTimeout: Self.defaultRequestTimeout
        )
    }

    public func transcribe(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        requestTimeout: TimeInterval,
        responseFormat: String? = nil
    ) async throws -> PluginTranscriptionResult {
        try await performTranscribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            responseFormat: responseFormat,
            requestTimeout: requestTimeout
        )
    }

    public func transcribeCompressedAudio(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        requestTimeout: TimeInterval,
        responseFormat: String? = nil
    ) async throws -> PluginTranscriptionResult {
        let uploadAudio = normalizedAudioForUpload(audio)
        let compressedData: Data
        do {
            compressedData = try Self.makeCompressedM4AData(from: uploadAudio.samples)
        } catch {
            throw PluginTranscriptionError.apiError(
                "Failed to encode compressed upload: \(error.localizedDescription)"
            )
        }

        return try await performTranscribe(
            audio: uploadAudio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            responseFormat: responseFormat,
            requestTimeout: requestTimeout,
            uploadFile: UploadFile(
                data: compressedData,
                filename: "audio.m4a",
                contentType: "audio/mp4"
            )
        )
    }

    private func performTranscribe(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        responseFormat: String?,
        requestTimeout: TimeInterval,
        uploadFile: UploadFile? = nil
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
        request.timeoutInterval = requestTimeout

        let uploadAudio = uploadFile == nil ? normalizedAudioForUpload(audio) : audio
        let uploadFile = uploadFile ?? UploadFile(
            data: uploadAudio.wavData,
            filename: "audio.wav",
            contentType: "audio/wav"
        )
        var body = Data()

        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(uploadFile.filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(uploadFile.contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(uploadFile.data)
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

    private static func makeCompressedM4AData(from samples: [Float]) throws -> Data {
        guard !samples.isEmpty else {
            throw PluginTranscriptionError.apiError("Cannot encode empty audio upload")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typewhisper-upload-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(uploadSampleRate),
            AVNumberOfChannelsKey: 1,
        ]
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(uploadSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw PluginTranscriptionError.apiError("Failed to create compressed upload format")
        }

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            var offset = 0
            while offset < samples.count {
                let count = min(compressedUploadChunkFrames, samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(count)
                ) else {
                    throw PluginTranscriptionError.apiError("Failed to create compressed upload buffer")
                }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { pointer in
                    buffer.floatChannelData?[0].update(from: pointer.baseAddress! + offset, count: count)
                }
                try file.write(from: buffer)
                offset += count
            }
        }

        return try Data(contentsOf: url)
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

    // Keep the pre-requestTimeout symbols available so already-installed plugin
    // bundles continue to load after the helper grew the timeout parameter.
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
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: reasoningEffort,
            temperature: temperature,
            requestTimeout: 30
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
        temperature: Double?,
        requestTimeout: TimeInterval
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: reasoningEffort,
            temperature: temperature,
            requestTimeout: requestTimeout,
            thinkingEnabled: nil
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
        temperature: Double?,
        requestTimeout: TimeInterval,
        thinkingEnabled: Bool?
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
            temperature: temperature,
            thinkingEnabled: thinkingEnabled
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await PluginHTTPClient.data(for: request, resourceTimeout: requestTimeout)

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
            throw PluginChatError.apiError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
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
            temperature: temperature,
            requestTimeout: 30
        )
    }

    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int? = 4096,
        maxOutputTokenParameter: String = "max_tokens",
        temperature: Double?,
        requestTimeout: TimeInterval
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: nil,
            temperature: temperature,
            requestTimeout: requestTimeout
        )
    }

    /// Extracts a human-readable error message from an OpenAI-compatible error body,
    /// falling back to `HTTP <status>` when no message can be found.
    ///
    /// Most providers return `{"error": {"message": ...}}`, but some (notably
    /// Google's Gemini OpenAI-compat endpoint) wrap the error in a top-level JSON
    /// array: `[{"error": {"message": ...}}]`. Both shapes are handled here so the
    /// descriptive message survives instead of being collapsed to `HTTP 404`.
    static func errorMessage(from data: Data, statusCode: Int) -> String {
        let json = try? JSONSerialization.jsonObject(with: data)

        let object: [String: Any]?
        if let dictionary = json as? [String: Any] {
            object = dictionary
        } else if let array = json as? [Any],
                  let first = array.first as? [String: Any] {
            object = first
        } else {
            object = nil
        }

        if let object, let message = message(fromErrorObject: object) {
            return message
        }
        return "HTTP \(statusCode)"
    }

    /// Extracts a message from a single error object following the precedence used
    /// across providers: top-level `detail`, then nested `error.message`, then a
    /// top-level `message`.
    private static func message(fromErrorObject object: [String: Any]) -> String? {
        if let detail = object["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
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
        requestBody(
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: reasoningEffort,
            temperature: temperature,
            thinkingEnabled: nil
        )
    }

    func requestBody(
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int?,
        maxOutputTokenParameter: String,
        reasoningEffort: String?,
        temperature: Double?,
        thinkingEnabled: Bool?
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

        if let thinkingEnabled {
            requestBody["thinking"] = [
                "type": thinkingEnabled ? "enabled" : "disabled"
            ]
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
