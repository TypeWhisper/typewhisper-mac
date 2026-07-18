import Foundation

enum CloudFolderSyncProvider: String, Equatable, Sendable {
    case iCloudDrive = "iCloud Drive"
    case oneDrive = "OneDrive"
    case dropbox = "Dropbox"
    case custom = "Custom Folder"

    var displayName: String {
        switch self {
        case .iCloudDrive:
            String(localized: "iCloud Drive")
        case .oneDrive:
            String(localized: "OneDrive")
        case .dropbox:
            String(localized: "Dropbox")
        case .custom:
            String(localized: "Custom Folder")
        }
    }

    static func detect(folderURL: URL) -> CloudFolderSyncProvider {
        let path = folderURL.path.lowercased()
        if path.contains("mobile documents") || path.contains("icloud drive") {
            return .iCloudDrive
        }
        if path.contains("onedrive") {
            return .oneDrive
        }
        if path.contains("dropbox") {
            return .dropbox
        }
        return .custom
    }
}

struct CloudFolderSyncState: Codable, Equatable, Sendable {
    var deviceId: String
    var knownLocalItemIDs: Set<String>
    var exportedItemVersions: [String: String]
    var appliedOperationIDs: Set<String>
    var lastSyncAt: Date?

    init(
        deviceId: String = UUID().uuidString,
        knownLocalItemIDs: Set<String> = [],
        exportedItemVersions: [String: String] = [:],
        appliedOperationIDs: Set<String> = [],
        lastSyncAt: Date? = nil
    ) {
        self.deviceId = deviceId
        self.knownLocalItemIDs = knownLocalItemIDs
        self.exportedItemVersions = exportedItemVersions
        self.appliedOperationIDs = appliedOperationIDs
        self.lastSyncAt = lastSyncAt
    }
}

struct CloudFolderSyncResult: Equatable, Sendable {
    let operationsRead: Int
    let operationsWritten: Int
    let mutationsApplied: Int
    let syncedAt: Date
    let diagnostics: [CloudFolderSyncDiagnostic]
}

struct CloudFolderSyncDiagnostic: Equatable, Sendable {
    enum Kind: String, Sendable { case unreadableFile, malformedOperation, unsupportedSchema }
    let kind: Kind
    let fileName: String
}

struct CloudFolderSyncManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let createdBy: String
    let updatedAt: Date
}

struct CloudFolderSyncDeviceRecord: Codable, Equatable, Sendable {
    let deviceId: String
    let platform: String
    let appVersion: String
    let updatedAt: Date
}

struct CloudFolderSyncOperation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case upsert
        case delete
    }

    let schemaVersion: Int
    let operationId: String
    let deviceId: String
    let collection: UserDataSyncCollection
    let itemId: String
    let kind: Kind
    let updatedAt: Date
    let deletedAt: Date?
    let dictionary: UserDataSyncDictionaryEntry?
    let snippet: UserDataSyncSnippet?

    static func upsertDictionary(
        _ entry: UserDataSyncDictionaryEntry,
        itemID: String,
        deviceId: String,
        operationId: String = UUID().uuidString
    ) -> CloudFolderSyncOperation {
        CloudFolderSyncOperation(
            schemaVersion: 1,
            operationId: operationId,
            deviceId: deviceId,
            collection: .dictionary,
            itemId: itemID,
            kind: .upsert,
            updatedAt: entry.updatedAt,
            deletedAt: nil,
            dictionary: entry,
            snippet: nil
        )
    }

    static func upsertSnippet(
        _ snippet: UserDataSyncSnippet,
        itemID: String,
        deviceId: String,
        operationId: String = UUID().uuidString
    ) -> CloudFolderSyncOperation {
        CloudFolderSyncOperation(
            schemaVersion: 1,
            operationId: operationId,
            deviceId: deviceId,
            collection: .snippets,
            itemId: itemID,
            kind: .upsert,
            updatedAt: snippet.updatedAt,
            deletedAt: nil,
            dictionary: nil,
            snippet: snippet
        )
    }

    static func delete(
        collection: UserDataSyncCollection,
        itemID: String,
        deviceId: String,
        deletedAt: Date,
        operationId: String = UUID().uuidString
    ) -> CloudFolderSyncOperation {
        CloudFolderSyncOperation(
            schemaVersion: 1,
            operationId: operationId,
            deviceId: deviceId,
            collection: collection,
            itemId: itemID,
            kind: .delete,
            updatedAt: deletedAt,
            deletedAt: deletedAt,
            dictionary: nil,
            snippet: nil
        )
    }
}

