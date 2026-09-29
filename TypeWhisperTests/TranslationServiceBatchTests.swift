#if canImport(Translation)
import Translation
import XCTest
@testable import TypeWhisper

/// Regression tests for the batch translation ownership fixes: overlapping
/// requests must never lose a continuation, a stalled framework session
/// must still hit its timeout with exactly-once completion, and silently
/// untranslated segments must not ship under the target language.
/// A controllable `BatchSessionTranslator` double stands in for the Apple
/// framework session; availability and the watchdog duration are stubbed.
@available(macOS 15, *)
@MainActor
final class TranslationServiceBatchTests: XCTestCase {

    // MARK: - Doubles

    /// Async gate: `wait()` suspends until `open()` is called.
    private actor TestGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    /// Controllable stand-in for the framework batch session.
    private struct ControllableBatchSession: TranslationService.BatchSessionTranslator {
        var gate: TestGate?
        var results: ([String]) -> [String]

        func prepareTranslation() async throws {}
        func translateTexts(_ texts: [String]) async throws -> [String] {
            if let gate { await gate.wait() }
            return results(texts)
        }
    }

    private enum BatchTestError: Error {
        case timedOutWaiting
    }

    // MARK: - Helpers

    private func makeService(
        availability: ((String, Locale.Language?, Locale.Language) async -> LanguageAvailability.Status?)? = nil,
        batchTimeout: Duration? = nil
    ) -> TranslationService {
        let service = TranslationService()
        service.availabilityStub = availability ?? { _, _, _ in .installed }
        service.batchTimeoutOverride = batchTimeout
        return service
    }

    /// Starts a batch, returning a task for its terminal outcome.
    private func startBatch(
        _ service: TranslationService,
        texts: [String],
        target: Locale.Language,
        strict: Bool = true
    ) -> Task<Result<[String], Error>, Never> {
        Task { @MainActor in
            do {
                return .success(try await service.translateBatch(texts: texts, to: target, strict: strict))
            } catch {
                return .failure(error)
            }
        }
    }

