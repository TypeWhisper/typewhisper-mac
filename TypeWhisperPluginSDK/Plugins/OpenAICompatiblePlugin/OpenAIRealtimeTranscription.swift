import Foundation
import os
import TypeWhisperPluginSDK

// MARK: - OpenAI-Compatible Realtime Transcription

// Provider-agnostic protocol support scoped to this plugin bundle so it remains
// loadable against released v1 host SDKs. The caller builds the endpoint-specific
// request; these types own the WebSocket lifecycle, session configuration, PCM
// resampling/encoding, and transcript assembly.

public enum PluginOpenAILiveTranscriptionDelay: String, CaseIterable, Sendable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    public var displayName: String {
        switch self {
        case .minimal:
            "Minimal"
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        case .xhigh:
            "X High"
        }
    }
}

public struct PluginOpenAIRealtimeTranscriptionConfiguration: Sendable {
    public let modelID: String
    public let languageSelection: PluginLanguageSelection
    public let prompt: String?
    public let keywords: [String]
    public let delay: PluginOpenAILiveTranscriptionDelay?
    public let usesContextAwareHints: Bool

    public init(
        modelID: String,
        languageSelection: PluginLanguageSelection,
        prompt: String?,
        keywords: [String],
        delay: PluginOpenAILiveTranscriptionDelay?,
        usesContextAwareHints: Bool
    ) {
        self.modelID = modelID
        self.languageSelection = languageSelection
        self.prompt = prompt
        self.keywords = keywords
        self.delay = delay
        self.usesContextAwareHints = usesContextAwareHints
    }

    public var fallbackLanguage: String? {
        if let requestedLanguage = languageSelection.requestedLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedLanguage.isEmpty {
            return requestedLanguage
        }

        let languages = Self.normalizedLanguages(from: languageSelection)
        return languages.count == 1 ? languages[0] : nil
    }

    public static func normalizedLanguages(from selection: PluginLanguageSelection) -> [String] {
        var seen = Set<String>()
        var languages: [String] = []
        let candidates = [selection.requestedLanguage].compactMap { $0 } + selection.languageHints

        for candidate in candidates {
            let language = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !language.isEmpty else { continue }
            let dedupeKey = language.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }
            languages.append(language)
        }

        return languages
    }

    /// Filters dictionary term hints down to the realtime `keywords` array shape:
    /// deduplicated, and excluding characters (`<`, `>`, `\r`, `\n`) the realtime
    /// transcription protocol does not accept in keyword strings.
    public static func normalizedRealtimeKeywords(from dictionaryTermHints: [PluginDictionaryTermHint]) -> [String] {
        PluginDictionaryTerms.normalizedTermHints(from: dictionaryTermHints)
            .map(\.text)
            .filter { keyword in
                !keyword.contains("<")
                    && !keyword.contains(">")
                    && !keyword.contains("\r")
                    && !keyword.contains("\n")
            }
    }
}

public actor PluginOpenAIRealtimeTranscriptCollector {
    private static let unidentifiedItemID = "__typewhisper_unidentified_item__"

    private var completedOrder: [String] = []
    private var completedTexts: [String: String] = [:]
    private var deltaTexts: [String: String] = [:]
    private var serverError: String?
    private var connectionFailure: String?
    private var sessionReady = false

    public init() {}

    @discardableResult
    public func applyEvent(_ data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid OpenAI realtime event")
        }

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            let itemID = json["item_id"] as? String ?? Self.unidentifiedItemID
            let delta = json["delta"] as? String ?? ""
            deltaTexts[itemID, default: ""].append(delta)
            return currentText()
        case "conversation.item.input_audio_transcription.completed":
            let itemID = json["item_id"] as? String ?? Self.unidentifiedItemID
            let transcript = (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                if completedTexts[itemID] == nil {
                    completedOrder.append(itemID)
                }
                completedTexts[itemID] = transcript
                deltaTexts[itemID] = nil
            }
            return currentText()
        case "session.updated", "transcription_session.updated":
            sessionReady = true
            return nil
        case "conversation.item.input_audio_transcription.failed":
            let message = Self.errorMessage(from: json) ?? "OpenAI realtime transcription failed"
            serverError = message
            throw PluginTranscriptionError.apiError(message)
        case "error":
            let message = Self.errorMessage(from: json) ?? "Unknown OpenAI realtime error"
            serverError = message
            throw PluginTranscriptionError.apiError(message)
        default:
            return nil
        }
    }

    public func currentText() -> String {
        var parts = completedOrder.compactMap { completedTexts[$0] }
        let interim = deltaTexts
            .filter { completedTexts[$0.key] == nil }
            .sorted { $0.key < $1.key }
            .map(\.value)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        parts.append(contentsOf: interim)
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func finalResult(fallbackLanguage: String?) -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: currentText(), detectedLanguage: fallbackLanguage)
    }

    public func recordConnectionFailure(_ message: String) {
        if serverError == nil {
            connectionFailure = message
        }
    }

    public var hasCompletedTranscript: Bool {
        !completedOrder.isEmpty
    }

    public var isSessionReady: Bool {
        sessionReady
    }

    public var error: String? {
        serverError ?? connectionFailure
    }

    private static func errorMessage(from json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String ?? error["type"] as? String
        }
        return json["message"] as? String
    }
}

