import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PluginRegistry")

enum PluginDownloadError: LocalizedError {
    case httpStatus(Int)
    case unexpectedContentType(String?)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let statusCode):
            return "Plugin download failed with HTTP \(statusCode)"
        case .unexpectedContentType(let mimeType):
            if let mimeType, !mimeType.isEmpty {
                return "Plugin download returned \(mimeType) instead of a ZIP archive"
            }
            return "Plugin download did not return a ZIP archive"
        }
    }
}

// MARK: - Plugin Category

enum PluginCategory: String, CaseIterable {
    case transcription
    case tts
    case llm
    case postProcessor = "post-processor"
    case action
    case memory
    case utility

    var displayName: String {
        switch self {
        case .transcription: String(localized: "Transcription Engines")
        case .tts: String(localized: "Text-to-Speech")
        case .llm: String(localized: "LLM Providers")
        case .postProcessor: String(localized: "Post-Processors")
        case .action: String(localized: "Actions")
        case .memory: String(localized: "Memory")
        case .utility: String(localized: "Utilities")
        }
    }

    var iconSystemName: String {
        switch self {
        case .transcription: "waveform"
        case .tts: "speaker.wave.2.fill"
        case .llm: "brain"
        case .postProcessor: "arrow.triangle.2.circlepath"
        case .action: "bolt.fill"
        case .memory: "brain.head.profile"
        case .utility: "wrench"
        }
    }

    var sortOrder: Int {
        switch self {
        case .transcription: 0
        case .tts: 1
        case .llm: 2
        case .postProcessor: 3
        case .action: 4
        case .memory: 5
        case .utility: 6
        }
    }
}

// MARK: - Registry Models

struct RegistryPlugin: Codable, Identifiable {
    let id: String
    let name: String
    let version: String
    let minHostVersion: String
    let sdkCompatibilityVersion: String?
    let minOSVersion: String?
    let supportedArchitectures: [String]?
    let author: String
    let description: String
    let category: String
    let size: Int64
    let downloadURL: String
    let iconSystemName: String?
    let requiresAPIKey: Bool?
    let descriptions: [String: String]?
    let downloadCount: Int?

    var localizedDescription: String {
        if let descriptions,
           let lang = Locale.current.language.languageCode?.identifier,
           let localized = descriptions[lang] {
            return localized
        }
        return description
    }

    var isCompatibleWithCurrentEnvironment: Bool {
        PluginCompatibility.isCompatible(
            minOSVersion: minOSVersion,
            supportedArchitectures: supportedArchitectures
        )
    }
}

struct RegistryPluginRelease: Decodable, Equatable {
    let version: String
    let minHostVersion: String
    let sdkCompatibilityVersion: String?
    let minOSVersion: String?
    let supportedArchitectures: [String]?
    let size: Int64
    let downloadURL: String
    let publishedAt: String?
    let downloadCount: Int?

    func isCompatible(
        withAppVersion appVersion: String,
        sdkCompatibilityVersion: String,
        currentOSVersion: OperatingSystemVersion,
        architecture: String
    ) -> Bool {
        PluginRegistryService.compareVersions(minHostVersion, appVersion) != .orderedDescending
            && self.sdkCompatibilityVersion == sdkCompatibilityVersion
            && PluginCompatibility.isCompatible(
                minOSVersion: minOSVersion,
                supportedArchitectures: supportedArchitectures,
                currentOSVersion: currentOSVersion,
                architecture: architecture
            )
    }
}

private struct LegacyRegistryRelease: Decodable {
    let version: String?
    let minHostVersion: String?
    let sdkCompatibilityVersion: String?
    let minOSVersion: String?
    let supportedArchitectures: [String]?
    let size: Int64?
    let downloadURL: String?
    let downloadCount: Int?
}

struct RegistryPluginEntry: Decodable {
    let id: String
    let name: String
    let author: String
    let description: String
    let category: String
    let iconSystemName: String?
    let requiresAPIKey: Bool?
    let descriptions: [String: String]?
    let downloadCount: Int?
    let releases: [RegistryPluginRelease]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case author
        case description
        case category
        case iconSystemName
        case requiresAPIKey
        case descriptions
        case downloadCount
        case releases
        case version
        case minHostVersion
        case sdkCompatibilityVersion
        case minOSVersion
        case supportedArchitectures
        case size
        case downloadURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        author = try container.decode(String.self, forKey: .author)
        description = try container.decode(String.self, forKey: .description)
        category = try container.decode(String.self, forKey: .category)
        iconSystemName = try container.decodeIfPresent(String.self, forKey: .iconSystemName)
        requiresAPIKey = try container.decodeIfPresent(Bool.self, forKey: .requiresAPIKey)
        descriptions = try container.decodeIfPresent([String: String].self, forKey: .descriptions)
        downloadCount = try container.decodeIfPresent(Int.self, forKey: .downloadCount)