    /// Awaits a batch task, failing if it never settles — a hung batch is
    /// exactly the regression these tests guard against.
    private func awaitBatch(
        _ task: Task<Result<[String], Error>, Never>,
        timeout: Duration = .seconds(30)
    ) async throws -> Result<[String], Error> {
        try await withThrowingTaskGroup(of: Result<[String], Error>.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BatchTestError.timedOutWaiting
            }
            defer { group.cancelAll() }
            return try await group.next() ?? .failure(BatchTestError.timedOutWaiting)
        }
    }

    private func awaitClaim(on service: TranslationService, timeoutSeconds: Double = 10) async throws {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while service.claimedBatchRequestId == nil {
            guard Date() < deadline else { throw BatchTestError.timedOutWaiting }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func assertBatchThrows(
        _ expected: TypeWhisper.TranslationError,
        _ result: Result<[String], Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let error) = result,
              let translationError = error as? TypeWhisper.TranslationError,
              translationError == expected else {
            XCTFail("expected batch to throw \(expected), got \(result)", file: file, line: line)
            return
        }
    }

    // MARK: - P1: overlapping requests

    func testOverlappingBatchCallsWithinResetWindowBothFinish() async throws {
        let service = makeService()
        let german = Locale.Language(identifier: "de")

        let first = startBatch(service, texts: ["eins"], target: german)
        // Start the second call inside the first call's 100 ms reset window.
        try await Task.sleep(for: .milliseconds(50))
        let second = startBatch(service, texts: ["zwei"], target: german)

        // The second request preempts the first, which must surface
        // cancellation instead of hanging on a lost continuation.
        assertBatchThrows(.cancelled, try await awaitBatch(first))

        // The surviving request completes through its own session.
        await service.handleBatchSession(ControllableBatchSession(results: { texts in texts.map { "DE:\($0)" } }))
        let secondTranslated = try await awaitBatch(second).get()
        XCTAssertEqual(secondTranslated, ["DE:zwei"])
    }

    func testNewBatchWhileSessionExecutingResolvesBothExactlyOnce() async throws {
        let service = makeService(batchTimeout: .seconds(30))
        let german = Locale.Language(identifier: "de")
        let gate = TestGate()

        let first = startBatch(service, texts: ["eins"], target: german)
        try await awaitClaim(on: service)
        // The framework session for the first request is now executing; hold it.
        let staleSession = Task { @MainActor in
            await service.handleBatchSession(ControllableBatchSession(gate: gate, results: { _ in ["IGNORED"] }))
        }

        // A new request arrives while the earlier session is executing.
        let second = startBatch(service, texts: ["zwei"], target: german)

        // The superseded request must surface cancellation, not hang.
        assertBatchThrows(.cancelled, try await awaitBatch(first))

        // Releasing the stale session: its late result must be ignored, not
        // resume anything a second time.
        await gate.open()
        await staleSession.value

        // The surviving request completes through its own session.
        try await awaitClaim(on: service)
        await service.handleBatchSession(ControllableBatchSession(results: { texts in texts.map { "DE:\($0)" } }))
        let secondTranslated = try await awaitBatch(second).get()
        XCTAssertEqual(secondTranslated, ["DE:zwei"])
    }

    // MARK: - P2: timeout during an executing session

    func testStalledBatchSessionHitsTimeoutAndLateResultIsIgnored() async throws {
        let service = makeService(batchTimeout: .milliseconds(300))
        let german = Locale.Language(identifier: "de")
        let gate = TestGate()

        let first = startBatch(service, texts: ["hello"], target: german)
        try await awaitClaim(on: service)
        // Hand the claimed request to a session, then hold it past the deadline.
        Task { @MainActor in
            await service.handleBatchSession(ControllableBatchSession(gate: gate, results: { _ in ["HALLO"] }))
        }

        // The caller must time out even though the session is still running.
        assertBatchThrows(.timedOut, try await awaitBatch(first))

        // Release the session: the late result is safely ignored and the
        // timed-out request has released its registration.
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(service.claimedBatchRequestId, "timed-out request must release its registration")
    }

    // MARK: - Unchanged-result fallback

    func testUnchangedBatchResultRetriesViaEnglish() async throws {
        let service = makeService(availability: { _, _, target in
            // Direct pair looks usable but not installed; the English legs are.
            target.minimalIdentifier == "en" ? .installed : .supported
        })
        let german = Locale.Language(identifier: "de")

        let first = startBatch(service, texts: ["Hello world", "Good morning"], target: german)
        try await awaitClaim(on: service)

        // The framework silently echoes the source text for the direct pair.
        await service.handleBatchSession(ControllableBatchSession(results: { $0 }))

        // The fallback reissues through English: drive both legs.
        try await awaitClaim(on: service)
        await service.handleBatchSession(ControllableBatchSession(results: { $0 }))
        try await awaitClaim(on: service)
        await service.handleBatchSession(ControllableBatchSession(results: { texts in
            texts.map { $0 == "Hello world" ? "Hallo Welt" : "Guten Morgen" }
        }))

        // The segments come back translated, never as source text reported
        // under the target language.
        let firstTranslated = try await awaitBatch(first).get()
        XCTAssertEqual(firstTranslated, ["Hallo Welt", "Guten Morgen"])
    }

    // MARK: - P2: strict fallback rejects invalid final output

    /// Drives one full fallback round: the direct leg echoes the source, the
    /// English leg translates, and the target leg answers with `targetResults`.
    private func driveFallbackRound(
        _ service: TranslationService,
        targetResults: @escaping ([String]) -> [String]
    ) async throws {
        try await awaitClaim(on: service)
        // Direct leg echoes the source; the fallback retries through English.
        await service.handleBatchSession(ControllableBatchSession(results: { $0 }))
        try await awaitClaim(on: service)
        await service.handleBatchSession(ControllableBatchSession(results: { _ in ["Hello world"] }))
        try await awaitClaim(on: service)
        await service.handleBatchSession(ControllableBatchSession(results: targetResults))
    }

    private func makeFallbackService() -> TranslationService {
        makeService(availability: { _, _, target in
            // Direct pair looks usable but not installed; the English legs are.
            target.minimalIdentifier == "en" ? .installed : .supported
        })
    }

    func testEmptyTargetLegResponseThrowsInStrictMode() async throws {
        let service = makeFallbackService()
        let german = Locale.Language(identifier: "de")

        let batch = startBatch(service, texts: ["Bonjour le monde"], target: german, strict: true)
        // The target leg answers empty: strict must fail, not report success.
        try await driveFallbackRound(service, targetResults: { _ in [""] })

        assertBatchThrows(.noTranslation, try await awaitBatch(batch))
    }

    func testEmptyTargetLegResponseKeepsSourceWhenNotStrict() async throws {
        let service = makeFallbackService()
        let german = Locale.Language(identifier: "de")

        let batch = startBatch(service, texts: ["Bonjour le monde"], target: german, strict: false)
        try await driveFallbackRound(service, targetResults: { _ in [""] })

        let translated = try await awaitBatch(batch).get()
        XCTAssertEqual(translated, ["Bonjour le monde"])
    }

    func testEchoedEnglishIntermediateThrowsInStrictMode() async throws {
        let service = makeFallbackService()
        let german = Locale.Language(identifier: "de")

        let batch = startBatch(service, texts: ["Bonjour le monde"], target: german, strict: true)
        // The target leg echoes the English intermediate unchanged: strict
        // must fail instead of reporting English as German.
        try await driveFallbackRound(service, targetResults: { _ in ["Hello world"] })

        assertBatchThrows(.noTranslation, try await awaitBatch(batch))
    }

    func testEchoedEnglishIntermediateKeepsSourceWhenNotStrict() async throws {
        let service = makeFallbackService()
        let german = Locale.Language(identifier: "de")

        let batch = startBatch(service, texts: ["Bonjour le monde"], target: german, strict: false)
        try await driveFallbackRound(service, targetResults: { _ in ["Hello world"] })

        let translated = try await awaitBatch(batch).get()
        XCTAssertEqual(translated, ["Bonjour le monde"])
    }
}
#endif
