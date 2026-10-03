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
        // URLComponents leaves "+" alone, but the server decodes it as a space ("C++" would become "C  ").
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
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

    /// 300 ms of silence, then the terminating chunk. R2T2 drops a final word that ends exactly at
    /// the end of the audio; the silence matches the tail padding TypeWhisper adds for batch engines.
    static let endOfStream = chunkFrame(Data(count: sampleRate * 3 / 10 * 2)) + terminatingChunk

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
    /// Undecoded SSE bytes; decoding waits for a complete event so a UTF-8 character split
    /// across packets stays intact.
    private var eventBytes = Data()
    private var errorBody = Data()
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
            eventBytes.append(decoded)
            while let separator = eventBytes.range(of: Data("\n\n".utf8)) {
                let block = String(decoding: eventBytes[..<separator.lowerBound], as: UTF8.self)
                eventBytes.removeSubrange(..<separator.upperBound)
                let payload = block
                    .components(separatedBy: "\n")
                    .filter { $0.hasPrefix("data:") }
                    .map { String($0.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n")
                if !payload.isEmpty, let event = R2T2Protocol.parseSSEData(payload) {
                    events.append(event)
                }
            }
        case .failedBody:
            // Reported by finish() once the whole body is in.
            errorBody.append(decoded)
        case .head:
            break
        }
        return events
    }

    /// Call when the connection closes. Reports a non-200 response, also one with an empty body,
    /// and a connection that closed before sending a response.
    mutating func finish() -> [R2T2Protocol.ServerEvent] {
        switch phase {
        case .head:
            return [.error("The server closed the connection without a response")]
        case .failedBody(let status):
            phase = .body
            let body = String(decoding: errorBody, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (try? JSONSerialization.jsonObject(with: errorBody) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            let detail = message ?? body
            return [.error(detail.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(detail)")]
        case .body:
            return []
        }
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
    private static let logger = Logger(subsystem: "com.scriptease.r2t2", category: "Live")
    private static let connectTimeout: Duration = .seconds(5)
    /// Includes model load on the server's first request after startup or idle unload.
    private static let finishTimeout: Duration = .seconds(120)

    /// What the receive callbacks report; one consumer task applies these in arrival order.
    private enum Input {
        case events([R2T2Protocol.ServerEvent])
        case failed(String)
        case closed
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.scriptease.r2t2.live")
    private let collector: R2T2TranscriptCollector
    private let inputs: AsyncStream<Input>.Continuation
    private let parserLock = OSAllocatedUnfairLock(initialState: R2T2ResponseParser())
    private var sentTerminator = false
    /// Keeps the built-in server from being replaced while this connection uses it.
    private let lease: R2T2ServerLease?

    init(serverURL: URL, modelId: String, language: String?, prompt: String?, lease: R2T2ServerLease? = nil,
         onProgress: @Sendable @escaping (String) -> Bool) async throws {
        self.lease = lease
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()
        guard let host = serverURL.host else { throw PluginTranscriptionError.notConfigured }
        let isTLS = serverURL.scheme == "https"
        let port = UInt16(serverURL.port ?? (isTLS ? 443 : 80))
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw PluginTranscriptionError.notConfigured
        }
        let parameters = isTLS ? NWParameters.tls : NWParameters.tcp
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        let collector = R2T2TranscriptCollector()
        self.collector = collector
        let (stream, inputs) = AsyncStream<Input>.makeStream()
        self.inputs = inputs
        Task {
            for await input in stream {
                switch input {
                case .events(let events):
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
                case .failed(let message):
                    // A reset after the server already finished is just the server hanging up.
                    if await collector.finalText == nil {
                        await collector.setError(message)
                    } else {
                        await collector.complete()
                    }
                case .closed:
                    await collector.complete()
                }
            }
            await collector.complete()
        }

        try await waitUntilReady(serverURL: serverURL)
        try await send(R2T2Protocol.makeLiveRequestHead(serverURL: serverURL, modelId: modelId, language: language, prompt: prompt))
        receiveLoop()
    }

    private func waitUntilReady(serverURL: URL) async throws {
        let connection = self.connection
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let ready: Bool
        do {
            ready = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    // Without this, a caller cancelled while the connection is .waiting would wait forever.
                    try await withTaskCancellationHandler {
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
                            guard !Task.isCancelled else {
                                if !resumed.withLock({ let was = $0; $0 = true; return was }) {
                                    continuation.resume(throwing: CancellationError())
                                }
                                return
                            }
                            connection.start(queue: self.queue)
                        }
                    } onCancel: {
                        connection.cancel()
                    }
                }
                group.addTask {
                    try await Task.sleep(for: Self.connectTimeout)
                    // Cancelling moves the connection to .cancelled, which resumes the waiting child.
                    timedOut.withLock { $0 = true }
                    connection.cancel()
                    return false
                }
                let first = try await group.next() ?? false
                group.cancelAll()
                return first
            }
        } catch where timedOut.withLock({ $0 }) {
            // The waiting child's CancellationError can arrive before the timeout child's result.
            ready = false
        }
        guard ready else {
            connection.cancel()
            throw PluginTranscriptionError.networkError("Timed out connecting to R2T2 server at \(serverURL.absoluteString)")
        }
        connection.stateUpdateHandler = { [inputs] state in
            if case .failed(let error) = state {
                inputs.yield(.failed(error.localizedDescription))
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
            if let data {
                let events = self.parserLock.withLock { $0.feed(data) }
                if !events.isEmpty { self.inputs.yield(.events(events)) }
            }
            if error != nil || isComplete {
                let events = self.parserLock.withLock { $0.finish() }
                if !events.isEmpty { self.inputs.yield(.events(events)) }
            }
            if let error {
                self.inputs.yield(.failed(error.localizedDescription))
                self.inputs.finish()
            } else if isComplete {
                self.inputs.yield(.closed)
                self.inputs.finish()
            } else {
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

    /// Ends the audio stream and waits for the final transcript.
    func finish() async throws -> String {
        if !sentTerminator {
            sentTerminator = true
            do {
                try await send(R2T2Protocol.endOfStream)
            } catch {
                Self.logger.warning("Failed to send terminating chunk: \(error.localizedDescription)")
            }
        }

        let collector = self.collector
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await collector.waitForCompletion() }
            group.addTask {
                // The sleep ends early when the transcript completes first or the caller is cancelled.
                if (try? await Task.sleep(for: Self.finishTimeout)) != nil {
                    timedOut.withLock { $0 = true }
                }
                // Releases the waiting child; the group cannot return while it is still suspended.
                await collector.complete()
            }
            await group.next()
            group.cancelAll()
        }
        connection.cancel()
        inputs.finish()
        lease?.release()
        if let error = await collector.error {
            throw PluginTranscriptionError.apiError(error)
        }
        if let finalText = await collector.finalText { return finalText }
        let text = await collector.text
        if timedOut.withLock({ $0 }) {
            // Keep what was already dictated; fail only when nothing arrived.
            Self.logger.warning("Timed out waiting for the final R2T2 transcript")
            if text.isEmpty { throw PluginTranscriptionError.networkError("Timed out waiting for the R2T2 transcript") }
        }
        return text
    }

    func cancel() {
        connection.cancel()
        inputs.finish()
        lease?.release()
    }

    /// Ends the consumer task when the connection is dropped without finish() or cancel(),
    /// for example when init throws after connecting.
    deinit {
        inputs.finish()
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

enum R2T2ServerMode: String {
    /// The plugin downloads audio.cpp and a model and runs `audiocpp_server` itself.
    case builtIn
    /// The user runs `audiocpp_server` and enters its URL.
    case custom
}

/// What is on disk, cached so that settings and `isConfigured` do not stat files on every read.
struct R2T2InstallState: Sendable, Equatable {
    var runtime = false
    var models: Set<String> = []
}

/// Download state shared with the settings view, which polls it.
struct R2T2DownloadSnapshot: Sendable, Equatable {
    var modelId: String?
    var progress: Double = 0
    var error: String?
}

@objc(R2T2Plugin)
final class R2T2Plugin: NSObject, TranscriptionEnginePlugin, LiveTranscriptionCapablePlugin,
    LiveTranscriptionProgressModeProviding, DictionaryTermsCapabilityProviding,
    TranscriptionModelCatalogProviding, PluginDownloadedModelManaging, @unchecked Sendable
{
    static let pluginId = "com.scriptease.r2t2"
    static let pluginName = "Confucius4-R2T2"
    static let serverURLKey = "serverURL"
    static let modelIdKey = "modelId"
    static let serverModeKey = "serverMode"
    static let builtInModelKey = "builtInModel"

    private let logger = Logger(subsystem: "com.scriptease.r2t2", category: "Plugin")
    fileprivate var host: HostServices?
    fileprivate var _serverURL = R2T2Protocol.defaultServerURL
    fileprivate var _modelId = R2T2Protocol.defaultModelId
    fileprivate var _mode = R2T2ServerMode.builtIn
    fileprivate var _builtInModel = R2T2ModelDefinition.recommended
    fileprivate var assets: R2T2ManagedAssets?
    fileprivate var server: R2T2ManagedServer?
    fileprivate let download = OSAllocatedUnfairLock(initialState: R2T2DownloadSnapshot())
    fileprivate let installState = OSAllocatedUnfairLock(initialState: R2T2InstallState())
    /// Only touched on the main actor, where the settings view reads it.
    @MainActor private var downloadTask: Task<Void, Never>?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        let storedURL = host.userDefault(forKey: Self.serverURLKey) as? String
        if let storedURL, !storedURL.isEmpty {
            _serverURL = storedURL
        }
        if let stored = host.userDefault(forKey: Self.modelIdKey) as? String, !stored.isEmpty {
            _modelId = stored
        }
        // Installs from before the built-in server keep using the server they configured.
        let storedMode = (host.userDefault(forKey: Self.serverModeKey) as? String).flatMap(R2T2ServerMode.init)
        _mode = storedMode ?? (storedURL?.isEmpty == false ? .custom : .builtIn)
        _builtInModel = R2T2ModelDefinition.model(for: host.userDefault(forKey: Self.builtInModelKey) as? String)
            ?? R2T2ModelDefinition.recommended
        let assets = R2T2ManagedAssets(pluginDataDirectory: host.pluginDataDirectory)
        self.assets = assets
        let server = R2T2ManagedServer(assets: assets)
        server.onStatusChange = { [weak self] in self?.host?.notifyCapabilitiesChanged() }
        server.selectedModel = { [weak self] in self?._builtInModel }
        self.server = server
        refreshInstallState()
    }

    fileprivate func refreshInstallState() {
        guard let assets else { return }
        let state = R2T2InstallState(
            runtime: assets.isRuntimeInstalled,
            models: Set(R2T2ModelDefinition.all.filter(assets.isModelInstalled).map(\.id))
        )
        installState.withLock { $0 = state }
    }

    func deactivate() {
        Task { @MainActor in self.downloadTask?.cancel() }
        server?.stop()
        server = nil
        host = nil
    }

    // MARK: TranscriptionEnginePlugin

    var providerId: String { "r2t2" }
    var providerDisplayName: String { "Confucius4-R2T2" }
    var isConfigured: Bool {
        switch _mode {
        case .builtIn:
            let state = installState.withLock { $0 }
            return state.runtime && state.models.contains(_builtInModel.id)
        case .custom:
            return R2T2Protocol.normalizedServerURL(_serverURL) != nil && !_modelId.isEmpty
        }
    }
    var transcriptionModels: [PluginModelInfo] {
        switch _mode {
        case .builtIn:
            let installed = downloadedModels
            return installed.isEmpty ? [Self.modelInfo(_builtInModel)] : installed
        case .custom:
            return [PluginModelInfo(id: _modelId, displayName: "Confucius4-R2T2 (\(_modelId))")]
        }
    }
    var selectedModelId: String? { _mode == .builtIn ? _builtInModel.id : _modelId }
    func selectModel(_ modelId: String) {
        guard _mode == .builtIn, let model = R2T2ModelDefinition.model(for: modelId) else { return }
        setBuiltInModel(model)
    }
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }
    var liveTranscriptionProgressMode: LiveTranscriptionProgressMode { .completeSnapshot }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }
    var supportedLanguages: [String] { Array(R2T2Protocol.languageNames.keys).sorted() }

    var serverURLString: String { _serverURL }
    var modelId: String { _modelId }

    // MARK: TranscriptionModelCatalogProviding, PluginDownloadedModelManaging

    var availableModels: [PluginModelInfo] {
        _mode == .builtIn ? R2T2ModelDefinition.all.map(Self.modelInfo) : transcriptionModels
    }

    var downloadedModels: [PluginModelInfo] {
        let installed = installState.withLock { $0.models }
        return R2T2ModelDefinition.all.filter { installed.contains($0.id) }.map(Self.modelInfo)
    }

    func deleteDownloadedModel(_ modelId: String) async throws {
        guard let assets, let model = R2T2ModelDefinition.model(for: modelId) else { return }
        if server?.runningModel == model { server?.stop() }
        defer {
            refreshInstallState()
            // Keep dictation working when another model is still installed.
            if _builtInModel == model {
                let installed = installState.withLock { $0.models }
                if let fallback = ([R2T2ModelDefinition.recommended] + R2T2ModelDefinition.all).first(where: { installed.contains($0.id) }) {
                    setBuiltInModel(fallback)
                }
            }
            host?.notifyCapabilitiesChanged()
        }
        try assets.deleteModel(model)
    }

    static func modelInfo(_ model: R2T2ModelDefinition) -> PluginModelInfo {
        PluginModelInfo(id: model.id, displayName: "Confucius4-R2T2 \(model.displayName)")
    }

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
        let (url, modelId, lease) = try await endpoint()
        // On failure the lease is released when it goes out of scope here or with the connection.
        return try await R2T2LiveConnection(
            serverURL: url,
            modelId: modelId,
            language: R2T2Protocol.languageName(for: language),
            prompt: R2T2Protocol.contextPrompt(from: prompt),
            lease: lease,
            onProgress: onProgress
        )
    }

    /// The server to talk to; in built-in mode this starts `audiocpp_server` when it is not running
    /// and returns a lease on it.
    private func endpoint() async throws -> (URL, String, R2T2ServerLease?) {
        switch _mode {
        case .builtIn:
            guard let server else { throw PluginTranscriptionError.notConfigured }
            let (url, lease) = try await server.acquire(model: _builtInModel)
            return (url, R2T2ManagedServer.modelId, lease)
        case .custom:
            guard let url = R2T2Protocol.normalizedServerURL(_serverURL), !_modelId.isEmpty else {
                throw PluginTranscriptionError.notConfigured
            }
            return (url, _modelId, nil)
        }
    }

    // MARK: Settings

    var settingsView: AnyView? {
        AnyView(R2T2SettingsView(plugin: self))
    }

    fileprivate func setMode(_ mode: R2T2ServerMode) {
        _mode = mode
        host?.setUserDefault(mode.rawValue, forKey: Self.serverModeKey)
        if mode == .custom { server?.stop() }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setBuiltInModel(_ model: R2T2ModelDefinition) {
        _builtInModel = model
        host?.setUserDefault(model.id, forKey: Self.builtInModelKey)
        host?.notifyCapabilitiesChanged()
    }

    @MainActor fileprivate func startDownload(_ model: R2T2ModelDefinition) {
        guard let assets, downloadTask == nil else { return }
        let download = self.download
        download.withLock { $0 = R2T2DownloadSnapshot(modelId: model.id) }
        // Runs on the main actor; install() itself is nonisolated and does its work off the main thread.
        downloadTask = Task { @MainActor [weak self] in
            do {
                try await assets.install(model) { fraction in
                    download.withLock { $0.progress = fraction }
                }
                self?.download.withLock { $0 = R2T2DownloadSnapshot() }
                self?.setBuiltInModel(model)
            } catch {
                let message = error is CancellationError || (error as? URLError)?.code == .cancelled
                    ? nil : error.localizedDescription
                self?.download.withLock { $0 = R2T2DownloadSnapshot(error: message) }
            }
            self?.refreshInstallState()
            self?.downloadTask = nil
            self?.host?.notifyCapabilitiesChanged()
        }
    }

    @MainActor fileprivate func cancelDownload() {
        downloadTask?.cancel()
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

    /// Checks that the server lists the model with `mode: streaming`, starting the built-in server first.
    /// Returns nil on success, otherwise a user-facing error message.
    fileprivate func testConnection() async -> String? {
        do {
            let (base, modelId, lease) = try await endpoint()
            defer { lease?.release() }
            try PluginHTTPClient.ensureNetworkAccessIsAllowed()
            var request = URLRequest(url: base.appendingPathComponent("v1/models"))
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return "Server answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = json?["data"] as? [[String: Any]] ?? []
            guard let model = models.first(where: { ($0["id"] as? String) == modelId }) else {
                let ids = models.compactMap { $0["id"] as? String }.joined(separator: ", ")
                return "Model '\(modelId)' not found on server (available: \(ids))"
            }
            guard (model["mode"] as? String) == "streaming" else {
                return "Model '\(modelId)' is not configured with mode=streaming"
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
    @State private var mode = R2T2ServerMode.builtIn
    @State private var serverURL = ""
    @State private var modelId = ""
    @State private var isTesting = false
    @State private var testError: String?
    @State private var testSucceeded = false
    @State private var selectedModel = R2T2ModelDefinition.recommended
    @State private var installed: Set<String> = []
    @State private var runtimeInstalled = false
    @State private var download = R2T2DownloadSnapshot()
    @State private var runningPort: Int?
    @State private var modelToDelete: R2T2ModelDefinition?
    private let bundle = Bundle(for: R2T2Plugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(String(localized: "Server", bundle: bundle), selection: $mode) {
                Text("Built-in", bundle: bundle).tag(R2T2ServerMode.builtIn)
                Text("Own server", bundle: bundle).tag(R2T2ServerMode.custom)
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, newValue in
                plugin.setMode(newValue)
                testError = nil
                testSucceeded = false
            }

            switch mode {
            case .builtIn: builtInSection
            case .custom: customServerSection
            }

            testRow

            Text("Audio is streamed as 16 kHz PCM only to the audio.cpp server configured here.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            mode = plugin._mode
            serverURL = plugin.serverURLString
            modelId = plugin.modelId
            refresh()
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .confirmationDialog(
            String(localized: "Delete the downloaded model?", bundle: bundle),
            isPresented: Binding(get: { modelToDelete != nil }, set: { if !$0 { modelToDelete = nil } })
        ) {
            Button(String(localized: "Delete", bundle: bundle), role: .destructive) {
                if let model = modelToDelete {
                    Task { try? await plugin.deleteDownloadedModel(model.id) }
                }
                modelToDelete = nil
            }
        }
    }

    // MARK: Built-in

    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model", bundle: bundle)
                .font(.headline)
            ForEach(R2T2ModelDefinition.all) { model in
                modelRow(model)
            }
            // After a plugin update pins a new audio.cpp release, installed models need only the runtime.
            if !runtimeInstalled, let model = R2T2ModelDefinition.all.first(where: { installed.contains($0.id) }) {
                HStack {
                    Label(String(localized: "audiocpp_server \(R2T2Runtime.version) is not installed yet.", bundle: bundle),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Spacer()
                    Button(String(localized: "Download", bundle: bundle)) { plugin.startDownload(model) }
                        .controlSize(.small)
                        .disabled(download.modelId != nil)
                }
            }
            if let error = download.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Group {
                if let runningPort {
                    Text("audiocpp_server \(R2T2Runtime.version) is running on 127.0.0.1:\(String(runningPort)).", bundle: bundle)
                } else {
                    Text("audiocpp_server \(R2T2Runtime.version) starts with the first dictation and restarts if it stops.", bundle: bundle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            licenseNote
        }
    }

    private func modelRow(_ model: R2T2ModelDefinition) -> some View {
        let isInstalled = installed.contains(model.id)
        let isDownloading = download.modelId == model.id
        return HStack(spacing: 10) {
            Image(systemName: selectedModel == model ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isInstalled ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model == .recommended
                    ? String(localized: "\(model.displayName) (recommended)", bundle: bundle)
                    : model.displayName)
                Text("\(ByteCountFormatter.string(fromByteCount: model.fileSize, countStyle: .file)) · \(summary(model))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDownloading {
                ProgressView(value: download.progress)
                    .frame(width: 100)
                Button(String(localized: "Cancel", bundle: bundle)) { plugin.cancelDownload() }
                    .controlSize(.small)
            } else if isInstalled {
                Button(String(localized: "Delete", bundle: bundle)) { modelToDelete = model }
                    .controlSize(.small)
            } else {
                Button(String(localized: "Download", bundle: bundle)) { plugin.startDownload(model) }
                    .controlSize(.small)
                    .disabled(download.modelId != nil)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isInstalled else { return }
            plugin.setBuiltInModel(model)
            refresh()
        }
    }

    private func summary(_ model: R2T2ModelDefinition) -> String {
        switch model {
        case .q4km: return String(localized: "Smallest and fastest, community quant by Nairod785", bundle: bundle)
        case .f16: return String(localized: "Full precision, largest", bundle: bundle)
        default: return String(localized: "Near full quality, by davidxifeng", bundle: bundle)
        }
    }

    private var licenseNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The model weights are licensed by NetEase Youdao under the Confucius4-R2T2 Model Use License, which is downloaded with each model (LICENSE, LICENSE_zh, NOTICE). By downloading you accept it. The server is audio.cpp, Apache-2.0.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Link(String(localized: "Model license", bundle: bundle),
                     destination: selectedModel.repositoryURL.appendingPathComponent("blob/\(selectedModel.revision)/LICENSE"))
                Link("audio.cpp \(R2T2Runtime.version)", destination: R2T2Runtime.releaseURL)
                if let directory = plugin.assets?.modelDirectory(selectedModel), installed.contains(selectedModel.id) {
                    Button(String(localized: "Show in Finder", bundle: bundle)) {
                        NSWorkspace.shared.activateFileViewerSelecting([directory])
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.caption)
        }
    }

    // MARK: Own server

    private var customServerSection: some View {
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
        }
    }

    private var testRow: some View {
        HStack(spacing: 8) {
            if mode == .custom {
                Button(String(localized: "Save", bundle: bundle)) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button(String(localized: "Test Connection", bundle: bundle)) {
                if mode == .custom { save() }
                runTest()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isTesting || (mode == .builtIn && !installed.contains(selectedModel.id)))

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
    }

    private func refresh() {
        selectedModel = plugin._builtInModel
        let installState = plugin.installState.withLock { $0 }
        installed = installState.models
        runtimeInstalled = installState.runtime
        download = plugin.download.withLock { $0 }
        runningPort = plugin.server?.baseURL?.port
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
                refresh()
            }
        }
    }
}
