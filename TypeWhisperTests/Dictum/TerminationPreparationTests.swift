import AppKit
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class TerminationPreparationTests: XCTestCase {
    func testSecondQuitWhileWaitingForInferenceRepliesOnce() async throws {
        let gate = PluginLocalInferenceGate()
        let preparation = TerminationPreparation(gate: gate)
        let release = InferenceRelease()
        let inferenceStarted = expectation(description: "local inference started")
        let inference = Task {
            try await gate.withLock {
                inferenceStarted.fulfill()
                await release.wait()
            }
        }
        await fulfillment(of: [inferenceStarted], timeout: 1.0)

        let replies = ReplyCounter()
        let replied = expectation(description: "termination replied")
        replied.assertForOverFulfill = false
        let reply: @MainActor () -> Void = {
            replies.count += 1
            replied.fulfill()
        }
        XCTAssertEqual(preparation.requestTermination(reply: reply), .terminateLater)
        XCTAssertEqual(preparation.requestTermination(reply: reply), .terminateLater)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(replies.count, 0, "The reply must wait for the running inference")

        await release.release()
        await fulfillment(of: [replied], timeout: 2.0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(replies.count, 1)
        try await inference.value

        do {
            _ = try await gate.withLock { true }
            XCTFail("Local inference must stay closed after the termination reply")
        } catch is CancellationError {
            // Expected.
        }
    }
}

@MainActor
private final class ReplyCounter {
    var count = 0
}

private actor InferenceRelease {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
