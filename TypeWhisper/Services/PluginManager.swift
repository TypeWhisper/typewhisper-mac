import AppKit
import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PluginManager")

// MARK: - Plugin Manifest

struct PluginManifest: Codable {
    let id: String
    let name: String
    let version: String
    let minHostVersion: String?
    let minOSVersion: String?
    let author: String?
    let principalClass: String
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

    init() {
        self.pluginsDirectory = AppConstants.appSupportDirectory
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
            loadPlugin(at: bundleURL)
        }

        // Built-in plugins from app bundle
        if let builtInURL = Bundle.main.builtInPlugInsURL,
           let builtIn = try? fm.contentsOfDirectory(at: builtInURL, includingPropertiesForKeys: nil) {
            let builtInBundles = builtIn.filter { $0.pathExtension == "bundle" }
            logger.info("Found \(builtInBundles.count) built-in plugin bundle(s)")
            for bundleURL in builtInBundles {
                loadPlugin(at: bundleURL)
            }
        }
    }

    func loadPlugin(at url: URL) {
        let manifestURL = url.appendingPathComponent("Contents/Resources/manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
            logger.error("Failed to read manifest from \(url.lastPathComponent)")
            return
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

        guard !loadedPlugins.contains(where: { $0.manifest.id == manifest.id }) else {
            logger.warning("Plugin \(manifest.id) already loaded, skipping")
            return
        }

        guard let bundle = Bundle(url: url) else {
            logger.error("Failed to create Bundle for \(url.lastPathComponent)")
            return
        }

        do {
            try bundle.loadAndReturnError()
        } catch {
            logger.error("Failed to load bundle \(url.lastPathComponent): \(error.localizedDescription)")
            return
        }

        guard let pluginClass = NSClassFromString(manifest.principalClass) as? TypeWhisperPlugin.Type else {
            logger.error("Failed to find class \(manifest.principalClass) in \(url.lastPathComponent)")
            return
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
}
