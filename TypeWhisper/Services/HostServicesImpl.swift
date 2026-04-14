import AppKit
import Foundation
import TypeWhisperPluginSDK

final class HostServicesImpl: HostServices, @unchecked Sendable {
    let pluginId: String
    let pluginDataDirectory: URL
    let eventBus: EventBusProtocol
    private let ruleNamesProvider: () -> [String]

    init(pluginId: String, eventBus: EventBusProtocol, ruleNamesProvider: @escaping () -> [String]) {
        self.pluginId = pluginId
        self.eventBus = eventBus
        self.ruleNamesProvider = ruleNamesProvider

        self.pluginDataDirectory = AppConstants.appSupportDirectory
            .appendingPathComponent("PluginData", isDirectory: true)
            .appendingPathComponent(pluginId, isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: pluginDataDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Keychain

    func storeSecret(key: String, value: String) throws {
        let scopedService = "\(pluginId).\(key)"
        if value.isEmpty {
            try KeychainService.delete(service: scopedService)
        } else {
            try KeychainService.save(key: value, service: scopedService)
        }
    }

    func loadSecret(key: String) -> String? {
        let scopedService = "\(pluginId).\(key)"
        return KeychainService.load(service: scopedService)
    }

    // MARK: - UserDefaults (plugin-scoped)

    func userDefault(forKey key: String) -> Any? {
        UserDefaults.standard.object(forKey: "plugin.\(pluginId).\(key)")
    }

    func setUserDefault(_ value: Any?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: "plugin.\(pluginId).\(key)")
    }

    // MARK: - App Context

    var activeAppBundleId: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    var activeAppName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    // MARK: - Rules

    var availableRuleNames: [String] {
        ruleNamesProvider()
    }

    // MARK: - Capabilities

    func notifyCapabilitiesChanged() {
        DispatchQueue.main.async {
            PluginManager.shared?.notifyPluginStateChanged()
        }
    }

    // MARK: - Streaming Display

    func setStreamingDisplayActive(_ active: Bool) {
        DispatchQueue.main.async {
            DictationViewModel._shared?.updateExternalStreamingDisplay(active: active)
        }
    }
}
