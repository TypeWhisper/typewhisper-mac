import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class SpeechStateTests: XCTestCase {
    func testLocalDownloadNoticePreservesProgressAndClampsInvalidValues() {
        XCTAssertEqual(DictationModelNotice.resolve(isLocal: true, isReady: false, hasDownloadedModel: false,
            activity: PluginSettingsActivity(message: "Preparing model", progress: 0.62)), .downloading(progress: 0.62))
        XCTAssertEqual(DictationModelNotice.resolve(isLocal: true, isReady: false, hasDownloadedModel: false,
            activity: PluginSettingsActivity(message: "Preparing model", progress: 1.2)), .downloading(progress: 1))
        XCTAssertEqual(DictationModelNotice.resolve(isLocal: true, isReady: false, hasDownloadedModel: false,
            activity: PluginSettingsActivity(message: "Preparing model", progress: .nan)), .downloading(progress: nil))
    }

    func testReadyAndCloudEnginesDoNotProduceLocalModelNotice() {
        XCTAssertNil(DictationModelNotice.resolve(isLocal: true, isReady: true, hasDownloadedModel: true, activity: nil))
        XCTAssertNil(DictationModelNotice.resolve(isLocal: false, isReady: false, hasDownloadedModel: false, activity: nil))
    }

    func testMissingLoadingAndFailedModelsRemainDistinct() {
        XCTAssertEqual(DictationModelNotice.resolve(isLocal: true, isReady: false, hasDownloadedModel: false, activity: nil), .notDownloaded)
        XCTAssertEqual(DictationModelNotice.resolve(isLocal: true, isReady: false, hasDownloadedModel: true,
            activity: PluginSettingsActivity(message: "Preparing model")), .loading)
        XCTAssertEqual(DictationModelNotice.resolve(isLocal: true, isReady: false, hasDownloadedModel: false,
            activity: PluginSettingsActivity(message: "Connection lost", isError: true)), .failed(message: "Connection lost"))
    }

    func testPreviewConfirmsOnlyTheSharedPrefixIncludingChineseAndCorrections() {
        XCTAssertEqual(StreamingHandler.Preview.comparing(previous: "", current: "明天下午"),
                       .init(confirmedPrefix: "", tentativeTail: "明天下午"))
        XCTAssertEqual(StreamingHandler.Preview.comparing(previous: "明天下午三点", current: "明天下午四点"),
                       .init(confirmedPrefix: "明天下午", tentativeTail: "四点"))
        XCTAssertEqual(StreamingHandler.Preview.comparing(previous: "Please move", current: "Please move the meeting."),
                       .init(confirmedPrefix: "Please move", tentativeTail: " the meeting."))
    }
}
