import Foundation
import XCTest
@testable import TypeWhisper

final class CalendarMeetingAutomationPolicyTests: XCTestCase {
    private let identity = CalendarMeetingCanonicalLink(provider: .zoom, identity: "j/123456789")

    func testAutomaticStartRequiresThreeSecondDwellAndFiveSecondCountdown() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        var policy = CalendarMeetingAutomationPolicy()

        let configured = policy.reduce(.configure(
            configuration(mode: .automatic),
            occurrences: [occurrence],
            now: now
        ))
        XCTAssertTrue(configured.contains(.startActivityCollector))

        XCTAssertFalse(policy.reduce(.activity([signal(for: occurrence)], now: now)).contains {
            if case .showStartCountdown = $0 { return true }
            return false
        })

        let dwellEffects = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))
        let deadline = try XCTUnwrap(dwellEffects.compactMap { effect -> Date? in
            guard case .showStartCountdown(let candidate, let deadline) = effect else { return nil }
            XCTAssertEqual(candidate.id, occurrence.id)
            return deadline
        }.first)
        XCTAssertEqual(deadline, now.addingTimeInterval(8))

        let startEffects = policy.reduce(.timeAdvanced(deadline))
        XCTAssertTrue(startEffects.contains(.startRecording(occurrence, identity)))
    }

    func testSignalLossCancelsCountdownAndLaterStableSignalCanRetry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(configuration(mode: .automatic), occurrences: [occurrence], now: now))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))

        XCTAssertEqual(
            policy.reduce(.activity([], now: now.addingTimeInterval(4))),
            [.dismissStartCountdown]
        )
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now.addingTimeInterval(5)))
        let retried = policy.reduce(.timeAdvanced(now.addingTimeInterval(8)))
        XCTAssertTrue(retried.contains {
            if case .showStartCountdown = $0 { return true }
            return false
        })
    }

    func testChangingMeetingIdentityRestartsStableInputDwell() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secondIdentity = CalendarMeetingCanonicalLink(provider: .zoom, identity: "j/987654321")
        let occurrence = makeCalendarMeetingTestOccurrence(
            start: now,
            links: [identity, secondIdentity]
        )
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(configuration(mode: .automatic), occurrences: [occurrence], now: now))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))

        _ = policy.reduce(.activity([
            CalendarMeetingJoinSignal(
                occurrenceDigest: occurrence.id,
                meetingIdentity: secondIdentity,
                quality: .nativeProvider,
                isRunningInput: true,
                isRunningOutput: false
            )
        ], now: now.addingTimeInterval(2)))

        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(3))).contains {
            if case .showStartCountdown = $0 { return true }
            return false
        })
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(5))).contains {
            if case .showStartCountdown = $0 { return true }
            return false
        })
    }

    func testEquivalentOverlappingNativeCandidatesNeverAutoStart() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeCalendarMeetingTestOccurrence(eventID: "one", start: now)
        let second = makeCalendarMeetingTestOccurrence(eventID: "two", start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic),
            occurrences: [first, second],
            now: now
        ))
        _ = policy.reduce(.activity(
            [signal(for: first), signal(for: second)],
            now: now
        ))

        let effects = policy.reduce(.timeAdvanced(now.addingTimeInterval(30)))
        XCTAssertFalse(effects.contains {
            if case .showStartCountdown = $0 { return true }
            if case .startRecording = $0 { return true }
            return false
        })
    }

    func testPendingInvitationCanPublishDetectedReminderButCannotAutoStart() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let pending = makeCalendarMeetingTestOccurrence(start: now, participation: .pending)

        var reminderPolicy = CalendarMeetingAutomationPolicy()
        _ = reminderPolicy.reduce(.configure(
            configuration(mode: .reminder),
            occurrences: [pending],
            now: now
        ))
        _ = reminderPolicy.reduce(.activity([signal(for: pending)], now: now))
        XCTAssertTrue(reminderPolicy.reduce(.timeAdvanced(now.addingTimeInterval(3))).contains(
            .publishDetectedMeeting(pending)
        ))

        var automaticPolicy = CalendarMeetingAutomationPolicy()
        _ = automaticPolicy.reduce(.configure(
            configuration(mode: .automatic),
            occurrences: [pending],
            now: now
        ))
        _ = automaticPolicy.reduce(.activity([signal(for: pending)], now: now))
        XCTAssertFalse(automaticPolicy.reduce(.timeAdvanced(now.addingTimeInterval(10))).contains {
            if case .showStartCountdown = $0 { return true }
            return false
        })
    }

    func testBusyRecorderGetsExactlyOneIdleRetry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(configuration(mode: .automatic), occurrences: [occurrence], now: now))
        _ = policy.reduce(.recorderReadiness(.recorderBusy, now: now))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))

        let idle = policy.reduce(.recorderReadiness(.idle, now: now.addingTimeInterval(4)))
        XCTAssertEqual(idle.filter {
            if case .showStartCountdown = $0 { return true }
            return false
        }.count, 1)

        _ = policy.reduce(.recorderReadiness(.recorderBusy, now: now.addingTimeInterval(4.5)))
        let secondIdle = policy.reduce(.recorderReadiness(.idle, now: now.addingTimeInterval(4.75)))
        XCTAssertFalse(secondIdle.contains {
            if case .showStartCountdown = $0 { return true }
            return false
        })
    }

    func testStartRaceDeferredByBusyRecorderGetsOneIdleRetry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(configuration(mode: .automatic), occurrences: [occurrence], now: now))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))
        let startTime = now.addingTimeInterval(8)
        XCTAssertTrue(policy.reduce(.timeAdvanced(startTime)).contains(.startRecording(occurrence, identity)))

        _ = policy.reduce(.recordingStartDeferred(
            occurrenceDigest: occurrence.id,
            identity: identity,
            readiness: .recorderBusy,
            now: startTime
        ))
        let retry = policy.reduce(.recorderReadiness(.idle, now: startTime.addingTimeInterval(1)))

        XCTAssertEqual(retry.filter {
            if case .showStartCountdown = $0 { return true }
            return false
        }.count, 1)
    }

    func testMissingSourceIsPermanentForOccurrenceAndDoesNotIdleRetry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(configuration(mode: .automatic), occurrences: [occurrence], now: now))
        _ = policy.reduce(.recorderReadiness(.noAudioSource, now: now))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))

        let idle = policy.reduce(.recorderReadiness(.idle, now: now.addingTimeInterval(4)))
        let later = policy.reduce(.timeAdvanced(now.addingTimeInterval(30)))

        XCTAssertFalse((idle + later).contains {
            if case .showStartCountdown = $0 { return true }
            if case .startRecording = $0 { return true }
            return false
        })
    }

    func testModeChangeDismissesAutomaticCountdown() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(configuration(mode: .automatic), occurrences: [occurrence], now: now))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))

        let changed = policy.reduce(.configure(
            configuration(mode: .reminder),
            occurrences: [occurrence],
            now: now.addingTimeInterval(4)
        ))

        XCTAssertTrue(changed.contains(.dismissStartCountdown))
        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(8))).contains {
            if case .startRecording = $0 { return true }
            return false
        })
    }

    func testAutoStopUsesThirtySecondLossAndFifteenSecondVeto() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        let handle = CalendarMeetingRecordingHandle(
            id: UUID(),
            outputURL: URL(fileURLWithPath: "/tmp/meeting.wav")
        )
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic, autoStop: true),
            occurrences: [occurrence],
            now: now
        ))
        _ = policy.reduce(.recordingStarted(
            handle: handle,
            occurrenceDigest: occurrence.id,
            identity: identity,
            autoStopArmed: true,
            now: now
        ))

        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        _ = policy.reduce(.activity([], now: now))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(29))).isEmpty)
        let grace = policy.reduce(.timeAdvanced(now.addingTimeInterval(30)))
        XCTAssertEqual(grace, [.showStopCountdown(handle, deadline: now.addingTimeInterval(45))])

        let returned = policy.reduce(.activity([
            signal(for: occurrence, input: false, output: true)
        ], now: now.addingTimeInterval(35)))
        XCTAssertEqual(returned, [.dismissStopCountdown])

        _ = policy.reduce(.activity([], now: now.addingTimeInterval(36)))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(66)))
        let veto = policy.reduce(.userAction(.continueRecording(handle), now: now.addingTimeInterval(67)))
        XCTAssertEqual(veto, [.dismissStopCountdown, .stopActivityCollector])
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(200))).isEmpty)
    }

    func testAutoStopWaitsUntilMeetingSignalWasObserved() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        let handle = CalendarMeetingRecordingHandle(
            id: UUID(),
            outputURL: URL(fileURLWithPath: "/tmp/no-signal.wav")
        )
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic, autoStop: true),
            occurrences: [occurrence],
            now: now
        ))
        _ = policy.reduce(.recordingStarted(
            handle: handle,
            occurrenceDigest: occurrence.id,
            identity: identity,
            autoStopArmed: true,
            now: now
        ))

        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(300))).contains {
            if case .showStopCountdown = $0 { return true }
            if case .stopRecording = $0 { return true }
            return false
        })
    }

    func testUnavailableActivityDisarmsAutoStopWithoutStoppingRecording() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        let handle = CalendarMeetingRecordingHandle(
            id: UUID(),
            outputURL: URL(fileURLWithPath: "/tmp/unsupported.wav")
        )
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic, autoStop: true),
            occurrences: [occurrence],
            now: now
        ))
        _ = policy.reduce(.recordingStarted(
            handle: handle,
            occurrenceDigest: occurrence.id,
            identity: identity,
            autoStopArmed: true,
            now: now
        ))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))

        let unavailable = policy.reduce(.activityUnavailable(now: now.addingTimeInterval(1)))

        XCTAssertTrue(unavailable.contains(.stopActivityCollector))
        XCTAssertFalse(unavailable.contains(.stopRecording(handle)))
        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(300))).contains(
            .stopRecording(handle)
        ))
    }

    func testRecordedOccurrenceCannotRestartAfterManualStop() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        let handle = CalendarMeetingRecordingHandle(
            id: UUID(),
            outputURL: URL(fileURLWithPath: "/tmp/manual-stop.wav")
        )
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic),
            occurrences: [occurrence],
            now: now
        ))

        let started = policy.reduce(.recordingStarted(
            handle: handle,
            occurrenceDigest: occurrence.id,
            identity: identity,
            autoStopArmed: false,
            now: now
        ))
        XCTAssertTrue(started.contains(.stopActivityCollector))
        _ = policy.reduce(.recordingStopped(handle, now: now.addingTimeInterval(1)))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now.addingTimeInterval(2)))
        let later = policy.reduce(.timeAdvanced(now.addingTimeInterval(30)))

        XCTAssertFalse(later.contains {
            if case .showStartCountdown = $0 { return true }
            if case .startRecording = $0 { return true }
            return false
        })
    }

    func testGateLossDisarmsAutoStopWithoutStoppingRecording() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        let handle = CalendarMeetingRecordingHandle(id: UUID(), outputURL: URL(fileURLWithPath: "/tmp/a.wav"))
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic, autoStop: true),
            occurrences: [occurrence],
            now: now
        ))
        _ = policy.reduce(.recordingStarted(
            handle: handle,
            occurrenceDigest: occurrence.id,
            identity: identity,
            autoStopArmed: true,
            now: now
        ))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        _ = policy.reduce(.activity([], now: now))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(30)))

        let effects = policy.reduce(.configure(
            configuration(mode: .off, autoStop: false, premium: false),
            occurrences: [],
            now: now.addingTimeInterval(31)
        ))
        XCTAssertTrue(effects.contains(.dismissStopCountdown))
        XCTAssertFalse(effects.contains(.stopRecording(handle)))
        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(100))).contains(.stopRecording(handle)))
    }

    func testSuppressingAnotherOccurrenceDoesNotDisarmActiveRecordingAutoStop() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let activeOccurrence = makeCalendarMeetingTestOccurrence(eventID: "active", start: now)
        let otherOccurrence = makeCalendarMeetingTestOccurrence(eventID: "other", start: now)
        let handle = CalendarMeetingRecordingHandle(
            id: UUID(),
            outputURL: URL(fileURLWithPath: "/tmp/suppression.wav")
        )
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic, autoStop: true),
            occurrences: [activeOccurrence, otherOccurrence],
            now: now
        ))
        _ = policy.reduce(.recordingStarted(
            handle: handle,
            occurrenceDigest: activeOccurrence.id,
            identity: identity,
            autoStopArmed: true,
            now: now
        ))
        _ = policy.reduce(.activity([signal(for: activeOccurrence)], now: now))

        let reconfigured = policy.reduce(.configure(
            configuration(
                mode: .automatic,
                autoStop: true,
                suppressedDigests: [otherOccurrence.occurrenceDigest]
            ),
            occurrences: [activeOccurrence, otherOccurrence],
            now: now
        ))
        XCTAssertFalse(reconfigured.contains(.stopActivityCollector))

        _ = policy.reduce(.activity([], now: now))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(30))).contains(
            .showStopCountdown(handle, deadline: now.addingTimeInterval(45))
        ))
    }

    private func configuration(
        mode: CalendarMeetingStartMode,
        autoStop: Bool = false,
        premium: Bool = true,
        suppressedDigests: Set<String> = []
    ) -> CalendarMeetingAutomationConfiguration {
        CalendarMeetingAutomationConfiguration(
            hasPremiumAccess: premium,
            startMode: mode,
            autoStopEnabled: autoStop,
            calendarAuthorization: .fullAccess,
            selectedCalendarIDs: ["calendar-1"],
            enabledProviders: Set(MeetingProvider.allCases),
            suppressedOccurrenceDigests: suppressedDigests
        )
    }

    private func signal(
        for occurrence: CalendarMeetingOccurrence,
        input: Bool = true,
        output: Bool = false
    ) -> CalendarMeetingJoinSignal {
        CalendarMeetingJoinSignal(
            occurrenceDigest: occurrence.id,
            meetingIdentity: identity,
            quality: .nativeProvider,
            isRunningInput: input,
            isRunningOutput: output
        )
    }
}
