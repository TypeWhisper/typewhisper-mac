import AppKit
import Combine
import Foundation
import SwiftUI
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "PluginManager")

enum RuntimeArchitecture {
    nonisolated(unsafe) static var overrideCurrent: String?

    static var current: String {
        if let overrideCurrent {
            return overrideCurrent
        }
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }
}

enum PluginCompatibility {
    static func isCompatible(minOSVersion: String?, supportedArchitectures: [String]?) -> Bool {
        isCompatible(
            minOSVersion: minOSVersion,
            supportedArchitectures: supportedArchitectures,
            currentOSVersion: ProcessInfo.processInfo.operatingSystemVersion,
            architecture: RuntimeArchitecture.current
        )
    }

    static func isCompatible(
        minOSVersion: String?,
        supportedArchitectures: [String]?,
        currentOSVersion: OperatingSystemVersion,
        architecture: String
    ) -> Bool {
        if let minOSVersion, !isCompatibleWithCurrentOS(minOSVersion: minOSVersion, currentOSVersion: currentOSVersion) {
            return false
        }

        guard let supportedArchitectures, !supportedArchitectures.isEmpty else {
            return true
        }

        return supportedArchitectures.contains(architecture)
    }

    static func incompatibilityReason(
        minOSVersion: String?,
        supportedArchitectures: [String]?,
        architecture: String
    ) -> String? {
        if let minOSVersion, !isCompatibleWithCurrentOS(
            minOSVersion: minOSVersion,
            currentOSVersion: ProcessInfo.processInfo.operatingSystemVersion
        ) {
            return "requires macOS \(minOSVersion)"
        }

        guard let supportedArchitectures, !supportedArchitectures.isEmpty else {
            return nil
        }

        guard !supportedArchitectures.contains(architecture) else {
            return nil
        }

        return "supports architectures \(supportedArchitectures.joined(separator: ", "))"
    }

    private static func isCompatibleWithCurrentOS(
        minOSVersion: String,
        currentOSVersion: OperatingSystemVersion
    ) -> Bool {
        let parts = minOSVersion.split(separator: ".").compactMap { Int($0) }
        let required = OperatingSystemVersion(
            majorVersion: parts.count > 0 ? parts[0] : 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        if currentOSVersion.majorVersion != required.majorVersion {
            return currentOSVersion.majorVersion > required.majorVersion
        }
        if currentOSVersion.minorVersion != required.minorVersion {
            return currentOSVersion.minorVersion > required.minorVersion
        }
        return currentOSVersion.patchVersion >= required.patchVersion
    }
}

extension PluginManifest {
    var isCompatibleWithCurrentEnvironment: Bool {
        PluginCompatibility.isCompatible(
            minOSVersion: minOSVersion,
            supportedArchitectures: supportedArchitectures
        )
    }
}

private enum PluginLoadError: LocalizedError {
    case incompatibleHostVersion(pluginName: String, required: String, current: String)
    case failedToCreateBundle(bundleName: String)
    case missingPrincipalClass(className: String, bundleName: String)

    var errorDescription: String? {
        switch self {
        case .incompatibleHostVersion(let pluginName, let required, let current):
            return "\(pluginName) requires dictum \(required) or newer (current: \(current))"
        case .failedToCreateBundle(let bundleName):
            return "Failed to create bundle for \(bundleName)"
        case .missingPrincipalClass(let className, let bundleName):
            return "Failed to find class \(className) in \(bundleName)"
        }
    }
}

/// Maps an enabled plugin bundle's executable and resolves its principal class.
///
/// Production always uses `.bundleExecutable`. Tests inject in-process classes so the
/// launch scan, activation order and change publication can be exercised without
/// compiled plugin bundles.
struct PluginRuntimeLoader {
    let principalClass: @MainActor (_ bundle: Bundle, _ manifest: PluginManifest) throws -> TypeWhisperPlugin.Type

    static var bundleExecutable: PluginRuntimeLoader {
        PluginRuntimeLoader { bundle, manifest in
            let bundleName = bundle.bundleURL.lastPathComponent
            do {
                try bundle.loadAndReturnError()
            } catch {
                logger.error("Failed to load bundle \(bundleName): \(error.localizedDescription)")
                throw error
            }

            guard let pluginClass = NSClassFromString(manifest.principalClass) as? TypeWhisperPlugin.Type else {
                let error = PluginLoadError.missingPrincipalClass(
                    className: manifest.principalClass,
                    bundleName: bundleName
                )
                logger.error("\(error.localizedDescription, privacy: .public)")
                throw error
            }
            return pluginClass
        }
    }
}

// MARK: - Loaded Plugin

private final class UnloadedPluginPlaceholder: NSObject, TypeWhisperPlugin, @unchecked Sendable {
    static var pluginId: String { "com.typewhisper.unloaded-placeholder" }
    static var pluginName: String { "Unloaded Plugin Placeholder" }

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {}
    func deactivate() {}
}

struct LoadedPlugin: Identifiable {
    let manifest: PluginManifest
    let instance: TypeWhisperPlugin
    let bundle: Bundle
    let sourceURL: URL
    var isEnabled: Bool
    private let builtInPluginsURL: URL?

    init(
        manifest: PluginManifest,
        instance: TypeWhisperPlugin,
        bundle: Bundle,
        sourceURL: URL,
        isEnabled: Bool,
        builtInPluginsURL: URL? = Bundle.main.builtInPlugInsURL
    ) {
        self.manifest = manifest
        self.instance = instance
        self.bundle = bundle
        self.sourceURL = sourceURL
        self.isEnabled = isEnabled
        self.builtInPluginsURL = builtInPluginsURL?.resolvingSymlinksInPath().standardizedFileURL
    }

    var id: String { manifest.id }

    var isBundled: Bool {
        guard let builtInURL = builtInPluginsURL else { return false }
        return sourceURL.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL
            == builtInURL.resolvingSymlinksInPath().standardizedFileURL
    }

    var isRuntimeLoaded: Bool {
        !(instance is UnloadedPluginPlaceholder)
    }

    @MainActor
    var supportsSettingsWindow: Bool {
        guard isRuntimeLoaded else { return false }
        return instance.settingsView != nil
    }
}


enum PluginModelManagementError: LocalizedError {
    case pluginNotFound
    case pluginNotLoaded(String)
    case unsupported(String)
    case modelNotFound(String)
    case pluginBusy(String)

    var errorDescription: String? {
        switch self {
        case .pluginNotFound:
            return "Plugin not found."
        case .pluginNotLoaded(let name):
            return "\(name) is disabled. Enable the plugin before managing downloaded models."
        case .unsupported(let name):
            return "\(name) does not expose downloaded model management."
        case .modelNotFound(let modelId):
            return "Downloaded model '\(modelId)' was not found."
        case .pluginBusy(let name):
            return "\(name) is currently updating models. Try again when the operation finishes."
        }
    }
}

// MARK: - Plugin Manager


@MainActor
final class PluginManager: ObservableObject {
    nonisolated(unsafe) static var shared: PluginManager!

