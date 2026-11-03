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
        /// The server closed the connection with this status code and reason.
        case closedByServer(code: UInt16?, reason: String)

        var errorDescription: String? {
            switch self {
            case .upgradeFailed(let msg): return "WebSocket upgrade failed: \(msg)"
            case .closed: return "WebSocket closed"
            case .closedByServer(let code, let reason):
                let detail = [code.map(String.init), reason.isEmpty ? nil : reason]
                    .compactMap { $0 }
                    .joined(separator: " ")
                return detail.isEmpty ? "WebSocket closed by server" : "WebSocket closed by server (\(detail))"
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
    private let usesTLS: Bool
    private let path: String
    private let extraHeaders: [(String, String)]
    private let logger = Logger(subsystem: "com.typewhisper.reson8", category: "WebSocket")

    private let buffer = OSAllocatedUnfairLock(initialState: Data())

    init(host: String, port: Int, usesTLS: Bool, path: String, headers: [(String, String)]) {
        self.hostName = host
        self.usesTLS = usesTLS
        self.path = path
        self.extraHeaders = headers

        self.streamTask = URLSession.shared.streamTask(withHostName: host, port: port)
    }

    // MARK: - Connect + Upgrade

    func connect() async throws {
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()
        if usesTLS {
            streamTask.startSecureConnection()
        }
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
        let lines = responseStr.components(separatedBy: "\r\n")
        let statusLine = lines.first ?? ""
        guard statusLine.split(separator: " ").dropFirst().first == "101" else {
            throw WSError.upgradeFailed(Self.upgradeFailureSummary(statusLine: statusLine, headerLines: lines.dropFirst()))
        }
    }

    /// Reson8 rejects a connection, for example at the concurrent connection limit,
    /// without a body and names the reason in `X-Error-Message`.
    static func upgradeFailureSummary(statusLine: String, headerLines: some Sequence<String>) -> String {
        let prefix = "x-error-message:"
        let reason = headerLines
            .first { $0.lowercased().hasPrefix(prefix) }
            .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
        return [statusLine, reason ?? ""].filter { !$0.isEmpty }.joined(separator: ": ")
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

// MARK: - Realtime Session

/// The realtime endpoint as `Reson8RealtimeSession` uses it.
protocol Reson8RealtimeSocket: Sendable {
    /// Opens the connection; throws when Reson8 rejects it, for example at the
    /// concurrent connection limit.
    func connect() async throws
    func sendAudio(_ data: Data) async throws
    func sendText(_ text: String) async throws
    /// The next text message; throws once the connection is closed.
    func receive() async throws -> String
    func close()
}

extension RawWebSocket: Reson8RealtimeSocket {
    func sendAudio(_ data: Data) async throws {
        try await sendBinary(data)
    }

    func receive() async throws -> String {
        while true {
            let frame = try await receiveFrame()
            switch frame.opcode {
            case .text:
                return String(decoding: frame.payload, as: UTF8.self)
            case .close:
                // A close frame starts with a two-byte status code, followed by the reason.
                let bytes = [UInt8](frame.payload)
                let code = bytes.count >= 2 ? UInt16(bytes[0]) << 8 | UInt16(bytes[1]) : nil
                let reason = bytes.count > 2 ? String(decoding: bytes[2...], as: UTF8.self) : ""
                throw WSError.closedByServer(code: code, reason: reason)
            default:
                continue
            }
        }
    }

    func close() {
        cancel()
    }
}

/// One connection to Reson8's realtime or turns endpoint. A dictation feeds it while the
/// user speaks, a finished recording all at once.
///
/// - Realtime: Reson8 sends a final transcript per utterance, which ends at a pause, and
///   interim transcripts of the current utterance in between. A flush request finalizes
///   the rest, and its confirmation follows the last final transcript.
/// - Turns: Reson8 sends `turn_start` when speech begins, `turn_end_candidate` with the
///   transcript of the turn so far when it expects the turn to end, and `turn_end` once the
///   speaker finished a thought, which a pause in the middle of a sentence is not. A flush
///   request ends an open turn; without one, Reson8 answers nothing.
///   https://docs.reson8.dev/speech-to-text/turns/
actor Reson8RealtimeSession: LiveTranscriptionSession {
    enum Mode: Sendable {
        case realtime
        /// Reports the end of each turn.
        case turns(onTurnEnd: @Sendable () -> Void)
    }

    /// 256 ms of audio; Reson8 closes the connection on frames above 64 KiB.
    static let maximumFrameByteCount = 8_192
    /// Reson8 confirmed a flush 0.3 s after live audio and 2 s after 72 seconds sent at
    /// once. A recording sent at once gets a tenth of its length on top.
    static let finishTimeout: Duration = .seconds(10)
    /// How long a turns session waits for speech it heard since the last turn to become a
    /// turn; Reson8 ended an open turn 0.1 s after a flush.
    static let pendingSpeechTimeout: Duration = .seconds(2)

    private struct Utterance {
        let text: String
        let language: String?
        let words: [PluginWordTiming]
    }

    private static let logger = Logger(subsystem: "com.typewhisper.reson8", category: "RealtimeSession")

    private let socket: any Reson8RealtimeSocket
    private let mode: Mode
    private let requestedLanguage: String?
    private let onProgress: @Sendable (String) -> Bool
    private var receiveTask: Task<Void, Never>?

    /// The transcript of the open turn so far.
    private var turnCandidate: Utterance?
    private var isTurnOpen = false
    private var endedTurnCount = 0
    /// Whether the audio since the last turn end holds speech, which can still become a turn.
    private var hasSpeechSinceTurnEnd = false

    private var utterances: [Utterance] = []
    private var interimText = ""
    private var reportsProgress = true
    private var sentSampleCount = 0
    private var isFlushRequested = false
    private var isFlushConfirmed = false
    private var isClosed = false
    private var isCancelled = false
    private var failure: Error?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init(
        socket: any Reson8RealtimeSocket,
        mode: Mode,
        requestedLanguage: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) {
        self.socket = socket
        self.mode = mode
        self.requestedLanguage = requestedLanguage
        self.onProgress = onProgress
    }

    /// Opens the connection before it returns, so a wrong key or an exhausted credit
    /// limit fails here instead of during the recording.
    static func connect(
        socket: any Reson8RealtimeSocket,
        mode: Mode = .realtime,
        language: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> Reson8RealtimeSession {
        do {
            try await withTaskCancellationHandler {
                try await socket.connect()
            } onCancel: {
                socket.close()
            }
        } catch {
            // A connection that is not upgraded would otherwise stay open.
            socket.close()
            throw error
        }
        let session = Reson8RealtimeSession(socket: socket, mode: mode, requestedLanguage: language, onProgress: onProgress)
        await session.startReceiving()
        return session
    }

    /// The final transcripts and the current interim one, which together cover all audio so far.
    var currentText: String {
        (utterances.map(\.text) + [interimText]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func appendAudio(samples: [Float]) async throws {
        try throwIfEnded()
        let data = Reson8Plugin.floatToPCM16(samples)
        var start = data.startIndex
        while start < data.endIndex {
            try Task.checkCancellation()
            let end = min(start + Self.maximumFrameByteCount, data.endIndex)
            let frame = data.subdata(in: start..<end)
            try await send { try await $0.sendAudio(frame) }
            start = end
        }
        sentSampleCount += samples.count
        if case .turns = mode, !hasSpeechSinceTurnEnd {
            hasSpeechSinceTurnEnd = Self.containsSpeech(samples)
        }
    }

    /// Speech by the rule of TypeWhisper's silence stop: a 100 ms frame with an RMS of at
    /// least 0.004.
    static func containsSpeech(_ samples: [Float]) -> Bool {
        stride(from: 0, to: samples.count, by: 1_600).contains { start in
            let frame = samples[start..<min(start + 1_600, samples.count)]
            let power = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count)
            return power.squareRoot() >= 0.004
        }
    }

    func finish() async throws -> PluginTranscriptionResult {
        try throwIfEnded()
        if case .turns = mode {
            return try await finishTurns()
        }
        isFlushRequested = true
        try await send { try await $0.sendText(#"{"type":"flush_request","id":"typewhisper"}"#) }

        let timeout = Self.finishTimeout + .milliseconds(sentSampleCount / 160)
        let isConfirmed = await wait(timeout: timeout) { $0.isFlushConfirmed }
        close()
        guard isConfirmed else {
            if isCancelled || Task.isCancelled { throw CancellationError() }
            // Without the confirmation the last utterance may be missing, so TypeWhisper
            // transcribes the whole recording instead.
            throw failure ?? PluginTranscriptionError.networkError("Reson8 did not finish the realtime transcript in time")
        }

        return finalResult()
    }

    /// Ends an open turn with a flush, or waits briefly for speech that has not become a
    /// turn yet. Otherwise all turns ended, and the result is complete at once.
    private func finishTurns() async throws -> PluginTranscriptionResult {
        guard isTurnOpen || hasSpeechSinceTurnEnd else {
            close()
            return finalResult()
        }
        // Taken before the flush goes out: its turn end can arrive while the send is in progress.
        let turnsBefore = endedTurnCount
        let timeout = isTurnOpen
            ? Self.finishTimeout + .milliseconds(sentSampleCount / 160)
            : Self.pendingSpeechTimeout
        isFlushRequested = true
        try await send { try await $0.sendText(#"{"type":"flush_request"}"#) }

        let hasEnded = await wait(timeout: timeout) { $0.endedTurnCount > turnsBefore }
        // Closing ends the receive task, which must not count as a failure of the session.
        let connectionFailure = failure
        close()
        if !hasEnded {
            if isCancelled || Task.isCancelled { throw CancellationError() }
            // A turn that never ended may miss its last words, and a connection that failed
            // may have lost speech that had not become a turn, so TypeWhisper transcribes the
            // whole recording instead. Speech that never became a turn on a healthy
            // connection had no words.
            if let connectionFailure { throw connectionFailure }
            if isTurnOpen {
                throw PluginTranscriptionError.networkError("Reson8 did not end the last turn in time")
            }
        }
        return finalResult()
    }

    private func finalResult() -> PluginTranscriptionResult {
        PluginWordTimings.report(utterances.flatMap(\.words))
        Self.logger.info("Realtime session finished with \(self.utterances.count, privacy: .public) utterances")
        return PluginTranscriptionResult(
            text: utterances.map(\.text).joined(separator: " "),
            detectedLanguage: Reson8Plugin.detectedLanguage(
                Reson8Transcript.mostFrequentLanguage(utterances.compactMap(\.language)),
                requested: requestedLanguage
            ),
            // Sentence segments of each utterance.
            segments: utterances
                .flatMap { Reson8Transcript.sentenceSegments(from: $0.words) }
                .map { PluginTranscriptionSegment(text: $0.text, start: $0.start, end: $0.end) }
        )
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        close()
    }

    // MARK: Sending

    private func send(_ operation: (any Reson8RealtimeSocket) async throws -> Void) async throws {
        do {
            try await operation(socket)
        } catch {
            let failure = self.failure ?? error
            fail(failure)
            throw failure
        }
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
        guard let json = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "turn_start":
            isTurnOpen = true
        case "turn_end_candidate":
            // Each candidate replaces the previous one of the same turn.
            isTurnOpen = true
            turnCandidate = Utterance(
                text: ((json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                language: json["language"] as? String,
                words: Reson8Transcript.words(from: json["words"])
            )
            interimText = turnCandidate?.text ?? ""
            reportProgress()
        case "turn_end":
            if let turnCandidate, !turnCandidate.text.isEmpty {
                utterances.append(turnCandidate)
            }
            turnCandidate = nil
            interimText = ""
            isTurnOpen = false
            hasSpeechSinceTurnEnd = false
            endedTurnCount += 1
            if case .turns(let onTurnEnd) = mode, !isFlushRequested {
                onTurnEnd()
            }
            resumeWaiters()
        case "transcript":
            let text = ((json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if json["is_final"] as? Bool == true {
                if !text.isEmpty {
                    utterances.append(Utterance(
                        text: text,
                        language: json["language"] as? String,
                        words: Reson8Transcript.words(from: json["words"])
                    ))
                }
                interimText = ""
            } else {
                interimText = text
            }
            reportProgress()
        case "flush_confirmation":
            guard isFlushRequested else { return }
            isFlushConfirmed = true
            resumeWaiters()
        default:
            break
        }
    }

    private func reportProgress() {
        let text = currentText
        guard reportsProgress, !isCancelled, !text.isEmpty else { return }
        // A caller that returns false wants no further progress.
        reportsProgress = onProgress(text)
    }

    /// Reson8 reports errors after the connection opened only by closing it.
    private func receiveEnded(_ error: Error) {
        isClosed = true
        if failure == nil, !isCancelled, !isFlushConfirmed {
            Self.logger.warning("Realtime connection ended: \(error.localizedDescription, privacy: .public)")
            failure = PluginTranscriptionError.networkError("Reson8 realtime connection ended: \(error.localizedDescription)")
        }
        resumeWaiters()
    }

    // MARK: State

    private func throwIfEnded() throws {
        if isCancelled { throw CancellationError() }
        if let failure { throw failure }
        if isClosed { throw PluginTranscriptionError.networkError("Reson8 realtime connection is closed") }
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
        until condition: (isolated Reson8RealtimeSession) -> Bool
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

// MARK: - Models

/// A speech-to-text model as `GET /v1/model` lists it. The list is not in the
/// API reference, so every field the plugin relies on beyond the name is optional.
struct Reson8Model: Codable, Sendable {
    let id: String
    let displayName: String
    let endpoints: [String]?
    let languages: [String]?
    let isDefault: Bool?
}

struct Reson8CustomModel: Codable, Sendable {
    let id: String
    let name: String
    let description: String?
    let phraseCount: Int?
}

/// How the transcript treats filler words such as "um" and "uh". `natural` sends
/// no `filler_mode`, which is the API's default.
enum Reson8FillerMode: String, CaseIterable, Sendable {
    case natural
    case clean
    case verbatim
}

/// The endpoint for audio that is complete before it is sent: Recorder recordings,
/// file transcriptions and dictations without a live session. Prerecorded costs 1
/// credit per minute and finished 72 seconds of audio in 0.9 s in our tests; realtime
/// costs 2 credits per minute, took 2.0 s and shows the text while it arrives.
enum Reson8RecordingEndpoint: String, CaseIterable, Sendable {
    case prerecorded
    case realtime
}

/// Patterns that describe structured tokens such as order codes, offered as a model of
/// its own so that a profile or workflow can select them where such tokens are spoken.
/// Reson8 advises against applying patterns to every request:
/// https://docs.reson8.dev/speech-to-text/features/patterns/
struct Reson8PatternSet: Codable, Equatable, Identifiable, Sendable {
    static let modelIdPrefix = "patterns:"

    var id: String
    var name: String
    /// One pattern per entry, such as `AMZ[0-9]{6}`.
    var patterns: [String]

    var modelId: String { Self.modelIdPrefix + id }

    /// The patterns as Reson8 takes them, without empty lines.
    var queryValue: String? {
        let patterns = patterns
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return patterns.isEmpty ? nil : patterns.joined(separator: ",")
    }
}

// MARK: - Dictionary Custom Model

/// The custom model that holds the dictionary, and the terms it held after the last sync.
struct Reson8DictionaryModelState: Codable, Equatable, Sendable {
    var modelId: String?
    var terms: [String] = []
}

/// The custom model endpoints the dictionary sync uses.
/// https://docs.reson8.dev/speech-to-text/features/custom-models/
protocol Reson8CustomModelAPI: Sendable {
    /// Creates a model; Reson8 requires at least one phrase.
    func createModel(name: String, description: String, phrases: [String]) async throws -> String
    func addPhrases(_ phrases: [String], toModel modelId: String) async throws
    func deletePhrases(_ phrases: [String], fromModel modelId: String) async throws
}

enum Reson8CustomModelError: Error, Equatable {
    /// The model was deleted, for example in the Reson8 console.
    case modelNotFound
    /// Reson8 creates no model without phrases.
    case noTerms
}

/// Keeps the dictionary in a custom model, so Reson8 gets up to 50,000 terms per request
/// instead of 250 phrases in the query string. Only changes go to Reson8: terms added to
/// or removed from the dictionary since the last sync. Calls run one at a time.
actor Reson8DictionaryModelSync {
    static let modelName = "TypeWhisper Dictionary"
    static let modelDescription = "Dictionary terms from TypeWhisper. TypeWhisper updates this model when the dictionary changes."
    /// Phrases per request; Reson8 documents no limit.
    static let batchSize = 1_000

    private let api: any Reson8CustomModelAPI
    private let persist: @Sendable (Reson8DictionaryModelState) -> Void
    private(set) var state: Reson8DictionaryModelState
    private var running: Task<String, Error>?

    init(
        state: Reson8DictionaryModelState,
        api: any Reson8CustomModelAPI,
        persist: @escaping @Sendable (Reson8DictionaryModelState) -> Void
    ) {
        self.state = state
        self.api = api
        self.persist = persist
    }

    /// The model that holds exactly `terms`, created or updated first when needed.
    func modelId(for terms: [String]) async throws -> String {
        if let running {
            _ = try? await running.value
        }
        if let modelId = state.modelId, Set(state.terms) == Set(terms) {
            return modelId
        }
        let task = Task { try await self.sync(to: terms) }
        running = task
        defer {
            if running == task { running = nil }
        }
        return try await task.value
    }

    /// Forgets a model Reson8 no longer has, so the next sync creates a new one.
    func forget(modelId: String) {
        guard state.modelId == modelId else { return }
        save(Reson8DictionaryModelState())
    }

    func reset() {
        save(Reson8DictionaryModelState())
    }

    private func sync(to terms: [String]) async throws -> String {
        if let modelId = state.modelId {
            do {
                // Each batch is saved once Reson8 applied it, so a sync that fails halfway
                // leaves a state that matches the model and the next sync repairs the rest.
                var synced = state.terms
                let wanted = Set(terms)
                for batch in Self.batches(state.terms.filter { !wanted.contains($0) }) {
                    try await api.deletePhrases(batch, fromModel: modelId)
                    let deleted = Set(batch)
                    synced.removeAll { deleted.contains($0) }
                    save(Reson8DictionaryModelState(modelId: modelId, terms: synced))
                }
                let present = Set(synced)
                for batch in Self.batches(terms.filter { !present.contains($0) }) {
                    try await api.addPhrases(batch, toModel: modelId)
                    synced += batch
                    save(Reson8DictionaryModelState(modelId: modelId, terms: synced))
                }
                save(Reson8DictionaryModelState(modelId: modelId, terms: terms))
                return modelId
            } catch Reson8CustomModelError.modelNotFound {
                save(Reson8DictionaryModelState())
            }
        }

        let batches = Self.batches(terms)
        guard let first = batches.first else { throw Reson8CustomModelError.noTerms }
        let modelId = try await api.createModel(name: Self.modelName, description: Self.modelDescription, phrases: first)
        var synced = first
        save(Reson8DictionaryModelState(modelId: modelId, terms: synced))
        for batch in batches.dropFirst() {
            try await api.addPhrases(batch, toModel: modelId)
            synced += batch
            save(Reson8DictionaryModelState(modelId: modelId, terms: synced))
        }
        return modelId
    }

    private func save(_ newState: Reson8DictionaryModelState) {
        state = newState
        persist(newState)
    }

    private static func batches(_ terms: [String]) -> [[String]] {
        stride(from: 0, to: terms.count, by: batchSize).map {
            Array(terms[$0..<min($0 + batchSize, terms.count)])
        }
    }
}

/// Reson8's custom model endpoints, with the base URL and key at the time of each call.
struct Reson8HTTPCustomModelAPI: Reson8CustomModelAPI {
    /// An authorized request for a path, or nil without a key.
    let makeRequest: @Sendable (_ path: String) -> URLRequest?

    func createModel(name: String, description: String, phrases: [String]) async throws -> String {
        let data = try await send(
            "/v1/custom-model",
            body: ["name": name, "description": description, "phrases": phrases]
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw PluginTranscriptionError.apiError("Reson8 returned no custom model ID")
        }
        return id
    }

    func addPhrases(_ phrases: [String], toModel modelId: String) async throws {
        _ = try await send("/v1/custom-model/\(modelId)/phrases", body: ["phrases": phrases])
    }

    func deletePhrases(_ phrases: [String], fromModel modelId: String) async throws {
        _ = try await send("/v1/custom-model/\(modelId)/phrases/delete", body: ["phrases": phrases])
    }

    private func send(_ path: String, body: [String: Any]) async throws -> Data {
        guard var request = makeRequest(path) else {
            throw PluginTranscriptionError.notConfigured
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await PluginHTTPClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 404:
            throw Reson8CustomModelError.modelNotFound
        default:
            throw PluginTranscriptionError.apiError(
                "Reson8 custom model: HTTP \(httpResponse.statusCode): \(Reson8Plugin.errorMessage(from: data, response: httpResponse))"
            )
        }
    }
}

/// The result of `operation`, or a timeout error after `timeout`. Unlike a task group, it
/// does not wait for an operation that ignores cancellation, such as a sync that should
/// finish in the background.
func reson8Result<T: Sendable>(
    within timeout: Duration,
    of operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let resumer = Reson8OnceResumer<T>()
    return try await withCheckedThrowingContinuation { continuation in
        resumer.set(continuation)
        Task {
            do {
                resumer.resume(with: .success(try await operation()))
            } catch {
                resumer.resume(with: .failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: timeout)
            resumer.resume(with: .failure(PluginTranscriptionError.networkError("Reson8 did not answer in time")))
        }
    }
}

/// The host's turn end block. The host's handler hops to its main actor, so it can be called
/// from any thread.
final class Reson8TurnEndHandler: @unchecked Sendable {
    private let block: () -> Void

    init(_ block: @escaping @convention(block) () -> Void) {
        self.block = block
    }

    func callAsFunction() {
        block()
    }
}

private final class Reson8OnceResumer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(with result: Result<T, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

// MARK: - Transcript Parsing

/// The text, segments and word timings of a prerecorded response.
struct Reson8Transcript {
    let result: PluginStructuredTranscriptionResult
    let words: [PluginWordTiming]

    /// With diarization Reson8 returns one segment per speaker turn, each with its own
    /// `language` and none for the whole response. Each turn becomes a segment with its
    /// speaker label, from which the host builds its speaker transcript and subtitles.
    init(json: [String: Any], requestedLanguage: String?) {
        guard let speakerSegments = json["segments"] as? [[String: Any]], !speakerSegments.isEmpty else {
            let words = Self.words(from: json["words"])
            self.words = words
            result = PluginStructuredTranscriptionResult(
                text: (json["text"] as? String) ?? "",
                detectedLanguage: Reson8Plugin.detectedLanguage(json["language"] as? String, requested: requestedLanguage),
                segments: Self.sentenceSegments(from: words)
            )
            return
        }

        var words: [PluginWordTiming] = []
        var segments: [PluginStructuredTranscriptionSegment] = []
        for speakerSegment in speakerSegments {
            let text = ((speakerSegment["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let segmentWords = Self.words(from: speakerSegment["words"])
            words += segmentWords
            guard !text.isEmpty else { continue }
            let start = segmentWords.first?.start ?? ((speakerSegment["start_ms"] as? Double) ?? 0) / 1000
            let end = segmentWords.last?.end
                ?? start + ((speakerSegment["duration_ms"] as? Double) ?? 0) / 1000
            segments.append(PluginStructuredTranscriptionSegment(
                text: text,
                start: start,
                end: end,
                speakerLabel: (speakerSegment["speaker_id"] as? Int).map { "Speaker \($0 + 1)" }
            ))
        }
        self.words = words
        let detected = Self.mostFrequentLanguage(speakerSegments.compactMap { $0["language"] as? String })
        result = PluginStructuredTranscriptionResult(
            text: Self.unlabeledText(of: segments),
            detectedLanguage: Reson8Plugin.detectedLanguage(detected, requested: requestedLanguage),
            segments: segments
        )
    }

    /// The host cannot tell a dictation from a recording, and dictated text must not
    /// start with "Speaker 1:", so the labels stay on the segments only. Unlike the
    /// "Speaker N: text" lines of AssemblyAI and Microsoft AI.
    static func unlabeledText(of segments: [PluginStructuredTranscriptionSegment]) -> String {
        segments.map(\.text).joined(separator: " ")
    }

    /// The language most utterances were detected as; the earliest one wins a tie.
    /// Same as PluginAudioChunking's private helper.
    static func mostFrequentLanguage(_ languages: [String]) -> String? {
        var counts: [String: Int] = [:]
        for language in languages where !language.isEmpty {
            counts[language, default: 0] += 1
        }
        return languages.filter { !$0.isEmpty }.max { counts[$0, default: 0] < counts[$1, default: 0] }
    }

    static func words(from value: Any?) -> [PluginWordTiming] {
        (value as? [[String: Any]] ?? []).compactMap { word in
            guard let text = word["text"] as? String,
                  let start = word["start_ms"] as? Double,
                  let duration = word["duration_ms"] as? Double else {
                return nil
            }
            return PluginWordTiming(text: text, start: start / 1000, end: (start + duration) / 1000)
        }
    }

    // Segmentation follows ElevenLabsTimedTranscriptParser. Reson8 returns words with
    // their punctuation, and only for Resonant-1, whose languages separate words with
    // spaces, so the words are joined with one.

    /// A silence longer than this starts a new segment.
    static let pauseThreshold: TimeInterval = 1.0
    /// A sentence end splits only after this many words, so short answers
    /// such as "Yes." join the next sentence instead of standing alone.
    static let minimumSentenceWordCount = 3
    /// A segment without sentence end or pause is split at the next word
    /// after this length, like the 30-second windows of Whisper.
    static let maximumSegmentDuration: TimeInterval = 30

    private static let sentenceEndCharacters: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "؟", "।"]
    private static let trailingClosers: Set<Character> = ["\"", "'", "”", "’", "»", "«", ")", "]", "」", "』"]

    /// Splits words into subtitle-sized segments.
    static func sentenceSegments(from words: [PluginWordTiming]) -> [PluginStructuredTranscriptionSegment] {
        var segments: [PluginStructuredTranscriptionSegment] = []
        var current: [PluginWordTiming] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(PluginStructuredTranscriptionSegment(
                text: current.map(\.text).joined(separator: " "),
                start: first.start,
                end: last.end
            ))
            current = []
        }

        for word in words {
            if let first = current.first, let last = current.last,
               word.start - last.end > pauseThreshold || word.end - first.start > maximumSegmentDuration {
                close()
            }
            current.append(word)
            if current.count >= minimumSentenceWordCount, endsSentence(word.text) {
                close()
            }
        }
        close()
        return segments
    }

    private static func endsSentence(_ word: String) -> Bool {
        var trimmed = Substring(word)
        while let last = trimmed.last, trailingClosers.contains(last) {
            trimmed = trimmed.dropLast()
        }
        return trimmed.last.map(sentenceEndCharacters.contains) ?? false
    }
}

// MARK: - Plugin Entry Point

@objc(Reson8Plugin)
final class Reson8Plugin: NSObject,
    StructuredLanguageHintTranscriptionEnginePlugin,
    LanguageHintTranscriptionEnginePlugin,
    LiveLanguageHintTranscriptionCapablePlugin,
    LiveTranscriptionModelSupportProviding,
    LiveTranscriptionProgressModeProviding,
    TranscriptPreviewFallbackPolicyProviding,
    DictionaryTermsCapabilityProviding,
    DictionaryTermsBudgetProviding,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.reson8"
    static let pluginName = "Reson8"
    private static let logger = Logger(subsystem: "com.typewhisper.reson8", category: "Plugin")
    fileprivate static let defaultModelSentinel = "__default__"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _customBaseURL: String?
    fileprivate var _customAuthHeader: String?
    fileprivate var _fetchedModels: [Reson8Model] = []
    fileprivate var _fetchedCustomModels: [Reson8CustomModel] = []
    /// The settings fetch the models on their own once per activation.
    fileprivate var _didRefreshModelsOnAppear = false
    fileprivate var _fillerMode: Reson8FillerMode = .natural
    /// Nil keeps Reson8's default.
    fileprivate var _biasStrength: Double?
    fileprivate static let defaultBiasStrength = 0.45
    fileprivate var _diarizationEnabled = false
    /// Nil lets Reson8 determine the number of speakers.
    fileprivate var _maxSpeakers: Int?
    /// Reson8 tells up to eight speakers apart per request.
    fileprivate static let maximumSpeakerCount = 8
    fileprivate static let automaticSpeakerCount = 0
    fileprivate var _recordingEndpoint: Reson8RecordingEndpoint = .prerecorded
    fileprivate var _dictionaryModelEnabled = false
    fileprivate var _patternSets: [Reson8PatternSet] = []
    fileprivate var _endsDictationAtTurnEnd = false
    /// The host's handler for the end of each turn in the live session created next.
    private let turnEndHandler = OSAllocatedUnfairLock<Reson8TurnEndHandler?>(initialState: nil)
    /// The dictionary's custom model as last synced, for the model list and the settings.
    private let dictionaryModelState = OSAllocatedUnfairLock(initialState: Reson8DictionaryModelState())
    /// Set up on activation with Reson8's custom model endpoints.
    private(set) var dictionaryModelSync: Reson8DictionaryModelSync?
    /// How long a transcription waits for the dictionary's custom model before it sends
    /// the terms as phrases instead; the sync goes on in the background.
    static let dictionaryModelTimeout: Duration = .seconds(5)

    private static let defaultBaseURL = "https://api.reson8.dev"

    /// Query parameters a model rejects, as https://docs.reson8.dev/speech-to-text/models/
    /// lists them; `GET /v1/model` does not. Models not listed take every parameter.
    private static let unsupportedParameters: [String: Set<String>] = [
        "rumble-2-flash": [
            "diarize", "include_timestamps", "include_words", "phrases",
            "custom_model_id", "patterns", "filler_mode",
        ],
    ]

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
        _fillerMode = (host.userDefault(forKey: "fillerMode") as? String)
            .flatMap(Reson8FillerMode.init(rawValue:)) ?? .natural
        _biasStrength = host.userDefault(forKey: "biasStrength") as? Double
        _diarizationEnabled = host.userDefault(forKey: "speakerDiarizationEnabled") as? Bool ?? false
        _maxSpeakers = (host.userDefault(forKey: "maxSpeakers") as? Int)
            .flatMap { (1...Self.maximumSpeakerCount).contains($0) ? $0 : nil }
        if let data = host.userDefault(forKey: "fetchedModels") as? Data,
           let models = try? JSONDecoder().decode([Reson8Model].self, from: data) {
            _fetchedModels = models
        }
        if let data = host.userDefault(forKey: "fetchedCustomModels") as? Data,
           let models = try? JSONDecoder().decode([Reson8CustomModel].self, from: data) {
            _fetchedCustomModels = models
        }
        _recordingEndpoint = (host.userDefault(forKey: "recordingEndpoint") as? String)
            .flatMap(Reson8RecordingEndpoint.init(rawValue:)) ?? .prerecorded
        _dictionaryModelEnabled = host.userDefault(forKey: "dictionaryModelEnabled") as? Bool ?? false
        _endsDictationAtTurnEnd = host.userDefault(forKey: "endsDictationAtTurnEnd") as? Bool ?? false
        if let data = host.userDefault(forKey: "patternSets") as? Data,
           let sets = try? JSONDecoder().decode([Reson8PatternSet].self, from: data) {
            _patternSets = sets
        }
        let modelState = (host.userDefault(forKey: "dictionaryModel") as? Data)
            .flatMap { try? JSONDecoder().decode(Reson8DictionaryModelState.self, from: $0) }
            ?? Reson8DictionaryModelState()
        dictionaryModelState.withLock { $0 = modelState }
        useCustomModelAPI(Reson8HTTPCustomModelAPI { [weak self] path in self?.customModelRequest(path: path) })
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

    /// The default model keeps the sentinel ID so saved selections stay valid, then
    /// come the other models Reson8 lists, the custom models and the pattern sets, which
    /// run on the default model. The custom model that holds the dictionary is left out.
    var transcriptionModels: [PluginModelInfo] {
        let defaultName = defaultModel?.displayName
            ?? String(localized: "Default model", bundle: Bundle(for: Reson8Plugin.self))
        let defaultLanguageCount = supportedLanguages(forModelId: Self.defaultModelSentinel).count
        var list: [PluginModelInfo] = [
            PluginModelInfo(id: Self.defaultModelSentinel, displayName: defaultName, languageCount: defaultLanguageCount)
        ]
        list.append(contentsOf: _fetchedModels.filter { $0.isDefault != true }.map {
            PluginModelInfo(id: $0.id, displayName: $0.displayName, languageCount: $0.languages?.count ?? 0)
        })
        list.append(contentsOf: customModels.map {
            PluginModelInfo(id: $0.id, displayName: $0.name, languageCount: defaultLanguageCount)
        })
        list.append(contentsOf: _patternSets.map {
            PluginModelInfo(id: $0.modelId, displayName: Self.displayName(of: $0), languageCount: defaultLanguageCount)
        })
        return list
    }

    /// The custom models to choose from, without the one that holds the dictionary.
    fileprivate var customModels: [Reson8CustomModel] {
        let dictionaryModelId = dictionaryModelState.withLock { $0.modelId }
        return _fetchedCustomModels.filter { $0.id != dictionaryModelId }
    }

    fileprivate static func displayName(of patternSet: Reson8PatternSet) -> String {
        let bundle = Bundle(for: Reson8Plugin.self)
        let name = patternSet.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return String(localized: "Pattern set", bundle: bundle) }
        return String(localized: "\(name) (patterns)", bundle: bundle)
    }

    fileprivate func patternSet(forModelId modelId: String?) -> Reson8PatternSet? {
        guard let modelId, modelId.hasPrefix(Reson8PatternSet.modelIdPrefix) else { return nil }
        return _patternSets.first { $0.modelId == modelId }
    }

    private var defaultModel: Reson8Model? {
        _fetchedModels.first { $0.isDefault == true }
    }

    /// The listed model a selection transcribes with. The default selection and
    /// custom models use the default model.
    private func model(forModelId modelId: String?) -> Reson8Model? {
        _fetchedModels.first { $0.isDefault != true && $0.id == modelId } ?? defaultModel
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { false }

    /// Transcribes through the realtime endpoint, live while the user speaks, when the
    /// selected model streams.
    var supportsStreaming: Bool {
        supportsLiveTranscriptionSession(forModelId: nil)
    }

    /// Labels speakers when the user turned it on and the model can.
    private func diarizes(forModelId modelId: String?) -> Bool {
        _diarizationEnabled && supportsParameter("diarize", forModelId: modelId)
    }

    /// Word timings feed the host's subtitles, speaker alignment and playback.
    private var includesWordTimings: Bool {
        supportsParameter("include_timestamps", forModelId: _selectedModelId)
            && supportsParameter("include_words", forModelId: _selectedModelId)
    }

    // MARK: - Dictionary Terms

    /// The host sends the dictionary in `prompt`; it goes to Reson8 as `phrases` or into
    /// the dictionary's custom model.
    var dictionaryTermsSupport: DictionaryTermsSupport {
        takesDictionaryTerms(forModelId: _selectedModelId) ? .supported : .unsupported
    }

    /// Reson8 takes up to 250 phrases of up to 255 characters per request. The host
    /// counts characters; terms outside ASCII take more room once percent-encoded and
    /// are cut further in `phrasesQueryItem(prompt:)`. A custom model holds up to 50,000.
    var dictionaryTermsBudget: DictionaryTermsBudget {
        _dictionaryModelEnabled ? Self.customModelBudget : Self.phrasesBudget
    }

    private static let phrasesBudget = DictionaryTermsBudget(
        maxTerms: 250,
        maxCharsPerTerm: 255,
        maxTotalChars: maximumPhrasesCharacterCount
    )
    static let customModelBudget = DictionaryTermsBudget(maxTerms: 50_000, maxCharsPerTerm: 255)

    // Lets the host resolve dictionary support for a per-flow model override, looked up
    // through the Objective-C runtime like `supportedLanguagesForModelId:`.
    @objc(supportsDictionaryTermsForModelId:)
    func supportsDictionaryTerms(forModelId modelId: String?) -> NSNumber {
        NSNumber(value: takesDictionaryTerms(forModelId: modelId))
    }

    /// Patterns cannot be combined with phrases or a custom model.
    fileprivate func takesDictionaryTerms(forModelId modelId: String?) -> Bool {
        supportsParameter("phrases", forModelId: modelId) && patternSet(forModelId: modelId) == nil
    }

    /// The dictionary goes into its custom model when the user turned that on and the
    /// request has no custom model of its own: Resonant-1 without a custom model the user
    /// selected, or another listed model that takes one.
    fileprivate func usesDictionaryModel(forModelId modelId: String?) -> Bool {
        guard _dictionaryModelEnabled,
              takesDictionaryTerms(forModelId: modelId),
              supportsParameter("custom_model_id", forModelId: modelId) else {
            return false
        }
        guard let modelId, modelId != Self.defaultModelSentinel else { return true }
        return _fetchedModels.contains { $0.id == modelId }
    }

    /// The dictionary's custom model for a request, created or updated first when the
    /// dictionary changed. Nil sends the terms as phrases: when the custom model is off or
    /// does not apply, the prompt holds no terms, or Reson8 could not update it in time.
    /// Without terms the model stays as it is, since a cloud text restriction also
    /// withholds them.
    private func dictionaryModelId(prompt: String?) async -> String? {
        guard usesDictionaryModel(forModelId: _selectedModelId), let sync = dictionaryModelSync else { return nil }
        let terms = PluginDictionaryTerms.clippedTerms(
            from: PluginDictionaryTerms.terms(fromPrompt: prompt),
            budget: Self.customModelBudget
        )
        guard !terms.isEmpty else { return nil }
        do {
            return try await reson8Result(within: Self.dictionaryModelTimeout) {
                try await sync.modelId(for: terms)
            }
        } catch {
            Self.logger.warning("Dictionary custom model unavailable, sending phrases: \(error.localizedDescription)")
            return nil
        }
    }

    /// Reson8 answers a request for a custom model it no longer has with 400 and
    /// "Unknown vocabulary: <id>".
    private static func isUnknownModelError(_ error: Error, modelId: String?) -> Bool {
        guard let modelId else { return false }
        return error.localizedDescription.contains(modelId)
    }

    fileprivate func customModelRequest(path: String) -> URLRequest? {
        guard let apiKey = _apiKey, !apiKey.isEmpty,
              let url = URL(string: "\(effectiveBaseURL)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue(authHeaderValue(apiKey: apiKey), forHTTPHeaderField: effectiveAuthHeader)
        return request
    }

    /// The endpoints the dictionary sync calls; tests pass a fake.
    func useCustomModelAPI(_ api: any Reson8CustomModelAPI) {
        dictionaryModelSync = Reson8DictionaryModelSync(
            state: dictionaryModelState.withLock { $0 },
            api: api,
            persist: { [weak self] state in self?.saveDictionaryModelState(state) }
        )
    }

    private func saveDictionaryModelState(_ state: Reson8DictionaryModelState) {
        dictionaryModelState.withLock { $0 = state }
        if let data = try? JSONEncoder().encode(state) {
            host?.setUserDefault(data, forKey: "dictionaryModel")
        }
    }

    /// Reson8 answers 414 once the query string passes about 4,000 characters, so the
    /// percent-encoded phrases stay well below that.
    private static let maximumEncodedPhrasesLength = 2_500
    /// The same room for ASCII terms, which encode to themselves.
    private static let maximumPhrasesCharacterCount = 2_500

    private static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))

    private func phrasesQueryItem(prompt: String?) -> URLQueryItem? {
        guard takesDictionaryTerms(forModelId: _selectedModelId) else { return nil }
        let terms = PluginDictionaryTerms.clippedTerms(
            from: PluginDictionaryTerms.terms(fromPrompt: prompt),
            budget: Self.phrasesBudget
        )
        var phrases: [String] = []
        var encodedLength = 0
        for term in terms {
            let encodedTerm = term.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed)
            let length = encodedLength + (phrases.isEmpty ? 0 : 1) + (encodedTerm?.count ?? term.utf8.count * 3)
            guard length <= Self.maximumEncodedPhrasesLength else { break }
            phrases.append(term)
            encodedLength = length
        }
        return phrases.isEmpty ? nil : URLQueryItem(name: "phrases", value: phrases.joined(separator: ","))
    }

    var supportedLanguages: [String] {
        supportedLanguages(forModelId: _selectedModelId)
    }

    // Lets the host resolve languages for a per-flow model override. It is looked up through the
    // Objective-C runtime, so the plugin stays loadable by hosts that do not know about it.
    @objc(supportedLanguagesForModelId:)
    func supportedLanguages(forModelId modelId: String?) -> [String] {
        if let languages = model(forModelId: modelId)?.languages, !languages.isEmpty {
            return languages
        }
        return Self.fallbackLanguages
    }

    /// Languages of the default model, for use until the model list was fetched.
    private static let fallbackLanguages = ["nl", "en", "fr", "de", "it", "pl", "pt", "es", "sv"]

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

    /// A listed model goes in `model`, a custom model in `custom_model_id` without
    /// `model`, so it runs on the default model as before. A pattern set runs on the
    /// default model too.
    private func modelQueryItem() -> URLQueryItem? {
        guard let modelId = _selectedModelId,
              modelId != Self.defaultModelSentinel,
              !modelId.isEmpty,
              !modelId.hasPrefix(Reson8PatternSet.modelIdPrefix) else {
            return nil
        }
        if _fetchedModels.contains(where: { $0.id == modelId }) {
            return URLQueryItem(name: "model", value: modelId)
        }
        return URLQueryItem(name: "custom_model_id", value: modelId)
    }

    /// Natural is the API's default and is left out, as is a mode for a model that rejects it.
    private func fillerModeQueryItem() -> URLQueryItem? {
        guard _fillerMode != .natural,
              supportsParameter("filler_mode", forModelId: _selectedModelId) else {
            return nil
        }
        return URLQueryItem(name: "filler_mode", value: _fillerMode.rawValue)
    }

    /// Only phrases and custom models bias the transcription, so the strength goes
    /// along with them.
    private func biasStrengthQueryItem(for queryItems: [URLQueryItem]) -> URLQueryItem? {
        guard let strength = _biasStrength,
              queryItems.contains(where: { $0.name == "custom_model_id" || $0.name == "phrases" }) else {
            return nil
        }
        return URLQueryItem(name: "bias_strength", value: String(format: "%.2f", strength))
    }

    /// Whether the model a selection transcribes with takes `parameter`. Custom models
    /// run on the default model.
    fileprivate func supportsParameter(_ parameter: String, forModelId modelId: String?) -> Bool {
        guard let id = model(forModelId: modelId)?.id else { return true }
        return Self.unsupportedParameters[id]?.contains(parameter) != true
    }

    // MARK: - Transcription

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        Self.legacyResult(from: try await transcribeStructured(
            audio: audio,
            language: language,
            translate: translate,
            prompt: prompt
        ))
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

    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        Self.legacyResult(from: try await transcribeStructured(
            audio: audio,
            languageSelection: languageSelection,
            translate: translate,
            prompt: prompt
        ))
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
        guard transcribesThroughRealtime(duration: audio.duration) else {
            return Self.legacyResult(from: try await transcribeREST(
                audio: audio,
                language: resolved,
                prompt: prompt,
                apiKey: apiKey
            ))
        }

        do {
            return try await transcribeRealtime(
                audio: audio,
                language: resolved,
                prompt: prompt,
                apiKey: apiKey,
                onProgress: onProgress
            )
        } catch {
            // A cancelled transcription does not start over at the other endpoint.
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            Self.logger.warning("Realtime transcription failed, falling back to REST: \(error.localizedDescription)")
            return Self.legacyResult(from: try await transcribeREST(
                audio: audio,
                language: resolved,
                prompt: prompt,
                apiKey: apiKey
            ))
        }
    }

    func transcribeStructured(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginStructuredTranscriptionResult {
        try await transcribeStructured(
            audio: audio,
            languageSelection: PluginLanguageSelection(requestedLanguage: language, languageHints: []),
            translate: translate,
            prompt: prompt
        )
    }

    func transcribeStructured(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginStructuredTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        return try await transcribeREST(
            audio: audio,
            language: Self.resolveLanguage(selection: languageSelection),
            prompt: prompt,
            apiKey: apiKey
        )
    }

    private static func legacyResult(from result: PluginStructuredTranscriptionResult) -> PluginTranscriptionResult {
        PluginTranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            segments: result.segments.map { PluginTranscriptionSegment(text: $0.text, start: $0.start, end: $0.end) }
        )
    }

    /// Whether finished audio goes through the realtime endpoint: when the user chose it
    /// for recordings and files, the selected model streams, and the audio fits one request.
    func transcribesThroughRealtime(duration: TimeInterval) -> Bool {
        _recordingEndpoint == .realtime && supportsStreaming && Self.streamsAudio(ofDuration: duration)
    }

    /// The realtime endpoint takes a recording as one stream and documents no
    /// session length. Longer files go to the prerecorded endpoint, which takes
    /// them in five-minute requests.
    static func streamsAudio(ofDuration duration: TimeInterval) -> Bool {
        duration <= maximumRequestDuration
    }

    /// A requested language pins the transcription. Several hints go as a comma-separated
    /// list, which restricts Reson8's per-utterance auto-detection to them.
    static func resolveLanguage(selection: PluginLanguageSelection) -> String? {
        if let req = selection.requestedLanguage, !req.isEmpty {
            return req
        }
        let hints = selection.languageHints.filter { !$0.isEmpty }
        return hints.isEmpty ? nil : hints.joined(separator: ",")
    }

    /// The language Reson8 detected, or the language the request pinned. Rumble-2-Flash
    /// reports an empty language for a list of languages.
    static func detectedLanguage(_ detected: String?, requested language: String?) -> String? {
        if let detected, !detected.isEmpty {
            return detected
        }
        guard let language, !language.isEmpty, !language.contains(",") else { return nil }
        return language
    }

    // MARK: - Query Parameters

    /// The parameters both endpoints take. Diarization is left to the prerecorded
    /// endpoint, since a diarizing selection does not stream.
    /// Patterns, the dictionary's custom model and phrases exclude each other.
    private func queryItems(language: String?, prompt: String?, dictionaryModelId: String?) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "include_language", value: "true"),
        ]
        if let lang = language, !lang.isEmpty {
            items.append(URLQueryItem(name: "language", value: lang))
        }
        if let modelItem = modelQueryItem() {
            items.append(modelItem)
        }
        if let fillerModeItem = fillerModeQueryItem() {
            items.append(fillerModeItem)
        }
        if let patterns = patternSet(forModelId: _selectedModelId)?.queryValue,
           supportsParameter("patterns", forModelId: _selectedModelId) {
            items.append(URLQueryItem(name: "patterns", value: patterns))
        } else if let dictionaryModelId {
            items.append(URLQueryItem(name: "custom_model_id", value: dictionaryModelId))
        } else if let phrasesItem = phrasesQueryItem(prompt: prompt) {
            items.append(phrasesItem)
        }
        if let biasItem = biasStrengthQueryItem(for: items) {
            items.append(biasItem)
        }
        if includesWordTimings {
            items.append(URLQueryItem(name: "include_timestamps", value: "true"))
            items.append(URLQueryItem(name: "include_words", value: "true"))
        }
        return items
    }

    private func diarizationQueryItems() -> [URLQueryItem] {
        guard diarizes(forModelId: _selectedModelId) else { return [] }
        var items = [URLQueryItem(name: "diarize", value: "true")]
        if let maxSpeakers = _maxSpeakers {
            items.append(URLQueryItem(name: "max_speakers", value: String(maxSpeakers)))
        }
        return items
    }

    /// URLComponents leaves `+` unencoded, which servers read as a space, so a
    /// dictionary term such as "C++" is encoded by hand.
    static func percentEncodedQuery(_ items: [URLQueryItem]) -> String? {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }

    // MARK: - REST Implementation

    private func transcribeREST(
        audio: AudioData,
        language: String?,
        prompt: String?,
        apiKey: String
    ) async throws -> PluginStructuredTranscriptionResult {
        let dictionaryModelId = await dictionaryModelId(prompt: prompt)
        do {
            return try await transcribeREST(
                audio: audio,
                language: language,
                prompt: prompt,
                dictionaryModelId: dictionaryModelId,
                apiKey: apiKey
            )
        } catch where Self.isUnknownModelError(error, modelId: dictionaryModelId) {
            // The dictionary's custom model was deleted, for example in the Reson8 console.
            Self.logger.warning("Dictionary custom model is gone, creating it again")
            if let dictionaryModelId {
                await dictionaryModelSync?.forget(modelId: dictionaryModelId)
            }
            return try await transcribeREST(
                audio: audio,
                language: language,
                prompt: prompt,
                dictionaryModelId: await self.dictionaryModelId(prompt: prompt),
                apiKey: apiKey
            )
        }
    }

    private func transcribeREST(
        audio: AudioData,
        language: String?,
        prompt: String?,
        dictionaryModelId: String?,
        apiKey: String
    ) async throws -> PluginStructuredTranscriptionResult {
        guard var components = URLComponents(string: "\(effectiveBaseURL)/v1/speech-to-text/prerecorded") else {
            throw PluginTranscriptionError.apiError("Invalid base URL: \(effectiveBaseURL)")
        }
        components.percentEncodedQuery = Self.percentEncodedQuery(
            queryItems(language: language, prompt: prompt, dictionaryModelId: dictionaryModelId)
                + diarizationQueryItems()
        )

        guard let url = components.url else {
            throw PluginTranscriptionError.apiError("Failed to construct request URL")
        }
        // Reson8 numbers the speakers anew in every request; the chunks of a
        // longer recording keep their labels under numbers of their own.
        let result = try await PluginAudioChunking.transcribeStructured(
            audio,
            maximumChunkDuration: Self.maximumRequestDuration
        ) { chunk in
            try await transcribeRESTRequest(url: url, samples: chunk.samples, language: language, apiKey: apiKey)
        }
        // PluginAudioChunking writes the labels of a chunked recording into its text.
        guard result.segments.contains(where: { $0.speakerLabel != nil }) else { return result }
        return PluginStructuredTranscriptionResult(
            text: Reson8Transcript.unlabeledText(of: result.segments),
            detectedLanguage: result.detectedLanguage,
            segments: result.segments
        )
    }

    /// The prerecorded endpoint rejects bodies above an undocumented size with
    /// 413 and has to answer within the 60-second request timeout; five
    /// minutes are 9.6 MB as PCM.
    static let maximumRequestDuration: TimeInterval = 300

    private func transcribeRESTRequest(
        url: URL,
        samples: [Float],
        language: String?,
        apiKey: String
    ) async throws -> PluginStructuredTranscriptionResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authHeaderValue(apiKey: apiKey), forHTTPHeaderField: effectiveAuthHeader)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.floatToPCM16(samples)
        request.timeoutInterval = 60

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 400:
            throw PluginTranscriptionError.apiError(
                "Invalid request: \(Self.errorMessage(from: data, response: httpResponse))"
            )
        case 401: throw PluginTranscriptionError.invalidApiKey
        case 402:
            throw PluginTranscriptionError.apiError(
                "Reson8 credit limit reached: \(Self.errorMessage(from: data, response: httpResponse))"
            )
        case 404:
            let subject = url.query?.contains("custom_model_id=") == true ? "Custom model" : "Model"
            throw PluginTranscriptionError.apiError(
                "\(subject) not found: \(Self.errorMessage(from: data, response: httpResponse))"
            )
        case 413: throw PluginTranscriptionError.fileTooLarge
        // Reson8 answers 429 when the account's concurrent connection limit is reached.
        case 429: throw PluginTranscriptionError.rateLimitOrQuota(from: data)
        case 500:
            throw PluginTranscriptionError.apiError(
                "Reson8 server error: \(Self.errorMessage(from: data, response: httpResponse))"
            )
        default:
            let body = PluginHTTPErrorBodyFormatter.summary(from: data, response: httpResponse)
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(body)")
        }

        if let htmlPageSummary = PluginHTTPErrorBodyFormatter.htmlPageSummary(
            from: data,
            response: httpResponse
        ) {
            throw PluginTranscriptionError.apiError(
                "Failed to parse Reson8 response: \(htmlPageSummary)"
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let transcript = Reson8Transcript(json: json, requestedLanguage: language)
        // Times are relative to this request; chunking shifts them.
        PluginWordTimings.report(transcript.words)
        return transcript.result
    }

    // MARK: - Live Sessions

    /// Resonant-1 streams while the user speaks; Rumble-2-Flash transcribes prerecorded
    /// audio only. Before the model list was fetched, the default model is assumed to
    /// stream. Speaker labels need the prerecorded endpoint's segments, so a diarizing
    /// selection does not stream either.
    func supportsLiveTranscriptionSession(forModelId modelId: String?) -> Bool {
        let modelId = modelId ?? _selectedModelId
        guard !diarizes(forModelId: modelId) else { return false }
        return hasRealtimeEndpoint(forModelId: modelId)
    }

    fileprivate func hasRealtimeEndpoint(forModelId modelId: String?) -> Bool {
        model(forModelId: modelId)?.endpoints?.contains("realtime") ?? true
    }

    fileprivate func hasTurnsEndpoint(forModelId modelId: String?) -> Bool {
        model(forModelId: modelId)?.endpoints?.contains("turns") ?? true
    }

    // MARK: - Turn Ends

    // TypeWhisper sets a handler right before it creates a live session for a toggle dictation
    // that stops after silence, and nil right after. Looked up through the Objective-C runtime,
    // so the plugin stays loadable by hosts that do not know about it.
    @objc(setLiveTranscriptionTurnEndHandler:)
    func setLiveTranscriptionTurnEndHandler(_ handler: (@convention(block) () -> Void)?) {
        let box = handler.map(Reson8TurnEndHandler.init)
        turnEndHandler.withLock { $0 = box }
    }

    /// With the setting on and a handler from the host, a live session uses Reson8's turns
    /// endpoint and reports the end of each turn; otherwise the realtime endpoint, whose
    /// preview follows the speech more closely.
    func liveSessionMode(forModelId modelId: String?) -> Reson8RealtimeSession.Mode {
        guard _endsDictationAtTurnEnd,
              hasTurnsEndpoint(forModelId: modelId),
              let handler = turnEndHandler.withLock({ $0 }) else {
            return .realtime
        }
        return .turns(onTurnEnd: handler.callAsFunction)
    }

    /// The final transcripts plus the current interim one cover the whole recording.
    var liveTranscriptionProgressMode: LiveTranscriptionProgressMode { .completeSnapshot }

    /// A live session that cannot start, for example at the concurrent connection limit,
    /// leaves the recording without preview instead of uploading its last seconds again
    /// every few seconds.
    var allowsTranscriptPreviewFallback: Bool {
        !supportsLiveTranscriptionSession(forModelId: nil)
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: PluginLanguageSelection(requestedLanguage: language, languageHints: []),
            translate: translate,
            prompt: prompt,
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard supportsLiveTranscriptionSession(forModelId: nil) else {
            throw PluginTranscriptionError.apiError("The selected Reson8 model does not stream")
        }
        return try await openRealtimeSession(
            language: Self.resolveLanguage(selection: languageSelection),
            prompt: prompt,
            apiKey: apiKey,
            mode: liveSessionMode(forModelId: nil),
            onProgress: onProgress
        )
    }

    // MARK: - Realtime Implementation (Raw RFC 6455)

    /// The realtime endpoint with the parameters both endpoints take, plus interim transcripts.
    func realtimePath(language: String?, prompt: String?, dictionaryModelId: String? = nil) -> String? {
        var components = URLComponents()
        components.path = "/v1/speech-to-text/realtime"
        components.percentEncodedQuery = Self.percentEncodedQuery(
            queryItems(language: language, prompt: prompt, dictionaryModelId: dictionaryModelId)
                + [URLQueryItem(name: "include_interim", value: "true")]
        )
        return components.string
    }

    /// The turns endpoint with the same parameters. A low `eager_turn_probability` sends a
    /// candidate transcript at every pause, so the preview does not wait for the end of the
    /// turn. https://docs.reson8.dev/api/speech-to-text/turns/
    func turnsPath(language: String?, prompt: String?, dictionaryModelId: String? = nil) -> String? {
        var components = URLComponents()
        components.path = "/v1/speech-to-text/turns"
        components.percentEncodedQuery = Self.percentEncodedQuery(
            queryItems(language: language, prompt: prompt, dictionaryModelId: dictionaryModelId)
                + [URLQueryItem(name: "eager_turn_probability", value: "0.05")]
        )
        return components.string
    }

    private func openRealtimeSession(
        language: String?,
        prompt: String?,
        apiKey: String,
        mode: Reson8RealtimeSession.Mode = .realtime,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> Reson8RealtimeSession {
        let dictionaryModelId = await dictionaryModelId(prompt: prompt)
        do {
            return try await openRealtimeSession(
                language: language,
                prompt: prompt,
                dictionaryModelId: dictionaryModelId,
                apiKey: apiKey,
                mode: mode,
                onProgress: onProgress
            )
        } catch where Self.isUnknownModelError(error, modelId: dictionaryModelId) {
            // Reson8 rejects the connection and names the model in `X-Error-Message`.
            Self.logger.warning("Dictionary custom model is gone, creating it again")
            if let dictionaryModelId {
                await dictionaryModelSync?.forget(modelId: dictionaryModelId)
            }
            return try await openRealtimeSession(
                language: language,
                prompt: prompt,
                dictionaryModelId: await self.dictionaryModelId(prompt: prompt),
                apiKey: apiKey,
                mode: mode,
                onProgress: onProgress
            )
        }
    }

    private func openRealtimeSession(
        language: String?,
        prompt: String?,
        dictionaryModelId: String?,
        apiKey: String,
        mode: Reson8RealtimeSession.Mode,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> Reson8RealtimeSession {
        let baseURL = effectiveBaseURL
        guard let urlComponents = URLComponents(string: baseURL),
              let host = urlComponents.host else {
            throw PluginTranscriptionError.apiError("Invalid base URL")
        }
        let path: String?
        switch mode {
        case .realtime:
            path = realtimePath(language: language, prompt: prompt, dictionaryModelId: dictionaryModelId)
        case .turns:
            path = turnsPath(language: language, prompt: prompt, dictionaryModelId: dictionaryModelId)
        }
        guard let path else {
            throw PluginTranscriptionError.apiError("Invalid query parameters")
        }
        let usesTLS = baseURL.hasPrefix("https://")
        let socket = RawWebSocket(
            host: host,
            port: urlComponents.port ?? (usesTLS ? 443 : 80),
            usesTLS: usesTLS,
            path: path,
            headers: [(effectiveAuthHeader, authHeaderValue(apiKey: apiKey))]
        )
        return try await Reson8RealtimeSession.connect(socket: socket, mode: mode, language: language, onProgress: onProgress)
    }

    /// Sends a finished recording through a realtime session, which reports the
    /// transcript while it arrives.
    private func transcribeRealtime(
        audio: AudioData,
        language: String?,
        prompt: String?,
        apiKey: String,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        let session = try await openRealtimeSession(
            language: language,
            prompt: prompt,
            apiKey: apiKey,
            onProgress: onProgress
        )
        do {
            try await session.appendAudio(samples: audio.samples)
            return try await session.finish()
        } catch {
            // Closes the connection before a fallback request, which counts against
            // the same concurrent connection limit.
            await session.cancel()
            throw error
        }
    }

    // MARK: - JSON Error Body Helper

    fileprivate static func errorMessage(
        from data: Data,
        response: HTTPURLResponse? = nil
    ) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let response {
                return PluginHTTPErrorBodyFormatter.summary(from: data, response: response)
            }
            return ""
        }
        let message: String?
        if let code = json["code"] as? String,
           let message = json["message"] as? String {
            return PluginHTTPErrorBodyFormatter.summary(from: "\(code): \(message)")
        }
        message = (json["message"] as? String)
            ?? (json["error"] as? String)
            ?? (json["detail"] as? String)
        if let message {
            return PluginHTTPErrorBodyFormatter.summary(from: message)
        }
        if let response {
            return PluginHTTPErrorBodyFormatter.summary(from: data, response: response)
        }
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

    // MARK: - Models

    /// The models Reson8 offers, or nil when they could not be fetched, so a
    /// failed refresh keeps the models fetched before.
    func fetchModels() async -> [Reson8Model]? {
        await fetchList(path: "/v1/model")
    }

    fileprivate func setFetchedModels(_ models: [Reson8Model]) {
        _fetchedModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: "fetchedModels")
        }
        host?.notifyCapabilitiesChanged()
    }

    // MARK: - Custom Models

    fileprivate func fetchCustomModels() async -> [Reson8CustomModel]? {
        await fetchList(path: "/v1/custom-model")
    }

    // MARK: - Model Catalog

    /// Fetches both lists. A list that cannot be fetched, as after a timeout or from a
    /// proxy without `/v1/model`, keeps the one fetched before, and with it the
    /// selection. A selection that is no longer offered falls back to the default model.
    @MainActor
    func refreshModels() async {
        let models = await fetchModels()
        let customModels = await fetchCustomModels()
        if let models {
            setFetchedModels(models)
        }
        if let customModels {
            setFetchedCustomModels(customModels)
        }
        if let selected = _selectedModelId, !transcriptionModels.contains(where: { $0.id == selected }) {
            selectModel(Self.defaultModelSentinel)
        }
    }

    private func fetchList<Item: Decodable>(path: String) async -> [Item]? {
        guard let apiKey = _apiKey, !apiKey.isEmpty,
              let url = URL(string: "\(effectiveBaseURL)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue(authHeaderValue(apiKey: apiKey), forHTTPHeaderField: effectiveAuthHeader)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try? JSONDecoder().decode([Item].self, from: data)
        } catch {
            return nil
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
        // The next key may belong to another account.
        Task { [dictionaryModelSync] in await dictionaryModelSync?.reset() }
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

    fileprivate func setFillerMode(_ mode: Reson8FillerMode) {
        _fillerMode = mode
        host?.setUserDefault(mode.rawValue, forKey: "fillerMode")
    }

    fileprivate func setDiarizationEnabled(_ enabled: Bool) {
        _diarizationEnabled = enabled
        host?.setUserDefault(enabled, forKey: "speakerDiarizationEnabled")
        // Diarizing turns streaming off.
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setMaxSpeakers(_ count: Int?) {
        _maxSpeakers = count
        host?.setUserDefault(count, forKey: "maxSpeakers")
    }

    fileprivate func setBiasStrength(_ strength: Double) {
        let isDefault = abs(strength - Self.defaultBiasStrength) < 0.001
        _biasStrength = isDefault ? nil : strength
        host?.setUserDefault(_biasStrength, forKey: "biasStrength")
    }

    fileprivate func setRecordingEndpoint(_ endpoint: Reson8RecordingEndpoint) {
        _recordingEndpoint = endpoint
        host?.setUserDefault(endpoint.rawValue, forKey: "recordingEndpoint")
    }

    fileprivate func setEndsDictationAtTurnEnd(_ enabled: Bool) {
        _endsDictationAtTurnEnd = enabled
        host?.setUserDefault(enabled, forKey: "endsDictationAtTurnEnd")
    }

    fileprivate func setDictionaryModelEnabled(_ enabled: Bool) {
        _dictionaryModelEnabled = enabled
        host?.setUserDefault(enabled, forKey: "dictionaryModelEnabled")
        // The dictionary budget changes.
        host?.notifyCapabilitiesChanged()
    }

    /// Saves the pattern sets, which are models, and falls back to the default model when
    /// the selected set was removed.
    fileprivate func setPatternSets(_ sets: [Reson8PatternSet]) {
        _patternSets = sets
        if let data = try? JSONEncoder().encode(sets) {
            host?.setUserDefault(data, forKey: "patternSets")
        }
        if let selected = _selectedModelId,
           selected.hasPrefix(Reson8PatternSet.modelIdPrefix),
           patternSet(forModelId: selected) == nil {
            selectModel(Self.defaultModelSentinel)
        }
        host?.notifyCapabilitiesChanged()
    }

    /// Sends half a second of silence with the patterns, so Reson8 checks them. Nil when
    /// Reson8 accepts them, otherwise its reason, such as invalid syntax or an API client
    /// with a custom model configured, which patterns cannot be combined with.
    fileprivate func checkPatterns(of patternSet: Reson8PatternSet) async -> String? {
        guard let apiKey = _apiKey, !apiKey.isEmpty, let patterns = patternSet.queryValue,
              var components = URLComponents(string: "\(effectiveBaseURL)/v1/speech-to-text/prerecorded") else {
            return nil
        }
        components.percentEncodedQuery = Self.percentEncodedQuery([
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "patterns", value: patterns),
        ])
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authHeaderValue(apiKey: apiKey), forHTTPHeaderField: effectiveAuthHeader)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.floatToPCM16([Float](repeating: 0, count: 8_000))
        request.timeoutInterval = 20
        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return "No HTTP response" }
            return httpResponse.statusCode == 200 ? nil : Self.errorMessage(from: data, response: httpResponse)
        } catch {
            return error.localizedDescription
        }
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
    @State private var fillerMode: Reson8FillerMode = .natural
    @State private var biasStrength = Reson8Plugin.defaultBiasStrength
    @State private var diarizationEnabled = false
    @State private var maxSpeakers = Reson8Plugin.automaticSpeakerCount
    @State private var showAdvanced = false
    @State private var customBaseURL = ""
    @State private var customAuthHeader = ""
    @State private var fetchedCustomModels: [Reson8CustomModel] = []
    @State private var isRefreshingModels = false
    @State private var recordingEndpoint: Reson8RecordingEndpoint = .prerecorded
    @State private var dictionaryModelEnabled = false
    @State private var endsDictationAtTurnEnd = false
    @State private var patternSets: [Reson8PatternSet] = []
    @State private var patternChecks: [String: PatternCheck] = [:]
    private let bundle = Bundle(for: Reson8Plugin.self)

    private enum PatternCheck: Equatable {
        case checking
        case accepted
        case rejected(String)
    }

    private var selectedModelName: String? {
        plugin.transcriptionModels.first { $0.id == selectedModel }?.displayName
    }

    // Settings the selected model cannot use are hidden; their values stay saved for
    // the models that can.
    private var supportsFillerMode: Bool { plugin.supportsParameter("filler_mode", forModelId: selectedModel) }
    private var supportsDiarization: Bool { plugin.supportsParameter("diarize", forModelId: selectedModel) }
    private var supportsDictionaryTerms: Bool { plugin.takesDictionaryTerms(forModelId: selectedModel) }
    private var supportsDictionaryModel: Bool {
        supportsDictionaryTerms && plugin.supportsParameter("custom_model_id", forModelId: selectedModel)
    }
    /// Whether live dictations can end at the end of a turn: the model streams, takes the turns
    /// endpoint and does not diarize.
    private var endsDictationsAtTurnEnds: Bool {
        choosesRecordingEndpoint && plugin.hasTurnsEndpoint(forModelId: selectedModel)
    }

    /// Whether the endpoint choice for finished audio applies: the model streams and does not diarize.
    private var choosesRecordingEndpoint: Bool {
        plugin.hasRealtimeEndpoint(forModelId: selectedModel) && !(diarizationEnabled && supportsDiarization)
    }

    /// What the selected model does without, as a list for the note under the model.
    private var unsupportedFeatureList: String? {
        var features: [String] = []
        if !supportsFillerMode {
            features.append(String(localized: "filler words", bundle: bundle))
        }
        if !supportsDiarization {
            features.append(String(localized: "speaker diarization", bundle: bundle))
        }
        if !supportsDictionaryTerms {
            features.append(String(localized: "dictionary terms", bundle: bundle))
        }
        return features.isEmpty ? nil : features.formatted(.list(type: .and))
    }

    /// Formatted like the slider's value, which follows the region's decimal separator.
    private var defaultBiasStrengthText: String {
        Reson8Plugin.defaultBiasStrength.formatted(.number.precision(.fractionLength(2)))
    }

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
                            .accessibilityLabel(Text("API Key", bundle: bundle))
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(Text("API Key", bundle: bundle))
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showApiKey ? Text("Hide API key", bundle: bundle) : Text("Show API key", bundle: bundle))

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
                        .accessibilityLabel(Text("Remove API key", bundle: bundle))
                    } else {
                        Button(String(localized: "Save", bundle: bundle)) {
                            saveApiKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(Text("Save API key", bundle: bundle))
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
                            .accessibilityHidden(true)
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
                            refreshModels()
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
                        .accessibilityLabel(Text("Refresh models", bundle: bundle))
                    }

                    Picker(String(localized: "Model", bundle: bundle), selection: $selectedModel) {
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectModel(selectedModel)
                        // Models differ in languages and in whether they stream.
                        plugin.host?.notifyCapabilitiesChanged()
                    }

                    if fetchedCustomModels.isEmpty, selectedModel == Reson8Plugin.defaultModelSentinel {
                        Text("No custom models yet — using default model", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let modelName = selectedModelName, let unsupportedFeatures = unsupportedFeatureList {
                        Text("\(modelName) does not support \(unsupportedFeatures).", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if supportsFillerMode {
                    Divider()

                    // Filler Words
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Filler words", bundle: bundle)
                            .font(.headline)

                        Picker(String(localized: "Filler words", bundle: bundle), selection: $fillerMode) {
                            ForEach(Reson8FillerMode.allCases, id: \.self) { mode in
                                Text(mode.displayName(bundle: bundle)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: fillerMode) {
                            plugin.setFillerMode(fillerMode)
                        }

                        Text(fillerMode.explanation(bundle: bundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if supportsDiarization {
                    Divider()

                    // Speaker Diarization
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(String(localized: "Speaker diarization", bundle: bundle), isOn: $diarizationEnabled)
                            .onChange(of: diarizationEnabled) {
                                plugin.setDiarizationEnabled(diarizationEnabled)
                            }

                        if diarizationEnabled {
                            Picker(String(localized: "Maximum speakers", bundle: bundle), selection: $maxSpeakers) {
                                Text("Automatic", bundle: bundle).tag(Reson8Plugin.automaticSpeakerCount)
                                ForEach(1...Reson8Plugin.maximumSpeakerCount, id: \.self) { count in
                                    Text(count, format: .number).tag(count)
                                }
                            }
                            .fixedSize()
                            .onChange(of: maxSpeakers) {
                                plugin.setMaxSpeakers(maxSpeakers == Reson8Plugin.automaticSpeakerCount ? nil : maxSpeakers)
                            }
                        }

                        Text("Reson8 labels who spoke when, up to eight speakers. With Detect Speakers on, recordings and file transcriptions use these labels instead of detecting speakers on this Mac. Dictated text stays without labels. While this is on, transcripts appear once the whole recording is done. Recordings longer than five minutes are labelled in five-minute parts, so one person can appear under several numbers.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if endsDictationsAtTurnEnds {
                    Divider()

                    // End of speech
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(String(localized: "End dictation when you finish speaking", bundle: bundle), isOn: $endsDictationAtTurnEnd)
                            .onChange(of: endsDictationAtTurnEnd) {
                                plugin.setEndsDictationAtTurnEnd(endsDictationAtTurnEnd)
                            }

                        Text("With Stop recording after silence on, Reson8 recognizes when you finished a thought, and a toggle dictation then stops after half the silence duration, at least one second. A pause in the middle of a sentence still waits the full duration. While this is on, the live preview shows your words at pauses rather than while you speak.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if supportsDictionaryModel {
                    Divider()

                    // Dictionary
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(String(localized: "Keep dictionary in a custom model", bundle: bundle), isOn: $dictionaryModelEnabled)
                            .onChange(of: dictionaryModelEnabled) {
                                plugin.setDictionaryModelEnabled(dictionaryModelEnabled)
                            }

                        Text("TypeWhisper keeps your dictionary terms in a custom model named “TypeWhisper Dictionary” in your Reson8 account and updates it when the dictionary changes. Reson8 then takes up to 50,000 terms instead of 250 per request. The model replaces a custom model configured on your API client; with a custom model selected above, the terms go as phrases.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                patternsSection
            }

            Divider()

            // Advanced Section
            DisclosureGroup(String(localized: "Advanced", bundle: bundle), isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    if plugin.isConfigured, choosesRecordingEndpoint {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recordings and files", bundle: bundle)
                                .font(.subheadline)

                            Picker(String(localized: "Recordings and files", bundle: bundle), selection: $recordingEndpoint) {
                                Text("Prerecorded", bundle: bundle).tag(Reson8RecordingEndpoint.prerecorded)
                                Text("Realtime", bundle: bundle).tag(Reson8RecordingEndpoint.realtime)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .onChange(of: recordingEndpoint) {
                                plugin.setRecordingEndpoint(recordingEndpoint)
                            }

                            Text("For the Recorder, file transcriptions and dictations without live preview. Prerecorded costs 1 credit per minute and is faster for finished audio. Realtime costs 2 credits per minute and shows the text while it arrives. Dictations with live preview stream either way.", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if supportsDictionaryTerms {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Bias strength", bundle: bundle)
                                    .font(.subheadline)

                                Spacer()

                                Text(biasStrength, format: .number.precision(.fractionLength(2)))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                if abs(biasStrength - Reson8Plugin.defaultBiasStrength) >= 0.001 {
                                    Button(String(localized: "Reset", bundle: bundle)) {
                                        biasStrength = Reson8Plugin.defaultBiasStrength
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .accessibilityLabel(Text("Reset bias strength", bundle: bundle))
                                }
                            }

                            Slider(value: $biasStrength, in: 0...1, step: 0.05)
                                .onChange(of: biasStrength) {
                                    plugin.setBiasStrength(biasStrength)
                                }
                                .accessibilityLabel(Text("Bias strength", bundle: bundle))

                            Text("How strongly custom models and dictionary terms steer recognition. Higher values recover these terms more often, but can also turn similar-sounding words into them. Default: \(defaultBiasStrengthText).", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom Base URL", bundle: bundle)
                            .font(.subheadline)

                        TextField("https://api.reson8.dev", text: $customBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: customBaseURL) {
                                plugin.setCustomBaseURL(customBaseURL)
                            }
                            .accessibilityLabel(Text("Custom Base URL", bundle: bundle))
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
                            .accessibilityLabel(Text("Custom Auth Header", bundle: bundle))
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
            fillerMode = plugin._fillerMode
            biasStrength = plugin._biasStrength ?? Reson8Plugin.defaultBiasStrength
            diarizationEnabled = plugin._diarizationEnabled
            maxSpeakers = plugin._maxSpeakers ?? Reson8Plugin.automaticSpeakerCount
            customBaseURL = plugin._customBaseURL ?? ""
            customAuthHeader = plugin._customAuthHeader ?? ""
            recordingEndpoint = plugin._recordingEndpoint
            dictionaryModelEnabled = plugin._dictionaryModelEnabled
            endsDictationAtTurnEnd = plugin._endsDictationAtTurnEnd
            patternSets = plugin._patternSets
            showAdvanced = !customBaseURL.isEmpty || !customAuthHeader.isEmpty || plugin._biasStrength != nil
                || recordingEndpoint != .prerecorded
            fetchedCustomModels = plugin.customModels
            // Fetches the models once per activation, so models Reson8 added since and
            // keys saved before the plugin listed models get the current list.
            if plugin.isConfigured, !plugin._didRefreshModelsOnAppear {
                plugin._didRefreshModelsOnAppear = true
                refreshModels()
            }
        }
    }

    // MARK: Patterns

    private var patternsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Patterns", bundle: bundle)
                    .font(.headline)

                Spacer()

                Button {
                    patternSets.append(Reson8PatternSet(id: UUID().uuidString, name: "", patterns: []))
                } label: {
                    Label(String(localized: "Add pattern set", bundle: bundle), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Patterns recover structured tokens such as order codes, reference numbers or licence plates. Each pattern set appears as a model, so a profile or workflow can use it where such tokens are spoken; Reson8 advises against applying patterns everywhere. They replace dictionary terms and do not work with an API client that has a custom model configured.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($patternSets) { $patternSet in
                patternSetEditor($patternSet)
            }

            if !patternSets.isEmpty {
                Text("One pattern per line: [0-9] is a digit, [A-Z] a letter, {n} or {m,n} repeats what comes before, (…)? marks an optional part, and a space or hyphen separates parts. Example: AMZ[0-9]{6}", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: patternSets) { oldSets, newSets in
            // A check applies to the patterns it checked.
            for set in newSets where oldSets.first(where: { $0.id == set.id })?.patterns != set.patterns {
                patternChecks[set.id] = nil
            }
            plugin.setPatternSets(newSets)
        }
    }

    private func patternSetEditor(_ patternSet: Binding<Reson8PatternSet>) -> some View {
        let id = patternSet.wrappedValue.id
        let patternsText = Binding<String>(
            get: { patternSet.wrappedValue.patterns.joined(separator: "\n") },
            set: { patternSet.wrappedValue.patterns = $0.components(separatedBy: "\n") }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(String(localized: "Name", bundle: bundle), text: patternSet.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text("Pattern set name", bundle: bundle))

                Button {
                    patternSets.removeAll { $0.id == id }
                    patternChecks[id] = nil
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Remove pattern set", bundle: bundle))
            }

            TextEditor(text: patternsText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 52)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel(Text("Patterns, one per line", bundle: bundle))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button(String(localized: "Check with Reson8", bundle: bundle)) {
                    checkPatterns(of: patternSet.wrappedValue)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(patternSet.wrappedValue.queryValue == nil || patternChecks[id] == .checking)

                switch patternChecks[id] {
                case .checking:
                    ProgressView().controlSize(.small)
                case .accepted:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Reson8 accepts these patterns.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .rejected(let reason):
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case nil:
                    EmptyView()
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func checkPatterns(of patternSet: Reson8PatternSet) {
        patternChecks[patternSet.id] = .checking
        Task {
            let reason = await plugin.checkPatterns(of: patternSet)
            await MainActor.run {
                // A newer edit cleared the check.
                guard patternChecks[patternSet.id] == .checking else { return }
                patternChecks[patternSet.id] = reason.map(PatternCheck.rejected) ?? .accepted
            }
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
                await plugin.refreshModels()
                await MainActor.run {
                    isValidating = false
                    validationResult = true
                    showRefreshedModels()
                }
            } else {
                await MainActor.run {
                    isValidating = false
                    validationResult = false
                }
            }
        }
    }

    private func refreshModels() {
        isRefreshingModels = true
        Task {
            await plugin.refreshModels()
            await MainActor.run {
                isRefreshingModels = false
                showRefreshedModels()
            }
        }
    }

    private func showRefreshedModels() {
        fetchedCustomModels = plugin.customModels
        selectedModel = plugin.selectedModelId ?? Reson8Plugin.defaultModelSentinel
    }
}

private extension Reson8FillerMode {
    func displayName(bundle: Bundle) -> String {
        switch self {
        case .natural: return String(localized: "Natural", bundle: bundle)
        case .clean: return String(localized: "Clean", bundle: bundle)
        case .verbatim: return String(localized: "Verbatim", bundle: bundle)
        }
    }

    // Follows https://docs.reson8.dev/speech-to-text/features/filler-words/
    func explanation(bundle: Bundle) -> String {
        switch self {
        case .natural:
            return String(localized: "Default. The model gets no instruction, so filler words such as “um” may appear in some places and be left out in others.", bundle: bundle)
        case .clean:
            return String(localized: "Leaves filler words such as “um” and “uh” out of the transcript. Suits dictation, notes and text that is processed further.", bundle: bundle)
        case .verbatim:
            return String(localized: "Transcribes filler words as they are spoken. Suits transcripts that must reflect exactly what was said, such as interviews.", bundle: bundle)
        }
    }
}
