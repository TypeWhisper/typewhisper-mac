import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class WhisperKitPluginLifecycleTests: XCTestCase {
    private final class MockEventBus: EventBusProtocol {
        @discardableResult
        func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID { UUID() }
        func unsubscribe(id: UUID) {}
    }

    private final class MockHostServices: HostServices, @unchecked Sendable {
        private var defaults: [String: Any]
        private var secrets: [String: String] = [:]

        let pluginDataDirectory: URL
        let eventBus: EventBusProtocol = MockEventBus()
        var activeAppBundleId: String?
        var activeAppName: String?
        var availableRuleNames: [String] = []
        private(set) var capabilitiesChangedCount = 0

        init(pluginDataDirectory: URL, defaults: [String: Any] = [:]) {
            self.pluginDataDirectory = pluginDataDirectory
            self.defaults = defaults
        }

        func storeSecret(key: String, value: String) throws { secrets[key] = value }
        func loadSecret(key: String) -> String? { secrets[key] }
        func userDefault(forKey key: String) -> Any? { defaults[key] }
        func setUserDefault(_ value: Any?, forKey key: String) { defaults[key] = value }
        func notifyCapabilitiesChanged() { capabilitiesChangedCount += 1 }
        func setStreamingDisplayActive(_ active: Bool) {}
    }

    private func makeHost(defaults: [String: Any] = [:]) throws -> MockHostServices {
        let pluginDataDirectory = try TestSupport.makeTemporaryDirectory(prefix: "WhisperKitLifecycleTests")
        return MockHostServices(pluginDataDirectory: pluginDataDirectory, defaults: defaults)
    }

    func testActivationPromotesPersistedLoadedModelToSelectedModelWhenSelectionMissing() async throws {
        let host = try makeHost(defaults: ["loadedModel": "openai_whisper-tiny"])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "openai_whisper-tiny")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "openai_whisper-tiny")

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "openai_whisper-tiny")
        XCTAssertEqual(host.capabilitiesChangedCount, 0)
    }

    func testUnloadWithoutClearingPersistenceKeepsLoadedModelMarker() throws {
        let host = try makeHost(defaults: [
            "selectedModel": "openai_whisper-tiny",
            "loadedModel": "openai_whisper-tiny",
        ])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        plugin.unloadModel(clearPersistence: false)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "openai_whisper-tiny")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "openai_whisper-tiny")
    }

    func testUnloadClearingPersistenceRemovesLoadedModelMarker() throws {
        let host = try makeHost(defaults: [
            "selectedModel": "openai_whisper-tiny",
            "loadedModel": "openai_whisper-tiny",
        ])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        plugin.unloadModel(clearPersistence: true)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "openai_whisper-tiny")
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
    }

    func testActivationDoesNotMarkPluginConfiguredBeforeRestoreSucceeds() async throws {
        let host = try makeHost(defaults: [
            "selectedModel": "openai_whisper-tiny",
            "loadedModel": "openai_whisper-tiny",
        ])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.isConfigured)

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "openai_whisper-tiny")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "openai_whisper-tiny")
    }
}
