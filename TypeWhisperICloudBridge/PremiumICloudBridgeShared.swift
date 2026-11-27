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
    /// Every reply is an encoded `PremiumICloudBridgeReply`.
    func synchronize(reply: @escaping (Data) -> Void)
    func deleteRemotePackage(reply: @escaping (Data) -> Void)
    func removeDevice(_ deviceID: String, reply: @escaping (Data) -> Void)

    // API keys in iCloud Keychain (`SharedAPIKeyItemFormat`). Every reply is an encoded
    // `SharedAPIKeyBridgeReply`; values never appear in logs or errors.

    /// Every present shared item with a valid account, with its modification date.
    func sharedAPIKeys(reply: @escaping (Data) -> Void)
    /// Adds or replaces the item of `account`. `displayName` goes into the item label.
    func setSharedAPIKey(
        _ account: String,
        value: Data,
        displayName: String,
        reply: @escaping (Data) -> Void
    )
    /// Deletes the item of `account` on every device that syncs it.
    func deleteSharedAPIKey(_ account: String, reply: @escaping (Data) -> Void)
}

enum PremiumICloudBridgeError: LocalizedError, Codable, Equatable, Sendable {
    case serviceUnavailable
    case appGroupUnavailable
    case iCloudUnavailable
    /// iCloud Drive could not provide a folder of the container, usually while it still
    /// fetches the folder from another device or while the Mac is offline.
    case iCloudFolderNotReady
    case iCloudStorageFull
    case macStorageFull
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            String(localized: "The private iCloud sync helper is unavailable.")
        case .appGroupUnavailable:
            String(localized: "The shared TypeWhisper container is unavailable.")
        case .iCloudUnavailable:
            String(localized: "Sign in to iCloud and enable iCloud Drive to use automatic sync.")
        case .iCloudFolderNotReady:
            String(localized: "iCloud Drive hasn't made the TypeWhisper sync folder available on this Mac yet. TypeWhisper tries again automatically. Check that this Mac is online.")
        case .iCloudStorageFull:
            String(localized: "Your iCloud storage is full. TypeWhisper keeps your changes on this Mac and uploads them once iCloud has space again.")
        case .macStorageFull:
            String(localized: "This Mac is out of storage space, so TypeWhisper can't sync. Free up space and TypeWhisper tries again automatically.")
        case let .operationFailed(message):
            message
        }
    }

    private static let fileProviderErrorDomain = "NSFileProviderErrorDomain"

    /// What a failed file operation means for the user. An error without a known cause keeps
    /// its system description and gains its error codes, so a screenshot of the message is
    /// enough to tell the cause apart.
    static func classify(_ error: any Error) -> PremiumICloudBridgeError {
        if let error = error as? PremiumICloudBridgeError {
            return error
        }
        if let failure = error as? PremiumSyncDeviceRemoval.Failure {
            return .operationFailed(failure.localizedDescription)
        }
        let chain = errorChain(of: error)
        func matches(_ domain: String, _ codes: Int...) -> Bool {
            chain.contains { $0.domain == domain && codes.contains($0.code) }
        }
        // Foundation reports EDQUOT and ENOSPC both as NSFileWriteOutOfSpaceError, so the
        // POSIX code decides between iCloud and the Mac.
        if matches(NSCocoaErrorDomain, NSUbiquitousFileNotUploadedDueToQuotaError)
            || matches(fileProviderErrorDomain, -1003) // insufficient quota
            || matches(NSPOSIXErrorDomain, Int(EDQUOT)) {
            return .iCloudStorageFull
        }
        if matches(NSCocoaErrorDomain, NSFileWriteOutOfSpaceError)
            || matches(NSPOSIXErrorDomain, Int(ENOSPC)) {
            return .macStorageFull
        }
        // Not signed in, iCloud Drive turned off, no iCloud Drive domain.
        if matches(fileProviderErrorDomain, -1000, -2011, -2013) {
            return .iCloudUnavailable
        }
        // A folder iCloud Drive has not fetched yet (EDEADLK), or iCloud cannot be reached.
        if matches(NSPOSIXErrorDomain, Int(EDEADLK))
            || matches(NSCocoaErrorDomain, NSUbiquitousFileUbiquityServerNotAvailable)
            || matches(fileProviderErrorDomain, -1004, -2012) {
            return .iCloudFolderNotReady
        }
        return .operationFailed("\(error.localizedDescription) (\(technicalSummary(of: error)))")
    }

    /// The domain and code of an error and of the errors beneath it, outermost first.
    static func technicalSummary(of error: any Error) -> String {
        errorChain(of: error).map { "\($0.domain) \($0.code)" }.joined(separator: ", ")
    }

    private static func errorChain(of error: any Error) -> [NSError] {
        var chain: [NSError] = []
        var next: NSError? = error as NSError
        while let current = next, chain.count < 8 {
            chain.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }
}

