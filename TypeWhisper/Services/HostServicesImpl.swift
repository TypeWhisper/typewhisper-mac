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

final class HostServicesImpl: HostServices, HostModelLifecyclePolicyProviding, HostModelAutoUnloadPolicyProviding, HostManagedPolicyProviding, @unchecked Sendable {
    let pluginId: String
    let pluginDataDirectory: URL
    /// Whether this plugin backs the engine the user actually has selected,
    /// evaluated AT CALL TIME rather than captured once.
    ///
    /// *** IT MUST BE DYNAMIC. *** `ModelManagerService.selectProvider` writes
    /// `selectedEngine` at any moment and notifies no existing host, and at startup
    /// `restoreProviderSelection()` runs AFTER `scanAndLoadPlugins()` -- three lines
    /// apart in ServiceContainer -- so a value captured during activation can be
    /// stale before the app has finished launching. Several plugins also consult
    /// their host again later from their settings views. A snapshot would suppress
    /// restore for an engine selected afterwards, and permit it for one deselected
    /// since.
    ///
    /// Defaults to `{ true }`, the pre-existing behaviour, so any host built without
    /// this knowledge behaves exactly as before.
    private let backsSelectedEngine: @Sendable () -> Bool

    var backsSelectedTranscriptionEngine: Bool { backsSelectedEngine() }
    let eventBus: EventBusProtocol
    private let ruleNamesProvider: @MainActor () -> [String]
    private let workflowProvider: @MainActor () -> [PluginWorkflowInfo]

    private let policyStore: ManagedPolicySnapshotStore
    private let locality: PluginLocality?

