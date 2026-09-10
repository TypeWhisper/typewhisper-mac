import AppKit
import Foundation
import SwiftUI
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PluginManager")

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
            return "\(pluginName) requires TypeWhisper \(required) or newer (current: \(current))"
        case .failedToCreateBundle(let bundleName):
            return "Failed to create bundle for \(bundleName)"
        case .missingPrincipalClass(let className, let bundleName):
            return "Failed to find class \(className) in \(bundleName)"
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

    var id: String { manifest.id }

    var isBundled: Bool {
        guard let builtInURL = Bundle.main.builtInPlugInsURL else { return false }
        return sourceURL.path.hasPrefix(builtInURL.path)
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

struct IncompatibleExternalBundle: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case sdkCompatibility(expected: String, actual: String?)
    }

    let pluginId: String
    let pluginName: String
    let version: String
    let bundleURL: URL
    let reason: Reason
}

extension IncompatibleExternalBundle.Reason {
    var diagnosticsValue: String {
        switch self {
        case .sdkCompatibility(let expected, let actual):
            if let actual {
                return "sdkCompatibility:expected=\(expected),actual=\(actual)"
            }
            return "sdkCompatibility:expected=\(expected),actual=missing"
        }
    }
}

enum ExternalBundleNotice: Equatable {
    case legacyBundlePresent(version: String)
    case incompatibleWithCurrentRuntime(version: String)
    case bundledFallbackActive(version: String)
    case boundaryUpgradeRequired(installedVersion: String, availableVersion: String)

    var requiresConfirmation: Bool {
        if case .boundaryUpgradeRequired = self {
            return true
        }
        return false
    }