        let decodedReleases = try container.decodeIfPresent([RegistryPluginRelease].self, forKey: .releases) ?? []
        if !decodedReleases.isEmpty {
            releases = decodedReleases
            return
        }

        let legacy = try LegacyRegistryRelease(from: decoder)
        guard
            let version = legacy.version,
            let minHostVersion = legacy.minHostVersion,
            let size = legacy.size,
            let downloadURL = legacy.downloadURL
        else {
            releases = []
            return
        }

            releases = [
            RegistryPluginRelease(
                version: version,
                minHostVersion: minHostVersion,
                sdkCompatibilityVersion: legacy.sdkCompatibilityVersion,
                minOSVersion: legacy.minOSVersion,
                supportedArchitectures: legacy.supportedArchitectures,
                size: size,
                downloadURL: downloadURL,
                publishedAt: nil,
                downloadCount: legacy.downloadCount
            )
        ]
    }

    func resolvedPlugin(
        appVersion: String,
        sdkCompatibilityVersion: String,
        currentOSVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        architecture: String = RuntimeArchitecture.current
    ) -> RegistryPlugin? {
        let compatibleRelease = releases
            .filter {
                $0.isCompatible(
                    withAppVersion: appVersion,
                    sdkCompatibilityVersion: sdkCompatibilityVersion,
                    currentOSVersion: currentOSVersion,
                    architecture: architecture
                )
            }
            .max { first, second in
                PluginRegistryService.compareVersions(first.version, second.version) == .orderedAscending
            }

        guard let compatibleRelease else { return nil }

        return RegistryPlugin(
            id: id,
            name: name,
            version: compatibleRelease.version,
            minHostVersion: compatibleRelease.minHostVersion,
            sdkCompatibilityVersion: compatibleRelease.sdkCompatibilityVersion,
            minOSVersion: compatibleRelease.minOSVersion,
            supportedArchitectures: compatibleRelease.supportedArchitectures,
            author: author,
            description: description,
            category: category,
            size: compatibleRelease.size,
            downloadURL: compatibleRelease.downloadURL,
            iconSystemName: iconSystemName,
            requiresAPIKey: requiresAPIKey,
            descriptions: descriptions,
            downloadCount: compatibleRelease.downloadCount ?? downloadCount
        )
    }
}

struct PluginRegistryResponse: Decodable {
    let schemaVersion: Int
    let plugins: [RegistryPluginEntry]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case plugins
    }

    init(schemaVersion: Int, plugins: [RegistryPluginEntry]) {
        self.schemaVersion = schemaVersion
        self.plugins = plugins
    }

    /// Decodes the registry tolerantly: a single malformed plugin entry is
    /// logged and skipped instead of aborting the entire fetch. Without this,
    /// one bad entry on the gh-pages `plugins.json` would empty the marketplace
    /// for every installed app until a fix is deployed (release review K4).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)

        var pluginsContainer = try container.nestedUnkeyedContainer(forKey: .plugins)
        var collected: [RegistryPluginEntry] = []
        if let count = pluginsContainer.count {
            collected.reserveCapacity(count)
        }

        var index = 0
        while !pluginsContainer.isAtEnd {
            do {
                let entry = try pluginsContainer.decode(RegistryPluginEntry.self)
                collected.append(entry)
            } catch {
                // Advance past the malformed element so decoding can continue.
                // JSONDecoder advances the cursor on a thrown decode, but we
                // defend against that assumption with an explicit skip decode.
                _ = try? pluginsContainer.decode(AnyDecodableSkip.self)
                logger.error("Skipping malformed plugin entry at index \(index): \(error.localizedDescription)")
            }
            index += 1
        }

        self.plugins = collected
    }

    func resolvedPlugins(
        appVersion: String,
        sdkCompatibilityVersion: String,
        currentOSVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        architecture: String = RuntimeArchitecture.current
    ) -> [RegistryPlugin] {
        plugins.compactMap {
            $0.resolvedPlugin(
                appVersion: appVersion,
                sdkCompatibilityVersion: sdkCompatibilityVersion,
                currentOSVersion: currentOSVersion,
                architecture: architecture
            )
        }
    }
}

