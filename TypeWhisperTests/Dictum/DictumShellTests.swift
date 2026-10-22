import XCTest
import TypeWhisperPluginSDK
import Carbon
@testable import TypeWhisper

final class DictumShellTests: XCTestCase {
    func testSidebarOrderAndKeyboardShortcuts() {
        XCTAssertEqual(DictumPage.allCases, [.home, .history, .dictionary, .style, .general, .speech, .aiModels])
        XCTAssertEqual(DictumPage.allCases.map(\.shortcutCharacter), Array("1234567"))
        XCTAssertEqual(Set(DictumPage.allCases.map(\.shortcutCharacter)).count, 7)
        XCTAssertEqual(DictumPage.allCases.filter(\.isSettings), [.general, .speech, .aiModels])
    }

    func testReadySpeechReflectsAIConfiguration() {
        XCTAssertEqual(SidebarStatus.derive(speech: .ready(engine: "Qwen3-ASR"), ai: .ready), .ready(engine: "Qwen3-ASR"))
        XCTAssertEqual(SidebarStatus.derive(speech: .ready(engine: "WhisperKit"), ai: .unconfigured), .noAIProvider)
        XCTAssertEqual(SidebarStatus.derive(speech: .ready(engine: "WhisperKit"), ai: .usingBackup), .usingBackup)
    }

    func testSpeechFailureTakesPriorityOverAIState() {
        for ai in [SidebarStatus.AI.ready, .unconfigured, .usingBackup] {
            XCTAssertEqual(SidebarStatus.derive(speech: .missing, ai: ai), .noModel)
            XCTAssertEqual(SidebarStatus.derive(speech: .downloadFailed, ai: ai), .downloadFailed)
            XCTAssertEqual(SidebarStatus.derive(speech: .loadFailed, ai: ai), .loadFailed)
            XCTAssertEqual(SidebarStatus.derive(speech: .loading(engine: "Qwen3-ASR"), ai: ai), .loading(engine: "Qwen3-ASR"))
            XCTAssertEqual(SidebarStatus.derive(speech: .downloading(progress: 0.62), ai: ai), .downloading(progress: 0.62))
        }
    }

    func testDownloadProgressHandlesIndeterminateAndBounds() {
        XCTAssertEqual(SidebarStatus.derive(speech: .downloading(progress: nil), ai: .ready), .downloading(progress: nil))
        XCTAssertEqual(SidebarStatus.derive(speech: .downloading(progress: -0.2), ai: .ready), .downloading(progress: 0))
        XCTAssertEqual(SidebarStatus.derive(speech: .downloading(progress: 1.2), ai: .ready), .downloading(progress: 1))
        XCTAssertNil(SidebarStatus.downloading(progress: nil).caption)
        XCTAssertEqual(SidebarStatus.ready(engine: "Qwen3-ASR").caption, "Qwen3-ASR")
    }

    func testActivitySeparatesDownloadsFromPreparation() {
        XCTAssertEqual(SidebarStatus.Speech.current(
            activity: PluginSettingsActivity(message: "Downloading model", progress: 0.62),
            readinessError: .modelNotLoaded, hasMissingModel: true, engine: "WhisperKit"
        ), .downloading(progress: 0.62))
        XCTAssertEqual(SidebarStatus.Speech.current(
            activity: PluginSettingsActivity(message: "Preparing model"),
            readinessError: .modelNotLoaded, hasMissingModel: true, engine: "Qwen3-ASR"
        ), .downloading(progress: nil))
        for message in ["Preparing model", "Loading model", "Optimizing model"] {
            XCTAssertEqual(SidebarStatus.Speech.current(
                activity: PluginSettingsActivity(message: message),
                readinessError: nil, hasMissingModel: false, engine: "Qwen3-ASR"
            ), .loading(engine: "Qwen3-ASR"))
        }
    }

    func testActivityErrorUsesDownloadedModelReadiness() {
        let failure = PluginSettingsActivity(message: "Failed", isError: true)
        XCTAssertEqual(SidebarStatus.Speech.current(activity: failure, readinessError: .modelNotLoaded,
                                                   hasMissingModel: true, engine: "Qwen3-ASR"), .downloadFailed)
        XCTAssertEqual(SidebarStatus.Speech.current(activity: failure, readinessError: nil,
                                                   hasMissingModel: false, engine: "Qwen3-ASR"), .loadFailed)
        XCTAssertEqual(SidebarStatus.Speech.current(activity: nil, readinessError: .modelLoadFailed("Memory"),
                                                   hasMissingModel: false, engine: "Qwen3-ASR"), .loadFailed)
        XCTAssertEqual(SidebarStatus.Speech.current(activity: nil, readinessError: .modelDownloadFailed("Network"),
                                                   hasMissingModel: true, engine: "Qwen3-ASR"), .downloadFailed)
    }

    func testActivityWithoutWorkReflectsEngineReadiness() {
        XCTAssertEqual(SidebarStatus.Speech.current(activity: nil, readinessError: nil,
                                                   hasMissingModel: false, engine: "Qwen3-ASR"), .ready(engine: "Qwen3-ASR"))
        XCTAssertEqual(SidebarStatus.Speech.current(activity: nil, readinessError: .noEngineSelected,
                                                   hasMissingModel: true, engine: "Qwen3-ASR"), .missing)
        XCTAssertEqual(SidebarStatus.loading(engine: "Qwen3-ASR").caption, "Qwen3-ASR")
    }

    @MainActor func testLoginLaunchUsesTheOpenApplicationEvent() {
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(AppDelegate.isLoginItemLaunch(nil))
        XCTAssertFalse(AppDelegate.isLoginItemLaunch(event))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(AppDelegate.isLoginItemLaunch(event))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsServiceItem), forKeyword: keyAEPropData)
        XCTAssertFalse(AppDelegate.isLoginItemLaunch(event))
    }
}
