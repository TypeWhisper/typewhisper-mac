import Foundation
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "WorkflowSegmentedPostProcessing"
)

/// Sends one prepared segment through the workflow LLM and returns its output.
typealias WorkflowSegmentProcessor = @MainActor @Sendable (String) async throws -> String

/// FIFO limit for concurrent segment requests of one dictation.
@MainActor
final class WorkflowSegmentRequestLimiter {
    private let limit: Int
    private var activeCount = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func run<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id)
            }
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            activeCount -= 1
            return
        }
        // Hand the slot directly to the next waiter.
        waiters.removeFirst().continuation.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

enum WorkflowSegmentedPostProcessing {
    /// Processes `inputs` with at most `maximumConcurrentRequests` requests in flight
    /// and returns the outputs in input order. The first failure cancels the rest.
    @MainActor
    static func processConcurrently(
        _ inputs: [String],
        maximumConcurrentRequests: Int,
        processor: @escaping WorkflowSegmentProcessor
    ) async throws -> [String] {
        try await collectInOrder(
            count: inputs.count,
            maximumConcurrentOperations: maximumConcurrentRequests
        ) { index in
            try await processor(inputs[index])
        }
    }

    /// Runs `operation` for every index below `count` with at most
    /// `maximumConcurrentOperations` in flight and returns the results in index order.
    /// The first failure, or cancellation of the caller, is returned immediately:
    /// started operations are cancelled but not awaited, because a provider request
    /// that ignores cancellation must not hold up the whole-text fallback. Results
    /// that arrive afterwards are ignored.
    @MainActor
    static func collectInOrder(
        count: Int,
        maximumConcurrentOperations: Int,
        operation: @escaping @MainActor @Sendable (Int) async throws -> String
    ) async throws -> [String] {
        guard count > 0 else { return [] }
        try Task.checkCancellation()
        let run = WorkflowSegmentRun(
            count: count,
            width: maximumConcurrentOperations,
            operation: operation
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                run.start(continuation)
            }
        } onCancel: {
            Task { @MainActor in
                run.fail(CancellationError())
            }
        }
    }
}

/// One `collectInOrder` call. Resolves its continuation exactly once: with all
/// outputs, or with the first failure, after which it cancels every started
/// operation, starts no further ones, and ignores late results.
@MainActor
private final class WorkflowSegmentRun {
    private let count: Int
    private let width: Int
    private let operation: @MainActor @Sendable (Int) async throws -> String
    private var outputs: [String?]
    private var remainingCount: Int
    private var nextIndex = 0
    private var tasks: [Task<Void, Never>] = []
    private var continuation: CheckedContinuation<[String], Error>?
    private var isResolved = false

    init(count: Int, width: Int, operation: @escaping @MainActor @Sendable (Int) async throws -> String) {
        self.count = count
        self.width = max(1, width)
        self.operation = operation
        self.outputs = Array(repeating: nil, count: count)
        self.remainingCount = count
    }

    func start(_ continuation: CheckedContinuation<[String], Error>) {
        guard !isResolved else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        while nextIndex < min(width, count) {
            startNext()
        }
    }

    func fail(_ error: Error) {
        guard !isResolved else { return }
        isResolved = true
        for task in tasks {
            task.cancel()
        }
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func startNext() {
        guard !isResolved, nextIndex < count else { return }
        let index = nextIndex
        nextIndex += 1
        let operation = self.operation
        tasks.append(Task { @MainActor [weak self] in
            do {
                let output = try await operation(index)
                self?.succeed(index, output: output)
            } catch {
                self?.fail(error)
            }
        })
    }

    private func succeed(_ index: Int, output: String) {
        guard !isResolved else { return }
        outputs[index] = output
        remainingCount -= 1
        guard remainingCount == 0 else {
            startNext()
            return
        }
        isResolved = true
        continuation?.resume(returning: outputs.map { $0 ?? "" })
        continuation = nil
    }
}

/// Runs the workflow LLM on the stable part of a streaming transcript while the
/// user is still speaking. Owned by exactly one dictation session: its requests
/// only ever write into this object, so late results cannot reach a newer session.
@MainActor
final class WorkflowIncrementalPostProcessingSession {
    enum DiscardReason: String, Sendable {
        case configurationChanged
        case transcriptRevised
        case finalTranscriptMismatch
        case noStableSegments
        case cancelled
        case alreadyFinished
    }

