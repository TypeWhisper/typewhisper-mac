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
    var historyGeneration: String

    init(
        deviceId: String = UUID().uuidString,
        knownLocalItemIDs: Set<String> = [],
        exportedItemVersions: [String: String] = [:],
        appliedOperationIDs: Set<String> = [],
        lastSyncAt: Date? = nil,
        historyGeneration: String = "history-v1"
    ) {
        self.deviceId = deviceId
        self.knownLocalItemIDs = knownLocalItemIDs
        self.exportedItemVersions = exportedItemVersions
        self.appliedOperationIDs = appliedOperationIDs
        self.lastSyncAt = lastSyncAt
        self.historyGeneration = historyGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId
        case knownLocalItemIDs
        case exportedItemVersions
        case appliedOperationIDs
        case lastSyncAt
        case historyGeneration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
            ?? UUID().uuidString
        knownLocalItemIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .knownLocalItemIDs
        ) ?? []
        exportedItemVersions = try container.decodeIfPresent(
            [String: String].self,
            forKey: .exportedItemVersions
        ) ?? [:]
        appliedOperationIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .appliedOperationIDs
        ) ?? []
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        historyGeneration = try container.decodeIfPresent(
            String.self,
            forKey: .historyGeneration
        ) ?? "history-v1"
    }
}

struct CloudFolderSyncResult: Equatable, Sendable {
    let operationsRead: Int
    let operationsWritten: Int
    let mutationsApplied: Int
    let syncedAt: Date
    let diagnostics: [CloudFolderSyncDiagnostic]
    let devices: [CloudFolderSyncDeviceRecord]
}

struct CloudFolderSyncDiagnostic: Equatable, Sendable {
    enum Kind: String, Sendable {
        case unreadableFile
        case malformedOperation
        case malformedDevice
        case unsupportedSchema
        case audioTransferFailed
    }
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
    let historyOriginDeviceID: String?
    let platform: String
    let appVersion: String
    let updatedAt: Date
    let name: String?

