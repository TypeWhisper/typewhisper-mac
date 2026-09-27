import Darwin
import Foundation
import os

@_spi(FirstPartyPlugins)
public struct PluginInsufficientDiskSpaceError: LocalizedError, Equatable, Sendable {
    public let modelName: String
    public let requiredBytes: Int64
    /// Free space left for this download after subtracting other in-flight model downloads.
    public let availableBytes: Int64
    public let reservedByOtherDownloadsBytes: Int64
    public let volumeName: String?

    public init(
        modelName: String,
        requiredBytes: Int64,
        availableBytes: Int64,
        reservedByOtherDownloadsBytes: Int64 = 0,
        volumeName: String? = nil
    ) {
        self.modelName = modelName
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
        self.reservedByOtherDownloadsBytes = reservedByOtherDownloadsBytes
        self.volumeName = volumeName
    }

    public var errorDescription: String? {
        let required = Self.format(requiredBytes)
        let available = Self.format(availableBytes)
        var message: String
        if let volumeName, !volumeName.isEmpty {
            message = String(localized: "Not enough disk space to download \(modelName). It needs \(required) of free space, but only \(available) is available on “\(volumeName)”.")
        } else {
            message = String(localized: "Not enough disk space to download \(modelName). It needs \(required) of free space, but only \(available) is available.")
        }
        if reservedByOtherDownloadsBytes > 0 {
            let reserved = Self.format(reservedByOtherDownloadsBytes)
            message += " " + String(localized: "Other model downloads in progress still need \(reserved).")
        }
        return message + " " + String(localized: "Free up space and try again.")
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}

@_spi(FirstPartyPlugins)
public struct PluginDiskSpaceVolume: Equatable, Sendable {
    /// Stable key for the volume, used to group concurrent reservations.
    public let identifier: String
    public let name: String?
    public let availableBytes: Int64

    public init(identifier: String, name: String?, availableBytes: Int64) {
        self.identifier = identifier
        self.name = name
        self.availableBytes = availableBytes
    }

    /// Resolves the volume that will receive files written to `url`.
    ///
    /// The destination often does not exist yet, so this walks up to the nearest
    /// existing ancestor and resolves symlinks there. A plugin data directory that
    /// links to an external disk is therefore measured on that disk.
    public static func containing(_ url: URL) -> PluginDiskSpaceVolume? {
        let fileManager = FileManager.default
        var path = url.standardizedFileURL.path
        while !fileManager.fileExists(atPath: path) {
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { return nil }
            path = parent
        }

        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeURLKey,
            .volumeLocalizedNameKey,
        ]) else {
            return nil
        }

        // Important-usage capacity includes purgeable space macOS frees on demand.
        // Some external and network volumes report 0 or nothing for it.
        let available: Int64
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            available = important
        } else if let basic = values.volumeAvailableCapacity {
            available = Int64(basic)
        } else {
            return nil
        }

        return PluginDiskSpaceVolume(
            identifier: values.volume?.standardizedFileURL.path ?? resolved.path,
            name: values.volumeLocalizedName,
            availableBytes: available
        )
    }
}

/// Holds space for a model download until `release()` is called or the
/// reservation is deallocated.
@_spi(FirstPartyPlugins)
public final class PluginDownloadSpaceReservation: Sendable {
    private let releaseAction: @Sendable () -> Void
    private let released = OSAllocatedUnfairLock(initialState: false)

    init(releaseAction: @escaping @Sendable () -> Void) {
        self.releaseAction = releaseAction
    }

    deinit { release() }

    public func release() {
        let shouldRelease = released.withLock { released -> Bool in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease { releaseAction() }
    }
}

@_spi(FirstPartyPlugins)
public enum PluginDownloadDiskSpace {
    /// Extra room kept free beyond the download itself for metadata, temporary
    /// files, and Core ML compilation caches.
    public static let defaultHeadroomBytes: Int64 = 256 * 1024 * 1024

    private static let logger = Logger(subsystem: "com.typewhisper.sdk", category: "DiskSpace")

