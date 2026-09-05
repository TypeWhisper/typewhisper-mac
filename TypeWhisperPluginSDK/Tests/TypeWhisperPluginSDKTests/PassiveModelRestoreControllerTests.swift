import XCTest
@testable import TypeWhisperPluginSDK

final class PassiveModelRestoreControllerTests: XCTestCase {
    func testConcurrentRequestsCoalesceWhileRestoreIsInFlight() async {
        let controller = PluginPassiveModelRestoreController()
        let started = expectation(description: "restore started once")
        started.assertForOverFulfill = true
        let release = AsyncRestoreBarrier()
        controller.request {
            started.fulfill()
            await release.wait()
        }
        await fulfillment(of: [started], timeout: 2)
        let pending = expectation(description: "pending requests coalesced")
        pending.assertForOverFulfill = true
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    controller.request { pending.fulfill() }
                }
            }
        }
        await release.open()
        await fulfillment(of: [pending], timeout: 2)
        controller.cancel()
    }

    func testCancelDoesNotLetOldCompletionClearNewRequest() async {
        let controller = PluginPassiveModelRestoreController()
        let oldStarted = expectation(description: "old restore started")
        let oldCompleted = expectation(description: "old restore completed")
        let oldRelease = AsyncRestoreBarrier()
        controller.request {
            oldStarted.fulfill()
            await oldRelease.wait()
            XCTAssertTrue(Task.isCancelled)
            oldCompleted.fulfill()
        }
        await fulfillment(of: [oldStarted], timeout: 2)
        controller.cancel()
        let newStarted = expectation(description: "new restore started")
        let newRelease = AsyncRestoreBarrier()
        controller.request {
            newStarted.fulfill()
            await newRelease.wait()
        }
        await fulfillment(of: [newStarted], timeout: 2)
        await oldRelease.open()
        await fulfillment(of: [oldCompleted], timeout: 2)
        // Give the old task's completion a chance to run before another request.
        for _ in 0..<10 { await Task.yield() }
        let pending = expectation(description: "request after new restore")
        let state = RestoreTestState()
        controller.request {
            let isAllowed = await state.isAllowed
            XCTAssertFalse(isAllowed, "Old completion cleared the new restore")
            pending.fulfill()
        }
        for _ in 0..<10 { await Task.yield() }
        await state.deselect()
        await newRelease.open()
        await fulfillment(of: [pending], timeout: 2)
        controller.cancel()
    }

    func testSerializedLoadRechecksLivePolicyAfterWaiting() async throws {
        let gate = PluginLocalInferenceGate()
        let state = RestoreTestState()
        let busy = expectation(description: "explicit load in flight")
        let release = AsyncRestoreBarrier()
        let explicit = Task {
            try await gate.withLock {
                busy.fulfill()
                await release.wait()
            }
        }
        await fulfillment(of: [busy], timeout: 2)
        let passive = Task {
            try await gate.withLock {
                guard await state.isAllowed else { return }
                await state.recordLoad()
            }
        }
        await state.deselect()
        await release.open()
        try await explicit.value
        try await passive.value
        let loads = await state.loads
        XCTAssertEqual(loads, 0)
    }
}

private actor AsyncRestoreBarrier {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor RestoreTestState {
    var isAllowed = true
    var loads = 0
    func deselect() { isAllowed = false }
    func recordLoad() { loads += 1 }
}
