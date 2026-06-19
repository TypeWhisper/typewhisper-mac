import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import FillerWordsPlugin

final class FillerWordsPluginTests: XCTestCase {
    func testMetadataPlacesProcessorBeforePromptProcessing() {
        let plugin = FillerWordsPlugin()

        XCTAssertEqual(FillerWordsPlugin.pluginId, "com.typewhisper.filler-words")
        XCTAssertEqual(plugin.processorName, "Filler Words")
        XCTAssertLessThan(plugin.priority, 300)
    }

    func testRemovesBuiltInFillerWordsCaseInsensitively() async throws {
        let plugin = FillerWordsPlugin()

        let result = try await plugin.process(
            text: "Ähm, um uh hello?",
            context: PostProcessingContext()
        )

        XCTAssertEqual(result, "hello?")
    }

    func testRemovesBuiltInJapaneseFillerWordsAtPhraseBoundaries() async throws {
        let plugin = FillerWordsPlugin()

        let result = try await plugin.process(
            text: "えっと友達追加されたのは2月9日で、なんか様子を見たいです。まあ今日から開始してください。",
            context: PostProcessingContext()
        )

        XCTAssertEqual(result, "友達追加されたのは2月9日で、様子を見たいです。今日から開始してください。")
    }

    func testPreservesMeaningfulJapaneseConnectorsAndDemonstratives() {
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "あと最後に送信確認してください。"),
            "あと最後に送信確認してください。"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "そのまま送信してください。"),
            "そのまま送信してください。"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "あの人に確認してください。"),
            "あの人に確認してください。"
        )
    }

    @MainActor
    func testActivationSeedsPluginScopedDefaultWords() throws {
        let host = try PluginTestHostServices()
        let plugin = FillerWordsPlugin()

        plugin.activate(host: host)

        XCTAssertNotNil(plugin.settingsView)
        XCTAssertEqual(
            host.userDefault(forKey: "words") as? String,
            FillerWordsPlugin.defaultFillerWords.joined(separator: "\n")
        )
    }

    func testActivationMigratesLegacyDefaultsWithoutDroppingCustomWords() throws {
        let host = try PluginTestHostServices(defaults: [
            "words": [
                "ah",
                "ahh",
                "hm",
                "hmm",
                "uh",
                "uhh",
                "um",
                "umm",
                "basically",
            ].joined(separator: "\n")
        ])
        let plugin = FillerWordsPlugin()

        plugin.activate(host: host)

        let storedWords = host.userDefault(forKey: "words") as? String
        XCTAssertTrue(storedWords?.contains("basically") == true)
        XCTAssertTrue(storedWords?.contains("ähm") == true)
        XCTAssertTrue(storedWords?.contains("えっと") == true)
        XCTAssertEqual(host.userDefault(forKey: "wordsDefaultsVersion") as? Int, 3)
    }

    func testProcessUsesPluginScopedCustomWords() async throws {
        let host = try PluginTestHostServices(defaults: ["words": "basically\nlike"])
        let plugin = FillerWordsPlugin()

        plugin.activate(host: host)

        let result = try await plugin.process(
            text: "basically hello um",
            context: PostProcessingContext()
        )

        XCTAssertEqual(result, "hello um")
    }

    func testPreservesWordBoundariesAndExistingSpacing() {
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "umbrella"), "umbrella")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "summer humor"), "summer humor")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "hello  world"), "hello  world")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "\n\num hello"), "\n\nhello")
    }
}
