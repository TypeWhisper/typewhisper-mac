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
    case llm
    case postProcessor = "post-processor"
    case action
    case memory
    case utility

    var displayName: String {
        switch self {
        case .transcription: String(localized: "Transcription Engines")
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
        case .llm: 1
        case .postProcessor: 2
        case .action: 3
        case .memory: 4
        case .utility: 5
        }
    }
}

// MARK: - Registry Models

struct RegistryPlugin: Codable, Identifiable {
    let id: String
    let name: String
    let version: String
    let minHostVersion: String
    let minOSVersion: String?
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

    var isCompatibleWithCurrentOS: Bool {
        guard let minOS = minOSVersion else { return true }
        let parts = minOS.split(separator: ".").compactMap { Int($0) }
        let required = OperatingSystemVersion(
            majorVersion: parts.count > 0 ? parts[0] : 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(required)
    }
}

struct PluginRegistryResponse: Codable {
    let schemaVersion: Int
    let plugins: [RegistryPlugin]
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

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
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
            registry = response.plugins.filter {
                Self.compareVersions($0.minHostVersion, appVersion) != .orderedDescending
                    && $0.isCompatibleWithCurrentOS
            }
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
