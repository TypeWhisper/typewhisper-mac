import XCTest
@testable import TypeWhisperPluginSDK

final class HostManagedPolicyTests: XCTestCase {
    private struct SilentEventBus: EventBusProtocol {
        func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID { UUID() }
        func unsubscribe(id: UUID) {}
    }

    private struct PlainHost: HostServices {
        func storeSecret(key: String, value: String) throws {}
        func loadSecret(key: String) -> String? { nil }
        func userDefault(forKey: String) -> Any? { nil }
        func setUserDefault(_ value: Any?, forKey: String) {}
        var pluginDataDirectory: URL { FileManager.default.temporaryDirectory }
        var activeAppBundleId: String? { nil }
        var activeAppName: String? { nil }
        var eventBus: EventBusProtocol { SilentEventBus() }
        var availableRuleNames: [String] { [] }
        func notifyCapabilitiesChanged() {}
        func setStreamingDisplayActive(_ active: Bool) {}
    }

    private struct ManagedHost: HostServices, HostManagedPolicyProviding {
        let modelDownloadRefusal: String?

        func storeSecret(key: String, value: String) throws {}
        func loadSecret(key: String) -> String? { nil }
        func userDefault(forKey: String) -> Any? { nil }
        func setUserDefault(_ value: Any?, forKey: String) {}
        var pluginDataDirectory: URL { FileManager.default.temporaryDirectory }
        var activeAppBundleId: String? { nil }
        var activeAppName: String? { nil }
        var eventBus: EventBusProtocol { SilentEventBus() }
        var availableRuleNames: [String] { [] }
        func notifyCapabilitiesChanged() {}
        func setStreamingDisplayActive(_ active: Bool) {}
    }

    func testHostsWithoutManagedSettingsAllowDownloads() {
        let host: any HostServices = PlainHost()

        XCTAssertNil(host.modelDownloadRefusal)
        XCTAssertNoThrow(try host.requireModelDownloadAllowed())
    }

    func testManagedHostRefusesWithItsLocalizedReason() {
        let reason = "Your organization does not allow model downloads."
        let host: any HostServices = ManagedHost(modelDownloadRefusal: reason)

        XCTAssertEqual(host.modelDownloadRefusal, reason)
        XCTAssertThrowsError(try host.requireModelDownloadAllowed()) { error in
            XCTAssertEqual(error as? PluginModelDownloadRefusedError, PluginModelDownloadRefusedError(reason: reason))
            XCTAssertEqual(error.localizedDescription, reason)
        }

        let allowing: any HostServices = ManagedHost(modelDownloadRefusal: nil)
        XCTAssertNoThrow(try allowing.requireModelDownloadAllowed())
    }
}
