import AppKit
import Foundation
import SQLite3
import UniformTypeIdentifiers

/// Every place this app variant (release, dev, or screenshot run) writes user
/// data to. The full data export and `UserDataEraser` share it so "export all"
/// and "delete all" cover the same ground.
///
/// Deliberately not listed: `~/Library/Application Support/FluidAudio`
/// (Parakeet models shared with other apps), recorder output in
/// `~/Documents/TypeWhisper Recordings` (user files), a user-chosen cloud sync
/// folder, and the iCloud Drive package (both reach other devices).
struct UserDataLocations: Sendable {
    /// Prefix for every file and folder this app variant creates in the
    /// per-user temporary directory: API uploads, recorder tracks, import
    /// scratch copies and export staging. Release and dev builds share that
    /// directory, so the bundle identifier keeps their items apart.
    static let temporaryItemPrefix = "TypeWhisper-\(Bundle.main.bundleIdentifier ?? "com.typewhisper.mac")-"

    static func temporaryItemURL(_ name: String, isDirectory: Bool = false) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(temporaryItemPrefix + name, isDirectory: isDirectory)
    }

    var appSupportDirectory: URL
    /// Items outside `appSupportDirectory`: the widget snapshot and local
    /// iCloud mirror in the App Group container, plus caches, HTTP storage and
    /// saved window state under `~/Library`.
    var auxiliaryItems: [URL]
    var preferencesDomain: String

    static func current(fileManager: FileManager = .default) -> UserDataLocations {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.typewhisper.mac"
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]

        var auxiliaryItems: [URL] = [
            library.appendingPathComponent("Caches/\(bundleIdentifier)", isDirectory: true),
            library.appendingPathComponent("HTTPStorages/\(bundleIdentifier)", isDirectory: true),
            library.appendingPathComponent("HTTPStorages/\(bundleIdentifier).binarycookies"),
            library.appendingPathComponent("WebKit/\(bundleIdentifier)", isDirectory: true),
            library.appendingPathComponent("Saved Application State/\(bundleIdentifier).savedState", isDirectory: true),
        ]
        if let groupContainer = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetData.groupIdentifier
        ) {
            auxiliaryItems.append(groupContainer.appendingPathComponent(WidgetData.fileName))
        }
        if let mirrorRoot = PremiumICloudBridgeConstants.localRootURL(fileManager: fileManager) {
            auxiliaryItems.append(mirrorRoot.appendingPathComponent(
                PremiumICloudBridgeConstants.packageDirectoryName,
                isDirectory: true
            ))
        }
        auxiliaryItems += temporaryItems(withPrefix: temporaryItemPrefix, fileManager: fileManager)

        return UserDataLocations(
            appSupportDirectory: AppConstants.appSupportDirectory,
            auxiliaryItems: auxiliaryItems,
            preferencesDomain: bundleIdentifier
        )
    }

    static func temporaryItems(withPrefix prefix: String, fileManager: FileManager = .default) -> [URL] {
        let temporaryDirectory = fileManager.temporaryDirectory
        let names = (try? fileManager.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) }
            .map { temporaryDirectory.appendingPathComponent($0) }
    }
}

/// Writes a ZIP archive with everything TypeWhisper stores about the user:
/// the raw Application Support data (history databases and audio, dictionary,
/// snippets, workflows, profiles, plugin data, logs), all preferences as JSON,
/// and an importable settings backup.
///
/// Secrets stay out of the archive: provider API keys, license activations and
/// the premium account token live in the Keychain, and the local API token file
/// is skipped. Downloaded and imported models and plugin bundles are skipped as
/// well: model weights are not personal data and would make the archive
/// gigabytes large. The UI names imported models explicitly, since the managed
/// copy may be the only one left.
enum UserDataExportService {
    enum ExportError: LocalizedError {
        case archiveFailed(Int32)
        case databaseSnapshotFailed(String)
        case unreadableDirectory(String)

