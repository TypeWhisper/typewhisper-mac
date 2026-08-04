import Foundation
import os
import XCTest
@testable import TypeWhisper

private final class FakeMeetingCameraActivityClient: MeetingCameraActivityClient, @unchecked Sendable {
    private struct State {
        var startResult = true
        var availability = MeetingActivityAvailability.available
        var isAnyCameraRunning = false
        var handler: (@Sendable () -> Void)?
        var startCount = 0
        var stopCount = 0
        var snapshotCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func configure(
        startResult: Bool = true,
        availability: MeetingActivityAvailability = .available,
        isAnyCameraRunning: Bool = false
    ) {
        state.withLock {
            $0.startResult = startResult
            $0.availability = availability
            $0.isAnyCameraRunning = isAnyCameraRunning
        }
    }

    func start(changeHandler: @escaping @Sendable () -> Void) -> Bool {
        state.withLock {
            $0.startCount += 1
            $0.handler = changeHandler
            return $0.startResult
        }
    }

    func snapshot(at date: Date) -> MeetingCameraActivitySnapshot {
        state.withLock {
            $0.snapshotCount += 1
            return MeetingCameraActivitySnapshot(
                capturedAt: date,
                availability: $0.availability,
                isAnyCameraRunning: $0.isAnyCameraRunning
            )
        }
    }

    func stop() {
        state.withLock {
            $0.stopCount += 1
            $0.handler = nil
        }
    }

    func notify() {
        let handler = state.withLock { $0.handler }
        handler?()
    }

    var counts: (start: Int, stop: Int, snapshot: Int) {
        state.withLock { ($0.startCount, $0.stopCount, $0.snapshotCount) }
    }
}

final class MeetingCameraActivityCollectorTests: XCTestCase {
    func testCoreMediaIOClientReadsPublicCameraRunningState() throws {
        let client = CoreMediaIOCameraActivityClient()
        defer { client.stop() }

        guard client.start(changeHandler: {}) else {
            throw XCTSkip("CoreMediaIO camera metadata is unavailable on this host")
        }
        XCTAssertEqual(client.snapshot(at: Date()).availability, .available)
    }

    func testUnsupportedClientFailsClosedAndFinishesStream() async {
        let client = FakeMeetingCameraActivityClient()
        client.configure(startResult: false)
        let collector = MeetingCameraActivityCollector(client: client)
        var iterator = await collector.startCollecting().makeAsyncIterator()

        let unsupported = await iterator.next()
        let finished = await iterator.next()
        XCTAssertEqual(unsupported?.availability, .unsupported)
        XCTAssertNil(finished)
        XCTAssertEqual(client.counts.start, 1)
    }

    func testCollectorPublishesInitialAndChangedCameraState() async {
        let client = FakeMeetingCameraActivityClient()
        client.configure(isAnyCameraRunning: false)
        let collector = MeetingCameraActivityCollector(client: client)
        var iterator = await collector.startCollecting().makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial?.availability, .available)
        XCTAssertEqual(initial?.isAnyCameraRunning, false)

        client.configure(isAnyCameraRunning: true)
        client.notify()

        let changed = await iterator.next()
        XCTAssertEqual(changed?.availability, .available)
        XCTAssertEqual(changed?.isAnyCameraRunning, true)

        await collector.stopCollecting()
        XCTAssertEqual(client.counts.stop, 1)
        XCTAssertGreaterThanOrEqual(client.counts.snapshot, 2)
    }

    func testReleasingCollectorStopsClientWithoutExplicitStop() async {
        let client = FakeMeetingCameraActivityClient()
        var collector: MeetingCameraActivityCollector? = MeetingCameraActivityCollector(
            client: client
        )
        weak let weakCollector = collector
        _ = await collector?.startCollecting()

        collector = nil

        XCTAssertNil(weakCollector)
        XCTAssertEqual(client.counts.stop, 1)
    }
}
