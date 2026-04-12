import AppKit
import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PluginManager")

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
}

// MARK: - Plugin Manager

@MainActor
final class PluginManager: ObservableObject {
    nonisolated(unsafe) static var shared: PluginManager!

    @Published var loadedPlugins: [LoadedPlugin] = []

    let pluginsDirectory: URL
    private var profileNamesProvider: () -> [String] = { [] }

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

    func actionPlugin(for actionId: String) -> ActionPlugin? {
        actionPlugins.first { $0.actionId == actionId }
    }

    func llmProvider(for providerName: String) -> LLMProviderPlugin? {
        llmProviders.first { $0.providerName.caseInsensitiveCompare(providerName) == .orderedSame }
    }

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        self.pluginsDirectory = appSupportDirectory
            .appendingPathComponent("Plugins", isDirectory: true)

        try? FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Plugin Loading

    func scanAndLoadPlugins() {
        logger.info("Scanning plugins directory: \(self.pluginsDirectory.path)")

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: pluginsDirectory, includingPropertiesForKeys: nil) else {
            logger.info("No plugins directory or empty")
            return
        }

        let bundles = contents.filter { $0.pathExtension == "bundle" }
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
            let builtInBundles = builtIn.filter { $0.pathExtension == "bundle" }
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

    func loadPlugin(at url: URL) throws {
        let manifestURL = url.appendingPathComponent("Contents/Resources/manifest.json")
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

        if let minOS = manifest.minOSVersion {
            let parts = minOS.split(separator: ".").compactMap { Int($0) }
            let required = OperatingSystemVersion(
                majorVersion: parts.count > 0 ? parts[0] : 0,
                minorVersion: parts.count > 1 ? parts[1] : 0,
                patchVersion: parts.count > 2 ? parts[2] : 0
            )
            if !ProcessInfo.processInfo.isOperatingSystemAtLeast(required) {
                logger.info("Plugin \(manifest.name) requires macOS \(minOS), skipping")
                return
            }
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

        let enabledKey = "plugin.\(manifest.id).enabled"
        let isEnabled: Bool
        if let stored = UserDefaults.standard.object(forKey: enabledKey) as? Bool {
            isEnabled = stored
        } else {
            // Auto-enable bundled plugins on first encounter
            let isBundled = Bundle.main.builtInPlugInsURL.map { url.path.hasPrefix($0.path) } ?? false
            isEnabled = isBundled
            if isBundled {
                UserDefaults.standard.set(true, forKey: enabledKey)
            }
        }

        let loaded = LoadedPlugin(
            manifest: manifest, instance: instance, bundle: bundle, sourceURL: url, isEnabled: isEnabled
        )
        loadedPlugins.append(loaded)

        if isEnabled {
            activatePlugin(loaded)
        }

        logger.info("Loaded plugin: \(manifest.name) v\(manifest.version)")
    }

    func setProfileNamesProvider(_ provider: @escaping () -> [String]) {
        self.profileNamesProvider = provider
    }

    private func activatePlugin(_ plugin: LoadedPlugin) {
        let host = HostServicesImpl(pluginId: plugin.manifest.id, eventBus: EventBus.shared, profileNamesProvider: profileNamesProvider)
        plugin.instance.activate(host: host)
        logger.info("Activated plugin: \(plugin.manifest.id)")
    }

    func setPluginEnabled(_ pluginId: String, enabled: Bool) {
        guard let index = loadedPlugins.firstIndex(where: { $0.manifest.id == pluginId }) else { return }

        loadedPlugins[index].isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "plugin.\(pluginId).enabled")

        if enabled {
            activatePlugin(loadedPlugins[index])
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
            loadedPlugins[index].instance.deactivate()
            logger.info("Deactivated plugin: \(pluginId)")
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
        if plugin.isEnabled {
            plugin.instance.deactivate()
        }
        plugin.bundle.unload()
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
