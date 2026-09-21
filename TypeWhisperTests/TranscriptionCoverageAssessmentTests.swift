import Foundation
import XCTest
@testable import TypeWhisper

/// Fixtures from issue #1352: Groq Whisper Large V3 intermittently returns only part
/// of a long dictation. All cases run without network against inline fixtures.
final class TranscriptionCoverageAssessmentTests: XCTestCase {
    private func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String = "x") -> TranscriptionSegment {
        TranscriptionSegment(text: text, start: start, end: end)
    }

    private func words(_ count: Int) -> String {
        (0..<count).map { "wort\($0)" }.joined(separator: " ")
    }

    /// Evenly spaced segments up to `end`, so that the tail check does not fire.
    private func segments(coveringUpTo end: TimeInterval, count: Int = 4) -> [TranscriptionSegment] {
        let step = end / Double(count)
        return (0..<count).map { segment(Double($0) * step, Double($0 + 1) * step) }
    }

    func testDefaultThresholdsArePinned() {
        let thresholds = TranscriptionCoverageAssessor.Thresholds.default
        XCTAssertEqual(thresholds.minimumDurationForWordRate, 20)
        XCTAssertEqual(thresholds.minimumWordsPerSecond, 0.8)
        XCTAssertEqual(thresholds.minimumDurationForTailCheck, 15)
        XCTAssertEqual(thresholds.uncoveredTailFloorSeconds, 6)
        XCTAssertEqual(thresholds.uncoveredTailFraction, 0.2)
    }

    // Fixture 1: 40.3 s, three words, one segment 0.0 to 2.5 s (extreme case from the issue).
    func testFortySecondsWithThreeWords_flagsWordRateAndTail() {
        let assessment = TranscriptionCoverageAssessor.assess(
            text: "AtoLayout.org. Vielen Dank!",
            segments: [segment(0.0, 2.5, "AtoLayout.org. Vielen Dank!")],
            audioDuration: 40.3
        )

        XCTAssertEqual(assessment.reasons, [.lowWordRate, .uncoveredTail])
        XCTAssertTrue(assessment.isSuspicious)
        XCTAssertTrue((3...4).contains(assessment.wordCount), "\(assessment.wordCount)")
        XCTAssertEqual(assessment.lastSegmentEnd, 2.5)
        XCTAssertEqual(assessment.uncoveredTailSeconds ?? -1, 37.8, accuracy: 0.001)
        XCTAssertLessThan(assessment.wordsPerSecond, 0.2)
    }

    // Fixture 2: 34 s, nine words, no segments (text-only fallback in the helper).
    func testThirtyFourSecondsWithNineWordsAndNoSegments_flagsWordRateOnly() {
        let assessment = TranscriptionCoverageAssessor.assess(
            text: "Das ist ein kurzer Test. Vielen Dank für's Zuschauen!",
            segments: [],
            audioDuration: 34
        )

        XCTAssertEqual(assessment.reasons, [.lowWordRate])
        XCTAssertNil(assessment.lastSegmentEnd)
        XCTAssertNil(assessment.uncoveredTailSeconds)
    }

    // Fixture 3: 60 s, 65 words (1.08 words/s), last segment ends at 30 s.
    func testSixtySecondsHalfCovered_flagsTailButNotWordRate() {
        let assessment = TranscriptionCoverageAssessor.assess(
            text: words(65),
            segments: segments(coveringUpTo: 30.0),
            audioDuration: 60
        )

        XCTAssertEqual(assessment.reasons, [.uncoveredTail])
        XCTAssertEqual(assessment.uncoveredTailSeconds ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(assessment.wordsPerSecond, 65.0 / 60.0, accuracy: 0.001)
    }

    // Fixture 4: 60 s, 60 words (slow speech with pauses), segments up to 58.5 s.
    func testSlowSpeechFullyCovered_isNotSuspicious() {
        let assessment = TranscriptionCoverageAssessor.assess(
            text: words(60),
            segments: segments(coveringUpTo: 58.5),
            audioDuration: 60
        )

        XCTAssertFalse(assessment.isSuspicious)
        XCTAssertEqual(assessment.reasons, [])
    }

    // Fixture 5: 12 s, 8 words (0.67 words/s), below both minimum durations.
    func testShortRecordingBelowMinimumDurations_isNotSuspicious() {
        let assessment = TranscriptionCoverageAssessor.assess(
            text: words(8),
            segments: [segment(0, 11.0)],
            audioDuration: 12
        )

        XCTAssertFalse(assessment.isSuspicious)
    }

    // Fixture 6: 15 s at the measured baseline of 2.18 words/s.
    func testBaselineSpeechRate_isNotSuspicious() {
        let assessment = TranscriptionCoverageAssessor.assess(
            text: words(33),
            segments: segments(coveringUpTo: 14.6),
            audioDuration: 15
        )

        XCTAssertFalse(assessment.isSuspicious)
        XCTAssertEqual(assessment.wordsPerSecond, 2.2, accuracy: 0.01)
    }

    // Fixture 7: Japanese text without spaces must not count as a single word.
    func testJapaneseTextWithoutSpaces_countsMultipleWords() {
        let text = "今日は新しい機能をテストしています。長い口述が途中で切れないことを確認したいです。"
        let assessment = TranscriptionCoverageAssessor.assess(
            text: text,
            segments: segments(coveringUpTo: 19.5),
            audioDuration: 20
        )

        XCTAssertGreaterThan(assessment.wordCount, 3)
        XCTAssertEqual(text.split(separator: " ").count, 1, "fixture must contain no spaces")
        XCTAssertFalse(assessment.isSuspicious)
    }

    // Fixture 8: segment end beyond the audio duration yields a zero tail.
    func testSegmentEndBeyondDuration_hasZeroTail() {
        let assessment = TranscriptionCoverageAssessor.assess(
            text: words(80),
            segments: [segment(0, 20), segment(20, 40.4)],
            audioDuration: 40
        )

        XCTAssertEqual(assessment.uncoveredTailSeconds, 0)
        XCTAssertFalse(assessment.isSuspicious)
    }

    // Fixture 9: unsorted segments, the maximum end counts, not the last array element.
    func testUnsortedSegments_useMaximumEnd() {
        let assessment = TranscriptionCoverageAssessor.assess(
            text: words(50),
            segments: [segment(0, 10), segment(20, 29.5), segment(10, 20)],
            audioDuration: 30
        )

        XCTAssertEqual(assessment.lastSegmentEnd, 29.5)
        XCTAssertFalse(assessment.isSuspicious)
    }

    // Fixture 10: zero duration and empty text must not crash or flag.
    func testZeroDurationAndEmptyText_isNotSuspicious() {
        let assessment = TranscriptionCoverageAssessor.assess(text: "", segments: [], audioDuration: 0)

        XCTAssertEqual(assessment.reasons, [])
        XCTAssertEqual(assessment.wordsPerSecond, 0)
        XCTAssertEqual(assessment.wordCount, 0)
        XCTAssertFalse(assessment.isSuspicious)
    }

    // Fixture 11: log line carries all coverage fields.
    func testLogDescriptionContainsAllFields() {
        let assessment = TranscriptionCoverageAssessor.assess(
            text: words(4),
            segments: [segment(0.0, 2.5)],
            audioDuration: 40.3
        )

        let log = assessment.logDescription
        XCTAssertTrue(log.contains("audioDuration=40.30s"), log)
        XCTAssertTrue(log.contains("lastSegmentEnd=2.50s"), log)
        XCTAssertTrue(log.contains("uncoveredTail=37.80s"), log)
        XCTAssertTrue(log.contains("words=4"), log)
        XCTAssertTrue(log.contains("wordsPerSecond=0.10"), log)
        XCTAssertTrue(log.contains("suspicious=true"), log)
        XCTAssertTrue(log.contains("reasons=lowWordRate,uncoveredTail"), log)

        let noSegments = TranscriptionCoverageAssessor.assess(text: words(30), segments: [], audioDuration: 10)
        XCTAssertTrue(noSegments.logDescription.contains("lastSegmentEnd=n/a"))
        XCTAssertTrue(noSegments.logDescription.contains("suspicious=false"))
        XCTAssertTrue(noSegments.logDescription.contains("reasons=none"))
    }

    // Fixture 12: custom thresholds are respected.
    func testCustomThresholdsAreRespected() {
        var thresholds = TranscriptionCoverageAssessor.Thresholds.default
        thresholds.minimumWordsPerSecond = 2.5
        thresholds.minimumDurationForWordRate = 10

        let assessment = TranscriptionCoverageAssessor.assess(
            text: words(33),
            segments: segments(coveringUpTo: 14.6),
            audioDuration: 15,
            thresholds: thresholds
        )

        XCTAssertEqual(assessment.reasons, [.lowWordRate])
    }

    // MARK: - Tester hardening (#1352): calibration boundaries that protect against false alarms

    // Tail check: for long audio the 20 % fraction dominates the 6 s floor. A trailing pause
    // of 8 s in a 60 s dictation is normal speech and must not flag; 13 s must.
    func testTailFractionDominatesFloorOnLongAudio() {
        let notFlagged = TranscriptionCoverageAssessor.assess(
            text: words(100),
            segments: segments(coveringUpTo: 52.0),
            audioDuration: 60
        )
        XCTAssertEqual(notFlagged.uncoveredTailSeconds ?? -1, 8, accuracy: 0.001)
        XCTAssertFalse(notFlagged.isSuspicious, notFlagged.logDescription)

        let flagged = TranscriptionCoverageAssessor.assess(
            text: words(100),
            segments: segments(coveringUpTo: 47.0),
            audioDuration: 60
        )
        XCTAssertEqual(flagged.reasons, [.uncoveredTail], flagged.logDescription)
    }

    // Tail check: for short audio the 6 s floor dominates the fraction (20 % of 20 s = 4 s).
    func testTailFloorDominatesFractionOnShortAudio() {
        let flagged = TranscriptionCoverageAssessor.assess(
            text: words(40),
            segments: segments(coveringUpTo: 13.5),
            audioDuration: 20
        )
        XCTAssertEqual(flagged.reasons, [.uncoveredTail], flagged.logDescription)

        let notFlagged = TranscriptionCoverageAssessor.assess(
            text: words(40),
            segments: segments(coveringUpTo: 14.5),
            audioDuration: 20
        )
        XCTAssertFalse(notFlagged.isSuspicious, notFlagged.logDescription)
    }

    // Word-rate check: applies from exactly 20 s, and exactly 0.8 words/s is still fine.
    func testWordRateBoundaries() {
        let justBelowRate = TranscriptionCoverageAssessor.assess(
            text: words(15),
            segments: segments(coveringUpTo: 20),
            audioDuration: 20
        )
        XCTAssertEqual(justBelowRate.reasons, [.lowWordRate], justBelowRate.logDescription)

        let exactlyAtRate = TranscriptionCoverageAssessor.assess(
            text: words(16),
            segments: segments(coveringUpTo: 20),
            audioDuration: 20
        )
        XCTAssertFalse(exactlyAtRate.isSuspicious, exactlyAtRate.logDescription)

        let justBelowDuration = TranscriptionCoverageAssessor.assess(
            text: words(15),
            segments: segments(coveringUpTo: 19.9),
            audioDuration: 19.9
        )
        XCTAssertFalse(justBelowDuration.isSuspicious, justBelowDuration.logDescription)
    }

    // Non-finite input from a broken provider response must neither crash nor flag.
    func testNonFiniteDurationAndSegmentEndsAreIgnored() {
        let assessment = TranscriptionCoverageAssessor.assess(
            text: words(10),
            segments: [segment(0, .infinity), segment(0, .nan)],
            audioDuration: .nan
        )
        XCTAssertEqual(assessment.audioDuration, 0)
        XCTAssertEqual(assessment.wordsPerSecond, 0)
        XCTAssertNil(assessment.lastSegmentEnd)
        XCTAssertFalse(assessment.isSuspicious)
    }

    func testWordCountIgnoresPunctuationOnlyTokens() {
        XCTAssertEqual(TranscriptionCoverageAssessor.wordCount(in: "Hallo, Welt! ... 123 - ?"), 3)
        XCTAssertEqual(TranscriptionCoverageAssessor.wordCount(in: "   "), 0)
    }
}
