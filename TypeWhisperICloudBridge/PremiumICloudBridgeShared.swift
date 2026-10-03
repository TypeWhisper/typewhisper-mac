import Foundation

enum PremiumICloudBridgeConstants {
    static let productionServiceBundleIdentifier =
        "com.typewhisper.typewhisper-mac"
    static let productionContainerIdentifier = "iCloud.com.typewhisper.sync"
    static let serviceBundleIdentifierInfoKey =
        "TypeWhisperICloudBridgeServiceIdentifier"
    static let containerIdentifierInfoKey = "TypeWhisperICloudContainer"
    static let packageDirectoryName = "typewhisper-sync"
    /// Hidden, so the mirror never copies it into the package.
    static let mirrorStateFileName = ".typewhisper-sync-mirror-state.json"

    static func serviceBundleIdentifier(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String {
        configuredIdentifier(
            forKey: serviceBundleIdentifierInfoKey,
            in: infoDictionary,
            fallback: productionServiceBundleIdentifier
        )
    }

    static func containerIdentifier(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String {
        configuredIdentifier(
            forKey: containerIdentifierInfoKey,
            in: infoDictionary,
            fallback: productionContainerIdentifier
        )
    }

    private static func configuredIdentifier(
        forKey key: String,
        in infoDictionary: [String: Any]?,
        fallback: String
    ) -> String {
        guard let identifier = infoDictionary?[key] as? String,
              !identifier.isEmpty,
              !identifier.contains("$(") else {
            return fallback
        }
        return identifier
    }

    static func localRootURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let appGroup = bundle.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              !appGroup.isEmpty,
              !appGroup.contains("$("),
              let container = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup
              ) else {
            return nil
        }
        let root = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("TypeWhisper", isDirectory: true)
            .appendingPathComponent("ICloudBridge", isDirectory: true)
        guard let namespace = localMirrorNamespace(
            infoDictionary: bundle.infoDictionary
        ) else {
            return root
        }
        return root
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    static func localMirrorNamespace(
        infoDictionary: [String: Any]?
    ) -> String? {
        let identifier = containerIdentifier(
            infoDictionary: infoDictionary
        )
        guard identifier != productionContainerIdentifier,
              identifier != ".",
              identifier != "..",
              !identifier.contains("/"),
              !identifier.contains("\\"),
              identifier == URL(fileURLWithPath: identifier).lastPathComponent else {
            return nil
        }
        return identifier
    }

    static func embeddedServiceURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent("TypeWhisperICloudBridge.xpc", isDirectory: true)
    }
}

@objc(PremiumICloudBridgeXPCProtocol)
protocol PremiumICloudBridgeXPCProtocol: NSObjectProtocol {
    func synchronize(reply: @escaping (String?) -> Void)
    func deleteRemotePackage(reply: @escaping (String?) -> Void)
}

enum PremiumICloudBridgeError: LocalizedError, Equatable, Sendable {
    case serviceUnavailable
    case appGroupUnavailable
    case iCloudUnavailable
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            "The private iCloud sync helper is unavailable."
        case .appGroupUnavailable:
            "The shared TypeWhisper container is unavailable."
        case .iCloudUnavailable:
            "Sign in to iCloud and enable iCloud Drive to use automatic sync."
        case let .operationFailed(message):
            message
        }
    }
}

enum PremiumICloudBridgeFileMirror {
    private static let modificationDateTolerance: TimeInterval = 0.001
    /// Package directories whose files get new names instead of being rewritten: operations
    /// are named by timestamp and ID, assets by their SHA-256 digest.
    private static let writeOnceDirectoryNames: Set<String> = ["ops", "assets"]

    static func synchronize(
        localRoot: URL,
        remoteRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: localRoot,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: remoteRoot,
            withIntermediateDirectories: true
        )

        let localPackage = localRoot.appendingPathComponent(
            PremiumICloudBridgeConstants.packageDirectoryName,
            isDirectory: true
        )
        let remotePackage = remoteRoot.appendingPathComponent(
            PremiumICloudBridgeConstants.packageDirectoryName,
            isDirectory: true
        )
        let stateURL = mirrorStateURL(localRoot: localRoot)

        // Both sides are listed before anything is deleted, so a listing failure aborts the
        // pass without touching either side.
        if let base = readMirrorState(at: stateURL, fileManager: fileManager) {
            let remoteFiles = try listFiles(in: remotePackage, fileManager: fileManager)
            let localFiles = try listFiles(in: localPackage, fileManager: fileManager)
            try propagateDeletions(
                base: base,
                localFiles: localFiles,
                remoteFiles: remoteFiles,
                localPackage: localPackage,
                remotePackage: remotePackage,
                fileManager: fileManager
            )
        }

