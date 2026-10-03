import Foundation

enum PremiumICloudBridgeConstants {
    static let productionServiceBundleIdentifier =
        "com.typewhisper.typewhisper-mac"
    static let productionContainerIdentifier = "iCloud.com.typewhisper.sync"
    static let serviceBundleIdentifierInfoKey =
        "TypeWhisperICloudBridgeServiceIdentifier"
    static let containerIdentifierInfoKey = "TypeWhisperICloudContainer"
    static let packageDirectoryName = "typewhisper-sync"

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
    func removeDevice(_ deviceID: String, reply: @escaping (String?) -> Void)
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

/// Removes a device from the sync list: its record and the older records of
/// the same installation, which share its history origin. Synced entries stay.
enum PremiumSyncDeviceRemoval {
    struct Installation: Equatable {
        let deviceID: String
        let historyOrigin: String?
    }

    enum Failure: LocalizedError, Equatable {
        case invalidIdentifier
        case recordUnreadable

        var errorDescription: String? {
            switch self {
            case .invalidIdentifier: "The synchronized device identifier is invalid."
            case .recordUnreadable: "The device record could not be read. Try again after the next sync."
            }
        }
    }

    private struct Record: Decodable {
        let deviceId: String
        let historyOriginDeviceID: String?
    }

    static func isSafeIdentifier(_ deviceID: String) -> Bool {
        !deviceID.isEmpty
            && deviceID == URL(fileURLWithPath: deviceID).lastPathComponent
            && !deviceID.contains("/")
            && !deviceID.contains("\\")
    }

    /// Removes the device from every package, for example the bridge's mirror
    /// and the iCloud container. The installation is read once from the first
    /// readable record, so a copy missing on one side still removes the other
    /// side's older records of the same installation.
    /// - Parameter packages: `typewhisper-sync` folders.
    static func removeRecords(
        of deviceID: String,
        inPackages packages: [URL],
        fileManager: FileManager = .default
    ) throws {
        let installation = try installation(of: deviceID, inPackages: packages, fileManager: fileManager)
        for package in packages {
            try removeRecords(of: installation, inPackage: package, fileManager: fileManager)
        }
    }

    static func installation(
        of deviceID: String,
        inPackages packages: [URL],
        fileManager: FileManager = .default
    ) throws -> Installation {
        guard isSafeIdentifier(deviceID) else { throw Failure.invalidIdentifier }
        for package in packages {
            let file = devicesURL(in: package).appendingPathComponent("\(deviceID).json")
            guard fileManager.fileExists(atPath: file.path),
                  let record = record(at: file, fileManager: fileManager) else {
                continue
            }
            return Installation(deviceID: record.deviceId, historyOrigin: normalized(record.historyOriginDeviceID))
        }
        throw Failure.recordUnreadable
    }

    static func removeRecords(
        of installation: Installation,
        inPackage package: URL,
        fileManager: FileManager = .default
    ) throws {
        let devicesURL = devicesURL(in: package)
        guard let files = try? fileManager.contentsOfDirectory(
            at: devicesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let matching = files.filter { file in
            guard file.pathExtension == "json" else { return false }
            if file.deletingPathExtension().lastPathComponent == installation.deviceID { return true }
            guard let origin = installation.historyOrigin,
                  let candidate = record(at: file, fileManager: fileManager) else {
                return false
            }
            return normalized(candidate.historyOriginDeviceID) == origin
        }
        for file in matching {
            try delete(file, fileManager: fileManager)
        }
    }

    private static func devicesURL(in package: URL) -> URL {
        package.appendingPathComponent("devices", isDirectory: true)
    }

    /// A record in iCloud may not be downloaded yet; a coordinated read downloads it.
    private static func record(at file: URL, fileManager: FileManager) -> Record? {
        if fileManager.isUbiquitousItem(at: file) {
            try? fileManager.startDownloadingUbiquitousItem(at: file)
        }
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: file,
            options: [],
            error: &coordinationError
        ) { coordinatedFile in
            data = try? Data(contentsOf: coordinatedFile)
        }
        guard coordinationError == nil,
              let data,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              file.deletingPathExtension().lastPathComponent == record.deviceId else {
            return nil
        }
        return record
    }

    private static func delete(_ file: URL, fileManager: FileManager) throws {
        var removalError: (any Error)?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: file,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedFile in
            do {
                try fileManager.removeItem(at: coordinatedFile)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Already gone, which is the requested outcome.
            } catch {
                removalError = error
            }
        }
        if let error = coordinationError ?? removalError { throw error }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
