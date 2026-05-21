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
