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

    func testNegativeTimesAndNaNStartAtZero() {
        let segments = [
            TranscriptionSegment(text: "negative", start: -0.2, end: -.infinity),
            TranscriptionSegment(text: "nan", start: .nan, end: .nan),
        ]

        XCTAssertEqual(
            SubtitleExporter.exportVTT(segments: segments),
            "WEBVTT\n\n1\n00:00:00.000 --> 00:00:00.000\nnegative\n\n2\n00:00:00.000 --> 00:00:00.000\nnan\n"
        )
    }

    func testHoursGrowBeyondTwoDigits() {
        let segments = [
            TranscriptionSegment(text: "long", start: 359_999.9996, end: 360_001.5),
        ]

        XCTAssertEqual(
            SubtitleExporter.exportVTT(segments: segments),
            "WEBVTT\n\n1\n100:00:00.000 --> 100:00:01.500\nlong\n"
        )
    }

    func testHugeAndInfiniteTimesAreClampedInsteadOfTrapping() {
        let segments = [
            TranscriptionSegment(text: "huge", start: 1e20, end: .infinity),
        ]

        XCTAssertEqual(
            SubtitleExporter.exportSRT(segments: segments),
            "1\n277777777:46:40,000 --> 277777777:46:40,000\nhuge"
        )
    }
}
