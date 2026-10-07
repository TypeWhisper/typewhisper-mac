#if APPSTORE
import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "AppStorePluginCatalog")

/// The plugin marketplace of the Mac App Store edition.
///
/// App Store apps may not download or load code from outside their signed
/// bundle, so every first-party plugin the edition offers is built into
/// `Contents/PlugIns`. Installing a plugin marks it as installed and loads the
/// bundled copy; uninstalling unloads it and keeps the bundle in place.
/// Plugins that are not installed are never loaded.
enum AppStorePluginCatalog {
    static let downloadURLScheme = "bundled"

    /// Plugins installed on first launch, matching the direct-distribution app.
    static let defaultInstalledPluginIDs: Set<String> = ["com.typewhisper.speechanalyzer"]

    /// Plugins that belong to an app feature rather than the marketplace, as in
    /// the direct-distribution app: always loaded and never listed. Speaker
    /// detection is managed on the Speakers page.
    static let appFeaturePluginIDs: Set<String> = ["com.typewhisper.speaker-diarization"]

    private static let installedPluginIDsKey = "appStore.installedPluginIDs"

    struct Entry: Decodable {
        let id: String
        let bundleName: String
        let name: String
        let author: String
        let description: String
        let descriptions: [String: String]?
        let category: String?
        let categories: [String]?
        let capabilities: [String]?
        let iconSystemName: String?
        let requiresAPIKey: Bool?
        let hosting: PluginHosting?
        let detailsURL: String?
        let homepageURL: String?
        let iconURL: String?
        let iconDarkURL: String?
    }

    private struct Catalog: Decodable {
        let schemaVersion: Int
        let plugins: [Entry]
    }

    // MARK: - Installed State

    static func installedPluginIDs(userDefaults: UserDefaults = .standard) -> Set<String> {
        guard let stored = userDefaults.stringArray(forKey: installedPluginIDsKey) else {
            return defaultInstalledPluginIDs
        }
        return Set(stored)
    }

    static func isInstalled(_ pluginId: String, userDefaults: UserDefaults = .standard) -> Bool {
        appFeaturePluginIDs.contains(pluginId)
            || installedPluginIDs(userDefaults: userDefaults).contains(pluginId)
    }

    static func setInstalled(_ installed: Bool, pluginId: String, userDefaults: UserDefaults = .standard) {
        var ids = installedPluginIDs(userDefaults: userDefaults)
        if installed {
            ids.insert(pluginId)
        } else {
            ids.remove(pluginId)
        }
        userDefaults.set(ids.sorted(), forKey: installedPluginIDsKey)
    }

    /// Whether the plugin bundle at `url` should be loaded during the launch scan.
    static func shouldLoadBundledPlugin(at url: URL, userDefaults: UserDefaults = .standard) -> Bool {
        guard let manifest = manifest(at: url) else { return false }
        return isInstalled(manifest.id, userDefaults: userDefaults)
    }

    // MARK: - Catalog

    static func entries(bundle: Bundle = .main) -> [Entry] {
        guard let url = bundle.url(forResource: "AppStorePluginCatalog", withExtension: "json") else {
            logger.error("AppStorePluginCatalog.json is missing from the app bundle")
            return []
        }
        do {
            return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url)).plugins
        } catch {
            logger.error("Failed to read AppStorePluginCatalog.json: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func bundleURL(for pluginId: String, bundle: Bundle = .main) -> URL? {
        guard let entry = entries(bundle: bundle).first(where: { $0.id == pluginId }) else { return nil }
        return bundle.builtInPlugInsURL?.appendingPathComponent(entry.bundleName, isDirectory: true)
    }

    /// Marketplace entries for every bundled plugin that runs on this Mac.
    static func registryPlugins(bundle: Bundle = .main) -> [RegistryPlugin] {
        entries(bundle: bundle).compactMap { entry in
            guard !appFeaturePluginIDs.contains(entry.id),
                  let pluginsURL = bundle.builtInPlugInsURL else { return nil }
            let bundleURL = pluginsURL.appendingPathComponent(entry.bundleName, isDirectory: true)
            guard let manifest = manifest(at: bundleURL) else {
                logger.error("Bundled plugin \(entry.id, privacy: .public) has no readable manifest")
                return nil
            }
            let categories = PluginManifest.normalizedCategoryIdentifiers(
                primary: entry.category ?? manifest.category,
                categories: entry.categories ?? manifest.categories
            )
            let plugin = RegistryPlugin(
                id: manifest.id,
                source: .official,
                name: entry.name,
                version: manifest.version,
                minHostVersion: manifest.minHostVersion ?? "0.0.0",
                sdkCompatibilityVersion: manifest.sdkCompatibilityVersion,
                minOSVersion: manifest.minOSVersion,
                supportedArchitectures: manifest.supportedArchitectures,
                author: entry.author,
                description: entry.description,
                category: categories.first ?? PluginCategory.utility.rawValue,
                categories: categories,
                capabilities: PluginManifest.normalizedCapabilityIdentifiers(entry.capabilities ?? manifest.capabilities),
                size: bundleSize(at: bundleURL),
                downloadURL: "\(downloadURLScheme)://\(manifest.id)",
                iconSystemName: entry.iconSystemName ?? manifest.iconSystemName,
                requiresAPIKey: entry.requiresAPIKey ?? manifest.requiresAPIKey,
                hosting: entry.hosting ?? manifest.hosting,
                descriptions: entry.descriptions,
                downloadCount: nil,
                detailsURL: entry.detailsURL,
                homepageURL: entry.homepageURL,
                iconURL: entry.iconURL,
                iconDarkURL: entry.iconDarkURL
            )
            return plugin.isCompatibleWithCurrentEnvironment ? plugin : nil
        }
    }

    // MARK: - Helpers

    static func manifest(at bundleURL: URL) -> PluginManifest? {
        let manifestURL = bundleURL.appendingPathComponent("Contents/Resources/manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(PluginManifest.self, from: data)
    }

    private static func bundleSize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }
}

// MARK: - Registry Service

extension PluginRegistryService {
    /// Installs a bundled plugin. Nothing is downloaded: the plugin is marked as
    /// installed and its signed bundle inside the app is loaded.
    func installBundledPlugin(_ plugin: RegistryPlugin) -> Bool {
        guard plugin.isCompatibleWithCurrentEnvironment else {
            installStates[plugin.id] = .error("Plugin is not compatible with this Mac")
            return false
        }
        guard let bundleURL = AppStorePluginCatalog.bundleURL(for: plugin.id) else {
            installStates[plugin.id] = .error("Plugin is not part of this app")
            return false
        }

        AppStorePluginCatalog.setInstalled(true, pluginId: plugin.id)
        if PluginManager.shared.loadedPlugins.contains(where: { $0.manifest.id == plugin.id }) {
            PluginManager.shared.setPluginEnabled(plugin.id, enabled: true)
            installStates.removeValue(forKey: plugin.id)
            return true
        }
        UserDefaults.standard.set(true, forKey: "plugin.\(plugin.id).enabled")

        do {
            try PluginManager.shared.loadPlugin(at: bundleURL)
            installStates.removeValue(forKey: plugin.id)
            updateAvailableUpdatesCount()
            logger.info("Installed bundled plugin \(plugin.id, privacy: .public)")
            return true
        } catch {
            AppStorePluginCatalog.setInstalled(false, pluginId: plugin.id)
            installStates[plugin.id] = .error(error.localizedDescription)
            logger.error("Failed to install bundled plugin \(plugin.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
#endif