/// What a completed mirror pass found besides the files it copied.
struct PremiumICloudBridgeReport: Codable, Equatable, Sendable {
    /// iCloud refused to upload files of the package because the iCloud storage is full.
    var iCloudStorageFull = false
}

/// The helper's answer to a request, sent over XPC as JSON.
struct PremiumICloudBridgeReply: Codable, Equatable, Sendable {
    var failure: PremiumICloudBridgeError?
    var report = PremiumICloudBridgeReport()

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// A reply that cannot be read counts as a failed helper.
    static func decoded(from data: Data) -> PremiumICloudBridgeReply {
        (try? JSONDecoder().decode(Self.self, from: data))
            ?? PremiumICloudBridgeReply(failure: .serviceUnavailable)
    }
}

/// Whether iCloud has uploaded a file this Mac wrote.
enum PremiumICloudBridgeUploadStatus: Sendable {
    case uploaded
    /// iCloud still has to upload the file; the error says why the last attempt failed.
    case waiting(lastError: (any Error)?)
    /// The status could not be read; the file stays listed with its last known state.
    case unknown
}

/// How the mirror reaches the folders of one side.
///
/// iCloud Drive keeps a folder that another device created, or that macOS evicted to save
/// space, as a dataless placeholder until a process reads it through file coordination. Until
/// then the helper may not list the folder, look up an item in it or create one: the system
/// refuses with EDEADLK ("Resource deadlock avoided"), Foundation reports that as "couldn't be
/// opened" or "couldn't be saved", and `FileManager.fileExists` reports every item in the
/// folder as missing. The iCloud side therefore prepares each folder before it looks into it,
/// and treats a failed lookup as an error instead of a missing item.
struct PremiumICloudBridgeFolderAccess: Sendable {
    enum ItemKind: Equatable, Sendable {
        case missing
        case directory
        case other
    }

    /// Makes a folder's listing available; does nothing for a folder that has one.
    let prepareDirectory: @Sendable (URL) throws -> Void
    /// Whether this side creates and removes items through file coordination.
    let coordinatesChanges: Bool
    /// Whether iCloud has uploaded a file, and why it could not so far.
    let uploadStatus: @Sendable (URL) -> PremiumICloudBridgeUploadStatus

    static let local = PremiumICloudBridgeFolderAccess(
        prepareDirectory: { _ in },
        coordinatesChanges: false,
        uploadStatus: { _ in .uploaded }
    )