    /// Reserves space for a download or throws `PluginInsufficientDiskSpaceError`.
    ///
    /// - Parameters:
    ///   - downloadBytes: Total size of the files the download will write.
    ///   - destination: Directory the files are written to. It does not have to exist yet.
    ///   - trackedDirectory: Directory that grows while the download runs. Bytes written
    ///     there count against this reservation, so parallel downloads are not charged
    ///     twice for data that is already on disk.
    ///   - stagingDirectory: Where the downloader writes files before moving them into
    ///     `destination`, such as URLSession's temporary directory. When it is on
    ///     another volume, that volume must also hold `stagingBytes`.
    ///   - stagingBytes: Largest amount staged at once, usually the largest single file.
    ///   - modelName: Display name used in the error message.
    /// - Returns: A reservation, or `nil` when the volume capacity cannot be determined.
    ///   An unknown capacity never blocks a download.
    public static func reserve(
        downloadBytes: Int64,
        destination: URL,
        trackedDirectory: URL? = nil,
        stagingDirectory: URL? = nil,
        stagingBytes: Int64 = 0,
        modelName: String,
        headroomBytes: Int64 = defaultHeadroomBytes
    ) throws -> PluginDownloadSpaceReservation? {
        try PluginDiskSpaceLedger.shared.reserve(
            downloadBytes: downloadBytes,
            destination: destination,
            trackedDirectory: trackedDirectory,
            stagingDirectory: stagingDirectory,
            stagingBytes: stagingBytes,
            modelName: modelName,
            headroomBytes: headroomBytes
        )
    }