        var errorDescription: String? {
            switch self {
            case .archiveFailed(let status):
                return localizedAppText(
                    "The ZIP archive could not be created (ditto exit code \(status)).",
                    de: "Das ZIP-Archiv konnte nicht erstellt werden (ditto-Exit-Code \(status))."
                )
            case .unreadableDirectory(let path):
                return localizedAppText(
                    "The folder \(path) could not be read.",
                    de: "Der Ordner \(path) konnte nicht gelesen werden."
                )
            case .databaseSnapshotFailed(let name):
                return localizedAppText(
                    "The database \(name) could not be copied.",
                    de: "Die Datenbank \(name) konnte nicht kopiert werden."
                )
            }
        }
    }

    static let stagingDirectoryName = "DataExport-"

    static let appSupportFolderName = "Application Support"
    static let preferencesFileName = "preferences.json"
    static let settingsBackupFileName = "settings-backup.json"
    static let readmeFileName = "README.txt"

    /// Top-level entries of the Application Support folder that are not user
    /// data: installed plugin bundles, the marketplace cache, legacy model
    /// downloads, and the local API port/token files.
    static let excludedTopLevelNames: Set<String> = [
        "Plugins", "MarketplaceCache", "models", "api-port", "api-discovery.json",
    ]

    /// Model download folders inside `PluginData/<pluginId>/`, compared
    /// case-insensitively.
    static let excludedPluginDataNames: Set<String> = ["models", "custom-models"]

    static func shouldExport(relativePath: String) -> Bool {
        let components = (relativePath as NSString).pathComponents
        guard let first = components.first else { return false }
        if excludedTopLevelNames.contains(first) { return false }
        if first == "PluginData", components.count >= 3,
           excludedPluginDataNames.contains(components[2].lowercased()) {
            return false
        }
        return true
    }