    // Registry mutations publish through `registryRevision` (like `@Published`, but a
    // bulk scan coalesces them; see `coalescingRegistryChangeNotifications`).
    var loadedPlugins: [LoadedPlugin] = [] {
        willSet { publishRegistryChange() }
    }
    /// Plugins the managed settings refuse as a whole, with the localized reason. They are
    /// registered without loading their code.
    private(set) var policyRefusals: [String: String] = [:] {
        willSet { publishRegistryChange() }
    }
    /// The cloud, provider and plugin restrictions of the managed settings.
    private(set) var providerPolicy: ManagedProviderPolicy = .unmanaged
    /// The enforced and recommended provider and model pairs of the managed settings.
    private(set) var selectionPolicy: ManagedSelectionPolicy = .unmanaged
    /// 注册表变更时递增，批量扫描只发布一次。
    @Published private(set) var registryRevision = 0
    @Published private(set) var readinessRevision = 0

    let pluginsDirectory: URL
    private let builtInPluginsURL: URL?
    private let runtimeLoader: PluginRuntimeLoader
    private var ruleNamesProvider: @MainActor () -> [String] = { [] }
    private var workflowProvider: @MainActor () -> [PluginWorkflowInfo] = { [] }
    private var deletingModelPluginIds = Set<String>()
    private var registryNotificationBatchDepth = 0
    private var registryChangedDuringBatch = false


    var postProcessors: [PostProcessorPlugin] {
        loadedPlugins
            .filter { $0.isEnabled && permitsText($0) }
            .compactMap { $0.instance as? PostProcessorPlugin }
            .sorted { $0.priority < $1.priority }
    }

    var fileJobAutomations: [FileJobAutomationPlugin] {
        loadedPlugins
            .filter { $0.isEnabled && permitsText($0) }
            .compactMap { $0.instance as? FileJobAutomationPlugin }
            .sorted { $0.priority < $1.priority }
    }

    var mediaImportPlugins: [any MediaImportPlugin] {
        loadedPlugins
            .filter { $0.isEnabled }
            .flatMap { plugin -> [any MediaImportPlugin] in
                var importers: [any MediaImportPlugin] = []
                if let importer = plugin.instance as? any MediaImportPlugin {
                    importers.append(importer)
                }
                if let expanded = plugin.instance as? any AdditionalMediaImportPluginsProviding {
                    importers.append(contentsOf: expanded.additionalMediaImportPlugins)
                }
                return importers
            }
    }

    var llmProviders: [LLMProviderPlugin] {
        loadedPlugins
            .filter { $0.isEnabled && policyRefusals[$0.manifest.id] == nil }
            .flatMap { plugin -> [LLMProviderPlugin] in
                var providers: [LLMProviderPlugin] = []
                if let provider = plugin.instance as? LLMProviderPlugin {
                    providers.append(provider)
                }
                if let expanded = plugin.instance as? AdditionalLLMProvidersProviding {
                    providers.append(contentsOf: expanded.additionalLLMProviders)
                }
                return providers.filter { llmRefusal(for: $0, in: plugin) == nil }
            }
    }

    var ttsProviders: [TTSProviderPlugin] {
        loadedPlugins
            .filter { $0.isEnabled && permitsText($0) }
            .compactMap { $0.instance as? TTSProviderPlugin }
    }

    /// Engines the managed settings refuse are left out, so pickers and fallbacks never offer them;
    /// `transcriptionPolicyRefusal(forProviderId:)` names the reason for a refused selection.
    var transcriptionEngines: [TranscriptionEnginePlugin] {
        loadedPlugins
            .filter { $0.isEnabled && policyRefusals[$0.manifest.id] == nil }
            .flatMap { plugin -> [TranscriptionEnginePlugin] in
                var engines: [TranscriptionEnginePlugin] = []
                if let engine = plugin.instance as? TranscriptionEnginePlugin {
                    engines.append(engine)
                }
                if let expanded = plugin.instance as? AdditionalTranscriptionEnginesProviding {
                    engines.append(contentsOf: expanded.additionalTranscriptionEngines)
                }
                return engines.filter { transcriptionRefusal(for: $0.providerId, in: plugin) == nil }
            }
    }

    var actionPlugins: [ActionPlugin] {
        loadedPlugins
            .filter { $0.isEnabled && permitsText($0) }
            .flatMap { plugin -> [ActionPlugin] in
                var actions: [ActionPlugin] = []
                if let action = plugin.instance as? ActionPlugin {
                    actions.append(action)
                }
                if let expanded = plugin.instance as? AdditionalActionPluginsProviding {
                    actions.append(contentsOf: expanded.additionalActionPlugins)
                }
                return actions
            }
    }

    var speakerDiarizationProviders: [any SpeakerDiarizationProviderPlugin] {
        loadedPlugins
            .filter { $0.isEnabled && permits($0, .audio) }
            .compactMap { $0.instance as? any SpeakerDiarizationProviderPlugin }
    }


    // MARK: - Managed settings

    private func permits(_ plugin: LoadedPlugin, _ content: ManagedProviderPolicy.Content) -> Bool {
        policyRefusals[plugin.manifest.id] == nil
            && providerPolicy.cloudRefusal(content, locality: plugin.manifest.resolvedLocality) == nil
    }

    private func permitsText(_ plugin: LoadedPlugin) -> Bool {
        policyRefusals[plugin.manifest.id] == nil
            && providerPolicy.textRefusal(pluginId: plugin.manifest.id, locality: plugin.manifest.resolvedLocality) == nil
    }

    private func transcriptionRefusal(for providerId: String, in plugin: LoadedPlugin) -> String? {
        policyRefusals[plugin.manifest.id] ?? providerPolicy.transcriptionRefusal(
            pluginId: plugin.manifest.id,
            providerId: providerId,
            locality: plugin.manifest.resolvedLocality
        )
    }

    private func llmRefusal(for provider: LLMProviderPlugin, in plugin: LoadedPlugin) -> String? {
        policyRefusals[plugin.manifest.id] ?? providerPolicy.llmRefusal(
            pluginId: plugin.manifest.id,
            providerId: provider.llmProviderId,
            locality: plugin.manifest.resolvedLocality
        )
    }

    /// Why the managed settings refuse audio for this engine, or nil. Also finds engines the
    /// filtered lists leave out and plugins refused as a whole, so a refused selection reports the
    /// reason instead of a missing engine.
    func transcriptionPolicyRefusal(forProviderId providerId: String) -> String? {
        guard let plugin = loadedPlugins.first(where: { $0.isEnabled && Self.plugin($0, provides: providerId) }) else {
            return refusalOfRefusedPackage(exposing: providerId)
        }
        return transcriptionRefusal(for: providerId, in: plugin)
    }

