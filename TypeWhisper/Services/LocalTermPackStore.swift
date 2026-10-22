import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "LocalTermPackStore")

/// Keeps the sources of imported local term packs, one `<id>.json` per pack in the registry
/// format, inside Application Support (the app container in the App Store edition).
///
/// Whether a pack is turned on is stored separately, with the other pack activation states
/// in `DictionaryViewModel`. Nothing here is synced: a pack only exists on the Mac it was
/// imported on.
@MainActor
final class LocalTermPackStore: ObservableObject {
    nonisolated static let directoryName = "LocalTermPacks"

    @Published private(set) var packs: [TermPack] = []

    let directory: URL
    private let fileManager: FileManager
    private var files: [String: LocalTermPackFile] = [:]
    /// Every file that holds a pack, the loaded one first. Extra copies only exist if files
    /// were copied into the folder by hand; saving or removing the pack deletes them too.
    private var fileURLs: [String: [URL]] = [:]

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        reload()
    }

    func file(withID id: String) -> LocalTermPackFile? {
        files[id]
    }

    func pack(withID id: String) -> TermPack? {
        files[id]?.termPack
    }

    /// Writes the pack as `<id>.json`, replacing a stored pack with the same ID.
    func save(_ file: LocalTermPackFile) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(forID: file.id)
        try file.encodedData().write(to: url, options: .atomic)

        // On a case-insensitive volume, a copy named like `Team-Terms.json` is the file just written.
        let savedFile = fileNumber(of: url)
        for staleURL in fileURLs[file.id] ?? [] where staleURL.lastPathComponent != url.lastPathComponent {
            guard fileNumber(of: staleURL) != savedFile else { continue }
            try? fileManager.removeItem(at: staleURL)
        }
        files[file.id] = file
        fileURLs[file.id] = [url]
        publish()
    }

    func remove(id: String) throws {
        for url in fileURLs[id] ?? [] {
            do {
                try fileManager.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Already gone.
            }
        }
        files[id] = nil
        fileURLs[id] = nil
        publish()
    }

    /// Loads every valid pack file. Unreadable or invalid files are skipped and left in place.
    func reload() {
        var loadedFiles: [String: LocalTermPackFile] = [:]
        var loadedURLs: [String: [URL]] = [:]

        let urls = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for url in urls {
            let file: LocalTermPackFile
            do {
                file = try LocalTermPackFile.decode(Data(contentsOf: url))
            } catch {
                logger.warning("Skipping local term pack \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }

            // `<id>.json` wins over a copy with another name; otherwise the first file by name.
            let isNamedAfterID = url.lastPathComponent == fileURL(forID: file.id).lastPathComponent
            if loadedFiles[file.id] == nil || isNamedAfterID {
                loadedFiles[file.id] = file
                loadedURLs[file.id, default: []].insert(url, at: 0)
            } else {
                loadedURLs[file.id, default: []].append(url)
            }
            if (loadedURLs[file.id]?.count ?? 0) > 1 {
                logger.warning("Local term pack ID \(file.id, privacy: .public) is stored more than once; using \(loadedURLs[file.id]?.first?.lastPathComponent ?? "", privacy: .public)")
            }
        }

        files = loadedFiles
        fileURLs = loadedURLs
        publish()
    }

    private func fileURL(forID id: String) -> URL {
        // IDs are validated to lowercase letters, digits and hyphens, so they are safe file names.
        directory.appendingPathComponent("\(id).json", isDirectory: false)
    }

    /// Volume and file number, so two paths can be compared as the same file.
    private func fileNumber(of url: URL) -> [UInt64]? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        return [volume, file]
    }

    private func publish() {
        packs = files.values
            .map(\.termPack)
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }
}
