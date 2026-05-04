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
        XCTAssertEqual(host.userDefault(forKey: "wordsDefaultsVersion") as? Int, 2)
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
