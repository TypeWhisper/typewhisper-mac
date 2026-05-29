import Foundation
import Security
import SwiftUI
import os
import TypeWhisperPluginSDK

// MARK: - Raw WebSocket Client (RFC 6455)
// Apple's URLSessionWebSocketTask and NWConnection+NWProtocolWebSocket negotiate HTTP/2
// via TLS ALPN, which is incompatible with edges that advertise h2 but don't
// support RFC 8441 WebSocket-over-HTTP/2.
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
    private let logger = Logger(subsystem: "com.typewhisper.reson8", category: "WebSocket")

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
        var payload = Data()
        payload.append(0x03)
        payload.append(0xE8)
        try? await sendFrame(opcode: .close, payload: payload)
    }

    private func sendFrame(opcode: Opcode, payload: Data) async throws {
        var frame = Data()

        frame.append(0x80 | opcode.rawValue)

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

        var maskKey = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &maskKey)
        frame.append(contentsOf: maskKey)

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

// MARK: - Custom Model

struct Reson8CustomModel: Codable, Sendable {
    let id: String
    let name: String
    let description: String?
    let phraseCount: Int?
}

// MARK: - Plugin Entry Point

@objc(Reson8Plugin)
final class Reson8Plugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.reson8"
    static let pluginName = "Reson8"
    private static let logger = Logger(subsystem: "com.typewhisper.reson8", category: "Plugin")
    fileprivate static let defaultModelSentinel = "__default__"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _customBaseURL: String?
    fileprivate var _customAuthHeader: String?
    fileprivate var _fetchedCustomModels: [Reson8CustomModel] = []

    private static let defaultBaseURL = "https://api.reson8.dev"

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? Self.defaultModelSentinel
        _customBaseURL = host.userDefault(forKey: "customBaseURL") as? String
        _customAuthHeader = host.userDefault(forKey: "customAuthHeader") as? String
        if let data = host.userDefault(forKey: "fetchedCustomModels") as? Data,
           let models = try? JSONDecoder().decode([Reson8CustomModel].self, from: data) {
            _fetchedCustomModels = models
        }
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "reson8" }
    var providerDisplayName: String { "Reson8" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        var list: [PluginModelInfo] = [
            PluginModelInfo(id: Self.defaultModelSentinel, displayName: "Default model")
        ]
        list.append(contentsOf: _fetchedCustomModels.map {
            PluginModelInfo(id: $0.id, displayName: $0.name)
        })
        return list
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }

    var supportedLanguages: [String] {
        ["nl", "en", "fr", "de", "it", "pl", "pt", "es", "sv"]
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

    private var effectiveAuthHeader: String {
        if let custom = _customAuthHeader, !custom.isEmpty {
            return custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Authorization"
    }

    private func authHeaderValue(apiKey: String) -> String {
        if effectiveAuthHeader == "Authorization" {
            return "ApiKey \(apiKey)"
        }
        return apiKey
    }

    private func customModelQueryItem() -> URLQueryItem? {
        guard let modelId = _selectedModelId,
              modelId != Self.defaultModelSentinel,
              !modelId.isEmpty else {
            return nil
        }
        return URLQueryItem(name: "custom_model_id", value: modelId)
    }

    // MARK: - Transcription (single language)

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        try await transcribe(
            audio: audio,
            languageSelection: PluginLanguageSelection(requestedLanguage: language, languageHints: []),
            translate: translate,
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
        try await transcribe(
            audio: audio,
            languageSelection: PluginLanguageSelection(requestedLanguage: language, languageHints: []),
            translate: translate,
            prompt: prompt,
            onProgress: onProgress
        )
    }

    // MARK: - Transcription (selection helper)

    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        let resolved = Self.resolveLanguage(selection: languageSelection)
        return try await transcribeREST(
            audio: audio,
            language: resolved,
            apiKey: apiKey
        )
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
        let resolved = Self.resolveLanguage(selection: languageSelection)

        do {
            return try await transcribeWebSocket(
                audio: audio,
                language: resolved,
                apiKey: apiKey,
                onProgress: onProgress
            )
        } catch {
            Self.logger.warning("Realtime transcription failed, falling back to REST: \(error.localizedDescription)")
            return try await transcribeREST(
                audio: audio,
                language: resolved,
                apiKey: apiKey
            )
        }
    }

    /// Reson8 accepts one language query parameter, not an ordered hint list.
    /// If multiple hints reach this helper, keep #627 semantics by using the first.
    static func resolveLanguage(selection: PluginLanguageSelection) -> String? {
        if let req = selection.requestedLanguage, !req.isEmpty {
            return req
        }
        return selection.languageHints.first.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - REST Implementation

    private func transcribeREST(
        audio: AudioData,
        language: String?,
        apiKey: String
    ) async throws -> PluginTranscriptionResult {
        guard var components = URLComponents(string: "\(effectiveBaseURL)/v1/speech-to-text/prerecorded") else {
            throw PluginTranscriptionError.apiError("Invalid base URL: \(effectiveBaseURL)")
        }
        var queryItems = [
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
        ]
        if let lang = language, !lang.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: lang))
        }
        if let modelItem = customModelQueryItem() {
            queryItems.append(modelItem)
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw PluginTranscriptionError.apiError("Failed to construct request URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authHeaderValue(apiKey: apiKey), forHTTPHeaderField: effectiveAuthHeader)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.floatToPCM16(audio.samples)
        request.timeoutInterval = 60

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 400: throw PluginTranscriptionError.apiError("Invalid request: \(Self.errorMessage(from: data))")
        case 401: throw PluginTranscriptionError.invalidApiKey
        case 404: throw PluginTranscriptionError.apiError("Custom model not found: \(Self.errorMessage(from: data))")
        case 413: throw PluginTranscriptionError.fileTooLarge
        case 429: throw PluginTranscriptionError.rateLimited
        case 500: throw PluginTranscriptionError.apiError("Reson8 server error: \(Self.errorMessage(from: data))")
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (json?["text"] as? String) ?? ""
        return PluginTranscriptionResult(text: text, detectedLanguage: language)
    }

    // MARK: - WebSocket Implementation (Raw RFC 6455)

    private func transcribeWebSocket(
        audio: AudioData,
        language: String?,
        apiKey: String,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        var queryItems = [
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "include_interim", value: "true"),
        ]
        if let lang = language, !lang.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: lang))
        }
        if let modelItem = customModelQueryItem() {
            queryItems.append(modelItem)
        }

        let baseURL = effectiveBaseURL
        guard let urlComponents = URLComponents(string: baseURL),
              let host = urlComponents.host else {
            throw PluginTranscriptionError.apiError("Invalid base URL")
        }
        let usesTLS = baseURL.hasPrefix("https://")
        let port = urlComponents.port ?? (usesTLS ? 443 : 80)

        var pathComponents = URLComponents()
        pathComponents.path = "/v1/speech-to-text/realtime"
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

        let receiveTask = Task {
            do {
                while !Task.isCancelled {
                    let frame = try await ws.receiveFrame()

                    if frame.opcode == .close { break }
                    guard frame.opcode == .text else { continue }

                    guard let json = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                          let type = json["type"] as? String else {
                        continue
                    }

                    if type == "flush_confirmation" { break }
                    if type.localizedCaseInsensitiveContains("error") {
                        Self.logger.warning("Reson8 realtime error: \(Self.errorMessage(from: frame.payload))")
                        break
                    }
                    guard type == "transcript" else { continue }

                    let transcript = (json["text"] as? String) ?? ""
                    let isFinal = (json["is_final"] as? Bool) ?? false

                    if isFinal {
                        await collector.addFinal(transcript)
                    } else {
                        await collector.setInterim(transcript)
                    }

                    let currentText = await collector.currentText()
                    if !currentText.isEmpty {
                        if !onProgress(currentText) { break }
                    }
                }
            } catch {
                // Connection closed or error - stop receiving
            }
        }

        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            try await ws.sendBinary(chunk)
            offset = end
        }

        let flushId = UUID().uuidString
        try await ws.sendText("{\"type\":\"flush_request\",\"id\":\"\(flushId)\"}")

        _ = await receiveTask.result

        try await ws.sendClose()
        ws.cancel()

        let finalText = await collector.finalResult()
        return PluginTranscriptionResult(text: finalText, detectedLanguage: language)
    }

    // MARK: - JSON Error Body Helper

    fileprivate static func errorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        if let code = json["code"] as? String,
           let message = json["message"] as? String {
            return "\(code): \(message)"
        }
        if let message = json["message"] as? String { return message }
        if let error = json["error"] as? String { return error }
        if let detail = json["detail"] as? String { return detail }
        return ""
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
        guard let url = URL(string: "\(effectiveBaseURL)/v1/speech-to-text/prerecorded") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authHeaderValue(apiKey: key), forHTTPHeaderField: effectiveAuthHeader)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data()
        request.timeoutInterval = 10

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            // 400 INVALID_REQUEST for an authenticated but empty-body request,
            // 401 UNAUTHORIZED for an invalid key.
            return httpResponse.statusCode != 401
        } catch {
            return false
        }
    }

    // MARK: - Custom Models

    fileprivate func fetchCustomModels() async -> [Reson8CustomModel] {
        guard let apiKey = _apiKey, !apiKey.isEmpty,
              let url = URL(string: "\(effectiveBaseURL)/v1/custom-model") else {
            return []
        }
        var request = URLRequest(url: url)
        request.setValue(authHeaderValue(apiKey: apiKey), forHTTPHeaderField: effectiveAuthHeader)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            return (try? JSONDecoder().decode([Reson8CustomModel].self, from: data)) ?? []
        } catch {
            return []
        }
    }

    fileprivate func setFetchedCustomModels(_ models: [Reson8CustomModel]) {
        _fetchedCustomModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: "fetchedCustomModels")
        }
        host?.notifyCapabilitiesChanged()
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(Reson8SettingsView(plugin: self))
    }

    // MARK: - Internal Methods for Settings

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[Reson8Plugin] Failed to store API key: \(error)")
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
                print("[Reson8Plugin] Failed to delete API key: \(error)")
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