public final class PluginOpenAIRealtimeWebSocketOpenWaiter: @unchecked Sendable {
    private struct State {
        var opened = false
        var failure: Error?
        var continuations: [CheckedContinuation<Void, Error>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func waitForOpen() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<Void, Error>? in
                    if state.opened {
                        return .success(())
                    }
                    if let failure = state.failure {
                        return .failure(failure)
                    }
                    state.continuations.append(continuation)
                    return nil
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            markFailed(CancellationError())
        }
    }

    public func markOpened() {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            guard !state.opened, state.failure == nil else { return [] }
            state.opened = true
            let continuations = state.continuations
            state.continuations = []
            return continuations
        }
        continuations.forEach { $0.resume() }
    }

    public func markFailed(_ error: Error) {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            guard !state.opened, state.failure == nil else { return [] }
            state.failure = error
            let continuations = state.continuations
            state.continuations = []
            return continuations
        }
        continuations.forEach { $0.resume(throwing: error) }
    }
}

private final class PluginOpenAIRealtimeWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let openWaiter: PluginOpenAIRealtimeWebSocketOpenWaiter

    init(openWaiter: PluginOpenAIRealtimeWebSocketOpenWaiter) {
        self.openWaiter = openWaiter
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        openWaiter.markOpened()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            openWaiter.markFailed(error)
        }
    }
}

/// A `LiveTranscriptionSession` that streams 24 kHz PCM audio to an OpenAI-compatible
/// realtime transcription endpoint over a WebSocket. The plugin supplies a fully
/// formed `URLRequest` containing the endpoint path, query, and authorization.
public final class PluginOpenAIRealtimeTranscriptionSession: LiveTranscriptionSession, @unchecked Sendable {
    public static let sourceSampleRate = 16_000
    public static let targetSampleRate = 24_000
    public static let socketOpenTimeoutNanoseconds: UInt64 = 10_000_000_000
    public static let sessionReadyTimeoutNanoseconds: UInt64 = 3_000_000_000

    private struct State {
        var finished = false
        var cancelled = false
    }

