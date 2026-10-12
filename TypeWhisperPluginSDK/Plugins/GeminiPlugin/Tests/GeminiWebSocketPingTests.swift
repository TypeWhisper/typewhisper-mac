import Foundation
import XCTest
@testable import GeminiPlugin

final class GeminiWebSocketPingTests: XCTestCase {
    func testPongHandlerCalledAgainAfterSuccessIsIgnored() async throws {
        try await GeminiWebSocketPing.send { pongReceiveHandler in
            pongReceiveHandler(nil)
            pongReceiveHandler(URLError(.cancelled))
        }
    }

    func testPongHandlerCalledAgainAfterFailureKeepsFirstError() async {
        do {
            try await GeminiWebSocketPing.send { pongReceiveHandler in
                pongReceiveHandler(URLError(.networkConnectionLost))
                pongReceiveHandler(URLError(.cancelled))
            }
            XCTFail("Expected the first ping error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
    }

    func testConcurrentPongHandlerCallsResumeOnce() async {
        for _ in 0..<100 {
            do {
                try await GeminiWebSocketPing.send { pongReceiveHandler in
                    DispatchQueue.concurrentPerform(iterations: 4) { _ in
                        pongReceiveHandler(URLError(.cancelled))
                    }
                }
                XCTFail("Expected the ping to fail")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .cancelled)
            }
        }
    }
}
