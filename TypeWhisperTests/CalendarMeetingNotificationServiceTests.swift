import Foundation
import UserNotifications
import XCTest
@testable import TypeWhisper

@MainActor
private final class FakeCalendarMeetingNotificationClient: CalendarMeetingNotificationClient {
    var authorization: CalendarMeetingNotificationAuthorization = .notDetermined
    var pendingIdentifiers: [String] = []
    var added: [CalendarMeetingNotificationRequest] = []
    var removed: [[String]] = []
    var removedDelivered: [[String]] = []
    var addError: Error?
    var registerCount = 0
    var requestCount = 0
    var responseHandler: (@MainActor (CalendarMeetingNotificationResponse) -> Void)?

    func installResponseHandler(
        _ handler: @escaping @MainActor (CalendarMeetingNotificationResponse) -> Void
    ) {
        responseHandler = handler
    }

    func registerCategories() { registerCount += 1 }
    func authorizationStatus() async -> CalendarMeetingNotificationAuthorization { authorization }
    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        return true
    }
    func pendingRequestIdentifiers() async -> [String] { pendingIdentifiers }
    func add(_ request: CalendarMeetingNotificationRequest) async throws {
        if let addError { throw addError }
        added.append(request)
    }
    func removePendingRequests(withIdentifiers identifiers: [String]) { removed.append(identifiers) }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(identifiers)
    }
}

private extension CalendarMeetingNotificationService {
    func replaceScheduledReminders(
        _ occurrences: [CalendarMeetingOccurrence],
        startMode: CalendarMeetingStartMode = .reminder,
        now: Date
    ) async {
        await replaceScheduledReminders(
            occurrences.map { CalendarMeetingUpcomingReminder(occurrence: $0, startMode: startMode) },
            now: now
        )
    }
}

@MainActor
final class CalendarMeetingNotificationServiceTests: XCTestCase {
    func testReminderPlanningIsSortedLimitedToSevenDaysAndFortyEight() async throws {
        let suiteName = "CalendarMeetingNotificationServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrences = (0..<60).reversed().map { index in
            makeCalendarMeetingTestOccurrence(
                eventID: "event-\(index)",
                start: now.addingTimeInterval(600 + Double(index * 60))
            )
        } + [
            makeCalendarMeetingTestOccurrence(
                eventID: "too-late",
                start: now.addingTimeInterval(8 * 24 * 60 * 60)
            )
        ]

        await service.replaceScheduledReminders(occurrences, now: now)