    /// Why the managed settings refuse the engine that offers this model, for requests that name
    /// only a model. Searches the engines the filtered lists leave out.
    func transcriptionPolicyRefusal(forModelId modelId: String) -> String? {
        for plugin in loadedPlugins where plugin.isEnabled {
            var engines: [TranscriptionEnginePlugin] = []
            if let engine = plugin.instance as? TranscriptionEnginePlugin {
                engines.append(engine)
            }
            if let expanded = plugin.instance as? AdditionalTranscriptionEnginesProviding {
                engines.append(contentsOf: expanded.additionalTranscriptionEngines)
            }
            for engine in engines where engine.modelCatalog.contains(where: { $0.id == modelId }) {
                if let refusal = transcriptionRefusal(for: engine.providerId, in: plugin) {
                    return refusal
                }
            }
        }
        // A plugin refused as a whole is a placeholder without models; match the ones it offered.
        return policyRefusals.first { pluginId, _ in
            (UserDefaults.standard.stringArray(forKey: Self.knownModelIdsKey(pluginId)) ?? []).contains(modelId)
        }?.value
    }

    /// Provider IDs a plugin exposed when it last ran, so a plugin refused before it loads can still
    /// be matched to the engine or language model a user selected.
    static func knownProviderIdsKey(_ pluginId: String) -> String {
        "plugin.\(pluginId).knownProviderIds"
    }

    /// Transcription model IDs a plugin offered when it last ran, for requests that name only a model.
    static func knownModelIdsKey(_ pluginId: String) -> String {
        "plugin.\(pluginId).knownTranscriptionModelIds"
    }

    private func rememberProviderIds(of plugin: LoadedPlugin) {
        var ids = transcriptionProviderIds(exposedBy: plugin.instance)
        var llmProviders: [LLMProviderPlugin] = []
        if let provider = plugin.instance as? LLMProviderPlugin {
            llmProviders.append(provider)
        }
        if let expanded = plugin.instance as? AdditionalLLMProvidersProviding {
            llmProviders.append(contentsOf: expanded.additionalLLMProviders)
        }
        for provider in llmProviders {
            ids.insert(provider.llmProviderId)
            ids.insert(provider.providerName)
            ids.insert(provider.llmProviderDisplayName)
            ids.formUnion(provider.llmProviderLegacyAliases)
        }
        Self.remember(ids, forKey: Self.knownProviderIdsKey(plugin.manifest.id))

        var engines: [TranscriptionEnginePlugin] = []
        if let engine = plugin.instance as? TranscriptionEnginePlugin {
            engines.append(engine)
        }
        if let expanded = plugin.instance as? AdditionalTranscriptionEnginesProviding {
            engines.append(contentsOf: expanded.additionalTranscriptionEngines)
        }
        Self.remember(Set(engines.flatMap { $0.modelCatalog.map(\.id) }), forKey: Self.knownModelIdsKey(plugin.manifest.id))
    }

    private static func remember(_ ids: Set<String>, forKey key: String) {
        let sorted = ids.sorted()
        guard !sorted.isEmpty, UserDefaults.standard.stringArray(forKey: key) != sorted else { return }
        UserDefaults.standard.set(sorted, forKey: key)
    }

    private func refusalOfRefusedPackage(exposing providerId: String) -> String? {
        policyRefusals.first { pluginId, _ in
            (UserDefaults.standard.stringArray(forKey: Self.knownProviderIdsKey(pluginId)) ?? [])
                .contains { $0.caseInsensitiveCompare(providerId) == .orderedSame }
        }?.value
    }

    /// Why the managed settings refuse text for this language model provider, or nil.
    func llmPolicyRefusal(forProviderId providerId: String) -> String? {
        let providerId = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        for plugin in loadedPlugins where plugin.isEnabled {
            var providers: [LLMProviderPlugin] = []
            if let provider = plugin.instance as? LLMProviderPlugin {
                providers.append(provider)
            }
            if let expanded = plugin.instance as? AdditionalLLMProvidersProviding {
                providers.append(contentsOf: expanded.additionalLLMProviders)
            }
            // The same names llmProvider(for:) accepts, so saved legacy aliases report the refusal too.
            if let provider = providers.first(where: { provider in
                ([provider.llmProviderId, provider.providerName, provider.llmProviderDisplayName]
                    + provider.llmProviderLegacyAliases)
                    .contains { $0.caseInsensitiveCompare(providerId) == .orderedSame }
            }) {
                return llmRefusal(for: provider, in: plugin)
            }
        }
        return refusalOfRefusedPackage(exposing: providerId)
    }

    /// Whether dictionary terms may travel as prompt text with audio sent to this engine.
    func allowsPromptText(forTranscriptionProviderId providerId: String) -> Bool {
        guard let plugin = loadedTranscriptionPlugin(for: providerId) else { return true }
        return providerPolicy.allowsPromptText(toTranscriptionLocality: plugin.manifest.resolvedLocality)
    }

    /// Applies new managed settings: plugins refused as a whole stop and stay unloaded, refused
    /// providers drop out of the lists, and plugins the user enabled load again once allowed. Neither
    /// the enabled preference nor the selected engine is written; code that was already loaded stays
    /// mapped until the next launch.
    func applyProviderPolicy(_ policy: ManagedProviderPolicy) {
        guard policy != providerPolicy else { return }
        providerPolicy = policy
        coalescingRegistryChangeNotifications {
            for plugin in loadedPlugins {
                let refusal = policy.packageRefusal(for: plugin.manifest)
                let wasRefused = policyRefusals[plugin.manifest.id] != nil
                if let refusal {
                    policyRefusals[plugin.manifest.id] = refusal
                    if plugin.isEnabled {
                        stopRefusedPlugin(plugin.manifest.id)
                    }
                } else if wasRefused {
                    policyRefusals.removeValue(forKey: plugin.manifest.id)
                    if !plugin.isEnabled, storedEnabledState(for: plugin) {
                        resumeAllowedPlugin(plugin.manifest.id)
                    }
                }
            }
        }
        publishRegistryChange()
    }

    /// Applies new provider and model pairs. Listeners re-resolve the engine and language model.
    func applySelectionPolicy(_ policy: ManagedSelectionPolicy) {
        guard policy != selectionPolicy else { return }
        selectionPolicy = policy
        publishRegistryChange()
    }

    /// The engine the enforced transcription pair selects, nil when no pair is enforced.
    var enforcedTranscriptionResolution: ManagedPairResolution? {
        if selectionPolicy.isTranscriptionBlocked {
            return .unavailable(ManagedProviderPolicy.blockedMessage)
        }
        return selectionPolicy.enforcedTranscription.map(resolveTranscriptionPair)
    }

    /// The language model the enforced LLM pair selects, nil when no pair is enforced.
    var enforcedLlmResolution: ManagedPairResolution? {
        if selectionPolicy.isLlmBlocked {
            return .unavailable(ManagedProviderPolicy.blockedMessage)
        }
        return selectionPolicy.enforcedLlm.map(resolveLlmPair)
    }

