import Foundation
import os
import XCTest
@testable import TypeWhisper

private final class FakeMeetingAudioProcessClient: MeetingAudioProcessClient, @unchecked Sendable {
    private struct State {
        var startResult = true
        var restartResult = true
        var snapshot = MeetingActivitySnapshot(
            capturedAt: .distantPast,
            availability: .available,
            processes: []
        )
        var handler: (@Sendable (Bool) -> Void)?
        var startCount = 0
        var restartCount = 0
        var stopCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func configure(
        startResult: Bool = true,
        restartResult: Bool = true,
        snapshot: MeetingActivitySnapshot
    ) {
        state.withLock {
            $0.startResult = startResult
            $0.restartResult = restartResult
            $0.snapshot = snapshot
        }
    }

    func start(changeHandler: @escaping @Sendable (Bool) -> Void) -> Bool {
        state.withLock {
            $0.startCount += 1
            $0.handler = changeHandler
            return $0.startResult
        }
    }

    func restart(changeHandler: @escaping @Sendable (Bool) -> Void) -> Bool {
        state.withLock {
            $0.restartCount += 1
            $0.handler = changeHandler
            return $0.restartResult
        }
    }

    func snapshot(at date: Date) -> MeetingActivitySnapshot {
        state.withLock {
            MeetingActivitySnapshot(
                capturedAt: date,
                availability: $0.snapshot.availability,
                processes: $0.snapshot.processes
            )
        }
    }

    func stop() {
        state.withLock {
            $0.stopCount += 1
            $0.handler = nil
        }
    }

    func notify(requiresRebuild: Bool) {
        let handler = state.withLock { $0.handler }
        handler?(requiresRebuild)
    }

    var counts: (start: Int, restart: Int, stop: Int) {
        state.withLock { ($0.startCount, $0.restartCount, $0.stopCount) }
    }
}

final class MeetingAudioActivityCollectorTests: XCTestCase {
    func testUnsupportedClientFailsClosedAndFinishesStream() async {
        let client = FakeMeetingAudioProcessClient()
        client.configure(
            startResult: false,
            snapshot: MeetingActivitySnapshot(capturedAt: .distantPast, availability: .available, processes: [])
        )
        let collector = MeetingAudioActivityCollector(client: client)
        var iterator = await collector.startCollecting().makeAsyncIterator()

        let unsupported = await iterator.next()
        let finished = await iterator.next()
        XCTAssertEqual(unsupported?.availability, .unsupported)
        XCTAssertNil(finished)
        XCTAssertEqual(client.counts.start, 1)
    }

    func testCollectorPublishesInitialAndPropertyChangeSnapshots() async throws {
        let process = MeetingAudioProcess(
            audioObjectID: 42,
            processID: 900,
            bundleIdentifier: "us.zoom.xos",
            isRunningInput: true,
            isRunningOutput: false
        )
        let client = FakeMeetingAudioProcessClient()
        client.configure(snapshot: MeetingActivitySnapshot(
            capturedAt: .distantPast,
            availability: .available,
            processes: [process]
        ))
        let collector = MeetingAudioActivityCollector(client: client)
        var iterator = await collector.startCollecting().makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial?.processes, [process])
        client.notify(requiresRebuild: false)
        let changed = await iterator.next()
        XCTAssertEqual(changed?.processes, [process])

        await collector.stopCollecting()
        XCTAssertEqual(client.counts.stop, 1)
    }

    func testHALRestartRebuildFailurePublishesUnsupportedAndTearsDown() async {
        let client = FakeMeetingAudioProcessClient()
        client.configure(
            restartResult: false,
            snapshot: MeetingActivitySnapshot(capturedAt: .distantPast, availability: .available, processes: [])
        )
        let collector = MeetingAudioActivityCollector(client: client)
        var iterator = await collector.startCollecting().makeAsyncIterator()
        _ = await iterator.next()

        client.notify(requiresRebuild: true)

        let unsupported = await iterator.next()
        let finished = await iterator.next()
        XCTAssertEqual(unsupported?.availability, .unsupported)
        XCTAssertNil(finished)
        XCTAssertEqual(client.counts.restart, 1)
        XCTAssertEqual(client.counts.stop, 1)
    }
}