        XCTAssertEqual(client.added.count, 48)
        XCTAssertEqual(client.added.map(\.fireDate), client.added.map(\.fireDate).sorted())
        XCTAssertTrue(client.added.allSatisfy { $0.fireDate <= now.addingTimeInterval(7 * 24 * 60 * 60) })
        XCTAssertTrue(client.added.allSatisfy { $0.identifier.hasPrefix(
            CalendarMeetingNotificationService.requestIdentifierPrefix
        ) })
        XCTAssertTrue(client.added.allSatisfy { $0.category == .upcomingReminder })
        XCTAssertTrue(client.added.allSatisfy {
            if case .scheduled(let fireDate) = $0.delivery {
                return fireDate == $0.fireDate
            }
            return false
        })
    }

    func testLateCreatedOccurrenceGetsOneImmediateCatchUpReminder() async throws {
        let suiteName = "CalendarMeetingCatchUpTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            eventID: "late-created",
            start: now.addingTimeInterval(-10 * 60)
        )

        await service.replaceScheduledReminders([occurrence], now: now)

        let request = try XCTUnwrap(client.added.first)
        XCTAssertEqual(client.added.count, 1)
        XCTAssertEqual(request.delivery, .immediate)
        XCTAssertEqual(request.fireDate, now)
        XCTAssertEqual(
            request.title,
            String(localized: "calendarMeeting.notification.inProgressTitle")
        )
        XCTAssertEqual(
            defaults.stringArray(
                forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests
            ),
            [occurrence.occurrenceDigest]
        )

        client.added.removeAll()
        await service.replaceScheduledReminders(
            [occurrence],
            now: now.addingTimeInterval(1)
        )
        XCTAssertTrue(client.added.isEmpty)
    }

    func testPreviouslyScheduledReminderDoesNotBecomeDuplicateCatchUpReminder() async throws {
        let suiteName = "CalendarMeetingScheduledLedgerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            eventID: "scheduled-before-fire",
            start: now.addingTimeInterval(10 * 60)
        )

        await service.replaceScheduledReminders([occurrence], now: now)
        XCTAssertEqual(client.added.count, 1)
        client.added.removeAll()

        await service.replaceScheduledReminders(
            [occurrence],
            now: now.addingTimeInterval(6 * 60)
        )
        XCTAssertTrue(client.added.isEmpty)
    }

    func testRescheduledOccurrenceDigestCanReceiveNewCatchUpReminder() async throws {
        let suiteName = "CalendarMeetingRescheduledCatchUpTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let original = makeCalendarMeetingTestOccurrence(
            eventID: "rescheduled",
            start: now.addingTimeInterval(-20 * 60)
        )
        let moved = makeCalendarMeetingTestOccurrence(
            eventID: "rescheduled",
            start: now.addingTimeInterval(-10 * 60)
        )

        await service.replaceScheduledReminders([original], now: now)
        client.added.removeAll()
        await service.replaceScheduledReminders([moved], now: now)

        XCTAssertNotEqual(original.occurrenceDigest, moved.occurrenceDigest)
        XCTAssertEqual(client.added.map(\.occurrenceDigest), [moved.occurrenceDigest])
    }

    func testCatchUpReminderFailsClosedAfterJoinWindow() async throws {
        let suiteName = "CalendarMeetingExpiredCatchUpTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            eventID: "expired",
            start: now.addingTimeInterval(-2 * 60 * 60),
            duration: 30 * 60
        )

        await service.replaceScheduledReminders([occurrence], now: now)

        XCTAssertTrue(client.added.isEmpty)
    }

    func testReminderRequestLedgerIsUniqueAndBounded() {
        let initial = (0..<CalendarMeetingReminderRequestLedger.capacity).map {
            "digest-\($0)"
        }
        let refreshed = CalendarMeetingReminderRequestLedger.appending(
            "digest-10",
            to: initial
        )
        XCTAssertEqual(refreshed.count, CalendarMeetingReminderRequestLedger.capacity)
        XCTAssertEqual(refreshed.last, "digest-10")
        XCTAssertEqual(refreshed.filter { $0 == "digest-10" }.count, 1)

        let overflow = CalendarMeetingReminderRequestLedger.appending(
            "digest-new",
            to: refreshed
        )
        XCTAssertEqual(overflow.count, CalendarMeetingReminderRequestLedger.capacity)
        XCTAssertFalse(overflow.contains("digest-0"))
        XCTAssertEqual(overflow.last, "digest-new")
    }

    func testFailedReminderReplacementIsEligibleForLaterRetry() async throws {
        struct AddError: Error {}

        let suiteName = "CalendarMeetingReminderRetryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        client.addError = AddError()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            eventID: "retry-after-add-failure",
            start: now.addingTimeInterval(10 * 60)
        )
        defaults.set(
            [occurrence.occurrenceDigest],
            forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests
        )

        await service.replaceScheduledReminders([occurrence], now: now)

        XCTAssertEqual(
            defaults.stringArray(
                forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests
            ),
            []
        )
    }

    func testUpcomingNotificationCategoryAndCopyReflectStartMode() async throws {
        let suiteName = "CalendarMeetingNotificationModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            start: now.addingTimeInterval(10 * 60)
        )

        await service.replaceScheduledReminders(
            [occurrence],
            startMode: .automatic,
            now: now
        )

        let request = try XCTUnwrap(client.added.last)
        XCTAssertEqual(request.category, .upcomingAutomatic)
        XCTAssertEqual(
            request.body,
            String(localized: "calendarMeeting.notification.upcomingAutomaticBody")
        )

        client.added.removeAll()
        await service.replaceScheduledReminders(
            [occurrence],
            startMode: .reminder,
            now: now
        )
        XCTAssertEqual(client.added.last?.category, .upcomingReminder)
    }

    func testUpcomingNotificationCategoryFollowsEachReminderStartMode() async throws {
        let suiteName = "CalendarMeetingNotificationMixedModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let solo = makeCalendarMeetingTestOccurrence(
            eventID: "solo",
            start: now.addingTimeInterval(10 * 60),
            title: "Dentist",
            hasOtherParticipants: false
        )
        let team = makeCalendarMeetingTestOccurrence(
            eventID: "team",
            start: now.addingTimeInterval(20 * 60)
        )

        await service.replaceScheduledReminders([
            CalendarMeetingUpcomingReminder(occurrence: solo, startMode: .reminder),
            CalendarMeetingUpcomingReminder(occurrence: team, startMode: .automatic),
        ], now: now)

        XCTAssertEqual(client.added.map(\.occurrenceDigest), [solo.id, team.id])
        XCTAssertEqual(client.added.map(\.category), [.upcomingReminder, .upcomingAutomatic])
        XCTAssertEqual(client.added.first?.body, "Dentist")
        XCTAssertEqual(
            client.added.last?.body,
            String(localized: "calendarMeeting.notification.upcomingAutomaticBody")
        )
    }

    func testRefreshOnlyRemovesCalendarMeetingRequests() async throws {
        let suiteName = "CalendarMeetingNotificationRemovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        client.pendingIdentifiers = [
            "external.notification",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "one.upcoming",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "two.detected",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "three.autoStop"
        ]
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)

        await service.removeScheduledMeetingRequests()

        XCTAssertEqual(client.removed, [[
            CalendarMeetingNotificationService.requestIdentifierPrefix + "one.upcoming",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "two.detected"
        ]])
    }

    func testOccurrenceFiveMinutesBeyondFetchHorizonStillFiresWithinSevenDays() async throws {
        let suiteName = "CalendarMeetingNotificationBoundaryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            start: now.addingTimeInterval(7 * 24 * 60 * 60 + 5 * 60)
        )

        await service.replaceScheduledReminders([occurrence], now: now)

        XCTAssertEqual(client.added.map(\.fireDate), [now.addingTimeInterval(7 * 24 * 60 * 60)])
    }

    func testDetectedNotificationReplacesPendingAndDeliveredStartNotifications() async throws {
        let suiteName = "CalendarMeetingDetectedTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let occurrence = makeCalendarMeetingTestOccurrence()
        let now = Date(timeIntervalSince1970: 2_000_000_010)

        await service.publishDetectedMeeting(occurrence, now: now)

        let startIdentifiers = [CalendarMeetingNotificationKind.upcoming, .detected].map {
            "\(CalendarMeetingNotificationService.requestIdentifierPrefix)\(occurrence.id).\($0.rawValue)"
        }
        XCTAssertEqual(client.removed, [startIdentifiers])
        XCTAssertEqual(client.removedDelivered, [startIdentifiers])
        XCTAssertEqual(client.added.count, 1)
        XCTAssertEqual(client.added.first?.kind, .detected)
        XCTAssertEqual(client.added.first?.category, .detected)
        XCTAssertEqual(client.added.first?.occurrenceDigest, occurrence.id)
        XCTAssertEqual(client.added.first?.fireDate, now.addingTimeInterval(1))
        XCTAssertEqual(client.added.first?.delivery, .immediate)
    }

    func testStartNotificationRemovalIsScopedToAcceptedOccurrenceAndLeavesAutoStopAlone() throws {
        let suiteName = "CalendarMeetingStartRemovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let digest = String(repeating: "a", count: 64)
        let expected = [CalendarMeetingNotificationKind.upcoming, .detected].map {
            "\(CalendarMeetingNotificationService.requestIdentifierPrefix)\(digest).\($0.rawValue)"
        }

        service.removeStartNotifications(occurrenceDigest: digest)

        XCTAssertEqual(client.removed, [expected])
        XCTAssertEqual(client.removedDelivered, [expected])
        XCTAssertTrue(client.added.isEmpty)
    }

    func testConfigurationRequestsAuthorizationOnlyWhenUndetermined() async throws {
        let suiteName = "CalendarMeetingAuthorizationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        client.authorization = .denied
        let deniedService = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let denied = await deniedService.configureAndRequestAuthorization()
        XCTAssertEqual(denied, .denied)
        XCTAssertEqual(client.requestCount, 0)

        client.authorization = .notDetermined
        let undeterminedService = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let undetermined = await undeterminedService.configureAndRequestAuthorization()
        XCTAssertEqual(undetermined, .notDetermined)
        XCTAssertEqual(client.requestCount, 1)
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.calendarMeetingNotificationsConfigured))
    }

    func testAutoStopWarningRequiresAuthorizationAndRemovesPendingAndDeliveredCopies() async throws {
        let suiteName = "CalendarMeetingAutoStopNotificationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let digest = String(repeating: "b", count: 64)
        let now = Date(timeIntervalSince1970: 2_000_000_020)

        client.authorization = .denied
        let denied = await service.publishAutoStopWarning(
            occurrenceDigest: digest,
            now: now
        )
        XCTAssertFalse(denied)
        XCTAssertTrue(client.added.isEmpty)

        client.authorization = .authorized
        let authorized = await service.publishAutoStopWarning(
            occurrenceDigest: digest,
            now: now
        )
        XCTAssertTrue(authorized)
        let request = try XCTUnwrap(client.added.last)
        XCTAssertEqual(request.kind, .autoStop)
        XCTAssertEqual(request.occurrenceDigest, digest)
        XCTAssertEqual(request.fireDate, now)
        XCTAssertEqual(request.delivery, .immediate)
        XCTAssertTrue(request.identifier.hasSuffix(".autoStop"))
        XCTAssertEqual(client.removed.last, [request.identifier])
        XCTAssertEqual(client.removedDelivered.last, [request.identifier])

        let removedCountBeforeExplicitCall = client.removed.count
        let removedDeliveredCountBeforeExplicitCall = client.removedDelivered.count
        service.removeAutoStopWarning(occurrenceDigest: digest)
        XCTAssertEqual(client.removed.count, removedCountBeforeExplicitCall + 1)
        XCTAssertEqual(
            client.removedDelivered.count,
            removedDeliveredCountBeforeExplicitCall + 1
        )
        XCTAssertEqual(client.removed.last, [request.identifier])
        XCTAssertEqual(client.removedDelivered.last, [request.identifier])
    }

    func testAutoStopWarningFailsClosedWhenNotificationCannotBePublished() async throws {
        struct AddError: Error {}

        let suiteName = "CalendarMeetingAutoStopNotificationFailureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        client.authorization = .authorized
        client.addError = AddError()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)

        let published = await service.publishAutoStopWarning(
            occurrenceDigest: String(repeating: "c", count: 64)
        )

        XCTAssertFalse(published)
        XCTAssertTrue(client.added.isEmpty)
    }

    func testColdLaunchActionsRequireDigestAndDefaultClickNeverStarts() {
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: CalendarMeetingNotificationService.startActionIdentifier,
                occurrenceDigest: digest
            ),
            .armStart(digest)
        )
        XCTAssertNil(CalendarMeetingNotificationResponseMapper.response(
            actionIdentifier: CalendarMeetingNotificationService.startActionIdentifier,
            occurrenceDigest: nil
        ))
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: CalendarMeetingNotificationService
                    .armWhenJoinedActionIdentifier,
                occurrenceDigest: digest
            ),
            .armStart(digest)
        )
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                occurrenceDigest: digest
            ),
            .openRecorder
        )
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: UNNotificationDismissActionIdentifier,
                occurrenceDigest: digest
            ),
            .suppress(digest)
        )
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: CalendarMeetingNotificationService
                    .continueRecordingActionIdentifier,
                occurrenceDigest: digest,
                kind: .autoStop
            ),
            .continueRecording(digest)
        )
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                occurrenceDigest: digest,
                kind: .autoStop
            ),
            .continueRecording(digest)
        )
        XCTAssertNil(CalendarMeetingNotificationResponseMapper.response(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            occurrenceDigest: digest,
            kind: .autoStop
        ))
    }

    func testStartActionDoesNotActivateAppOrOpenSettings() {
        let startOptions = CalendarMeetingNotificationResponseMapper.actionOptions(
            for: CalendarMeetingNotificationService.startActionIdentifier
        )
        let armOptions = CalendarMeetingNotificationResponseMapper.actionOptions(
            for: CalendarMeetingNotificationService.armWhenJoinedActionIdentifier
        )
        let suppressOptions = CalendarMeetingNotificationResponseMapper.actionOptions(
            for: CalendarMeetingNotificationService.suppressActionIdentifier
        )
        let continueOptions = CalendarMeetingNotificationResponseMapper.actionOptions(
            for: CalendarMeetingNotificationService.continueRecordingActionIdentifier
        )

        XCTAssertFalse(startOptions.contains(.foreground))
        XCTAssertFalse(armOptions.contains(.foreground))
        XCTAssertTrue(suppressOptions.contains(.destructive))
        XCTAssertFalse(suppressOptions.contains(.foreground))
        XCTAssertFalse(continueOptions.contains(.foreground))
    }

    func testOnlyRecorderResponseAllowsManagedWindowReopen() {
        let digest = String(repeating: "a", count: 64)

        XCTAssertTrue(
            CalendarMeetingNotificationResponse.armStart(digest).keepsApplicationInBackground
        )
        XCTAssertTrue(
            CalendarMeetingNotificationResponse.suppress(digest).keepsApplicationInBackground
        )
        XCTAssertTrue(
            CalendarMeetingNotificationResponse.continueRecording(digest)
                .keepsApplicationInBackground
        )
        XCTAssertFalse(
            CalendarMeetingNotificationResponse.openRecorder.keepsApplicationInBackground
        )
    }

    func testOnlyAutoStopUsesTimeSensitiveInterruptionLevel() {
        XCTAssertEqual(
            CalendarMeetingNotificationPresentationPolicy.interruptionLevel(for: .autoStop),
            .timeSensitive
        )
        XCTAssertNil(
            CalendarMeetingNotificationPresentationPolicy.interruptionLevel(for: .upcoming)
        )
        XCTAssertNil(
            CalendarMeetingNotificationPresentationPolicy.interruptionLevel(for: .detected)
        )
    }

    func testForegroundAutoStopIncludesBannerListAndSound() {
        let autoStop = CalendarMeetingNotificationPresentationPolicy.foregroundOptions(
            for: .autoStop
        )
        XCTAssertTrue(autoStop.contains(.banner))
        XCTAssertTrue(autoStop.contains(.list))
        XCTAssertTrue(autoStop.contains(.sound))

        let reminder = CalendarMeetingNotificationPresentationPolicy.foregroundOptions(
            for: .upcoming
        )
        XCTAssertTrue(reminder.contains(.banner))
        XCTAssertFalse(reminder.contains(.list))
        XCTAssertTrue(reminder.contains(.sound))
    }

    func testAutoStopMetadataContainsOnlyDigestAndKind() {
        let digest = String(repeating: "d", count: 64)
        let userInfo = CalendarMeetingNotificationPresentationPolicy.userInfo(
            occurrenceDigest: digest,
            kind: .autoStop
        )

        XCTAssertEqual(
            Set(userInfo.keys.compactMap { $0 as? String }),
            [
                CalendarMeetingNotificationService.digestUserInfoKey,
                CalendarMeetingNotificationService.kindUserInfoKey
            ]
        )
        XCTAssertEqual(
            userInfo[CalendarMeetingNotificationService.digestUserInfoKey] as? String,
            digest
        )
        XCTAssertEqual(
            userInfo[CalendarMeetingNotificationService.kindUserInfoKey] as? String,
            CalendarMeetingNotificationKind.autoStop.rawValue
        )
    }
}