    init(
        deviceId: String,
        historyOriginDeviceID: String? = nil,
        platform: String,
        appVersion: String,
        updatedAt: Date,
        name: String? = nil
    ) {
        self.deviceId = deviceId
        self.historyOriginDeviceID = historyOriginDeviceID
        self.platform = platform
        self.appVersion = appVersion
        self.updatedAt = updatedAt
        self.name = name
    }
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
    let historyPayloadVersion: Int?
    let historyGeneration: String?
    let historyComponent: UserDataSyncHistoryComponent?
    let historyContent: UserDataSyncHistoryContentV1?
    let historyInbox: UserDataSyncHistoryInboxV1?
    let historyAudio: UserDataSyncHistoryAudioV1?

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
            snippet: nil,
            historyPayloadVersion: nil,
            historyGeneration: nil,
            historyComponent: nil,
            historyContent: nil,
            historyInbox: nil,
            historyAudio: nil
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
            snippet: snippet,
            historyPayloadVersion: nil,
            historyGeneration: nil,
            historyComponent: nil,
            historyContent: nil,
            historyInbox: nil,
            historyAudio: nil
        )
    }

    static func upsertHistory(
        itemID: String,
        component: UserDataSyncHistoryComponent,
        generation: String,
        deviceId: String,
        content: UserDataSyncHistoryContentV1? = nil,
        inbox: UserDataSyncHistoryInboxV1? = nil,
        audio: UserDataSyncHistoryAudioV1? = nil,
        operationId: String = UUID().uuidString
    ) -> CloudFolderSyncOperation {
        let updatedAt = content?.updatedAt ?? inbox?.updatedAt ?? audio?.updatedAt ?? .distantPast
        return CloudFolderSyncOperation(
            schemaVersion: 1,
            operationId: operationId,
            deviceId: deviceId,
            collection: .history,
            itemId: itemID,
            kind: .upsert,
            updatedAt: updatedAt,
            deletedAt: nil,
            dictionary: nil,
            snippet: nil,
            historyPayloadVersion: 1,
            historyGeneration: generation,
            historyComponent: component,
            historyContent: content,
            historyInbox: inbox,
            historyAudio: audio
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
            snippet: nil,
            historyPayloadVersion: collection == .history ? 1 : nil,
            historyGeneration: nil,
            historyComponent: nil,
            historyContent: nil,
            historyInbox: nil,
            historyAudio: nil
        )
    }

    static func deleteHistory(
        recordID: UUID,
        generation: String,
        deviceId: String,
        deletedAt: Date,
        operationId: String = UUID().uuidString
    ) -> CloudFolderSyncOperation {
        let itemID = UserDataSyncIdentity.historyItemID(recordID: recordID)
        return CloudFolderSyncOperation(
            schemaVersion: 1,
            operationId: operationId,
            deviceId: deviceId,
            collection: .history,
            itemId: itemID,
            kind: .delete,
            updatedAt: deletedAt,
            deletedAt: deletedAt,
            dictionary: nil,
            snippet: nil,
            historyPayloadVersion: 1,
            historyGeneration: generation,
            historyComponent: nil,
            historyContent: nil,
            historyInbox: nil,
            historyAudio: nil
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
        historyOriginDeviceID: String? = nil,
        now: Date = Date(),
        afterFileIO: (@Sendable () async -> Void)? = nil
    ) async throws -> CloudFolderSyncResult {
        guard entitlements.canUseCloudFolderSync else {
            throw CloudFolderSyncError.notEntitled
        }
        guard let store else {
            throw CloudFolderSyncError.missingStore
        }

        let initialSnapshot = await store.snapshot()
        let stateSnapshot = state
        let deviceName = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
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
                historyOriginDeviceID: historyOriginDeviceID,
                deviceName: deviceName,
                now: now
            )

            let assetPreparation = prepareHistoryAssets(
                in: initialSnapshot,
                packageURL: packageURL,
                generation: stateSnapshot.historyGeneration
            )
            let preparedSnapshot = assetPreparation.snapshot
            let initialRecords = records(from: preparedSnapshot)

            let localOperations = makeLocalOperations(
                records: initialRecords,
                deletedHistoryRecords: preparedSnapshot.deletedHistoryRecords,
                state: stateSnapshot,
                now: now
            )
            try write(localOperations, to: deviceOperationsURL, now: now)
            pruneExpiredTombstones(in: deviceOperationsURL, now: now)

            let readResult = try readOperations(from: operationsURL)
            let deviceReadResult = try readDevices(from: devicesURL)
            let winners = winningOperations(from: readResult.operations)
            let mutations = makeMutations(
                from: winners,
                localRecords: initialRecords,
                localDeviceId: stateSnapshot.deviceId,
                historyGeneration: stateSnapshot.historyGeneration,
                appliedOperationIDs: stateSnapshot.appliedOperationIDs
            )
            return (
                initialRecords: initialRecords,
                localOperations: localOperations,
                readResult: readResult,
                deviceReadResult: deviceReadResult,
                mutations: mutations,
                assetDiagnostics: assetPreparation.diagnostics
            )
        }.value
        let operations = fileResult.readResult.operations
        let mutations = fileResult.mutations

        await afterFileIO?()
        if !mutations.isEmpty {
            try await store.apply(mutations)
        }

        let finalSnapshot = await store.snapshot()
        let synchronizedRecords = records(from: finalSnapshot)
        state.knownLocalItemIDs = Set(synchronizedRecords.keys)
        state.exportedItemVersions = synchronizedRecords.mapValues(\.version)
        for operation in fileResult.localOperations {
            let key = operationStateKey(operation)
            if operation.kind == .delete {
                state.exportedItemVersions[key] = versionString(for: operation.updatedAt)
            } else if let record = fileResult.initialRecords[key] {
                state.knownLocalItemIDs.insert(key)
                state.exportedItemVersions[key] = record.version
            }
        }
        for itemID in dictionaryItemIDsRequiringRepublish(
            afterApplying: mutations
        ) {
            state.exportedItemVersions.removeValue(forKey: itemID)
        }
        state.appliedOperationIDs.formUnion(operations.map(\.operationId))
        state.lastSyncAt = now

        return CloudFolderSyncResult(
            operationsRead: operations.count,
            operationsWritten: fileResult.localOperations.count,
            mutationsApplied: mutations.count,
            syncedAt: now,
            diagnostics: fileResult.readResult.diagnostics
                + fileResult.deviceReadResult.diagnostics
                + fileResult.assetDiagnostics,
            devices: fileResult.deviceReadResult.devices
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
                    version: dictionaryVersionString(for: entry),
                    dictionary: entry,
                    snippet: nil,
                    historyComponent: nil,
                    historyContent: nil,
                    historyInbox: nil,
                    historyAudio: nil
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
                    snippet: snippet,
                    historyComponent: nil,
                    historyContent: nil,
                    historyInbox: nil,
                    historyAudio: nil
                ),
                into: &records
            )
        }
        for history in snapshot.historyRecords {
            let itemID = UserDataSyncIdentity.historyItemID(
                recordID: history.content.recordID
            )
            let contentKey = UserDataSyncIdentity.historyStateKey(
                itemID: itemID,
                component: .content
            )
            records[contentKey] = CloudFolderSyncRecord(
                collection: .history,
                itemID: itemID,
                updatedAt: history.content.updatedAt,
                version: versionString(for: history.content.updatedAt),
                dictionary: nil,
                snippet: nil,
                historyComponent: .content,
                historyContent: history.content,
                historyInbox: nil,
                historyAudio: nil
            )
            let inboxKey = UserDataSyncIdentity.historyStateKey(
                itemID: itemID,
                component: .inbox
            )
            records[inboxKey] = CloudFolderSyncRecord(
                collection: .history,
                itemID: itemID,
                updatedAt: history.inbox.updatedAt,
                version: versionString(for: history.inbox.updatedAt),
                dictionary: nil,
                snippet: nil,
                historyComponent: .inbox,
                historyContent: nil,
                historyInbox: history.inbox,
                historyAudio: nil
            )
            if let audio = history.audio, audio.isValid {
                let audioKey = UserDataSyncIdentity.historyStateKey(
                    itemID: itemID,
                    component: .audio
                )
                records[audioKey] = CloudFolderSyncRecord(
                    collection: .history,
                    itemID: itemID,
                    updatedAt: audio.updatedAt,
                    version: versionString(for: audio.updatedAt),
                    dictionary: nil,
                    snippet: nil,
                    historyComponent: .audio,
                    historyContent: nil,
                    historyInbox: nil,
                    historyAudio: audio
                )
            }
        }
        return records
    }

    private static func records(
        afterApplying mutations: [UserDataSyncMutation],
        to initialRecords: [String: CloudFolderSyncRecord]
    ) -> [String: CloudFolderSyncRecord] {
        var records = initialRecords
        for mutation in mutations {
            switch mutation {
            case .upsertDictionary(let entry):
                let itemID = UserDataSyncIdentity.dictionaryItemID(
                    entryType: entry.entryType,
                    original: entry.original
                )
                records[itemID] = Self.records(
                    from: UserDataSyncSnapshot(dictionaryEntries: [entry])
                )[itemID]
            case .deleteDictionary(let itemID), .deleteSnippet(let itemID):
                records.removeValue(forKey: itemID)
            case .upsertSnippet(let snippet):
                let itemID = UserDataSyncIdentity.snippetItemID(trigger: snippet.trigger)
                records[itemID] = Self.records(
                    from: UserDataSyncSnapshot(snippets: [snippet])
                )[itemID]
            case .upsertHistoryContent,
                 .upsertHistoryInbox,
                 .upsertHistoryAudio,
                 .deleteHistory:
                break
            }
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
            let ctcValue = dictionary.ctcMinSimilarity.map {
                String($0)
            } ?? "null"
            return [
                record.collection.rawValue,
                dictionary.entryType.rawValue,
                dictionary.original,
                dictionary.replacement ?? "",
                String(dictionary.caseSensitive),
                String(dictionary.isEnabled),
                String(dictionary.ctcMinSimilarityFieldPresent),
                ctcValue,
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
            guard operationIsValid(operation) else { return }
            let key = operationStateKey(operation)
            if let existing = result[key] {
                if prefers(operation, over: existing) {
                    result[key] = operation
                }
            } else {
                result[key] = operation
            }
        }
    }

    private static func makeLocalOperations(
        records: [String: CloudFolderSyncRecord],
        deletedHistoryRecords: [UserDataSyncHistoryDeletion],
        state: CloudFolderSyncState,
        now: Date
    ) -> [CloudFolderSyncOperation] {
        var operations: [CloudFolderSyncOperation] = []

        for record in records.values.sorted(by: { $0.itemID < $1.itemID }) {
            guard state.exportedItemVersions[record.stateKey] != record.version else { continue }
            if let dictionary = record.dictionary {
                operations.append(.upsertDictionary(dictionary, itemID: record.itemID, deviceId: state.deviceId))
            } else if let snippet = record.snippet {
                operations.append(.upsertSnippet(snippet, itemID: record.itemID, deviceId: state.deviceId))
            } else if let component = record.historyComponent {
                operations.append(.upsertHistory(
                    itemID: record.itemID,
                    component: component,
                    generation: state.historyGeneration,
                    deviceId: state.deviceId,
                    content: record.historyContent,
                    inbox: record.historyInbox,
                    audio: record.historyAudio
                ))
            }
        }

        let deletedItemIDs = state.knownLocalItemIDs
            .subtracting(records.keys)
            .filter { !$0.hasPrefix("history:") }
        for itemID in deletedItemIDs.sorted() {
            let collection: UserDataSyncCollection = itemID.hasPrefix("snippet:") ? .snippets : .dictionary
            operations.append(.delete(collection: collection, itemID: itemID, deviceId: state.deviceId, deletedAt: now))
        }

        for deletion in deletedHistoryRecords.sorted(by: { $0.recordID.uuidString < $1.recordID.uuidString }) {
            let itemID = UserDataSyncIdentity.historyItemID(recordID: deletion.recordID)
            let deleteKey = historyDeleteStateKey(itemID: itemID)
            let version = versionString(for: deletion.deletedAt)
            guard state.exportedItemVersions[deleteKey] != version else { continue }
            operations.append(.deleteHistory(
                recordID: deletion.recordID,
                generation: state.historyGeneration,
                deviceId: state.deviceId,
                deletedAt: deletion.deletedAt
            ))
        }

        return operations
    }

    private static func makeMutations(
        from winners: [String: CloudFolderSyncOperation],
        localRecords: [String: CloudFolderSyncRecord],
        localDeviceId: String,
        historyGeneration: String,
        appliedOperationIDs: Set<String> = []
    ) -> [UserDataSyncMutation] {
        var mutations: [UserDataSyncMutation] = []

        for operation in winners.values
            .filter({ $0.collection != .history })
            .sorted(by: { $0.itemId < $1.itemId }) {
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
            case (_, .history):
                break
            }
        }

        let historyOperations = winners.values.filter {
            $0.collection == .history
                && $0.historyGeneration == historyGeneration
                && !appliedOperationIDs.contains($0.operationId)
        }
        let historyItemIDs = Set(historyOperations.map(\.itemId))
        for itemID in historyItemIDs.sorted() {
            guard let recordID = UserDataSyncIdentity.historyRecordID(from: itemID) else { continue }
            let itemOperations = historyOperations.filter { $0.itemId == itemID }
            let deletion = itemOperations.first(where: { $0.kind == .delete })
            let localComponents = UserDataSyncHistoryComponent.allCases.compactMap {
                localRecords[UserDataSyncIdentity.historyStateKey(itemID: itemID, component: $0)]
            }

            if let deletion,
               !localComponents.isEmpty,
               shouldApply(
                   deletion,
                   over: localComponents.max(by: { $0.updatedAt < $1.updatedAt }),
                   localDeviceId: localDeviceId
               ) {
                mutations.append(.deleteHistory(recordID: recordID))
                continue
            }

            for component in UserDataSyncHistoryComponent.allCases {
                let key = UserDataSyncIdentity.historyStateKey(itemID: itemID, component: component)
                guard let operation = winners[key],
                      operation.historyGeneration == historyGeneration,
                      !appliedOperationIDs.contains(operation.operationId),
                      deletion.map({ prefers($0, over: operation) }) != true,
                      shouldApply(operation, over: localRecords[key], localDeviceId: localDeviceId) else {
                    continue
                }
                switch component {
                case .content:
                    if let content = operation.historyContent {
                        mutations.append(.upsertHistoryContent(content))
                    }
                case .inbox:
                    if let inbox = operation.historyInbox {
                        mutations.append(.upsertHistoryInbox(inbox))
                    }
                case .audio:
                    if let audio = operation.historyAudio, audio.isValid {
                        mutations.append(.upsertHistoryAudio(audio))
                    }
                }
            }
        }

        return mutations
    }

    private static func prepareHistoryAssets(
        in snapshot: UserDataSyncSnapshot,
        packageURL: URL,
        generation: String
    ) -> (snapshot: UserDataSyncSnapshot, diagnostics: [CloudFolderSyncDiagnostic]) {
        var diagnostics: [CloudFolderSyncDiagnostic] = []
        let historyRecords = snapshot.historyRecords.map { record in
            guard record.audioEligible, let sourceURL = record.localAudioFileURL else {
                return record
            }
            do {
                let audio = try HistorySyncAssetStore.publish(
                    sourceURL: sourceURL,
                    packageURL: packageURL,
                    generation: generation,
                    recordID: record.content.recordID,
                    updatedAt: record.audio?.updatedAt ?? record.content.updatedAt,
                    durationSeconds: record.content.durationSeconds
                )
                return UserDataSyncHistoryRecord(
                    content: record.content,
                    inbox: record.inbox,
                    audio: audio,
                    localAudioFileURL: record.localAudioFileURL,
                    audioEligible: record.audioEligible
                )
            } catch {
                diagnostics.append(.init(
                    kind: .audioTransferFailed,
                    fileName: sourceURL.lastPathComponent
                ))
                return UserDataSyncHistoryRecord(
                    content: record.content,
                    inbox: record.inbox,
                    audio: nil,
                    localAudioFileURL: record.localAudioFileURL,
                    audioEligible: record.audioEligible
                )
            }
        }
        return (
            UserDataSyncSnapshot(
                dictionaryEntries: snapshot.dictionaryEntries,
                snippets: snapshot.snippets,
                historyRecords: historyRecords,
                deletedHistoryRecords: snapshot.deletedHistoryRecords
            ),
            diagnostics
        )
    }

    private static func operationIsValid(_ operation: CloudFolderSyncOperation) -> Bool {
        switch operation.collection {
        case .dictionary:
            return operation.kind == .delete || operation.dictionary != nil
        case .snippets:
            return operation.kind == .delete || operation.snippet != nil
        case .history:
            guard operation.historyPayloadVersion == 1,
                  operation.historyGeneration != nil,
                  UserDataSyncIdentity.historyRecordID(from: operation.itemId) != nil else {
                return false
            }
            if operation.kind == .delete {
                return operation.historyComponent == nil
                    && operation.historyContent == nil
                    && operation.historyInbox == nil
                    && operation.historyAudio == nil
            }
            switch operation.historyComponent {
            case .content:
                return operation.historyContent?.recordID
                    == UserDataSyncIdentity.historyRecordID(from: operation.itemId)
                    && operation.historyInbox == nil && operation.historyAudio == nil
            case .inbox:
                return operation.historyInbox?.recordID
                    == UserDataSyncIdentity.historyRecordID(from: operation.itemId)
                    && operation.historyContent == nil && operation.historyAudio == nil
            case .audio:
                return operation.historyAudio?.recordID
                    == UserDataSyncIdentity.historyRecordID(from: operation.itemId)
                    && operation.historyAudio?.isValid == true
                    && operation.historyContent == nil && operation.historyInbox == nil
            case nil:
                return false
            }
        }
    }

    private static func operationStateKey(_ operation: CloudFolderSyncOperation) -> String {
        guard operation.collection == .history else { return operation.itemId }
        guard let component = operation.historyComponent else {
            return historyDeleteStateKey(itemID: operation.itemId)
        }
        return UserDataSyncIdentity.historyStateKey(itemID: operation.itemId, component: component)
    }

    private static func historyDeleteStateKey(itemID: String) -> String {
        "\(itemID)#delete"
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
        if operation.updatedAt == local.updatedAt {
            if let presencePreference = ctcPresencePreference(
                candidate: operation.dictionary,
                existing: local.dictionary
            ) {
                return presencePreference
            }
            return operation.deviceId > localDeviceId
        }
        return false
    }

    private static func prefers(_ candidate: CloudFolderSyncOperation, over existing: CloudFolderSyncOperation) -> Bool {
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        if let presencePreference = ctcPresencePreference(
            candidate: candidate.dictionary,
            existing: existing.dictionary
        ) {
            return presencePreference
        }
        if candidate.deviceId != existing.deviceId {
            return candidate.deviceId > existing.deviceId
        }
        return candidate.operationId > existing.operationId
    }

    private static func writePackageMetadata(
        packageURL: URL,
        devicesURL: URL,
        deviceId: String,
        historyOriginDeviceID: String?,
        deviceName: String,
        now: Date
    ) throws {
        let manifest = CloudFolderSyncManifest(
            schemaVersion: 1,
            createdBy: "TypeWhisper",
            updatedAt: now
        )
        try writeJSON(manifest, to: packageURL.appendingPathComponent(manifestFileName))

        let device = CloudFolderSyncDeviceRecord(
            deviceId: deviceId,
            historyOriginDeviceID: historyOriginDeviceID,
            platform: "macOS",
            appVersion: AppConstants.currentReleaseFingerprint,
            updatedAt: now,
            name: deviceName
        )
        try writeJSON(device, to: devicesURL.appendingPathComponent("\(deviceId).json"))
    }

    static func readDevices(
        from devicesURL: URL
    ) throws -> (devices: [CloudFolderSyncDeviceRecord], diagnostics: [CloudFolderSyncDiagnostic]) {
        let files = try FileManager.default.contentsOfDirectory(
            at: devicesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var devicesByIdentity: [String: CloudFolderSyncDeviceRecord] = [:]
        var diagnostics: [CloudFolderSyncDiagnostic] = []

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else {
                diagnostics.append(.init(kind: .unreadableFile, fileName: file.lastPathComponent))
                continue
            }
            guard let device = try? decoder.decode(CloudFolderSyncDeviceRecord.self, from: data),
                  !device.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !device.platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                diagnostics.append(.init(kind: .malformedDevice, fileName: file.lastPathComponent))
                continue
            }
            let identity = device.historyOriginDeviceID.flatMap { value in
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : cleaned
            } ?? "transport:\(device.deviceId)"
            if let existing = devicesByIdentity[identity], existing.updatedAt >= device.updatedAt {
                continue
            }
            devicesByIdentity[identity] = device
        }

        let devices = devicesByIdentity.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return ($0.name ?? $0.platform).localizedStandardCompare(
                $1.name ?? $1.platform
            ) == .orderedAscending
        }
        return (devices, diagnostics)
    }

    private static func write(_ operations: [CloudFolderSyncOperation], to directory: URL, now: Date) throws {
        for operation in operations {
            let fileName = "\(operationTimestamp(now))-\(operation.operationId).json"
            try writeJSON(operation, to: directory.appendingPathComponent(fileName))
        }
    }

    static func readOperations(
        from operationsURL: URL
    ) throws -> (operations: [CloudFolderSyncOperation], diagnostics: [CloudFolderSyncDiagnostic]) {
        let deviceDirectories = try FileManager.default.contentsOfDirectory(
            at: operationsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var operations: [CloudFolderSyncOperation] = []
        var diagnostics: [CloudFolderSyncDiagnostic] = []
        for deviceDirectory in deviceDirectories {
            guard (try? deviceDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: deviceDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                diagnostics.append(.init(kind: .unreadableFile, fileName: deviceDirectory.lastPathComponent))
                continue
            }

            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file) else {
                    diagnostics.append(.init(kind: .unreadableFile, fileName: file.lastPathComponent))
                    continue
                }
                guard let envelope = try? decoder.decode(CloudFolderSyncSchemaEnvelope.self, from: data) else {
                    diagnostics.append(.init(kind: .malformedOperation, fileName: file.lastPathComponent))
                    continue
                }
                guard envelope.schemaVersion == 1 else {
                    diagnostics.append(.init(kind: .unsupportedSchema, fileName: file.lastPathComponent))
                    continue
                }
                guard let operation = try? decoder.decode(CloudFolderSyncOperation.self, from: data) else {
                    diagnostics.append(.init(kind: .malformedOperation, fileName: file.lastPathComponent))
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

    private static func dictionaryVersionString(
        for entry: UserDataSyncDictionaryEntry
    ) -> String {
        "dictionary-v2|\(versionString(for: entry.updatedAt))"
    }

    private static func ctcPresencePreference(
        candidate: UserDataSyncDictionaryEntry?,
        existing: UserDataSyncDictionaryEntry?
    ) -> Bool? {
        guard candidate?.entryType == .term,
              existing?.entryType == .term,
              candidate?.ctcMinSimilarityFieldPresent
                != existing?.ctcMinSimilarityFieldPresent else {
            return nil
        }
        return candidate?.ctcMinSimilarityFieldPresent == true
    }

    private static func dictionaryItemIDsRequiringRepublish(
        afterApplying mutations: [UserDataSyncMutation]
    ) -> Set<String> {
        Set(mutations.compactMap { mutation in
            guard case .upsertDictionary(let entry) = mutation,
                  entry.entryType == .term,
                  !entry.ctcMinSimilarityFieldPresent else {
                return nil
            }
            return UserDataSyncIdentity.dictionaryItemID(
                entryType: entry.entryType,
                original: entry.original
            )
        })
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

private struct CloudFolderSyncSchemaEnvelope: Decodable {
    let schemaVersion: Int
}

struct CloudFolderSyncRecord: Equatable, Sendable {
    let collection: UserDataSyncCollection
    let itemID: String
    let updatedAt: Date
    let version: String
    let dictionary: UserDataSyncDictionaryEntry?
    let snippet: UserDataSyncSnippet?
    let historyComponent: UserDataSyncHistoryComponent?
    let historyContent: UserDataSyncHistoryContentV1?
    let historyInbox: UserDataSyncHistoryInboxV1?
    let historyAudio: UserDataSyncHistoryAudioV1?

    var stateKey: String {
        guard let historyComponent else { return itemID }
        return UserDataSyncIdentity.historyStateKey(
            itemID: itemID,
            component: historyComponent
        )
    }
}