    var diagnosticsValue: String {
        switch self {
        case .legacyBundlePresent(let version):
            return "legacyBundlePresent:version=\(version)"
        case .incompatibleWithCurrentRuntime(let version):
            return "incompatibleWithCurrentRuntime:version=\(version)"
        case .bundledFallbackActive(let version):
            return "bundledFallbackActive:version=\(version)"
        case .boundaryUpgradeRequired(let installedVersion, let availableVersion):
            return "boundaryUpgradeRequired:installed=\(installedVersion),available=\(availableVersion)"
        }
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
struct PluginUserInterfaceContribution {
    let pluginId: String
    let pluginName: String
    let provider: any PluginUserInterfaceProviding
    let appMenuCommands: [PluginCommandDescriptor]
    let primaryMenuBarCommands: [PluginCommandDescriptor]
    let settingsSidebarItems: [PluginSettingsSidebarItemDescriptor]

    var allCommands: [PluginCommandDescriptor] {
        appMenuCommands + primaryMenuBarCommands
    }
}

@MainActor
final class PluginManager: ObservableObject {
    nonisolated(unsafe) static var shared: PluginManager!

    @Published var loadedPlugins: [LoadedPlugin] = []
    @Published private(set) var incompatibleExternalBundles: [String: IncompatibleExternalBundle] = [:]
    @Published private(set) var readinessRevision = 0

    let pluginsDirectory: URL
    private var ruleNamesProvider: @MainActor () -> [String] = { [] }
    private var workflowProvider: @MainActor () -> [PluginWorkflowInfo] = { [] }
    private var deletingModelPluginIds = Set<String>()

    var userInterfaceContributions: [PluginUserInterfaceContribution] {
        loadedPlugins.compactMap { plugin in
            guard plugin.isEnabled,
                  let provider = plugin.instance as? any PluginUserInterfaceProviding else {
                return nil
            }
            return PluginUserInterfaceContribution(
                pluginId: plugin.manifest.id,
                pluginName: plugin.manifest.name,
                provider: provider,
                appMenuCommands: provider.appMenuCommands,
                primaryMenuBarCommands: provider.primaryMenuBarCommands,
                settingsSidebarItems: provider.settingsSidebarItems
            )
        }
    }

    func settingsSidebarView(pluginId: String, itemId: String) -> AnyView? {
        guard let contribution = userInterfaceContributions.first(where: { $0.pluginId == pluginId }),
              contribution.settingsSidebarItems.contains(where: { $0.id == itemId }) else {
            return nil
        }
        return contribution.provider.settingsSidebarView(for: itemId)
    }

    @discardableResult
    func performPluginCommand(pluginId: String, commandId: String) -> Bool {
        guard let contribution = userInterfaceContributions.first(where: { $0.pluginId == pluginId }),
              contribution.allCommands.contains(where: { $0.id == commandId && $0.isEnabled }) else {
            return false
        }
        contribution.provider.performPluginCommand(commandId)
        return true
    }

    var postProcessors: [PostProcessorPlugin] {
        loadedPlugins
            .filter { $0.isEnabled }
            .compactMap { $0.instance as? PostProcessorPlugin }
            .sorted { $0.priority < $1.priority }
    }

    var fileJobAutomations: [FileJobAutomationPlugin] {
        loadedPlugins
            .filter { $0.isEnabled }
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
            .filter { $0.isEnabled }
            .flatMap { plugin -> [LLMProviderPlugin] in
                var providers: [LLMProviderPlugin] = []
                if let provider = plugin.instance as? LLMProviderPlugin {
                    providers.append(provider)
                }
                if let expanded = plugin.instance as? AdditionalLLMProvidersProviding {
                    providers.append(contentsOf: expanded.additionalLLMProviders)
                }
                return providers
            }
    }

    var ttsProviders: [TTSProviderPlugin] {
        loadedPlugins
            .filter { $0.isEnabled }
            .compactMap { $0.instance as? TTSProviderPlugin }
    }

    var transcriptionEngines: [TranscriptionEnginePlugin] {
        loadedPlugins
            .filter { $0.isEnabled }
            .flatMap { plugin -> [TranscriptionEnginePlugin] in
                var engines: [TranscriptionEnginePlugin] = []
                if let engine = plugin.instance as? TranscriptionEnginePlugin {
                    engines.append(engine)
                }
                if let expanded = plugin.instance as? AdditionalTranscriptionEnginesProviding {
                    engines.append(contentsOf: expanded.additionalTranscriptionEngines)
                }
                return engines
            }
    }

    var actionPlugins: [ActionPlugin] {
        loadedPlugins
            .filter { $0.isEnabled }
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

    var memoryStoragePlugins: [MemoryStoragePlugin] {
        loadedPlugins
            .filter { $0.isEnabled }
            .compactMap { $0.instance as? MemoryStoragePlugin }
    }

    func transcriptionEngine(for providerId: String) -> TranscriptionEnginePlugin? {
        transcriptionEngines.first { $0.providerId == providerId }
    }

    func loadedTranscriptionPlugin(for providerId: String) -> LoadedPlugin? {
        loadedPlugins.first {
            guard $0.isEnabled else { return false }
            if let engine = $0.instance as? TranscriptionEnginePlugin,
               engine.providerId == providerId {
                return true
            }
            if let expanded = $0.instance as? AdditionalTranscriptionEnginesProviding,
               expanded.additionalTranscriptionEngines.contains(where: { $0.providerId == providerId }) {
                return true
            }
            return false
        }
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

    static func externalBundleNotice(
        loadedPlugin: LoadedPlugin?,
        registryPlugin: RegistryPlugin?,
        incompatibleExternalBundle: IncompatibleExternalBundle?
    ) -> ExternalBundleNotice? {
        guard let incompatibleExternalBundle else { return nil }

        if let registryPlugin {
            return .boundaryUpgradeRequired(
                installedVersion: incompatibleExternalBundle.version,
                availableVersion: registryPlugin.version
            )
        }

        if let loadedPlugin, loadedPlugin.isBundled {
            return .bundledFallbackActive(version: incompatibleExternalBundle.version)
        }

        switch incompatibleExternalBundle.reason {
        case .sdkCompatibility(_, let actual):
            if actual == nil {
                return .legacyBundlePresent(version: incompatibleExternalBundle.version)
            }
            return .incompatibleWithCurrentRuntime(version: incompatibleExternalBundle.version)
        }
    }

    func incompatibleExternalBundle(for pluginId: String) -> IncompatibleExternalBundle? {
        incompatibleExternalBundles[pluginId]
    }

    func externalBundleNotice(for pluginId: String, registryPlugin: RegistryPlugin? = nil) -> ExternalBundleNotice? {
        Self.externalBundleNotice(
            loadedPlugin: loadedPlugins.first(where: { $0.manifest.id == pluginId }),
            registryPlugin: registryPlugin,
            incompatibleExternalBundle: incompatibleExternalBundles[pluginId]
        )
    }

    func clearIncompatibleExternalBundle(_ pluginId: String) {
        incompatibleExternalBundles.removeValue(forKey: pluginId)
    }

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        self.pluginsDirectory = appSupportDirectory
            .appendingPathComponent("Plugins", isDirectory: true)

        try? FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Plugin Loading

    func scanAndLoadPlugins() {
        logger.info("Scanning plugins directory: \(self.pluginsDirectory.path)")
        incompatibleExternalBundles = [:]

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: pluginsDirectory, includingPropertiesForKeys: nil) else {
            logger.info("No plugins directory or empty")
            return
        }

        let bundles = sortedPluginBundleURLs(
            contents.filter { $0.pathExtension == "bundle" },
            isBundledSource: false
        )
        logger.info("Found \(bundles.count) plugin bundle(s)")

        for bundleURL in bundles {
            do {
                try loadPlugin(at: bundleURL)
            } catch {
                logger.error("Failed to load plugin at \(bundleURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Built-in plugins from app bundle
        if let builtInURL = Bundle.main.builtInPlugInsURL,
           let builtIn = try? fm.contentsOfDirectory(at: builtInURL, includingPropertiesForKeys: nil) {
            let builtInBundles = sortedPluginBundleURLs(
                builtIn.filter { $0.pathExtension == "bundle" },
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
        let isEnabled = (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? isBundledSource
        return (isEnabled, url.lastPathComponent.lowercased())
    }

    func loadPlugin(at url: URL) throws {
        let manifestURL = url.appendingPathComponent("Contents/Resources/manifest.json")
        let isBundledSource = Bundle.main.builtInPlugInsURL.map { url.path.hasPrefix($0.path) } ?? false
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

        guard ScreenshotPluginSourcePolicy.allowsCandidate(
            isScreenshotAutomation: AppConstants.isScreenshotAutomation,
            selectedPluginId: AppConstants.screenshotPluginId,
            manifestId: manifest.id,
            isBundledSource: isBundledSource,
            isIsolatedScreenshotSource: url.deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .standardizedFileURL == pluginsDirectory
                .resolvingSymlinksInPath()
                .standardizedFileURL
        ) else {
            logger.info("Skipping external screenshot plugin candidate \(manifest.id, privacy: .public)")
            return
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
            if !isBundledSource {
                incompatibleExternalBundles[manifest.id] = IncompatibleExternalBundle(
                    pluginId: manifest.id,
                    pluginName: manifest.name,
                    version: manifest.version,
                    bundleURL: url,
                    reason: .sdkCompatibility(
                        expected: PluginSDKCompatibility.currentVersion,
                        actual: manifest.sdkCompatibilityVersion
                    )
                )
            }
            let reason = PluginSDKCompatibility.incompatibilityReason(
                manifestVersion: manifest.sdkCompatibilityVersion,
                isBundled: isBundledSource
            ) ?? "is not compatible with this TypeWhisper build"
            logger.info(
                "Skipping plugin \(manifest.id, privacy: .public): \(reason, privacy: .public)"
            )
            return
        }

        if !isBundledSource {
            incompatibleExternalBundles.removeValue(forKey: manifest.id)
        }

        if let minHostVersion = manifest.minHostVersion {
            let currentAppVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
            if PluginRegistryService.compareVersions(minHostVersion, currentAppVersion) == .orderedDescending {
                throw PluginLoadError.incompatibleHostVersion(
                    pluginName: manifest.name,
                    required: minHostVersion,
                    current: currentAppVersion
                )
            }
        }

        let isEnabled = resolvedEnabledState(for: manifest, isBundledSource: isBundledSource)

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

        if !isEnabled {
            let unloaded = try makeUnloadedPluginRecord(manifest: manifest, sourceURL: url)
            loadedPlugins.append(unloaded)
            logger.info("Registered disabled plugin without loading bundle: \(manifest.name) v\(manifest.version)")
            return
        }

        guard let bundle = Bundle(url: url) else {
            logger.error("Failed to create Bundle for \(url.lastPathComponent)")
            throw PluginLoadError.failedToCreateBundle(bundleName: url.lastPathComponent)
        }

        do {
            try bundle.loadAndReturnError()
        } catch {
            logger.error("Failed to load bundle \(url.lastPathComponent): \(error.localizedDescription)")
            throw error
        }

        guard let pluginClass = NSClassFromString(manifest.principalClass) as? TypeWhisperPlugin.Type else {
            let error = PluginLoadError.missingPrincipalClass(
                className: manifest.principalClass,
                bundleName: url.lastPathComponent
            )
            logger.error("\(error.localizedDescription, privacy: .public)")
            throw error
        }

        let instance = pluginClass.init()

        let loaded = LoadedPlugin(
            manifest: manifest, instance: instance, bundle: bundle, sourceURL: url, isEnabled: isEnabled
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

        if isBundledSource {
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

        return LoadedPlugin(
            manifest: manifest,
            instance: UnloadedPluginPlaceholder(),
            bundle: bundle,
            sourceURL: sourceURL,
            isEnabled: isEnabled
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
        let host = HostServicesImpl(
            pluginId: plugin.manifest.id,
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
            guard let selected = defaults().string(forKey: UserDefaultsKeys.selectedEngine),
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

        UserDefaults.standard.set(enabled, forKey: "plugin.\(pluginId).enabled")

        if enabled {
            if loadedPlugins[index].isRuntimeLoaded {
                loadedPlugins[index].isEnabled = true
                activatePlugin(loadedPlugins[index])
                return
            }

            let unloaded = loadedPlugins.remove(at: index)
            do {
                try loadPlugin(at: unloaded.sourceURL)
            } catch {
                logger.error("Failed to enable plugin \(pluginId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                UserDefaults.standard.set(false, forKey: "plugin.\(pluginId).enabled")
                loadedPlugins.insert(unloaded, at: index)
            }
        } else {
            // If the deactivated plugin was selected as default engine, fall back to first available
            let disabledProviderIds = transcriptionProviderIds(exposedBy: loadedPlugins[index].instance)
            PluginSettingsWindowManager.shared.closeWindow(for: pluginId)
            selectFallbackTranscriptionProviderIfNeeded(disabling: disabledProviderIds)

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

    func openPluginsFolder() {
        NSWorkspace.shared.open(pluginsDirectory)
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

        if modelManager.downloadedModels.isEmpty {
            setPluginEnabled(pluginId, enabled: false)
        } else {
            notifyPluginStateChanged()
        }
    }

    // MARK: - Dynamic Plugin Management

    /// Removes a plugin from the active runtime registry without unmapping its executable code.
    /// SwiftUI and AppKit may retain plugin-defined view metadata beyond the visible window's
    /// lifetime, so calling `Bundle.unload()` while the app is running is not safe.
    func unloadPlugin(_ pluginId: String) {
        guard let index = loadedPlugins.firstIndex(where: { $0.manifest.id == pluginId }) else { return }
        let plugin = loadedPlugins[index]
        let disabledProviderIds = transcriptionProviderIds(exposedBy: plugin.instance)

        PluginSettingsWindowManager.shared.closeWindow(for: pluginId)
        selectFallbackTranscriptionProviderIfNeeded(disabling: disabledProviderIds)

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
        let incomingIsBundled = Bundle.main.builtInPlugInsURL.map { incomingURL.path.hasPrefix($0.path) } ?? false
        let versionComparison = PluginRegistryService.compareVersions(incomingManifest.version, existing.manifest.version)

        if incomingIsBundled != existing.isBundled {
            if incomingIsBundled {
                return versionComparison != .orderedAscending
            }
            return versionComparison == .orderedDescending
        }

        return versionComparison == .orderedDescending
    }
}

enum ScreenshotPluginSourcePolicy {
    static func allowsCandidate(
        isScreenshotAutomation: Bool,
        selectedPluginId: String?,
        manifestId: String,
        isBundledSource: Bool,
        isIsolatedScreenshotSource: Bool
    ) -> Bool {
        guard isScreenshotAutomation, selectedPluginId == manifestId else { return true }
        return isBundledSource || isIsolatedScreenshotSource
    }
}