    init(
        pluginId: String,
        locality: PluginLocality? = nil,
        policyStore: ManagedPolicySnapshotStore = .shared,
        eventBus: EventBusProtocol,
        ruleNamesProvider: @escaping @MainActor () -> [String],
        workflowProvider: @escaping @MainActor () -> [PluginWorkflowInfo] = { [] },
        backsSelectedTranscriptionEngine: @escaping @Sendable () -> Bool = { true }
    ) {
        self.pluginId = pluginId
        self.backsSelectedEngine = backsSelectedTranscriptionEngine
        self.policyStore = policyStore
        self.locality = locality
        self.eventBus = ManagedPolicyEventBus(base: eventBus, pluginId: pluginId, locality: locality, store: policyStore)
        self.ruleNamesProvider = ruleNamesProvider
        self.workflowProvider = workflowProvider

        self.pluginDataDirectory = AppConstants.appSupportDirectory
            .appendingPathComponent("PluginData", isDirectory: true)
            .appendingPathComponent(pluginId, isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: pluginDataDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Managed settings

    /// Read on the plugin's own threads, so it comes from the thread-safe snapshot store.
    var modelDownloadRefusal: String? {
        policyStore.providerPolicy.modelDownloadRefusal
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
        // Plugins read credentials synchronously in activate(host:), so keychain
        // latency is part of launch. The interval carries no key or value.
        let signposter = LaunchSignposts.signposter
        return signposter.withIntervalSignpost("Plugin.loadSecret", id: signposter.makeSignpostID()) {
            KeychainService.load(service: scopedService)
        }
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

    /// Passive restore is permitted only when the auto-unload policy allows it AND
    /// this plugin backs the selected engine.
    ///
    /// *** THIS IS THE LIVE PATH, AND THAT IS THE WHOLE POINT. *** Each local-model
    /// plugin spawns its own restore from this property, e.g. Qwen3Plugin.activate:
    /// `if shouldRestoreLoadedModelsPassively { Task { await restoreLoadedModel() } }`.
    /// An earlier fix for the same issue instead tightened
    /// `PluginManager.shouldSuppressPassiveLoadedModelRestore`, which feeds a guard
    /// whose last term is `!shouldRestoreLoadedModelsPassively` -- so it could only
    /// fire when the policy was NOT "Never", while the plugins only restore when it
    /// IS. Mutually exclusive, and therefore inert. Its tests passed because they
    /// asserted a predicate's return value rather than that a model fails to load.
    var shouldRestoreLoadedModelsPassively: Bool {
        ModelAutoUnloadPolicy.shouldRestoreLoadedModelsPassively()
            && backsSelectedTranscriptionEngine
    }

    var unloadsModelsImmediatelyAfterUse: Bool {
        ModelAutoUnloadPolicy.unloadsModelsImmediatelyAfterUse()
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

    /// Whether the managed settings let this plugin receive text and context, such as the
    /// active app, rule names and workflows. Checked on every read, so a policy change
    /// applies at once.
    private var mayReceiveContext: Bool {
        policyStore.providerPolicy.textRefusal(pluginId: pluginId, locality: locality) == nil
    }

    var activeAppBundleId: String? {
        guard mayReceiveContext else { return nil }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    var activeAppName: String? {
        guard mayReceiveContext else { return nil }
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }

    // MARK: - Rules

    var availableRuleNames: [String] {
        guard mayReceiveContext else { return [] }
        return readMainActor(ruleNamesProvider)
    }

    var availableWorkflows: [PluginWorkflowInfo] {
        guard mayReceiveContext else { return [] }
        return readMainActor(workflowProvider)
    }

    // MARK: - Capabilities

    func notifyCapabilitiesChanged() {
        DispatchQueue.main.async {
            PluginManager.shared?.notifyPluginStateChanged()
        }
    }

    func openPluginSettings() {
        DispatchQueue.main.async { [pluginId] in
            guard PluginManager.shared?.loadedPlugins.contains(where: {
                $0.id == pluginId && $0.isEnabled && $0.isRuntimeLoaded
            }) == true else { return }
            SettingsNavigationCoordinator.shared.navigate(to: .installedPlugin(pluginId: pluginId))
            ManagedAppWindowOpener.shared.open(id: "settings")
        }
    }


    func enqueueImportedMediaForTranscription(
        _ media: PluginImportedMedia,
        fromMediaImporterId mediaImporterId: String
    ) async -> Bool {
        await MainActor.run { [pluginId] in
            guard let importer = PluginManager.shared?.mediaImportPlugins.first(where: {
                type(of: $0).pluginId == pluginId && $0.mediaImportId == mediaImporterId
            }) else {
                return false
            }
            return FileTranscriptionViewModel.shared.enqueueImportedMedia(media, from: importer)
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

/// Keeps transcripts and other content off plugins the managed settings do not let receive text.
/// Events without content, such as recording start and stop, still arrive.
struct ManagedPolicyEventBus: EventBusProtocol {
    let base: EventBusProtocol
    let pluginId: String
    let locality: PluginLocality?
    var store: ManagedPolicySnapshotStore = .shared

    @discardableResult
    func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID {
        let pluginId = pluginId
        let locality = locality
        let store = store
        return base.subscribe { event in
            // Checked per event, so a policy that changes while the plugin runs applies at once.
            guard store.providerPolicy.textRefusal(pluginId: pluginId, locality: locality) != nil else {
                await handler(event)
                return
            }
            if let event = event.withoutContext {
                await handler(event)
            }
        }
    }

    func unsubscribe(id: UUID) {
        base.unsubscribe(id: id)
    }
}

extension TypeWhisperEvent {
    /// The event for a plugin that may not receive text: lifecycle events lose the active app,
    /// and events that carry transcript, inserted or corrected text, or files with it are
    /// withheld (nil).
    var withoutContext: TypeWhisperEvent? {
        switch self {
        case .recordingStarted(let payload):
            .recordingStarted(RecordingStartedPayload(timestamp: payload.timestamp))
        case .recordingStopped:
            self
        case .transcriptionFailed(let payload):
            .transcriptionFailed(TranscriptionFailedPayload(timestamp: payload.timestamp, error: payload.error))
        case .transcriptionCompleted, .textInserted, .textCorrectionCommitted, .actionCompleted,
             .partialTranscriptionUpdate, .recorderTranscriptReady:
            nil
        }
    }
}