    func resolveTranscriptionPair(_ pair: ManagedSelectionPair) -> ManagedPairResolution {
        let (pluginId, qualifier) = pair.components
        guard let plugin = loadedPlugins.first(where: { $0.manifest.id.caseInsensitiveCompare(pluginId) == .orderedSame }) else {
            return .unavailable(String(localized: "The transcription provider your organization requires is not installed."))
        }
        if let refusal = policyRefusals[plugin.manifest.id] {
            return .unavailable(refusal)
        }
        guard plugin.isEnabled, plugin.isRuntimeLoaded else {
            return .unavailable(String(localized: "The transcription provider your organization requires is turned off."))
        }
        var engines: [TranscriptionEnginePlugin] = []
        if let engine = plugin.instance as? TranscriptionEnginePlugin {
            engines.append(engine)
        }
        if let expanded = plugin.instance as? AdditionalTranscriptionEnginesProviding {
            engines.append(contentsOf: expanded.additionalTranscriptionEngines)
        }
        let engine: TranscriptionEnginePlugin? = if let qualifier {
            engines.first { $0.providerId.caseInsensitiveCompare(qualifier) == .orderedSame }
        } else {
            engines.count == 1 ? engines.first : nil
        }
        guard let engine else {
            return .unavailable(String(localized: "Your organization's transcription provider does not name one of this plugin's engines."))
        }
        if let refusal = transcriptionRefusal(for: engine.providerId, in: plugin) {
            return .unavailable(refusal)
        }
        // The catalog lists every selectable model; some engines list only the loaded one as models.
        guard let modelId = Self.matchingModelId(pair.modelId, in: engine.modelCatalog.map(\.id)) else {
            return .unavailable(String(localized: "The transcription model your organization requires is not offered by this provider."))
        }
        return .resolved(providerId: engine.providerId, modelId: modelId)
    }

    func resolveLlmPair(_ pair: ManagedSelectionPair) -> ManagedPairResolution {
        let (pluginId, qualifier) = pair.components
        if pluginId.caseInsensitiveCompare(ManagedProviderPolicy.appleIntelligenceId) == .orderedSame {
            if let refusal = providerPolicy.llmRefusal(
                pluginId: ManagedProviderPolicy.appleIntelligenceId,
                providerId: PromptProcessingService.appleIntelligenceId,
                locality: .local
            ) {
                return .unavailable(refusal)
            }
            // The built-in provider exists from macOS 26 on.
            guard #available(macOS 26, *) else {
                return .unavailable(String(localized: "The language model provider your organization requires needs macOS 26 or later."))
            }
            return .resolved(providerId: PromptProcessingService.appleIntelligenceId, modelId: pair.modelId)
        }
        guard let plugin = loadedPlugins.first(where: { $0.manifest.id.caseInsensitiveCompare(pluginId) == .orderedSame }) else {
            return .unavailable(String(localized: "The language model provider your organization requires is not installed."))
        }
        if let refusal = policyRefusals[plugin.manifest.id] {
            return .unavailable(refusal)
        }
        guard plugin.isEnabled, plugin.isRuntimeLoaded else {
            return .unavailable(String(localized: "The language model provider your organization requires is turned off."))
        }
        var providers: [LLMProviderPlugin] = []
        if let provider = plugin.instance as? LLMProviderPlugin {
            providers.append(provider)
        }
        if let expanded = plugin.instance as? AdditionalLLMProvidersProviding {
            providers.append(contentsOf: expanded.additionalLLMProviders)
        }
        let provider: LLMProviderPlugin? = if let qualifier {
            providers.first {
                $0.llmProviderId.caseInsensitiveCompare(qualifier) == .orderedSame
                    || $0.providerName.caseInsensitiveCompare(qualifier) == .orderedSame
            }
        } else {
            providers.count == 1 ? providers.first : nil
        }
        guard let provider else {
            return .unavailable(String(localized: "Your organization's language model provider does not name one of this plugin's providers."))
        }
        if let refusal = llmRefusal(for: provider, in: plugin) {
            return .unavailable(refusal)
        }
        guard let modelId = Self.matchingModelId(pair.modelId, in: provider.supportedModels.map(\.id)) else {
            return .unavailable(String(localized: "The language model your organization requires is not offered by this provider."))
        }
        return .resolved(providerId: provider.llmProviderId, modelId: modelId)
    }

    /// The catalog's spelling of `modelId`. Providers whose models are not listed in advance accept it as is.
    private static func matchingModelId(_ modelId: String, in catalog: [String]) -> String? {
        guard !catalog.isEmpty else { return modelId }
        return catalog.first { $0.caseInsensitiveCompare(modelId) == .orderedSame }
    }

    private func storedEnabledState(for plugin: LoadedPlugin) -> Bool {
        (UserDefaults.standard.object(forKey: "plugin.\(plugin.manifest.id).enabled") as? Bool) ?? plugin.isBundled
    }

    private func stopRefusedPlugin(_ pluginId: String) {
        guard let index = loadedPlugins.firstIndex(where: { $0.manifest.id == pluginId }) else { return }
        let plugin = loadedPlugins[index]
        PluginSettingsWindowManager.shared.closeWindow(for: pluginId)
        if plugin.isRuntimeLoaded {
            rememberProviderIds(of: plugin)
            plugin.instance.deactivate()
        }
        if let placeholder = try? makeUnloadedPluginRecord(manifest: plugin.manifest, sourceURL: plugin.sourceURL) {
            loadedPlugins[index] = placeholder
        } else {
            loadedPlugins[index].isEnabled = false
        }
        logger.info("Stopped plugin \(pluginId, privacy: .public) refused by managed settings")
    }

    private func resumeAllowedPlugin(_ pluginId: String) {
        guard let index = loadedPlugins.firstIndex(where: { $0.manifest.id == pluginId }) else { return }
        let placeholder = loadedPlugins.remove(at: index)
        do {
            try loadPlugin(at: placeholder.sourceURL)
        } catch {
            logger.error("Failed to load plugin \(pluginId, privacy: .public) allowed again by managed settings: \(error.localizedDescription, privacy: .public)")
            loadedPlugins.insert(placeholder, at: min(index, loadedPlugins.count))
        }
    }

    func transcriptionEngine(for providerId: String) -> TranscriptionEnginePlugin? {
        transcriptionEngines.first { $0.providerId == providerId }
    }

    func loadedTranscriptionPlugin(for providerId: String) -> LoadedPlugin? {
        loadedPlugins.first { $0.isEnabled && Self.plugin($0, provides: providerId) }
    }

    /// Also finds disabled plugins, so callers can open the page where one gets re-enabled.
    func installedTranscriptionPlugin(for providerId: String) -> LoadedPlugin? {
        loadedPlugins.first { Self.plugin($0, provides: providerId) }
    }

