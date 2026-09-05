import Foundation
import XCTest
@_spi(Testing) @testable import TypeWhisperPluginSDK

final class PluginHTTPClientTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClient.resetTestingHooks()
        super.tearDown()
    }

    func testHTTPClientReusesSharedSessionAcrossRequests() async throws {
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [.success(Self.okResponse())])
        }

        _ = try await PluginHTTPClient.data(for: Self.request(path: "/first"))
        _ = try await PluginHTTPClient.data(for: Self.request(path: "/second"))

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/first", "/second"])
    }

    func testHTTPClientResetInvalidatesSharedSessionAndCreatesNewOne() async throws {
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [.success(Self.okResponse())])
        }

        _ = try await PluginHTTPClient.data(for: Self.request(path: "/before-reset"))
        PluginHTTPClient.resetSharedSession(reason: "test reset")
        _ = try await PluginHTTPClient.data(for: Self.request(path: "/after-reset"))

        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertTrue(store.sessions[0].didInvalidate)
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/before-reset"])
        XCTAssertEqual(store.sessions[1].requestedPaths, ["/after-reset"])
    }

    func testHTTPClientRetriesTransientURLErrorAfterResettingSession() async throws {
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            if store.sessions.isEmpty {
                return store.makeSession(outcomes: [.failure(URLError(.networkConnectionLost))])
            }
            return store.makeSession(outcomes: [.success(Self.okResponse())])
        }

        let (data, response) = try await PluginHTTPClient.data(for: Self.request(path: "/retry"))

        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertTrue(store.sessions[0].didInvalidate)
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/retry"])
        XCTAssertEqual(store.sessions[1].requestedPaths, ["/retry"])
    }

    func testHTTPClientResourceTimeoutAllowsLongRunningRequests() async throws {
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { configuration in
            store.makeSession(outcomes: [.success(Self.okResponse())], configuration: configuration)
        }

        var request = Self.request(path: "/long-running")
        request.timeoutInterval = 600

        _ = try await PluginHTTPClient.data(for: request)

        XCTAssertEqual(store.configurations.first?.timeoutIntervalForRequest, 30)
        XCTAssertEqual(store.configurations.first?.timeoutIntervalForResource, 600)
        XCTAssertEqual(store.sessions.first?.requestedRequests.first?.timeoutInterval, 600)
    }

    func testHTTPClientDisablesNetworkForScreenshotAutomation() {
        XCTAssertFalse(
            PluginHTTPClient.networkAccessAllowed(arguments: ["TypeWhisper", "--store-screenshots"])
        )
        XCTAssertTrue(
            PluginHTTPClient.networkAccessAllowed(arguments: ["TypeWhisper", "--ui-testing"])
        )
    }

    func testDirectClientNetworkGateFailsClosedForScreenshotAutomation() throws {
        XCTAssertThrowsError(
            try PluginHTTPClient.ensureNetworkAccessIsAllowed(
                arguments: ["TypeWhisper", "--store-screenshots"]
            )
        ) { error in
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        XCTAssertNoThrow(
            try PluginHTTPClient.ensureNetworkAccessIsAllowed(
                arguments: ["TypeWhisper", "--ui-testing"]
            )
        )
    }

    // MARK: - Transient HTTP STATUS retry
    //
    // Before this ladder existed the client retried only THROWN URLErrors. A
    // delivered response carrying 503, or Cloudflare's 522, never threw, so it was
    // handed straight back to the plugin and failed the dictation outright.

    func testRetriesRetryableStatusThenSucceeds() async throws {
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .success(Self.statusResponse(503)),
                .success(Self.okResponse()),
            ])
        }
        let recorder = DelayRecorder()
        PluginHTTPClient.configureRetryForTesting(sleeper: { await recorder.record($0) })

        let (data, response) = try await PluginHTTPClient.data(for: Self.request(path: "/flaky"))

        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/flaky", "/flaky"])
        let delays = await recorder.delays
        XCTAssertEqual(delays, [.milliseconds(500)])
    }

    func testCloudflare522IsRetried() async throws {
        // The 2026-09-03 incident shape: Cloudflare in front of a transcription API
        // answering 522 while the origin was unreachable.
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .success(Self.statusResponse(522)),
                .success(Self.okResponse()),
            ])
        }
        PluginHTTPClient.configureRetryForTesting(sleeper: { _ in })

        let (_, response) = try await PluginHTTPClient.data(for: Self.request(path: "/522"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(store.sessions.first?.requestedPaths.count, 2)
    }

    func testDoesNotRetryNonRetryableStatus() async throws {
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .success(Self.statusResponse(400)),
                .success(Self.okResponse()),
            ])
        }
        PluginHTTPClient.configureRetryForTesting(sleeper: { _ in })

        let (_, response) = try await PluginHTTPClient.data(for: Self.request(path: "/bad"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/bad"])
    }

    func testDoesNotRetryHeaderless429() async throws {
        // No header means the origin told us nothing actionable, and the plugins above
        // already map 429 to a quota or rate-limit error. A quota will not clear inside
        // this budget.
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .success(Self.statusResponse(429)),
                .success(Self.okResponse()),
            ])
        }
        let recorder = DelayRecorder()
        PluginHTTPClient.configureRetryForTesting(sleeper: { await recorder.record($0) })

        let (_, response) = try await PluginHTTPClient.data(for: Self.request(path: "/429"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/429"])
        let delays = await recorder.delays
        XCTAssertTrue(delays.isEmpty, "a headerless rate limit must reach the plugin at once")
    }

    func testRetries429ExactlyOnceWhenRetryAfterSaysWhen() async throws {
        // A provider throttling a burst sends Retry-After with a small value. Honouring
        // it once is actionable; laddering is not, so the grace is single-shot.
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .success(Self.statusResponse(429, retryAfter: "2")),
                .success(Self.statusResponse(429, retryAfter: "2")),
                .success(Self.okResponse()),
            ])
        }
        let recorder = DelayRecorder()
        PluginHTTPClient.configureRetryForTesting(sleeper: { await recorder.record($0) })

        let (_, response) = try await PluginHTTPClient.data(for: Self.request(path: "/429ra"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 429,
                       "the grace is one retry, so the second 429 is returned")
        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/429ra", "/429ra"])
        let delays = await recorder.delays
        XCTAssertEqual(delays, [.seconds(2)])
    }

    func testOversizedRetryAfterIsIgnoredRatherThanCrashing() async throws {
        // Regression. Double("999999999999999999999999") is finite and non-negative, so
        // an isFinite guard passes it, and Duration.seconds then TRAPS on overflow,
        // killing the process. Reachable from any provider's proxy, mid-dictation.
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .success(Self.statusResponse(503, retryAfter: "999999999999999999999999")),
                .success(Self.okResponse()),
            ])
        }
        let recorder = DelayRecorder()
        PluginHTTPClient.configureRetryForTesting(sleeper: { await recorder.record($0) }, jitterFraction: { 1.0 })

        let (_, response) = try await PluginHTTPClient.data(for: Self.request(path: "/huge-ra"))

        // Survives, ignores the unusable header, and falls back to the ordinary ladder.
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let delays = await recorder.delays
        XCTAssertEqual(delays, [.milliseconds(500)])
    }

    func testGatewayStatusesAreRetriedOnlyForIdempotentMethods() async throws {
        // 504 and Cloudflare 524 do NOT establish that the origin skipped the work, so
        // repeating a POST could duplicate it.
        let post = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            post.makeSession(outcomes: [.success(Self.statusResponse(504)), .success(Self.okResponse())])
        }
        PluginHTTPClient.configureRetryForTesting(sleeper: { _ in })
        var postRequest = Self.request(path: "/504")
        postRequest.httpMethod = "POST"
        let (_, postResponse) = try await PluginHTTPClient.data(for: postRequest)
        XCTAssertEqual((postResponse as? HTTPURLResponse)?.statusCode, 504)
        XCTAssertEqual(post.sessions.first?.requestedPaths, ["/504"])

        PluginHTTPClient.resetTestingHooks()
        let get = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            get.makeSession(outcomes: [.success(Self.statusResponse(504)), .success(Self.okResponse())])
        }
        PluginHTTPClient.configureRetryForTesting(sleeper: { _ in })
        var getRequest = Self.request(path: "/504")
        getRequest.httpMethod = "GET"
        let (_, getResponse) = try await PluginHTTPClient.data(for: getRequest)
        XCTAssertEqual((getResponse as? HTTPURLResponse)?.statusCode, 200,
                       "a GET is safe to repeat, so it rides the ladder")
        XCTAssertEqual(get.sessions.first?.requestedPaths, ["/504", "/504"])
    }

    func testDisabledPolicySkipsTheLadder() async throws {
        // Opt-out for pollers, self-retrying callers, and teardown.
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [.success(Self.statusResponse(503)), .success(Self.okResponse())])
        }
        let recorder = DelayRecorder()
        PluginHTTPClient.configureRetryForTesting(sleeper: { await recorder.record($0) })

        let (_, response) = try await PluginHTTPClient.data(
            for: Self.request(path: "/opted-out"), retry: .disabled
        )

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/opted-out"])
        let delays = await recorder.delays
        XCTAssertTrue(delays.isEmpty)
    }

    func testTimeoutStillGetsTheCompatibilityImmediateRetry() async throws {
        // This asserted the OPPOSITE until CodeRabbit caught it. Narrowing the
        // immediate retry to stale-pool codes ALTERED pre-existing behaviour rather
        // than adding to it, and it meant one timeout aborted the very poll loops that
        // opt out with `.disabled`. Any transient error still gets one immediate retry
        // after the session reset, exactly as before the ladder existed.
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            if store.sessions.isEmpty {
                return store.makeSession(outcomes: [.failure(URLError(.timedOut))])
            }
            return store.makeSession(outcomes: [.success(Self.okResponse())])
        }
        let recorder = DelayRecorder()
        PluginHTTPClient.configureRetryForTesting(sleeper: { await recorder.record($0) })

        let (_, response) = try await PluginHTTPClient.data(for: Self.request(path: "/slow"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let delays = await recorder.delays
        XCTAssertTrue(delays.isEmpty, "the compatibility retry is immediate, not backed off")
    }

    func testDisabledPolicyStillGetsTheCompatibilityTransportRetry() async throws {
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            if store.sessions.isEmpty {
                return store.makeSession(outcomes: [.failure(URLError(.timedOut))])
            }
            return store.makeSession(outcomes: [.success(Self.okResponse())])
        }
        PluginHTTPClient.configureRetryForTesting(sleeper: { _ in })

        let (_, response) = try await PluginHTTPClient.data(
            for: Self.request(path: "/opted-out-transient"), retry: .disabled
        )

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "an opted-out poll loop must survive a transient error as it did before")
    }

    func testLadderedTransportRetriesAreIdempotentOnly() async throws {
        // A POST can time out AFTER the origin processed it, so it gets the single
        // compatibility retry and no ladder.
        let post = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            post.makeSession(outcomes: [.failure(URLError(.timedOut))])
        }
        PluginHTTPClient.configureRetryForTesting(sleeper: { _ in })
        var postRequest = Self.request(path: "/post-timeout")
        postRequest.httpMethod = "POST"
        do {
            _ = try await PluginHTTPClient.data(for: postRequest)
            XCTFail("a POST must not ride the transport ladder")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(post.sessions.flatMap(\.requestedPaths).count, 2,
                       "initial attempt plus the one compatibility retry")

        PluginHTTPClient.resetTestingHooks()
        let get = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            get.makeSession(outcomes: [.failure(URLError(.timedOut))])
        }
        PluginHTTPClient.configureRetryForTesting(sleeper: { _ in })
        var getRequest = Self.request(path: "/get-timeout")
        getRequest.httpMethod = "GET"
        do {
            _ = try await PluginHTTPClient.data(for: getRequest)
            XCTFail("expected exhaustion")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(get.sessions.flatMap(\.requestedPaths).count,
                       PluginHTTPClient.retryMaxAttempts,
                       "a GET is safe to repeat, so it uses the whole ladder")
    }

    func testDoesNotRetryServerError500() async throws {
        // Deliberate exclusion: this client is shared by plugins that POST
        // side-effecting requests, and a 500 can mean the origin accepted the work
        // and then failed partway.
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .success(Self.statusResponse(500)),
                .success(Self.okResponse()),
            ])
        }
        PluginHTTPClient.configureRetryForTesting(sleeper: { _ in })

        let (_, response) = try await PluginHTTPClient.data(for: Self.request(path: "/500"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 500)
        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/500"])
    }

    func testReturnsLastResponseWhenAttemptsAreExhausted() async throws {
        // Exhaustion RETURNS the real response rather than throwing, so the caller
        // still sees the status and body and renders its own error.
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [.success(Self.statusResponse(503))])
        }
        PluginHTTPClient.configureRetryForTesting(sleeper: { _ in })

        let (_, response) = try await PluginHTTPClient.data(for: Self.request(path: "/always-503"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(store.sessions.first?.requestedPaths.count, PluginHTTPClient.retryMaxAttempts)
    }

    func testBackoffScheduleDoublesAcrossTheWholeLadder() async throws {
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [.success(Self.statusResponse(503))])
        }
        let recorder = DelayRecorder()
        // jitterFraction 1.0 gives the un-jittered upper bound, which is the readable
        // thing to assert; full jitter draws uniformly below each of these.
        PluginHTTPClient.configureRetryForTesting(
            sleeper: { await recorder.record($0) },
            jitterFraction: { 1.0 }
        )

        _ = try await PluginHTTPClient.data(for: Self.request(path: "/ladder"))

        let delays = await recorder.delays
        XCTAssertEqual(
            delays,
            [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)]
        )
    }

    func testBackoffIsCappedAtMaxDelayBeyondTheLadder() async throws {
        // The ladder that `retryMaxAttempts` permits tops out at exactly
        // `retryMaxDelay`, so the cap is a no-op for every delay the loop actually
        // takes and the schedule test above cannot exercise it. Mutation testing
        // caught that: deleting `min(..., retryMaxDelay)` left the whole suite green.
        // This asserts the cap directly, at an attempt the current bound never
        // reaches, so the cap stays honest if that bound is ever raised.
        PluginHTTPClient.configureRetryForTesting(sleeper: { _ in }, jitterFraction: { 1.0 })
        let deadline = ContinuousClock.now + .seconds(600)

        let capped = PluginHTTPClient.backoffDelay(forAttempt: 10, deadline: deadline, retryAfter: nil)

        // Uncapped this would be 0.5s * 2^10 = 512s.
        XCTAssertEqual(capped, PluginHTTPClient.retryMaxDelay)
    }

    func testHonoursRetryAfterHeaderWithinBudget() async throws {
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .success(Self.statusResponse(503, retryAfter: "3")),
                .success(Self.okResponse()),
            ])
        }
        let recorder = DelayRecorder()
        PluginHTTPClient.configureRetryForTesting(sleeper: { await recorder.record($0) })

        let (_, response) = try await PluginHTTPClient.data(for: Self.request(path: "/503-retry-after"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let delays = await recorder.delays
        XCTAssertEqual(delays, [.seconds(3)], "Retry-After must win over the ladder")
    }

    func testStopsWhenRetryAfterExceedsRemainingBudget() async throws {
        // Sleeping past the deadline is worse than giving up: the user is waiting.
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [.success(Self.statusResponse(503, retryAfter: "600"))])
        }
        let recorder = DelayRecorder()
        PluginHTTPClient.configureRetryForTesting(sleeper: { await recorder.record($0) })

        let (_, response) = try await PluginHTTPClient.data(for: Self.request(path: "/503-long"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/503-long"])
        let delays = await recorder.delays
        XCTAssertTrue(delays.isEmpty, "must not sleep at all when Retry-After overshoots")
    }

    func testFirstTransportRetryStaysImmediate() async throws {
        // Preserves the pre-existing behaviour: the usual cause is a stale pooled
        // connection, which the session reset has just fixed, so sleeping would only
        // add latency.
        let store = MockHTTPSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            if store.sessions.isEmpty {
                return store.makeSession(outcomes: [.failure(URLError(.networkConnectionLost))])
            }
            return store.makeSession(outcomes: [.success(Self.okResponse())])
        }
        let recorder = DelayRecorder()
        PluginHTTPClient.configureRetryForTesting(sleeper: { await recorder.record($0) })

        let (_, response) = try await PluginHTTPClient.data(for: Self.request(path: "/transient"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let delays = await recorder.delays
        XCTAssertTrue(delays.isEmpty, "the first transport retry must not back off")
    }

    private static func statusResponse(_ code: Int, retryAfter: String? = nil) -> (Data, URLResponse) {
        let url = URL(string: "https://example.test/status")!
        var headers: [String: String] = [:]
        if let retryAfter {
            headers["Retry-After"] = retryAfter
        }
        let response = HTTPURLResponse(
            url: url, statusCode: code, httpVersion: nil, headerFields: headers
        )!
        return (Data("status-\(code)".utf8), response)
    }

    private static func request(path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://example.test\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = Data("payload".utf8)
        return request
    }

    private static func okResponse() -> (Data, URLResponse) {
        let url = URL(string: "https://example.test/ok")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("ok".utf8), response)
    }
}

