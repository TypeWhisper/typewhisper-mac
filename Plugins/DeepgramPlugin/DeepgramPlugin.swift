import Foundation
import Security
import SwiftUI
import os
import TypeWhisperPluginSDK

// MARK: - Raw WebSocket Client (RFC 6455)
// Apple's URLSessionWebSocketTask and NWConnection+NWProtocolWebSocket negotiate HTTP/2
// via TLS ALPN, which is incompatible with Deepgram's server (advertises h2 but doesn't
// support RFC 8441 WebSocket-over-HTTP/2).
// This client uses URLSessionStreamTask for raw TCP+TLS (no ALPN negotiation)
// and performs a manual HTTP/1.1 WebSocket upgrade handshake + RFC 6455 frame encoding.

private final class RawWebSocket: @unchecked Sendable {
    enum WSError: Error, LocalizedError {
        case upgradeFailed(String)
        case closed

        var errorDescription: String? {
            switch self {
            case .upgradeFailed(let msg): return "WebSocket upgrade failed: \(msg)"
            case .closed: return "WebSocket closed"
            }
        }
    }

    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    struct Frame {
        let opcode: Opcode
        let payload: Data
    }

    private let streamTask: URLSessionStreamTask
    private let hostName: String
    private let path: String
    private let extraHeaders: [(String, String)]
    private let logger = Logger(subsystem: "com.typewhisper.deepgram", category: "WebSocket")

    private let buffer = OSAllocatedUnfairLock(initialState: Data())

    init(host: String, port: Int, usesTLS: Bool, path: String, headers: [(String, String)]) {
        self.hostName = host
        self.path = path
        self.extraHeaders = headers

        self.streamTask = URLSession.shared.streamTask(withHostName: host, port: port)
        if usesTLS {
            streamTask.startSecureConnection()
        }
    }

    // MARK: - Connect + Upgrade

    func connect() async throws {
        streamTask.resume()
        logger.info("Stream task started, performing WebSocket upgrade to \(self.hostName)")
        try await performUpgrade()
        logger.info("WebSocket upgrade successful")
    }

    private func performUpgrade() async throws {
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &keyBytes)
        let wsKey = Data(keyBytes).base64EncodedString()

        var request = "GET \(path) HTTP/1.1\r\n"
        request += "Host: \(hostName)\r\n"
        request += "Upgrade: websocket\r\n"
        request += "Connection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: \(wsKey)\r\n"
        request += "Sec-WebSocket-Version: 13\r\n"
        for (name, value) in extraHeaders {
            request += "\(name): \(value)\r\n"
        }
        request += "\r\n"

        logger.debug("Sending upgrade request")
        try await writeRaw(Data(request.utf8))

