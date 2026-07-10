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

    func testOneHundredTwentyMsVeryQuietClip_transcribesByDefault() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.12, peakLevel: 0.0029, hasConfirmedText: false), .transcribe)
    }

    func testOneHundredTwentyMsVeryQuietClip_discardsWhenAggressivePolicyDisabled() {
        XCTAssertEqual(
            classifyShortSpeech(
                rawDuration: 0.12,
                peakLevel: 0.0029,
                hasConfirmedText: false,
                transcribeShortQuietClipsAggressively: false
            ),
            .discardNoSpeech
        )
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

    func testFourHundredMsVeryQuietClip_transcribesByDefaultAndPads() {
        XCTAssertEqual(classifyShortSpeech(rawDuration: 0.4, peakLevel: 0.0029, hasConfirmedText: false), .transcribe)
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

final class MicrophoneBoostProcessorTests: XCTestCase {
    func testDisabledBoostLeavesSamplesUnchanged() {
        let samples: [Float] = [0.01, -0.02, 0.03]

        let result = MicrophoneBoostProcessor.process(samples, enabled: false)

        XCTAssertEqual(result.samples, samples)
        XCTAssertEqual(result.gain, 1)
    }

    func testQuietSpeechIsBoostedTowardTargetRMS() {
        let samples = [Float](repeating: 0.01, count: 100)

        let result = MicrophoneBoostProcessor.process(samples, enabled: true)

        XCTAssertEqual(result.gain, 10, accuracy: 0.0001)
        XCTAssertEqual(result.outputRMS, MicrophoneBoostProcessor.targetRMS, accuracy: 0.0001)
        XCTAssertTrue(result.samples.allSatisfy { abs($0 - 0.1) < 0.0001 })
    }

    func testBoostIsCappedAtMaximumGain() {
        let samples = [Float](repeating: 0.001, count: 100)

        let result = MicrophoneBoostProcessor.process(samples, enabled: true)

        XCTAssertEqual(result.gain, MicrophoneBoostProcessor.maximumGain, accuracy: 0.0001)
        XCTAssertEqual(result.outputRMS, 0.02, accuracy: 0.0001)
    }

    func testNearSilenceIsNotBoosted() {
        let samples = [Float](repeating: 0.00005, count: 100)

        let result = MicrophoneBoostProcessor.process(samples, enabled: true)

        XCTAssertEqual(result.samples, samples)
        XCTAssertEqual(result.gain, 1)
    }

    func testBoostClampsSamplesToValidRange() {
        let samples = [Float(0.96)] + [Float](repeating: 0, count: 99)

        let result = MicrophoneBoostProcessor.process(samples, enabled: true)

        XCTAssertEqual(try XCTUnwrap(result.samples.first), 1, accuracy: 0.0001)
        XCTAssertTrue(result.samples.allSatisfy { $0 >= -1 && $0 <= 1 })
    }
}

final class DictationInsertionTextFormatterTests: XCTestCase {
    func testDoesNotAddTrailingSpaceToNonEmptyText() {
        XCTAssertEqual(DictationInsertionTextFormatter.textForInsertion("Hello"), "Hello")
    }

    func testLeavesExistingTrailingSpaceUntouched() {
        XCTAssertEqual(DictationInsertionTextFormatter.textForInsertion("Hello "), "Hello ")
    }

    func testLeavesExistingTrailingNewlineUntouched() {
        XCTAssertEqual(DictationInsertionTextFormatter.textForInsertion("Hello\n"), "Hello\n")
    }

    func testLeavesEmptyTextUntouched() {
        XCTAssertEqual(DictationInsertionTextFormatter.textForInsertion(""), "")
    }

    func testDisabledContextualInsertionDoesNotAddTrailingSpace() {
        let context = TextInsertionService.InsertionContext(
            value: "coffeemachine",
            selectedRange: NSRange(location: 6, length: 0),
            selectedText: nil,
            previousCharacter: "e",
            nextCharacter: "m"
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion(
                "Strong.",
                insertionContext: context,
                contextualInsertionEnabled: false
            ),
            "Strong."
        )
    }

    func testMissingContextDoesNotAddTrailingSpace() {
        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion("Strong."),
            "Strong."
        )
    }

    func testSmartInsertionAddsMissingLeadingAndTrailingSpacesBetweenWords() {
        let context = TextInsertionService.InsertionContext(
            value: "coffeemachine",
            selectedRange: NSRange(location: 6, length: 0),
            selectedText: nil,
            previousCharacter: "e",
            nextCharacter: "m"
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion("strong", insertionContext: context),
            " strong "
        )
    }

    func testSmartInsertionAvoidsDuplicateLeadingSpace() {
        let context = TextInsertionService.InsertionContext(
            value: "coffee machine",
            selectedRange: NSRange(location: 7, length: 0),
            selectedText: nil,
            previousCharacter: " ",
            nextCharacter: "m"
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion("strong", insertionContext: context),
            "strong "
        )
    }

    func testSmartInsertionDoesNotAddSpaceBeforePunctuation() {
        let context = TextInsertionService.InsertionContext(
            value: "Hello,",
            selectedRange: NSRange(location: 5, length: 0),
            selectedText: nil,
            previousCharacter: "o",
            nextCharacter: ","
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion("friend", insertionContext: context),
            " friend"
        )
    }

    func testSmartInsertionStripsFinalPeriodBeforeExistingComma() {
        let context = TextInsertionService.InsertionContext(
            value: "start, I will begin",
            selectedRange: NSRange(location: 5, length: 0),
            selectedText: nil,
            previousCharacter: "t",
            nextCharacter: ","
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion(
                "Dictation in the middle of a sentence before the comma.",
                insertionContext: context
            ),
            " dictation in the middle of a sentence before the comma"
        )
    }

    func testSmartInsertionStripsFinalPeriodBeforeExistingPeriod() {
        let context = TextInsertionService.InsertionContext(
            value: "dictating.",
            selectedRange: NSRange(location: 9, length: 0),
            selectedText: nil,
            previousCharacter: "g",
            nextCharacter: "."
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion("my first sentence.", insertionContext: context),
            " my first sentence"
        )
    }

    func testSmartInsertionDoesNotLowercaseAfterSentenceEndingPunctuation() {
        let context = TextInsertionService.InsertionContext(
            value: "Done.Next",
            selectedRange: NSRange(location: 5, length: 0),
            selectedText: nil,
            previousCharacter: ".",
            nextCharacter: "N"
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion("Another item", insertionContext: context),
            " Another item "
        )
    }

    func testSmartInsertionLowercasesTitlecaseFirstWordInMidSentence() {
        let context = TextInsertionService.InsertionContext(
            value: "The presentation will bemachine",
            selectedRange: NSRange(location: 24, length: 0),
            selectedText: nil,
            previousCharacter: "e",
            nextCharacter: "m"
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion("Presented tomorrow", insertionContext: context),
            " presented tomorrow "
        )
    }

    func testSmartInsertionLowercasesAndStripsPeriodAfterExistingWordSeparatedBySpace() {
        let context = TextInsertionService.InsertionContext(
            value: "will begin",
            selectedRange: NSRange(location: 5, length: 0),
            selectedText: nil,
            previousCharacter: " ",
            nextCharacter: "b"
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion("Immediately.", insertionContext: context),
            "immediately "
        )
    }

    func testSmartInsertionTrimsDictatedBoundaryWhitespaceBeforePunctuation() {
        let context = TextInsertionService.InsertionContext(
            value: "dictating.",
            selectedRange: NSRange(location: 9, length: 0),
            selectedText: nil,
            previousCharacter: "g",
            nextCharacter: "."
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion(" my first sentence ", insertionContext: context),
            " my first sentence"
        )
    }

    func testSmartInsertionPreservesAllCapsFirstWord() {
        let context = TextInsertionService.InsertionContext(
            value: "we use",
            selectedRange: NSRange(location: 6, length: 0),
            selectedText: nil,
            previousCharacter: "e",
            nextCharacter: nil
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion("NASA tools.", insertionContext: context),
            " NASA tools."
        )
    }

    func testSmartInsertionPreservesCamelCaseFirstWord() {
        let context = TextInsertionService.InsertionContext(
            value: "about",
            selectedRange: NSRange(location: 5, length: 0),
            selectedText: nil,
            previousCharacter: "t",
            nextCharacter: nil
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion("TypeWhisper", insertionContext: context),
            " TypeWhisper"
        )
    }

    func testSmartInsertionStripsSingleFinalPeriodBeforeExistingWord() {
        let context = TextInsertionService.InsertionContext(
            value: "coffeemachine",
            selectedRange: NSRange(location: 6, length: 0),
            selectedText: nil,
            previousCharacter: "e",
            nextCharacter: "m"
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion("Strong.", insertionContext: context),
            " strong "
        )
    }

    func testSmartInsertionPreservesQuestionPunctuation() {
        let context = TextInsertionService.InsertionContext(
            value: "coffeemachine",
            selectedRange: NSRange(location: 6, length: 0),
            selectedText: nil,
            previousCharacter: "e",
            nextCharacter: "m"
        )

        XCTAssertEqual(
            DictationInsertionTextFormatter.textForInsertion("Really?", insertionContext: context),
            " really? "
        )
    }
}