private final class MockHTTPSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sessions: [MockHTTPSession] = []
    private(set) var configurations: [URLSessionConfiguration] = []

    func makeSession(
        outcomes: [Result<(Data, URLResponse), Error>],
        configuration: URLSessionConfiguration? = nil
    ) -> MockHTTPSession {
        let session = MockHTTPSession(outcomes: outcomes)
        lock.withLock {
            sessions.append(session)
            if let configuration {
                configurations.append(configuration)
            }
        }
        return session
    }
}

private final class MockHTTPSession: PluginHTTPClientSession, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Result<(Data, URLResponse), Error>]
    private(set) var requestedPaths: [String] = []
    private(set) var requestedRequests: [URLRequest] = []
    private(set) var didInvalidate = false

    init(outcomes: [Result<(Data, URLResponse), Error>]) {
        self.outcomes = outcomes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let outcome = lock.withLock {
            requestedRequests.append(request)
            requestedPaths.append(request.url?.path ?? "")
            if outcomes.count > 1 {
                return outcomes.removeFirst()
            }
            return outcomes.first ?? .failure(URLError(.badServerResponse))
        }

        return try outcome.get()
    }

    func finishTasksAndInvalidate() {
        lock.withLock {
            didInvalidate = true
        }
    }
}

private actor DelayRecorder {
    private(set) var delays: [Duration] = []

    func record(_ delay: Duration) {
        delays.append(delay)
    }
}
