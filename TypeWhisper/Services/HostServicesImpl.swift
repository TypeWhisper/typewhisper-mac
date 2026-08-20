import AppKit
import Foundation
import TypeWhisperPluginSDK

private enum PassiveLoadedModelRestoreContext {
    @TaskLocal static var suppressLoadedModelDefault = false

    private static let synchronousActivationAccessKey = "com.typewhisper.host.loadedModel.synchronousActivationAccess"

    static var allowsLoadedModelDefaultInCurrentCallStack: Bool {
        Thread.current.threadDictionary[synchronousActivationAccessKey] as? Bool == true
    }

    static func withSynchronousLoadedModelDefaultAccess(_ body: () -> Void) {
        let threadDictionary = Thread.current.threadDictionary
        let previousValue = threadDictionary[synchronousActivationAccessKey]
        threadDictionary[synchronousActivationAccessKey] = true
        defer {
            if let previousValue {
                threadDictionary[synchronousActivationAccessKey] = previousValue
            } else {
                threadDictionary.removeObject(forKey: synchronousActivationAccessKey)
            }
        }

        body()
    }
}

final class HostServicesImpl: HostServices, HostModelLifecyclePolicyProviding, @unchecked Sendable {
    let pluginId: String
    let pluginDataDirectory: URL
    let eventBus: EventBusProtocol
    private let ruleNamesProvider: @MainActor () -> [String]
    private let workflowProvider: @MainActor () -> [PluginWorkflowInfo]

    init(
        pluginId: String,
        eventBus: EventBusProtocol,
        ruleNamesProvider: @escaping @MainActor () -> [String],
        workflowProvider: @escaping @MainActor () -> [PluginWorkflowInfo] = { [] }
    ) {
        self.pluginId = pluginId
        self.eventBus = eventBus
        self.ruleNamesProvider = ruleNamesProvider
        self.workflowProvider = workflowProvider

        self.pluginDataDirectory = AppConstants.appSupportDirectory
            .appendingPathComponent("PluginData", isDirectory: true)
            .appendingPathComponent(pluginId, isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: pluginDataDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Keychain

    func storeSecret(key: String, value: String) throws {
        if AppConstants.isScreenshotAutomation {
            return
        }

        let scopedService = "\(pluginId).\(key)"
        if value.isEmpty {
            try KeychainService.delete(service: scopedService)
        } else {
            try KeychainService.save(key: value, service: scopedService)
        }
    }

    func loadSecret(key: String) -> String? {
        if AppConstants.isScreenshotAutomation {
            return ScreenshotPluginFixture.secret(
                selectedPluginId: AppConstants.screenshotPluginId,
                pluginId: pluginId,
                key: key
            )
        }

        let scopedService = "\(pluginId).\(key)"
        return KeychainService.load(service: scopedService)
    }

    // MARK: - UserDefaults (plugin-scoped)

    func userDefault(forKey key: String) -> Any? {
        if key == "loadedModel",
           PassiveLoadedModelRestoreContext.suppressLoadedModelDefault,
           !PassiveLoadedModelRestoreContext.allowsLoadedModelDefaultInCurrentCallStack,
           !shouldRestoreLoadedModelsPassively {
            return nil
        }

        return UserDefaults.standard.object(forKey: "plugin.\(pluginId).\(key)")
    }

    func setUserDefault(_ value: Any?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: "plugin.\(pluginId).\(key)")
    }

    // MARK: - Model Lifecycle Policy

    var shouldRestoreLoadedModelsPassively: Bool {
        ModelAutoUnloadPolicy.shouldRestoreLoadedModelsPassively()
    }

    func performPluginActivation(
        suppressPassiveLoadedModelRestore: Bool,
        _ body: @escaping () -> Void
    ) {
        let activation = {
            PassiveLoadedModelRestoreContext.withSynchronousLoadedModelDefaultAccess(body)
        }

        guard suppressPassiveLoadedModelRestore else {
            activation()
            return
        }

        PassiveLoadedModelRestoreContext.$suppressLoadedModelDefault.withValue(true) {
            activation()
        }
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
        readMainActor(ruleNamesProvider)
    }

    var availableWorkflows: [PluginWorkflowInfo] {
        readMainActor(workflowProvider)
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

    private func readMainActor<Value: Sendable>(_ body: @escaping @MainActor () -> Value) -> Value {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                body()
            }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                body()
            }
        }
    }
}

enum ScreenshotPluginFixture {
    static func secret(selectedPluginId: String?, pluginId: String, key: String) -> String? {
        guard selectedPluginId == pluginId else { return nil }

        switch key {
        case "api-key":
            return "tw-screenshot-api-key"
        case let value where value.hasPrefix("api-key."):
            return "tw-screenshot-api-key"
        case "hf-token":
            return "hf_tw_screenshot_fixture"
        case "authorization-key":
            return "tw-screenshot-authorization-key"
        case "cf-client-id":
            return "tw-screenshot-client-id"
        case "cf-client-secret":
            return "tw-screenshot-client-secret"
        case "service-account-json":
            return #"{"type":"service_account","project_id":"typewhisper-screenshot","private_key_id":"screenshot","private_key":"-----BEGIN PRIVATE KEY-----\nSCREENSHOT FIXTURE\n-----END PRIVATE KEY-----\n","client_email":"screenshots@typewhisper-screenshot.iam.gserviceaccount.com"}"#
        case "contributor-token":
            return "tw-screenshot-contributor-token"
        case "oauth-access-token", "oauth-refresh-token", "oauth-id-token":
            // Keep the OpenAI screenshot in API-key mode instead of simulating a ChatGPT account.
            return nil
        default:
            return nil
        }
    }
}
