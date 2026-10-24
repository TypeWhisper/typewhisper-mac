import XCTest
@testable import TypeWhisper

final class VoiceBarStateTests: XCTestCase {
    func testAllStatesAndModelNotices() {
        var input = VoiceBarState.Input()
        XCTAssertEqual(VoiceBarState.derive(input), .idle)
        input.activity = .preparing
        XCTAssertEqual(VoiceBarState.derive(input), .preparing)
        input.activity = .recording
        XCTAssertEqual(VoiceBarState.derive(input), .listening)
        input.confirmedText = "今天天气不错。"
        XCTAssertEqual(VoiceBarState.derive(input), .listeningWithText)
        input.translation = true
        XCTAssertEqual(VoiceBarState.derive(input), .translating)
        input.targetMenuOpen = true
        XCTAssertEqual(VoiceBarState.derive(input), .targetMenu)
        input.activity = .processing
        XCTAssertEqual(VoiceBarState.derive(input), .polishing(translating: true))
        input.translation = false
        XCTAssertEqual(VoiceBarState.derive(input), .polishing(translating: false))
        let outcomes: [(VoiceBarState.Input.Outcome, VoiceBarState)] = [
            (.inserted(7), .inserted(count: 7)), (.copied, .copied),
            (.recoveredError, .recoveredError), (.blockingError("Microphone unavailable"), .blockingError("Microphone unavailable")),
            (.noSpeech, .noSpeech), (.noAI, .noAI)
        ]
        for (outcome, expected) in outcomes {
            input.outcome = outcome
            XCTAssertEqual(VoiceBarState.derive(input), expected)
        }
        input.outcome = nil
        input.model = .downloading(0.62)
        XCTAssertEqual(VoiceBarState.derive(input), .downloading(0.62))
        input.model = .loading
        XCTAssertEqual(VoiceBarState.derive(input), .preparing)
        input.model = .notDownloaded
        XCTAssertEqual(VoiceBarState.derive(input), .notDownloaded)
        input.model = .failed("Download failed")
        XCTAssertEqual(VoiceBarState.derive(input), .modelFailed("Download failed"))
        input.model = nil
        input.activity = .recording
        input.duration = 498
        XCTAssertEqual(VoiceBarState.derive(input), .countdown(seconds: 42))
        input.duration = 541
        XCTAssertEqual(VoiceBarState.derive(input), .countdown(seconds: 0))
        input.cancellationRemaining = 1.5
        XCTAssertEqual(VoiceBarState.derive(input), .cancelled(remaining: 0.5))
        input.cancellationRemaining = 0
        input.activity = .idle
        XCTAssertEqual(VoiceBarState.derive(input), .idle)
    }

    @MainActor
    func testRecordingTextSplitsConfirmedPrefixFromTentativeTail() {
        let preview = StreamingHandler.Preview.comparing(previous: "明天下午三点。", current: "明天下午三点。地点不变。")
        let recording = VoiceBarPresentation.transcriptParts(recording: true, partialText: "明天下午三点。地点不变。", preview: preview)
        XCTAssertEqual(recording.confirmed, "明天下午三点。")
        XCTAssertEqual(recording.tentative, "地点不变。")
        let polishing = VoiceBarPresentation.transcriptParts(recording: false, partialText: "明天下午三点。地点不变。", preview: preview)
        XCTAssertEqual(polishing.confirmed, "明天下午三点。地点不变。")
        XCTAssertEqual(polishing.tentative, "")
    }

    @MainActor
    func testInsertedCountIgnoresLineBreaksAndPunctuation() {
        XCTAssertEqual(DictumWordCount.count("明天下午三点，请准备。\n\n我们开会。"), 13)
        XCTAssertEqual(DictumWordCount.count("Hello, world.\nSecond line"), 4)
    }

    @MainActor
    func testFirstPartialWithEmptyPrefixShowsTranscriptAndSizesFromCombinedText() {
        let presentation = VoiceBarPresentation()
        presentation.setStateForTesting(.listeningWithText)
        let preview = StreamingHandler.Preview.comparing(previous: "", current: "明天下午三点")
        presentation.updateTranscript(recording: true, partialText: "明天下午三点", preview: preview)
        XCTAssertEqual(presentation.text, "")
        XCTAssertEqual(presentation.tentativeText, "明天下午三点")
        XCTAssertTrue(presentation.hasTranscript)
        XCTAssertEqual(presentation.contentSize.width, 460)
        XCTAssertEqual(presentation.contentSize.height, 82)
    }

    @MainActor
    func testWrappedTentativeTailGrowsTheBar() {
        let presentation = VoiceBarPresentation()
        presentation.setStateForTesting(.listeningWithText)
        presentation.text = "今天"
        presentation.tentativeText = String(repeating: "明天下午三点开会地点不变。", count: 6)
        XCTAssertEqual(presentation.contentSize.height, 126)
    }

    func testPreparingShowsOnlyAfterContinuousDelay() {
        var debounce = PreparingDebounce()
        let start = Date()
        XCTAssertNil(debounce.update(preparing: true, now: start))
        XCTAssertNil(debounce.update(preparing: true, now: start.addingTimeInterval(0.1)))
        XCTAssertEqual(debounce.update(preparing: true, now: start.addingTimeInterval(0.16)), true)
    }

    func testBriefReadyBlipDoesNotLeavePreparing() {
        var debounce = PreparingDebounce()
        let start = Date()
        _ = debounce.update(preparing: true, now: start)
        XCTAssertEqual(debounce.update(preparing: true, now: start.addingTimeInterval(0.2)), true)
        XCTAssertEqual(debounce.update(preparing: false, now: start.addingTimeInterval(0.25)), true)
        XCTAssertEqual(debounce.update(preparing: true, now: start.addingTimeInterval(0.3)), true)
        XCTAssertEqual(debounce.update(preparing: false, now: start.addingTimeInterval(0.35)), true)
        XCTAssertEqual(debounce.update(preparing: false, now: start.addingTimeInterval(0.52)), false)
    }

    func testBriefPreparingBlipDoesNotLeaveListening() {
        var debounce = PreparingDebounce()
        let start = Date()
        XCTAssertEqual(debounce.update(preparing: false, now: start), false)
        XCTAssertEqual(debounce.update(preparing: true, now: start.addingTimeInterval(0.05)), false)
        XCTAssertEqual(debounce.update(preparing: false, now: start.addingTimeInterval(0.1)), false)
        XCTAssertEqual(debounce.update(preparing: true, now: start.addingTimeInterval(0.2)), false)
        XCTAssertEqual(debounce.update(preparing: true, now: start.addingTimeInterval(0.4)), true)
    }
}
