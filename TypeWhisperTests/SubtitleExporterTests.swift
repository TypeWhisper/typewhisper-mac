import XCTest
@testable import TypeWhisper

final class SubtitleExporterTests: XCTestCase {
    func testAdjacentCuesShareTheirBoundary() {
        // 12.16 + 6.56 is 18.720000000000002 and 18.72 is 18.7199… as a Double.
        let segments = [
            TranscriptionSegment(text: "first", start: 12.16, end: 12.16 + 6.56),
            TranscriptionSegment(text: "second", start: 18.72, end: 19.68),
        ]

        XCTAssertEqual(
            SubtitleExporter.exportSRT(segments: segments),
            "1\n00:00:12,160 --> 00:00:18,720\nfirst\n\n2\n00:00:18,720 --> 00:00:19,680\nsecond"
        )
        XCTAssertEqual(
            SubtitleExporter.exportVTT(segments: segments),
            "WEBVTT\n\n1\n00:00:12.160 --> 00:00:18.720\nfirst\n\n2\n00:00:18.720 --> 00:00:19.680\nsecond\n"
        )
    }

    func testRoundingCarriesIntoSecondsMinutesAndHours() {
        let segments = [
            TranscriptionSegment(text: "carry", start: 59.9996, end: 3599.9999),
        ]

        XCTAssertEqual(
            SubtitleExporter.exportSRT(segments: segments),
            "1\n00:01:00,000 --> 01:00:00,000\ncarry"
        )
    }

    func testNegativeAndNonFiniteTimesStartAtZero() {
        let segments = [
            TranscriptionSegment(text: "clamped", start: -0.2, end: .infinity),
        ]

        XCTAssertEqual(
            SubtitleExporter.exportVTT(segments: segments),
            "WEBVTT\n\n1\n00:00:00.000 --> 00:00:00.000\nclamped\n"
        )
    }
}
