import Foundation
import os
import TypeWhisperPluginSDK

/// The WebSocket a live session talks to, so tests can play the server.
protocol MistralRealtimeSocket: Sendable {
    func send(text: String) async throws
    /// The next text message; throws once the socket is closed.
    func receive() async throws -> String
    func close()
}

final class URLSessionMistralRealtimeSocket: MistralRealtimeSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
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

/// Streams a dictation to Mistral's realtime transcription API while it is recorded,
/// for the live preview.
///
/// The session waits for `session.created`, sends every setting in one
/// `session.update` and waits for `session.updated` before any audio, because the
/// settings are fixed once audio has started. Audio goes out as base64 PCM in
/// `input_audio.append` messages of 100 ms. Each `transcription.text.delta` adds
/// text after the text before it. When the recording stops, the session sends
/// `input_audio.end`. With a `finalTranscriber`, the final text comes from it: the
/// file transcription models heard dictations more accurately than Realtime 3 and
/// answered sooner after the stop (0.6 s against 1.2 s on average). The text of
/// `transcription.done` is the final text without one, and when it fails.
/// https://docs.mistral.ai/studio/audio/speech-to-text/transcribe-in-realtime
actor MistralLiveTranscriptionSession: LiveTranscriptionSession {
    typealias FinalTranscriber = @Sendable (AudioData) async throws -> PluginTranscriptionResult

    static let sampleRate = 16_000
    static let chunkSampleCount = sampleRate / 10
    static let startTimeout: Duration = .seconds(10)
    /// `transcription.done` arrived 0.5 to 1.1 s after `input_audio.end` in our tests.
    static let finishTimeout: Duration = .seconds(10)

    private static let logger = Logger(subsystem: "com.minerale.mistralai", category: "LiveSession")

    private let socket: any MistralRealtimeSocket
    private let sessionSettings: [String: Any]
    private let pinnedLanguage: String?
    private let finalTranscriber: FinalTranscriber?
    private let onProgress: @Sendable (String) -> Bool
    private var receiveTask: Task<Void, Never>?

    private var isCreated = false
    private var isConfigured = false
    private var hasSentEnd = false
    private var isDone = false
    private var isClosed = false
    private var isCancelled = false
    private var failure: Error?
    private var pendingSamples: [Float] = []
    private var recordedSamples: [Float] = []
    private var deltaText = ""
    private var finalText: String?
    private var detectedLanguage: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init(
        socket: any MistralRealtimeSocket,
        sessionSettings: [String: Any],
        pinnedLanguage: String?,
        finalTranscriber: FinalTranscriber?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) {
        self.socket = socket
        self.sessionSettings = sessionSettings
        self.pinnedLanguage = pinnedLanguage
        self.finalTranscriber = finalTranscriber
        self.onProgress = onProgress
    }

    /// The `session.update` settings for 16 kHz PCM, with a pinned language and
    /// dictionary terms when there are any.
    static func sessionSettings(language: String?, contextBias: [String]) -> [String: Any] {
        var settings: [String: Any] = [
            "audio_format": ["encoding": "pcm_s16le", "sample_rate": sampleRate],
        ]
        if let language {
            settings["language"] = language
        }
        if !contextBias.isEmpty {
            settings["context_bias"] = contextBias
        }
        return settings
    }

    /// Opens the session and returns once Mistral applied the settings, so a wrong
    /// key, a model the account cannot use or a rejected setting fails here instead
    /// of during the recording.
    static func connect(
        socket: any MistralRealtimeSocket,
        language: String?,
        contextBias: [String],
        finalTranscriber: FinalTranscriber? = nil,
        startTimeout: Duration = startTimeout,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> MistralLiveTranscriptionSession {
        let session = MistralLiveTranscriptionSession(
            socket: socket,
            sessionSettings: sessionSettings(language: language, contextBias: contextBias),
            pinnedLanguage: language,
            finalTranscriber: finalTranscriber,
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

    /// The text so far: every delta, in order.
    var currentText: String {
        deltaText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func appendAudio(samples: [Float]) async throws {
        try throwIfEnded()
        guard !samples.isEmpty else { return }
        if finalTranscriber != nil {
            recordedSamples.append(contentsOf: samples)
        }
        pendingSamples.append(contentsOf: samples)
        try await sendPendingAudio(flush: false)
    }

    func finish() async throws -> PluginTranscriptionResult {
        var endError: Error?
        do {
            try throwIfEnded()
            try await sendPendingAudio(flush: true)
            try await send(["type": "input_audio.end"])
            hasSentEnd = true
        } catch {
            if error is CancellationError {
                close()
                throw error
            }
            endError = error
        }

        if let finalTranscriber {
            let samples = recordedSamples
            recordedSamples = []
            do {
                let result = try await finalTranscriber(AudioData(
                    samples: samples,
                    wavData: PluginWavEncoder.encode(samples),
                    duration: Double(samples.count) / Double(Self.sampleRate)
                ))
                close()
                Self.logger.info("Live session finished with the transcription model's text")
                return result
            } catch {
                if Task.isCancelled {
                    close()
                    throw CancellationError()
                }
                Self.logger.warning("Transcribing the recording failed, using the realtime transcript: \(error.localizedDescription, privacy: .public)")
            }
        }

        if let endError {
            close()
            throw endError
        }

        let isComplete = await wait(timeout: Self.finishTimeout) { $0.isDone }
        close()
        guard isComplete, let finalText else {
            // Without `transcription.done` the end of the speech may be missing;
            // TypeWhisper then transcribes the whole recording instead.
            throw failure ?? PluginTranscriptionError.apiError("Realtime API did not finish the transcript")
        }
        Self.logger.info("Live session finished with the realtime transcript")
        return PluginTranscriptionResult(
            text: finalText.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: detectedLanguage ?? pinnedLanguage
        )
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        pendingSamples = []
        recordedSamples = []
        close()
        Self.logger.info("Live session cancelled")
    }

    // MARK: Sending

    private func configure(timeout: Duration) async throws {
        guard await wait(timeout: timeout, until: { $0.isCreated }) else {
            close()
            if Task.isCancelled { throw CancellationError() }
            throw failure ?? PluginTranscriptionError.networkError("Realtime session did not start")
        }
        do {
            try await send(["type": "session.update", "session": sessionSettings])
        } catch {
            // `connect` throws, so no caller is left to close the socket.
            close()
            throw error
        }
        guard await wait(timeout: timeout, until: { $0.isConfigured }) else {
            close()
            if Task.isCancelled { throw CancellationError() }
            throw failure ?? PluginTranscriptionError.networkError("Realtime session did not apply its settings")
        }
    }

    /// Sends buffered audio in 100 ms messages; `flush` also sends the rest.
    private func sendPendingAudio(flush: Bool) async throws {
        while pendingSamples.count >= Self.chunkSampleCount || (flush && !pendingSamples.isEmpty) {
            let count = min(pendingSamples.count, Self.chunkSampleCount)
            let chunk = Array(pendingSamples.prefix(count))
            pendingSamples.removeFirst(count)
            let audio = Self.pcm16(chunk).base64EncodedString()
            try await send(["type": "input_audio.append", "audio": audio])
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
        case "transcription.text.delta":
            guard let text = json["text"] as? String, !text.isEmpty else { return }
            deltaText += text
            reportProgress()
        case "transcription.language":
            if let language = json["audio_language"] as? String ?? json["language"] as? String, !language.isEmpty {
                detectedLanguage = language
            }
        case "transcription.done":
            finalText = json["text"] as? String ?? deltaText
            if let language = json["language"] as? String, !language.isEmpty {
                detectedLanguage = language
            }
            isDone = true
            resumeWaiters()
        case "error":
            let detail = Self.errorMessage(from: json)
            Self.logger.warning("Realtime session failed: \(detail, privacy: .public)")
            fail(PluginTranscriptionError.apiError(detail))
            close()
        default:
            break
        }
    }

    /// `error.message` is a string, or for rejected settings an object with a
    /// `detail` list.
    static func errorMessage(from json: [String: Any]) -> String {
        let error = json["error"] as? [String: Any] ?? json
        if let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = error["message"] as? [String: Any],
           let text = MistralAPIClient.detailText(from: message) {
            return text
        }
        return "Unknown realtime error"
    }

    private func reportProgress() {
        let text = currentText
        guard !text.isEmpty, !isCancelled else { return }
        _ = onProgress(text)
    }

    private func receiveEnded(_ error: Error) {
        isClosed = true
        if failure == nil, !isCancelled, !isDone {
            fail(PluginTranscriptionError.networkError("Realtime session closed: \(error.localizedDescription)"))
        }
        resumeWaiters()
    }

    // MARK: State

    private func throwIfEnded() throws {
        if isCancelled { throw CancellationError() }
        if let failure { throw failure }
        if isClosed { throw PluginTranscriptionError.networkError("Realtime session closed") }
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
        until condition: (isolated MistralLiveTranscriptionSession) -> Bool
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