    private static func plugin(_ plugin: LoadedPlugin, provides providerId: String) -> Bool {
        if let engine = plugin.instance as? TranscriptionEnginePlugin,
           engine.providerId == providerId {
            return true
        }
        if let expanded = plugin.instance as? AdditionalTranscriptionEnginesProviding,
           expanded.additionalTranscriptionEngines.contains(where: { $0.providerId == providerId }) {
            return true
        }
        return false
    }

    func ttsProvider(for providerId: String) -> TTSProviderPlugin? {
        ttsProviders.first { $0.providerId == providerId }
    }

    func loadedTTSPlugin(for providerId: String) -> LoadedPlugin? {
        loadedPlugins.first {
            guard let provider = $0.instance as? TTSProviderPlugin else { return false }
            return $0.isEnabled && provider.providerId == providerId
        }
    }

    func actionPlugin(for actionId: String) -> ActionPlugin? {
        actionPlugins.first { $0.actionId == actionId }
    }

    func llmProvider(for providerName: String) -> LLMProviderPlugin? {
        let lookup = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lookup.isEmpty else { return nil }

        if let idMatch = llmProviders.first(where: {
            $0.llmProviderId.caseInsensitiveCompare(lookup) == .orderedSame
        }) {
            return idMatch
        }

        return llmProviders.first { provider in
            provider.llmProviderDisplayName.caseInsensitiveCompare(lookup) == .orderedSame
                || provider.providerName.caseInsensitiveCompare(lookup) == .orderedSame
                || provider.llmProviderLegacyAliases.contains {
                    $0.caseInsensitiveCompare(lookup) == .orderedSame
                }
        }
    }

    func isManifestCompatible(_ manifest: PluginManifest) -> Bool {
        manifest.isCompatibleWithCurrentEnvironment
    }

    func isManifestSDKCompatible(_ manifest: PluginManifest, isBundled: Bool) -> Bool {
        PluginSDKCompatibility.isCompatible(
            manifestVersion: manifest.sdkCompatibilityVersion,
            isBundled: isBundled
        )
    }


    init(
        appSupportDirectory: URL = AppConstants.appSupportDirectory,
        builtInPluginsURL: URL? = Bundle.main.builtInPlugInsURL,
        runtimeLoader: PluginRuntimeLoader = .bundleExecutable
    ) {
        self.pluginsDirectory = appSupportDirectory
            .appendingPathComponent("Plugins", isDirectory: true)
        self.runtimeLoader = runtimeLoader
        self.builtInPluginsURL = builtInPluginsURL?.resolvingSymlinksInPath().standardizedFileURL
    }

    // MARK: - Registry Change Publication

    private func publishRegistryChange() {
        guard registryNotificationBatchDepth == 0 else {
            registryChangedDuringBatch = true
            return
        }
        registryRevision &+= 1
    }

    /// Runs `body` with registry change notifications coalesced into at most one
    /// `registryRevision` step (and so one `objectWillChange`), sent after the batch.
    ///
    /// Every `objectWillChange` fans out to the services and view models observing
    /// this manager, and each of them re-reconciles its engine/LLM selection on the
    /// main queue. Without coalescing, a launch scan queues one such pass per
    /// observer for every registry mutation (roughly two per bundle), all of which
    /// run after the scan and see the same final registry. Mutations still apply in
    /// place, so `loadedPlugins` is current throughout the batch.
    func coalescingRegistryChangeNotifications<Result>(_ body: () throws -> Result) rethrows -> Result {
        registryNotificationBatchDepth += 1
        defer {
            registryNotificationBatchDepth -= 1
            if registryNotificationBatchDepth == 0, registryChangedDuringBatch {
                registryChangedDuringBatch = false
                registryRevision &+= 1
            }
        }
        return try body()
    }

    // MARK: - Plugin Loading

    func scanAndLoadPlugins() {
        let signposter = LaunchSignposts.signposter
        let scanState = signposter.beginInterval("Plugin.scan")
        defer { signposter.endInterval("Plugin.scan", scanState) }
        coalescingRegistryChangeNotifications {
            loadAllPluginBundles()
        }
    }

