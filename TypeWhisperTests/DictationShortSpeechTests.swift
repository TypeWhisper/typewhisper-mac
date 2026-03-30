import Foundation
import XCTest
@testable import TypeWhisper

final class DictationShortSpeechTests: XCTestCase {
    func testEmptyBuffer_isDiscardedAsTooShort() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0, peakLevel: 0), .discardTooShort)
    }

    func testThirtyMsHighPeak_isStillTooShort() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.03, peakLevel: 0.2), .discardTooShort)
    }

    func testEightyMsSpeechAtPointZeroZeroEight_transcribesAndPadsToZeroPointSevenFive() {
        let samples = makeSamples(duration: 0.08)

        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.08, peakLevel: 0.008), .transcribe)

        let paddedSamples = paddedSamplesForFinalTranscription(samples, rawDuration: 0.08)
        XCTAssertEqual(paddedSamples.count, 12_000)
        XCTAssertEqual(Double(paddedSamples.count) / AudioRecordingService.targetSampleRate, 0.75, accuracy: 0.0001)
    }

    func testOneHundredTwentyMsQuietClip_isNoSpeech() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.12, peakLevel: 0.005), .discardNoSpeech)
    }

    func testFourHundredMsSpeech_usesStandardNoSpeechThresholdAndNoMinimumPad() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.4, peakLevel: 0.009), .discardNoSpeech)
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.4, peakLevel: 0.011), .transcribe)

        let paddedSamples = paddedSamplesForFinalTranscription(makeSamples(duration: 0.4), rawDuration: 0.4)
        XCTAssertEqual(paddedSamples.count, 12_000)
        XCTAssertEqual(Double(paddedSamples.count) / AudioRecordingService.targetSampleRate, 0.75, accuracy: 0.0001)
    }

    func testFinalizeShortSpeechPolicy_waitsOnlyWhenBufferedDurationIsBelowFiveHundredths() {
        let policy = AudioRecordingService.StopPolicy.finalizeShortSpeech()

        XCTAssertTrue(policy.shouldApplyGracePeriod(bufferedDuration: 0))
        XCTAssertTrue(policy.shouldApplyGracePeriod(bufferedDuration: 0.049))
        XCTAssertFalse(policy.shouldApplyGracePeriod(bufferedDuration: 0.05))
        XCTAssertFalse(policy.shouldApplyGracePeriod(bufferedDuration: 0.08))
        XCTAssertFalse(AudioRecordingService.StopPolicy.immediate.shouldApplyGracePeriod(bufferedDuration: 0.01))
    }

    private func makeSamples(duration: TimeInterval) -> [Float] {
        let count = Int(duration * AudioRecordingService.targetSampleRate)
        return [Float](repeating: 0.1, count: count)
    }
}
