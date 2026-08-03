import Darwin
import Foundation

@_spi(FirstPartyPlugins)
public struct PluginHuggingFaceModelStore: Sendable {
    public struct Requirements: Sendable {
        public let requiredFiles: Set<String>
        public let alternativeFileGroups: [Set<String>]
        public let weightFileExtensions: Set<String>

        public init(
            requiredFiles: Set<String>,
            alternativeFileGroups: [Set<String>] = [],
            weightFileExtensions: Set<String>
        ) {
            self.requiredFiles = requiredFiles
            self.alternativeFileGroups = alternativeFileGroups
            self.weightFileExtensions = Set(
                weightFileExtensions.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
            )
        }
    }

    public let modelsDirectory: URL

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory.standardizedFileURL
    }

    public func repositoryCacheDirectory(for repositoryID: String, cacheRoot: URL? = nil) -> URL? {
        guard let cacheName = repositoryCacheName(for: repositoryID) else { return nil }
        return (cacheRoot ?? modelsDirectory).appendingPathComponent(cacheName, isDirectory: true)
    }

    public func repositoryMetadataDirectory(for repositoryID: String, cacheRoot: URL? = nil) -> URL? {
        guard let cacheName = repositoryCacheName(for: repositoryID) else { return nil }
        return (cacheRoot ?? modelsDirectory)
            .appendingPathComponent(".metadata", isDirectory: true)
            .appendingPathComponent(cacheName, isDirectory: true)
    }

    public func repositoryLockDirectory(for repositoryID: String, cacheRoot: URL? = nil) -> URL? {
        guard let cacheName = repositoryCacheName(for: repositoryID) else { return nil }
        return (cacheRoot ?? modelsDirectory)
            .appendingPathComponent(".locks", isDirectory: true)
            .appendingPathComponent(cacheName, isDirectory: true)
    }

    public func snapshotDirectory(
        for repositoryID: String,
        revision: String = "main",
        cacheRoot: URL? = nil,
        requirements: Requirements
    ) -> URL? {
        guard isSafePathComponent(revision),
              let repositoryDirectory = repositoryCacheDirectory(for: repositoryID, cacheRoot: cacheRoot) else {
            return nil
        }

        let refURL = repositoryDirectory
            .appendingPathComponent("refs", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: false)
        guard let refData = try? Data(contentsOf: refURL, options: .mappedIfSafe),
              refData.count <= 256,
              let rawRef = String(data: refData, encoding: .utf8) else {
            return nil
        }

        let commit = rawRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeCommit(commit) else { return nil }

        let snapshot = repositoryDirectory
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(commit, isDirectory: true)
        return isUsableModelDirectory(snapshot, requirements: requirements) ? snapshot : nil
    }

    public func usableModelDirectory(
        for repositoryID: String,
        revision: String = "main",
        legacyDirectories: [URL],
        requirements: Requirements
    ) -> URL? {
        if let snapshot = snapshotDirectory(
            for: repositoryID,
            revision: revision,
            requirements: requirements
        ) {
            return snapshot
        }

        return legacyDirectories.first {
            isPathInsideModelsDirectory($0) && isUsableModelDirectory($0, requirements: requirements)
        }
    }

    public func isUsableModelDirectory(_ directory: URL, requirements: Requirements) -> Bool {
        guard isDirectory(directory),
              requirements.requiredFiles.allSatisfy({ isNonemptyRegularFile(relativePath: $0, in: directory) }),
              requirements.alternativeFileGroups.isEmpty
                || requirements.alternativeFileGroups.contains(where: { group in
                    group.allSatisfy { isNonemptyRegularFile(relativePath: $0, in: directory) }
                }),
              !requirements.weightFileExtensions.isEmpty else {
            return false
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            let fileExtension = fileURL.pathExtension.lowercased()
            if requirements.weightFileExtensions.contains(fileExtension), regularFileSize(fileURL) ?? 0 > 0 {
                return true
            }
        }
        return false
    }

    @discardableResult
    public func removeRedundantLegacyDirectories(
        for repositoryID: String,
        revision: String = "main",
        legacyDirectories: [URL],
        requirements: Requirements,
        reproducibleRelativePaths: Set<String> = []
    ) throws -> [URL] {
        guard let snapshot = snapshotDirectory(
            for: repositoryID,
            revision: revision,
            requirements: requirements
        ) else {
            return []
        }

        var removed: [URL] = []
        var firstError: Error?
        for legacyDirectory in legacyDirectories
        where isPathInsideModelsDirectory(legacyDirectory) && entryExists(legacyDirectory) {
            guard legacyIsEquivalent(
                legacyDirectory,
                to: snapshot,
                reproducibleRelativePaths: reproducibleRelativePaths
            ) else {
                continue
            }

            do {
                try FileManager.default.removeItem(at: legacyDirectory)
                removed.append(legacyDirectory)
                removeEmptyParents(startingAt: legacyDirectory.deletingLastPathComponent())
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let firstError { throw firstError }
        return removed
    }

    public func hasCachedModelFiles(
        for repositoryID: String,
        legacyDirectories: [URL],
        additionalCacheRoots: [URL] = []
    ) -> Bool {
        artifactURLs(
            for: repositoryID,
            legacyDirectories: legacyDirectories,
            additionalCacheRoots: additionalCacheRoots
        ).contains(where: entryExists)
    }

    public func deleteModelFiles(
        for repositoryID: String,
        legacyDirectories: [URL],
        additionalCacheRoots: [URL] = []
    ) throws {
        var firstError: Error?
        let artifacts = artifactURLs(
            for: repositoryID,
            legacyDirectories: legacyDirectories,
            additionalCacheRoots: additionalCacheRoots
        )

        for artifact in artifacts where entryExists(artifact) {
            do {
                try FileManager.default.removeItem(at: artifact)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        for artifact in artifacts {
            removeEmptyParents(startingAt: artifact.deletingLastPathComponent())
        }

        if let firstError { throw firstError }
    }

    private func artifactURLs(
        for repositoryID: String,
        legacyDirectories: [URL],
        additionalCacheRoots: [URL]
    ) -> [URL] {
        var urls = legacyDirectories.filter(isPathInsideModelsDirectory)
        let safeAdditionalRoots = additionalCacheRoots
            .map(\.standardizedFileURL)
            .filter(isPathInsideModelsDirectory)
        for root in [modelsDirectory] + safeAdditionalRoots {
            if let repository = repositoryCacheDirectory(for: repositoryID, cacheRoot: root) {
                urls.append(repository)
            }
            if let metadata = repositoryMetadataDirectory(for: repositoryID, cacheRoot: root) {
                urls.append(metadata)
            }
            if let locks = repositoryLockDirectory(for: repositoryID, cacheRoot: root) {
                urls.append(locks)
            }
        }

        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func legacyIsEquivalent(
        _ legacyDirectory: URL,
        to snapshot: URL,
        reproducibleRelativePaths: Set<String>
    ) -> Bool {
        guard isDirectory(legacyDirectory),
              let enumerator = FileManager.default.enumerator(
                at: legacyDirectory,
                includingPropertiesForKeys: nil,
                options: []
              ) else {
            return false
        }

        let normalizedReproduciblePaths = Set(reproducibleRelativePaths.map(normalizedRelativePath))
        var comparedFile = false
        for case let legacyFile as URL in enumerator {
            guard let relativePath = relativePath(of: legacyFile, below: legacyDirectory) else { return false }
            if relativePath == ".cache" || relativePath.hasPrefix(".cache/") {
                enumerator.skipDescendants()
                continue
            }
            if normalizedReproduciblePaths.contains(relativePath) {
                continue
            }
            if isDirectory(legacyFile) {
                continue
            }
            guard let legacySize = regularFileSize(legacyFile) else { return false }

            let snapshotFile = snapshot.appendingPathComponent(relativePath, isDirectory: false)
            guard regularFileSize(snapshotFile) == legacySize else { return false }
            comparedFile = true
        }
        return comparedFile
    }

    private func repositoryCacheName(for repositoryID: String) -> String? {
        let components = repositoryID.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.allSatisfy(isSafePathComponent) else { return nil }
        return "models--" + components.joined(separator: "--")
    }

    private func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && !component.contains("/") && !component.contains("\\")
            && !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func isSafeCommit(_ commit: String) -> Bool {
        commit.utf8.count == 40 && commit.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private func normalizedRelativePath(_ path: String) -> String {
        path.split(separator: "/").map(String.init).joined(separator: "/")
    }

    private func isNonemptyRegularFile(relativePath: String, in directory: URL) -> Bool {
        let normalized = normalizedRelativePath(relativePath)
        guard !normalized.isEmpty,
              !relativePath.hasPrefix("/"),
              !normalized.split(separator: "/").contains("..") else {
            return false
        }
        return regularFileSize(directory.appendingPathComponent(normalized, isDirectory: false)) ?? 0 > 0
    }

    private func relativePath(of url: URL, below directory: URL) -> String? {
        let base = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func isPathInsideModelsDirectory(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(modelsDirectory.path + "/")
    }

    private func entryExists(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            var info = stat()
            return lstat(path, &info) == 0
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            var info = stat()
            guard stat(path, &info) == 0 else { return false }
            return (info.st_mode & S_IFMT) == S_IFDIR
        }
    }

    private func regularFileSize(_ url: URL) -> Int64? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            var info = stat()
            guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return info.st_size
        }
    }

    private func removeEmptyParents(startingAt directory: URL) {
        var current = directory.standardizedFileURL
        let root = modelsDirectory.standardizedFileURL
        while current.path != root.path, current.path.hasPrefix(root.path + "/") {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path), contents.isEmpty else {
                return
            }
            do {
                try FileManager.default.removeItem(at: current)
            } catch {
                return
            }
            current.deleteLastPathComponent()
        }
    }
}