    private func loadAllPluginBundles() {
        let fm = FileManager.default
        // Built-in plugins from app bundle
        if let builtInURL = builtInPluginsURL,
           let builtIn = try? fm.contentsOfDirectory(at: builtInURL, includingPropertiesForKeys: nil) {
            let candidateBundles = builtIn.filter { $0.pathExtension == "bundle" }
            let builtInBundles = sortedPluginBundleURLs(
                candidateBundles,
                isBundledSource: true
            )
            logger.info("Found \(builtInBundles.count) built-in plugin bundle(s)")
            for bundleURL in builtInBundles {
                do {
                    try loadPlugin(at: bundleURL)
                } catch {
                    logger.error("Failed to load built-in plugin \(bundleURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    func sortedPluginBundleURLs(_ urls: [URL], isBundledSource: Bool) -> [URL] {
        // Read each manifest once per scan. Sorting must not repeatedly perform
        // file IO and JSON decoding, and later scans must see changed settings.
        let candidates = urls.map { url in
            (url: url, metadata: pluginBundleSortMetadata(for: url, isBundledSource: isBundledSource))
        }
        return candidates.sorted { lhs, rhs in
            let left = lhs.metadata
            let right = rhs.metadata

            if left.isEnabled != right.isEnabled {
                return left.isEnabled && !right.isEnabled
            }

            if left.sortName != right.sortName {
                return left.sortName < right.sortName
            }

            return lhs.url.path < rhs.url.path
        }.map(\.url)
    }

    private func pluginBundleSortMetadata(for url: URL, isBundledSource: Bool) -> (isEnabled: Bool, sortName: String) {
        let manifestURL = url.appendingPathComponent("Contents/Resources/manifest.json")

        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
            return (isBundledSource, url.lastPathComponent.lowercased())
        }

        let enabledKey = "plugin.\(manifest.id).enabled"
        let isEnabled = (UserDefaults.standard.object(forKey: enabledKey) as? Bool)
            ?? (isBundledSource && manifest.category != "post-processor")
        return (isEnabled, url.lastPathComponent.lowercased())
    }

    func loadPlugin(at url: URL) throws {
        let manifestURL = url.appendingPathComponent("Contents/Resources/manifest.json")
        let isBundledSource = builtInPluginsURL.map {
            url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL
                == $0.resolvingSymlinksInPath().standardizedFileURL
        } ?? false
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            logger.error("Failed to read manifest from \(url.lastPathComponent): \(error.localizedDescription)")
            throw error
        }

        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            logger.error("Invalid manifest in \(url.lastPathComponent): \(error.localizedDescription)")
            throw error
        }

        if !isManifestCompatible(manifest) {
            let architecture = RuntimeArchitecture.current
            let reason = PluginCompatibility.incompatibilityReason(
                minOSVersion: manifest.minOSVersion,
                supportedArchitectures: manifest.supportedArchitectures,
                architecture: architecture
            ) ?? "is not compatible with this Mac"
            logger.info(
                "Skipping plugin \(manifest.id, privacy: .public) on \(architecture, privacy: .public): \(reason, privacy: .public)"
            )
            return
        }

        if !isManifestSDKCompatible(manifest, isBundled: isBundledSource) {
            let reason = PluginSDKCompatibility.incompatibilityReason(
                manifestVersion: manifest.sdkCompatibilityVersion,
                isBundled: isBundledSource
            ) ?? "is not compatible with this dictum build"
            logger.info(
                "Skipping plugin \(manifest.id, privacy: .public): \(reason, privacy: .public)"
            )
            return
        }

        if let minHostVersion = manifest.minHostVersion {
            if PluginVersion.compare(minHostVersion, AppConstants.pluginHostVersion) == .orderedDescending {
                throw PluginLoadError.incompatibleHostVersion(
                    pluginName: manifest.name,
                    required: minHostVersion,
                    current: AppConstants.pluginHostVersion
                )
            }
        }

        let isEnabled = resolvedEnabledState(for: manifest, isBundledSource: isBundledSource)
        // A plugin the managed settings refuse is registered like a disabled one: none of its code runs.
        let policyRefusal = providerPolicy.packageRefusal(for: manifest)

        if let existingIndex = loadedPlugins.firstIndex(where: { $0.manifest.id == manifest.id }) {
            let existing = loadedPlugins[existingIndex]
            guard shouldReplace(existing: existing, with: manifest, from: url) else {
                logger.warning("Plugin \(manifest.id) already loaded from preferred source, skipping \(url.lastPathComponent)")
                return
            }

            PluginSettingsWindowManager.shared.closeWindow(for: manifest.id)
            if existing.isEnabled {
                existing.instance.deactivate()
            }
            loadedPlugins.remove(at: existingIndex)
            logger.info("Replacing plugin \(manifest.id) from \(existing.sourceURL.lastPathComponent) with \(url.lastPathComponent)")
        }

        // Only the copy that is registered decides the plugin's refusal; a skipped copy must not change it.
        if let policyRefusal {
            policyRefusals[manifest.id] = policyRefusal
        } else if policyRefusals[manifest.id] != nil {
            policyRefusals.removeValue(forKey: manifest.id)
        }

        if !isEnabled || policyRefusal != nil {
            let unloaded = try makeUnloadedPluginRecord(manifest: manifest, sourceURL: url)
            loadedPlugins.append(unloaded)
            logger.info("Registered disabled plugin without loading bundle: \(manifest.name) v\(manifest.version)")
            return
        }

        guard let bundle = Bundle(url: url) else {
            logger.error("Failed to create Bundle for \(url.lastPathComponent)")
            throw PluginLoadError.failedToCreateBundle(bundleName: url.lastPathComponent)
        }

        // Mapping the executable dominates launch cost for large local-model bundles.
        let signposter = LaunchSignposts.signposter
        let instance = try signposter.withIntervalSignpost(
            "Plugin.load",
            id: signposter.makeSignpostID(),
            "\(manifest.id, privacy: .public)"
        ) {
            try runtimeLoader.principalClass(bundle, manifest).init()
        }

        let loaded = LoadedPlugin(
            manifest: manifest, instance: instance, bundle: bundle, sourceURL: url, isEnabled: isEnabled,
            builtInPluginsURL: builtInPluginsURL
        )
        loadedPlugins.append(loaded)

        if isEnabled {
            activatePlugin(loaded)
        }

        logger.info("Loaded plugin: \(manifest.name) v\(manifest.version)")
    }

    private func resolvedEnabledState(for manifest: PluginManifest, isBundledSource: Bool) -> Bool {
        if AppConstants.isScreenshotAutomation,
           AppConstants.screenshotPluginId == manifest.id {
            return true
        }

        let enabledKey = "plugin.\(manifest.id).enabled"
        if let stored = UserDefaults.standard.object(forKey: enabledKey) as? Bool {
            return stored
        }

        if isBundledSource && manifest.category != "post-processor" {
            UserDefaults.standard.set(true, forKey: enabledKey)
            return true
        }

        return false
    }

    private func makeUnloadedPluginRecord(
        manifest: PluginManifest,
        sourceURL: URL,
        isEnabled: Bool = false
    ) throws -> LoadedPlugin {
        guard let bundle = Bundle(url: sourceURL) else {
            throw PluginLoadError.failedToCreateBundle(bundleName: sourceURL.lastPathComponent)
        }
        // An unread bundle whose folder is removed later stays in Bundle.allBundles
        // without a resource URL, and MLX aborts on it while looking for its metallib.
        _ = bundle.resourceURL

        return LoadedPlugin(
            manifest: manifest,
            instance: UnloadedPluginPlaceholder(),
            bundle: bundle,
            sourceURL: sourceURL,
            isEnabled: isEnabled,
            builtInPluginsURL: builtInPluginsURL
        )
    }

    func registerUnloadedPlugin(manifest: PluginManifest, sourceURL: URL, isEnabled: Bool) throws {
        if let existingIndex = loadedPlugins.firstIndex(where: { $0.manifest.id == manifest.id }) {
            loadedPlugins.remove(at: existingIndex)
        }

        loadedPlugins.append(try makeUnloadedPluginRecord(
            manifest: manifest,
            sourceURL: sourceURL,
            isEnabled: isEnabled
        ))
        UserDefaults.standard.set(isEnabled, forKey: "plugin.\(manifest.id).enabled")
        logger.info("Registered plugin \(manifest.id, privacy: .public) v\(manifest.version, privacy: .public) as restart-required unloaded placeholder")
    }

    func setRuleNamesProvider(_ provider: @escaping @MainActor () -> [String]) {
        self.ruleNamesProvider = provider
    }

    func setWorkflowProvider(_ provider: @escaping @MainActor () -> [PluginWorkflowInfo]) {
        self.workflowProvider = provider
    }

    private func activatePlugin(_ plugin: LoadedPlugin) {
        let signposter = LaunchSignposts.signposter
        let activationState = signposter.beginInterval(
            "Plugin.activate",
            id: signposter.makeSignpostID(),
            "\(plugin.manifest.id, privacy: .public)"
        )
        defer { signposter.endInterval("Plugin.activate", activationState) }

        let host = HostServicesImpl(
            pluginId: plugin.manifest.id,
            locality: plugin.manifest.resolvedLocality,
            eventBus: EventBus.shared,
            ruleNamesProvider: ruleNamesProvider,
            workflowProvider: workflowProvider,
            backsSelectedTranscriptionEngine: Self.selectionMatcher(
                forEnginesExposedBy: transcriptionProviderIds(exposedBy: plugin.instance)
            )
        )
        host.performPluginActivation(suppressPassiveLoadedModelRestore: shouldSuppressPassiveLoadedModelRestore(for: plugin)) {
            plugin.instance.activate(host: host)
        }
        rememberProviderIds(of: plugin)
        logger.info("Activated plugin: \(plugin.manifest.id)")
    }

    /// Builds the predicate a host uses to decide whether it backs the selected
    /// engine. Re-reads `selectedEngine` on EVERY call.
    ///
    /// *** WHY A CLOSURE OVER A CAPTURED SET, AND NOT A CAPTURED Bool. ***
    /// `selectProvider` writes `selectedEngine` at any time and notifies no
    /// existing host, and at startup `restoreProviderSelection()` runs AFTER
    /// `scanAndLoadPlugins()`, so a Bool decided during activation can be stale
    /// before launch finishes. The exposed ids ARE captured, because they are a
    /// plain value: this manager is `@MainActor` while `HostServicesImpl` is
    /// `@unchecked Sendable` and plugins read the property from arbitrary
    /// contexts, so the closure must capture no actor-isolated state.
    ///
    /// One case deliberately keeps the previous behaviour: a plugin exposing no
    /// transcription engines has no engine-backing model to restore.
    ///
    /// An ABSENT selection now suppresses rather than permits. An earlier revision
    /// permitted it, reasoning that an unrecorded selection is not evidence a plugin
    /// is unselected. That is true in isolation and wrong here, because the absent
    /// case is exactly the startup window in which a restore gets spawned that no
    /// later selection can cancel.
    /// `nonisolated` deliberately: this manager is `@MainActor`, but the returned
    /// predicate is read by plugins from arbitrary contexts, so the builder must
    /// touch no actor-isolated state. The compiler enforces that here, which is why
    /// the closure captures a plain `Set` rather than the manager or the plugin.
    /// The engine dictation uses while the saved one is unavailable (#1533). It
    /// lives in memory only, so the saved choice stays intact, and the matcher
    /// treats it as the selected engine until the saved one is usable again.
    nonisolated static let temporaryFallbackEngine = OSAllocatedUnfairLock<String?>(initialState: nil)

    nonisolated static func selectionMatcher(
        forEnginesExposedBy exposed: Set<String>,
        defaults: @autoclosure @escaping @Sendable () -> UserDefaults = .standard
    ) -> @Sendable () -> Bool {
        {
            // A plugin exposing no transcription engines has no engine-backing model
            // to restore, so it keeps its previous behaviour entirely.
            guard !exposed.isEmpty else { return true }
            // NO SELECTION RECORDED => SUPPRESS, not permit.
            //
            // Passive restore exists to reload the model for the engine you use. If
            // no engine is selected there is no such engine, so nothing should be
            // restored on its behalf.
            //
            // This also closes the startup window. `restoreProviderSelection()` runs
            // AFTER `scanAndLoadPlugins()` and WRITES a selection when the saved one
            // is missing or no longer usable, and a selection written then cannot
            // cancel a restore task that activation has already spawned. Permitting
            // during that window is what let an unselected engine's model load.
            guard let selected = temporaryFallbackEngine.withLock({ $0 })
                    ?? defaults().string(forKey: UserDefaultsKeys.selectedEngine),
                  !selected.isEmpty
            else { return false }
            return exposed.contains(selected)
        }
    }

    func backsSelectedTranscriptionEngine(_ plugin: LoadedPlugin) -> Bool {
        Self.selectionMatcher(
            forEnginesExposedBy: transcriptionProviderIds(exposedBy: plugin.instance)
        )()
    }

    func shouldSuppressPassiveLoadedModelRestore(for plugin: LoadedPlugin) -> Bool {
        guard !plugin.isBundled else { return false }
        return !(plugin.instance is any HostModelLifecyclePolicyAwarePlugin)
    }

    @available(*, deprecated, renamed: "setRuleNamesProvider")
    func setProfileNamesProvider(_ provider: @escaping @MainActor () -> [String]) {
        setRuleNamesProvider(provider)
    }

    func setPluginEnabled(_ pluginId: String, enabled: Bool) {
        guard let index = loadedPlugins.firstIndex(where: { $0.manifest.id == pluginId }) else { return }
        if enabled, let refusal = policyRefusals[pluginId] {
            logger.info("Refused enabling \(pluginId, privacy: .public): \(refusal, privacy: .public)")
            return
        }

        UserDefaults.standard.set(enabled, forKey: "plugin.\(pluginId).enabled")

        if enabled {
            if loadedPlugins[index].isRuntimeLoaded {
                loadedPlugins[index].isEnabled = true
                activatePlugin(loadedPlugins[index])
                UserDefaults.standard.removeObject(forKey: Self.disabledEngineIdsKey(pluginId))
                return
            }

            let unloaded = loadedPlugins.remove(at: index)
            do {
                try loadPlugin(at: unloaded.sourceURL)
                // Kept until the plugin is back, so a failed enable can still be uninstalled cleanly.
                UserDefaults.standard.removeObject(forKey: Self.disabledEngineIdsKey(pluginId))
            } catch {
                logger.error("Failed to enable plugin \(pluginId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                UserDefaults.standard.set(false, forKey: "plugin.\(pluginId).enabled")
                loadedPlugins.insert(unloaded, at: index)
            }
        } else {
            // If the deactivated plugin was selected as default engine, fall back to first available
            var disabledProviderIds = transcriptionProviderIds(exposedBy: loadedPlugins[index].instance)
            // An update that waits for a relaunch exposes no engines either.
            if disabledProviderIds.isEmpty {
                disabledProviderIds = providerIdsAwaitingRelaunch[pluginId] ?? []
            }
            PluginSettingsWindowManager.shared.closeWindow(for: pluginId)
            selectFallbackTranscriptionProviderIfNeeded(disabling: disabledProviderIds)
            // The placeholder of a disabled plugin exposes no engines; uninstalling
            // it must still know them.
            if !disabledProviderIds.isEmpty {
                UserDefaults.standard.set(disabledProviderIds.sorted(), forKey: Self.disabledEngineIdsKey(pluginId))
            }

            let plugin = loadedPlugins[index]
            if plugin.isRuntimeLoaded {
                plugin.instance.deactivate()
            }

            do {
                loadedPlugins[index] = try makeUnloadedPluginRecord(
                    manifest: plugin.manifest,
                    sourceURL: plugin.sourceURL
                )
                logger.info("Deactivated plugin: \(pluginId)")
            } catch {
                logger.error("Failed to convert disabled plugin \(pluginId, privacy: .public) into unloaded placeholder: \(error.localizedDescription, privacy: .public)")
                loadedPlugins[index].isEnabled = false
            }
        }
    }

    static func disabledEngineIdsKey(_ pluginId: String) -> String {
        "plugin.\(pluginId).disabledTranscriptionEngineIds"
    }

    func transcriptionProviderIds(exposedBy pluginInstance: TypeWhisperPlugin) -> Set<String> {
        var providerIds = Set<String>()
        if let engine = pluginInstance as? TranscriptionEnginePlugin {
            providerIds.insert(engine.providerId)
        }
        if let expanded = pluginInstance as? AdditionalTranscriptionEnginesProviding {
            for engine in expanded.additionalTranscriptionEngines {
                providerIds.insert(engine.providerId)
            }
        }
        return providerIds
    }

    func selectFallbackTranscriptionProviderIfNeeded(disabling disabledProviderIds: Set<String>) {
        guard !disabledProviderIds.isEmpty,
              let selectedProvider = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine),
              disabledProviderIds.contains(selectedProvider) else { return }

        if let fallbackProviderId = fallbackTranscriptionProviderId(disabling: disabledProviderIds) {
            ServiceContainer.shared.modelManagerService.selectProvider(fallbackProviderId)
        } else {
            ServiceContainer.shared.modelManagerService.clearProviderSelection()
        }
    }

    func fallbackTranscriptionProviderId(disabling disabledProviderIds: Set<String>) -> String? {
        guard !disabledProviderIds.isEmpty,
              let selectedProvider = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine),
              disabledProviderIds.contains(selectedProvider) else { return nil }

        return transcriptionEngines.first {
            !disabledProviderIds.contains($0.providerId) && $0.isConfigured
        }?.providerId
    }