        if fileManager.fileExists(atPath: localPackage.path) {
            try mergeDirectory(
                from: localPackage,
                to: remotePackage,
                isPackageRoot: true,
                fileManager: fileManager
            )
        }
        if fileManager.fileExists(atPath: remotePackage.path) {
            try mergeDirectory(
                from: remotePackage,
                to: localPackage,
                isPackageRoot: true,
                fileManager: fileManager
            )
        }

        let remoteFiles = try listFiles(in: remotePackage, fileManager: fileManager)
        let localFiles = try listFiles(in: localPackage, fileManager: fileManager)
        var base = MirrorState(files: [:])
        for (path, local) in localFiles {
            guard let remote = remoteFiles[path] else { continue }
            base.files[path] = MirrorState.Entry(
                local: local.modificationDate,
                remote: remote.modificationDate
            )
        }
        try writeMirrorState(base, to: stateURL)
    }

    static func deletePackages(
        localRoot: URL,
        remoteRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        for root in [localRoot, remoteRoot] {
            let package = root.appendingPathComponent(
                PremiumICloudBridgeConstants.packageDirectoryName,
                isDirectory: true
            )
            if fileManager.fileExists(atPath: package.path) {
                try fileManager.removeItem(at: package)
            }
        }
        let stateURL = mirrorStateURL(localRoot: localRoot)
        if fileManager.fileExists(atPath: stateURL.path) {
            try fileManager.removeItem(at: stateURL)
        }
    }

    static func mirrorStateURL(localRoot: URL) -> URL {
        localRoot.appendingPathComponent(
            PremiumICloudBridgeConstants.mirrorStateFileName,
            isDirectory: false
        )
    }

    /// Package-relative paths that were present on both sides after the last complete pass,
    /// with the modification date each side had then. A path from this base that is missing
    /// on one side was deleted there since.
    private struct MirrorState: Codable {
        struct Entry: Codable {
            var local: Date?
            var remote: Date?
        }

        var version = 1
        var files: [String: Entry]
    }

    private struct ListedFile {
        let modificationDate: Date?
    }

    private static func propagateDeletions(
        base: MirrorState,
        localFiles: [String: ListedFile],
        remoteFiles: [String: ListedFile],
        localPackage: URL,
        remotePackage: URL,
        fileManager: FileManager
    ) throws {
        // An empty local mirror means it was reset, for example by erasing all data, not
        // that every file was deleted on purpose. It must never empty the iCloud package.
        let propagatesLocalDeletions = !localFiles.isEmpty
        for (path, entry) in base.files.sorted(by: { $0.key < $1.key }) {
            switch (localFiles[path], remoteFiles[path]) {
            case let (local?, nil):
                // Manifest and device files are rewritten in place; a version written after
                // the base wins over the deletion and is copied back by the merge.
                guard !isModified(local, since: entry.local) else { continue }
                let file = localPackage.appendingPathComponent(path, isDirectory: false)
                try removeItem(at: file, coordinated: false, fileManager: fileManager)
                try removeEmptyDirectories(
                    from: file.deletingLastPathComponent(),
                    through: localPackage,
                    coordinated: false,
                    fileManager: fileManager
                )
            case let (nil, remote?) where propagatesLocalDeletions:
                guard !isModified(remote, since: entry.remote) else { continue }
                let file = remotePackage.appendingPathComponent(path, isDirectory: false)
                try removeItem(at: file, coordinated: true, fileManager: fileManager)
                try removeEmptyDirectories(
                    from: file.deletingLastPathComponent(),
                    through: remotePackage,
                    coordinated: true,
                    fileManager: fileManager
                )
            default:
                continue
            }
        }
    }

    /// Compares against the date recorded for the same side instead of the time of the last
    /// pass, so clock differences between devices cannot hide a rewrite.
    private static func isModified(_ file: ListedFile, since recordedDate: Date?) -> Bool {
        guard let date = file.modificationDate, let recordedDate else { return true }
        return abs(date.timeIntervalSince(recordedDate)) >= modificationDateTolerance
    }

    /// Lists the files of a package by package-relative path. Dataless iCloud placeholders
    /// are listed under their real names, so they count as present.
    private static func listFiles(
        in package: URL,
        fileManager: FileManager
    ) throws -> [String: ListedFile] {
        var files: [String: ListedFile] = [:]
        guard fileManager.fileExists(atPath: package.path) else { return files }
        try listFiles(in: package, prefix: "", into: &files, fileManager: fileManager)
        return files
    }

    private static func listFiles(
        in directory: URL,
        prefix: String,
        into files: inout [String: ListedFile],
        fileManager: FileManager
    ) throws {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let values = try child.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { continue }
            let path = prefix + child.lastPathComponent
            if values.isDirectory == true {
                try listFiles(in: child, prefix: path + "/", into: &files, fileManager: fileManager)
            } else {
                files[path] = ListedFile(modificationDate: values.contentModificationDate)
            }
        }
    }

    private static func removeItem(
        at url: URL,
        coordinated: Bool,
        fileManager: FileManager
    ) throws {
        func remove(_ url: URL) throws {
            do {
                try fileManager.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Already gone, which is the requested outcome.
            }
        }
        guard coordinated else {
            try remove(url)
            return
        }
        var coordinationError: NSError?
        var removalError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try remove(coordinatedURL)
            } catch {
                removalError = error
            }
        }
        if let error = coordinationError ?? removalError {
            throw error
        }
    }

    /// Removes directories a deletion left empty, up to the package itself, so the merge
    /// does not recreate them on the other side.
    private static func removeEmptyDirectories(
        from directory: URL,
        through package: URL,
        coordinated: Bool,
        fileManager: FileManager
    ) throws {
        let packagePath = package.standardizedFileURL.path
        var current = directory.standardizedFileURL
        while current.path.hasPrefix(packagePath) {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: current.path),
                  contents.isEmpty else {
                return
            }
            try removeItem(at: current, coordinated: coordinated, fileManager: fileManager)
            guard current.path != packagePath else { return }
            current = current.deletingLastPathComponent()
        }
    }

    private static func readMirrorState(
        at url: URL,
        fileManager: FileManager
    ) -> MirrorState? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(MirrorState.self, from: data),
              state.version == 1 else {
            return nil
        }
        return state
    }

    private static func writeMirrorState(_ state: MirrorState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private static func mergeDirectory(
        from source: URL,
        to destination: URL,
        isPackageRoot: Bool = false,
        isWriteOnce: Bool = false,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isUbiquitousItemKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else { continue }
            let destinationChild = destination.appendingPathComponent(
                child.lastPathComponent,
                isDirectory: values.isDirectory == true
            )
            if values.isDirectory == true {
                try mergeDirectory(
                    from: child,
                    to: destinationChild,
                    isWriteOnce: isWriteOnce
                        || (isPackageRoot && writeOnceDirectoryNames.contains(child.lastPathComponent)),
                    fileManager: fileManager
                )
            } else {
                try copyNewerFile(
                    from: child,
                    to: destinationChild,
                    isWriteOnce: isWriteOnce,
                    fileManager: fileManager
                )
            }
        }
    }

    private static func copyNewerFile(
        from source: URL,
        to destination: URL,
        isWriteOnce: Bool,
        fileManager: FileManager
    ) throws {
        let sourceValues = try? source.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .fileSizeKey,
        ])
        let isUbiquitous = sourceValues?.isUbiquitousItem == true
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        var sizesDiffer = false
        if destinationExists {
            let sourceDate = try source.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            let destinationValues = try destination.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            let destinationDate = destinationValues.contentModificationDate
            if let sourceSize = sourceValues?.fileSize,
               let destinationSize = destinationValues.fileSize {
                sizesDiffer = sourceSize != destinationSize
                // Copies keep the source modification date, so a mirrored pair of write-once
                // files has matching metadata and neither side needs to be downloaded or read.
                // The tolerance only absorbs the precision lost when the date is written back.
                // Manifest and device files are rewritten in place and always compare contents.
                if isWriteOnce,
                   !sizesDiffer,
                   let sourceDate,
                   let destinationDate,
                   abs(sourceDate.timeIntervalSince(destinationDate)) < modificationDateTolerance {
                    return
                }
            }
            // An older source never replaces the destination, whatever its contents are.
            guard (sourceDate ?? .distantPast) >= (destinationDate ?? .distantPast) else { return }
        }

        if isUbiquitous {
            try? fileManager.startDownloadingUbiquitousItem(at: source)
        }

        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: source)
        } catch where isUbiquitous {
            // A dataless iCloud placeholder is downloaded asynchronously. The
            // next periodic bridge pass will copy it without blocking uploads.
            return
        }
        if destinationExists {
            // Metadata was inconclusive; files of different sizes cannot be equal.
            if !sizesDiffer,
               let destinationData = try? Data(contentsOf: destination),
               destinationData == sourceData {
                return
            }
        } else {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let sourceDate = try source.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        try sourceData.write(to: destination, options: .atomic)
        if let sourceDate {
            try fileManager.setAttributes(
                [.modificationDate: sourceDate],
                ofItemAtPath: destination.path
            )
        }
    }
}
