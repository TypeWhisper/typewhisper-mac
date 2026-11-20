import Foundation
import os
import TypeWhisperPluginSDK

/// The WebSocket a live session talks to, so tests can play the server.
protocol ZoomLiveSocket: Sendable {
    func send(text: String) async throws
    func send(data: Data) async throws
    /// The next text message; throws once the socket is closed.
    func receive() async throws -> String
    func close()
}

final class URLSessionZoomLiveSocket: ZoomLiveSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func send(data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> String {
        while true {
            switch try await task.receive() {
            case .string(let text):
                return text
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) { return text }
            @unknown default:
                continue
            }
        }
    }

    func close() {
        // `receive()` ignores task cancellation; only closing the socket ends it.
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Streams a dictation to Zoom Scribe's Live mode while it is recorded.
///
/// The session waits for `session.created`, sends the settings in one
/// `session.update` and waits for `session.updated` before any audio. Audio goes
/// out as binary 16 kHz PCM16 frames of 100 ms. Scribe splits the speech into
/// items: `transcription.delta` holds the whole partial text of an item so far,
/// `transcription.completed` its final text. When the recording stops, the
/// session sends `session.close` and waits for `session.closed`, which follows
/// the last `transcription.completed` (0.3 to 0.5 s after the stop in our tests).
/// https://developers.zoom.us/docs/ai-services/scribe/live-mode/
actor ZoomLiveTranscriptionSession: LiveTranscriptionSession {
    static let sampleRate = 16_000
    static let chunkSampleCount = sampleRate / 10
    static let startTimeout: Duration = .seconds(10)
    static let finishTimeout: Duration = .seconds(10)

    private static let logger = Logger(subsystem: "com.typewhisper.zoom", category: "LiveSession")

    private struct Item {
        var text: String
        var isCompleted: Bool
    }

    private let socket: any ZoomLiveSocket
    private let sessionUpdate: [String: Any]
    private let pinnedLanguage: String?
    private let onProgress: @Sendable (String) -> Bool
    private var receiveTask: Task<Void, Never>?

    private var isCreated = false
    private var isConfigured = false
    private var isSessionClosed = false
    private var isClosed = false
    private var isCancelled = false
    private var failure: Error?
    private var pendingSamples: [Float] = []
    private var itemOrder: [String] = []
    private var items: [String: Item] = [:]
    private var detectedLanguage: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init(
        socket: any ZoomLiveSocket,
        sessionUpdate: [String: Any],
        pinnedLanguage: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) {
        self.socket = socket
        self.sessionUpdate = sessionUpdate
        self.pinnedLanguage = pinnedLanguage
        self.onProgress = onProgress
    }

    /// Opens the session and returns once Scribe applied the settings, so a wrong
    /// key or a model the account cannot use fails here instead of during the
    /// recording.
    static func connect(
        socket: any ZoomLiveSocket,
        request: ZoomAPIClient.Request,
        startTimeout: Duration = startTimeout,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> ZoomLiveTranscriptionSession {
        var config = request.config
        config["interim_results"] = true
        let session = ZoomLiveTranscriptionSession(
            socket: socket,
            sessionUpdate: [
                "type": "session.update",
                "config": config,
                "audio": ["format": "pcm16"],
            ],
            pinnedLanguage: request.languageCode,
            onProgress: onProgress
        )
        await session.startReceiving()
        try await withTaskCancellationHandler {
            try await session.configure(timeout: startTimeout)
        } onCancel: {
            socket.close()
        }
        return session
    }

    /// The final text of every finished item and the partial text of the others,
    /// in the order the items started.
    var currentText: String {
        itemOrder.compactMap { items[$0]?.text }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func appendAudio(samples: [Float]) async throws {
        try throwIfEnded()
        guard !samples.isEmpty else { return }
        pendingSamples.append(contentsOf: samples)
        try await sendPendingAudio(flush: false)
    }

    func finish() async throws -> PluginTranscriptionResult {
        do {
            try throwIfEnded()
            try await sendPendingAudio(flush: true)
            try await send(["type": "session.close"])
        } catch {
            close()
            throw error
        }

        let isComplete = await wait(timeout: Self.finishTimeout) { $0.isSessionClosed }
        close()
        guard isComplete else {
            // Without `session.closed` the end of the speech may be missing;
            // TypeWhisper then transcribes the whole recording instead.
            throw failure ?? PluginTranscriptionError.apiError("Zoom did not finish the live transcript")
        }
        Self.logger.info("Live session finished")
        return PluginTranscriptionResult(
            text: currentText,
            detectedLanguage: detectedLanguage ?? pinnedLanguage
        )
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        pendingSamples = []
        close()
        Self.logger.info("Live session cancelled")
    }

    // MARK: Sending

    private func configure(timeout: Duration) async throws {
        guard await wait(timeout: timeout, until: { $0.isCreated }) else {
            close()
            if Task.isCancelled { throw CancellationError() }
            throw failure ?? PluginTranscriptionError.networkError("Zoom live session did not start")
        }
        do {
            try await send(sessionUpdate)
        } catch {
            // `connect` throws, so no caller is left to close the socket.
            close()
            throw error
        }
        guard await wait(timeout: timeout, until: { $0.isConfigured }) else {
            close()
            if Task.isCancelled { throw CancellationError() }
            throw failure ?? PluginTranscriptionError.networkError("Zoom live session did not apply its settings")
        }
    }

    /// Sends buffered audio in 100 ms frames; `flush` also sends the rest.
    private func sendPendingAudio(flush: Bool) async throws {
        while pendingSamples.count >= Self.chunkSampleCount || (flush && !pendingSamples.isEmpty) {
            let count = min(pendingSamples.count, Self.chunkSampleCount)
            let chunk = Array(pendingSamples.prefix(count))
            pendingSamples.removeFirst(count)
            do {
                try await socket.send(data: Self.pcm16(chunk))
            } catch {
                let failure = self.failure ?? PluginTranscriptionError.networkError(error.localizedDescription)
                fail(failure)
                throw failure
            }
        }
    }

    private func send(_ message: [String: Any]) async throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            try await socket.send(text: String(data: data, encoding: .utf8) ?? "")
        } catch {
            let failure = self.failure ?? PluginTranscriptionError.networkError(error.localizedDescription)
            fail(failure)
            throw failure
        }
    }

    static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var value = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: Receiving

    private func startReceiving() {
        let socket = self.socket
        receiveTask = Task {
            do {
                while true {
                    let message = try await socket.receive()
                    self.handle(message)
                }
            } catch {
                self.receiveEnded(error)
            }
        }
    }

    func handle(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "session.created":
            isCreated = true
            resumeWaiters()
        case "session.updated":
            isConfigured = true
            resumeWaiters()
        case "transcription.delta":
            guard let itemId = json["item_id"] as? String else { return }
            var item = items[itemId] ?? startItem(itemId)
            guard !item.isCompleted else { return }
            item.text = (json["delta"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            items[itemId] = item
            reportProgress()
        case "transcription.completed":
            guard let itemId = json["item_id"] as? String else { return }
            var item = items[itemId] ?? startItem(itemId)
            item.text = (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            item.isCompleted = true
            items[itemId] = item
            if let language = json["language"] as? String, !language.isEmpty {
                detectedLanguage = ZoomAPIClient.languageCode(fromLocale: language)
            }
            reportProgress()
        case "session.closed":
            isSessionClosed = true
            resumeWaiters()
        case "error":
            let error = json["error"] as? [String: Any] ?? [:]
            // Only a fatal error ends the session.
            guard error["fatal"] as? Bool != false else { return }
            let detail = (error["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown live error"
            Self.logger.warning("Live session failed: \(detail, privacy: .public)")
            fail(PluginTranscriptionError.apiError(detail))
            close()
        default:
            break
        }
    }

    private func startItem(_ itemId: String) -> Item {
        itemOrder.append(itemId)
        return Item(text: "", isCompleted: false)
    }

    private func reportProgress() {
        let text = currentText
        guard !text.isEmpty, !isCancelled else { return }
        _ = onProgress(text)
    }

    private func receiveEnded(_ error: Error) {
        isClosed = true
        if failure == nil, !isCancelled, !isSessionClosed {
            fail(PluginTranscriptionError.networkError("Zoom live session closed: \(error.localizedDescription)"))
        }
        resumeWaiters()
    }

    // MARK: State

    private func throwIfEnded() throws {
        if isCancelled { throw CancellationError() }
        if let failure { throw failure }
        if isClosed { throw PluginTranscriptionError.networkError("Zoom live session closed") }
    }

    private func fail(_ error: Error) {
        if failure == nil {
            failure = error
        }
        resumeWaiters()
    }

    private func close() {
        isClosed = true
        socket.close()
        receiveTask?.cancel()
        resumeWaiters()
    }

    /// Waits until `condition` holds, the session fails or closes, or `timeout` passes.
    private func wait(
        timeout: Duration,
        until condition: (isolated ZoomLiveTranscriptionSession) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            self.resumeWaiters()
        }
        defer { timer.cancel() }

        return await withTaskCancellationHandler {
            while !condition(self) {
                guard failure == nil, !isClosed, !isCancelled, !Task.isCancelled,
                      ContinuousClock.now < deadline else {
                    return false
                }
                await withCheckedContinuation { waiters.append($0) }
            }
            return true
        } onCancel: {
            Task { await self.resumeWaiters() }
        }
    }

    private func resumeWaiters() {
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}