    private let urlSession: URLSession?
    private let webSocketTask: URLSessionWebSocketTask?
    private let receiveTask: Task<Void, Never>?
    private let collector: PluginOpenAIRealtimeTranscriptCollector
    private let fallbackLanguage: String?
    private let onProgress: @Sendable (String) -> Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        urlSession: URLSession? = nil,
        webSocketTask: URLSessionWebSocketTask?,
        receiveTask: Task<Void, Never>?,
        collector: PluginOpenAIRealtimeTranscriptCollector,
        language: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) {
        self.urlSession = urlSession
        self.webSocketTask = webSocketTask
        self.receiveTask = receiveTask
        self.collector = collector
        self.fallbackLanguage = language
        self.onProgress = onProgress
    }

    /// Opens the WebSocket described by `request`, sends the `session.update` event
    /// derived from `configuration`, and waits for the server to confirm the session
    /// before returning. `request` must already carry provider-specific authorization
    /// headers (for example, `Authorization: Bearer <token>` or `api-key: <key>`).
    public static func connect(
        request: URLRequest,
        configuration: PluginOpenAIRealtimeTranscriptionConfiguration,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginOpenAIRealtimeTranscriptionSession {
        let openWaiter = PluginOpenAIRealtimeWebSocketOpenWaiter()
        let delegate = PluginOpenAIRealtimeWebSocketDelegate(openWaiter: openWaiter)
        let urlSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let webSocketTask = urlSession.webSocketTask(with: request)
        let collector = PluginOpenAIRealtimeTranscriptCollector()
        var receiveTask: Task<Void, Never>?

        do {
            webSocketTask.resume()
            try await waitForSocketOpen(openWaiter)

            receiveTask = Task { [webSocketTask, collector, onProgress] in
                do {
                    while !Task.isCancelled {
                        let message = try await webSocketTask.receive()
                        guard let data = Self.data(from: message) else { continue }
                        if let text = try await collector.applyEvent(data), !text.isEmpty {
                            _ = onProgress(text)
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await collector.recordConnectionFailure(realtimeErrorDescription(error))
                }
            }

            try await webSocketTask.send(
                .string(try jsonString(sessionUpdatePayload(configuration: configuration)))
            )
            try await waitForSessionReady(collector)

            return PluginOpenAIRealtimeTranscriptionSession(
                urlSession: urlSession,
                webSocketTask: webSocketTask,
                receiveTask: receiveTask,
                collector: collector,
                language: configuration.fallbackLanguage,
                onProgress: onProgress
            )
        } catch {
            receiveTask?.cancel()
            webSocketTask.cancel(with: .goingAway, reason: nil)
            urlSession.finishTasksAndInvalidate()
            if let collectorError = await collector.error {
                throw PluginTranscriptionError.apiError(collectorError)
            }
            throw error
        }
    }

    private static func waitForSessionReady(_ collector: PluginOpenAIRealtimeTranscriptCollector) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    if await collector.isSessionReady {
                        return
                    }
                    if let error = await collector.error {
                        throw PluginTranscriptionError.apiError(error)
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: sessionReadyTimeoutNanoseconds)
                throw PluginTranscriptionError.networkError("Realtime API did not confirm the transcription session.")
            }

            defer { group.cancelAll() }
            try await group.next()
        }
    }

    public static func sessionUpdatePayload(
        configuration: PluginOpenAIRealtimeTranscriptionConfiguration
    ) -> [String: Any] {
        var transcription: [String: Any] = ["model": configuration.modelID]

        if configuration.usesContextAwareHints {
            let languages = PluginOpenAIRealtimeTranscriptionConfiguration.normalizedLanguages(
                from: configuration.languageSelection
            )
            if !languages.isEmpty {
                transcription["languages"] = languages
            }
            if let prompt = configuration.prompt?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty {
                transcription["prompt"] = prompt
            }
            if !configuration.keywords.isEmpty {
                transcription["keywords"] = configuration.keywords
            }
            if let delay = configuration.delay {
                transcription["delay"] = delay.rawValue
            }
        } else if let language = configuration.languageSelection.requestedLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines),
                  !language.isEmpty {
            transcription["language"] = language
        }

        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": targetSampleRate,
                        ],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
    }

    public static func pcm16DataForRealtime(_ samples: [Float]) -> Data {
        let resampled = resample16kTo24k(samples)
        var data = Data(capacity: resampled.count * MemoryLayout<Int16>.size)
        for sample in resampled {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    public func appendAudio(samples: [Float]) async throws {
        guard !state.withLock({ $0.finished || $0.cancelled }) else { return }
        guard let webSocketTask else { return }
        if let error = await collector.error {
            throw PluginTranscriptionError.apiError(error)
        }
        let data = Self.pcm16DataForRealtime(samples)
        guard !data.isEmpty else { return }
        do {
            try await webSocketTask.send(.string(try Self.jsonString([
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString(),
            ])))
        } catch {
            if let collectorError = await collector.error {
                throw PluginTranscriptionError.apiError(collectorError)
            }
            let message = Self.realtimeErrorDescription(error)
            await collector.recordConnectionFailure(message)
            throw PluginTranscriptionError.networkError(message)
        }
    }

    public func finish() async throws -> PluginTranscriptionResult {
        let shouldFinish = state.withLock { state in
            guard !state.finished else { return false }
            state.finished = true
            return !state.cancelled
        }

        if shouldFinish, let webSocketTask {
            defer {
                receiveTask?.cancel()
                webSocketTask.cancel(with: .normalClosure, reason: nil)
                urlSession?.finishTasksAndInvalidate()
            }
            if !(await collector.hasCompletedTranscript) {
                try? await webSocketTask.send(.string(#"{"type":"input_audio_buffer.commit"}"#))
            }
            try await waitForCompletedTranscript()
        }

        if let error = await collector.error {
            throw PluginTranscriptionError.apiError(error)
        }

        let result = await collector.finalResult(fallbackLanguage: fallbackLanguage)
        if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, webSocketTask != nil {
            throw PluginTranscriptionError.apiError("Realtime API returned no transcript")
        }
        return result
    }

    public func cancel() async {
        let shouldCancel = state.withLock { state in
            guard !state.cancelled else { return false }
            state.cancelled = true
            return true
        }
        guard shouldCancel else { return }
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.finishTasksAndInvalidate()
    }

    private static func waitForSocketOpen(_ waiter: PluginOpenAIRealtimeWebSocketOpenWaiter) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await waiter.waitForOpen()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: socketOpenTimeoutNanoseconds)
                throw PluginTranscriptionError.networkError("Realtime WebSocket did not open.")
            }

            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func waitForCompletedTranscript() async throws {
        for _ in 0..<100 {
            if await collector.hasCompletedTranscript {
                return
            }
            if let error = await collector.error {
                throw PluginTranscriptionError.apiError(error)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PluginTranscriptionError.networkError("Realtime API did not complete the transcript.")
    }

    private static func resample16kTo24k(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let ratio = Double(targetSampleRate) / Double(sourceSampleRate)
        let targetCount = max(1, Int((Double(samples.count) * ratio).rounded()))
        guard samples.count > 1 else {
            return Array(repeating: samples[0], count: targetCount)
        }

        return (0..<targetCount).map { targetIndex in
            let sourcePosition = Double(targetIndex) * Double(sourceSampleRate) / Double(targetSampleRate)
            let lowerIndex = min(Int(sourcePosition.rounded(.down)), samples.count - 1)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            return samples[lowerIndex] + (samples[upperIndex] - samples[lowerIndex]) * fraction
        }
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw PluginTranscriptionError.apiError("Failed to encode realtime event")
        }
        return string
    }

    private static func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .string(let text):
            return text.data(using: .utf8)
        case .data(let data):
            return data
        @unknown default:
            return nil
        }
    }

    private static func realtimeErrorDescription(_ error: Error) -> String {
        if let transcriptionError = error as? PluginTranscriptionError {
            return transcriptionError.localizedDescription
        }
        return error.localizedDescription
    }
}