private struct Reson8SettingsView: View {
    let plugin: Reson8Plugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var showAdvanced = false
    @State private var customBaseURL = ""
    @State private var customAuthHeader = ""
    @State private var fetchedCustomModels: [Reson8CustomModel] = []
    @State private var isRefreshingModels = false
    private let bundle = Bundle(for: Reson8Plugin.self)

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
                            fetchedCustomModels = []
                            plugin.setFetchedCustomModels([])
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
                    HStack {
                        Text("Model", bundle: bundle)
                            .font(.headline)

                        Spacer()

                        Button {
                            refreshCustomModels()
                        } label: {
                            if isRefreshingModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(String(localized: "Refresh", bundle: bundle), systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRefreshingModels)
                    }

                    Picker("Model", selection: $selectedModel) {
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectModel(selectedModel)
                    }

                    if fetchedCustomModels.isEmpty {
                        Text("No custom models yet — using default model", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

                        TextField("https://api.reson8.dev", text: $customBaseURL)
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

                    Text("For LiveKit gateway or custom proxies", bundle: bundle)
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
            selectedModel = plugin.selectedModelId ?? Reson8Plugin.defaultModelSentinel
            customBaseURL = plugin._customBaseURL ?? ""
            customAuthHeader = plugin._customAuthHeader ?? ""
            showAdvanced = !customBaseURL.isEmpty || !customAuthHeader.isEmpty
            fetchedCustomModels = plugin._fetchedCustomModels
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
            if isValid {
                let models = await plugin.fetchCustomModels()
                await MainActor.run {
                    isValidating = false
                    validationResult = true
                    fetchedCustomModels = models
                    plugin.setFetchedCustomModels(models)
                }
            } else {
                await MainActor.run {
                    isValidating = false
                    validationResult = false
                }
            }
        }
    }

    private func refreshCustomModels() {
        isRefreshingModels = true
        Task {
            let models = await plugin.fetchCustomModels()
            await MainActor.run {
                isRefreshingModels = false
                fetchedCustomModels = models
                plugin.setFetchedCustomModels(models)
                if !models.contains(where: { $0.id == selectedModel }),
                   selectedModel != Reson8Plugin.defaultModelSentinel {
                    selectedModel = Reson8Plugin.defaultModelSentinel
                    plugin.selectModel(Reson8Plugin.defaultModelSentinel)
                }
            }
        }
    }
}