        let responseData = try await readUntilHeaderEnd()
        guard let responseStr = String(data: responseData, encoding: .utf8) else {
            throw WSError.upgradeFailed("Invalid response encoding")
        }
        logger.debug("Upgrade response: \(responseStr.prefix(200))")
        guard responseStr.contains("101") else {
            throw WSError.upgradeFailed(String(responseStr.prefix(200)))
        }
    }

    // MARK: - Raw I/O via URLSessionStreamTask

    private func writeRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            streamTask.write(data, timeout: 30) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    private func readRaw(maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            streamTask.readData(ofMinLength: 1, maxLength: maxLength, timeout: 60) { data, atEOF, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: WSError.closed)
                }
            }
        }
    }

    private func readUntilHeaderEnd() async throws -> Data {
        var accumulated = Data()
        let headerEnd = Data([0x0D, 0x0A, 0x0D, 0x0A])

        while true {
            let chunk = try await readRaw(maxLength: 4096)
            accumulated.append(chunk)
            if let range = accumulated.range(of: headerEnd) {
                let afterHeaders = Data(accumulated[range.upperBound...])
                if !afterHeaders.isEmpty {
                    buffer.withLock { $0.append(afterHeaders) }
                }
                return Data(accumulated[..<range.upperBound])
            }
            if accumulated.count > 65536 {
                throw WSError.upgradeFailed("Response headers too large")
            }
        }
    }

    private func readExact(count: Int) async throws -> Data {
        var result = buffer.withLock { buf -> Data in
            let available = min(count, buf.count)
            let data = Data(buf.prefix(available))
            buf.removeFirst(available)
            return data
        }

        while result.count < count {
            let needed = count - result.count
            let chunk = try await readRaw(maxLength: max(needed, 16384))
            if chunk.count <= needed {
                result.append(chunk)
            } else {
                result.append(chunk.prefix(needed))
                // Wrap in Data() to avoid Slice index issues
                buffer.withLock { $0 = Data(chunk.suffix(from: chunk.startIndex + needed)) }
            }
        }

        return result
    }

    // MARK: - Send WebSocket Frames (Client-Masked per RFC 6455)

    func sendText(_ text: String) async throws {
        try await sendFrame(opcode: .text, payload: Data(text.utf8))
    }

    func sendBinary(_ data: Data) async throws {
        try await sendFrame(opcode: .binary, payload: data)
    }

    func sendClose() async throws {
        // Close frame with status code 1000 (normal closure)
        var payload = Data()
        payload.append(0x03)
        payload.append(0xE8)
        try? await sendFrame(opcode: .close, payload: payload)
    }

    private func sendFrame(opcode: Opcode, payload: Data) async throws {
        var frame = Data()

        // FIN | opcode
        frame.append(0x80 | opcode.rawValue)

        // MASK | payload length
        let length = payload.count
        if length < 126 {
            frame.append(0x80 | UInt8(length))
        } else if length <= 65535 {
            frame.append(0x80 | 126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> shift) & 0xFF))
            }
        }

        // Random 4-byte masking key
        var maskKey = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &maskKey)
        frame.append(contentsOf: maskKey)

        // XOR payload with mask
        var masked = Data(capacity: length)
        for (i, byte) in payload.enumerated() {
            masked.append(byte ^ maskKey[i % 4])
        }
        frame.append(masked)

        try await writeRaw(frame)
    }

    // MARK: - Receive WebSocket Frames (Server-Unmasked)

    func receiveFrame() async throws -> Frame {
        let header = try await readExact(count: 2)
        let byte0 = header[0]
        let byte1 = header[1]

        let opcodeRaw = byte0 & 0x0F
        let isMasked = (byte1 & 0x80) != 0
        var payloadLength = UInt64(byte1 & 0x7F)

        if payloadLength == 126 {
            let ext = try await readExact(count: 2)
            payloadLength = UInt64(ext[0]) << 8 | UInt64(ext[1])
        } else if payloadLength == 127 {
            let ext = try await readExact(count: 8)
            payloadLength = 0
            for byte in ext { payloadLength = payloadLength << 8 | UInt64(byte) }
        }

        var maskKey: [UInt8]?
        if isMasked {
            let keyData = try await readExact(count: 4)
            maskKey = Array(keyData)
        }

        var payload = payloadLength > 0 ? try await readExact(count: Int(payloadLength)) : Data()
        if let mask = maskKey {
            for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
        }

        // Auto-reply to pings
        if opcodeRaw == Opcode.ping.rawValue {
            try await sendFrame(opcode: .pong, payload: payload)
            return try await receiveFrame()
        }

        let opcode = Opcode(rawValue: opcodeRaw) ?? .text
        return Frame(opcode: opcode, payload: payload)
    }

    func cancel() {
        streamTask.cancel()
    }
}

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