    struct Statistics: Equatable, Sendable {
        let reusedSegmentCount: Int
        let segmentsCompletedBeforeStop: Int
        let tailSegmentCount: Int
        let tailLength: Int
    }

    enum FinishOutcome {
        case processed(text: String, statistics: Statistics)
        case notReusable(DiscardReason)
    }

    private enum State {
        case collecting
        case discarded(DiscardReason)
        case failed(Error)
        case finishing
        case finished
    }

    private struct Entry {
        let input: String
        var separator: String
        let task: Task<String, Error>
    }

    let request: WorkflowLLMRequest
    let policy: WorkflowSegmentationPolicy
    private let limiter: WorkflowSegmentRequestLimiter
    private let prepareInput: @MainActor (String) -> String
    private let processor: WorkflowSegmentProcessor
    private var state: State = .collecting
    /// Confirmed transcript text already handed to segments, including separators.
    private var committedSourceText = ""
    private var leadingWhitespace = ""
    private var entries: [Entry] = []
    private var completedSegmentCount = 0

    /// - Parameters:
    ///   - request: The LLM request every segment is sent with.
    ///   - prepareInput: Turns confirmed transcript text into the text the LLM step
    ///     would receive for it (the post-processing steps that run before the LLM).
    ///   - processor: Sends one prepared segment through the workflow provider path.
    init(
        request: WorkflowLLMRequest,
        policy: WorkflowSegmentationPolicy = .default,
        prepareInput: @escaping @MainActor (String) -> String,
        processor: @escaping WorkflowSegmentProcessor
    ) {
        self.request = request
        self.policy = policy
        self.limiter = WorkflowSegmentRequestLimiter(limit: policy.maximumConcurrentRequests)
        self.prepareInput = prepareInput
        self.processor = processor
    }

    var committedSegmentCount: Int { entries.count }

    var isCollecting: Bool {
        if case .collecting = state { return true }
        return false
    }

    /// Feeds the latest confirmed transcript. Stable, sentence-aligned text beyond
    /// what was already committed is sent to the LLM in the background.
    func ingest(confirmedText: String) {
        guard case .collecting = state else { return }

        guard let pending = Self.remainder(of: confirmedText, afterExactPrefix: committedSourceText) else {
            // An older snapshot delivered late is a prefix of the committed text.
            if committedSourceText.unicodeScalars.starts(with: confirmedText.unicodeScalars) {
                return
            }
            discard(.transcriptRevised)
            return
        }

        guard let stable = WorkflowTextSegmenter.stablePrefix(in: pending, policy: policy) else { return }
        appendWhitespace(stable.leadingWhitespace)
        for segment in stable.segments {
            enqueue(input: prepareInput(segment.text), separator: segment.separator)
        }
        committedSourceText += stable.consumedText
        logger.info(
            "Incremental workflow post-processing committed segments=\(stable.segments.count, privacy: .public), totalSegments=\(self.entries.count, privacy: .public), committedLength=\(self.committedSourceText.count, privacy: .public)"
        )
    }

