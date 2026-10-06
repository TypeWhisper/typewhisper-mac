import Foundation
import os
import XCTest
import TypeWhisperPluginSDK
@testable import GeminiPlugin

final class GeminiLiveSessionPoolTests: XCTestCase {
    func testSuccessfulDictationPreparesFreshSessionWithoutTranscriptCarryover() async throws {
        let factory = GeminiTestSessionFactory()
        let pool = GeminiLiveSessionPool(factory: factory.connect)
        let first = try await pool.checkout(configuration: configuration(), onProgress: { _ in true })
        try await first.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"First dictation"},"turnComplete":true}}"#))
        _ = try await first.finish()
        try await waitUntil { factory.sessions.count == 2 }
        XCTAssertTrue(factory.sockets[0].isClosed)
        XCTAssertEqual(factory.sockets[1].sentMessages.count, 1, "Standby must send only setup, never audio")

        let second = try await pool.checkout(configuration: configuration(), onProgress: { _ in true })
        XCTAssertTrue(second === factory.sessions[1])
        XCTAssertEqual(factory.sockets.count, 2)
        try await second.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Second dictation"},"turnComplete":true}}"#))
        let result = try await second.finish()
        XCTAssertEqual(result.text, "Second dictation")
        await pool.shutdown()
    }

    func testCheckoutUsesPendingWarmSetupInsteadOfOpeningAnotherSocket() async throws {
        let factory = GeminiTestSessionFactory(automaticallyCompleteSetup: false)
        let pool = GeminiLiveSessionPool(factory: factory.connect)
        await pool.prewarm(configuration: configuration())
        try await waitUntil { factory.sockets.count == 1 }
        let checkout = Task { try await pool.checkout(configuration: configuration(), onProgress: { _ in true }) }
        factory.sockets[0].enqueue(#"{"setupComplete":{}}"#)
        let session = try await checkout.value
        XCTAssertEqual(factory.sockets.count, 1)
        XCTAssertTrue(session === factory.sessions[0])
        await session.cancel()
        await pool.shutdown()
    }

    func testEveryConfigurationChangeDiscardsStandby() async throws {
        let alternatives = [
            configuration(apiKey: "another-key"), configuration(modelId: "another-model"),
            configuration(mode: .smart), configuration(languageCodes: ["de-DE"]),
            configuration(vocabulary: ["Another term"]),
        ]
        for alternative in alternatives {
            let factory = GeminiTestSessionFactory()
            let pool = GeminiLiveSessionPool(factory: factory.connect)
            await pool.prewarm(configuration: configuration())
            try await waitUntil { factory.sessions.count == 1 }
            let session = try await pool.checkout(configuration: alternative, onProgress: { _ in true })
            try await waitUntil { factory.sockets[0].isClosed }
            XCTAssertEqual(factory.sockets.count, 2)
            XCTAssertTrue(session === factory.sessions[1])
            await session.cancel()
            await pool.shutdown()
        }
    }

    func testStandbyPingsButStillExpiresAndReconnects() async throws {
        let factory = GeminiTestSessionFactory()
        let pool = GeminiLiveSessionPool(
            idleTimeout: .milliseconds(100), pingInterval: .milliseconds(10), factory: factory.connect
        )
        await pool.prewarm(configuration: configuration())
        try await waitUntil { factory.sockets.first?.isClosed == true }
        XCTAssertGreaterThan(factory.sockets[0].pingCount, 0)
        let session = try await pool.checkout(configuration: configuration(), onProgress: { _ in true })
        XCTAssertEqual(factory.sockets.count, 2)
        XCTAssertTrue(session === factory.sessions[1])
        await session.cancel()
        await pool.shutdown()
    }

    func testAgingStandbyIsReplacedBeforeItsIdleTimeout() async throws {
        let clock = GeminiTestClock()
        let factory = GeminiTestSessionFactory(now: clock.now)
        let pool = GeminiLiveSessionPool(factory: factory.connect)
        await pool.prewarm(configuration: configuration())
        try await waitUntil { factory.sessions.count == 1 }
        clock.advance(by: .seconds(61))

        let session = try await pool.checkout(configuration: configuration(), onProgress: { _ in true })
        XCTAssertTrue(factory.sockets[0].isClosed)
        XCTAssertEqual(factory.sockets.count, 2)
        XCTAssertTrue(session === factory.sessions[1])
        await session.cancel()
        await pool.shutdown()
    }

    func testRecentStandbyStillUsesWarmConnection() async throws {
        let clock = GeminiTestClock()
        let factory = GeminiTestSessionFactory(now: clock.now)
        let pool = GeminiLiveSessionPool(factory: factory.connect)
        await pool.prewarm(configuration: configuration())
        try await waitUntil { factory.sessions.count == 1 }
        clock.advance(by: .seconds(30))

        let session = try await pool.checkout(configuration: configuration(), onProgress: { _ in true })
        XCTAssertEqual(factory.sockets.count, 1)
        XCTAssertTrue(session === factory.sessions[0])
        await session.cancel()
        await pool.shutdown()
    }

    func testConnectionAgeIncludesSetupBeforeStandbyIsPrepared() async throws {
        let clock = GeminiTestClock()
        let socket = GeminiTestWebSocket(automaticallyCompleteSetup: false)
        let connect = Task { @Sendable [socket, clock] in
            try await GeminiLiveTranscriptionSession.connect(
                apiKey: "test-key", modelId: "test-model", mode: .verbatim,
                languageCodes: [], customVocabulary: [], socket: socket, now: clock.now
            )
        }
        try await waitUntil { !socket.sentMessages.isEmpty }
        clock.advance(by: .seconds(58))
        socket.enqueue(#"{"setupComplete":{}}"#)
        let session = try await connect.value
        // There is no idle deadline yet. The absolute connection age must still
        // reserve recording time plus the default five-second finish limit.
        let claimed = await session.claim(onProgress: { _ in true }, onFinished: {})
        XCTAssertFalse(claimed)
        XCTAssertTrue(socket.isClosed)
        await session.cancel()
    }

    func testClaimedConnectionSurvivesFormerIdleDeadline() async throws {
        let factory = GeminiTestSessionFactory()
        let pool = GeminiLiveSessionPool(
            idleTimeout: .milliseconds(100), pingInterval: .milliseconds(10), factory: factory.connect
        )
        await pool.prewarm(configuration: configuration())
        let session = try await pool.checkout(configuration: configuration(), onProgress: { _ in true })
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(factory.sockets[0].isClosed)
        try await session.appendAudio(samples: [0.1])
        await session.cancel()
        await pool.shutdown()
    }

    func testGoAwayDiscardsStandbyBeforeCheckout() async throws {
        let factory = GeminiTestSessionFactory()
        let pool = GeminiLiveSessionPool(factory: factory.connect)
        await pool.prewarm(configuration: configuration())
        try await waitUntil { factory.sessions.count == 1 }
        try await factory.sessions[0].handle(.string(#"{"goAway":{"timeLeft":"1s"}}"#))
        XCTAssertTrue(factory.sockets[0].isClosed)
        let session = try await pool.checkout(configuration: configuration(), onProgress: { _ in true })
        XCTAssertEqual(factory.sockets.count, 2)
        await session.cancel()
        await pool.shutdown()
    }

    func testFailedWarmConnectionFallsBackToFreshConnection() async throws {
        let factory = GeminiTestSessionFactory()
        let pool = GeminiLiveSessionPool(factory: factory.connect)
        await pool.prewarm(configuration: configuration())
        try await waitUntil { factory.sessions.count == 1 }
        factory.sockets[0].close(code: .abnormalClosure)
        // Deliver the receive failure before claiming the standby connection.
        try await Task.sleep(for: .milliseconds(25))
        let session = try await pool.checkout(configuration: configuration(), onProgress: { _ in true })
        XCTAssertEqual(factory.sockets.count, 2)
        await session.cancel()
        await pool.shutdown()
    }

    func testConcurrentCheckoutsNeverShareSession() async throws {
        let factory = GeminiTestSessionFactory()
        let pool = GeminiLiveSessionPool(factory: factory.connect)
        await pool.prewarm(configuration: configuration())
        async let first = pool.checkout(configuration: configuration(), onProgress: { _ in true })
        async let second = pool.checkout(configuration: configuration(), onProgress: { _ in true })
        let sessions = try await [first, second]
        XCTAssertFalse(sessions[0] === sessions[1])
        XCTAssertEqual(factory.sockets.count, 2)
        for session in sessions { await session.cancel() }
        await pool.shutdown()
    }

    func testFailedWarmSetupIsRetriedForCheckout() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let factory = GeminiTestSessionFactory()
        let pool = GeminiLiveSessionPool { configuration in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw URLError(.cannotConnectToHost) }
            return try await factory.connect(configuration)
        }
        await pool.prewarm(configuration: configuration())
        try await waitUntil { attempts.withLock { $0 } == 1 }
        let session = try await pool.checkout(configuration: configuration(), onProgress: { _ in true })
        XCTAssertEqual(attempts.withLock { $0 }, 2)
        await session.cancel()
        await pool.shutdown()
    }

    func testShutdownCancelsInFlightSetup() async throws {
        let factory = GeminiTestSessionFactory(automaticallyCompleteSetup: false)
        let pool = GeminiLiveSessionPool(factory: factory.connect)
        await pool.prewarm(configuration: configuration())
        try await waitUntil { factory.sockets.count == 1 }
        await pool.shutdown()
        try await waitUntil { factory.sockets[0].isClosed }
        await pool.prewarm(configuration: configuration())
        XCTAssertEqual(factory.sockets.count, 1)
        do {
            _ = try await pool.checkout(configuration: configuration(), onProgress: { _ in true })
            XCTFail("A stopped pool must not reconnect")
        } catch is CancellationError {}
    }

    func testFinishingActiveSessionAfterShutdownCannotReopenStandby() async throws {
        let factory = GeminiTestSessionFactory()
        let pool = GeminiLiveSessionPool(factory: factory.connect)
        let session = try await pool.checkout(configuration: configuration(), onProgress: { _ in true })
        await pool.shutdown()
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Done"},"turnComplete":true}}"#))
        _ = try await session.finish()
        XCTAssertEqual(factory.sockets.count, 1)
    }

    func testCancellationDuringWarmCheckoutClosesSocketWithoutRetry() async throws {
        let factory = GeminiTestSessionFactory(automaticallyCompleteSetup: false)
        let pool = GeminiLiveSessionPool(factory: factory.connect)
        await pool.prewarm(configuration: configuration())
        try await waitUntil { factory.sockets.count == 1 }
        let checkout = Task { try await pool.checkout(configuration: configuration(), onProgress: { _ in true }) }
        try await Task.sleep(for: .milliseconds(25))
        checkout.cancel()
        do {
            _ = try await checkout.value
            XCTFail("Checkout cancellation must propagate")
        } catch is CancellationError {}
        try await waitUntil { factory.sockets[0].isClosed }
        XCTAssertEqual(factory.sockets.count, 1)
        await pool.shutdown()
    }
}

private func configuration(
    apiKey: String = "test-key", modelId: String = "gemini-3.5-transcribe-live",
    mode: GeminiTranscriptionMode = .verbatim, languageCodes: [String] = ["ru-RU"],
    vocabulary: [String] = ["TypeWhisper"]
) -> GeminiLiveConfiguration {
    GeminiLiveConfiguration(
        apiKey: apiKey, modelId: modelId, mode: mode,
        languageCodes: languageCodes, customVocabulary: vocabulary
    )
}

private final class GeminiTestSessionFactory: @unchecked Sendable {
    private struct State {
        var sockets: [GeminiTestWebSocket] = []
        var sessions: [GeminiLiveTranscriptionSession] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let automaticallyCompleteSetup: Bool
    private let now: @Sendable () -> ContinuousClock.Instant
    var sockets: [GeminiTestWebSocket] { state.withLock { $0.sockets } }
    var sessions: [GeminiLiveTranscriptionSession] { state.withLock { $0.sessions } }

    init(
        automaticallyCompleteSetup: Bool = true,
        now: @Sendable @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.automaticallyCompleteSetup = automaticallyCompleteSetup
        self.now = now
    }

    func connect(_ configuration: GeminiLiveConfiguration) async throws -> GeminiLiveTranscriptionSession {
        let socket = GeminiTestWebSocket(automaticallyCompleteSetup: automaticallyCompleteSetup)
        state.withLock { $0.sockets.append(socket) }
        let session = try await GeminiLiveTranscriptionSession.connect(
            apiKey: configuration.apiKey, modelId: configuration.modelId, mode: configuration.mode,
            languageCodes: configuration.languageCodes, customVocabulary: configuration.customVocabulary,
            socket: socket, finishTimeout: .milliseconds(400), completionSettleTime: .milliseconds(5), now: now
        )
        state.withLock { $0.sessions.append(session) }
        return session
    }
}

final class GeminiTestClock: @unchecked Sendable {
    private let time = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
    func now() -> ContinuousClock.Instant { time.withLock { $0 } }
    func advance(by duration: Duration) { time.withLock { $0 = $0.advanced(by: duration) } }
}
