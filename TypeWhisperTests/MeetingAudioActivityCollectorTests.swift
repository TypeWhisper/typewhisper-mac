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
        var snapshotCount = 0
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
            $0.snapshotCount += 1
            return MeetingActivitySnapshot(
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

    var counts: (start: Int, restart: Int, stop: Int, snapshot: Int) {
        state.withLock {
            ($0.startCount, $0.restartCount, $0.stopCount, $0.snapshotCount)
        }
    }
}

final class MeetingAudioActivityCollectorTests: XCTestCase {
    func testCoreAudioClientStartsWithoutRequiringOptionalServiceRestartListener() throws {
        let client = CoreAudioMeetingProcessClient()
        defer { client.stop() }

        guard client.start(changeHandler: { _ in }) else {
            throw XCTSkip("CoreAudio process metadata is unavailable on this host")
        }
        XCTAssertEqual(client.snapshot(at: Date()).availability, .available)
    }

    func testNativeProcessRegistryMapsFaceTimeAudioServices() {
        XCTAssertEqual(
            NativeMeetingAudioProcessRegistry.provider(for: "com.apple.FaceTime"),
            .faceTime
        )
        XCTAssertEqual(
            NativeMeetingAudioProcessRegistry.provider(
                for: "com.apple.FaceTime.FTConversationService"
            ),
            .faceTime
        )
        XCTAssertEqual(
            NativeMeetingAudioProcessRegistry.provider(for: "com.apple.avconferenced"),
            .faceTime
        )
        XCTAssertEqual(
            NativeMeetingAudioProcessRegistry.provider(for: "com.apple.TelephonyUtilities"),
            .faceTime
        )
    }

    func testNativeProcessRegistryMapsZoomAndBothTeamsBundleIdentifiers() {
        let expectedProviders: [(String, MeetingProvider)] = [
            ("us.zoom.xos", .zoom),
            ("com.microsoft.teams2", .teams),
            ("com.microsoft.teams", .teams)
        ]

        for (bundleIdentifier, expectedProvider) in expectedProviders {
            XCTAssertEqual(
                NativeMeetingAudioProcessRegistry.provider(for: bundleIdentifier),
                expectedProvider,
                "Unexpected provider for \(bundleIdentifier)"
            )
        }
    }

    func testNativeProcessRegistryRejectsZoomAndTeamsLookalikes() {
        for bundleIdentifier in [
            "us.zoom.xos.helper",
            "com.microsoft.teams2.helper",
            "com.microsoft.teams.updater",
            "com.example.microsoft.teams"
        ] {
            XCTAssertNil(
                NativeMeetingAudioProcessRegistry.provider(for: bundleIdentifier),
                "Unexpected native meeting attribution for \(bundleIdentifier)"
            )
        }
    }

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

    func testPeriodicReconciliationRecoversMissedProcessPropertyCallbacks() async throws {
        let inactiveProcess = MeetingAudioProcess(
            audioObjectID: 42,
            processID: 900,
            bundleIdentifier: "com.apple.avconferenced",
            isRunningInput: false,
            isRunningOutput: false
        )
        let activeProcess = MeetingAudioProcess(
            audioObjectID: inactiveProcess.audioObjectID,
            processID: inactiveProcess.processID,
            bundleIdentifier: inactiveProcess.bundleIdentifier,
            isRunningInput: true,
            isRunningOutput: true
        )
        let client = FakeMeetingAudioProcessClient()
        client.configure(snapshot: MeetingActivitySnapshot(
            capturedAt: .distantPast,
            availability: .available,
            processes: [inactiveProcess]
        ))
        let collector = MeetingAudioActivityCollector(
            client: client,
            reconciliationInterval: .milliseconds(10)
        )
        let stream = await collector.startCollecting()
        try await Task.sleep(for: .milliseconds(20))

        client.configure(snapshot: MeetingActivitySnapshot(
            capturedAt: .distantPast,
            availability: .available,
            processes: [activeProcess]
        ))
        try await Task.sleep(for: .milliseconds(30))

        var iterator = stream.makeAsyncIterator()
        let reconciled = await iterator.next()
        XCTAssertEqual(reconciled?.processes, [activeProcess])
        XCTAssertGreaterThanOrEqual(client.counts.snapshot, 2)

        await collector.stopCollecting()
        let snapshotsAfterStop = client.counts.snapshot
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(client.counts.snapshot, snapshotsAfterStop)
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

    func testReleasingCollectorStopsClientWithoutExplicitStop() async {
        let client = FakeMeetingAudioProcessClient()
        client.configure(snapshot: MeetingActivitySnapshot(
            capturedAt: .distantPast,
            availability: .available,
            processes: []
        ))
        var collector: MeetingAudioActivityCollector? = MeetingAudioActivityCollector(client: client)
        weak let weakCollector = collector
        _ = await collector?.startCollecting()

        collector = nil

        XCTAssertNil(weakCollector)
        XCTAssertEqual(client.counts.stop, 1)
    }
}