    static let iCloud = PremiumICloudBridgeFolderAccess(
        prepareDirectory: { try fetchListingIfDataless($0) },
        coordinatesChanges: true,
        uploadStatus: { url in
            guard let values = try? url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemIsUploadedKey,
                .ubiquitousItemUploadingErrorKey,
            ]) else {
                return .unknown
            }
            guard let isUbiquitous = values.isUbiquitousItem else { return .unknown }
            // A file outside iCloud has nothing to upload.
            guard isUbiquitous else { return .uploaded }
            guard let isUploaded = values.ubiquitousItemIsUploaded else { return .unknown }
            return isUploaded ? .uploaded : .waiting(lastError: values.ubiquitousItemUploadingError)
        }
    )

    /// The kind of item at `url`. Unlike `FileManager.fileExists`, a lookup that fails for
    /// another reason than a missing item throws, so an unreadable folder never counts as empty.
    func itemKind(at url: URL) throws -> ItemKind {
        do {
            return try Self.lookUp(url)
        } catch let error as POSIXError where error.code == .EDEADLK {
            // The item sits in a folder that has no listing yet.
            try prepareDirectory(url.deletingLastPathComponent())
            return try Self.lookUp(url)
        }
    }

    /// Lists a folder after preparing it.
    func contentsOfDirectory(
        at directory: URL,
        includingPropertiesForKeys keys: [URLResourceKey],
        options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles],
        fileManager: FileManager
    ) throws -> [URL] {
        try prepareDirectory(directory)
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: options
        )
    }

    /// Creates a folder and its missing parents, or prepares it if it exists.
    func createDirectory(at directory: URL, fileManager: FileManager) throws {
        switch try itemKind(at: directory) {
        case .directory:
            try prepareDirectory(directory)
        case .other:
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: directory.path])
        case .missing:
            try write(at: directory, options: []) { url in
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    /// Removes an item; one that is already gone counts as removed.
    func removeItem(at url: URL, fileManager: FileManager) throws {
        try write(at: url, options: .forDeleting) { url in
            do {
                try fileManager.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Already gone, which is the requested outcome.
            }
        }
    }

    /// Prepares a folder and every folder below it, so that removing it can walk the tree.
    func prepareTree(at directory: URL, fileManager: FileManager) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        for child in try contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],
            fileManager: fileManager
        ) {
            let values = try child.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true, values.isSymbolicLink != true {
                try prepareTree(at: child, fileManager: fileManager)
            }
        }
    }

    private func write(
        at url: URL,
        options: NSFileCoordinator.WritingOptions,
        _ body: (URL) throws -> Void
    ) throws {
        guard coordinatesChanges else {
            try body(url)
            return
        }
        var coordinationError: NSError?
        var bodyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: options,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try body(coordinatedURL)
            } catch {
                bodyError = error
            }
        }
        if let error = coordinationError ?? bodyError {
            throw error
        }
    }

    private static func lookUp(_ url: URL) throws -> ItemKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                return .missing
            }
            throw posixError(code, at: url)
        }
        return info.st_mode & S_IFMT == S_IFDIR ? .directory : .other
    }

    /// A coordinated read of a dataless folder makes iCloud Drive fetch its listing. It does
    /// not download the files in the folder or the folders below it. A folder that has a
    /// listing is not coordinated, so a regular pass costs one `lstat` per folder.
    private static func fetchListingIfDataless(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            var code = errno
            if code == EDEADLK, directory.pathComponents.count > 1 {
                // The folder sits in a folder that has no listing yet.
                try fetchListingIfDataless(directory.deletingLastPathComponent())
                code = lstat(directory.path, &info) == 0 ? 0 : errno
            }
            if code == ENOENT || code == ENOTDIR {
                return
            }
            if code != 0 {
                throw posixError(code, at: directory)
            }
        }
        guard info.st_flags & UInt32(SF_DATALESS) != 0 else { return }
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: directory,
            options: [],
            error: &coordinationError
        ) { _ in }
        if let coordinationError {
            throw coordinationError
        }
    }

    private static func posixError(_ code: Int32, at url: URL) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path])
    }
}

enum PremiumICloudBridgeFileMirror {
    private static let modificationDateTolerance: TimeInterval = 0.001
    /// Package directories whose files get new names instead of being rewritten: operations
    /// are named by timestamp and ID, assets by their SHA-256 digest.
    private static let writeOnceDirectoryNames: Set<String> = ["ops", "assets"]
    /// Bounds the upload checks of one pass while iCloud keeps files back.
    static let uploadChecksPerPass = 1_000
    private static let local = PremiumICloudBridgeFolderAccess.local