    /// Notify observers that plugin state changed (e.g. a model was loaded/unloaded)
    func notifyPluginStateChanged() {
        readinessRevision += 1
    }

    func deleteDownloadedModel(pluginId: String, modelId: String) async throws {
        guard let plugin = loadedPlugins.first(where: { $0.manifest.id == pluginId }) else {
            throw PluginModelManagementError.pluginNotFound
        }
        guard plugin.isRuntimeLoaded else {
            throw PluginModelManagementError.pluginNotLoaded(plugin.manifest.name)
        }
        guard let modelManager = plugin.instance as? any PluginDownloadedModelManaging else {
            throw PluginModelManagementError.unsupported(plugin.manifest.name)
        }
        if let activityReporter = plugin.instance as? any PluginSettingsActivityReporting,
           let activity = activityReporter.currentSettingsActivity,
           !activity.isError {
            throw PluginModelManagementError.pluginBusy(plugin.manifest.name)
        }
        guard modelManager.downloadedModels.contains(where: { $0.id == modelId }) else {
            throw PluginModelManagementError.modelNotFound(modelId)
        }
        guard deletingModelPluginIds.insert(pluginId).inserted else {
            throw PluginModelManagementError.pluginBusy(plugin.manifest.name)
        }
        defer {
            deletingModelPluginIds.remove(pluginId)
        }

        try await modelManager.deleteDownloadedModel(modelId)

        if modelManager.downloadedModels.isEmpty, disablesWithoutDownloadedModels(plugin) {
            setPluginEnabled(pluginId, enabled: false)
        } else {
            notifyPluginStateChanged()
        }
    }

