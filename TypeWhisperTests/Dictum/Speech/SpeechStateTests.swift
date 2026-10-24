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
        XCTAssertNil(DictationModelNotice.resolve(isLocal: true, isReady: false, hasDownloadedModel: true, activity: nil))
    }

    func testMissingAndFailedDownloadsRemainDistinct() {
        XCTAssertEqual(DictationModelNotice.resolve(isLocal: true, isReady: false, hasDownloadedModel: false, activity: nil), .notDownloaded)
        XCTAssertEqual(DictationModelNotice.resolve(isLocal: true, isReady: false, hasDownloadedModel: false,
            activity: PluginSettingsActivity(message: "Connection lost", isError: true)), .failed(message: "Connection lost"))
    }

    func testDownloadedModelNeverBlocksDictationWhileLoadingOrAfterLoadFailure() {
        XCTAssertNil(DictationModelNotice.resolve(isLocal: true, isReady: false, hasDownloadedModel: true,
            activity: PluginSettingsActivity(message: "Preparing model")))
        XCTAssertNil(DictationModelNotice.resolve(isLocal: true, isReady: false, hasDownloadedModel: true,
            activity: PluginSettingsActivity(message: "Out of memory", isError: true)))
    }

    func testAnotherDownloadedPrecisionDoesNotMakeTheSelectedModelReady() {
        let engine = DownloadedModelsTestEngine(downloaded: ["6bit"], selected: "8bit")
        XCTAssertFalse(DictationModelNotice.hasDownloadedSelectedModel(engine))
        XCTAssertEqual(SidebarStatus.Speech.current(activity: nil, readinessError: nil,
            hasMissingModel: !DictationModelNotice.hasDownloadedSelectedModel(engine), engine: "Qwen3"), .missing)

        engine.selectModel("6bit")
        XCTAssertTrue(DictationModelNotice.hasDownloadedSelectedModel(engine))
        XCTAssertEqual(SidebarStatus.Speech.current(activity: nil, readinessError: nil,
            hasMissingModel: !DictationModelNotice.hasDownloadedSelectedModel(engine), engine: "Qwen3"), .ready(engine: "Qwen3"))
    }

    @MainActor
    func testFailedDownloadShowsDownloadedBytesInBothLanguages() {
        let engine = DownloadedModelsTestEngine(downloaded: [], selected: "8bit", completedBytes: 1_288_490_188)
        let size = ByteCountFormatter.string(fromByteCount: 1_288_490_188, countStyle: .file)
        XCTAssertEqual(SpeechDownloadProgress.interruptedCopy(engine: engine, locale: Locale(identifier: "zh-Hans")),
                       "网络中断，已下载 \(size)")
        XCTAssertEqual(SpeechDownloadProgress.interruptedCopy(engine: engine, locale: Locale(identifier: "en")),
                       "Connection lost, \(size) downloaded")
        XCTAssertEqual(SidebarStatus.Speech.current(activity: PluginSettingsActivity(message: "x", isError: true),
            readinessError: nil, hasMissingModel: true, engine: "Qwen3"), .downloadFailed)
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