    @discardableResult
    static func synchronize(
        localRoot: URL,
        remoteRoot: URL,
        fileManager: FileManager = .default,
        remoteAccess: PremiumICloudBridgeFolderAccess = .iCloud,
        uploadChecksPerPass: Int = PremiumICloudBridgeFileMirror.uploadChecksPerPass
    ) throws -> PremiumICloudBridgeReport {
        try local.createDirectory(at: localRoot, fileManager: fileManager)
        try remoteAccess.createDirectory(at: remoteRoot, fileManager: fileManager)

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
        let previousState = readMirrorState(at: stateURL, fileManager: fileManager)
        if let base = previousState {
            let remoteFiles = try listFiles(in: remotePackage, access: remoteAccess, fileManager: fileManager)
            let localFiles = try listFiles(in: localPackage, access: local, fileManager: fileManager)
            try propagateDeletions(
                base: base,
                localFiles: localFiles,
                remoteFiles: remoteFiles,
                localPackage: localPackage,
                remotePackage: remotePackage,
                remoteAccess: remoteAccess,
                fileManager: fileManager
            )
        }

        var copiedToICloud: [URL] = []
        let remoteFiles: [String: ListedFile]
        let localFiles: [String: ListedFile]
        do {
            if try local.itemKind(at: localPackage) != .missing {
                try mergeDirectory(
                    from: localPackage,
                    readingWith: local,
                    to: remotePackage,
                    writingWith: remoteAccess,
                    isPackageRoot: true,
                    copied: &copiedToICloud,
                    fileManager: fileManager
                )
            }
            if try remoteAccess.itemKind(at: remotePackage) != .missing {
                var copiedToMirror: [URL] = []
                try mergeDirectory(
                    from: remotePackage,
                    readingWith: remoteAccess,
                    to: localPackage,
                    writingWith: local,
                    isPackageRoot: true,
                    copied: &copiedToMirror,
                    fileManager: fileManager
                )
            }
            remoteFiles = try listFiles(in: remotePackage, access: remoteAccess, fileManager: fileManager)
            localFiles = try listFiles(in: localPackage, access: local, fileManager: fileManager)
        } catch {
            // The next pass finds the copied files unchanged and does not copy them again,
            // so their uploads are remembered before the pass fails.
            rememberUploads(
                copiedToICloud,
                previousState: previousState,
                remotePackage: remotePackage,
                stateURL: stateURL
            )
            throw error
        }
        var base = MirrorState(files: [:])
        for (path, local) in localFiles {
            guard let remote = remoteFiles[path] else { continue }
            base.files[path] = MirrorState.Entry(
                local: local.modificationDate,
                remote: remote.modificationDate
            )
        }
        let uploads = checkUploads(
            pending: previousState?.pendingUploads ?? [],
            refusedForQuota: Set(previousState?.quotaRefusedUploads ?? []),
            copied: copiedToICloud,
            remotePackage: remotePackage,
            remoteFiles: remoteFiles,
            access: remoteAccess,
            limit: uploadChecksPerPass
        )
        base.pendingUploads = uploads.pending
        base.quotaRefusedUploads = uploads.refusedForQuota
        try writeMirrorState(base, to: stateURL)
        return PremiumICloudBridgeReport(iCloudStorageFull: !uploads.refusedForQuota.isEmpty)
    }

    static func deletePackages(
        localRoot: URL,
        remoteRoot: URL,
        fileManager: FileManager = .default,
        remoteAccess: PremiumICloudBridgeFolderAccess = .iCloud
    ) throws {
        for (root, access) in [(localRoot, local), (remoteRoot, remoteAccess)] {
            let package = root.appendingPathComponent(
                PremiumICloudBridgeConstants.packageDirectoryName,
                isDirectory: true
            )
            try access.prepareDirectory(root)
            switch try access.itemKind(at: package) {
            case .missing:
                continue
            case .directory:
                // Removing the package walks every folder in it.
                try access.prepareTree(at: package, fileManager: fileManager)
            case .other:
                break
            }
            try access.removeItem(at: package, fileManager: fileManager)
        }
        let stateURL = mirrorStateURL(localRoot: localRoot)
        if fileManager.fileExists(atPath: stateURL.path) {
            try fileManager.removeItem(at: stateURL)
        }
    }

    /// Files this Mac copied into iCloud are checked on later passes until iCloud has uploaded
    /// them. iCloud Drive keeps a file it cannot upload on this Mac and records why. Whether
    /// the remaining storage takes a file depends on its size, so a large audio file can be
    /// refused while small records still upload; any refusal for quota means iCloud is full.
    /// A pass checks at most `limit` files. The others stay listed and go first next time.
    /// A file refused for quota counts as refused until a check reads a different status.
    private static func checkUploads(
        pending previous: [String],
        refusedForQuota previouslyRefused: Set<String>,
        copied: [URL],
        remotePackage: URL,
        remoteFiles: [String: ListedFile],
        access: PremiumICloudBridgeFolderAccess,
        limit: Int
    ) -> (pending: [String], refusedForQuota: [String]) {
        // Files deleted since drop out; they no longer need an upload.
        let candidates = adding(packagePaths(of: copied, in: remotePackage), to: previous)
            .filter { remoteFiles[$0] != nil }
        let unchecked = Array(candidates.dropFirst(max(limit, 0)))
        var stillWaiting: [String] = []
        var refused = previouslyRefused.intersection(unchecked)
        for path in candidates.prefix(max(limit, 0)) {
            let file = remotePackage.appendingPathComponent(path, isDirectory: false)
            switch access.uploadStatus(file) {
            case .uploaded:
                continue
            case .unknown:
                stillWaiting.append(path)
                if previouslyRefused.contains(path) {
                    refused.insert(path)
                }
            case let .waiting(lastError):
                stillWaiting.append(path)
                if let lastError, PremiumICloudBridgeError.classify(lastError) == .iCloudStorageFull {
                    refused.insert(path)
                }
            }
        }
        return (unchecked + stillWaiting, refused.sorted())
    }

