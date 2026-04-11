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
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0, peakLevel: 0, hasPreviewText: false), .discardTooShort)
    }

    func testThirtyMsHighPeak_isStillTooShort() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.03, peakLevel: 0.2, hasPreviewText: false), .discardTooShort)
    }

    func testThirtyMsPreviewText_isStillTooShort() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.03, peakLevel: 0.2, hasPreviewText: true), .discardTooShort)
    }

    func testEightyMsSpeechAtPointZeroZeroEight_transcribesAndPadsToZeroPointSevenFive() {
        let samples = makeSamples(duration: 0.08)

        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.08, peakLevel: 0.008, hasPreviewText: false), .transcribe)

        let paddedSamples = paddedSamplesForFinalTranscription(samples, rawDuration: 0.08)
        XCTAssertEqual(paddedSamples.count, 12_000)
        XCTAssertEqual(Double(paddedSamples.count) / AudioRecordingService.targetSampleRate, 0.75, accuracy: 0.0001)
    }

    func testOneHundredTwentyMsQuietClip_isNoSpeech() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.12, peakLevel: 0.0049, hasPreviewText: false), .discardNoSpeech)
    }

    func testOneHundredTwentyMsQuietClip_withPreviewText_transcribes() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.12, peakLevel: 0.0049, hasPreviewText: true), .transcribe)
    }

    func testFourHundredMsSpeech_usesRelaxedShortClipThresholdAndNoMinimumPad() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.4, peakLevel: 0.0049, hasPreviewText: false), .discardNoSpeech)
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.4, peakLevel: 0.009, hasPreviewText: false), .transcribe)

        let paddedSamples = paddedSamplesForFinalTranscription(makeSamples(duration: 0.4), rawDuration: 0.4)
        XCTAssertEqual(paddedSamples.count, 12_000)
        XCTAssertEqual(Double(paddedSamples.count) / AudioRecordingService.targetSampleRate, 0.75, accuracy: 0.0001)
    }

    func testFourHundredMsQuietClip_withPreviewText_transcribes() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.4, peakLevel: 0.0049, hasPreviewText: true), .transcribe)
    }

    func testEightHundredEightyFiveMsClip_withLowSpeechPeakStillTranscribes() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.885, peakLevel: 0.0069, hasPreviewText: false), .transcribe)
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
