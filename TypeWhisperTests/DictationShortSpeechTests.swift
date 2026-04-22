import Foundation
import XCTest
@testable import TypeWhisper

final class DictationShortSpeechTests: XCTestCase {
    private final class ReleaseProbe {
        private let onDeinit: () -> Void

        init(onDeinit: @escaping () -> Void = {}) {
            self.onDeinit = onDeinit
        }

        deinit {
            onDeinit()
        }
    }

    func testEmptyBuffer_isDiscardedAsTooShort() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0, peakLevel: 0, hasConfirmedText: false), .discardTooShort)
    }

    func testThirtyMsHighPeak_isStillTooShort() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.03, peakLevel: 0.2, hasConfirmedText: false), .discardTooShort)
    }

    func testThirtyMsPreviewText_isStillTooShort() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.03, peakLevel: 0.2, hasConfirmedText: true), .discardTooShort)
    }

    func testEightyMsSpeechAtPointZeroZeroEight_transcribesAndPadsToZeroPointSevenFive() {
        let samples = makeSamples(duration: 0.08)

        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.08, peakLevel: 0.008, hasConfirmedText: false), .transcribe)

        let paddedSamples = paddedSamplesForFinalTranscription(samples, rawDuration: 0.08)
        XCTAssertEqual(paddedSamples.count, 12_000)
        XCTAssertEqual(Double(paddedSamples.count) / AudioRecordingService.targetSampleRate, 0.75, accuracy: 0.0001)
    }

    func testOneHundredTwentyMsVeryQuietClip_isNoSpeech() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.12, peakLevel: 0.0029, hasConfirmedText: false), .discardNoSpeech)
    }

    func testOneHundredTwentyMsBorderlineQuietClip_nowTranscribes() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.12, peakLevel: 0.0034, hasConfirmedText: false), .transcribe)
    }

    func testOneHundredTwentyMsQuietClip_transcribesWhenAggressivePolicyEnabled() {
        XCTAssertEqual(
            classifyShortSpeech(
                rawDuration: 0.12,
                peakLevel: 0.0034,
                hasConfirmedText: false,
                transcribeShortQuietClipsAggressively: true
            ),
            .transcribe
        )
    }

    func testOneHundredTwentyMsQuietClip_withConfirmedText_transcribes() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.12, peakLevel: 0.0029, hasConfirmedText: true), .transcribe)
    }

    func testFourHundredMsSpeech_usesLoweredShortClipThresholdAndNoMinimumPad() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.4, peakLevel: 0.0029, hasConfirmedText: false), .discardNoSpeech)
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.4, peakLevel: 0.0034, hasConfirmedText: false), .transcribe)

        let paddedSamples = paddedSamplesForFinalTranscription(makeSamples(duration: 0.4), rawDuration: 0.4)
        XCTAssertEqual(paddedSamples.count, 12_000)
        XCTAssertEqual(Double(paddedSamples.count) / AudioRecordingService.targetSampleRate, 0.75, accuracy: 0.0001)
    }

    func testFourHundredMsQuietClip_withConfirmedText_transcribes() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.4, peakLevel: 0.0029, hasConfirmedText: true), .transcribe)
    }

    func testThirtyMsQuietClip_staysTooShortEvenWhenAggressivePolicyEnabled() {
        XCTAssertEqual(
            classifyShortSpeech(
                rawDuration: 0.03,
                peakLevel: 0.2,
                hasConfirmedText: false,
                transcribeShortQuietClipsAggressively: true
            ),
            .discardTooShort
        )
    }

    func testEightHundredEightyFiveMsClip_withLowSpeechPeakStillTranscribes() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.885, peakLevel: 0.0069, hasConfirmedText: false), .transcribe)
    }

    func testOnePointTwoSecondsVeryQuietClip_isNoSpeech() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 1.2, peakLevel: 0.0059, hasConfirmedText: false), .discardNoSpeech)
    }

    func testOnePointTwoSecondsBorderlineQuietClip_nowTranscribes() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 1.2, peakLevel: 0.0061, hasConfirmedText: false), .transcribe)
    }

    func testOnePointTwoSecondsVeryQuietClip_withConfirmedText_transcribes() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 1.2, peakLevel: 0.0059, hasConfirmedText: true), .transcribe)
    }

    func testConfirmedTranscriptionResultText_requiresNonEmptyResult() {
        XCTAssertFalse(hasConfirmedTranscriptionResultText(nil))
        XCTAssertFalse(hasConfirmedTranscriptionResultText(TranscriptionResult(
            text: "",
            detectedLanguage: nil,
            duration: 1.2,
            processingTime: 0.1,
            engineUsed: "whisper",
            segments: []
        )))
        XCTAssertFalse(hasConfirmedTranscriptionResultText(TranscriptionResult(
            text: "   ",
            detectedLanguage: nil,
            duration: 1.2,
            processingTime: 0.1,
            engineUsed: "whisper",
            segments: []
        )))
        XCTAssertTrue(hasConfirmedTranscriptionResultText(TranscriptionResult(
            text: "hello",
            detectedLanguage: "en",
            duration: 1.2,
            processingTime: 0.1,
            engineUsed: "whisper",
            segments: []
        )))
    }

    func testFinalizeShortSpeechPolicy_waitsOnlyWhenBufferedDurationIsBelowFiveHundredths() {
        let policy = AudioRecordingService.StopPolicy.finalizeShortSpeech()

        XCTAssertTrue(policy.shouldApplyGracePeriod(bufferedDuration: 0))
        XCTAssertTrue(policy.shouldApplyGracePeriod(bufferedDuration: 0.049))
        XCTAssertFalse(policy.shouldApplyGracePeriod(bufferedDuration: 0.05))
        XCTAssertFalse(policy.shouldApplyGracePeriod(bufferedDuration: 0.08))
        XCTAssertFalse(AudioRecordingService.StopPolicy.immediate.shouldApplyGracePeriod(bufferedDuration: 0.01))
    }

    func testDelayedReleaseRetainer_keepsObjectAliveUntilDelayExpires() throws {
        let retainer = DelayedReleaseRetainer<ReleaseProbe>(label: "com.typewhisper.tests.delayed-release")
        let released = expectation(description: "release after delay")
        let releaseLock = NSLock()
        var didRelease = false
        var probe: ReleaseProbe? = ReleaseProbe {
            releaseLock.withLock {
                didRelease = true
            }
            released.fulfill()
        }

        retainer.retain(try XCTUnwrap(probe), for: 0.1)
        probe = nil

        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertFalse(releaseLock.withLock { didRelease })
        wait(for: [released], timeout: 0.5)
    }

    private func makeSamples(duration: TimeInterval) -> [Float] {
        let count = Int(duration * AudioRecordingService.targetSampleRate)
        return [Float](repeating: 0.1, count: count)
    }
}