enum CloudFolderSyncError: LocalizedError {
    case missingStore
    case notEntitled

    var errorDescription: String? {
        switch self {
        case .missingStore:
            String(localized: "TypeWhisper user data is unavailable.")
        case .notEntitled:
            String(localized: "Cloud Folder Sync requires an active Premium entitlement.")
        }
    }
}

enum CloudFolderSyncEngine {
    private static let packageDirectoryName = "typewhisper-sync"
    private static let manifestFileName = "manifest.json"
    private static let devicesDirectoryName = "devices"
    private static let operationsDirectoryName = "ops"
    private static let tombstoneRetentionInterval: TimeInterval = 90 * 24 * 60 * 60

    static func packageURL(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(packageDirectoryName, isDirectory: true)
    }

    static func sync(
        folderURL: URL,
        store: (any UserDataSyncStore)?,
        state: inout CloudFolderSyncState,
        entitlements: PaidEntitlements,
        now: Date = Date()
    ) async throws -> CloudFolderSyncResult {
        guard entitlements.canUseCloudFolderSync else {
            throw CloudFolderSyncError.notEntitled
        }
        guard let store else {
            throw CloudFolderSyncError.missingStore
        }

        let initialSnapshot = await store.snapshot()
        let initialRecords = records(from: initialSnapshot)
        let stateSnapshot = state
        let fileResult = try await Task.detached(priority: .utility) {
            let packageURL = packageURL(for: folderURL)
            let operationsURL = packageURL
                .appendingPathComponent(operationsDirectoryName, isDirectory: true)
            let deviceOperationsURL = operationsURL
                .appendingPathComponent(stateSnapshot.deviceId, isDirectory: true)
            let devicesURL = packageURL
                .appendingPathComponent(devicesDirectoryName, isDirectory: true)

            try FileManager.default.createDirectory(
                at: deviceOperationsURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: devicesURL,
                withIntermediateDirectories: true
            )
            try writePackageMetadata(
                packageURL: packageURL,
                devicesURL: devicesURL,
                deviceId: stateSnapshot.deviceId,
                now: now
            )

            let localOperations = makeLocalOperations(
                records: initialRecords,
                state: stateSnapshot,
                now: now
            )
            try write(localOperations, to: deviceOperationsURL, now: now)
            pruneExpiredTombstones(in: deviceOperationsURL, now: now)

            let readResult = readOperations(from: operationsURL)
            let winners = winningOperations(from: readResult.operations)
            let mutations = makeMutations(
                from: winners,
                localRecords: initialRecords,
                localDeviceId: stateSnapshot.deviceId,
                appliedOperationIDs: stateSnapshot.appliedOperationIDs
            )
            return (
                localOperations: localOperations,
                readResult: readResult,
                mutations: mutations
            )
        }.value
        let operations = fileResult.readResult.operations
        let mutations = fileResult.mutations

        if !mutations.isEmpty {
            try await store.apply(mutations)
        }

        let finalSnapshot = await store.snapshot()
        let finalRecords = records(from: finalSnapshot)
        state.knownLocalItemIDs = Set(finalRecords.keys)
        state.exportedItemVersions = finalRecords.mapValues(\.version)
        state.appliedOperationIDs.formUnion(operations.map(\.operationId))
        state.lastSyncAt = now

        return CloudFolderSyncResult(
            operationsRead: operations.count,
            operationsWritten: fileResult.localOperations.count,
            mutationsApplied: mutations.count,
            syncedAt: now,
            diagnostics: fileResult.readResult.diagnostics
        )
    }