    /// Reuses the segments computed during recording when `finalInput` (the final
    /// LLM step input) still starts with exactly their inputs and the request is
    /// unchanged; only the remaining tail is sent now. Throws when a segment fails.
    func finish(finalInput: String, request finalRequest: WorkflowLLMRequest?) async throws -> FinishOutcome {
        switch state {
        case .collecting:
            break
        case .discarded(let reason):
            return .notReusable(reason)
        case .failed(let error):
            state = .finished
            throw error
        case .finishing, .finished:
            return .notReusable(.alreadyFinished)
        }

        guard finalRequest == request else {
            discard(.configurationChanged)
            return .notReusable(.configurationChanged)
        }
        guard !entries.isEmpty else {
            discard(.noStableSegments)
            return .notReusable(.noStableSegments)
        }

        let expectedPrefix = leadingWhitespace + entries.map { $0.input + $0.separator }.joined()
        guard let tail = Self.remainder(of: finalInput, afterExactPrefix: expectedPrefix) else {
            discard(.finalTranscriptMismatch)
            return .notReusable(.finalTranscriptMismatch)
        }

        state = .finishing
        let reusedSegmentCount = entries.count
        let segmentsCompletedBeforeStop = completedSegmentCount
        // A local provider would work through tail chunks one by one anyway.
        let tailSegmentation = WorkflowTextSegmenter.segment(
            tail,
            policy: policy,
            allowsSplitting: !policy.isLocalProvider
        )
        appendWhitespace(tailSegmentation.leadingWhitespace)
        for segment in tailSegmentation.segments {
            enqueue(input: segment.text, separator: segment.separator)
        }

        let tasks = entries.map(\.task)
        let outputs: [String]
        do {
            outputs = try await withTaskCancellationHandler {
                // Awaiting a task's value neither cancels it nor returns early; the
                // catch below cancels the segment requests themselves.
                try await WorkflowSegmentedPostProcessing.collectInOrder(
                    count: tasks.count,
                    maximumConcurrentOperations: tasks.count
                ) { index in
                    try await tasks[index].value
                }
            } onCancel: {
                for task in tasks { task.cancel() }
            }
        } catch {
            cancelSegmentRequests()
            state = .finished
            throw error
        }
        state = .finished

        let text = WorkflowTextSegmenter.join(
            leadingWhitespace: leadingWhitespace,
            pieces: zip(outputs, entries).map { (input: $1.input, output: $0, separator: $1.separator) }
        )
        return .processed(
            text: text,
            statistics: Statistics(
                reusedSegmentCount: reusedSegmentCount,
                segmentsCompletedBeforeStop: segmentsCompletedBeforeStop,
                tailSegmentCount: tailSegmentation.segments.count,
                tailLength: tail.count
            )
        )
    }

    /// Cancels all in-flight and queued segment requests of this session.
    func cancel() {
        switch state {
        case .collecting, .failed:
            discard(.cancelled)
        case .discarded, .finishing, .finished:
            cancelSegmentRequests()
        }
    }

    // MARK: - Private

    private func enqueue(input: String, separator: String) {
        let limiter = self.limiter
        let processor = self.processor
        let task: Task<String, Error> = Task { @MainActor [weak self] in
            do {
                let output: String
                if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output = ""
                } else {
                    output = try await limiter.run { try await processor(input) }
                }
                self?.segmentDidComplete()
                return output
            } catch {
                self?.segmentDidFail(error)
                throw error
            }
        }
        entries.append(Entry(input: input, separator: separator, task: task))
    }

    private func segmentDidComplete() {
        completedSegmentCount += 1
    }

    private func segmentDidFail(_ error: Error) {
        guard case .collecting = state, !isPostProcessingCancellation(error) else { return }
        logger.warning("Incremental workflow post-processing segment failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
        state = .failed(error)
        cancelSegmentRequests()
    }

    private func discard(_ reason: DiscardReason) {
        state = .discarded(reason)
        cancelSegmentRequests()
        logger.info("Incremental workflow post-processing discarded: reason=\(reason.rawValue, privacy: .public), segments=\(self.entries.count, privacy: .public)")
    }

    private func cancelSegmentRequests() {
        for entry in entries {
            entry.task.cancel()
        }
    }

    /// Leading whitespace of a later batch belongs between the previous segment and
    /// the next one, so it extends the previous separator.
    private func appendWhitespace(_ whitespace: String) {
        guard !whitespace.isEmpty else { return }
        if entries.isEmpty {
            leadingWhitespace += whitespace
        } else {
            entries[entries.count - 1].separator += whitespace
        }
    }

    /// The text following `prefix` when `text` starts with exactly the same Unicode
    /// scalars, or nil otherwise.
    static func remainder(of text: String, afterExactPrefix prefix: String) -> String? {
        let scalars = text.unicodeScalars
        let prefixScalars = prefix.unicodeScalars
        guard scalars.starts(with: prefixScalars) else { return nil }
        return String(Substring(scalars.dropFirst(prefixScalars.count)))
    }
}

/// Runs a workflow LLM step with segmentation: reuses incremental results when
/// they are still valid, otherwise splits the final input into concurrent chunks
/// (whole text for local providers), and falls back to the whole-text request
/// when any segment fails.
@MainActor
struct WorkflowSegmentedPostProcessor {
    enum Mode: String, Sendable {
        case wholeText
        case chunked
        case incremental
    }

