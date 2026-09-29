#if canImport(Translation)
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

    private var firstOutcome: Result<[String], Error>?
    private var secondOutcome: Result<[String], Error>?

    private func makeService(
        availability: ((String, Locale.Language?, Locale.Language) async -> LanguageAvailability.Status?)? = nil,
        batchTimeout: Duration? = nil
    ) -> TranslationService {
        let service = TranslationService()
        service.availabilityStub = availability ?? { _, _, _ in .installed }
        service.batchTimeoutOverride = batchTimeout
        return service
    }

    /// Starts a strict batch in the background, capturing its terminal outcome.
    private func startBatch(
        _ service: TranslationService,
        texts: [String],
        target: Locale.Language,
        store: WritableKeyPath<TranslationServiceBatchTests, Result<[String], Error>?>
    ) {
        Task {
            let outcome: Result<[String], Error>
            do {
                outcome = .success(try await service.translateBatch(texts: texts, to: target, strict: true))
            } catch {
                outcome = .failure(error)
            }
            self[keyPath: store] = outcome
        }
    }

    private func awaitClaim(on service: TranslationService, timeoutSeconds: Double = 10) async throws {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while service.claimedBatchRequestId == nil {
            guard Date() < deadline else { throw BatchTestError.timedOutWaiting }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func awaitOutcome(
        timeoutSeconds: Double = 10,
        _ read: () -> Result<[String], Error>?
    ) async throws -> Result<[String], Error> {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while true {
            if let outcome = read() { return outcome }
            guard Date() < deadline else { throw BatchTestError.timedOutWaiting }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - P1: overlapping requests

    func testOverlappingBatchCallsWithinResetWindowBothFinish() async throws {
        let service = makeService()
        let german = Locale.Language(identifier: "de")

        startBatch(service, texts: ["eins"], target: german, store: \.firstOutcome)
        // Start the second call inside the first call's 100 ms reset window.
        try await Task.sleep(for: .milliseconds(50))
        startBatch(service, texts: ["zwei"], target: german, store: \.secondOutcome)

        // The second request preempts the first, which must surface
        // cancellation instead of hanging on a lost continuation.
        let first = try await awaitOutcome { self.firstOutcome }
        guard case .failure(let error) = first, case TranslationError.cancelled = error else {
            XCTFail("preempted batch should have thrown cancelled, got \(String(describing: first))")
            return
        }

        // The surviving request completes through its own session.
        await service.handleBatchSession(ControllableBatchSession(results: { texts in texts.map { "DE:\($0)" } }))
        let second = try await awaitOutcome { self.secondOutcome }
        XCTAssertEqual(try second.get(), ["DE:zwei"])
    }

    func testNewBatchWhileSessionExecutingResolvesBothExactlyOnce() async throws {
        let service = makeService(batchTimeout: .seconds(30))
        let german = Locale.Language(identifier: "de")
        let gate = TestGate()

        startBatch(service, texts: ["eins"], target: german, store: \.firstOutcome)
        try await awaitClaim(on: service)
        // The framework session for the first request is now executing; hold it.
        let staleSession = Task {
            await service.handleBatchSession(ControllableBatchSession(gate: gate, results: { _ in ["IGNORED"] }))
        }

        // A new request arrives while the earlier session is executing.
        startBatch(service, texts: ["zwei"], target: german, store: \.secondOutcome)

        // The superseded request must surface cancellation, not hang.
        let first = try await awaitOutcome { self.firstOutcome }
        guard case .failure(let error) = first, case TranslationError.cancelled = error else {
            XCTFail("superseded batch should have thrown cancelled, got \(String(describing: first))")
            return
        }

        // Releasing the stale session: its late result must be ignored, not
        // resume anything a second time.
        await gate.open()
        await staleSession.value

        // The surviving request completes through its own session.
        try await awaitClaim(on: service)
        await service.handleBatchSession(ControllableBatchSession(results: { texts in texts.map { "DE:\($0)" } }))
        let second = try await awaitOutcome { self.secondOutcome }
        XCTAssertEqual(try second.get(), ["DE:zwei"])
    }

    // MARK: - P2: timeout during an executing session

    func testStalledBatchSessionHitsTimeoutAndLateResultIsIgnored() async throws {
        let service = makeService(batchTimeout: .milliseconds(300))
        let german = Locale.Language(identifier: "de")
        let gate = TestGate()

        startBatch(service, texts: ["hello"], target: german, store: \.firstOutcome)
        try await awaitClaim(on: service)
        // Hand the claimed request to a session, then hold it past the deadline.
        Task {
            await service.handleBatchSession(ControllableBatchSession(gate: gate, results: { _ in ["HALLO"] }))
        }

        // The caller must time out even though the session is still running.
        let settled = try await awaitOutcome { self.firstOutcome }
        guard case .failure(let error) = settled, case TranslationError.timedOut = error else {
            XCTFail("stalled batch should have thrown timedOut, got \(String(describing: settled))")
            return
        }

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

        startBatch(service, texts: ["Hello world", "Good morning"], target: german, store: \.firstOutcome)
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
        let settled = try await awaitOutcome { self.firstOutcome }
        XCTAssertEqual(try settled.get(), ["Hallo Welt", "Guten Morgen"])
    }
}
#endif