    static func records(from snapshot: UserDataSyncSnapshot) -> [String: CloudFolderSyncRecord] {
        var records: [String: CloudFolderSyncRecord] = [:]
        for entry in snapshot.dictionaryEntries {
            let itemID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original)
            merge(
                CloudFolderSyncRecord(
                    collection: .dictionary,
                    itemID: itemID,
                    updatedAt: entry.updatedAt,
                    version: versionString(for: entry.updatedAt),
                    dictionary: entry,
                    snippet: nil
                ),
                into: &records
            )
        }
        for snippet in snapshot.snippets {
            let itemID = UserDataSyncIdentity.snippetItemID(trigger: snippet.trigger)
            merge(
                CloudFolderSyncRecord(
                    collection: .snippets,
                    itemID: itemID,
                    updatedAt: snippet.updatedAt,
                    version: versionString(for: snippet.updatedAt),
                    dictionary: nil,
                    snippet: snippet
                ),
                into: &records
            )
        }
        return records
    }

    private static func merge(
        _ candidate: CloudFolderSyncRecord,
        into records: inout [String: CloudFolderSyncRecord]
    ) {
        guard let existing = records[candidate.itemID] else {
            records[candidate.itemID] = candidate
            return
        }

        // Legacy local data can contain duplicates that collapse to one natural sync ID.
        // Keep the newest deterministic record instead of depending on array order.
        if prefers(candidate, over: existing) {
            records[candidate.itemID] = candidate
        }
    }

    private static func prefers(_ candidate: CloudFolderSyncRecord, over existing: CloudFolderSyncRecord) -> Bool {
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        return recordTieBreaker(candidate) > recordTieBreaker(existing)
    }

    private static func recordTieBreaker(_ record: CloudFolderSyncRecord) -> String {
        if let dictionary = record.dictionary {
            return [
                record.collection.rawValue,
                dictionary.entryType.rawValue,
                dictionary.original,
                dictionary.replacement ?? "",
                String(dictionary.caseSensitive),
                String(dictionary.isEnabled),
                versionString(for: dictionary.createdAt)
            ].joined(separator: "|")
        }

        if let snippet = record.snippet {
            return [
                record.collection.rawValue,
                snippet.trigger,
                snippet.replacement,
                String(snippet.caseSensitive),
                String(snippet.isEnabled),
                snippet.tags.joined(separator: ","),
                versionString(for: snippet.createdAt)
            ].joined(separator: "|")
        }

        return record.itemID
    }

    static func winningOperations(from operations: [CloudFolderSyncOperation]) -> [String: CloudFolderSyncOperation] {
        operations.reduce(into: [:]) { result, operation in
            guard operation.schemaVersion == 1 else { return }
            guard operation.kind == .delete || operation.dictionary != nil || operation.snippet != nil else { return }
            if let existing = result[operation.itemId] {
                if prefers(operation, over: existing) {
                    result[operation.itemId] = operation
                }
            } else {
                result[operation.itemId] = operation
            }
        }
    }

    private static func makeLocalOperations(
        records: [String: CloudFolderSyncRecord],
        state: CloudFolderSyncState,
        now: Date
    ) -> [CloudFolderSyncOperation] {
        var operations: [CloudFolderSyncOperation] = []

        for record in records.values.sorted(by: { $0.itemID < $1.itemID }) {
            guard state.exportedItemVersions[record.itemID] != record.version else { continue }
            if let dictionary = record.dictionary {
                operations.append(.upsertDictionary(dictionary, itemID: record.itemID, deviceId: state.deviceId))
            } else if let snippet = record.snippet {
                operations.append(.upsertSnippet(snippet, itemID: record.itemID, deviceId: state.deviceId))
            }
        }

        let deletedItemIDs = state.knownLocalItemIDs.subtracting(records.keys)
        for itemID in deletedItemIDs.sorted() {
            let collection: UserDataSyncCollection = itemID.hasPrefix("snippet:") ? .snippets : .dictionary
            operations.append(.delete(collection: collection, itemID: itemID, deviceId: state.deviceId, deletedAt: now))
        }

        return operations
    }

    private static func makeMutations(
        from winners: [String: CloudFolderSyncOperation],
        localRecords: [String: CloudFolderSyncRecord],
        localDeviceId: String,
        appliedOperationIDs: Set<String> = []
    ) -> [UserDataSyncMutation] {
        var mutations: [UserDataSyncMutation] = []

        for operation in winners.values.sorted(by: { $0.itemId < $1.itemId }) {
            guard !appliedOperationIDs.contains(operation.operationId) else { continue }
            let local = localRecords[operation.itemId]
            guard shouldApply(operation, over: local, localDeviceId: localDeviceId) else { continue }

            switch (operation.kind, operation.collection) {
            case (.delete, .dictionary):
                mutations.append(.deleteDictionary(itemID: operation.itemId))
            case (.delete, .snippets):
                mutations.append(.deleteSnippet(itemID: operation.itemId))
            case (.upsert, .dictionary):
                if let dictionary = operation.dictionary {
                    mutations.append(.upsertDictionary(dictionary))
                }
            case (.upsert, .snippets):
                if let snippet = operation.snippet {
                    mutations.append(.upsertSnippet(snippet))
                }
            }
        }

        return mutations
    }

    private static func shouldApply(
        _ operation: CloudFolderSyncOperation,
        over local: CloudFolderSyncRecord?,
        localDeviceId: String
    ) -> Bool {
        guard let local else { return operation.kind == .upsert }
        if operation.updatedAt > local.updatedAt {
            return true
        }
        if operation.updatedAt == local.updatedAt && operation.deviceId > localDeviceId {
            return true
        }
        return false
    }

    private static func prefers(_ candidate: CloudFolderSyncOperation, over existing: CloudFolderSyncOperation) -> Bool {
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        if candidate.deviceId != existing.deviceId {
            return candidate.deviceId > existing.deviceId
        }
        return candidate.operationId > existing.operationId
    }

    private static func writePackageMetadata(packageURL: URL, devicesURL: URL, deviceId: String, now: Date) throws {
        let manifest = CloudFolderSyncManifest(
            schemaVersion: 1,
            createdBy: "TypeWhisper",
            updatedAt: now
        )
        try writeJSON(manifest, to: packageURL.appendingPathComponent(manifestFileName))

        let device = CloudFolderSyncDeviceRecord(
            deviceId: deviceId,
            platform: "macOS",
            appVersion: AppConstants.currentReleaseFingerprint,
            updatedAt: now
        )
        try writeJSON(device, to: devicesURL.appendingPathComponent("\(deviceId).json"))
    }

    private static func write(_ operations: [CloudFolderSyncOperation], to directory: URL, now: Date) throws {
        for operation in operations {
            let fileName = "\(operationTimestamp(now))-\(operation.operationId).json"
            try writeJSON(operation, to: directory.appendingPathComponent(fileName))
        }
    }

    private static func readOperations(
        from operationsURL: URL
    ) -> (operations: [CloudFolderSyncOperation], diagnostics: [CloudFolderSyncDiagnostic]) {
        guard let deviceDirectories = try? FileManager.default.contentsOfDirectory(
            at: operationsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }

        var operations: [CloudFolderSyncOperation] = []
        var diagnostics: [CloudFolderSyncDiagnostic] = []
        for deviceDirectory in deviceDirectories {
            guard (try? deviceDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: deviceDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file) else {
                    diagnostics.append(.init(kind: .unreadableFile, fileName: file.lastPathComponent))
                    continue
                }
                guard let operation = try? decoder.decode(CloudFolderSyncOperation.self, from: data) else {
                    diagnostics.append(.init(kind: .malformedOperation, fileName: file.lastPathComponent))
                    continue
                }
                guard operation.schemaVersion == 1 else {
                    diagnostics.append(.init(kind: .unsupportedSchema, fileName: file.lastPathComponent))
                    continue
                }
                operations.append(operation)
            }
        }
        return (operations, diagnostics)
    }

    private static func pruneExpiredTombstones(in deviceOperationsURL: URL, now: Date) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: deviceOperationsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let operation = try? decoder.decode(CloudFolderSyncOperation.self, from: data),
                  operation.kind == .delete,
                  let deletedAt = operation.deletedAt,
                  now.timeIntervalSince(deletedAt) > tombstoneRetentionInterval else {
                continue
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private static func operationTimestamp(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970 * 1000))
    }

    private static func versionString(for date: Date) -> String {
        iso8601String(from: date)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func iso8601Date(from string: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let wholeSecondFormatter = ISO8601DateFormatter()
        wholeSecondFormatter.formatOptions = [.withInternetDateTime]
        return wholeSecondFormatter.date(from: string)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601String(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = iso8601Date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return decoder
    }()

}

struct CloudFolderSyncRecord: Equatable, Sendable {
    let collection: UserDataSyncCollection
    let itemID: String
    let updatedAt: Date
    let version: String
    let dictionary: UserDataSyncDictionaryEntry?
    let snippet: UserDataSyncSnippet?
}
