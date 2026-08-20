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
                fileManager: fileManager
            )
        }
        if fileManager.fileExists(atPath: remotePackage.path) {
            try mergeDirectory(
                from: remotePackage,
                to: localPackage,
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
                    fileManager: fileManager
                )
            } else {
                try copyNewerFile(
                    from: child,
                    to: destinationChild,
                    fileManager: fileManager
                )
            }
        }
    }

    private static func copyNewerFile(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let isUbiquitous = (try? source.resourceValues(
            forKeys: [.isUbiquitousItemKey]
        ).isUbiquitousItem) == true
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
        if fileManager.fileExists(atPath: destination.path) {
            if let destinationData = try? Data(contentsOf: destination),
               destinationData == sourceData {
                return
            }
            let sourceDate = try source.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate ?? .distantPast
            let destinationDate = try destination.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate ?? .distantPast
            guard sourceDate >= destinationDate else { return }
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
