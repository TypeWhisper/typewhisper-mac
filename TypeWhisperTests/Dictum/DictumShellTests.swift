import XCTest
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
            XCTAssertEqual(SidebarStatus.derive(speech: .failed, ai: ai), .downloadFailed)
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
}
