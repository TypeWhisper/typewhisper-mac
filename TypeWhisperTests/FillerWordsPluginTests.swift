import Foundation
import TypeWhisperPluginSDK
import XCTest

final class FillerWordsPluginTests: XCTestCase {
    private final class MockEventBus: EventBusProtocol {
        @discardableResult
        func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID { UUID() }
        func unsubscribe(id: UUID) {}
    }

    private final class MockHostServices: HostServices, @unchecked Sendable {
        private var defaults: [String: Any]
        private var secrets: [String: String] = [:]

        let pluginDataDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        let eventBus: EventBusProtocol = MockEventBus()
        var activeAppBundleId: String?
        var activeAppName: String?
        var availableRuleNames: [String] = []

        init(defaults: [String: Any] = [:]) {
            self.defaults = defaults
        }

        func storeSecret(key: String, value: String) throws { secrets[key] = value }
        func loadSecret(key: String) -> String? { secrets[key] }
        func userDefault(forKey key: String) -> Any? { defaults[key] }
        func setUserDefault(_ value: Any?, forKey key: String) { defaults[key] = value }
        func notifyCapabilitiesChanged() {}
        func setStreamingDisplayActive(_ active: Bool) {}
    }

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

    func testActivationSeedsPluginScopedDefaultWordsAndSettingsView() {
        let host = MockHostServices()
        let plugin = FillerWordsPlugin()

        plugin.activate(host: host)

        XCTAssertNotNil(plugin.settingsView)
        XCTAssertEqual(
            host.userDefault(forKey: "words") as? String,
            FillerWordsPlugin.defaultFillerWords.joined(separator: "\n")
        )
    }

    func testActivationMigratesUnchangedLegacyDefaultsToGermanFillers() {
        let legacyWords = [
            "ah",
            "ahh",
            "hm",
            "hmm",
            "uh",
            "uhh",
            "um",
            "umm"
        ].joined(separator: "\n")
        let host = MockHostServices(defaults: ["words": legacyWords])
        let plugin = FillerWordsPlugin()

        plugin.activate(host: host)

        let storedWords = host.userDefault(forKey: "words") as? String
        XCTAssertTrue(storedWords?.contains("ähm") == true)
        XCTAssertTrue(storedWords?.contains("ehm") == true)
        XCTAssertEqual(host.userDefault(forKey: "wordsDefaultsVersion") as? Int, 2)
    }

    func testActivationMigratesLegacyDefaultsWithoutDroppingCustomWords() {
        let legacyWordsWithCustom = [
            "ah",
            "ahh",
            "hm",
            "hmm",
            "uh",
            "uhh",
            "um",
            "umm",
            "basically"
        ].joined(separator: "\n")
        let host = MockHostServices(defaults: ["words": legacyWordsWithCustom])
        let plugin = FillerWordsPlugin()

        plugin.activate(host: host)

        let storedWords = host.userDefault(forKey: "words") as? String
        XCTAssertTrue(storedWords?.contains("basically") == true)
        XCTAssertTrue(storedWords?.contains("ähm") == true)
        XCTAssertEqual(host.userDefault(forKey: "wordsDefaultsVersion") as? Int, 2)
    }

    func testProcessUsesPluginScopedCustomWords() async throws {
        let host = MockHostServices(defaults: ["words": "basically\nlike"])
        let plugin = FillerWordsPlugin()

        plugin.activate(host: host)

        let result = try await plugin.process(
            text: "basically hello um",
            context: PostProcessingContext()
        )

        XCTAssertEqual(result, "hello um")
    }

    func testCustomWordsMatchGermanUmlautsCaseInsensitively() async throws {
        let host = MockHostServices(defaults: ["words": "Ähm"])
        let plugin = FillerWordsPlugin()

        plugin.activate(host: host)

        let result = try await plugin.process(
            text: "ähm hallo",
            context: PostProcessingContext()
        )

        XCTAssertEqual(result, "hallo")
    }

    func testEmptyPluginScopedWordListDisablesRemoval() async throws {
        let host = MockHostServices(defaults: ["words": ""])
        let plugin = FillerWordsPlugin()

        plugin.activate(host: host)

        let result = try await plugin.process(
            text: "um hello",
            context: PostProcessingContext()
        )

        XCTAssertEqual(result, "um hello")
    }

    func testPreservesWordBoundariesAndExistingSpacing() {
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "umbrella"), "umbrella")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "summer humor"), "summer humor")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "hello  world"), "hello  world")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "\n\num hello"), "\n\nhello")
    }

    func testRemovesAdjacentPunctuation() {
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "Ähm, hallo"), "hallo")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "um, hello"), "hello")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "well, um, hello"), "well, hello")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "hello uh."), "hello")
    }

    func testDoesNotRemoveGermanPronounEr() {
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "er ist hier"), "er ist hier")
    }
}