/// Placeholder used to skip a malformed element in an unkeyed container.
private struct AnyDecodableSkip: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

enum PluginInstallInfo {
    case notInstalled
    case installed(version: String)
    case updateAvailable(installed: String, available: String)
    case bundled
}

// MARK: - Plugin Registry Service

@MainActor
final class PluginRegistryService: ObservableObject {
    nonisolated(unsafe) static var shared: PluginRegistryService!

    @Published var registry: [RegistryPlugin] = []
    @Published var fetchState: FetchState = .idle
    @Published var installStates: [String: InstallState] = [:]
    @Published var availableUpdatesCount: Int = 0

    private var lastFetchDate: Date?
    private var activeInstallPluginIDs: Set<String> = []
    private let registryURL = URL(string: "https://typewhisper.github.io/typewhisper-mac/plugins.json")!
    private let cacheDuration: TimeInterval = 300 // 5 minutes
    private static let lastUpdateCheckKey = "pluginRegistryLastUpdateCheck"

    enum FetchState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    enum InstallState: Equatable {
        case downloading(Double)
        case extracting
        case error(String)
    }

    // MARK: - Version Comparison

    nonisolated static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        let count = max(partsA.count, partsB.count)
        for i in 0..<count {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va < vb { return .orderedAscending }
            if va > vb { return .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Fetch Registry

    func fetchRegistry() async {
        if let lastFetch = lastFetchDate, Date().timeIntervalSince(lastFetch) < cacheDuration, !registry.isEmpty {
            return
        }

        fetchState = .loading

        do {
            var request = URLRequest(url: registryURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)

            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
            registry = response.resolvedPlugins(
                appVersion: appVersion,
                sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion
            )
            lastFetchDate = Date()
            fetchState = .loaded
            logger.info("Fetched \(self.registry.count) plugin(s) from registry")
        } catch {
            fetchState = .error(error.localizedDescription)
            logger.error("Failed to fetch registry: \(error.localizedDescription)")
        }
    }

    // MARK: - Background Update Check

    /// Check for plugin updates on app launch (at most once per 24h).
    func checkForUpdatesInBackground() {
        let lastCheck = UserDefaults.standard.double(forKey: Self.lastUpdateCheckKey)
        let hoursSinceLastCheck = (Date().timeIntervalSince1970 - lastCheck) / 3600
        guard hoursSinceLastCheck >= 24 || lastCheck == 0 else { return }

        Task {
            lastFetchDate = nil
            await fetchRegistry()
            updateAvailableUpdatesCount()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastUpdateCheckKey)
        }
    }

    func updateAvailableUpdatesCount() {
        let count = PluginManager.shared.loadedPlugins.count(where: { plugin in
            if case .updateAvailable = installInfo(for: plugin.manifest.id) { return true }
            return false
        })
        availableUpdatesCount = count
    }

    // MARK: - Install Info

    func installInfo(for pluginId: String) -> PluginInstallInfo {
        guard let loaded = PluginManager.shared.loadedPlugins.first(where: { $0.manifest.id == pluginId }) else {
            return .notInstalled
        }

        if loaded.isBundled {
            return .bundled
        }

        guard let registryPlugin = registry.first(where: { $0.id == pluginId }) else {
            return .installed(version: loaded.manifest.version)
        }

        if Self.compareVersions(registryPlugin.version, loaded.manifest.version) == .orderedDescending {
            return .updateAvailable(installed: loaded.manifest.version, available: registryPlugin.version)
        }

        return .installed(version: loaded.manifest.version)
    }

    // MARK: - Download & Install

    func downloadAndInstall(_ plugin: RegistryPlugin) async {
        guard plugin.isCompatibleWithCurrentEnvironment else {
            installStates[plugin.id] = .error("Plugin is not compatible with this Mac")
            return
        }

        guard let url = URL(string: plugin.downloadURL) else {
            installStates[plugin.id] = .error("Invalid download URL")
            return
        }

        guard activeInstallPluginIDs.insert(plugin.id).inserted else {
            logger.warning("Skipping duplicate install request for \(plugin.id)")
            return
        }
        defer { activeInstallPluginIDs.remove(plugin.id) }

        installStates[plugin.id] = .downloading(0)

        do {
            let delegate = DownloadProgressDelegate { [weak self] progress in
                Task { @MainActor in
                    self?.installStates[plugin.id] = .downloading(progress)
                }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let (tempURL, response) = try await session.download(from: url)
            try Self.validateDownloadedArchiveResponse(response)

            installStates[plugin.id] = .extracting

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let zipPath = tempDir.appendingPathComponent("plugin.zip")
            try FileManager.default.moveItem(at: tempURL, to: zipPath)

            let extractDir = tempDir.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-xk", zipPath.path, extractDir.path]
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                installStates[plugin.id] = .error("Failed to extract ZIP")
                return
            }

            // Find .bundle in extracted directory
            let extracted = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
            guard let bundleURL = extracted.first(where: { $0.pathExtension == "bundle" }) else {
                installStates[plugin.id] = .error("No .bundle found in ZIP")
                return
            }

            try installBundle(
                at: bundleURL,
                expectedPluginId: plugin.id,
                copyBundle: false
            )

            installStates.removeValue(forKey: plugin.id)
            lastFetchDate = nil // invalidate cache so installInfo refreshes
            updateAvailableUpdatesCount()
            logger.info("Installed plugin \(plugin.id) v\(plugin.version)")
        } catch {
            installStates[plugin.id] = .error(error.localizedDescription)
            logger.error("Failed to install \(plugin.id): \(error.localizedDescription)")
        }
    }

    // MARK: - Uninstall

    func uninstallPlugin(_ pluginId: String, deleteData: Bool = false) {
        guard let bundleURL = PluginManager.shared.bundleURL(for: pluginId) else { return }

        PluginManager.shared.unloadPlugin(pluginId)

        logger.info("Removing installed plugin bundle at \(bundleURL.path, privacy: .public)")
        try? FileManager.default.removeItem(at: bundleURL)

        if deleteData {
            let dataDir = AppConstants.appSupportDirectory
                .appendingPathComponent("PluginData", isDirectory: true)
                .appendingPathComponent(pluginId, isDirectory: true)
            try? FileManager.default.removeItem(at: dataDir)
        }

        UserDefaults.standard.removeObject(forKey: "plugin.\(pluginId).enabled")
        logger.info("Uninstalled plugin: \(pluginId)")
    }

    // MARK: - Install from File

    func installFromFile(_ url: URL) async throws {
        let fm = FileManager.default

        if url.pathExtension == "bundle" {
            try installBundle(at: url, expectedPluginId: nil, copyBundle: true)
        } else if url.pathExtension == "zip" {
            let tempDir = fm.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempDir) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-xk", url.path, tempDir.path]
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw NSError(domain: "PluginRegistry", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to extract ZIP"])
            }

            let extracted = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            guard let bundleURL = extracted.first(where: { $0.pathExtension == "bundle" }) else {
                throw NSError(domain: "PluginRegistry", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No .bundle found in ZIP"])
            }

            try installBundle(at: bundleURL, expectedPluginId: nil, copyBundle: false)
        }
    }

    private func installBundle(at bundleURL: URL, expectedPluginId: String?, copyBundle: Bool) throws {
        let fm = FileManager.default
        let manifest = try readManifest(at: bundleURL)
        let existingLoadedBundleURL = PluginManager.shared.bundleURL(for: manifest.id)

        guard manifest.isCompatibleWithCurrentEnvironment else {
            let architecture = RuntimeArchitecture.current
            let reason = PluginCompatibility.incompatibilityReason(
                minOSVersion: manifest.minOSVersion,
                supportedArchitectures: manifest.supportedArchitectures,
                architecture: architecture
            ) ?? "Plugin is not compatible with this Mac"
            throw NSError(
                domain: "PluginRegistry",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "\(manifest.name) \(reason) (current architecture: \(architecture))"]
            )
        }

        if let expectedPluginId, manifest.id != expectedPluginId {
            throw NSError(
                domain: "PluginRegistry",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded bundle ID \(manifest.id) does not match expected plugin \(expectedPluginId)"]
            )
        }

        let destinationURL = Self.resolveInstallDestinationURL(
            currentURL: PluginManager.shared.bundleURL(for: manifest.id),
            builtInPluginsURL: Bundle.main.builtInPlugInsURL,
            pluginsDirectory: PluginManager.shared.pluginsDirectory,
            incomingBundleName: bundleURL.lastPathComponent
        )

        let backupURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent("\(destinationURL.lastPathComponent).backup-\(UUID().uuidString)")
        let hadExistingBundle = fm.fileExists(atPath: destinationURL.path)

        do {
            PluginManager.shared.unloadPlugin(manifest.id)

            if hadExistingBundle {
                logger.info("Moving existing plugin bundle to backup: \(destinationURL.path, privacy: .public) -> \(backupURL.path, privacy: .public)")
                try fm.moveItem(at: destinationURL, to: backupURL)
            }

            if copyBundle {
                logger.info("Copying plugin bundle into install location: \(bundleURL.path, privacy: .public) -> \(destinationURL.path, privacy: .public)")
                try fm.copyItem(at: bundleURL, to: destinationURL)
            } else {
                logger.info("Moving plugin bundle into install location: \(bundleURL.path, privacy: .public) -> \(destinationURL.path, privacy: .public)")
                try fm.moveItem(at: bundleURL, to: destinationURL)
            }

            try PluginManager.shared.loadPlugin(at: destinationURL)
            try removeDuplicateBundles(for: manifest.id, keeping: destinationURL)

            if hadExistingBundle, fm.fileExists(atPath: backupURL.path) {
                logger.info("Removing plugin backup after successful install: \(backupURL.path, privacy: .public)")
                try fm.removeItem(at: backupURL)
            }
        } catch {
            logger.error("Plugin install rollback for \(manifest.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if fm.fileExists(atPath: destinationURL.path) {
                logger.info("Removing failed plugin install at \(destinationURL.path, privacy: .public)")
                try? fm.removeItem(at: destinationURL)
            }
            if hadExistingBundle, fm.fileExists(atPath: backupURL.path) {
                logger.info("Restoring plugin backup: \(backupURL.path, privacy: .public) -> \(destinationURL.path, privacy: .public)")
                try? fm.moveItem(at: backupURL, to: destinationURL)
                try? PluginManager.shared.loadPlugin(at: destinationURL)
            } else if let existingLoadedBundleURL {
                logger.info("Reloading previously loaded plugin from \(existingLoadedBundleURL.path, privacy: .public)")
                try? PluginManager.shared.loadPlugin(at: existingLoadedBundleURL)
            }
            throw error
        }
    }

