import XCTest
import AppKit
import ApplicationServices
@testable import TypeWhisper

@MainActor
final class PolishRetryTests: XCTestCase {
    func testFailureClearsWhenNextRecordingStarts() throws {
        let (model, directory) = try makeModel()
        defer { TestSupport.remove(directory) }
        model.recordPolishFailure(reason: "网络不可用", text: "会议四点开始。", handler: { $0 }, snapshot: nil)
        XCTAssertEqual(model.polishFailure, "网络不可用")
        model.state = .recording
        XCTAssertNil(model.polishFailure)
        model.state = .idle
    }

    func testRetryUsesSameTextAndCopiesWhenTargetCannotBeVerified() async throws {
        let (model, directory) = try makeModel()
        defer { TestSupport.remove(directory) }
        let previous = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let previous { NSPasteboard.general.setString(previous, forType: .string) }
        }
        let completed = expectation(description: "同一段原文重新润色")
        model.recordPolishFailure(reason: "请求超时", text: "嗯，会议四点开始。", handler: { text in
            XCTAssertEqual(text, "嗯，会议四点开始。")
            completed.fulfill()
            return "会议四点开始。"
        }, snapshot: nil)
        model.retryPolish()
        await fulfillment(of: [completed], timeout: 2)
        for _ in 0..<20 where model.polishFailure != nil { await Task.yield() }
        XCTAssertNil(model.polishFailure)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "会议四点开始。")
        XCTAssertEqual(model.actionFeedbackMessage, String(localized: "polish.retry.copied", table: "DictumStyle"))
        model.dismissActionFeedback()
    }

    func testRetryReplacesOnlyVerifiedOriginalRange() async throws {
        let insertion = TextInsertionService()
        let element = AXUIElementCreateApplication(1234)
        var value = "备注：嗯，会议四点开始。"
        let raw = "嗯，会议四点开始。"
        var selection = NSRange(location: (value as NSString).length, length: 0)
        let original = value
        insertion.accessibilityGrantedOverride = true
        insertion.captureActiveAppOverride = { (nil, "com.apple.TextEdit", nil) }
        insertion.focusedTextElementOverride = { element }
        insertion.focusedTextStateOverride = { _ in (value: value, selectedText: nil, selectedRange: selection) }
        insertion.setSelectedRangeOverride = { _, range in selection = range; return true }
        insertion.insertTextAtOverride = { _, text in
            value = (value as NSString).replacingCharacters(in: selection, with: text)
            selection = NSRange(location: selection.location + (text as NSString).length, length: 0)
            return true
        }
        let (model, directory) = try makeModel(insertion: insertion)
        defer { TestSupport.remove(directory) }
        let completed = expectation(description: "重试完成")
        model.recordPolishFailure(reason: "请求超时", text: raw, handler: { _ in
            completed.fulfill()
            return "会议四点开始。"
        }, snapshot: .init(rawTranscript: raw, insertedText: raw, transcriptionID: UUID(), timestamp: Date(),
                           applicationBundleIdentifier: "com.apple.TextEdit", element: element,
                           caretLocation: selection.location, value: original))
        model.retryPolish()
        await fulfillment(of: [completed], timeout: 2)
        for _ in 0..<20 where model.polishFailure != nil { await Task.yield() }
        XCTAssertNil(model.polishFailure)
        XCTAssertEqual(value, "备注：会议四点开始。")
        model.dismissActionFeedback()
    }

    func testFailedRetryKeepsFailureAvailable() async throws {
        let (model, directory) = try makeModel()
        defer { TestSupport.remove(directory) }
        let completed = expectation(description: "重试失败")
        model.recordPolishFailure(reason: "首次失败", text: "会议四点开始。", handler: { _ in
            completed.fulfill()
            throw URLError(.timedOut)
        }, snapshot: nil)
        model.retryPolish()
        await fulfillment(of: [completed], timeout: 2)
        for _ in 0..<20 where model.polishFailure == "首次失败" { await Task.yield() }
        XCTAssertEqual(model.polishFailure, URLError(.timedOut).localizedDescription)
    }

    private func makeModel(insertion: TextInsertionService = TextInsertionService()) throws -> (DictationViewModel, URL) {
        let directory = try TestSupport.makeTemporaryDirectory()
        let manager = ModelManagerService()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let punctuation = DictationPunctuationProfileStore(defaults: defaults, storageKey: "punctuation")
        let model = DictationViewModel(
            audioRecordingService: AudioRecordingService(), textInsertionService: insertion,
            hotkeyService: HotkeyService(), modelManager: manager,
            settingsViewModel: SettingsViewModel(modelManager: manager),
            historyService: HistoryService(appSupportDirectory: directory), recentTranscriptionStore: RecentTranscriptionStore(),
            profileService: ProfileService(appSupportDirectory: directory), workflowService: WorkflowService(appSupportDirectory: directory),
            translationService: nil, audioDuckingService: AudioDuckingService(),
            dictionaryService: DictionaryService(appSupportDirectory: directory), snippetService: SnippetService(appSupportDirectory: directory),
            soundService: SoundService(), audioDeviceService: AudioDeviceService(initialInputDevices: [], monitorDeviceChanges: false, probeCompatibilities: false),
            promptActionService: PromptActionService(appSupportDirectory: directory), promptProcessingService: PromptProcessingService(userDefaults: defaults),
            appFormatterService: AppFormatterService(), punctuationStrategyResolver: PunctuationStrategyResolver(profileStore: punctuation),
            speechPunctuationService: SpeechPunctuationService(rulesLoader: PunctuationRulesLoader()),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(), errorLogService: ErrorLogService(appSupportDirectory: directory),
            mediaPlaybackService: MediaPlaybackService(startListening: false))
        return (model, directory)
    }
}
