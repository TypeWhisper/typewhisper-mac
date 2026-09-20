import Foundation
import Network
import SwiftUI
import os
import TypeWhisperPluginSDK

// MARK: - Server Protocol

/// Wire protocol of the audio.cpp `audiocpp_server` live transcription route, used to run the
/// Confucius4-R2T2 GGUF on-device with Metal.
///
/// `POST /v1/audio/transcriptions/live?model=<id>&sample_rate=16000&channels=1&sample_format=s16le[&language=X]`
/// with a `Transfer-Encoding: chunked` body of raw PCM16LE. The response is a chunked
/// `text/event-stream` on the same connection, delivered while audio is still being sent:
/// `data: {"type":"transcript.text.delta","delta":"..."}` (append-only),
/// `data: {"type":"transcript.text.done","text":"<full transcript>"}`,
/// `data: {"type":"error","error":{"message":"..."}}`, then `data: [DONE]`.
enum R2T2Protocol {
    static let defaultServerURL = "http://127.0.0.1:8488"
    static let defaultModelId = "r2t2"
    static let sampleRate = 16_000

    enum ServerEvent: Equatable {
        case delta(String)
        case done(String)
        case error(String)
        case finished
    }

    /// ISO 639-1 code → canonical language name understood by the Qwen3-ASR / R2T2 prompt.
    static let languageNames: [String: String] = [
        "zh": "Chinese", "en": "English", "yue": "Cantonese", "ar": "Arabic", "de": "German",
        "fr": "French", "es": "Spanish", "pt": "Portuguese", "id": "Indonesian", "it": "Italian",
        "ko": "Korean", "ru": "Russian", "th": "Thai", "vi": "Vietnamese", "ja": "Japanese",
        "tr": "Turkish", "hi": "Hindi", "ms": "Malay", "nl": "Dutch", "sv": "Swedish",
        "da": "Danish", "fi": "Finnish", "pl": "Polish", "cs": "Czech", "fil": "Filipino",
        "tl": "Filipino", "fa": "Persian", "el": "Greek", "ro": "Romanian", "hu": "Hungarian",
        "mk": "Macedonian", "no": "Norwegian", "nb": "Norwegian", "uk": "Ukrainian",
    ]

    /// Returns the canonical language name, or nil to let the model detect the language.
    static func languageName(for code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !code.isEmpty else {
            return nil
        }
        if let name = languageNames[code] { return name }
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return languageNames[base]
    }

    static func normalizedServerURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") { trimmed = "http://" + trimmed }
        guard let components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else {
            return nil
        }
        return components.url
    }

    /// Joins TypeWhisper dictionary terms into the comma-separated hotword context R2T2 expects.
    static func contextPrompt(from prompt: String?) -> String? {
        let terms = PluginDictionaryTerms.terms(fromPrompt: prompt)
        return terms.isEmpty ? nil : terms.joined(separator: ", ")
    }

    static func livePath(modelId: String, language: String?, prompt: String? = nil) -> String {
        var items = [
            URLQueryItem(name: "model", value: modelId),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "sample_format", value: "s16le"),
        ]
        if let language { items.append(URLQueryItem(name: "language", value: language)) }
        if let prompt, !prompt.isEmpty { items.append(URLQueryItem(name: "prompt", value: prompt)) }
        var components = URLComponents()
        components.path = "/v1/audio/transcriptions/live"
        components.queryItems = items
        return components.string ?? "/v1/audio/transcriptions/live"
    }

    static func makeLiveRequestHead(serverURL: URL, modelId: String, language: String?, prompt: String? = nil) -> Data {
        let hostHeader = serverURL.port.map { "\(serverURL.host ?? ""):\($0)" } ?? (serverURL.host ?? "")
        let head = [
            "POST \(livePath(modelId: modelId, language: language, prompt: prompt)) HTTP/1.1",
            "Host: \(hostHeader)",
            "Content-Type: application/octet-stream",
            "Transfer-Encoding: chunked",
            "Accept: text/event-stream",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(head.utf8)
    }

    static func chunkFrame(_ payload: Data) -> Data {
        var frame = Data(String(payload.count, radix: 16).utf8)
        frame.append(contentsOf: [0x0D, 0x0A])
        frame.append(payload)
        frame.append(contentsOf: [0x0D, 0x0A])
        return frame
    }

    static let terminatingChunk = Data("0\r\n\r\n".utf8)

    static func makePCM16LEData(samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func parseSSEData(_ payload: String) -> ServerEvent? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" { return .finished }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any] {
            return .error(error["message"] as? String ?? "Unknown server error")
        }
        switch json["type"] as? String {
        case "transcript.text.delta":
            return .delta(json["delta"] as? String ?? "")
        case "transcript.text.done":
            return .done(json["text"] as? String ?? "")
        case "error":
            return .error(json["message"] as? String ?? "Unknown server error")
        default:
            return nil
        }
    }
}

