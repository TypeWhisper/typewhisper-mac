import Foundation
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

/// Fake workflow LLM with explicit completion control. Requests stay pending until
/// the test completes, fails, or cancels them, so no test depends on timing.
@MainActor
private final class FakeSegmentLLM {
    private(set) var receivedInputs: [String] = []
    private(set) var cancelledInputs: [String] = []
    private(set) var inFlightCount = 0
    private(set) var peakInFlightCount = 0
    /// Inputs listed here complete immediately with the given result.
    var immediateResults: [String: Result<String, Error>] = [:]
    private let respondsImmediately: Bool
    private var pending: [String: CheckedContinuation<Result<String, Error>, Never>] = [:]
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(respondsImmediately: Bool = false) {
        self.respondsImmediately = respondsImmediately
    }

    static func output(for input: String) -> String {
        "<\(input.uppercased())>"
    }

    var processor: WorkflowSegmentProcessor {
        { [self] input in try await self.process(input) }
    }

    func process(_ input: String) async throws -> String {
        receivedInputs.append(input)
        inFlightCount += 1
        peakInFlightCount = max(peakInFlightCount, inFlightCount)
        resumeCallWaiters()
        defer { inFlightCount -= 1 }

        if let result = immediateResults[input] {
            return try result.get()
        }
        if respondsImmediately {
            return Self.output(for: input)
        }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<String, Error>, Never>) in
                pending[input] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(input)
            }
        }
        return try result.get()
    }

    func waitForCalls(_ count: Int) async {
        guard receivedInputs.count < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((count, continuation))
        }
    }

    func isPending(_ input: String) -> Bool {
        pending[input] != nil
    }

    func complete(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation = pending.removeValue(forKey: input) else {
            XCTFail("No pending request for input", file: file, line: line)
            return
        }
        continuation.resume(returning: .success(Self.output(for: input)))
    }

    func fail(_ input: String, with error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation = pending.removeValue(forKey: input) else {
            XCTFail("No pending request for input", file: file, line: line)
            return
        }
        continuation.resume(returning: .failure(error))
    }

    private func cancel(_ input: String) {
        guard let continuation = pending.removeValue(forKey: input) else { return }
        cancelledInputs.append(input)
        continuation.resume(returning: .failure(CancellationError()))
    }

    private func resumeCallWaiters() {
        let ready = callWaiters.filter { $0.count <= receivedInputs.count }
        callWaiters.removeAll { $0.count <= receivedInputs.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

/// Provider request that ignores cancellation and only returns when the test
/// releases it, like a stuck network call without cancellation support.
@MainActor
private final class NonCooperativeRequests {
    private(set) var startedInputs: [String] = []
    /// Inputs whose late result arrived, with whether they had been cancelled.
    private(set) var lateResults: [(input: String, wasCancelled: Bool)] = []
    private var pending: [CheckedContinuation<Void, Never>] = []

    func hang(_ input: String) async -> String {
        startedInputs.append(input)
        await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
        lateResults.append((input, Task.isCancelled))
        return "late \(input)"
    }

    func releaseAll() {
        let continuations = pending
        pending.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

@MainActor
private final class CallRecorder {
    private(set) var inputs: [String] = []

    var count: Int { inputs.count }

    func record(_ input: String) {
        inputs.append(input)
    }
}

private struct ProviderFailure: LocalizedError {
    var errorDescription: String? { "Provider unavailable" }
}

/// LLM provider plugin that only reports whether it needs external credentials.
private final class LocalityTestLLMPlugin: LLMProviderPlugin, LLMProviderSetupStatusProviding, Sendable {
    static var pluginId: String { "com.typewhisper.tests.segmentation-locality" }
    static var pluginName: String { "Segmentation Locality" }

    let providerName: String
    let requiresExternalCredentials: Bool
    var unavailableReason: String? { nil }
    var isAvailable: Bool { true }
    var supportedModels: [PluginModelInfo] { [] }

    init(providerName: String, requiresExternalCredentials: Bool) {
        self.providerName = providerName
        self.requiresExternalCredentials = requiresExternalCredentials
    }

    required convenience init() {
        self.init(providerName: "Unused", requiresExternalCredentials: true)
    }

    func activate(host: HostServices) {}
    func deactivate() {}

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        userText
    }
}

@MainActor
final class WorkflowSegmentedPostProcessingTests: XCTestCase {
    private let smallPolicy = WorkflowSegmentationPolicy(
        targetSegmentLength: 40,
        minimumSegmentLength: 10,
        minimumSplitLength: 60,
        maximumConcurrentRequests: 2,
        incrementalStabilityMargin: 10
    )

    private let request = WorkflowLLMRequest(
        systemPrompt: "Clean up the dictated text.",
        providerId: nil,
        cloudModel: nil,
        temperatureDirective: .inheritProviderSetting,
        effortId: nil
    )

    private let firstSentence = "The first sentence is right here and long."
    private let secondSentence = "Another sentence follows it with more words."
    private let thirdSentence = "A third one is also part of this text now."
    private let tailSentence = "Tail words here."

    // MARK: - Segmenter

    func testShortInputIsNotSplit() {
        let text = "Hello there. This is a short dictation."
        let segmentation = WorkflowTextSegmenter.segment(text)

        XCTAssertEqual(segmentation.segments, [WorkflowTextSegment(text: text, separator: "")])
        XCTAssertEqual(segmentation.source, text)
    }

    func testLongTextSplitsAtSentenceEndsWithoutTextLoss() {
        let sentences = (1...80).map { "Sentence number \($0) talks about the project plan in some detail." }
        let text = sentences.joined(separator: " ")
        let policy = WorkflowSegmentationPolicy.default

        let segmentation = WorkflowTextSegmenter.segment(text, policy: policy)

        XCTAssertGreaterThan(segmentation.segments.count, 1)
        XCTAssertEqual(segmentation.source, text)
        XCTAssertEqual(segmentation.joined(outputs: segmentation.segments.map(\.text)), text)
        for segment in segmentation.segments {
            XCTAssertTrue(segment.text.hasSuffix("detail."))
            XCTAssertTrue(segment.text.hasPrefix("Sentence number"))
            XCTAssertGreaterThanOrEqual(segment.text.count, policy.minimumSegmentLength)
            XCTAssertLessThanOrEqual(segment.text.count, policy.targetSegmentLength * 2)
        }
        for segment in segmentation.segments.dropLast() {
            XCTAssertEqual(segment.separator, " ")
        }
        XCTAssertEqual(segmentation.segments.last?.separator, "")
    }

    func testParagraphSeparatorsArePreserved() {
        let paragraph = String(repeating: "Words keep flowing in this paragraph ", count: 2) + "until it ends"
        let text = [paragraph, paragraph, paragraph, paragraph].joined(separator: "\n\n")

        let segmentation = WorkflowTextSegmenter.segment(text, policy: smallPolicy)

        XCTAssertEqual(segmentation.segments.count, 4)
        XCTAssertEqual(segmentation.segments.dropLast().map(\.separator), ["\n\n", "\n\n", "\n\n"])
        XCTAssertEqual(
            segmentation.joined(outputs: ["A", "B", "C", "D"]),
            "A\n\nB\n\nC\n\nD"
        )
    }

    func testDoesNotSplitAfterAbbreviationsInitialsOrOrdinals() {
        let policy = WorkflowSegmentationPolicy(
            targetSegmentLength: 20,
            minimumSegmentLength: 5,
            minimumSplitLength: 30,
            maximumConcurrentRequests: 2,
            incrementalStabilityMargin: 5
        )
        let text = "We met Dr. Smith and J. Doe today. Das ist z. B. ein Test am 3. Oktober mit Leuten. Ok fine then here."

        let segmentation = WorkflowTextSegmenter.segment(text, policy: policy)

        XCTAssertEqual(segmentation.source, text)
        for segment in segmentation.segments {
            XCTAssertFalse(segment.text.hasSuffix("Dr."))
            XCTAssertFalse(segment.text.hasSuffix("J."))
            XCTAssertFalse(segment.text.hasSuffix("z."))
            XCTAssertFalse(segment.text.hasSuffix("B."))
            XCTAssertFalse(segment.text.hasSuffix("3."))
        }
        XCTAssertEqual(segmentation.segments.map(\.text).first, "We met Dr. Smith and J. Doe today.")
    }

    func testLowercaseContinuationOnlyBlocksSplitsAfterPeriods() {
        let policy = WorkflowSegmentationPolicy(
            targetSegmentLength: 20,
            minimumSegmentLength: 5,
            minimumSplitLength: 30,
            maximumConcurrentRequests: 2,
            incrementalStabilityMargin: 5
        )
        let text = "is this ready for review? yes, it is ready now! then we ship it today. and it goes on etc. and so on"

        let segmentation = WorkflowTextSegmenter.segment(text, policy: policy)

        XCTAssertEqual(segmentation.source, text)
        XCTAssertEqual(segmentation.segments.map(\.text), [
            "is this ready for review?",
            "yes, it is ready now!",
            "then we ship it today. and it goes on etc. and so on"
        ])
    }

    func testCJKSentenceEndsSplitWithoutWhitespace() {
        let sentence = "今天我们讨论了项目的进度和下一步的计划。"
        let text = String(repeating: sentence, count: 12)

        let segmentation = WorkflowTextSegmenter.segment(text, policy: smallPolicy)

        XCTAssertGreaterThan(segmentation.segments.count, 1)
        XCTAssertEqual(segmentation.source, text)
        for segment in segmentation.segments {
            XCTAssertTrue(segment.text.hasSuffix("。"))
            XCTAssertEqual(segment.separator, "")
        }
        XCTAssertEqual(segmentation.joined(outputs: segmentation.segments.map(\.text)), text)
    }

    func testUnicodeTextRoundTripsForManyPolicies() {
        let pieces = [
            "Café au lait, s'il vous plaît! ",
            "Ümlaute wie ä, ö und ü bleiben erhalten. ",
            "Emoji 👩‍👩‍👧‍👦 and flags 🇩🇪 stay whole? ",
            "これは日本語の文です。",
            "مرحبا بالعالم؟ ",
            "Combining e\u{301} accents.\n",
            "\n  Indented paragraph after a blank line. "
        ]
        let text = "  " + String(repeating: pieces.joined(), count: 6) + "\n"

        for target in [15, 40, 90, 200] {
            let policy = WorkflowSegmentationPolicy(
                targetSegmentLength: target,
                minimumSegmentLength: target / 3,
                minimumSplitLength: target + target / 2,
                maximumConcurrentRequests: 3,
                incrementalStabilityMargin: 10
            )
            let segmentation = WorkflowTextSegmenter.segment(text, policy: policy)
            XCTAssertEqual(segmentation.source, text, "target \(target)")
            XCTAssertEqual(segmentation.joined(outputs: segmentation.segments.map(\.text)), text, "target \(target)")
            for segment in segmentation.segments {
                XCTAssertFalse(segment.text.isEmpty)
                XCTAssertEqual(segment.text, segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                XCTAssertTrue(segment.separator.allSatisfy(\.isWhitespace))
            }
        }
    }

    func testJoinTrimsOutputsAndDropsEmptyOutputsWithTheirSeparator() {
        let joined = WorkflowTextSegmenter.join(
            leadingWhitespace: "",
            pieces: [
                (output: " One. \n", separator: " "),
                (output: "   ", separator: "\n\n"),
                (output: "Three.", separator: "")
            ]
        )
        XCTAssertEqual(joined, "One. Three.")

        let allEmpty = WorkflowTextSegmenter.join(
            leadingWhitespace: " ",
            pieces: [(output: "", separator: " "), (output: "\n", separator: "")]
        )
        XCTAssertEqual(allEmpty, "")
    }

    func testStablePrefixWaitsForTargetLengthAndMargin() throws {
        XCTAssertNil(WorkflowTextSegmenter.stablePrefix(in: firstSentence, policy: smallPolicy))
        // The sentence end is too close to the end of the confirmed text.
        XCTAssertNil(WorkflowTextSegmenter.stablePrefix(in: firstSentence + " Anoth", policy: smallPolicy))

        let pending = firstSentence + " " + secondSentence
        let stable = try XCTUnwrap(WorkflowTextSegmenter.stablePrefix(in: pending, policy: smallPolicy))

        XCTAssertEqual(stable.segments, [WorkflowTextSegment(text: firstSentence, separator: " ")])
        XCTAssertEqual(stable.consumedText, firstSentence + " ")
        XCTAssertTrue(pending.hasPrefix(stable.consumedText))
    }

    // MARK: - Concurrent chunks

    func testChunksRunWithConcurrencyLimitAndJoinInOrder() async throws {
        let llm = FakeSegmentLLM()
        let inputs = ["a1", "b2", "c3", "d4", "e5"]
        let processing = Task {
            try await WorkflowSegmentedPostProcessing.processConcurrently(
                inputs,
                maximumConcurrentRequests: 2,
                processor: llm.processor
            )
        }

        await llm.waitForCalls(2)
        XCTAssertEqual(Set(llm.receivedInputs), ["a1", "b2"])
        llm.complete("b2")
        await llm.waitForCalls(3)
        llm.complete("c3")
        await llm.waitForCalls(4)
        llm.complete("a1")
        await llm.waitForCalls(5)
        llm.complete("e5")
        llm.complete("d4")

        let outputs = try await processing.value
        XCTAssertEqual(outputs, inputs.map(FakeSegmentLLM.output(for:)))
        XCTAssertEqual(llm.peakInFlightCount, 2)
    }

    func testChunkFailureCancelsInFlightChunksAndSkipsQueuedOnes() async {
        let llm = FakeSegmentLLM()
        let processing = Task {
            try await WorkflowSegmentedPostProcessing.processConcurrently(
                ["a1", "b2", "c3", "d4"],
                maximumConcurrentRequests: 2,
                processor: llm.processor
            )
        }

        await llm.waitForCalls(2)
        let failing = llm.receivedInputs[0]
        let other = llm.receivedInputs[1]
        llm.fail(failing, with: ProviderFailure())

        do {
            _ = try await processing.value
            XCTFail("Expected the chunk failure to propagate")
        } catch {
            XCTAssertTrue(error is ProviderFailure)
        }
        await waitUntilCancelled(other, llm: llm)
        XCTAssertEqual(llm.cancelledInputs, [other])
        XCTAssertEqual(llm.receivedInputs.count, 2)
    }

    func testCancellingChunkedProcessingCancelsAllRequests() async {
        let llm = FakeSegmentLLM()
        let processing = Task {
            try await WorkflowSegmentedPostProcessing.processConcurrently(
                ["a1", "b2", "c3"],
                maximumConcurrentRequests: 2,
                processor: llm.processor
            )
        }

        await llm.waitForCalls(2)
        processing.cancel()

        do {
            _ = try await processing.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await waitUntil { llm.cancelledInputs.count == 2 }
        XCTAssertEqual(Set(llm.cancelledInputs), Set(llm.receivedInputs))
        XCTAssertEqual(llm.receivedInputs.count, 2)
    }

    // MARK: - Incremental session

    private func makeSession(
        llm: FakeSegmentLLM,
        prepareInput: @escaping @MainActor (String) -> String = { $0 }
    ) -> WorkflowIncrementalPostProcessingSession {
        WorkflowIncrementalPostProcessingSession(
            request: request,
            policy: smallPolicy,
            prepareInput: prepareInput,
            processor: llm.processor
        )
    }

    func testIncrementalSessionReusesSegmentsAndOnlyProcessesTheTail() async throws {
        let llm = FakeSegmentLLM()
        let session = makeSession(llm: llm)

        session.ingest(confirmedText: firstSentence + " Anoth")
        XCTAssertEqual(session.committedSegmentCount, 0)

        session.ingest(confirmedText: firstSentence + " " + secondSentence)
        XCTAssertEqual(session.committedSegmentCount, 1)

        let confirmed = [firstSentence, secondSentence, thirdSentence].joined(separator: " ")
        session.ingest(confirmedText: confirmed)
        XCTAssertEqual(session.committedSegmentCount, 2)

        await llm.waitForCalls(2)
        llm.complete(firstSentence)

        let finalText = confirmed + " " + tailSentence
        let finishing = Task {
            try await session.finish(finalInput: finalText, request: request)
        }
        await llm.waitForCalls(3)
        let tail = thirdSentence + " " + tailSentence
        XCTAssertEqual(llm.receivedInputs, [firstSentence, secondSentence, tail])
        llm.complete(tail)
        llm.complete(secondSentence)

        guard case .processed(let text, let statistics) = try await finishing.value else {
            return XCTFail("Expected reused incremental results")
        }
        XCTAssertEqual(
            text,
            [firstSentence, secondSentence, tail].map(FakeSegmentLLM.output(for:)).joined(separator: " ")
        )
        XCTAssertEqual(statistics.reusedSegmentCount, 2)
        XCTAssertEqual(statistics.tailSegmentCount, 1)
        XCTAssertEqual(statistics.tailLength, tail.count)
        XCTAssertEqual(llm.receivedInputs.count, 3)
    }

    func testIncrementalSessionValidatesPreparedInputPrefix() async throws {
        let llm = FakeSegmentLLM(respondsImmediately: true)
        let prepare: @MainActor (String) -> String = { $0.replacingOccurrences(of: "twenty", with: "20") }
        let session = makeSession(llm: llm, prepareInput: prepare)
        let first = "There were twenty people in the room today."
        let confirmed = first + " " + secondSentence

        session.ingest(confirmedText: confirmed)
        XCTAssertEqual(session.committedSegmentCount, 1)

        // The final LLM input carries the normalized number, like the pipeline would.
        let finalInput = prepare(confirmed) + " " + tailSentence
        guard case .processed(let text, _) = try await session.finish(finalInput: finalInput, request: request) else {
            return XCTFail("Expected reused incremental results")
        }

        let preparedFirst = prepare(first)
        XCTAssertEqual(llm.receivedInputs, [preparedFirst, secondSentence, tailSentence])
        XCTAssertEqual(
            text,
            [preparedFirst, secondSentence, tailSentence].map(FakeSegmentLLM.output(for:)).joined(separator: " ")
        )
    }

    func testIncrementalSessionDiscardsWhenFinalTranscriptDiffers() async throws {
        let llm = FakeSegmentLLM()
        let session = makeSession(llm: llm)
        session.ingest(confirmedText: firstSentence + " " + secondSentence)
        await llm.waitForCalls(1)

        // The final pass re-transcribed the beginning differently.
        let finalInput = "The first sentence is right here, and long. " + secondSentence
        let outcome = try await session.finish(finalInput: finalInput, request: request)

        guard case .notReusable(let reason) = outcome else {
            return XCTFail("Expected mismatch to prevent reuse")
        }
        XCTAssertEqual(reason, .finalTranscriptMismatch)
        await waitUntilCancelled(firstSentence, llm: llm)
    }

    func testIncrementalSessionDiscardsWhenRequestChanged() async throws {
        let llm = FakeSegmentLLM()
        let session = makeSession(llm: llm)
        session.ingest(confirmedText: firstSentence + " " + secondSentence)
        await llm.waitForCalls(1)

        let changedRequest = WorkflowLLMRequest(
            systemPrompt: "Translate the dictated text into German.",
            providerId: nil,
            cloudModel: nil,
            temperatureDirective: .inheritProviderSetting,
            effortId: nil
        )
        let outcome = try await session.finish(
            finalInput: firstSentence + " " + secondSentence,
            request: changedRequest
        )

        guard case .notReusable(let reason) = outcome else {
            return XCTFail("Expected configuration change to prevent reuse")
        }
        XCTAssertEqual(reason, .configurationChanged)
        await waitUntilCancelled(firstSentence, llm: llm)
    }

    func testIncrementalSessionStopsWhenCommittedTextIsRevised() async throws {
        let llm = FakeSegmentLLM()
        let session = makeSession(llm: llm)
        let confirmed = firstSentence + " " + secondSentence
        session.ingest(confirmedText: confirmed)
        XCTAssertEqual(session.committedSegmentCount, 1)
        await llm.waitForCalls(1)

        // A late, older snapshot is a prefix of the committed text and is ignored.
        session.ingest(confirmedText: String(firstSentence.prefix(20)))
        XCTAssertTrue(session.isCollecting)

        session.ingest(confirmedText: "The first sentence was revised by the engine. " + secondSentence)
        XCTAssertFalse(session.isCollecting)

        let outcome = try await session.finish(finalInput: confirmed, request: request)
        guard case .notReusable(let reason) = outcome else {
            return XCTFail("Expected the revision to prevent reuse")
        }
        XCTAssertEqual(reason, .transcriptRevised)
        await waitUntilCancelled(firstSentence, llm: llm)
    }

    func testIncrementalSessionHonorsConcurrencyLimit() async throws {
        let llm = FakeSegmentLLM()
        let session = makeSession(llm: llm)
        let sentences = (1...5).map { "Sentence \($0) has enough words to fill a segment." }
        session.ingest(confirmedText: sentences.joined(separator: " "))
        XCTAssertEqual(session.committedSegmentCount, 4)

        await llm.waitForCalls(2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(llm.receivedInputs.count, 2)
        XCTAssertEqual(llm.inFlightCount, 2)

        llm.complete(llm.receivedInputs[1])
        await llm.waitForCalls(3)
        llm.complete(llm.receivedInputs[0])
        await llm.waitForCalls(4)
        XCTAssertEqual(Set(llm.receivedInputs), Set(sentences.prefix(4)))
        XCTAssertEqual(llm.peakInFlightCount, 2)
        session.cancel()
    }

    func testIncrementalSegmentFailureSurfacesAtFinish() async {
        let llm = FakeSegmentLLM()
        let session = makeSession(llm: llm)
        session.ingest(confirmedText: firstSentence + " " + secondSentence)
        await llm.waitForCalls(1)
        llm.fail(firstSentence, with: ProviderFailure())
        await waitUntil { !session.isCollecting }

        do {
            _ = try await session.finish(finalInput: firstSentence + " " + secondSentence, request: request)
            XCTFail("Expected the segment failure to surface")
        } catch {
            XCTAssertTrue(error is ProviderFailure)
        }
    }

    func testCancellingSessionCancelsInFlightRequestsAndIgnoresLateResults() async throws {
        let llm = FakeSegmentLLM()
        let session = makeSession(llm: llm)
        session.ingest(confirmedText: firstSentence + " " + secondSentence)
        await llm.waitForCalls(1)

        session.cancel()
        await waitUntilCancelled(firstSentence, llm: llm)

        session.ingest(confirmedText: [firstSentence, secondSentence, thirdSentence].joined(separator: " "))
        XCTAssertEqual(session.committedSegmentCount, 1)
        let outcome = try await session.finish(finalInput: firstSentence + " " + secondSentence, request: request)
        guard case .notReusable(let reason) = outcome else {
            return XCTFail("Expected a cancelled session to be unusable")
        }
        XCTAssertEqual(reason, .cancelled)
        XCTAssertEqual(llm.receivedInputs, [firstSentence])
    }

    func testCancellingFinishCancelsSegmentAndTailRequests() async {
        let llm = FakeSegmentLLM()
        let session = makeSession(llm: llm)
        let confirmed = firstSentence + " " + secondSentence
        session.ingest(confirmedText: confirmed)
        await llm.waitForCalls(1)

        let finishing = Task {
            try await session.finish(finalInput: confirmed, request: request)
        }
        await llm.waitForCalls(2)
        finishing.cancel()

        do {
            _ = try await finishing.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await waitUntil { llm.cancelledInputs.count == 2 }
        XCTAssertEqual(Set(llm.cancelledInputs), [firstSentence, secondSentence])
    }

    // MARK: - Orchestration

    func testShortTextUsesTheWholeTextRequest() async throws {
        let llm = FakeSegmentLLM(respondsImmediately: true)
        let wholeTextCalls = CallRecorder()
        let text = firstSentence

        let outcome = try await WorkflowSegmentedPostProcessor(policy: smallPolicy).process(
            text: text,
            incrementalSession: nil,
            incrementalRequest: nil,
            segmentProcessor: llm.processor,
            wholeTextProcessor: {
                wholeTextCalls.record(text)
                return "whole"
            }
        )

        XCTAssertEqual(outcome.text, "whole")
        XCTAssertEqual(outcome.report.mode, .wholeText)
        XCTAssertFalse(outcome.report.fellBackToWholeText)
        XCTAssertEqual(wholeTextCalls.count, 1)
        XCTAssertTrue(llm.receivedInputs.isEmpty)
    }

    func testLongTextIsChunkedWhenIncrementalResultsCannotBeReused() async throws {
        let llm = FakeSegmentLLM(respondsImmediately: true)
        let session = makeSession(llm: FakeSegmentLLM(respondsImmediately: true))
        session.ingest(confirmedText: firstSentence + " " + secondSentence)
        let text = [secondSentence, thirdSentence, firstSentence].joined(separator: " ")

        let outcome = try await WorkflowSegmentedPostProcessor(policy: smallPolicy).process(
            text: text,
            incrementalSession: session,
            incrementalRequest: request,
            segmentProcessor: llm.processor,
            wholeTextProcessor: {
                XCTFail("Chunked processing should not need the whole-text request")
                return ""
            }
        )

        XCTAssertEqual(outcome.report.mode, .chunked)
        XCTAssertEqual(outcome.report.incrementalDiscardReason, .finalTranscriptMismatch)
        XCTAssertEqual(outcome.report.segmentCount, 3)
        XCTAssertEqual(
            outcome.text,
            [secondSentence, thirdSentence, firstSentence].map(FakeSegmentLLM.output(for:)).joined(separator: " ")
        )
    }

    func testChunkFailureFallsBackToWholeTextRequest() async throws {
        let llm = FakeSegmentLLM(respondsImmediately: true)
        llm.immediateResults[thirdSentence] = .failure(ProviderFailure())
        let text = [firstSentence, secondSentence, thirdSentence].joined(separator: " ")
        let wholeTextCalls = CallRecorder()

        let outcome = try await WorkflowSegmentedPostProcessor(policy: smallPolicy).process(
            text: text,
            incrementalSession: nil,
            incrementalRequest: nil,
            segmentProcessor: llm.processor,
            wholeTextProcessor: {
                wholeTextCalls.record(text)
                return "whole"
            }
        )

        XCTAssertEqual(outcome.text, "whole")
        XCTAssertEqual(outcome.report.mode, .wholeText)
        XCTAssertTrue(outcome.report.fellBackToWholeText)
        XCTAssertEqual(wholeTextCalls.inputs, [text])
    }

    func testChunkFailureFallsBackWithoutAwaitingNonCooperativeSibling() async throws {
        let llm = FakeSegmentLLM()
        let stuck = NonCooperativeRequests()
        let text = [firstSentence, secondSentence, thirdSentence].joined(separator: " ")
        let wholeTextCalls = CallRecorder()
        let stuckInput = secondSentence
        let fallbackCompleted = expectation(description: "whole-text fallback completes")

        let processing = Task {
            defer { fallbackCompleted.fulfill() }
            return try await WorkflowSegmentedPostProcessor(policy: smallPolicy).process(
                text: text,
                incrementalSession: nil,
                incrementalRequest: nil,
                segmentProcessor: { segment in
                    if segment == stuckInput {
                        return await stuck.hang(segment)
                    }
                    return try await llm.process(segment)
                },
                wholeTextProcessor: {
                    wholeTextCalls.record(text)
                    return "whole"
                }
            )
        }

        await llm.waitForCalls(1)
        await waitUntil { stuck.startedInputs == [stuckInput] }
        llm.fail(firstSentence, with: ProviderFailure())

        // The stuck request never returns until released; the fallback must not wait for it.
        await fulfillment(of: [fallbackCompleted], timeout: 10)
        stuck.releaseAll()
        let outcome = try await processing.value
        XCTAssertEqual(outcome.text, "whole")
        XCTAssertEqual(outcome.report.mode, .wholeText)
        XCTAssertTrue(outcome.report.fellBackToWholeText)
        XCTAssertEqual(wholeTextCalls.inputs, [text])
        XCTAssertEqual(llm.receivedInputs, [firstSentence])

        // The abandoned request was cancelled, and its late result is ignored.
        await waitUntil { stuck.lateResults.count == 1 }
        XCTAssertEqual(stuck.lateResults.first?.wasCancelled, true)
        XCTAssertEqual(outcome.text, "whole")
    }

    func testIncrementalFailureFallsBackWithoutAwaitingNonCooperativeSegment() async throws {
        let stuck = NonCooperativeRequests()
        let stuckInput = firstSentence
        let session = WorkflowIncrementalPostProcessingSession(
            request: request,
            policy: smallPolicy,
            prepareInput: { $0 },
            processor: { segment in
                if segment == stuckInput {
                    return await stuck.hang(segment)
                }
                throw ProviderFailure()
            }
        )
        let confirmed = firstSentence + " " + secondSentence
        session.ingest(confirmedText: confirmed)
        await waitUntil { stuck.startedInputs == [stuckInput] }
        let fallbackCompleted = expectation(description: "whole-text fallback completes")

        let processing = Task {
            defer { fallbackCompleted.fulfill() }
            return try await WorkflowSegmentedPostProcessor(policy: smallPolicy).process(
                text: confirmed,
                incrementalSession: session,
                incrementalRequest: request,
                segmentProcessor: { _ in
                    XCTFail("The tail belongs to the incremental session")
                    return ""
                },
                wholeTextProcessor: { "whole" }
            )
        }

        // The tail request fails while the first segment request never returns.
        await fulfillment(of: [fallbackCompleted], timeout: 10)
        stuck.releaseAll()
        let outcome = try await processing.value
        XCTAssertEqual(outcome.text, "whole")
        XCTAssertTrue(outcome.report.fellBackToWholeText)

        await waitUntil { stuck.lateResults.count == 1 }
        XCTAssertEqual(stuck.lateResults.first?.wasCancelled, true)
    }

    func testIncrementalFailureFallsBackToWholeTextRequest() async throws {
        let llm = FakeSegmentLLM()
        let session = makeSession(llm: llm)
        let confirmed = firstSentence + " " + secondSentence
        session.ingest(confirmedText: confirmed)
        await llm.waitForCalls(1)
        llm.fail(firstSentence, with: ProviderFailure())
        await waitUntil { !session.isCollecting }

        let outcome = try await WorkflowSegmentedPostProcessor(policy: smallPolicy).process(
            text: confirmed,
            incrementalSession: session,
            incrementalRequest: request,
            segmentProcessor: llm.processor,
            wholeTextProcessor: { "whole" }
        )

        XCTAssertEqual(outcome.text, "whole")
        XCTAssertTrue(outcome.report.fellBackToWholeText)
    }

    func testWholeTextFallbackFailurePropagatesForRawTranscriptionFallback() async {
        let llm = FakeSegmentLLM(respondsImmediately: true)
        llm.immediateResults[firstSentence] = .failure(ProviderFailure())
        let text = [firstSentence, secondSentence, thirdSentence].joined(separator: " ")

        do {
            _ = try await WorkflowSegmentedPostProcessor(policy: smallPolicy).process(
                text: text,
                incrementalSession: nil,
                incrementalRequest: nil,
                segmentProcessor: llm.processor,
                wholeTextProcessor: { throw ProviderFailure() }
            )
            XCTFail("Expected the whole-text failure to propagate")
        } catch {
            XCTAssertTrue(error is ProviderFailure)
        }
    }

    func testChunkCancellationIsNotTreatedAsFailure() async {
        let llm = FakeSegmentLLM(respondsImmediately: true)
        llm.immediateResults[secondSentence] = .failure(CancellationError())
        let text = [firstSentence, secondSentence, thirdSentence].joined(separator: " ")
        let wholeTextCalls = CallRecorder()

        do {
            _ = try await WorkflowSegmentedPostProcessor(policy: smallPolicy).process(
                text: text,
                incrementalSession: nil,
                incrementalRequest: nil,
                segmentProcessor: llm.processor,
                wholeTextProcessor: {
                    wholeTextCalls.record(text)
                    return "whole"
                }
            )
            XCTFail("Expected cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(wholeTextCalls.count, 0)
    }

    func testIncrementalResultsAreUsedWhenValid() async throws {
        let llm = FakeSegmentLLM(respondsImmediately: true)
        let session = makeSession(llm: llm)
        let confirmed = firstSentence + " " + secondSentence
        session.ingest(confirmedText: confirmed)

        let outcome = try await WorkflowSegmentedPostProcessor(policy: smallPolicy).process(
            text: confirmed,
            incrementalSession: session,
            incrementalRequest: request,
            segmentProcessor: { _ in
                XCTFail("The tail belongs to the incremental session")
                return ""
            },
            wholeTextProcessor: {
                XCTFail("Valid incremental results must not use the whole-text request")
                return ""
            }
        )

        XCTAssertEqual(outcome.report.mode, .incremental)
        XCTAssertEqual(outcome.report.reusedSegmentCount, 1)
        XCTAssertEqual(
            outcome.text,
            FakeSegmentLLM.output(for: firstSentence) + " " + FakeSegmentLLM.output(for: secondSentence)
        )
    }

    // MARK: - Provider locality

    func testLocalProviderSendsLongTextAsOneRequestAfterStop() async throws {
        let llm = FakeSegmentLLM(respondsImmediately: true)
        let wholeTextCalls = CallRecorder()
        let text = [firstSentence, secondSentence, thirdSentence].joined(separator: " ")
        XCTAssertEqual(WorkflowTextSegmenter.segment(text, policy: smallPolicy).segments.count, 3)

        let outcome = try await WorkflowSegmentedPostProcessor(
            policy: smallPolicy.forLLMProvider(isLocal: true)
        ).process(
            text: text,
            incrementalSession: nil,
            incrementalRequest: nil,
            segmentProcessor: llm.processor,
            wholeTextProcessor: {
                wholeTextCalls.record(text)
                return "whole"
            }
        )

        XCTAssertEqual(outcome.text, "whole")
        XCTAssertEqual(outcome.report.mode, .wholeText)
        XCTAssertEqual(outcome.report.segmentCount, 1)
        XCTAssertFalse(outcome.report.fellBackToWholeText)
        XCTAssertTrue(outcome.report.localProvider)
        XCTAssertTrue(outcome.report.logDescription.contains("localProvider=true"))
        XCTAssertEqual(wholeTextCalls.inputs, [text])
        XCTAssertTrue(llm.receivedInputs.isEmpty)
    }

    func testLocalProviderRunsIncrementalSegmentsOneAtATimeAndSendsTheTailWhole() async throws {
        let llm = FakeSegmentLLM()
        let localPolicy = smallPolicy.forLLMProvider(isLocal: true)
        let session = WorkflowIncrementalPostProcessingSession(
            request: request,
            policy: localPolicy,
            prepareInput: { $0 },
            processor: llm.processor
        )
        let sentences = (1...5).map { "Sentence \($0) has enough words to fill a segment." }
        let confirmed = sentences.joined(separator: " ")
        session.ingest(confirmedText: confirmed)
        XCTAssertEqual(session.committedSegmentCount, 4)

        await llm.waitForCalls(1)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(llm.receivedInputs.count, 1)
        llm.complete(llm.receivedInputs[0])
        await llm.waitForCalls(2)
        llm.complete(llm.receivedInputs[1])
        await llm.waitForCalls(3)

        // Long enough that the cloud policy would split it into several chunks.
        let tail = [sentences[4], firstSentence, secondSentence].joined(separator: " ")
        XCTAssertGreaterThan(WorkflowTextSegmenter.segment(tail, policy: smallPolicy).segments.count, 1)
        let finalInput = sentences.prefix(4).joined(separator: " ") + " " + tail
        let processing = Task {
            try await WorkflowSegmentedPostProcessor(policy: localPolicy).process(
                text: finalInput,
                incrementalSession: session,
                incrementalRequest: request,
                segmentProcessor: { _ in
                    XCTFail("The tail belongs to the incremental session")
                    return ""
                },
                wholeTextProcessor: {
                    XCTFail("Valid incremental results must not use the whole-text request")
                    return ""
                }
            )
        }

        llm.complete(llm.receivedInputs[2])
        await llm.waitForCalls(4)
        llm.complete(llm.receivedInputs[3])
        await llm.waitForCalls(5)
        XCTAssertEqual(llm.receivedInputs[4], tail)
        llm.complete(tail)

        let outcome = try await processing.value
        XCTAssertEqual(outcome.report.mode, .incremental)
        XCTAssertEqual(outcome.report.reusedSegmentCount, 4)
        XCTAssertEqual(outcome.report.segmentCount, 5)
        XCTAssertTrue(outcome.report.localProvider)
        XCTAssertEqual(llm.receivedInputs.count, 5)
        XCTAssertEqual(llm.peakInFlightCount, 1)
        XCTAssertEqual(
            outcome.text,
            (Array(sentences.prefix(4)) + [tail]).map(FakeSegmentLLM.output(for:)).joined(separator: " ")
        )
    }

    func testCloudProviderKeepsConcurrentChunks() async throws {
        XCTAssertEqual(WorkflowSegmentationPolicy.default.forLLMProvider(isLocal: false), .default)
        XCTAssertEqual(WorkflowSegmentationPolicy.default.maximumConcurrentRequests, 4)
        var cloudPolicy = smallPolicy
        cloudPolicy.maximumConcurrentRequests = 4
        XCTAssertEqual(cloudPolicy.forLLMProvider(isLocal: false), cloudPolicy)

        let llm = FakeSegmentLLM()
        let sentences = (1...6).map { "Sentence \($0) has enough words to fill a segment." }
        let text = sentences.joined(separator: " ")
        let processing = Task {
            try await WorkflowSegmentedPostProcessor(policy: cloudPolicy.forLLMProvider(isLocal: false)).process(
                text: text,
                incrementalSession: nil,
                incrementalRequest: nil,
                segmentProcessor: llm.processor,
                wholeTextProcessor: {
                    XCTFail("Chunked processing should not need the whole-text request")
                    return ""
                }
            )
        }

        await llm.waitForCalls(4)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(llm.receivedInputs.count, 4)
        XCTAssertEqual(llm.inFlightCount, 4)
        for input in llm.receivedInputs {
            llm.complete(input)
        }
        await llm.waitForCalls(6)
        llm.complete(llm.receivedInputs[4])
        llm.complete(llm.receivedInputs[5])

        let outcome = try await processing.value
        XCTAssertEqual(outcome.report.mode, .chunked)
        XCTAssertEqual(outcome.report.segmentCount, 6)
        XCTAssertFalse(outcome.report.localProvider)
        XCTAssertTrue(outcome.report.logDescription.contains("localProvider=false"))
        XCTAssertEqual(llm.peakInFlightCount, 4)
        XCTAssertEqual(outcome.text, sentences.map(FakeSegmentLLM.output(for:)).joined(separator: " "))
    }

    func testWorkflowProviderLocalityResolution() throws {
        let previousPluginManager = PluginManager.shared
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock {
            PluginManager.shared = previousPluginManager
            TestSupport.remove(directory)
        }
        let pluginManager = PluginManager(appSupportDirectory: directory)
        pluginManager.loadedPlugins = [
            ("com.typewhisper.tests.local-llm", LocalityTestLLMPlugin(providerName: "Local Gemma", requiresExternalCredentials: false)),
            ("com.typewhisper.tests.cloud-llm", LocalityTestLLMPlugin(providerName: "Cloud Groq", requiresExternalCredentials: true))
        ].map { id, plugin in
            LoadedPlugin(
                manifest: PluginManifest(id: id, name: plugin.providerName, version: "1.0.0", principalClass: "LocalityTestLLMPlugin"),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: directory,
                isEnabled: true
            )
        }
        PluginManager.shared = pluginManager

        let suiteName = "WorkflowSegmentedPostProcessingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode([
                LLMFallbackPriorityItem(providerId: "Local Gemma"),
                LLMFallbackPriorityItem(providerId: "Cloud Groq")
            ]),
            forKey: UserDefaultsKeys.llmFallbackPriorityList
        )
        let service = PromptProcessingService(userDefaults: defaults)

        // A workflow override decides.
        XCTAssertTrue(service.workflowUsesLocalLLMProvider(providerOverride: PromptProcessingService.appleIntelligenceId))
        XCTAssertTrue(service.workflowUsesLocalLLMProvider(providerOverride: " Local Gemma "))
        XCTAssertFalse(service.workflowUsesLocalLLMProvider(providerOverride: "Cloud Groq"))
        XCTAssertFalse(service.workflowUsesLocalLLMProvider(providerOverride: "Uninstalled Provider"))

        // Without an override, the primary fallback entry decides.
        XCTAssertTrue(service.workflowUsesLocalLLMProvider(providerOverride: nil))
        XCTAssertTrue(service.workflowUsesLocalLLMProvider(providerOverride: "  "))
        let inherited = service.workflowProviderResolution(providerOverride: nil, cloudModelOverride: nil, effortOverride: nil)
        XCTAssertEqual(inherited.attempts.map(\.providerId), ["Local Gemma", "Cloud Groq"])
        XCTAssertTrue(inherited.isLocal)
        let overridden = service.workflowProviderResolution(
            providerOverride: " Cloud Groq ",
            cloudModelOverride: " fast ",
            effortOverride: nil
        )
        XCTAssertEqual(overridden.attempts, [.init(providerId: "Cloud Groq", modelId: "fast", effortId: nil)])
        XCTAssertFalse(overridden.isLocal)

        service.moveLLMFallbacks(from: IndexSet(integer: 1), to: 0)
        XCTAssertFalse(service.workflowUsesLocalLLMProvider(providerOverride: nil))
        let reordered = service.workflowProviderResolution(providerOverride: nil, cloudModelOverride: nil, effortOverride: nil)
        XCTAssertEqual(reordered.attempts.map(\.providerId), ["Cloud Groq", "Local Gemma"])
        XCTAssertFalse(reordered.isLocal)
        XCTAssertNotEqual(reordered, inherited)
        XCTAssertEqual(
            service.workflowProviderResolution(providerOverride: " Cloud Groq ", cloudModelOverride: " fast ", effortOverride: nil),
            overridden
        )

        for item in service.fallbackPriorityList {
            service.removeLLMFallback(item)
        }
        XCTAssertTrue(service.fallbackPriorityList.isEmpty)
        XCTAssertFalse(service.workflowUsesLocalLLMProvider(providerOverride: nil))

        XCTAssertEqual(WorkflowSegmentationPolicy.default.forLLMProvider(isLocal: true).maximumConcurrentRequests, 1)
        XCTAssertTrue(WorkflowSegmentationPolicy.default.forLLMProvider(isLocal: true).isLocalProvider)
    }

    // MARK: - Workflow model, persistence, and backup

    func testSegmentationIsOnlyAvailableForPromptBasedLLMWorkflows() {
        let enabled = WorkflowBehavior(segmentedPostProcessingEnabled: true)

        XCTAssertTrue(Workflow(name: "Clean", template: .cleanedText, trigger: .manual(), behavior: enabled).usesSegmentedPostProcessing)
        XCTAssertFalse(Workflow(name: "Clean", template: .cleanedText, trigger: .manual()).usesSegmentedPostProcessing)

        var inlineCommands = enabled
        inlineCommands.inlineCommandsEnabled = true
        XCTAssertFalse(Workflow(name: "Dictate", template: .dictation, trigger: .manual(), behavior: inlineCommands).supportsSegmentedPostProcessing)

        var appleTranslate = enabled
        appleTranslate.settings = [
            WorkflowBehavior.translationProcessorSettingKey: WorkflowTranslationProcessor.appleTranslate.rawValue,
            WorkflowBehavior.targetLanguageSettingKey: "de"
        ]
        XCTAssertFalse(Workflow(name: "Translate", template: .translation, trigger: .manual(), behavior: appleTranslate).supportsSegmentedPostProcessing)
        XCTAssertFalse(Workflow(name: "Custom", template: .custom, trigger: .manual(), behavior: enabled).supportsSegmentedPostProcessing)

        var llmTranslate = enabled
        llmTranslate.settings = [WorkflowBehavior.targetLanguageSettingKey: "de"]
        XCTAssertTrue(Workflow(name: "Translate", template: .translation, trigger: .manual(), behavior: llmTranslate).usesSegmentedPostProcessing)

        // Whole-document templates ignore a stored flag, even with a prompt.
        var customInstruction = enabled
        customInstruction.settings = ["instruction": "Fix typos."]
        let custom = Workflow(name: "Custom", template: .custom, trigger: .manual(), behavior: customInstruction)
        XCTAssertNotNil(custom.systemPrompt())
        XCTAssertFalse(custom.usesSegmentedPostProcessing)
        for template in [WorkflowTemplate.summary, .json, .emailReply, .meetingNotes, .checklist] {
            let workflow = Workflow(name: "Whole", template: template, trigger: .manual(), behavior: enabled)
            XCTAssertNotNil(workflow.systemPrompt(), "\(template)")
            XCTAssertEqual(workflow.behavior.segmentedPostProcessingEnabled, true)
            XCTAssertFalse(workflow.usesSegmentedPostProcessing, "\(template)")
        }
        XCTAssertEqual(
            WorkflowTemplate.allCases.filter(\.allowsSegmentedPostProcessing),
            [.cleanedText, .translation]
        )
    }

    func testBehaviorWithoutSegmentationFieldDecodesAsOff() throws {
        let legacyJSON = Data(#"{"settings":{},"fineTuning":"Keep it short","providerId":"Groq"}"#.utf8)
        let decoded = try JSONDecoder().decode(WorkflowBehavior.self, from: legacyJSON)
        XCTAssertNil(decoded.segmentedPostProcessingEnabled)
        XCTAssertEqual(decoded.fineTuning, "Keep it short")

        let workflow = Workflow(name: "Legacy", template: .cleanedText, trigger: .manual())
        workflow.behaviorData = legacyJSON
        XCTAssertFalse(workflow.usesSegmentedPostProcessing)

        // Off stays off the wire, so older peers read an unchanged payload.
        let encodedDefault = try JSONEncoder().encode(WorkflowBehavior(fineTuning: "Keep it short"))
        XCTAssertFalse(String(decoding: encodedDefault, as: UTF8.self).contains("segmentedPostProcessingEnabled"))

        let encodedEnabled = try JSONEncoder().encode(WorkflowBehavior(segmentedPostProcessingEnabled: true))
        let roundTripped = try JSONDecoder().decode(WorkflowBehavior.self, from: encodedEnabled)
        XCTAssertEqual(roundTripped.segmentedPostProcessingEnabled, true)
    }

    func testSegmentationFlagPersistsInWorkflowStore() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let suiteName = "WorkflowSegmentedPostProcessingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = WorkflowService(appSupportDirectory: directory, userDefaults: defaults)
        service.addWorkflow(
            name: "Long Cleanup",
            template: .cleanedText,
            trigger: .manual(),
            behavior: WorkflowBehavior(segmentedPostProcessingEnabled: true)
        )
        service.addWorkflow(name: "Plain Cleanup", template: .cleanedText, trigger: .manual())

        let reloaded = WorkflowService(appSupportDirectory: directory, userDefaults: defaults)
        let byName = Dictionary(uniqueKeysWithValues: reloaded.workflows.map { ($0.name, $0) })
        XCTAssertEqual(byName["Long Cleanup"]?.behavior.segmentedPostProcessingEnabled, true)
        XCTAssertEqual(byName["Long Cleanup"]?.usesSegmentedPostProcessing, true)
        XCTAssertNil(byName["Plain Cleanup"]?.behavior.segmentedPostProcessingEnabled)
    }

    func testWorkflowDraftStoresSegmentationOnlyWhenSupported() {
        let workflow = Workflow(
            name: "Clean",
            template: .cleanedText,
            trigger: .manual(),
            behavior: WorkflowBehavior(segmentedPostProcessingEnabled: true)
        )
        var draft = WorkflowDraft(workflow)
        XCTAssertEqual(draft.segmentedPostProcessingEnabled, true)
        XCTAssertEqual(draft.resolvedBehavior().segmentedPostProcessingEnabled, true)

        draft.segmentedPostProcessingEnabled = false
        XCTAssertNil(draft.resolvedBehavior().segmentedPostProcessingEnabled)

        var dictationDraft = WorkflowDraft(template: .dictation)
        dictationDraft.inlineCommandsEnabled = true
        dictationDraft.segmentedPostProcessingEnabled = true
        XCTAssertFalse(dictationDraft.supportsSegmentedPostProcessing)
        XCTAssertNil(dictationDraft.resolvedBehavior().segmentedPostProcessingEnabled)

        for template in [WorkflowTemplate.summary, .json, .emailReply, .meetingNotes, .checklist, .custom] {
            let stored = Workflow(
                name: "Whole",
                template: template,
                trigger: .manual(),
                behavior: WorkflowBehavior(segmentedPostProcessingEnabled: true)
            )
            let draft = WorkflowDraft(stored)
            XCTAssertFalse(draft.supportsSegmentedPostProcessing, "\(template)")
            XCTAssertNil(draft.resolvedBehavior().segmentedPostProcessingEnabled, "\(template)")
        }
        var translationDraft = WorkflowDraft(template: .translation)
        translationDraft.translationProcessor = .llmPrompt
        XCTAssertTrue(translationDraft.supportsSegmentedPostProcessing)
        translationDraft.translationProcessor = .appleTranslate
        XCTAssertFalse(translationDraft.supportsSegmentedPostProcessing)
    }

    // MARK: - Provider path and pipeline mirroring

    func testSegmentRequestsUseTheWholeTextProviderPath() async throws {
        let workflow = Workflow(
            name: "Clean",
            template: .cleanedText,
            trigger: .manual(),
            behavior: WorkflowBehavior(
                providerId: " Groq ",
                cloudModel: "llama-3.3",
                temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
                temperatureValue: 0.2,
                segmentedPostProcessingEnabled: true
            )
        )
        var calls: [(prompt: String, text: String, provider: String?, model: String?, temperature: PluginLLMTemperatureDirective)] = []
        let service = WorkflowTextProcessingService(
            promptProcessor: { prompt, text, providerId, cloudModel, temperature in
                calls.append((prompt, text, providerId, cloudModel, temperature))
                return "done"
            },
            appleTranslator: nil
        )

        let request = try XCTUnwrap(service.segmentedPromptRequest(workflow: workflow, configuredLanguage: "en"))
        _ = try await service.process(request: request, text: "segment")
        _ = try await service.process(workflow: workflow, text: "whole", configuredLanguage: "en")

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].prompt, calls[1].prompt)
        XCTAssertEqual(calls[0].provider, "Groq")
        XCTAssertEqual(calls[1].provider, "Groq")
        XCTAssertEqual(calls[0].model, "llama-3.3")
        XCTAssertEqual(calls[0].temperature, .custom(0.2))
        XCTAssertEqual(calls[0].temperature, calls[1].temperature)
        XCTAssertEqual(calls.map(\.text), ["segment", "whole"])

        let disabled = Workflow(name: "Clean", template: .cleanedText, trigger: .manual())
        XCTAssertNotNil(service.segmentedPromptRequest(workflow: disabled))
        XCTAssertNil(service.segmentedPromptRequest(
            workflow: Workflow(name: "Dictate", template: .dictation, trigger: .manual())
        ))
    }

    func testSegmentedRequestIdentityIncludesInheritedProviderSettings() async throws {
        let workflow = Workflow(
            name: "Clean",
            template: .cleanedText,
            trigger: .manual(),
            behavior: WorkflowBehavior(segmentedPostProcessingEnabled: true)
        )
        var resolution = WorkflowLLMProviderResolution(
            attempts: [.init(providerId: "Groq", modelId: "llama-3.3", effortId: nil)],
            isLocal: false
        )
        var resolverCalls: [(provider: String?, model: String?, effort: String?)] = []
        let service = WorkflowTextProcessingService(
            promptProcessor: { _, _, _, _, _ in "done" },
            appleTranslator: nil,
            providerResolver: { providerId, cloudModel, effortId in
                resolverCalls.append((providerId, cloudModel, effortId))
                return resolution
            }
        )

        let armed = try XCTUnwrap(service.segmentedPromptRequest(workflow: workflow))
        XCTAssertNil(armed.providerId)
        XCTAssertEqual(armed.providerResolution, resolution)
        XCTAssertEqual(service.segmentedPromptRequest(workflow: workflow), armed)
        XCTAssertEqual(resolverCalls.count, 2)
        XCTAssertNil(resolverCalls[0].provider)

        // The global fallback list changes during the recording.
        resolution = WorkflowLLMProviderResolution(
            attempts: [.init(providerId: "Groq", modelId: "llama-4", effortId: nil)],
            isLocal: false
        )
        let changedModel = try XCTUnwrap(service.segmentedPromptRequest(workflow: workflow))
        XCTAssertNotEqual(changedModel, armed)
        resolution = WorkflowLLMProviderResolution(
            attempts: [.init(providerId: PromptProcessingService.appleIntelligenceId, modelId: nil, effortId: nil)],
            isLocal: true
        )
        let changedLocality = try XCTUnwrap(service.segmentedPromptRequest(workflow: workflow))
        XCTAssertNotEqual(changedLocality, armed)
        XCTAssertEqual(changedLocality.providerResolution?.isLocal, true)

        // Segments computed with the old settings are not reused.
        let llm = FakeSegmentLLM()
        let session = WorkflowIncrementalPostProcessingSession(
            request: armed,
            policy: smallPolicy,
            prepareInput: { $0 },
            processor: llm.processor
        )
        let confirmed = firstSentence + " " + secondSentence
        session.ingest(confirmedText: confirmed)
        await llm.waitForCalls(1)
        guard case .notReusable(let reason) = try await session.finish(finalInput: confirmed, request: changedModel) else {
            return XCTFail("Expected the provider change to prevent reuse")
        }
        XCTAssertEqual(reason, .configurationChanged)
        await waitUntilCancelled(firstSentence, llm: llm)
    }

    func testTextBeforeLLMStepMatchesPipelineLLMInput() async throws {
        let previousPluginManager = PluginManager.shared
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock {
            PluginManager.shared = previousPluginManager
            TestSupport.remove(directory)
        }
        PluginManager.shared = PluginManager(appSupportDirectory: directory)
        let suiteName = "WorkflowSegmentedPostProcessingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rulesLoader = PunctuationRulesLoader { languageCode in
            guard languageCode == "it" else { return nil }
            return """
            {
              "language": "it",
              "rules": [
                { "phrase": "aperta parentesi", "replacement": "(", "category": "brackets" },
                { "phrase": "chiusa parentesi", "replacement": ")", "category": "brackets" }
              ],
              "verificationScenarios": []
            }
            """.data(using: .utf8)
        }
        let pipeline = PostProcessingPipeline(
            snippetService: SnippetService(appSupportDirectory: directory),
            dictionaryService: DictionaryService(appSupportDirectory: directory),
            appFormatterService: nil,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: rulesLoader),
            punctuationStrategyResolver: PunctuationStrategyResolver(
                profileStore: DictationPunctuationProfileStore(defaults: defaults, storageKey: suiteName)
            )
        )
        XCTAssertFalse(pipeline.hasPluginStepsBeforeLLMStep)

        let cases: [(text: String, language: String, engine: String)] = [
            ("I counted twenty three boxes", "en", "mock"),
            ("ciao aperta parentesi mondo chiusa parentesi", "it", "parakeet")
        ]
        for testCase in cases {
            let context = PostProcessingContext(language: testCase.language)
            let dictationContext = DictationRuntimeContext(
                engineId: testCase.engine,
                modelId: "parakeet-v3",
                configuredLanguage: testCase.language,
                detectedLanguage: nil
            )
            var llmInput: String?
            _ = try await pipeline.process(
                text: testCase.text,
                context: context,
                dictationContext: dictationContext,
                llmHandler: { text in
                    llmInput = text
                    return text
                },
                normalizeNumbers: true
            )

            let prepared = pipeline.textBeforeLLMStep(
                testCase.text,
                context: context,
                dictationContext: dictationContext,
                outputFormat: nil,
                normalizeNumbers: true
            )
            XCTAssertEqual(prepared, llmInput)
            XCTAssertNotEqual(prepared, testCase.text)
        }
    }

    // MARK: - Helpers

    private func waitUntilCancelled(_ input: String, llm: FakeSegmentLLM) async {
        await waitUntil { llm.cancelledInputs.contains(input) }
    }

    /// Yields to the main actor until `condition` holds; the fake completes all
    /// work on the main actor, so this never waits on wall-clock time.
    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition not met", file: file, line: line)
    }
}
