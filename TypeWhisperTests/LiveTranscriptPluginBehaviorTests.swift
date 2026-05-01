import XCTest
import TypeWhisperPluginSDK

@MainActor
final class LiveTranscriptPluginBehaviorTests: XCTestCase {
    private final class MockEventBus: EventBusProtocol, @unchecked Sendable {
        private var handlers: [UUID: @Sendable (TypeWhisperEvent) async -> Void] = [:]

        @discardableResult
        func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID {
            let id = UUID()
            handlers[id] = handler
            return id
        }

        func unsubscribe(id: UUID) {
            handlers.removeValue(forKey: id)
        }
    }

    private final class MockHostServices: HostServices, @unchecked Sendable {
        private var defaults: [String: Any]

        let pluginDataDirectory: URL
        let eventBus: EventBusProtocol = MockEventBus()
        var activeAppBundleId: String?
        var activeAppName: String?
        var availableRuleNames: [String] = []
        private(set) var streamingDisplayActiveValues: [Bool] = []

        init(defaults: [String: Any] = [:]) throws {
            self.defaults = defaults
            pluginDataDirectory = try TestSupport.makeTemporaryDirectory(prefix: "LiveTranscriptPlugin")
        }

        deinit {
            TestSupport.remove(pluginDataDirectory)
        }

        func storeSecret(key: String, value: String) throws {}
        func loadSecret(key: String) -> String? { nil }
        func userDefault(forKey key: String) -> Any? { defaults[key] }
        func setUserDefault(_ value: Any?, forKey key: String) { defaults[key] = value }
        func notifyCapabilitiesChanged() {}
        func setStreamingDisplayActive(_ active: Bool) {
            streamingDisplayActiveValues.append(active)
        }
    }

    func testAutoOpenDefaultsToDisabledWhenUnset() throws {
        let host = try MockHostServices()
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertNil(host.userDefault(forKey: "autoOpen"))
        XCTAssertEqual(host.streamingDisplayActiveValues, [])
    }

    func testStoredAutoOpenTrueIsPreservedOnActivation() throws {
        let host = try MockHostServices(defaults: ["autoOpen": true])
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertEqual(host.streamingDisplayActiveValues, [true])
    }

    func testActivationWithDefaultSettingsDoesNotRegisterStreamingDisplay() throws {
        let host = try MockHostServices()
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertTrue(host.streamingDisplayActiveValues.isEmpty)
    }

    func testEnablingAutoOpenRegistersStreamingDisplayExactlyOnce() throws {
        let host = try MockHostServices()
        let plugin = LiveTranscriptPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        plugin.updateAutoOpenPreference(true)
        plugin.updateAutoOpenPreference(true)

        XCTAssertEqual(host.userDefault(forKey: "autoOpen") as? Bool, true)
        XCTAssertEqual(host.streamingDisplayActiveValues, [true])
    }

    func testDeactivationUnregistersActiveStreamingDisplay() throws {
        let host = try MockHostServices()
        let plugin = LiveTranscriptPlugin()
        plugin.activate(host: host)

        plugin.updateAutoOpenPreference(true)
        plugin.deactivate()

        XCTAssertEqual(host.streamingDisplayActiveValues, [true, false])
    }
}