// MARK: - HTTP/SSE Response Parser

/// Incrementally parses the raw bytes of the live route's HTTP/1.1 response: status line and
/// headers, optional chunked transfer framing, then `data:` SSE events.
struct R2T2ResponseParser {
    private enum Phase {
        case head
        case body
        case failedBody(status: Int)
    }

    private var phase = Phase.head
    private var buffer = Data()
    private var isChunked = false
    private var eventText = ""
    private(set) var statusCode: Int?

    mutating func feed(_ data: Data) -> [R2T2Protocol.ServerEvent] {
        buffer.append(data)
        var events: [R2T2Protocol.ServerEvent] = []

        if case .head = phase {
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return [] }
            let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
            buffer.removeSubrange(..<headEnd.upperBound)
            let lines = head.components(separatedBy: "\r\n")
            let statusParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
            let status = statusParts.count > 1 ? Int(statusParts[1]) ?? 0 : 0
            statusCode = status
            isChunked = lines.dropFirst().contains { line in
                let lower = line.lowercased()
                return lower.hasPrefix("transfer-encoding:") && lower.contains("chunked")
            }
            phase = status == 200 ? .body : .failedBody(status: status)
        }

        let decoded = isChunked ? dechunk() : consumeAll()
        guard !decoded.isEmpty else { return events }

        switch phase {
        case .body:
            eventText += String(decoding: decoded, as: UTF8.self)
            while let separator = eventText.range(of: "\n\n") {
                let block = String(eventText[..<separator.lowerBound])
                eventText.removeSubrange(..<separator.upperBound)
                let payload = block
                    .components(separatedBy: "\n")
                    .filter { $0.hasPrefix("data:") }
                    .map { String($0.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n")
                if !payload.isEmpty, let event = R2T2Protocol.parseSSEData(payload) {
                    events.append(event)
                }
            }
        case .failedBody(let status):
            let body = String(decoding: decoded, as: UTF8.self)
            let message = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            events.append(.error("HTTP \(status): \(message ?? body)"))
            phase = .body
        case .head:
            break
        }
        return events
    }

    private mutating func consumeAll() -> Data {
        let all = buffer
        buffer.removeAll(keepingCapacity: true)
        return all
    }

    private var pendingChunkBytes = 0
    private var expectingChunkTerminator = false

    private mutating func dechunk() -> Data {
        var out = Data()
        while true {
            if expectingChunkTerminator {
                guard buffer.count >= 2 else { return out }
                buffer.removeFirst(2)
                expectingChunkTerminator = false
            }
            if pendingChunkBytes > 0 {
                let take = min(pendingChunkBytes, buffer.count)
                guard take > 0 else { return out }
                out.append(buffer.prefix(take))
                buffer.removeFirst(take)
                pendingChunkBytes -= take
                if pendingChunkBytes == 0 { expectingChunkTerminator = true }
                continue
            }
            guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else { return out }
            let sizeLine = String(decoding: buffer[..<lineEnd.lowerBound], as: UTF8.self)
            buffer.removeSubrange(..<lineEnd.upperBound)
            let sizeToken = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return out
            }
            if size == 0 {
                // Final chunk: swallow trailers; stream is complete.
                buffer.removeAll()
                return out
            }
            pendingChunkBytes = size
        }
    }
}