    /// Whether deleting a plugin's last downloaded model also disables it.
    /// A transcription plugin stays enabled and keeps the saved dictation
    /// engine; it is only not ready until a model is downloaded again (#1559).
    func disablesWithoutDownloadedModels(_ plugin: LoadedPlugin) -> Bool {
        transcriptionProviderIds(exposedBy: plugin.instance).isEmpty
    }

    // MARK: - Dynamic Plugin Management

    /// Removes a plugin from the active runtime registry without unmapping its executable code.
    /// SwiftUI and AppKit may retain plugin-defined view metadata beyond the visible window's
    /// lifetime, so calling `Bundle.unload()` while the app is running is not safe.
    /// Engine ids of an uninstalled plugin. Choices of these engines are
    /// forgotten; an update or disabling the plugin keeps them.
    let uninstalledTranscriptionEngines = PassthroughSubject<Set<String>, Never>()

    /// Engine ids of plugins unloaded for an update, kept until the update is
    /// gone or replaced, because the placeholder that stands in exposes none.
    private var providerIdsAwaitingRelaunch: [String: Set<String>] = [:]

    /// - Parameter keepsSavedEngine: Pass `true` when the plugin comes straight
    ///   back, as during an update. The saved dictation engine then stays, and
    ///   `restoreProviderSelection()` bridges the gap with a temporary fallback
    ///   (#1533). Disabling and uninstalling replace it, as the user asked for.
    func unloadPlugin(_ pluginId: String, keepsSavedEngine: Bool = false) {
        guard let index = loadedPlugins.firstIndex(where: { $0.manifest.id == pluginId }) else { return }
        let plugin = loadedPlugins[index]
        // An update can leave a restart-required placeholder that exposes no
        // engines, a disabled plugin exposes none either, and an earlier version
        // can name engines the current one dropped; uninstalling covers them all.
        let disabledProviderIds = transcriptionProviderIds(exposedBy: plugin.instance)
            .union(providerIdsAwaitingRelaunch[pluginId] ?? [])
            .union(UserDefaults.standard.stringArray(forKey: Self.disabledEngineIdsKey(pluginId)) ?? [])

        PluginSettingsWindowManager.shared.closeWindow(for: pluginId)
        if keepsSavedEngine {
            if !disabledProviderIds.isEmpty {
                providerIdsAwaitingRelaunch[pluginId] = disabledProviderIds
            }
        } else {
            providerIdsAwaitingRelaunch[pluginId] = nil
            UserDefaults.standard.removeObject(forKey: Self.disabledEngineIdsKey(pluginId))
            // An uninstalled plugin no longer explains a refusal of the providers it exposed.
            policyRefusals.removeValue(forKey: pluginId)
            UserDefaults.standard.removeObject(forKey: Self.knownProviderIdsKey(pluginId))
            UserDefaults.standard.removeObject(forKey: Self.knownModelIdsKey(pluginId))
            selectFallbackTranscriptionProviderIfNeeded(disabling: disabledProviderIds)
            if !disabledProviderIds.isEmpty {
                uninstalledTranscriptionEngines.send(disabledProviderIds)
            }
        }

        if plugin.isEnabled && plugin.isRuntimeLoaded {
            plugin.instance.deactivate()
        }
        loadedPlugins.remove(at: index)
        logger.info("Removed plugin from runtime registry: \(pluginId)")
    }


    func bundleURL(for pluginId: String) -> URL? {
        loadedPlugins.first { $0.manifest.id == pluginId }?.sourceURL
    }

    private func shouldReplace(existing: LoadedPlugin, with incomingManifest: PluginManifest, from incomingURL: URL) -> Bool {
        let incomingIsBundled = builtInPluginsURL.map {
            incomingURL.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL
                == $0.resolvingSymlinksInPath().standardizedFileURL
        } ?? false
        let versionComparison = PluginVersion.compare(incomingManifest.version, existing.manifest.version)

        if incomingIsBundled != existing.isBundled {
            if incomingIsBundled {
                return versionComparison != .orderedAscending
            }
            return versionComparison == .orderedDescending
        }

        return versionComparison == .orderedDescending
    }
}
