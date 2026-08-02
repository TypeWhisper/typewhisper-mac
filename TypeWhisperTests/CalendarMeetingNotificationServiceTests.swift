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
    func add(_ request: CalendarMeetingNotificationRequest) async throws { added.append(request) }
    func removePendingRequests(withIdentifiers identifiers: [String]) { removed.append(identifiers) }
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
    }

    func testRefreshOnlyRemovesCalendarMeetingRequests() async throws {
        let suiteName = "CalendarMeetingNotificationRemovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        client.pendingIdentifiers = [
            "external.notification",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "one.upcoming",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "two.detected"
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

    func testDetectedNotificationReplacesUpcomingRequest() async throws {
        let suiteName = "CalendarMeetingDetectedTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let occurrence = makeCalendarMeetingTestOccurrence()
        let now = Date(timeIntervalSince1970: 2_000_000_010)

        await service.publishDetectedMeeting(occurrence, now: now)

        XCTAssertEqual(client.removed.count, 1)
        XCTAssertEqual(client.added.count, 1)
        XCTAssertEqual(client.added.first?.kind, .detected)
        XCTAssertEqual(client.added.first?.occurrenceDigest, occurrence.id)
        XCTAssertEqual(client.added.first?.fireDate, now.addingTimeInterval(1))
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

    func testColdLaunchActionsRequireDigestAndDefaultClickNeverStarts() {
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: CalendarMeetingNotificationService.startActionIdentifier,
                occurrenceDigest: digest
            ),
            .start(digest)
        )
        XCTAssertNil(CalendarMeetingNotificationResponseMapper.response(
            actionIdentifier: CalendarMeetingNotificationService.startActionIdentifier,
            occurrenceDigest: nil
        ))
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                occurrenceDigest: digest
            ),
            .openPremiumSettings
        )
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: UNNotificationDismissActionIdentifier,
                occurrenceDigest: digest
            ),
            .suppress(digest)
        )
    }
}
