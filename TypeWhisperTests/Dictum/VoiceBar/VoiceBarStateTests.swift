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
        XCTAssertEqual(VoiceBarPresentation.countWords("明天下午三点，请准备。\n\n我们开会。"), 13)
        XCTAssertEqual(VoiceBarPresentation.countWords("Hello, world.\nSecond line"), 4)
    }
}
