import EventKit
import Foundation
import XCTest
@testable import TypeWhisper

final class CalendarMeetingEventProviderTests: XCTestCase {
    func testAuthorizationMappingCoversEventKitStates() {
        XCTAssertEqual(EventKitCalendarMeetingProvider.mapAuthorization(.notDetermined), .notDetermined)
        XCTAssertEqual(EventKitCalendarMeetingProvider.mapAuthorization(.restricted), .restricted)
        XCTAssertEqual(EventKitCalendarMeetingProvider.mapAuthorization(.denied), .denied)
        XCTAssertEqual(EventKitCalendarMeetingProvider.mapAuthorization(.writeOnly), .writeOnly)
        XCTAssertEqual(EventKitCalendarMeetingProvider.mapAuthorization(.fullAccess), .fullAccess)
    }

    func testParticipationRulesSeparateRemindersFromAutomaticStarts() {
        XCTAssertTrue(CalendarMeetingParticipationStatus.pending.permitsReminder)
        XCTAssertFalse(CalendarMeetingParticipationStatus.pending.permitsAutomaticStart)
        XCTAssertTrue(CalendarMeetingParticipationStatus.unknown.permitsReminder)
        XCTAssertFalse(CalendarMeetingParticipationStatus.delegated.permitsAutomaticStart)
        XCTAssertFalse(CalendarMeetingParticipationStatus.declined.permitsReminder)
        XCTAssertTrue(CalendarMeetingParticipationStatus.accepted.permitsAutomaticStart)
        XCTAssertTrue(CalendarMeetingParticipationStatus.tentative.permitsAutomaticStart)
        XCTAssertTrue(CalendarMeetingParticipationStatus.noCurrentUser.permitsAutomaticStart)
    }

    func testRescheduledSeriesOccurrenceGetsNewDetachedIdentity() {
        let originalStart = Date(timeIntervalSince1970: 2_000_000_000)
        let original = makeCalendarMeetingTestOccurrence(
            eventID: "recurring-event",
            start: originalStart
        )
        let rescheduled = makeCalendarMeetingTestOccurrence(
            eventID: "recurring-event",
            start: originalStart.addingTimeInterval(900)
        )

        XCTAssertNotEqual(original.id, rescheduled.id)
        XCTAssertEqual(original.eventIdentifier, rescheduled.eventIdentifier)
    }

    func testJoinWindowIncludesLeadAndThirtyMinuteTail() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: start, duration: 1_800)

        XCTAssertTrue(occurrence.isInsideJoinWindow(at: start.addingTimeInterval(-600)))
        XCTAssertTrue(occurrence.isInsideJoinWindow(at: start.addingTimeInterval(3_600)))
        XCTAssertFalse(occurrence.isInsideJoinWindow(at: start.addingTimeInterval(-601)))
        XCTAssertFalse(occurrence.isInsideJoinWindow(at: start.addingTimeInterval(3_601)))
    }
}