    static func validateDownloadedArchiveResponse(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse,
           !(200 ..< 300).contains(http.statusCode) {
            throw PluginDownloadError.httpStatus(http.statusCode)
        }

        let mimeType = response.mimeType?.lowercased()
        if let mimeType,
           mimeType.contains("html") || mimeType.contains("text/plain") || mimeType.contains("json") {
            throw PluginDownloadError.unexpectedContentType(response.mimeType)
        }
    }

    static func resolveInstallDestinationURL(
        currentURL: URL?,
        builtInPluginsURL: URL?,
        pluginsDirectory: URL,
        incomingBundleName: String
    ) -> URL {
        let pluginsDirectory = pluginsDirectory.standardizedFileURL

        guard let existingURL = currentURL else {
            return pluginsDirectory.appendingPathComponent(incomingBundleName)
        }

        let currentURL = existingURL.standardizedFileURL
        let isBuiltIn = builtInPluginsURL.map { currentURL.path.hasPrefix($0.standardizedFileURL.path) } ?? false
        let isInsidePluginsDirectory = currentURL.path.hasPrefix(pluginsDirectory.path + "/") || currentURL == pluginsDirectory

        if !isBuiltIn && isInsidePluginsDirectory {
            return currentURL
        }

        return pluginsDirectory.appendingPathComponent(incomingBundleName)
    }

    private func readManifest(at bundleURL: URL) throws -> PluginManifest {
        let manifestURL = bundleURL.appendingPathComponent("Contents/Resources/manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    private func removeDuplicateBundles(for pluginId: String, keeping keptURL: URL) throws {
        let fm = FileManager.default
        let keptPath = keptURL.resolvingSymlinksInPath().standardizedFileURL.path
        let bundleURLs = try fm.contentsOfDirectory(
            at: PluginManager.shared.pluginsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter {
            guard $0.pathExtension == "bundle" else { return false }
            let candidatePath = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return candidatePath != keptPath
        }

        for url in bundleURLs {
            guard let manifest = try? readManifest(at: url), manifest.id == pluginId else { continue }
            logger.info("Removing duplicate plugin bundle at \(url.path, privacy: .public), keeping \(keptURL.path, privacy: .public)")
            try fm.removeItem(at: url)
        }
    }

    // MARK: - Formatted Size

    static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func formattedDownloadCount(_ count: Int) -> String {
        if count >= 1000 {
            let k = Double(count) / 1000.0
            if k.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(k))K"
            }
            return String(format: "%.1fK", k)
        }
        return "\(count)"
    }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by the async download(from:) API
    }
}
