import Foundation
import XCTest
@testable import TypeWhisper

final class MeetingLinkParserTests: XCTestCase {
    private let parser = MeetingLinkParser()

    func testZoomVariantsCanonicalizeWithoutTrackingData() throws {
        let links = parser.parse(
            eventURL: URL(string: "https://acme.zoom.us/j/123456789?pwd=secret&utm_source=test#fragment"),
            location: "Also https://zoomgov.com/wc/join/987654321?tk=ignored",
            notes: "Vanity: acme.zoom.us/my/Weekly-Room. Duplicate https://acme.zoom.us/j/123456789"
        )

        XCTAssertEqual(Set(links), [
            CalendarMeetingCanonicalLink(provider: .zoom, identity: "j/123456789"),
            CalendarMeetingCanonicalLink(provider: .zoom, identity: "j/987654321"),
            CalendarMeetingCanonicalLink(provider: .zoom, identity: "my/weekly-room"),
        ])
    }

    func testZoomDeepLinkAcceptsDuplicateQueryKeysWithoutCrashing() {
        let links = parser.parse(text: "zoommtg://zoom.us/join?confno=123456&confno=999999&pwd=secret")

        XCTAssertEqual(links, [
            CalendarMeetingCanonicalLink(provider: .zoom, identity: "j/123456")
        ])
    }

    func testZoomStartAndJoinPathsShareCanonicalMeetingIdentity() {
        let join = parser.parse(text: "https://example.zoom.us/j/123456789")
        let start = parser.parse(text: "https://example.zoom.us/s/123-456-789")
        let webClient = parser.parse(text: "https://zoom.us/wc/join/123%20456%20789")

        XCTAssertEqual(join, start)
        XCTAssertEqual(start, webClient)
    }

    func testTeamsWebAndDeepLinksCanonicalize() {
        let web = parser.parse(text: "https://TEAMS.MICROSOFT.COM/l/meetup-join/19%3ameeting_ABC%40thread.v2/0?context=x")
        let live = parser.parse(text: "https://teams.live.com/meet/1234567890123?p=tracking")
        let deep = parser.parse(text: "msteams:/l/meetup-join/19%3ameeting_ABC%40thread.v2/0?foo=bar")

        XCTAssertEqual(web.first?.provider, .teams)
        XCTAssertEqual(web.first?.identity, "teams.microsoft.com/l/meetup-join/19:meeting_ABC@thread.v2/0")
        XCTAssertEqual(live.first?.identity, "teams.live.com/meet/1234567890123")
        XCTAssertEqual(deep.first?.identity, "teams.microsoft.com/l/meetup-join/19:meeting_ABC@thread.v2/0")
    }

    func testTeamsRouteCasingDoesNotChangeCanonicalIdentity() {
        let lowercase = parser.parse(
            text: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC%40thread.v2/0"
        )
        let mixedCase = parser.parse(
            text: "https://teams.microsoft.com/L/MEETUP-JOIN/19%3ameeting_ABC%40thread.v2/0"
        )
        let deepLink = parser.parse(
            text: "msteams:/L/MEETUP-JOIN/19%3ameeting_ABC%40thread.v2/0"
        )

        XCTAssertEqual(mixedCase, lowercase)
        XCTAssertEqual(deepLink, lowercase)
    }

    func testGoogleMeetCodeAndLookupCanonicalize() {
        XCTAssertEqual(
            parser.parse(text: "Join https://meet.google.com/ABC-defg-HIJ?authuser=1.").first,
            CalendarMeetingCanonicalLink(provider: .googleMeet, identity: "abc-defg-hij")
        )
        XCTAssertEqual(
            parser.parse(text: "https://meet.google.com/lookup/Weekly-Planning?hs=122").first,
            CalendarMeetingCanonicalLink(provider: .googleMeet, identity: "lookup/weekly-planning")
        )
    }

