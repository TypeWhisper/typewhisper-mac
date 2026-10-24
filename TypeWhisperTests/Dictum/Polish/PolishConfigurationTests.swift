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
        let pluginId = "com.typewhisper.openai-compatible"
        let directory = try TestSupport.makeTemporaryDirectory()
        let previousManager = PluginManager.shared
        let previousBus = EventBus.shared
        let previousOverride = AppConstants.testAppSupportDirectoryOverride
        let pluginDefaultsPrefix = "plugin.\(pluginId)."
        let savedPluginDefaults = UserDefaults.standard.dictionaryRepresentation()
            .filter { $0.key.hasPrefix(pluginDefaultsPrefix) }
        // 插件的配置写在标准偏好设置里，密钥写在应用支持文件夹的密钥文件里，两处都在测试后还原。
        AppConstants.testAppSupportDirectoryOverride = directory
        PluginManager.shared = PluginManager(appSupportDirectory: directory)
        EventBus.shared = EventBus()
        defer {
            PluginManager.shared.unloadPlugin(pluginId, keepsSavedEngine: true)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(pluginDefaultsPrefix) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            for (key, value) in savedPluginDefaults { UserDefaults.standard.set(value, forKey: key) }
            PluginManager.shared = previousManager
            EventBus.shared = previousBus
            AppConstants.testAppSupportDirectoryOverride = previousOverride
            TestSupport.remove(directory)
        }
        let bundleURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL).appendingPathComponent("OpenAICompatiblePlugin.bundle")
        try PluginManager.shared.loadPlugin(at: bundleURL)
        XCTAssertNotNil(ProviderConfiguration.compatiblePlugin)

        let profile = try ProviderConfiguration.configure(["preset": "deepseek", "key": "sk-fixed-test-key-0000"])
        let profileID = try XCTUnwrap(profile["id"] as? String)
        XCTAssertEqual(profile["hasKey"] as? Bool, true)
        XCTAssertEqual(KeychainService.load(service: "\(pluginId).api-key.\(profileID)"), "sk-fixed-test-key-0000")

        let suite = "PolishConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let processing = PromptProcessingService(userDefaults: defaults)
        processing.addLLMFallback(providerId: profileID, modelId: "deepseek-v4-flash")
        processing.addLLMFallback(providerId: profileID, modelId: "deepseek-v4-pro")
        processing.addLLMFallback(providerId: "openai-compatible:qwen", modelId: "qwen-plus")
        let flash = try XCTUnwrap(processing.fallbackPriorityList.first { $0.modelId == "deepseek-v4-flash" })
        let pro = try XCTUnwrap(processing.fallbackPriorityList.first { $0.modelId == "deepseek-v4-pro" })

        ProviderConfiguration.removeFallback(flash, from: processing)
        XCTAssertEqual(processing.fallbackPriorityList.map(\.modelId), ["deepseek-v4-pro", "qwen-plus"])
        XCTAssertEqual(try ProviderConfiguration.configure(["id": profileID])["hasKey"] as? Bool, true)
        XCTAssertEqual(KeychainService.load(service: "\(pluginId).api-key.\(profileID)"), "sk-fixed-test-key-0000")

        ProviderConfiguration.removeFallback(pro, from: processing)
        XCTAssertEqual(processing.fallbackPriorityList.map(\.modelId), ["qwen-plus"])
        XCTAssertThrowsError(try ProviderConfiguration.configure(["id": profileID]))
        XCTAssertNil(KeychainService.load(service: "\(pluginId).api-key.\(profileID)"))
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