    private static func rememberUploads(
        _ copied: [URL],
        previousState: MirrorState?,
        remotePackage: URL,
        stateURL: URL
    ) {
        let paths = packagePaths(of: copied, in: remotePackage)
        guard !paths.isEmpty else { return }
        // Without a recorded base an empty one is written, which deletes nothing.
        var state = previousState ?? MirrorState(files: [:])
        state.pendingUploads = adding(paths, to: state.pendingUploads ?? [])
        try? writeMirrorState(state, to: stateURL)
    }

    /// `paths` that are not in `list` yet, sorted, after the entries of `list`.
    private static func adding(_ paths: [String], to list: [String]) -> [String] {
        list + Set(paths).subtracting(list).sorted()
    }

    private static func packagePaths(of files: [URL], in package: URL) -> [String] {
        let packagePrefix = package.standardizedFileURL.path + "/"
        return files.compactMap { file in
            let path = file.standardizedFileURL.path
            return path.hasPrefix(packagePrefix) ? String(path.dropFirst(packagePrefix.count)) : nil
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
        /// Package-relative paths this Mac copied into iCloud that iCloud has not uploaded yet.
        var pendingUploads: [String]?
        /// The pending paths whose last check found them refused for quota.
        var quotaRefusedUploads: [String]?
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
        remoteAccess: PremiumICloudBridgeFolderAccess,
        fileManager: FileManager
    ) throws {
        // An empty local mirror means it was reset, for example by erasing all data, not
        // that every file was deleted on purpose. It must never empty the iCloud package.
        let propagatesLocalDeletions = !localFiles.isEmpty
        for (path, entry) in base.files.sorted(by: { $0.key < $1.key }) {
            switch (localFiles[path], remoteFiles[path]) {
            case let (localFile?, nil):
                // Manifest and device files are rewritten in place; a version written after
                // the base wins over the deletion and is copied back by the merge.
                guard !isModified(localFile, since: entry.local) else { continue }
                let file = localPackage.appendingPathComponent(path, isDirectory: false)
                try local.removeItem(at: file, fileManager: fileManager)
                try removeEmptyDirectories(
                    from: file.deletingLastPathComponent(),
                    through: localPackage,
                    access: local,
                    fileManager: fileManager
                )
            case let (nil, remote?) where propagatesLocalDeletions:
                guard !isModified(remote, since: entry.remote) else { continue }
                let file = remotePackage.appendingPathComponent(path, isDirectory: false)
                try remoteAccess.removeItem(at: file, fileManager: fileManager)
                try removeEmptyDirectories(
                    from: file.deletingLastPathComponent(),
                    through: remotePackage,
                    access: remoteAccess,
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
    /// are listed under their real names, so they count as present. A package that cannot be
    /// looked up or listed throws, so it never counts as empty.
    private static func listFiles(
        in package: URL,
        access: PremiumICloudBridgeFolderAccess,
        fileManager: FileManager
    ) throws -> [String: ListedFile] {
        var files: [String: ListedFile] = [:]
        guard try access.itemKind(at: package) != .missing else { return files }
        try listFiles(in: package, prefix: "", into: &files, access: access, fileManager: fileManager)
        return files
    }

    private static func listFiles(
        in directory: URL,
        prefix: String,
        into files: inout [String: ListedFile],
        access: PremiumICloudBridgeFolderAccess,
        fileManager: FileManager
    ) throws {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        let children = try access.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            fileManager: fileManager
        )
        for child in children {
            let values = try child.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { continue }
            let path = prefix + child.lastPathComponent
            if values.isDirectory == true {
                try listFiles(
                    in: child,
                    prefix: path + "/",
                    into: &files,
                    access: access,
                    fileManager: fileManager
                )
            } else {
                files[path] = ListedFile(modificationDate: values.contentModificationDate)
            }
        }
    }

    /// Removes directories a deletion left empty, up to the package itself, so the merge
    /// does not recreate them on the other side.
    private static func removeEmptyDirectories(
        from directory: URL,
        through package: URL,
        access: PremiumICloudBridgeFolderAccess,
        fileManager: FileManager
    ) throws {
        let packagePath = package.standardizedFileURL.path
        var current = directory.standardizedFileURL
        while current.path.hasPrefix(packagePath) {
            guard let contents = try? access.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [],
                options: [],
                fileManager: fileManager
            ), contents.isEmpty else {
                return
            }
            try access.removeItem(at: current, fileManager: fileManager)
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
        readingWith sourceAccess: PremiumICloudBridgeFolderAccess,
        to destination: URL,
        writingWith destinationAccess: PremiumICloudBridgeFolderAccess,
        isPackageRoot: Bool = false,
        isWriteOnce: Bool = false,
        copied: inout [URL],
        fileManager: FileManager
    ) throws {
        try destinationAccess.createDirectory(at: destination, fileManager: fileManager)
        let children = try sourceAccess.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isUbiquitousItemKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            fileManager: fileManager
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
                    readingWith: sourceAccess,
                    to: destinationChild,
                    writingWith: destinationAccess,
                    isWriteOnce: isWriteOnce
                        || (isPackageRoot && writeOnceDirectoryNames.contains(child.lastPathComponent)),
                    copied: &copied,
                    fileManager: fileManager
                )
            } else if try copyNewerFile(
                from: child,
                to: destinationChild,
                writingWith: destinationAccess,
                isWriteOnce: isWriteOnce,
                fileManager: fileManager
            ) {
                copied.append(destinationChild)
            }
        }
    }

    /// Returns whether the file was copied.
    private static func copyNewerFile(
        from source: URL,
        to destination: URL,
        writingWith destinationAccess: PremiumICloudBridgeFolderAccess,
        isWriteOnce: Bool,
        fileManager: FileManager
    ) throws -> Bool {
        let sourceValues = try? source.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .fileSizeKey,
        ])
        let isUbiquitous = sourceValues?.isUbiquitousItem == true
        let destinationExists = try destinationAccess.itemKind(at: destination) != .missing
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
                    return false
                }
            }
            // An older source never replaces the destination, whatever its contents are.
            guard (sourceDate ?? .distantPast) >= (destinationDate ?? .distantPast) else { return false }
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
            return false
        }
        if destinationExists {
            // Metadata was inconclusive; files of different sizes cannot be equal.
            if !sizesDiffer,
               let destinationData = try? Data(contentsOf: destination),
               destinationData == sourceData {
                return false
            }
        } else {
            try destinationAccess.createDirectory(
                at: destination.deletingLastPathComponent(),
                fileManager: fileManager
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
        return true
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
    /// - Parameter access: How the packages are reached. iCloud access also works for local
    ///   folders and for folders of other file providers.
    static func removeRecords(
        of deviceID: String,
        inPackages packages: [URL],
        fileManager: FileManager = .default,
        access: PremiumICloudBridgeFolderAccess = .iCloud
    ) throws {
        let installation = try installation(
            of: deviceID,
            inPackages: packages,
            fileManager: fileManager,
            access: access
        )
        for package in packages {
            try removeRecords(of: installation, inPackage: package, fileManager: fileManager, access: access)
        }
    }

    static func installation(
        of deviceID: String,
        inPackages packages: [URL],
        fileManager: FileManager = .default,
        access: PremiumICloudBridgeFolderAccess = .iCloud
    ) throws -> Installation {
        guard isSafeIdentifier(deviceID) else { throw Failure.invalidIdentifier }
        for package in packages {
            try prepare(package, access: access)
            let file = devicesURL(in: package).appendingPathComponent("\(deviceID).json")
            guard try access.itemKind(at: file) != .missing,
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
        fileManager: FileManager = .default,
        access: PremiumICloudBridgeFolderAccess = .iCloud
    ) throws {
        let devicesURL = devicesURL(in: package)
        try prepare(package, access: access)
        // A package without devices has nothing to remove; an unreadable
        // folder must fail, or a record would stay and be reported removed.
        guard try access.itemKind(at: devicesURL) != .missing else { return }
        let files = try access.contentsOfDirectory(
            at: devicesURL,
            includingPropertiesForKeys: [],
            fileManager: fileManager
        )
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
            try access.removeItem(at: file, fileManager: fileManager)
        }
    }

    private static func devicesURL(in package: URL) -> URL {
        package.appendingPathComponent("devices", isDirectory: true)
    }

    /// Prepares the folders down to the device records, so their lookups are reliable.
    private static func prepare(_ package: URL, access: PremiumICloudBridgeFolderAccess) throws {
        for directory in [package.deletingLastPathComponent(), package, devicesURL(in: package)] {
            try access.prepareDirectory(directory)
        }
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

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