    func testFaceTimeWebPayloadIsOrderIndependentAndDeepLinkNormalizesTarget() {
        let first = parser.parse(text: "https://facetime.apple.com/join?token=abc&groupId=123&utm_source=calendar")
        let second = parser.parse(text: "https://facetime.apple.com/join?groupId=123&token=abc")
        let deep = parser.parse(text: "facetime://Alice%40Example.com")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first?.identity, "join/groupid=123&token=abc")
        XCTAssertEqual(deep.first, CalendarMeetingCanonicalLink(
            provider: .faceTime,
            identity: "target/alice@example.com"
        ))
    }

    func testRejectsLookalikesHomepagesTitlesAndInvalidSchemes() {
        let text = """
        Zoom meeting
        https://zoom.us/
        https://zoom.us/j/not-a-meeting
        https://zoom.us.evil.example/j/123
        https://teams.microsoft.com/
        https://meet.google.com/not-a-code
        javascript:https://meet.google.com/abc-defg-hij
        """

        XCTAssertTrue(parser.parse(text: text).isEmpty)
        XCTAssertTrue(parser.parse(eventURL: nil, location: "Zoom", notes: nil).isEmpty)
    }

    func testOccurrenceDigestUsesStableIdentifierAndActualStartOnly() {
        let start = Date(timeIntervalSince1970: 2_000_000_000.125)
        let first = makeCalendarMeetingTestOccurrence(eventID: "series", start: start, title: "First")
        let renamed = makeCalendarMeetingTestOccurrence(eventID: "series", start: start, title: "Renamed")
        let moved = makeCalendarMeetingTestOccurrence(
            eventID: "series",
            start: start.addingTimeInterval(60),
            title: "First"
        )

        XCTAssertEqual(first.occurrenceDigest, renamed.occurrenceDigest)
        XCTAssertNotEqual(first.occurrenceDigest, moved.occurrenceDigest)
        XCTAssertEqual(first.occurrenceDigest.count, 64)
        XCTAssertFalse(first.occurrenceDigest.contains("series"))
    }
}

func makeCalendarMeetingTestOccurrence(
    eventID: String = "event-1",
    start: Date = Date(timeIntervalSince1970: 2_000_000_000),
    duration: TimeInterval = 3_600,
    title: String = "Planning",
    calendarID: String = "calendar-1",
    participation: CalendarMeetingParticipationStatus = .accepted,
    links: [CalendarMeetingCanonicalLink] = [
        CalendarMeetingCanonicalLink(provider: .zoom, identity: "j/123456789")
    ]
) -> CalendarMeetingOccurrence {
    CalendarMeetingOccurrence(
        eventIdentifier: eventID,
        occurrenceStart: start,
        startDate: start,
        endDate: start.addingTimeInterval(duration),
        title: title,
        calendarID: calendarID,
        participationStatus: participation,
        meetingLinks: links
    )
}

func makeCalendarMeetingTranscriptMetadata(
    eventIdentifier: String = "event-1",
    title: String = "Planning",
    startDate: Date = Date(timeIntervalSince1970: 2_000_000_000),
    endDate: Date = Date(timeIntervalSince1970: 2_000_003_600),
    location: String? = "Conference Room",
    organizer: CalendarMeetingParticipant? = CalendarMeetingParticipant(
        name: "Ada Organizer",
        emailAddress: "ada@example.com",
        status: .accepted,
        isCurrentUser: false
    ),
    attendees: [CalendarMeetingParticipant] = [
        CalendarMeetingParticipant(
            name: "Marco Attendee",
            emailAddress: "marco@example.com",
            status: .accepted,
            isCurrentUser: true
        )
    ]
) -> CalendarMeetingTranscriptMetadata {
    CalendarMeetingTranscriptMetadata(
        eventIdentifier: eventIdentifier,
        title: title,
        startDate: startDate,
        endDate: endDate,
        location: location,
        organizer: organizer,
        attendees: attendees
    )
}
