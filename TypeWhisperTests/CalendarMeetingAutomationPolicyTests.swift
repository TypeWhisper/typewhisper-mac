import Foundation
import XCTest
@testable import TypeWhisper

final class CalendarMeetingAutomationPolicyTests: XCTestCase {
    private let identity = CalendarMeetingCanonicalLink(provider: .zoom, identity: "j/123456789")

    func testOffConfigurationNeverRequestsAudioOrCameraCollectors() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)

        for configuration in [
            configuration(mode: .off)
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

    func testProvidersAddedAfterASavedSelectionStartEnabled() {
        XCTAssertEqual(
            CalendarMeetingEnabledProviders.resolve(storedEnabledIDs: nil, storedKnownIDs: nil),
            Set(MeetingProvider.allCases)
        )
        // Saved before Kontur Talk existed: Talk is new, the unchecked Zoom stays off.
        XCTAssertEqual(
            CalendarMeetingEnabledProviders.resolve(
                storedEnabledIDs: ["teams", "googleMeet", "faceTime"],
                storedKnownIDs: nil
            ),
            [.teams, .googleMeet, .faceTime, .konturTalk]
        )
        // Once a provider is known, unchecking it sticks.
        XCTAssertEqual(
            CalendarMeetingEnabledProviders.resolve(
                storedEnabledIDs: ["zoom"],
                storedKnownIDs: MeetingProvider.allCases.map(\.rawValue)
            ),
            [.zoom]
        )
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
        XCTAssertTrue(armed.contains(.dismissStartNotifications(occurrence.id)))
        XCTAssertTrue(armed.contains(.replaceScheduledReminders([])))
        let refreshed = policy.reduce(.configure(
            configuration(mode: .reminder),
            occurrences: [occurrence],
            now: now
        ))
        XCTAssertTrue(refreshed.contains(.replaceScheduledReminders([])))
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

    func testDetectedReminderActionUsesExistingStableDwellButStillShowsCountdown() throws {
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
        let dismissalIndex = try XCTUnwrap(armed.firstIndex(of: .dismissStartNotifications(occurrence.id)))
        let countdownIndex = try XCTUnwrap(armed.firstIndex {
            if case .showStartCountdown = $0 { return true }
            return false
        })
        XCTAssertLessThan(dismissalIndex, countdownIndex)
        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(4))).contains(
            .publishDetectedMeeting(occurrence)
        ))
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
        XCTAssertTrue(cancelled.contains(.dismissStartNotifications(occurrence.id)))
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

    func testCalendarRefreshDoesNotRestoreReminderDuringAutomaticCountdown() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now.addingTimeInterval(8 * 60))
        let laterOccurrence = makeCalendarMeetingTestOccurrence(
            eventID: "later-event",
            start: now.addingTimeInterval(60 * 60)
        )
        let occurrences = [occurrence, laterOccurrence]
        let automatic = configuration(mode: .automatic)
        var policy = CalendarMeetingAutomationPolicy()
        let configured = policy.reduce(.configure(automatic, occurrences: occurrences, now: now))
        XCTAssertTrue(configured.contains(.replaceScheduledReminders(occurrences.map {
            CalendarMeetingUpcomingReminder(occurrence: $0, startMode: .automatic)
        })))

        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        let countdown = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))
        XCTAssertTrue(countdown.contains(.dismissStartNotifications(occurrence.id)))
        XCTAssertTrue(countdown.contains(.showStartCountdown(
            occurrence,
            deadline: now.addingTimeInterval(8)
        )))

        let refreshed = policy.reduce(.configure(
            automatic,
            occurrences: occurrences,
            now: now.addingTimeInterval(4)
        ))
        XCTAssertTrue(refreshed.contains(.replaceScheduledReminders([
            CalendarMeetingUpcomingReminder(occurrence: laterOccurrence, startMode: .automatic)
        ])), "A calendar refresh must keep the automatic countdown's reminder dismissed")
    }

    func testCalendarRefreshDoesNotRestoreReminderWhileAutomaticRecordingStartIsInFlight() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now.addingTimeInterval(8 * 60))
        let automatic = configuration(mode: .automatic)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(automatic, occurrences: [occurrence], now: now))
        _ = policy.reduce(.activity([signal(for: occurrence)], now: now))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(8))).contains(
            .startRecording(occurrence, identity)
        ))

        let refreshed = policy.reduce(.configure(
            automatic,
            occurrences: [occurrence],
            now: now.addingTimeInterval(9)
        ))
        XCTAssertTrue(refreshed.contains(.replaceScheduledReminders([])),
            "The countdown has ended, but recorder startup must still keep the reminder dismissed")

        _ = policy.reduce(.recordingStartFailed(
            occurrenceDigest: occurrence.id,
            failure: .captureFailed
        ))
        let afterFailure = policy.reduce(.configure(
            automatic,
            occurrences: [occurrence],
            now: now.addingTimeInterval(10)
        ))
        XCTAssertTrue(afterFailure.contains(.replaceScheduledReminders([])))
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
            [
                .dismissStartCountdown,
                .allowReminderRestoration(occurrence.id),
                .replaceScheduledReminders([
                    CalendarMeetingUpcomingReminder(occurrence: occurrence, startMode: .automatic)
                ])
            ]
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
            [.dismissStartNotifications(suppressedOccurrence.id), .persistSuppression(suppressedOccurrence.id)]
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
        XCTAssertTrue(changed.contains(.replaceScheduledReminders([
            CalendarMeetingUpcomingReminder(occurrence: occurrence, startMode: .reminder)
        ])), "Changing modes must restore reminders after clearing the automatic countdown")
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
            configuration(mode: .off, autoStop: false),
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

    func testSoloConfirmationOnlyTurnsAutomaticSoloCalendarEventsIntoReminders() {
        let solo = makeCalendarMeetingTestOccurrence(eventID: "solo", hasOtherParticipants: false)
        let team = makeCalendarMeetingTestOccurrence(eventID: "team")
        let adHoc = CalendarMeetingOccurrence(
            eventIdentifier: "ad-hoc:call",
            occurrenceStart: solo.startDate,
            startDate: solo.startDate,
            endDate: solo.startDate,
            title: "Zoom call",
            calendarID: "",
            participationStatus: .noCurrentUser,
            meetingLinks: [identity],
            hasOtherParticipants: false,
            isAdHoc: true
        )
        let confirming = configuration(mode: .automatic, confirmSoloEvents: true)

        XCTAssertEqual(confirming.startMode(for: solo), .reminder)
        XCTAssertEqual(confirming.startMode(for: team), .automatic)
        XCTAssertEqual(confirming.startMode(for: adHoc), .automatic)
        XCTAssertEqual(configuration(mode: .automatic).startMode(for: solo), .automatic)
        XCTAssertEqual(configuration(mode: .reminder, confirmSoloEvents: true).startMode(for: team), .reminder)
        XCTAssertEqual(configuration(mode: .off, confirmSoloEvents: true).startMode(for: solo), .off)
    }

    func testConfirmedSoloEventPublishesDetectedReminderInsteadOfAutoStarting() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let solo = makeCalendarMeetingTestOccurrence(start: now, hasOtherParticipants: false)
        var policy = CalendarMeetingAutomationPolicy()
        let configured = policy.reduce(.configure(
            configuration(mode: .automatic, confirmSoloEvents: true),
            occurrences: [solo],
            now: now
        ))
        XCTAssertTrue(configured.contains(.replaceScheduledReminders([
            CalendarMeetingUpcomingReminder(occurrence: solo, startMode: .reminder)
        ])))
        XCTAssertTrue(configured.contains(.startActivityCollector))

        _ = policy.reduce(.activity([signal(for: solo)], now: now))
        XCTAssertEqual(
            policy.reduce(.timeAdvanced(now.addingTimeInterval(3))),
            [.publishDetectedMeeting(solo)]
        )
        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(60))).contains {
            if case .showStartCountdown = $0 { return true }
            if case .startRecording = $0 { return true }
            return false
        })
    }

    func testSoloConfirmationKeepsAutomaticStartForMeetingsWithOtherAttendees() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let team = makeCalendarMeetingTestOccurrence(start: now)
        var policy = CalendarMeetingAutomationPolicy()
        let configured = policy.reduce(.configure(
            configuration(mode: .automatic, confirmSoloEvents: true),
            occurrences: [team],
            now: now
        ))
        XCTAssertTrue(configured.contains(.replaceScheduledReminders([
            CalendarMeetingUpcomingReminder(occurrence: team, startMode: .automatic)
        ])))

        _ = policy.reduce(.activity([signal(for: team)], now: now))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(3))).contains(
            .showStartCountdown(team, deadline: now.addingTimeInterval(8))
        ))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(8))).contains(
            .startRecording(team, identity)
        ))
    }

    func testStartWhenIJoinArmsConfirmedSoloEventInAutomaticMode() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let solo = makeCalendarMeetingTestOccurrence(
            start: now.addingTimeInterval(5 * 60),
            hasOtherParticipants: false
        )
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic, confirmSoloEvents: true),
            occurrences: [solo],
            now: now
        ))
        _ = policy.reduce(.userAction(.armOccurrence(solo.id), now: now))
        _ = policy.reduce(.activity([signal(for: solo)], now: now))

        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(3))).contains(
            .showStartCountdown(solo, deadline: now.addingTimeInterval(8))
        ))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(8))).contains(
            .startRecording(solo, identity)
        ))
    }

    func testSoloEventAwaitingConsentKeepsCameraFallbackAmbiguous() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let solo = makeCalendarMeetingTestOccurrence(
            eventID: "solo",
            start: now,
            hasOtherParticipants: false
        )
        let team = makeCalendarMeetingTestOccurrence(eventID: "team", start: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(
            configuration(mode: .automatic, confirmSoloEvents: true),
            occurrences: [solo, team],
            now: now
        ))
        _ = policy.reduce(.cameraActivity(isRunning: true, now: now))

        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(30))).contains {
            if case .showStartCountdown = $0 { return true }
            if case .startRecording = $0 { return true }
            if case .publishDetectedMeeting = $0 { return true }
            return false
        })
    }

    func testEnablingSoloConfirmationCancelsRunningAutomaticCountdown() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let solo = makeCalendarMeetingTestOccurrence(start: now, hasOtherParticipants: false)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(configuration(mode: .automatic), occurrences: [solo], now: now))
        _ = policy.reduce(.activity([signal(for: solo)], now: now))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(3))).contains(
            .showStartCountdown(solo, deadline: now.addingTimeInterval(8))
        ))

        let changed = policy.reduce(.configure(
            configuration(mode: .automatic, confirmSoloEvents: true),
            occurrences: [solo],
            now: now.addingTimeInterval(4)
        ))
        XCTAssertTrue(changed.contains(.dismissStartCountdown))
        XCTAssertTrue(changed.contains(.replaceScheduledReminders([
            CalendarMeetingUpcomingReminder(occurrence: solo, startMode: .reminder)
        ])))
        XCTAssertEqual(
            policy.reduce(.timeAdvanced(now.addingTimeInterval(8))),
            [.publishDetectedMeeting(solo)]
        )
    }

    func testCalendarRefreshThatMakesEventSoloCancelsPendingAutomaticStart() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let team = makeCalendarMeetingTestOccurrence(start: now)
        let nowSolo = makeCalendarMeetingTestOccurrence(start: now, hasOtherParticipants: false)
        XCTAssertEqual(team.id, nowSolo.id)
        let confirming = configuration(mode: .automatic, confirmSoloEvents: true)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(confirming, occurrences: [team], now: now))
        _ = policy.reduce(.activity([signal(for: team)], now: now))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(3))).contains(
            .showStartCountdown(team, deadline: now.addingTimeInterval(8))
        ))

        // The only other attendee was removed while the countdown ran.
        let refreshed = policy.reduce(.configure(
            confirming,
            occurrences: [nowSolo],
            now: now.addingTimeInterval(4)
        ))
        XCTAssertTrue(refreshed.contains(.dismissStartCountdown))
        XCTAssertTrue(refreshed.contains(.allowReminderRestoration(nowSolo.id)))
        // The refreshed reminder can begin its fresh three-second detection dwell
        // immediately after invalidating the automatic countdown.
        XCTAssertEqual(
            policy.reduce(.timeAdvanced(now.addingTimeInterval(7))),
            [.publishDetectedMeeting(nowSolo)]
        )
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(11))).isEmpty)
    }

    func testCalendarRefreshThatMakesEventSoloDropsBusyRecorderRetry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let team = makeCalendarMeetingTestOccurrence(start: now)
        let nowSolo = makeCalendarMeetingTestOccurrence(start: now, hasOtherParticipants: false)
        let confirming = configuration(mode: .automatic, confirmSoloEvents: true)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(confirming, occurrences: [team], now: now))
        _ = policy.reduce(.recorderReadiness(.recorderBusy, now: now))
        _ = policy.reduce(.activity([signal(for: team)], now: now))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))

        var effects = policy.reduce(.configure(
            confirming,
            occurrences: [nowSolo],
            now: now.addingTimeInterval(4)
        ))
        effects += policy.reduce(.recorderReadiness(.idle, now: now.addingTimeInterval(5)))
        effects += policy.reduce(.timeAdvanced(now.addingTimeInterval(30)))

        XCTAssertFalse(effects.contains {
            if case .showStartCountdown = $0 { return true }
            if case .startRecording = $0 { return true }
            return false
        })
        XCTAssertTrue(effects.contains(.publishDetectedMeeting(nowSolo)))
    }

    func testStartCancelledForWithdrawnConsentKeepsOccurrenceArmable() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let team = makeCalendarMeetingTestOccurrence(start: now)
        let nowSolo = makeCalendarMeetingTestOccurrence(start: now, hasOtherParticipants: false)
        let confirming = configuration(mode: .automatic, confirmSoloEvents: true)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(confirming, occurrences: [team], now: now))
        _ = policy.reduce(.activity([signal(for: team)], now: now))
        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(8))).contains(
            .startRecording(team, identity)
        ))

        // The refresh arrives while the recorder is starting.
        _ = policy.reduce(.configure(confirming, occurrences: [nowSolo], now: now.addingTimeInterval(8)))
        XCTAssertFalse(policy.permitsStart(of: team.id, identity: identity, at: now.addingTimeInterval(8)))
        _ = policy.reduce(.recordingStartCancelled(occurrenceDigest: team.id, now: now.addingTimeInterval(8)))

        _ = policy.reduce(.timeAdvanced(now.addingTimeInterval(9)))
        XCTAssertEqual(
            policy.reduce(.timeAdvanced(now.addingTimeInterval(12))),
            [.publishDetectedMeeting(nowSolo)]
        )
        let armed = policy.reduce(.userAction(.armOccurrence(nowSolo.id), now: now.addingTimeInterval(12)))
        XCTAssertTrue(armed.contains(.showStartCountdown(nowSolo, deadline: now.addingTimeInterval(17))))
        XCTAssertTrue(policy.permitsStart(of: nowSolo.id, identity: identity, at: now.addingTimeInterval(17)))
    }

    func testCalendarRefreshKeepsPendingStartOfArmedSoloEvent() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let solo = makeCalendarMeetingTestOccurrence(start: now, hasOtherParticipants: false)
        let confirming = configuration(mode: .automatic, confirmSoloEvents: true)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(confirming, occurrences: [solo], now: now))
        _ = policy.reduce(.userAction(.armOccurrence(solo.id), now: now))
        _ = policy.reduce(.activity([signal(for: solo)], now: now))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(3))).contains(
            .showStartCountdown(solo, deadline: now.addingTimeInterval(8))
        ))

        let refreshed = policy.reduce(.configure(
            confirming,
            occurrences: [solo],
            now: now.addingTimeInterval(4)
        ))
        XCTAssertFalse(refreshed.contains(.dismissStartCountdown))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(8))).contains(
            .startRecording(solo, identity)
        ))
    }

    private func configuration(
        mode: CalendarMeetingStartMode,
        autoStop: Bool = false,
        suppressedDigests: Set<String> = [],
        confirmSoloEvents: Bool = false
    ) -> CalendarMeetingAutomationConfiguration {
        CalendarMeetingAutomationConfiguration(
            startMode: mode,
            autoStopEnabled: autoStop,
            calendarAuthorization: .fullAccess,
            selectedCalendarIDs: ["calendar-1"],
            enabledProviders: Set(MeetingProvider.allCases),
            suppressedOccurrenceDigests: suppressedDigests,
            confirmSoloEvents: confirmSoloEvents
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

extension CalendarMeetingAutomationPolicyTests {
    private func adHocConfiguration(
        mode: CalendarMeetingStartMode = .automatic,
        enabled: Bool = true,
        providers: Set<MeetingProvider> = [.zoom, .teams, .googleMeet]
    ) -> CalendarMeetingAutomationConfiguration {
        CalendarMeetingAutomationConfiguration(
            startMode: mode,
            autoStopEnabled: true,
            calendarAuthorization: .denied,
            selectedCalendarIDs: [],
            enabledProviders: providers,
            suppressedOccurrenceDigests: [],
            detectAdHocMeetings: enabled
        )
    }

    private func detectedSession(
        at now: Date,
        provider: MeetingProvider = .zoom,
        input: Bool = true,
        output: Bool = false
    ) -> (CalendarMeetingOccurrence, CalendarMeetingJoinSignal) {
        let activity = DetectedMeetingActivity(
            sourceID: provider == .googleMeet ? "browser:chrome" : "native:\(provider.rawValue)",
            link: CalendarMeetingCanonicalLink(provider: provider, identity: "call"),
            isRunningInput: true,
            isRunningOutput: false
        )
        var sessions = AdHocMeetingSessionTracker()
        sessions.update(activities: [activity], now: now, activeRecordingDigest: nil)
        let occurrence = sessions.occurrence(for: activity)!
        return (occurrence, CalendarMeetingJoinSignal(
            occurrenceDigest: occurrence.id,
            meetingIdentity: activity.link,
            quality: provider == .googleMeet ? .exactBrowserIdentity : .nativeProvider,
            isRunningInput: input,
            isRunningOutput: output
        ))
    }

    func testAdHocCollectorNeedsOptInAndActiveModeButNoCalendarPermission() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for config in [
            adHocConfiguration(enabled: false),
            adHocConfiguration(mode: .off)
        ] {
            var policy = CalendarMeetingAutomationPolicy()
            let effects = policy.reduce(.configure(config, occurrences: [], now: now))
            XCTAssertFalse(effects.contains(.startActivityCollector))
        }
        var policy = CalendarMeetingAutomationPolicy()
        let effects = policy.reduce(.configure(adHocConfiguration(), occurrences: [], now: now))
        XCTAssertTrue(effects.contains(.startActivityCollector))
        XCTAssertFalse(effects.contains(.startCameraActivityCollector))
    }

    func testAdHocNativeCallStartsWithoutCalendarAfterDwellAndCancellableCountdown() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let (occurrence, signal) = detectedSession(at: now)
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(adHocConfiguration(), occurrences: [], now: now))
        _ = policy.reduce(.activity([signal], detectedOccurrences: [occurrence], now: now))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(4))).isEmpty)
        XCTAssertEqual(policy.reduce(.timeAdvanced(now.addingTimeInterval(5))), [
            .dismissStartNotifications(occurrence.id),
            .showStartCountdown(occurrence, deadline: now.addingTimeInterval(10))
        ])
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(10))).contains(
            .startRecording(occurrence, signal.meetingIdentity)
        ))
    }

    func testAdHocBrowserRequiresLongerMicDwellAndNoCameraOrOutputOnlyFallback() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let (occurrence, input) = detectedSession(at: now, provider: .googleMeet)
        let output = CalendarMeetingJoinSignal(
            occurrenceDigest: occurrence.id, meetingIdentity: input.meetingIdentity,
            quality: .exactBrowserIdentity, isRunningInput: false, isRunningOutput: true
        )
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(adHocConfiguration(), occurrences: [], now: now))
        _ = policy.reduce(.activity([output], detectedOccurrences: [occurrence], now: now))
        _ = policy.reduce(.cameraActivity(isRunning: true, now: now))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(30))).isEmpty)
        _ = policy.reduce(.activity([input], now: now.addingTimeInterval(30)))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(49))).isEmpty)
        XCTAssertEqual(policy.reduce(.timeAdvanced(now.addingTimeInterval(50))), [
            .dismissStartNotifications(occurrence.id),
            .showStartCountdown(occurrence, deadline: now.addingTimeInterval(55))
        ])
        XCTAssertTrue(policy.reduce(.activity([], now: now.addingTimeInterval(51))).contains(.dismissStartCountdown))
        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(60))).contains {
            if case .startRecording = $0 { return true }; return false
        })
    }

    func testAdHocReminderWaitsForExplicitStartAndDoesNotScheduleCalendarReminder() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let (occurrence, signal) = detectedSession(at: now)
        var policy = CalendarMeetingAutomationPolicy()
        let configured = policy.reduce(.configure(adHocConfiguration(mode: .reminder), occurrences: [occurrence], now: now))
        XCTAssertTrue(configured.contains(.replaceScheduledReminders([])))
        _ = policy.reduce(.activity([signal], now: now))
        XCTAssertEqual(policy.reduce(.timeAdvanced(now.addingTimeInterval(5))), [.publishDetectedMeeting(occurrence)])
        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(50))).contains {
            if case .startRecording = $0 { return true }; return false
        })
        XCTAssertTrue(policy.reduce(.userAction(.armOccurrence(occurrence.id), now: now.addingTimeInterval(50))).contains {
            if case .showStartCountdown = $0 { return true }; return false
        })
    }

    func testAdHocDisabledProviderAndCompetingMeetingsNeverStart() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let (zoom, zoomSignal) = detectedSession(at: now)
        let (teams, teamsSignal) = detectedSession(at: now, provider: .teams)
        for (config, meetings, signals) in [
            (adHocConfiguration(providers: [.teams]), [zoom], [zoomSignal]),
            (adHocConfiguration(), [zoom, teams], [zoomSignal, teamsSignal])
        ] {
            var policy = CalendarMeetingAutomationPolicy()
            _ = policy.reduce(.configure(config, occurrences: [], now: now))
            _ = policy.reduce(.activity(signals, detectedOccurrences: meetings, now: now))
            XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(60))).isEmpty)
        }
    }

    func testAdHocAutoStopWaitsThroughShortGapsAndKeepsContinueVeto() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let (occurrence, signal) = detectedSession(at: now)
        let handle = CalendarMeetingRecordingHandle(id: UUID(), outputURL: URL(fileURLWithPath: "/tmp/ad-hoc.wav"))
        var policy = CalendarMeetingAutomationPolicy()
        _ = policy.reduce(.configure(adHocConfiguration(), occurrences: [occurrence], now: now))
        _ = policy.reduce(.activity([signal], now: now))
        _ = policy.reduce(.recordingStarted(handle: handle, occurrenceDigest: occurrence.id,
            identity: signal.meetingIdentity, autoStopArmed: true, now: now))
        XCTAssertTrue(policy.reduce(.activity([], now: now)).isEmpty)
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(89))).isEmpty)
        _ = policy.reduce(.activity([signal], now: now.addingTimeInterval(89)))
        _ = policy.reduce(.activity([], now: now.addingTimeInterval(90)))
        XCTAssertTrue(policy.reduce(.timeAdvanced(now.addingTimeInterval(179))).isEmpty)
        XCTAssertEqual(policy.reduce(.timeAdvanced(now.addingTimeInterval(180))), [
            .showStopCountdown(handle, deadline: now.addingTimeInterval(195))
        ])
        XCTAssertTrue(policy.reduce(.userAction(.continueRecording(handle), now: now.addingTimeInterval(181)))
            .contains(.dismissStopCountdown))
        XCTAssertFalse(policy.reduce(.timeAdvanced(now.addingTimeInterval(300))).contains(.stopRecording(handle)))
    }

    func testAdHocSessionsRequireInputAndRetainIdentityAcrossBriefMute() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let link = CalendarMeetingCanonicalLink(provider: .teams, identity: "native-call")
        let input = DetectedMeetingActivity(sourceID: "teams", link: link, isRunningInput: true, isRunningOutput: false)
        let output = DetectedMeetingActivity(sourceID: "teams", link: link, isRunningInput: false, isRunningOutput: true)
        var sessions = AdHocMeetingSessionTracker()
        sessions.update(activities: [output], now: now, activeRecordingDigest: nil)
        XCTAssertTrue(sessions.occurrences.isEmpty)
        sessions.update(activities: [input], now: now, activeRecordingDigest: nil)
        let first = try XCTUnwrap(sessions.occurrence(for: input))
        sessions.update(activities: [], now: now.addingTimeInterval(20), activeRecordingDigest: nil)
        sessions.update(activities: [output], now: now.addingTimeInterval(30), activeRecordingDigest: nil)
        XCTAssertEqual(sessions.occurrence(for: input)?.id, first.id)
        sessions.update(activities: [], now: now.addingTimeInterval(121), activeRecordingDigest: first.id)
        XCTAssertEqual(sessions.occurrence(for: input)?.id, first.id)
        sessions.update(activities: [], now: now.addingTimeInterval(122), activeRecordingDigest: nil)
        XCTAssertTrue(sessions.occurrences.isEmpty)
        sessions.update(activities: [input], now: now.addingTimeInterval(123), activeRecordingDigest: nil)
        XCTAssertNotEqual(sessions.occurrence(for: input)?.id, first.id)
    }
}
