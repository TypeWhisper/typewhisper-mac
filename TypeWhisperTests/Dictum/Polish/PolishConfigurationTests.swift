import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class PolishConfigurationTests: XCTestCase {
    func testFreshInstallHasNoProviderAndStandardStrength() throws {
        let suite = "PolishConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let processing = PromptProcessingService(userDefaults: defaults)
        XCTAssertTrue(processing.fallbackPriorityList.isEmpty)
        XCTAssertFalse(processing.hasConfiguredPolishProvider)
        let styles = StyleStore(defaults: defaults)
        XCTAssertEqual(styles.level, .standard)
        styles.level = .light
        XCTAssertEqual(defaults.string(forKey: "dictum.polishLevel"), "light")
        styles.global.signOff = "小林"
        let restored = StyleStore(defaults: defaults)
        XCTAssertEqual(restored.level, .light)
        XCTAssertEqual(restored.global.signOff, "小林")
        XCTAssertEqual(restored.apps, AppStyle.defaults)
    }

    func testConnectionErrorsHaveDistinctUIStates() {
        XCTAssertEqual(ProviderConfiguration.connectionErrorKey(PluginChatError.invalidApiKey), "provider.error.401")
        XCTAssertEqual(ProviderConfiguration.connectionErrorKey(PluginChatError.rateLimited), "provider.error.429")
        XCTAssertEqual(ProviderConfiguration.connectionErrorKey(PluginChatError.apiError("HTTP 402")), "provider.error.402")
        XCTAssertEqual(ProviderConfiguration.connectionErrorKey(URLError(.timedOut)), "provider.error.network")
    }

    func testRemovingOneOfTwoModelRowsKeepsSharedProfile() throws {
        let suite = "PolishConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let processing = PromptProcessingService(userDefaults: defaults)
        processing.addLLMFallback(providerId: "openai-compatible:deepseek", modelId: "deepseek-v4-flash")
        processing.addLLMFallback(providerId: "openai-compatible:deepseek", modelId: "deepseek-v4-pro")
        processing.addLLMFallback(providerId: "openai-compatible:qwen", modelId: "qwen-plus")
        let flash = try XCTUnwrap(processing.fallbackPriorityList.first { $0.modelId == "deepseek-v4-flash" })
        let pro = try XCTUnwrap(processing.fallbackPriorityList.first { $0.modelId == "deepseek-v4-pro" })
        var removedProfiles: [String] = []

        ProviderConfiguration.removeFallback(flash, from: processing) { removedProfiles.append($0) }
        XCTAssertEqual(processing.fallbackPriorityList.map(\.modelId), ["deepseek-v4-pro", "qwen-plus"])
        XCTAssertEqual(removedProfiles, [])

        ProviderConfiguration.removeFallback(pro, from: processing) { removedProfiles.append($0) }
        XCTAssertEqual(processing.fallbackPriorityList.map(\.modelId), ["qwen-plus"])
        XCTAssertEqual(removedProfiles, ["openai-compatible:deepseek"])
    }

    func testStrengthTracksExternalAppStorageWrites() async throws {
        let suite = "PolishConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let styles = StyleStore(defaults: defaults)
        defaults.set("rewrite", forKey: "dictum.polishLevel")
        for _ in 0..<20 where styles.level != .rewrite {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(styles.level, .rewrite)
    }
}