// MARK: - Transcript Collector

private actor R2T2TranscriptCollector {
    private(set) var text = ""
    private(set) var finalText: String?
    private(set) var error: String?
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func append(_ delta: String) {
        text += delta
    }

    func setFinalText(_ value: String) {
        finalText = value
    }

    func setError(_ message: String) {
        if error == nil { error = message }
        complete()
    }

    func complete() {
        guard !completed else { return }
        completed = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitForCompletion() async {
        if completed { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

// MARK: - Live Connection

/// One HTTP/1.1 connection to the live transcription route. Shared by batch and live transcription.
/// Uses Network.framework because URLSession cannot read a response while its request body is
/// still being streamed.
private final class R2T2LiveConnection: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.typewhisper.r2t2", category: "Live")
    private static let connectTimeout: Duration = .seconds(5)
    /// Includes model load on the server's first request after startup or idle unload.
    private static let finishTimeout: Duration = .seconds(120)

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.typewhisper.r2t2.live")
    private let collector = R2T2TranscriptCollector()
    private let onProgress: @Sendable (String) -> Bool
    private let parserLock = OSAllocatedUnfairLock(initialState: R2T2ResponseParser())
    private var sentTerminator = false

    init(serverURL: URL, modelId: String, language: String?, prompt: String?, onProgress: @Sendable @escaping (String) -> Bool) async throws {
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()
        guard let host = serverURL.host else { throw PluginTranscriptionError.notConfigured }
        let isTLS = serverURL.scheme == "https"
        let port = UInt16(serverURL.port ?? (isTLS ? 443 : 80))
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw PluginTranscriptionError.notConfigured
        }
        let parameters = isTLS ? NWParameters.tls : NWParameters.tcp
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        self.onProgress = onProgress

        try await waitUntilReady(serverURL: serverURL)
        try await send(R2T2Protocol.makeLiveRequestHead(serverURL: serverURL, modelId: modelId, language: language, prompt: prompt))
        receiveLoop()
    }

    private func waitUntilReady(serverURL: URL) async throws {
        let connection = self.connection
        let ready: Bool = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    let resumed = OSAllocatedUnfairLock(initialState: false)
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if !resumed.withLock({ let was = $0; $0 = true; return was }) { continuation.resume(returning: true) }
                        case .failed(let error):
                            if !resumed.withLock({ let was = $0; $0 = true; return was }) { continuation.resume(throwing: error) }
                        case .cancelled:
                            if !resumed.withLock({ let was = $0; $0 = true; return was }) {
                                continuation.resume(throwing: CancellationError())
                            }
                        default:
                            break
                        }
                    }
                    connection.start(queue: self.queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: Self.connectTimeout)
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard ready else {
            connection.cancel()
            throw PluginTranscriptionError.networkError("Timed out connecting to R2T2 server at \(serverURL.absoluteString)")
        }
        connection.stateUpdateHandler = { [collector] state in
            if case .failed(let error) = state {
                Task { await collector.setError(error.localizedDescription) }
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: PluginTranscriptionError.networkError(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let collector = self.collector
            let onProgress = self.onProgress
            let events = data.map { chunk in self.parserLock.withLock { $0.feed(chunk) } } ?? []
            Task {
                for event in events {
                    switch event {
                    case .delta(let delta):
                        guard !delta.isEmpty else { continue }
                        await collector.append(delta)
                        _ = onProgress(await collector.text)
                    case .done(let text):
                        await collector.setFinalText(text)
                    case .error(let message):
                        await collector.setError(message)
                    case .finished:
                        await collector.complete()
                    }
                }
                if let error {
                    // A reset after the server already finished is just the server hanging up.
                    if await collector.finalText == nil {
                        await collector.setError(error.localizedDescription)
                    } else {
                        await collector.complete()
                    }
                } else if isComplete {
                    await collector.complete()
                }
            }
            if error == nil && !isComplete {
                self.receiveLoop()
            }
        }
    }

    func sendAudio(samples: [Float]) async throws {
        if let error = await collector.error { throw PluginTranscriptionError.apiError(error) }
        let pcm = R2T2Protocol.makePCM16LEData(samples: samples)
        guard !pcm.isEmpty else { return }
        try await send(R2T2Protocol.chunkFrame(pcm))
    }

    /// Sends the terminating chunk and waits for the final transcript.
    func finish() async throws -> String {
        if !sentTerminator {
            sentTerminator = true
            do {
                try await send(R2T2Protocol.terminatingChunk)
            } catch {
                Self.logger.warning("Failed to send terminating chunk: \(error.localizedDescription)")
            }
        }

        let collector = self.collector
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await collector.waitForCompletion(); return true }
            group.addTask { try? await Task.sleep(for: Self.finishTimeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        connection.cancel()
        if !completed {
            Self.logger.warning("Timed out waiting for the final R2T2 transcript")
        }
        if let error = await collector.error {
            throw PluginTranscriptionError.apiError(error)
        }
        if let finalText = await collector.finalText { return finalText }
        return await collector.text
    }

    func cancel() {
        connection.cancel()
        Task { await collector.complete() }
    }
}

// MARK: - Live Session

private final class R2T2LiveTranscriptionSession: LiveTranscriptionSession, @unchecked Sendable {
    private let connection: R2T2LiveConnection
    private let language: String?

    init(connection: R2T2LiveConnection, language: String?) {
        self.connection = connection
        self.language = language
    }

    func appendAudio(samples: [Float]) async throws {
        try await connection.sendAudio(samples: samples)
    }

    func finish() async throws -> PluginTranscriptionResult {
        let text = try await connection.finish()
        return PluginTranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), detectedLanguage: language)
    }

    func cancel() async {
        connection.cancel()
    }
}

// MARK: - Plugin Entry Point

@objc(R2T2Plugin)
final class R2T2Plugin: NSObject, TranscriptionEnginePlugin, LiveTranscriptionCapablePlugin,
    LiveTranscriptionProgressModeProviding, DictionaryTermsCapabilityProviding, @unchecked Sendable
{
    static let pluginId = "com.typewhisper.r2t2"
    static let pluginName = "Confucius4-R2T2"
    static let serverURLKey = "serverURL"
    static let modelIdKey = "modelId"

    private let logger = Logger(subsystem: "com.typewhisper.r2t2", category: "Plugin")
    fileprivate var host: HostServices?
    fileprivate var _serverURL = R2T2Protocol.defaultServerURL
    fileprivate var _modelId = R2T2Protocol.defaultModelId

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        if let stored = host.userDefault(forKey: Self.serverURLKey) as? String, !stored.isEmpty {
            _serverURL = stored
        }
        if let stored = host.userDefault(forKey: Self.modelIdKey) as? String, !stored.isEmpty {
            _modelId = stored
        }
    }

    func deactivate() {
        host = nil
    }

    // MARK: TranscriptionEnginePlugin

    var providerId: String { "r2t2" }
    var providerDisplayName: String { "Confucius4-R2T2" }
    var isConfigured: Bool { R2T2Protocol.normalizedServerURL(_serverURL) != nil && !_modelId.isEmpty }
    var transcriptionModels: [PluginModelInfo] {
        [PluginModelInfo(id: _modelId, displayName: "Confucius4-R2T2 (\(_modelId))")]
    }
    var selectedModelId: String? { _modelId }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }
    var liveTranscriptionProgressMode: LiveTranscriptionProgressMode { .completeSnapshot }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }
    var supportedLanguages: [String] { Array(R2T2Protocol.languageNames.keys).sorted() }

    var serverURLString: String { _serverURL }
    var modelId: String { _modelId }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        try await transcribe(audio: audio, language: language, translate: translate, prompt: prompt, onProgress: { _ in true })
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        let connection = try await openConnection(language: language, prompt: prompt, onProgress: onProgress)
        do {
            // 4096 samples = 256 ms per HTTP chunk.
            let chunk = 4096
            var offset = 0
            while offset < audio.samples.count {
                let end = min(offset + chunk, audio.samples.count)
                try await connection.sendAudio(samples: Array(audio.samples[offset..<end]))
                offset = end
            }
            let text = try await connection.finish()
            return PluginTranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), detectedLanguage: language)
        } catch {
            connection.cancel()
            throw error
        }
    }

    // MARK: LiveTranscriptionCapablePlugin

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        let connection = try await openConnection(language: language, prompt: prompt, onProgress: onProgress)
        return R2T2LiveTranscriptionSession(connection: connection, language: language)
    }

    private func openConnection(language: String?, prompt: String?, onProgress: @Sendable @escaping (String) -> Bool) async throws -> R2T2LiveConnection {
        guard let url = R2T2Protocol.normalizedServerURL(_serverURL), !_modelId.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        return try await R2T2LiveConnection(
            serverURL: url,
            modelId: _modelId,
            language: R2T2Protocol.languageName(for: language),
            prompt: R2T2Protocol.contextPrompt(from: prompt),
            onProgress: onProgress
        )
    }

    // MARK: Settings

    var settingsView: AnyView? {
        AnyView(R2T2SettingsView(plugin: self))
    }

    fileprivate func setServerURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        _serverURL = trimmed.isEmpty ? R2T2Protocol.defaultServerURL : trimmed
        host?.setUserDefault(_serverURL, forKey: Self.serverURLKey)
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setModelId(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        _modelId = trimmed.isEmpty ? R2T2Protocol.defaultModelId : trimmed
        host?.setUserDefault(_modelId, forKey: Self.modelIdKey)
        host?.notifyCapabilitiesChanged()
    }

    /// Checks `/health` and that the configured model id exists with `mode: streaming`.
    /// Returns nil on success, otherwise a user-facing error message.
    fileprivate func testConnection() async -> String? {
        guard let base = R2T2Protocol.normalizedServerURL(_serverURL) else { return "Invalid server URL" }
        do {
            try PluginHTTPClient.ensureNetworkAccessIsAllowed()
            var request = URLRequest(url: base.appendingPathComponent("v1/models"))
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return "Server answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = json?["data"] as? [[String: Any]] ?? []
            guard let model = models.first(where: { ($0["id"] as? String) == _modelId }) else {
                let ids = models.compactMap { $0["id"] as? String }.joined(separator: ", ")
                return "Model '\(_modelId)' not found on server (available: \(ids))"
            }
            guard (model["mode"] as? String) == "streaming" else {
                return "Model '\(_modelId)' is not configured with mode=streaming"
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Settings View

private struct R2T2SettingsView: View {
    let plugin: R2T2Plugin
    @State private var serverURL = ""
    @State private var modelId = ""
    @State private var isTesting = false
    @State private var testError: String?
    @State private var testSucceeded = false
    private let bundle = Bundle(for: R2T2Plugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Server URL", bundle: bundle)
                    .font(.headline)
                TextField(R2T2Protocol.defaultServerURL, text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { save() }
                Text("audiocpp_server with a confucius4_r2t2 model in streaming mode.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Model ID", bundle: bundle)
                    .font(.headline)
                TextField(R2T2Protocol.defaultModelId, text: $modelId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { save() }
                Text("The \"id\" of the model entry in the server config.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(String(localized: "Save", bundle: bundle)) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(String(localized: "Test Connection", bundle: bundle)) {
                    save()
                    runTest()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTesting)

                if isTesting {
                    ProgressView().controlSize(.small)
                } else if let testError {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(testError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if testSucceeded {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Connected", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Text("Audio is streamed as 16 kHz PCM to your local audio.cpp server. Nothing is sent anywhere else.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            serverURL = plugin.serverURLString
            modelId = plugin.modelId
        }
    }

    private func save() {
        plugin.setServerURL(serverURL)
        plugin.setModelId(modelId)
        serverURL = plugin.serverURLString
        modelId = plugin.modelId
    }

    private func runTest() {
        isTesting = true
        testError = nil
        testSucceeded = false
        Task {
            let error = await plugin.testConnection()
            await MainActor.run {
                isTesting = false
                testError = error
                testSucceeded = error == nil
            }
        }
    }
}