    struct Report: Equatable, Sendable {
        var mode: Mode
        var inputLength: Int
        var segmentCount: Int
        var reusedSegmentCount = 0
        var segmentsCompletedBeforeStop = 0
        var tailLength = 0
        var incrementalDiscardReason: WorkflowIncrementalPostProcessingSession.DiscardReason?
        var fellBackToWholeText = false
        var localProvider = false

        var logDescription: String {
            "mode=\(mode.rawValue), inputLength=\(inputLength), segments=\(segmentCount), reusedSegments=\(reusedSegmentCount), segmentsDoneBeforeStop=\(segmentsCompletedBeforeStop), tailLength=\(tailLength), incrementalDiscard=\(incrementalDiscardReason?.rawValue ?? "none"), wholeTextFallback=\(fellBackToWholeText), localProvider=\(localProvider)"
        }
    }

    let policy: WorkflowSegmentationPolicy

    init(policy: WorkflowSegmentationPolicy = .default) {
        self.policy = policy
    }

    /// - Parameters:
    ///   - text: The final LLM step input.
    ///   - incrementalSession: Segments computed during recording, if any.
    ///   - incrementalRequest: The request the session's segments must have used.
    ///   - segmentProcessor: Processes one chunk of `text` with the final request.
    ///   - wholeTextProcessor: The existing single-request path for `text`.
    func process(
        text: String,
        incrementalSession: WorkflowIncrementalPostProcessingSession?,
        incrementalRequest: WorkflowLLMRequest?,
        segmentProcessor: @escaping WorkflowSegmentProcessor,
        wholeTextProcessor: @MainActor () async throws -> String
    ) async throws -> (text: String, report: Report) {
        var discardReason: WorkflowIncrementalPostProcessingSession.DiscardReason?

        if let incrementalSession {
            do {
                switch try await incrementalSession.finish(finalInput: text, request: incrementalRequest) {
                case .processed(let output, let statistics):
                    return (output, Report(
                        mode: .incremental,
                        inputLength: text.count,
                        segmentCount: statistics.reusedSegmentCount + statistics.tailSegmentCount,
                        reusedSegmentCount: statistics.reusedSegmentCount,
                        segmentsCompletedBeforeStop: statistics.segmentsCompletedBeforeStop,
                        tailLength: statistics.tailLength,
                        localProvider: incrementalSession.policy.isLocalProvider
                    ))
                case .notReusable(let reason):
                    discardReason = reason
                }
            } catch {
                if Task.isCancelled || isPostProcessingCancellation(error) { throw error }
                logger.warning("Incremental workflow segment failed; using whole-text processing: \(error.localizedDescription, privacy: .private(mask: .hash))")
                return try await wholeText(text, wholeTextProcessor, fellBack: true)
            }
        }

        // Local providers process one request at a time, so chunks only cost context.
        let segmentation = WorkflowTextSegmenter.segment(
            text,
            policy: policy,
            allowsSplitting: !policy.isLocalProvider
        )
        guard segmentation.segments.count > 1 else {
            var result = try await wholeText(text, wholeTextProcessor, fellBack: false)
            result.report.incrementalDiscardReason = discardReason
            return result
        }

        do {
            let outputs = try await WorkflowSegmentedPostProcessing.processConcurrently(
                segmentation.segments.map(\.text),
                maximumConcurrentRequests: policy.maximumConcurrentRequests,
                processor: segmentProcessor
            )
            return (segmentation.joined(outputs: outputs), Report(
                mode: .chunked,
                inputLength: text.count,
                segmentCount: segmentation.segments.count,
                incrementalDiscardReason: discardReason,
                localProvider: policy.isLocalProvider
            ))
        } catch {
            if Task.isCancelled || isPostProcessingCancellation(error) { throw error }
            logger.warning("Workflow segment failed; using whole-text processing: \(error.localizedDescription, privacy: .private(mask: .hash))")
            var result = try await wholeText(text, wholeTextProcessor, fellBack: true)
            result.report.incrementalDiscardReason = discardReason
            return result
        }
    }

    private func wholeText(
        _ text: String,
        _ processor: @MainActor () async throws -> String,
        fellBack: Bool
    ) async throws -> (text: String, report: Report) {
        let output = try await processor()
        return (output, Report(
            mode: .wholeText,
            inputLength: text.count,
            segmentCount: 1,
            fellBackToWholeText: fellBack,
            localProvider: policy.isLocalProvider
        ))
    }
}