    /// Looks up the download size on Hugging Face and reserves space for it.
    ///
    /// Returns `nil` without checking when the size lookup fails, for example when
    /// the Mac is offline. The download then reports its own, more specific error.
    ///
    /// - Parameter localRepositoryRoot: Directory that mirrors the repository layout.
    ///   Pass it when the downloader skips or resumes files that are already there.
    ///   Only files at the listed remote paths, or their `.partial` counterparts,
    ///   count as downloaded.
    public static func reserveHuggingFaceDownload(
        repositoryID: String,
        revision: String = "main",
        path: String? = nil,
        matching patterns: [String] = [],
        token: String? = nil,
        destination: URL,
        trackedDirectory: URL? = nil,
        localRepositoryRoot: URL? = nil,
        stagingDirectory: URL? = nil,
        modelName: String,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async throws -> PluginDownloadSpaceReservation? {
        let downloadBytes: Int64
        let stagingBytes: Int64
        do {
            let files = try await PluginHuggingFaceDownloadSize.files(
                repositoryID: repositoryID,
                revision: revision,
                path: path,
                matching: patterns,
                token: token,
                dataFetcher: dataFetcher
            )
            downloadBytes = localRepositoryRoot.map {
                PluginHuggingFaceDownloadSize.missingBytes(of: files, in: $0)
            } ?? files.reduce(0) { $0 + $1.size }
            // Snapshot downloads stage several files at once, and a server that
            // ignores a resume request sends the whole file again.
            stagingBytes = files.reduce(0) { $0 + $1.size }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.info("Skipping disk space check for \(repositoryID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        try Task.checkCancellation()
        return try reserve(
            downloadBytes: downloadBytes,
            destination: destination,
            trackedDirectory: trackedDirectory,
            stagingDirectory: stagingDirectory,
            stagingBytes: stagingBytes,
            modelName: modelName
        )
    }

    /// Sum of regular file sizes below `directory`, without following symlinks.
    public static func directorySize(_ directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}

final class PluginDiskSpaceLedger: @unchecked Sendable {
    static let shared = PluginDiskSpaceLedger()

    private struct Entry {
        let volumeIdentifier: String
        let downloadBytes: Int64
        let headroomBytes: Int64
        let trackedDirectory: URL?
        let baselineBytes: Int64
        /// Set once another reservation tracked the same or a nested directory.
        /// Growth can then no longer be attributed, even after the other ends.
        var sharesTrackedDirectory = false
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private let volumeProvider: (URL) -> PluginDiskSpaceVolume?
    private let directorySize: (URL) -> Int64

    init(
        volumeProvider: @escaping (URL) -> PluginDiskSpaceVolume? = PluginDiskSpaceVolume.containing,
        directorySize: @escaping (URL) -> Int64 = PluginDownloadDiskSpace.directorySize
    ) {
        self.volumeProvider = volumeProvider
        self.directorySize = directorySize
    }

    var activeReservationCount: Int {
        lock.withLock { entries.count }
    }

    func reserve(
        downloadBytes: Int64,
        destination: URL,
        trackedDirectory: URL?,
        stagingDirectory: URL? = nil,
        stagingBytes: Int64 = 0,
        modelName: String,
        headroomBytes: Int64
    ) throws -> PluginDownloadSpaceReservation? {
        // Hold the lock across measuring and inserting so two downloads that
        // start together cannot both claim the same free space.
        try lock.withLock {
            guard let volume = volumeProvider(destination) else { return nil }

            var requirements = [(
                volume: volume,
                entry: Entry(
                    volumeIdentifier: volume.identifier,
                    downloadBytes: max(downloadBytes, 0),
                    headroomBytes: max(headroomBytes, 0),
                    trackedDirectory: trackedDirectory,
                    baselineBytes: trackedDirectory.map(directorySize) ?? 0
                )
            )]
            // A staging copy on the same volume is moved, not duplicated.
            if let stagingDirectory,
               let stagingVolume = volumeProvider(stagingDirectory),
               stagingVolume.identifier != volume.identifier {
                requirements.append((
                    volume: stagingVolume,
                    entry: Entry(
                        volumeIdentifier: stagingVolume.identifier,
                        downloadBytes: max(stagingBytes, 0),
                        headroomBytes: 0,
                        trackedDirectory: nil,
                        baselineBytes: 0
                    )
                ))
            }

            for requirement in requirements {
                let needed = requirement.entry.downloadBytes + requirement.entry.headroomBytes
                let reservedByOthers = entries
                    .filter { $0.value.volumeIdentifier == requirement.volume.identifier }
                    .reduce(Int64(0)) { $0 + outstandingBytes(for: $1.key) }
                let available = max(requirement.volume.availableBytes - reservedByOthers, 0)
                guard available >= needed else {
                    throw PluginInsufficientDiskSpaceError(
                        modelName: modelName,
                        requiredBytes: needed,
                        availableBytes: available,
                        reservedByOtherDownloadsBytes: reservedByOthers,
                        volumeName: requirement.volume.name
                    )
                }
            }

            let ids = requirements.map { requirement in
                let id = UUID()
                var entry = requirement.entry
                if let trackedDirectory = entry.trackedDirectory {
                    for (otherID, other) in entries {
                        guard let otherDirectory = other.trackedDirectory,
                              Self.directoriesOverlap(otherDirectory, trackedDirectory) else { continue }
                        entries[otherID]?.sharesTrackedDirectory = true
                        entry.sharesTrackedDirectory = true
                    }
                }
                entries[id] = entry
                return id
            }
            return PluginDownloadSpaceReservation { [weak self] in
                self?.lock.withLock {
                    for id in ids { _ = self?.entries.removeValue(forKey: id) }
                }
            }
        }
    }

    /// Written bytes only offset the download part. The headroom stays reserved
    /// even when temporary copies make a download write more than expected.
    /// Reservations that ever shared a tracked directory keep the full amount.
    private func outstandingBytes(for id: UUID) -> Int64 {
        guard let entry = entries[id] else { return 0 }
        guard let trackedDirectory = entry.trackedDirectory,
              !entry.sharesTrackedDirectory else {
            return entry.downloadBytes + entry.headroomBytes
        }
        let written = max(directorySize(trackedDirectory) - entry.baselineBytes, 0)
        return max(entry.downloadBytes - written, 0) + entry.headroomBytes
    }

    static func directoriesOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = canonicalPath(lhs)
        let right = canonicalPath(rhs)
        return left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    /// Resolves symlinks in the nearest existing ancestor, so aliases of the same
    /// directory compare equal even before the directory itself exists.
    static func canonicalPath(_ url: URL) -> String {
        let fileManager = FileManager.default
        var existing = url.standardizedFileURL.path
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: existing) {
            let parent = (existing as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != existing else { break }
            missingComponents.insert((existing as NSString).lastPathComponent, at: 0)
            existing = parent
        }
        let resolved = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        return missingComponents.reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
    }
}

@_spi(FirstPartyPlugins)
public enum PluginHuggingFaceDownloadSize {
    public enum LookupError: Error, Equatable {
        case invalidRepository
        case http(Int)
        case tooManyPages
    }

    public struct RemoteFile: Equatable, Sendable {
        public let path: String
        public let size: Int64

        public init(path: String, size: Int64) {
            self.path = path
            self.size = size
        }
    }

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    private static let maxPages = 50

    /// Total size of the files a snapshot download of `repositoryID` would fetch.
    public static func totalBytes(
        repositoryID: String,
        revision: String = "main",
        path: String? = nil,
        matching patterns: [String] = [],
        token: String? = nil,
        host: URL = URL(string: "https://huggingface.co")!,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async throws -> Int64 {
        try await files(
            repositoryID: repositoryID,
            revision: revision,
            path: path,
            matching: patterns,
            token: token,
            host: host,
            dataFetcher: dataFetcher
        ).reduce(0) { $0 + $1.size }
    }

    /// Files a snapshot download of `repositoryID` would fetch, with their sizes.
    ///
    /// - Parameters:
    ///   - path: Limits the listing to a folder inside the repository.
    ///   - patterns: `fnmatch` globs matched against the full repository path, the same
    ///     way swift-huggingface filters `downloadSnapshot(matching:)`. Empty matches all files.
    public static func files(
        repositoryID: String,
        revision: String = "main",
        path: String? = nil,
        matching patterns: [String] = [],
        token: String? = nil,
        host: URL = URL(string: "https://huggingface.co")!,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async throws -> [RemoteFile] {
        let repositoryParts = repositoryID.split(separator: "/", omittingEmptySubsequences: false)
        guard repositoryParts.count == 2,
              repositoryParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LookupError.invalidRepository
        }

        var url = host
            .appendingPathComponent("api")
            .appendingPathComponent("models")
            .appendingPathComponent(String(repositoryParts[0]))
            .appendingPathComponent(String(repositoryParts[1]))
            .appendingPathComponent("tree")
            .appendingPathComponent(revision)
        for component in (path ?? "").split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LookupError.invalidRepository
        }
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]

        var nextURL = components.url
        var files: [RemoteFile] = []
        var pages = 0
        while let pageURL = nextURL {
            pages += 1
            guard pages <= maxPages else { throw LookupError.tooManyPages }
            try Task.checkCancellation()

            var request = URLRequest(url: pageURL)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let token = PluginHuggingFaceTokenHelper.normalizedToken(token) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await dataFetcher(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw LookupError.http(http.statusCode)
            }

            for entry in try JSONDecoder().decode([TreeEntry].self, from: data)
            where entry.type == "file" && matches(entry.path, patterns: patterns) {
                files.append(RemoteFile(path: entry.path, size: max(entry.size ?? 0, 0)))
            }
            nextURL = (response as? HTTPURLResponse).flatMap(nextPageURL)
        }
        return files
    }

    /// Bytes still missing below `localRoot`, which mirrors the repository layout.
    /// A local file, or a `.partial` file a resuming downloader left behind, counts
    /// up to the remote file's size. Unrelated local files are ignored.
    public static func missingBytes(of files: [RemoteFile], in localRoot: URL) -> Int64 {
        files.reduce(0) { total, file in
            let local = localRoot.appendingPathComponent(file.path)
            let present = regularFileSize(local)
                ?? regularFileSize(local.appendingPathExtension("partial"))
                ?? 0
            return total + max(file.size - min(present, file.size), 0)
        }
    }

    private static func regularFileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    static func matches(_ path: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        return patterns.contains { fnmatch($0, path, 0) == 0 }
    }

    static func nextPageURL(from response: HTTPURLResponse) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") {
            let segments = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segments.dropFirst().contains(where: { $0 == "rel=\"next\"" || $0 == "rel=next" }),
                  let target = segments.first,
                  target.hasPrefix("<"), target.hasSuffix(">") else { continue }
            return URL(string: String(target.dropFirst().dropLast()))
        }
        return nil
    }
}
