import Foundation
import XCTest
@testable import TypeWhisper

final class CalendarMeetingAutomationPolicyTests: XCTestCase {
    private let identity = CalendarMeetingCanonicalLink(provider: .zoom, identity: "j/123456789")

    func testFreeAndOffConfigurationsNeverRequestAudioOrCameraCollectors() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)

        for configuration in [
            configuration(mode: .automatic, premium: false),
            configuration(mode: .off, premium: true)
        ] {
            var policy = CalendarMeetingAutomationPolicy()
            let effects = policy.reduce(.configure(
                configuration,
                occurrences: [occurrence],
                now: now
            ))
            XCTAssertFalse(effects.contains(.startActivityCollector))
            XCTAssertFalse(effects.contains(.startCameraActivityCollector))
        }
    }

    func testReminderActionArmsOccurrenceWithoutStartingUntilStableJoinAndCountdown() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now.addingTimeInterval(5 * 60))
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .reminder),
            occurrences: [occurrence],
            now: now
        ))

        let armed = policy.reduce(.userAction(.armOccurrence(occurrence.id), now: now))
        XCTAssertFalse(armed.contains {
            if case .showStartCountdown = $0 { return true }
            if case .startRecording = $0 { return true }
            return false
        })

        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        let joined = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))
        let deadline = try XCTUnwrap(joined.compactMap { effect -> Date? in
            guard case .showStartCountdown(let candidate, let deadline) = effect else { return nil }
            XCTAssertEqual(candidate.id, occurrence.id)
            return deadline
        }.first)
        XCTAssertEqual(deadline, now.addingTimeInterval(8))
        XCTAssertTrue(policy.reduce(.timeAdvanced(deadline)).contains(
            .startRecording(occurrence, identity)
        ))
    }

    func testDetectedReminderActionUsesExistingStableDwellButStillShowsCountdown() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .reminder),
            occurrences: [occurrence],
            now: now
        ))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        XCTAssertEqual(
            policy.reduce(.timeAdvanced(now.addingTimeInterval(3))),
            [.publishDetectedMeeting(occurrence)]
        )

        let armed = policy.reduce(.userAction(
            .armOccurrence(occurrence.id),
            now: now.addingTimeInterval(3)
        ))
        XCTAssertTrue(armed.contains {
            if case .showStartCountdown(let candidate, _) = $0 {
                return candidate.id == occurrence.id
            }
            return false
        })
        XCTAssertFalse(armed.contains {
            if case .startRecording = $0 { return true }
            return false
        })
    }

    func testArmedReminderSurvivesSignalLossAndRetriesAfterNewStableJoin() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .reminder),
            occurrences: [occurrence],
            now: now
        ))
        _ = policy.reduce(.userAction(.armOccurrence(occurrence.id), now: now))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))

        XCTAssertEqual(
            policy.reduce(.activity([], now: now.addingTimeInterval(4))),
            [.dismissStartCountdown]
        )
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now.addingTimeInterval(5)))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(8))).contains {
            if case .showStartCountdown(let candidate, _) = $0 {
                return candidate.id == occurrence.id
            }
            return false
        })
    }

    func testCancellingArmedReminderSuppressesOccurrenceAndPreventsRetry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .reminder),
            occurrences: [occurrence],
            now: now
        ))
        _ = policy.reduce(.userAction(.armOccurrence(occurrence.id), now: now))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))

        let cancelled = policy.reduce(.userAction(
            .cancelStartCountdown(occurrence.id),
            now: now.addingTimeInterval(4)
        ))
        XCTAssertTrue(cancelled.contains(.persistSuppression(occurrence.id)))
        _ = policy.reduce(.activity([], now: now.addingTimeInterval(5)))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now.addingTimeInterval(6)))
        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(20))).contains {
            if case .showStartCountdown = $0 { return true }
            if case .startRecording = $0 { return true }
            return false
        })
    }

    func testSingleArmedReminderDisambiguatesOverlappingUnarmedOccurrence() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let armedOccurrence = makeCalendarMeetingTestOccurrence(eventID: "armed", start: now)
        let otherOccurrence = makeCalendarMeetingTestOccurrence(eventID: "other", start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .reminder),
            occurrences: [armedOccurrence, otherOccurrence],
            now: now
        ))
        _ = policy.reduce(.userAction(.armOccurrence(armedOccurrence.id), now: now))
        _ = policy.reduce(.activity(
            [signal(for: armedOccurrence), signal(for: otherOccurrence)],
            now: now
        ))

        let effects = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))
        XCTAssertTrue(effects.contains {
            if case .showStartCountdown(let candidate, _) = $0 {
                return candidate.id == armedOccurrence.id
            }
            return false
        })
        XCTAssertFalse(effects.contains(.publishDetectedMeeting(otherOccurrence)))
    }

    func testEquivalentOverlappingArmedRemindersFailClosed() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeCalendarMeetingTestOccurrence(eventID: "one", start: now)
        let second = makeCalendarMeetingTestOccurrence(eventID: "two", start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .reminder),
            occurrences: [first, second],
            now: now
        ))
        _ = policy.reduce(.userAction(.armOccurrence(first.id), now: now))
        _ = policy.reduce(.userAction(.armOccurrence(second.id), now: now))
        _ = policy.reduce(.activity([signal(for: first), signal(for: second)], now: now))

        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(10))).contains {
            if case .showStartCountdown = $0 { return true }
            if case .startRecording = $0 { return true }
            return false
        })
    }

    func testModeChangeDiscardsInMemoryReminderArm() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .reminder),
            occurrences: [occurrence],
            now: now
        ))
        _ = policy.reduce(.userAction(.armOccurrence(occurrence.id), now: now))
        _ = policy.reduce(.configure(
            configuration(mode: .off),
            occurrences: [occurrence],
            now: now
        ))
        _ = policy.reduce(.configure(
            configuration(mode: .reminder),
            occurrences: [occurrence],
            now: now
        ))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))

        XCTAssertEqual(
            policy.reduce(.timeAdvanced(now.addingTimeInterval(3))),
            [.publishDetectedMeeting(occurrence)]
        )
    }

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

    func testCameraFallbackStartsUniqueEligibleOccurrenceAfterDwellAndCountdown() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        var policy = CalendarMeetingAutomationPolicy()

        let configured = policy.reduce(.configure(
            configuration(mode: .automatic),
            occurrences: [occurrence],
            now: now
        ))
        XCTAssertTrue(configured.contains(.startCameraActivityCollector))

        XCTAssertFalse(policy.reduce(.cameraActivity(isRunning: true, now: now)).contains {
            if case .showStartCountdown = $0 { return true }
            return false
        })

        let dwellEffects = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))
        let deadline = try XCTUnwrap(dwellEffects.compactMap { effect -> Date? in
            guard case .showStartCountdown(let candidate, let deadline) = effect else {
                return nil
            }
            XCTAssertEqual(candidate.id, occurrence.id)
            return deadline
        }.first)
        XCTAssertEqual(deadline, now.addingTimeInterval(8))
        XCTAssertTrue(policy.reduce(.timeAdvanced(deadline)).contains(
            .startRecording(occurrence, identity)
        ))
    }

    func testCameraFallbackFailsClosedForOverlappingEligibleOccurrences() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeCalendarMeetingTestOccurrence(eventID: "camera-one", start: now)
        let second = makeCalendarMeetingTestOccurrence(eventID: "camera-two", start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic),
            occurrences: [first, second],
            now: now
        ))
        _ = policy.reduce(.cameraActivity(isRunning: true, now: now))

        let effects = policy.reduce(.timeAdvanced(now.addingTimeInterval(30)))
        XCTAssertFalse(effects.contains {
            if case .showStartCountdown = $0 { return true }
            if case .startRecording = $0 { return true }
            return false
        })
    }

    func testOutputOnlyBrowserSignalRequiresCameraToStart() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        let outputOnly = signal(for: occurrence, input: false, output: true)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic),
            occurrences: [occurrence],
            now: now
        ))
        _ = policy.reduce(.activity([outputOnly], now: now))

        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(3))).contains {
            if case .showStartCountdown = $0 { return true }
            return false
        })

        _ = policy.reduce(.cameraActivity(
            isRunning: true,
            now: now.addingTimeInterval(4)
        ))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(7))).contains {
            if case .showStartCountdown(let candidate, _) = $0 {
                return candidate.id == occurrence.id
            }
            return false
        })
    }

    func testCameraAndExactOutputURLDisambiguateOverlappingBrowserMeetings() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let meetIdentity = CalendarMeetingCanonicalLink(
            provider: .googleMeet,
            identity: "abc-defg-hij"
        )
        let otherIdentity = CalendarMeetingCanonicalLink(
            provider: .zoom,
            identity: "j/987654321"
        )
        let matched = makeCalendarMeetingTestOccurrence(
            eventID: "matched-browser",
            start: now,
            links: [meetIdentity]
        )
        let overlapping = makeCalendarMeetingTestOccurrence(
            eventID: "overlapping-camera",
            start: now,
            links: [otherIdentity]
        )
        let exactOutput = CalendarMeetingJoinSignal(
            occurrenceDigest: matched.id,
            meetingIdentity: meetIdentity,
            quality: .exactBrowserIdentity,
            isRunningInput: false,
            isRunningOutput: true
        )
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic),
            occurrences: [matched, overlapping],
            now: now
        ))
        _ = policy.reduce(.activity([exactOutput], now: now))
        _ = policy.reduce(.cameraActivity(isRunning: true, now: now))

        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(3))).contains {
            if case .showStartCountdown(let candidate, _) = $0 {
                return candidate.id == matched.id
            }
            return false
        })
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

    func testSuppressingAnotherOccurrencePreservesPendingIdleRetry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let pendingOccurrence = makeCalendarMeetingTestOccurrence(
            eventID: "pending",
            start: now
        )
        let suppressedOccurrence = makeCalendarMeetingTestOccurrence(
            eventID: "suppressed",
            start: now
        )
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic),
            occurrences: [pendingOccurrence, suppressedOccurrence],
            now: now
        ))
        _ = policy.reduce(.recorderReadiness(.recorderBusy, now: now))
        _ = policy.reduce(.activity([signal(for: pendingOccurrence)], now: now))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))

        XCTAssertEqual(
            policy.reduce(.userAction(
                .suppressOccurrence(suppressedOccurrence.id),
                now: now.addingTimeInterval(3.5)
            )),
            [.persistSuppression(suppressedOccurrence.id)]
        )

        let idle = policy.reduce(.recorderReadiness(.idle, now: now.addingTimeInterval(4)))
        XCTAssertTrue(idle.contains {
            if case .showStartCountdown(let occurrence, _) = $0 {
                return occurrence.id == pendingOccurrence.id
            }
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

    func testAutoStopRequiresStableSignalReturnBeforeDismissingWarning() {
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
        let warning = policy.reduce(.activity([], now: now))
        XCTAssertEqual(warning, [.showStopCountdown(handle, deadline: now.addingTimeInterval(15))])
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(14))).isEmpty)

        let returnStarted = policy.reduce(.activity([
            signal(for: occurrence, input: false, output: true)
        ], now: now.addingTimeInterval(5)))
        XCTAssertTrue(returnStarted.isEmpty)
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(7.9))).isEmpty)
        XCTAssertEqual(
            policy.reduce(.timeAdvanced(now.addingTimeInterval(8))),
            [.dismissStopCountdown]
        )

        let repeatedWarning = policy.reduce(.activity([], now: now.addingTimeInterval(9)))
        XCTAssertEqual(
            repeatedWarning,
            [.showStopCountdown(handle, deadline: now.addingTimeInterval(24))]
        )
        let veto = policy.reduce(.userAction(.continueRecording(handle), now: now.addingTimeInterval(10)))
        XCTAssertEqual(veto, [.dismissStopCountdown, .stopActivityCollector])
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(200))).isEmpty)
    }

    func testAutoStopIgnoresBriefSignalReturnWithoutRestartingCountdown() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        let handle = CalendarMeetingRecordingHandle(
            id: UUID(),
            outputURL: URL(fileURLWithPath: "/tmp/flapping-stop.wav")
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
        XCTAssertEqual(
            policy.reduce(.activity([], now: now)),
            [.showStopCountdown(handle, deadline: now.addingTimeInterval(15))]
        )

        XCTAssertTrue(policy.reduce(.activity([
            signal(for: occurrence, input: false, output: true)
        ], now: now.addingTimeInterval(1))).isEmpty)
        XCTAssertTrue(policy.reduce(.activity([], now: now.addingTimeInterval(2))).isEmpty)
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(14.9))).isEmpty)
        XCTAssertEqual(
            policy.reduce(.timeAdvanced(now.addingTimeInterval(15))),
            [.stopRecording(handle)]
        )
    }

    func testAutoStopStopsAtImmediateWarningDeadlineWithoutVeto() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        let handle = CalendarMeetingRecordingHandle(
            id: UUID(),
            outputURL: URL(fileURLWithPath: "/tmp/immediate-stop.wav")
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

        XCTAssertEqual(
            policy.reduce(.activity([], now: now)),
            [.showStopCountdown(handle, deadline: now.addingTimeInterval(15))]
        )
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(14.9))).isEmpty)
        XCTAssertEqual(
            policy.reduce(.timeAdvanced(now.addingTimeInterval(15))),
            [.stopRecording(handle)]
        )
        XCTAssertFalse(
            policy.reduce(.timeAdvanced(now.addingTimeInterval(30))).contains(.stopRecording(handle))
        )
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

    func testCameraPresenceNeverCountsAsAutoStopIdentitySignal() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        let handle = CalendarMeetingRecordingHandle(
            id: UUID(),
            outputURL: URL(fileURLWithPath: "/tmp/camera-fallback.wav")
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
        _ = policy.reduce(.cameraActivity(isRunning: true, now: now))

        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(60))).contains {
            if case .showStopCountdown = $0 { return true }
            return false
        })

        _ = policy.reduce(.activity([
            signal(for: occurrence, input: false, output: true)
        ], now: now.addingTimeInterval(61)))
        let missing = policy.reduce(.activity([], now: now.addingTimeInterval(62)))
        XCTAssertEqual(
            missing,
            [.showStopCountdown(handle, deadline: now.addingTimeInterval(77))]
        )
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
        XCTAssertEqual(
            policy.reduce(.activity([], now: now)),
            [.showStopCountdown(handle, deadline: now.addingTimeInterval(15))]
        )

        let effects = policy.reduce(.configure(
            configuration(mode: .off, autoStop: false, premium: false),
            occurrences: [],
            now: now.addingTimeInterval(1)
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

        XCTAssertTrue(policy.reduce(.activity([], now: now)).contains(
            .showStopCountdown(handle, deadline: now.addingTimeInterval(15))
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
