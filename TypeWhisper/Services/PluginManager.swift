import AppKit
import Foundation
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

    var supportsSettingsWindow: Bool {
        isRuntimeLoaded && instance.settingsView != nil
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
}

// MARK: - Plugin Manager

@MainActor
final class PluginManager: ObservableObject {
    nonisolated(unsafe) static var shared: PluginManager!

    @Published var loadedPlugins: [LoadedPlugin] = []
    @Published private(set) var incompatibleExternalBundles: [String: IncompatibleExternalBundle] = [:]

    let pluginsDirectory: URL
    private var ruleNamesProvider: () -> [String] = { [] }

    var postProcessors: [PostProcessorPlugin] {
        loadedPlugins
            .filter { $0.isEnabled }
            .compactMap { $0.instance as? PostProcessorPlugin }
            .sorted { $0.priority < $1.priority }
    }

    var llmProviders: [LLMProviderPlugin] {
        loadedPlugins
            .filter { $0.isEnabled }
            .compactMap { $0.instance as? LLMProviderPlugin }
    }

    var ttsProviders: [TTSProviderPlugin] {
        loadedPlugins
            .filter { $0.isEnabled }
            .compactMap { $0.instance as? TTSProviderPlugin }
    }

    var transcriptionEngines: [TranscriptionEnginePlugin] {
        loadedPlugins
            .filter { $0.isEnabled }
            .compactMap { $0.instance as? TranscriptionEnginePlugin }
    }

    var actionPlugins: [ActionPlugin] {
        loadedPlugins
            .filter { $0.isEnabled }
            .compactMap { $0.instance as? ActionPlugin }
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
            guard let engine = $0.instance as? TranscriptionEnginePlugin else { return false }
            return $0.isEnabled && engine.providerId == providerId
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
        llmProviders.first { $0.providerName.caseInsensitiveCompare(providerName) == .orderedSame }
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
        urls.sorted { lhs, rhs in
            let left = pluginBundleSortMetadata(for: lhs, isBundledSource: isBundledSource)
            let right = pluginBundleSortMetadata(for: rhs, isBundledSource: isBundledSource)

            if left.isEnabled != right.isEnabled {
                return left.isEnabled && !right.isEnabled
            }

            if left.sortName != right.sortName {
                return left.sortName < right.sortName
            }

            return lhs.path < rhs.path
        }
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

            if existing.isEnabled {
                existing.instance.deactivate()
            }
            existing.bundle.unload()
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

    private func makeUnloadedPluginRecord(manifest: PluginManifest, sourceURL: URL) throws -> LoadedPlugin {
        guard let bundle = Bundle(url: sourceURL) else {
            throw PluginLoadError.failedToCreateBundle(bundleName: sourceURL.lastPathComponent)
        }

        return LoadedPlugin(
            manifest: manifest,
            instance: UnloadedPluginPlaceholder(),
            bundle: bundle,
            sourceURL: sourceURL,
            isEnabled: false
        )
    }

    func setRuleNamesProvider(_ provider: @escaping () -> [String]) {
        self.ruleNamesProvider = provider
    }

    private func activatePlugin(_ plugin: LoadedPlugin) {
        let host = HostServicesImpl(pluginId: plugin.manifest.id, eventBus: EventBus.shared, ruleNamesProvider: ruleNamesProvider)
        plugin.instance.activate(host: host)
        logger.info("Activated plugin: \(plugin.manifest.id)")
    }

    @available(*, deprecated, renamed: "setRuleNamesProvider")
    func setProfileNamesProvider(_ provider: @escaping () -> [String]) {
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
            if let engine = loadedPlugins[index].instance as? TranscriptionEnginePlugin {
                let selectedProvider = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine)
                if selectedProvider == engine.providerId {
                    let fallback = transcriptionEngines.first(where: { $0.providerId != engine.providerId && $0.isConfigured })
                    if let fallback {
                        ServiceContainer.shared.modelManagerService.selectProvider(fallback.providerId)
                    }
                }
            }

            let plugin = loadedPlugins[index]
            if plugin.isRuntimeLoaded {
                plugin.instance.deactivate()
                plugin.bundle.unload()
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

    func openPluginsFolder() {
        NSWorkspace.shared.open(pluginsDirectory)
    }

    /// Notify observers that plugin state changed (e.g. a model was loaded/unloaded)
    func notifyPluginStateChanged() {
        objectWillChange.send()
    }

    // MARK: - Dynamic Plugin Management

    func unloadPlugin(_ pluginId: String) {
        guard let index = loadedPlugins.firstIndex(where: { $0.manifest.id == pluginId }) else { return }
        let plugin = loadedPlugins[index]
        if plugin.isEnabled && plugin.isRuntimeLoaded {
            plugin.instance.deactivate()
        }
        if plugin.isRuntimeLoaded {
            plugin.bundle.unload()
        }
        loadedPlugins.remove(at: index)
        logger.info("Unloaded plugin: \(pluginId)")
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