@objc(DeepgramPlugin)
final class DeepgramPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.deepgram"
    static let pluginName = "Deepgram"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _customBaseURL: String?
    fileprivate var _customAuthHeader: String?

    private static let defaultBaseURL = "https://api.deepgram.com"

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? transcriptionModels.first?.id
        _customBaseURL = host.userDefault(forKey: "customBaseURL") as? String
        _customAuthHeader = host.userDefault(forKey: "customAuthHeader") as? String
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "deepgram" }
    var providerDisplayName: String { "Deepgram" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "nova-3", displayName: "Nova-3"),
            PluginModelInfo(id: "nova-2", displayName: "Nova-2"),
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

    var supportedLanguages: [String] {
        [
            "bg", "ca", "cs", "da", "de", "de-CH", "el", "en", "en-AU", "en-GB",
            "en-IN", "en-NZ", "en-US", "es", "es-419", "et", "fi", "fr", "fr-CA",
            "hi", "hu", "id", "it", "ja", "ko", "lt", "lv", "ms", "nl", "nl-BE",
            "no", "pl", "pt", "pt-BR", "ro", "ru", "sk", "sv", "th", "tr",
            "uk", "vi", "zh", "zh-CN", "zh-TW",
        ]
    }

    // MARK: - URL Helpers

    private var effectiveBaseURL: String {
        if let custom = _customBaseURL, !custom.isEmpty {
            var url = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            while url.hasSuffix("/") { url = String(url.dropLast()) }
            return url
        }
        return Self.defaultBaseURL
    }

    private var effectiveWSBaseURL: String {
        effectiveBaseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
    }

    private var effectiveAuthHeader: String {
        if let custom = _customAuthHeader, !custom.isEmpty {
            return custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Authorization"
    }

    private func authHeaderValue(apiKey: String) -> String {
        if effectiveAuthHeader == "Authorization" {
            return "Token \(apiKey)"
        }
        return apiKey
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
            // Fallback to REST on WebSocket failure
            return try await transcribeREST(
                audio: audio,
                language: language,
                modelId: modelId,
                apiKey: apiKey,
                prompt: prompt
            )
        }
    }

    // MARK: - REST Implementation

    private func transcribeREST(
        audio: AudioData,
        language: String?,
        modelId: String,
        apiKey: String,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        var components = URLComponents(string: "\(effectiveBaseURL)/v1/listen")!
        var queryItems = [
            URLQueryItem(name: "model", value: modelId),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]
        if let lang = language, !lang.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: lang))
        }
        queryItems.append(contentsOf: Self.dictionaryQueryItems(prompt: prompt, modelId: modelId))
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(authHeaderValue(apiKey: apiKey), forHTTPHeaderField: effectiveAuthHeader)
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio.wavData
        request.timeoutInterval = 60

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
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let transcript = Self.extractTranscript(from: json)

        return PluginTranscriptionResult(text: transcript, detectedLanguage: language)
    }

    // MARK: - WebSocket Implementation (Raw RFC 6455)

    private func transcribeWebSocket(
        audio: AudioData,
        language: String?,
        modelId: String,
        prompt: String?,
        apiKey: String,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        // Build query string for path
        var queryItems = [
            URLQueryItem(name: "model", value: modelId),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: "300"),
        ]
        if let lang = language, !lang.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: lang))
        } else {
            queryItems.append(URLQueryItem(name: "detect_language", value: "true"))
        }
        queryItems.append(contentsOf: Self.dictionaryQueryItems(prompt: prompt, modelId: modelId))

        let baseURL = effectiveBaseURL
        guard let urlComponents = URLComponents(string: baseURL),
              let host = urlComponents.host else {
            throw PluginTranscriptionError.apiError("Invalid base URL")
        }
        let usesTLS = baseURL.hasPrefix("https://")
        let port = urlComponents.port ?? (usesTLS ? 443 : 80)

        // Build the path+query for the HTTP upgrade request
        var pathComponents = URLComponents()
        pathComponents.path = "/v1/listen"
        pathComponents.queryItems = queryItems
        guard let pathWithQuery = pathComponents.string else {
            throw PluginTranscriptionError.apiError("Invalid query parameters")
        }

        let ws = RawWebSocket(
            host: host,
            port: port,
            usesTLS: usesTLS,
            path: pathWithQuery,
            headers: [(effectiveAuthHeader, authHeaderValue(apiKey: apiKey))]
        )

        try await ws.connect()

        let collector = TranscriptCollector()
        let chunkSize = 8192
        let pcmData = Self.floatToPCM16(audio.samples)

        // Receive loop in background
        let receiveTask = Task {
            do {
                while !Task.isCancelled {
                    let frame = try await ws.receiveFrame()

                    if frame.opcode == .close { break }
                    guard frame.opcode == .text else { continue }

                    guard let json = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else {
                        continue
                    }

                    if let type = json["type"] as? String {
                        if type == "Error" { break }
                        if type != "Results" { continue }
                    }

                    let transcript = Self.extractWSTranscript(from: json)
                    let isFinal = Self.isFinalResult(json)

                    if isFinal {
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
                // Connection closed or error - stop receiving
            }
        }

        // Send audio in chunks as binary frames
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            try await ws.sendBinary(chunk)
            offset = end
        }

        // Signal end of audio
        try await ws.sendText("{\"type\":\"CloseStream\"}")

        // Wait for server to finish sending results
        _ = await receiveTask.result

        // Graceful close
        try await ws.sendClose()
        ws.cancel()

        let finalText = await collector.finalResult()
        return PluginTranscriptionResult(text: finalText, detectedLanguage: language)
    }

    private static func dictionaryQueryItems(prompt: String?, modelId: String) -> [URLQueryItem] {
        let terms = PluginDictionaryTerms.terms(fromPrompt: prompt)
        guard !terms.isEmpty else { return [] }

        let parameterName = modelId.lowercased().hasPrefix("nova-3") ? "keyterm" : "keywords"
        return terms.map { URLQueryItem(name: parameterName, value: $0) }
    }

    // MARK: - JSON Parsing Helpers

    fileprivate static func extractTranscript(from json: [String: Any]?) -> String {
        guard let json,
              let results = json["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let firstChannel = channels.first,
              let alternatives = firstChannel["alternatives"] as? [[String: Any]],
              let firstAlt = alternatives.first,
              let transcript = firstAlt["transcript"] as? String else {
            return ""
        }
        return transcript
    }

    // WebSocket responses have different structure: channel.alternatives[0].transcript
    fileprivate static func extractWSTranscript(from json: [String: Any]?) -> String {
        guard let json,
              let channel = json["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let firstAlt = alternatives.first,
              let transcript = firstAlt["transcript"] as? String else {
            return ""
        }
        return transcript
    }

    fileprivate static func isFinalResult(_ json: [String: Any]?) -> Bool {
        guard let json else { return false }
        return json["is_final"] as? Bool ?? false
    }

    // MARK: - Audio Conversion

    fileprivate static func floatToPCM16(_ samples: [Float]) -> Data {
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
        guard let url = URL(string: "\(effectiveBaseURL)/v1/projects") else { return false }
        var request = URLRequest(url: url)
        request.setValue(authHeaderValue(apiKey: key), forHTTPHeaderField: effectiveAuthHeader)
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
        AnyView(DeepgramSettingsView(plugin: self))
    }

    // MARK: - Internal Methods for Settings

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[DeepgramPlugin] Failed to store API key: \(error)")
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
                print("[DeepgramPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func setCustomBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        _customBaseURL = trimmed.isEmpty ? nil : trimmed
        host?.setUserDefault(trimmed.isEmpty ? nil : trimmed, forKey: "customBaseURL")
    }

    fileprivate func setCustomAuthHeader(_ header: String) {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        _customAuthHeader = trimmed.isEmpty ? nil : trimmed
        host?.setUserDefault(trimmed.isEmpty ? nil : trimmed, forKey: "customAuthHeader")
    }
}

// MARK: - Settings View

private struct DeepgramSettingsView: View {
    let plugin: DeepgramPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var showAdvanced = false
    @State private var customBaseURL = ""
    @State private var customAuthHeader = ""
    private let bundle = Bundle(for: DeepgramPlugin.self)

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

            Divider()

            // Advanced Section
            DisclosureGroup(String(localized: "Advanced", bundle: bundle), isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom Base URL", bundle: bundle)
                            .font(.subheadline)

                        TextField("https://api.deepgram.com", text: $customBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: customBaseURL) {
                                plugin.setCustomBaseURL(customBaseURL)
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom Auth Header", bundle: bundle)
                            .font(.subheadline)

                        TextField("Authorization", text: $customAuthHeader)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: customAuthHeader) {
                                plugin.setCustomAuthHeader(customAuthHeader)
                            }
                    }

                    Text("For Cloudflare AI Gateway or custom proxies", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
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
            customBaseURL = plugin._customBaseURL ?? ""
            customAuthHeader = plugin._customAuthHeader ?? ""
            showAdvanced = !customBaseURL.isEmpty || !customAuthHeader.isEmpty
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