    @MainActor
    static func presentSavePanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = localizedAppText("Export All Data", de: "Alle Daten exportieren")
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func defaultFilename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "TypeWhisper Data \(formatter.string(from: date)).zip"
    }

    /// Snapshots preferences on the calling actor, then copies files and builds
    /// the archive off the main thread.
    @MainActor
    static func export(
        to destination: URL,
        settingsBackup: Data,
        locations: UserDataLocations = .current(),
        userDefaults: UserDefaults = .standard
    ) async throws {
        let preferences = try preferencesJSON(
            userDefaults.persistentDomain(forName: locations.preferencesDomain) ?? [:]
        )
        let extraFiles = [
            readmeFileName: Data(readme.utf8),
            preferencesFileName: preferences,
            settingsBackupFileName: settingsBackup,
        ]
        let appSupportDirectory = locations.appSupportDirectory

        try await Task.detached(priority: .userInitiated) {
            try writeArchive(
                appSupportDirectory: appSupportDirectory,
                extraFiles: extraFiles,
                to: destination
            )
        }.value
    }

    static func writeArchive(
        appSupportDirectory: URL,
        extraFiles: [String: Data],
        to destination: URL
    ) throws {
        let fileManager = FileManager.default
        // Leftovers from an export interrupted by a crash or force quit hold
        // a full unencrypted copy of the user's data. The export button is
        // disabled while an export runs, so any existing folder is stale.
        let stagingPrefix = UserDataLocations.temporaryItemPrefix + stagingDirectoryName
        for staleDirectory in UserDataLocations.temporaryItems(withPrefix: stagingPrefix, fileManager: fileManager) {
            try? fileManager.removeItem(at: staleDirectory)
        }
        let workDirectory = UserDataLocations.temporaryItemURL(
            stagingDirectoryName + UUID().uuidString,
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: workDirectory) }

        let root = workDirectory.appendingPathComponent(
            destination.deletingPathExtension().lastPathComponent,
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, data) in extraFiles {
            try data.write(to: root.appendingPathComponent(name), options: .atomic)
        }
        try copyUserData(
            from: appSupportDirectory,
            to: root.appendingPathComponent(appSupportFolderName, isDirectory: true)
        )

        let archive = workDirectory.appendingPathComponent("export.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, archive.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.archiveFailed(process.terminationStatus)
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: archive)
        } else {
            try fileManager.moveItem(at: archive, to: destination)
        }
    }

    static func copyUserData(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: source.path) else { return }
        // An unreadable folder must fail the export instead of producing an
        // archive that silently lacks the user's data.
        guard fileManager.isReadableFile(atPath: source.path),
              let enumerator = fileManager.enumerator(atPath: source.path) else {
            throw ExportError.unreadableDirectory(source.path)
        }

        while let relativePath = enumerator.nextObject() as? String {
            let type = enumerator.fileAttributes?[.type] as? FileAttributeType
            // Links could point outside the export once the archive is unpacked.
            if type == .typeSymbolicLink { continue }
            let isDirectory = type == .typeDirectory
            guard shouldExport(relativePath: relativePath) else {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            let sourceFile = source.appendingPathComponent(relativePath, isDirectory: isDirectory)
            let target = destination.appendingPathComponent(relativePath, isDirectory: isDirectory)
            if isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            if isSQLiteSidecar(sourceFile) { continue }
            do {
                if isSQLiteDatabase(sourceFile) {
                    try snapshotSQLiteDatabase(from: sourceFile, to: target)
                } else {
                    try fileManager.copyItem(at: sourceFile, to: target)
                }
            } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
                // Transient files (SQLite journals, recovery audio) can
                // disappear between enumeration and copy.
                continue
            }
        }
    }

    private static let sqliteSidecarSuffixes = ["-wal", "-shm", "-journal"]

    static func isSQLiteDatabase(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        return header == Data("SQLite format 3\u{0}".utf8)
    }

    /// WAL, shared-memory and rollback journal files of a SQLite database.
    /// They are folded into the database snapshot instead of being copied.
    static func isSQLiteSidecar(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard let suffix = sqliteSidecarSuffixes.first(where: { name.hasSuffix($0) }) else { return false }
        let database = url.deletingLastPathComponent()
            .appendingPathComponent(String(name.dropLast(suffix.count)))
        return isSQLiteDatabase(database)
    }

    /// Copies a live database with `VACUUM INTO`, so the copy is a consistent
    /// snapshot even while the app writes to it, already contains the pages
    /// that still sit in the WAL file, and needs no sidecar files.
    static func snapshotSQLiteDatabase(from source: URL, to destination: URL) throws {
        let failure = ExportError.databaseSnapshotFailed(source.lastPathComponent)

        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(source.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw failure
        }
        sqlite3_busy_timeout(database, 5_000)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_prepare_v2(database, "VACUUM INTO ?", -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_text(statement, 1, destination.path, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw failure
        }
    }

    /// Converts a `UserDefaults` domain into pretty-printed JSON. `Data`
    /// values become base64 strings and dates become ISO 8601 strings.
    static func preferencesJSON(_ domain: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: jsonCompatible(domain),
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func jsonCompatible(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonCompatible)
        case let array as [Any]:
            return array.map(jsonCompatible)
        case let data as Data:
            return data.base64EncodedString()
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case is String, is NSNumber:
            return value
        default:
            return String(describing: value)
        }
    }

    private static let readme = """
        TypeWhisper data export

        settings-backup.json
          Workflows, dictionary, snippets, profiles, prompt actions, hotkeys,
          installed plugins, transcription history and preferences. Import it
          under Settings > Advanced > Import Settings.

        preferences.json
          Every stored preference of the app and its plugins.

        Application Support/
          The raw data files: history, usage statistics, workflow, profile,
          snippet, dictionary and prompt action databases (SQLite), saved
          history audio, dictation recovery audio, imported sounds, plugin data
          such as memories, the error log and watch folder history.

        Not included: provider API keys, license activations and the premium
        account token (stored in the macOS Keychain), the local API token,
        downloaded or imported models and installed plugin bundles.
        """
}
