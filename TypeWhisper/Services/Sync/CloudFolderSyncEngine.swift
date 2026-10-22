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
    /// Package listing taken before the operations were read, so later remote changes differ from it.
    let packageFingerprint: CloudFolderSyncPackageFingerprint?
    /// Set when applied remote changes must be republished by another sync, even though the
    /// package did not change since this one.
    let requiresFollowUpSync: Bool
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

    /// Failures that can clear up while the file keeps its size and modification date, such as
    /// restored permissions or a cloud placeholder that finished downloading.
    var isTransient: Bool {
        kind == .unreadableFile || kind == .audioTransferFailed
    }
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
    /// What this device's version syncs beyond the base schema; nil from older versions.
    let capabilities: [String]?

    /// The device reads and writes the `transcript` and `speakers` history components.
    static let speakerTranscriptCapability = "history.transcript.v1"

    var syncsSpeakerTranscripts: Bool {
        capabilities?.contains(Self.speakerTranscriptCapability) == true
    }

    init(
        deviceId: String,
        historyOriginDeviceID: String? = nil,
        platform: String,
        appVersion: String,
        updatedAt: Date,
        name: String? = nil,
        capabilities: [String]? = nil
    ) {
        self.deviceId = deviceId
        self.historyOriginDeviceID = historyOriginDeviceID
        self.platform = platform
        self.appVersion = appVersion
        self.updatedAt = updatedAt
        self.name = name
        self.capabilities = capabilities
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
    var itemId: String
    let kind: Kind
    let updatedAt: Date
    let deletedAt: Date?
    var dictionary: UserDataSyncDictionaryEntry?
    let snippet: UserDataSyncSnippet?
    let historyPayloadVersion: Int?
    let historyGeneration: String?
    let historyComponent: UserDataSyncHistoryComponent?
    let historyContent: UserDataSyncHistoryContentV1?
    let historyInbox: UserDataSyncHistoryInboxV1?
    let historyAudio: UserDataSyncHistoryAudioV1?
    var historyTranscript: UserDataSyncHistoryTranscriptV1? = nil
    var historySpeakers: UserDataSyncHistorySpeakersV1? = nil

    static func upsertDictionary(
        _ entry: UserDataSyncDictionaryEntry,
        itemID: String,
        deviceId: String,
        operationId: String = UUID().uuidString
    ) -> CloudFolderSyncOperation {
        CloudFolderSyncOperation(
            schemaVersion: entry.isRegex ? 2 : 1,
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
        transcript: UserDataSyncHistoryTranscriptV1? = nil,
        speakers: UserDataSyncHistorySpeakersV1? = nil,
        operationId: String = UUID().uuidString
    ) -> CloudFolderSyncOperation {
        let updatedAt = content?.updatedAt ?? inbox?.updatedAt ?? audio?.updatedAt
            ?? transcript?.updatedAt ?? speakers?.updatedAt ?? .distantPast
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
            historyAudio: audio,
            historyTranscript: transcript,
            historySpeakers: speakers
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
            schemaVersion: itemID.hasPrefix(UserDataSyncIdentity.regexCorrectionPrefix) ? 2 : 1,
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
    case incompleteMigrationHistory

    var errorDescription: String? {
        switch self {
        case .missingStore:
            String(localized: "dictum user data is unavailable.")
        case .notEntitled:
            String(localized: "Cloud Folder Sync requires an active Premium entitlement.")
        case .incompleteMigrationHistory:
            String(localized: "Previously synced correction files are missing or unreadable. Wait for your cloud provider to download them, or choose a new sync folder if the old files were deleted.")
        }
    }
}

enum CloudFolderSyncEngine {
    private static let packageDirectoryName = "typewhisper-sync"
    private static let manifestFileName = "manifest.json"
    private static let devicesDirectoryName = "devices"
    private static let operationsDirectoryName = "ops"
    private static let assetsDirectoryName = "assets"
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
        cache: CloudFolderSyncCache? = nil,
        afterFileIO: (@Sendable () async -> Void)? = nil
    ) async throws -> CloudFolderSyncResult {
        guard entitlements.canUseCloudFolderSync else {
            throw CloudFolderSyncError.notEntitled
        }
        guard let store else {
            throw CloudFolderSyncError.missingStore
        }

        let previousState = state
        // Repair modes dropped by a pre-regex Mac before it can republish them as
        // explicit literals. Only already-applied v1 operations and pre-v3 state qualify.
        let migration: (operations: [CloudFolderSyncOperation], rebuildPackage: Bool)
        if previousState.knownLocalItemIDs.contains(where: {
            $0.hasPrefix("dictionary:correction:") &&
                previousState.exportedItemVersions[$0]?.hasPrefix("dictionary-v3|") != true
        }) {
            migration = try await Task.detached(priority: .utility) {
                let operationsURL = packageURL(for: folderURL).appendingPathComponent(operationsDirectoryName)
                let read = FileManager.default.fileExists(atPath: operationsURL.path)
                    ? try readOperations(from: operationsURL, cache: cache ?? CloudFolderSyncCache())
                    : (operations: [CloudFolderSyncOperation](), diagnostics: [CloudFolderSyncDiagnostic]())
                if !legacyCorrectionHistoryIsComplete(operations: read.operations, state: previousState) {
                    let hasAppliedHistory = read.operations.contains { previousState.appliedOperationIDs.contains($0.operationId) }
                    let unreadableHistory = read.diagnostics.contains { $0.kind == .unreadableFile || $0.kind == .malformedOperation }
                    guard !hasAppliedHistory && !unreadableHistory else {
                        throw CloudFolderSyncError.incompleteMigrationHistory
                    }
                    // No old operations remain in an otherwise readable package.
                    // Republish local data without guessing old regex identities.
                    return (operations: [CloudFolderSyncOperation](), rebuildPackage: true)
                }
                return (operations: read.operations.filter { $0.schemaVersion == 1 }, rebuildPackage: false)
            }.value
        } else {
            migration = (operations: [], rebuildPackage: false)
        }
        let legacyOperations = migration.operations
        let stateSnapshot = previousState
        let preparation = try await MainActor.run {
            let snapshot = store.snapshot()
            let repairs = legacyRegexRepairs(operations: legacyOperations, snapshot: snapshot, state: stateSnapshot)
            guard !repairs.isEmpty else { return (snapshot: snapshot, repairs: 0) }
            try store.apply(repairs)
            return (snapshot: store.snapshot(), repairs: repairs.count)
        }
        let initialSnapshot = preparation.snapshot
        let deviceName = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
        let fileResult = try await Task.detached(priority: .utility) {
            // Without a caller-owned cache, a per-sync cache still decodes each file only once.
            let syncCache = cache ?? CloudFolderSyncCache()
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
                generation: stateSnapshot.historyGeneration,
                cache: syncCache
            )
            let preparedSnapshot = assetPreparation.snapshot
            let initialRecords = records(from: preparedSnapshot)
            var publicationState = stateSnapshot
            if migration.rebuildPackage {
                // Only unchanged regex rules can withdraw their old folded IDs.
                // Changed rules may have replaced literals that still need deleting.
                for record in initialRecords.values {
                    guard let entry = record.dictionary, entry.entryType == .correction, entry.isRegex else { continue }
                    let oldID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original)
                    let version = publicationState.exportedItemVersions[oldID]
                    let timestamp = versionString(for: entry.updatedAt)
                    if version == timestamp || version == "dictionary-v2|\(timestamp)" {
                        publicationState.knownLocalItemIDs.remove(oldID)
                    }
                }
                publicationState.exportedItemVersions = [:]
            }
            // Versions that do not know the speaker components report them as
            // invalid files, so they are held back while such a device syncs here.
            let withheldKeys = speakerComponentsCanBeWritten(
                devices: (try? readDevices(from: devicesURL))?.devices ?? [],
                ownDeviceId: stateSnapshot.deviceId,
                now: now
            ) ? Set<String>() : Set(initialRecords.filter {
                $0.value.historyComponent == .transcript || $0.value.historyComponent == .speakers
            }.keys)

            let localOperations = makeLocalOperations(
                records: initialRecords.filter { !withheldKeys.contains($0.key) },
                deletedHistoryRecords: preparedSnapshot.deletedHistoryRecords,
                state: publicationState,
                legacyRegexItemIDs: legacyRegexItemIDs(from: legacyOperations, state: stateSnapshot),
                now: now
            )
            try write(localOperations, to: deviceOperationsURL, now: now)
            pruneExpiredTombstones(in: deviceOperationsURL, now: now, cache: syncCache)

            let fingerprint = packageFingerprint(packageURL: packageURL)
            let readResult = try readOperations(from: operationsURL, cache: syncCache)
            let deviceReadResult = try readDevices(from: devicesURL)
            let winners = winningOperations(from: readResult.operations, localRecords: initialRecords)
            let mutations = makeMutations(
                from: winners,
                localRecords: initialRecords,
                localDeviceId: stateSnapshot.deviceId,
                historyGeneration: stateSnapshot.historyGeneration,
                appliedOperationIDs: stateSnapshot.appliedOperationIDs
            )
            return (
                initialRecords: initialRecords,
                withheldKeys: withheldKeys,
                localOperations: localOperations,
                readResult: readResult,
                deviceReadResult: deviceReadResult,
                mutations: mutations,
                assetDiagnostics: assetPreparation.diagnostics,
                packageFingerprint: fingerprint
            )
        }.value
        let operations = fileResult.readResult.operations
        let mutations = fileResult.mutations

        await afterFileIO?()
        // Without applied mutations the exported state is exactly what this sync read, so the
        // snapshot is only rebuilt when remote changes were applied to the store.
        var synchronizedRecords = fileResult.initialRecords
        if !mutations.isEmpty {
            try await store.apply(mutations)
            // Local edits and deletions made while the files were processed are not exported
            // yet. Only items changed by the applied mutations take their state from the store,
            // so those edits stay pending for the next sync.
            let mutatedKeys = stateKeys(changedBy: mutations)
            synchronizedRecords = synchronizedRecords.filter { !mutatedKeys.contains($0.key) }
            for (key, record) in records(from: await store.snapshot()) where mutatedKeys.contains(key) {
                synchronizedRecords[key] = record
            }
            // Published local audio descriptors only exist in the prepared snapshot. Keep them
            // exported while their history item survives, or the next sync would republish them.
            for (key, record) in fileResult.initialRecords
            where record.historyComponent == .audio && synchronizedRecords[key] == nil {
                let contentKey = UserDataSyncIdentity.historyStateKey(
                    itemID: record.itemID,
                    component: .content
                )
                if synchronizedRecords[contentKey] != nil {
                    synchronizedRecords[key] = record
                }
            }
        }
        state.knownLocalItemIDs = Set(synchronizedRecords.keys)
        state.exportedItemVersions = synchronizedRecords.mapValues(\.version)
        // Withheld components stay pending; only what another device sent counts as exported.
        let receivedKeys = Self.receivedSpeakerComponentKeys(from: mutations)
        for key in fileResult.withheldKeys where !receivedKeys.contains(key) {
            state.exportedItemVersions[key] = stateSnapshot.exportedItemVersions[key]
        }
        for operation in fileResult.localOperations {
            let key = operationStateKey(operation)
            if operation.kind == .delete {
                state.exportedItemVersions[key] = versionString(for: operation.updatedAt)
            } else if let record = fileResult.initialRecords[key] {
                state.knownLocalItemIDs.insert(key)
                state.exportedItemVersions[key] = record.version
            }
        }
        let republishedItemIDs = dictionaryItemIDsRequiringRepublish(
            afterApplying: mutations,
            legacyRegexEntries: operations
                .filter { $0.schemaVersion == 1 && !stateSnapshot.appliedOperationIDs.contains($0.operationId) }
                .compactMap(\.dictionary).filter(\.isRegex)
        )
        for itemID in republishedItemIDs {
            state.exportedItemVersions.removeValue(forKey: itemID)
        }
        // Names merged from two devices are newer than the ones read and go out again.
        let republishedSpeakerKeys = Self.speakerKeysRequiringRepublish(
            afterApplying: mutations,
            records: synchronizedRecords
        )
        for key in republishedSpeakerKeys {
            state.exportedItemVersions.removeValue(forKey: key)
        }
        state.appliedOperationIDs.formUnion(operations.filter(operationRegexIsSupported).map(\.operationId))
        state.lastSyncAt = now

        return CloudFolderSyncResult(
            operationsRead: operations.count,
            operationsWritten: fileResult.localOperations.count,
            mutationsApplied: mutations.count + preparation.repairs,
            syncedAt: now,
            diagnostics: fileResult.readResult.diagnostics
                + fileResult.deviceReadResult.diagnostics
                + fileResult.assetDiagnostics,
            devices: fileResult.deviceReadResult.devices,
            packageFingerprint: fileResult.packageFingerprint,
            requiresFollowUpSync: !republishedItemIDs.isEmpty || !republishedSpeakerKeys.isEmpty
        )
    }

    private static func legacyRegexRepairs(
        operations: [CloudFolderSyncOperation],
        snapshot: UserDataSyncSnapshot,
        state: CloudFolderSyncState
    ) -> [UserDataSyncMutation] {
        legacySynchronizedCorrections(from: operations, state: state).values.compactMap { operation in
            guard state.appliedOperationIDs.contains(operation.operationId),
                  let regex = operation.dictionary, regex.isRegex else { return nil }
            let oldID = UserDataSyncIdentity.dictionaryItemID(entryType: regex.entryType, original: regex.original)
            guard state.knownLocalItemIDs.contains(oldID),
                  state.exportedItemVersions[oldID]?.hasPrefix("dictionary-v3|") != true,
                  snapshot.dictionaryEntries.contains(where: { $0.isLegacyLiteralCopy(of: regex) }) else { return nil }
            return .restoreLegacyDictionaryRegex(regex)
        }
    }

    /// A device that has not synced for this long no longer holds speaker components back.
    static let speakerCapabilityDeviceLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// True when every other device that synced recently understands the
    /// `transcript` and `speakers` components.
    static func speakerComponentsCanBeWritten(
        devices: [CloudFolderSyncDeviceRecord],
        ownDeviceId: String,
        now: Date
    ) -> Bool {
        devices
            .filter { $0.deviceId != ownDeviceId }
            .filter { now.timeIntervalSince($0.updatedAt) < speakerCapabilityDeviceLifetime }
            .allSatisfy(\.syncsSpeakerTranscripts)
    }

    static func records(from snapshot: UserDataSyncSnapshot) -> [String: CloudFolderSyncRecord] {
        var records: [String: CloudFolderSyncRecord] = [:]
        for entry in snapshot.dictionaryEntries {
            let itemID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original, isRegex: entry.isRegex)
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
            if let transcript = history.transcript, transcript.isValid {
                let transcriptKey = UserDataSyncIdentity.historyStateKey(
                    itemID: itemID,
                    component: .transcript
                )
                records[transcriptKey] = CloudFolderSyncRecord(
                    collection: .history,
                    itemID: itemID,
                    updatedAt: transcript.updatedAt,
                    version: versionString(for: transcript.updatedAt),
                    dictionary: nil,
                    snippet: nil,
                    historyComponent: .transcript,
                    historyContent: nil,
                    historyInbox: nil,
                    historyAudio: nil,
                    historyTranscript: transcript
                )
            }
            if let speakers = history.speakers, speakers.isValid {
                let speakersKey = UserDataSyncIdentity.historyStateKey(
                    itemID: itemID,
                    component: .speakers
                )
                records[speakersKey] = CloudFolderSyncRecord(
                    collection: .history,
                    itemID: itemID,
                    updatedAt: speakers.updatedAt,
                    version: versionString(for: speakers.updatedAt),
                    dictionary: nil,
                    snippet: nil,
                    historyComponent: .speakers,
                    historyContent: nil,
                    historyInbox: nil,
                    historyAudio: nil,
                    historySpeakers: speakers
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
            case .restoreLegacyDictionaryRegex(let entry):
                records.removeValue(forKey: UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original))
                let migrated = Self.records(from: UserDataSyncSnapshot(dictionaryEntries: [entry]))
                records.merge(migrated) { existing, _ in existing }
            case .upsertDictionary(let entry):
                let itemID = UserDataSyncIdentity.dictionaryItemID(
                    entryType: entry.entryType,
                    original: entry.original,
                    isRegex: entry.isRegex
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
                 .upsertHistoryTranscript,
                 .upsertHistorySpeakers,
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
                String(dictionary.isRegexFieldPresent),
                String(dictionary.isRegex),
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

    private static func legacyDictionaryAliases(
        from operations: [CloudFolderSyncOperation], localRecords: [String: CloudFolderSyncRecord] = [:]
    ) -> [String: String] {
        var legacyAliases: [String: String] = [:]
        func remember(_ entry: UserDataSyncDictionaryEntry, transmittedID: String? = nil) {
            // Always map to the folded v1 namespace, never to an exact regex ID.
            let key = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original)
            if let transmittedID { legacyAliases[transmittedID] = key }
            legacyAliases["dictionary:\(entry.entryType.rawValue):\(UserDataSyncIdentity.normalizedKey(entry.original))"] = key
        }
        for record in localRecords.values {
            if let entry = record.dictionary { remember(entry) }
        }
        for operation in operations where operation.schemaVersion == 1 && operation.kind == .upsert && operationIsValid(operation) {
            if let entry = operation.dictionary { remember(entry, transmittedID: operation.itemId) }
        }
        return legacyAliases
    }

    private static func legacyItemID(_ itemID: String, aliases: [String: String]) -> String {
        if let canonical = aliases[itemID] { return canonical }
        // A v1 Base64URL suffix cannot contain a colon. In schema 1 this tag is
        // part of a raw literal, never an exact-pattern v2 identity.
        guard itemID.hasPrefix(UserDataSyncIdentity.regexCorrectionPrefix) else { return itemID }
        return UserDataSyncIdentity.dictionaryItemID(
            entryType: UserDataSyncDictionaryEntryType.correction,
            original: String(itemID.dropFirst("dictionary:correction:".count))
        )
    }

    private static func legacyWinningOperations(from operations: [CloudFolderSyncOperation]) -> [String: CloudFolderSyncOperation] {
        // Resolve the old namespace before migrating regex upserts. Otherwise an old
        // tombstone or a renamed pattern would resurrect superseded v1 regex records.
        let legacyAliases = legacyDictionaryAliases(from: operations)
        return operations.filter { $0.schemaVersion == 1 && operationIsValid($0) }
            .reduce(into: [String: CloudFolderSyncOperation]()) { result, operation in
                let key = operation.dictionary.map {
                    UserDataSyncIdentity.dictionaryItemID(entryType: $0.entryType, original: $0.original)
                } ?? legacyItemID(operation.itemId, aliases: legacyAliases)
                if let existing = result[key], !prefers(operation, over: existing) { return }
                result[key] = operation
            }
    }

    private static func legacySynchronizedCorrections(
        from operations: [CloudFolderSyncOperation], state: CloudFolderSyncState
    ) -> [String: CloudFolderSyncOperation] {
        // Match the actual exported local version. An already-applied tombstone or
        // older upsert can have a later timestamp when device clocks disagree.
        let matching = operations.filter { operation in
            guard operation.schemaVersion == 1, operation.kind == .upsert,
                  state.appliedOperationIDs.contains(operation.operationId),
                  let entry = operation.dictionary, entry.entryType == .correction else { return false }
            let itemID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original)
            guard state.knownLocalItemIDs.contains(itemID), let version = state.exportedItemVersions[itemID] else { return false }
            let timestamp = versionString(for: entry.updatedAt)
            return version == timestamp || version == "dictionary-v2|\(timestamp)"
        }
        return legacyWinningOperations(from: matching)
    }

    private static func legacyCorrectionHistoryIsComplete(
        operations: [CloudFolderSyncOperation], state: CloudFolderSyncState
    ) -> Bool {
        let known = legacySynchronizedCorrections(from: operations, state: state)
        return state.knownLocalItemIDs.allSatisfy { itemID in
            guard itemID.hasPrefix("dictionary:correction:"), !itemID.hasPrefix("dictionary:correction:regex:"),
                  let version = state.exportedItemVersions[itemID], !version.hasPrefix("dictionary-v3|") else { return true }
            // Upserts are retained even when unrelated applied tombstones are pruned.
            // Match the last exported version: an older readable operation is not enough.
            guard let operation = known[itemID], operation.kind == .upsert,
                  let entry = operation.dictionary, entry.entryType == .correction else { return false }
            let timestamp = versionString(for: entry.updatedAt)
            return version == timestamp || version == "dictionary-v2|\(timestamp)"
        }
    }

    /// Recover the identity this device last synced, before any local deletion or mode
    /// change. Unseen remote edits must not change which exact pattern that deletion targets.
    private static func legacyRegexItemIDs(
        from operations: [CloudFolderSyncOperation], state: CloudFolderSyncState
    ) -> [String: String] {
        let known = legacySynchronizedCorrections(from: operations, state: state)
        return known.filter {
            state.knownLocalItemIDs.contains($0.key) && state.exportedItemVersions[$0.key]?.hasPrefix("dictionary-v3|") != true
        }.compactMapValues { operation in
            guard operation.kind == .upsert, let entry = operation.dictionary,
                  entry.entryType == .correction, entry.isRegex else { return nil }
            return UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original, isRegex: true)
        }
    }

    static func winningOperations(
        from operations: [CloudFolderSyncOperation],
        localRecords: [String: CloudFolderSyncRecord] = [:]
    ) -> [String: CloudFolderSyncOperation] {
        // Keep migration history readable, but reject unsupported new patterns
        // before they can suppress a valid older correction.
        let operations = operations.filter(operationRegexIsSupported)
        let legacyWinners = legacyWinningOperations(from: operations)
        let legacyAliases = legacyDictionaryAliases(from: operations, localRecords: localRecords)
        return operations.reduce(into: [:]) { result, operation in
            guard operationSchemaIsSupported(operation) else { return }
            guard operationIsValid(operation) else { return }
            if operation.schemaVersion == 1, operation.kind == .upsert,
               let entry = operation.dictionary, entry.entryType == .correction {
                let oldKey = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original)
                guard legacyWinners[oldKey]?.operationId == operation.operationId else { return }
            }
            var operation = operation
            if operation.schemaVersion == 1, operation.collection == .dictionary, operation.kind == .delete,
               operation.itemId.hasPrefix(UserDataSyncIdentity.regexCorrectionPrefix) || localRecords[operation.itemId] == nil {
                operation.itemId = legacyItemID(operation.itemId, aliases: legacyAliases)
            }
            if operation.kind == .upsert, let entry = operation.dictionary {
                var effectiveEntry = entry
                // An old peer may omit the mode of a regex entry it previously received.
                // Only recover an exact pattern, and never steal an existing literal entry.
                if !entry.isRegexFieldPresent,
                   localRecords[UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original)] == nil,
                   localRecords.values.contains(where: {
                       $0.dictionary?.isRegex == true && $0.dictionary?.original.utf8.elementsEqual(entry.original.utf8) == true
                   }) {
                    effectiveEntry = entry.preservingRegexMode(true)
                    operation.dictionary = effectiveEntry
                }
                guard effectiveEntry.isRegexPatternSupported else { return }
                operation.itemId = UserDataSyncIdentity.dictionaryItemID(
                    entryType: effectiveEntry.entryType,
                    original: effectiveEntry.original,
                    isRegex: effectiveEntry.isRegex
                )
            }
            // A legacy tombstone suppresses legacy upserts above, but cannot delete a
            // migrated v2 rule: its folded ID cannot distinguish \d from \D.
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

    private static func operationRegexIsSupported(_ operation: CloudFolderSyncOperation) -> Bool {
        operation.kind != .upsert || operation.dictionary?.isRegexPatternSupported != false
    }

    private static func operationSchemaIsSupported(_ operation: CloudFolderSyncOperation) -> Bool {
        if operation.schemaVersion == 1 { return true }
        guard operation.schemaVersion == 2,
              operation.collection == .dictionary,
              operation.itemId.hasPrefix(UserDataSyncIdentity.regexCorrectionPrefix) else { return false }
        if operation.kind == .delete { return true }
        guard let entry = operation.dictionary, entry.entryType == .correction, entry.isRegex else { return false }
        return operation.itemId == UserDataSyncIdentity.dictionaryItemID(
            entryType: entry.entryType, original: entry.original, isRegex: true
        )
    }

    private static func makeLocalOperations(
        records: [String: CloudFolderSyncRecord],
        deletedHistoryRecords: [UserDataSyncHistoryDeletion],
        state: CloudFolderSyncState,
        legacyRegexItemIDs: [String: String],
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
                    audio: record.historyAudio,
                    transcript: record.historyTranscript,
                    speakers: record.historySpeakers
                ))
            }
        }

        // A rule removed before its first upgraded sync has no v2 key in local state.
        // Delete that exact identity too, including a switch back to a literal at the old ID.
        for (_, regexID) in legacyRegexItemIDs.sorted(by: { $0.key < $1.key })
        where records[regexID] == nil && !state.knownLocalItemIDs.contains(regexID) {
            operations.append(.delete(collection: .dictionary, itemID: regexID, deviceId: state.deviceId, deletedAt: now))
        }

        let deletedItemIDs = state.knownLocalItemIDs
            .subtracting(records.keys)
            .filter { !$0.hasPrefix("history:") }
        for itemID in deletedItemIDs.sorted() {
            // Only a known regex that still exists under its exact ID is a migration.
            // A literal-to-regex edit must still delete the old literal on other devices.
            if let regexID = legacyRegexItemIDs[itemID], records[regexID] != nil { continue }
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
        let historyOperationsByItemID = Dictionary(grouping: historyOperations, by: \.itemId)
        for (itemID, itemOperations) in historyOperationsByItemID.sorted(by: { $0.key < $1.key }) {
            guard let recordID = UserDataSyncIdentity.historyRecordID(from: itemID) else { continue }
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
                case .transcript:
                    if let transcript = operation.historyTranscript, transcript.isValid {
                        mutations.append(.upsertHistoryTranscript(transcript))
                    }
                case .speakers:
                    if let speakers = operation.historySpeakers, speakers.isValid {
                        mutations.append(.upsertHistorySpeakers(speakers))
                    }
                }
            }
        }

        return mutations
    }

    private static func prepareHistoryAssets(
        in snapshot: UserDataSyncSnapshot,
        packageURL: URL,
        generation: String,
        cache: CloudFolderSyncCache
    ) -> (snapshot: UserDataSyncSnapshot, diagnostics: [CloudFolderSyncDiagnostic]) {
        var diagnostics: [CloudFolderSyncDiagnostic] = []
        var publishedPaths = Set<String>()
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
                    durationSeconds: record.content.durationSeconds,
                    digestCache: cache
                )
                publishedPaths.insert(sourceURL.path)
                publishedPaths.insert(packageURL.appendingPathComponent(audio.relativeAssetPath).path)
                return UserDataSyncHistoryRecord(
                    content: record.content,
                    inbox: record.inbox,
                    audio: audio,
                    transcript: record.transcript,
                    speakers: record.speakers,
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
                    transcript: record.transcript,
                    speakers: record.speakers,
                    localAudioFileURL: record.localAudioFileURL,
                    audioEligible: record.audioEligible
                )
            }
        }
        cache.retainDigests(atPaths: publishedPaths)
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
            let recordID = UserDataSyncIdentity.historyRecordID(from: operation.itemId)
            // Exactly the component's own payload may be set.
            let payloadCount = [
                operation.historyContent != nil,
                operation.historyInbox != nil,
                operation.historyAudio != nil,
                operation.historyTranscript != nil,
                operation.historySpeakers != nil,
            ].filter { $0 }.count
            if operation.kind == .delete {
                return operation.historyComponent == nil && payloadCount == 0
            }
            guard payloadCount == 1 else { return false }
            switch operation.historyComponent {
            case .content:
                return operation.historyContent?.recordID == recordID
            case .inbox:
                return operation.historyInbox?.recordID == recordID
            case .audio:
                return operation.historyAudio?.recordID == recordID
                    && operation.historyAudio?.isValid == true
            case .transcript:
                return operation.historyTranscript?.recordID == recordID
                    && operation.historyTranscript?.isValid == true
            case .speakers:
                return operation.historySpeakers?.recordID == recordID
                    && operation.historySpeakers?.isValid == true
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
            if let presencePreference = dictionaryFieldPresencePreference(
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
        if let presencePreference = dictionaryFieldPresencePreference(
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
            createdBy: "dictum",
            updatedAt: now
        )
        try writeJSON(manifest, to: packageURL.appendingPathComponent(manifestFileName))

        let device = CloudFolderSyncDeviceRecord(
            deviceId: deviceId,
            historyOriginDeviceID: historyOriginDeviceID,
            platform: "macOS",
            appVersion: AppConstants.currentReleaseFingerprint,
            updatedAt: now,
            name: deviceName,
            capabilities: [CloudFolderSyncDeviceRecord.speakerTranscriptCapability]
        )
        try writeJSON(device, to: devicesURL.appendingPathComponent("\(deviceId).json"))
    }

    /// Reads the device catalog of a package without syncing; nil when it cannot be listed.
    static func devices(folderURL: URL) -> [CloudFolderSyncDeviceRecord]? {
        let devicesURL = packageURL(for: folderURL)
            .appendingPathComponent(devicesDirectoryName, isDirectory: true)
        return try? readDevices(from: devicesURL).devices
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
        from operationsURL: URL,
        cache: CloudFolderSyncCache? = nil
    ) throws -> (operations: [CloudFolderSyncOperation], diagnostics: [CloudFolderSyncDiagnostic]) {
        let deviceDirectories = try FileManager.default.contentsOfDirectory(
            at: operationsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var operations: [CloudFolderSyncOperation] = []
        var diagnostics: [CloudFolderSyncDiagnostic] = []
        var listedPaths = Set<String>()
        for deviceDirectory in deviceDirectories {
            guard (try? deviceDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: deviceDirectory,
                    includingPropertiesForKeys: Array(CloudFolderSyncFileStamp.resourceKeys),
                    options: [.skipsHiddenFiles]
                )
            } catch {
                diagnostics.append(.init(kind: .unreadableFile, fileName: deviceDirectory.lastPathComponent))
                continue
            }

            for file in files where file.pathExtension == "json" {
                listedPaths.insert(file.path)
                switch operationFileContents(at: file, cache: cache) {
                case .operation(let operation) where operationSchemaIsSupported(operation):
                    operations.append(operation)
                case .operation, .unsupportedSchema:
                    diagnostics.append(.init(kind: .unsupportedSchema, fileName: file.lastPathComponent))
                case .malformed:
                    diagnostics.append(.init(kind: .malformedOperation, fileName: file.lastPathComponent))
                case .unreadable:
                    diagnostics.append(.init(kind: .unreadableFile, fileName: file.lastPathComponent))
                case .unknownHistoryComponent:
                    // Written by a newer client (speaker transcripts, for example); not a fault.
                    break
                }
            }
        }
        cache?.retainOperations(atPaths: listedPaths)
        return (operations, diagnostics)
    }

    private enum OperationFileContents {
        case operation(CloudFolderSyncOperation)
        case unsupportedSchema
        case malformed
        case unreadable
        case unknownHistoryComponent
    }

    /// Decodes an operation file once and reuses the result while the file is unchanged.
    /// Operation files are write-once, so an unchanged size and modification date means
    /// unchanged contents.
    private static func operationFileContents(
        at file: URL,
        cache: CloudFolderSyncCache?
    ) -> OperationFileContents {
        let stamp = (try? file.resourceValues(forKeys: CloudFolderSyncFileStamp.resourceKeys))
            .flatMap { CloudFolderSyncFileStamp($0) }
        if let operation = cache?.operation(atPath: file.path, stamp: stamp) {
            return .operation(operation)
        }
        guard let data = try? Data(contentsOf: file) else {
            return .unreadable
        }
        if let operation = try? decoder.decode(CloudFolderSyncOperation.self, from: data) {
            guard operation.schemaVersion >= 1,
                  [operation.operationId, operation.deviceId, operation.itemId].allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else { return .malformed }
            cache?.storeOperation(operation, atPath: file.path, stamp: stamp, byteCount: data.count)
            return .operation(operation)
        }
        // Ignored future formats still need complete common metadata. Otherwise a
        // partially downloaded file could be mistaken for a replaced sync package.
        guard let envelope = try? decoder.decode(CloudFolderSyncSchemaEnvelope.self, from: data),
              envelope.isReadable else {
            return .malformed
        }
        if envelope.schemaVersion > 2 { return .unsupportedSchema }
        if envelope.schemaVersion == 1,
           envelope.collection == .string(UserDataSyncCollection.history.rawValue),
           let component = envelope.historyComponent,
           UserDataSyncHistoryComponent(rawValue: component) == nil {
            return .unknownHistoryComponent
        }
        return .malformed
    }

    /// Lists the sync package without reading file contents. Manifest and device files are
    /// rewritten by every sync, so only device file names take part in the comparison.
    static func packageFingerprint(folderURL: URL) -> CloudFolderSyncPackageFingerprint? {
        packageFingerprint(packageURL: packageURL(for: folderURL))
    }

    private static func packageFingerprint(packageURL: URL) -> CloudFolderSyncPackageFingerprint? {
        let fileManager = FileManager.default
        let operationsURL = packageURL.appendingPathComponent(operationsDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: operationsURL.path) else { return nil }

        let resourceKeys = CloudFolderSyncFileStamp.resourceKeys.union([.isRegularFileKey])
        var files: [String: CloudFolderSyncFileStamp?] = [:]
        for directoryURL in [
            operationsURL,
            packageURL.appendingPathComponent(assetsDirectoryName, isDirectory: true),
        ] {
            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true else {
                    continue
                }
                files.updateValue(CloudFolderSyncFileStamp(values), forKey: file.path)
            }
        }

        let devicesURL = packageURL.appendingPathComponent(devicesDirectoryName, isDirectory: true)
        let deviceFileNames = (try? fileManager.contentsOfDirectory(
            at: devicesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "json" }.map(\.lastPathComponent) ?? []
        return CloudFolderSyncPackageFingerprint(
            files: files,
            deviceFileNames: Set(deviceFileNames)
        )
    }

    private static func pruneExpiredTombstones(
        in deviceOperationsURL: URL,
        now: Date,
        cache: CloudFolderSyncCache
    ) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: deviceOperationsURL,
            includingPropertiesForKeys: Array(CloudFolderSyncFileStamp.resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for file in files where file.pathExtension == "json" {
            guard case .operation(let operation) = operationFileContents(at: file, cache: cache),
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
        "dictionary-v3|\(versionString(for: entry.updatedAt))"
    }

    private static func dictionaryFieldPresencePreference(
        candidate: UserDataSyncDictionaryEntry?,
        existing: UserDataSyncDictionaryEntry?
    ) -> Bool? {
        if candidate?.entryType == .correction,
           existing?.entryType == .correction,
           candidate?.isRegexFieldPresent != existing?.isRegexFieldPresent {
            return candidate?.isRegexFieldPresent == true
        }
        guard candidate?.entryType == .term,
              existing?.entryType == .term,
              candidate?.ctcMinSimilarityFieldPresent
                != existing?.ctcMinSimilarityFieldPresent else {
            return nil
        }
        return candidate?.ctcMinSimilarityFieldPresent == true
    }

    /// State keys whose records an applied mutation can change. A history mutation can add
    /// placeholder components or remove the whole item, so it covers every component.
    private static func stateKeys(changedBy mutations: [UserDataSyncMutation]) -> Set<String> {
        var keys = Set<String>()
        for mutation in mutations {
            let historyRecordID: UUID
            switch mutation {
            case .restoreLegacyDictionaryRegex(let entry):
                keys.insert(UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original))
                keys.insert(UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original, isRegex: true))
                continue
            case .upsertDictionary(let entry):
                keys.insert(UserDataSyncIdentity.dictionaryItemID(
                    entryType: entry.entryType,
                    original: entry.original,
                    isRegex: entry.isRegex
                ))
                continue
            case .deleteDictionary(let itemID), .deleteSnippet(let itemID):
                keys.insert(itemID)
                continue
            case .upsertSnippet(let snippet):
                keys.insert(UserDataSyncIdentity.snippetItemID(trigger: snippet.trigger))
                continue
            case .upsertHistoryContent(let content):
                historyRecordID = content.recordID
            case .upsertHistoryInbox(let inbox):
                historyRecordID = inbox.recordID
            case .upsertHistoryAudio(let audio):
                historyRecordID = audio.recordID
            case .upsertHistoryTranscript(let transcript):
                historyRecordID = transcript.recordID
            case .upsertHistorySpeakers(let speakers):
                historyRecordID = speakers.recordID
            case .deleteHistory(let recordID):
                historyRecordID = recordID
            }
            let itemID = UserDataSyncIdentity.historyItemID(recordID: historyRecordID)
            for component in UserDataSyncHistoryComponent.allCases {
                keys.insert(UserDataSyncIdentity.historyStateKey(itemID: itemID, component: component))
            }
        }
        return keys
    }

    /// The speaker components another device actually sent, unlike
    /// `stateKeys(changedBy:)`, which lists every component of a changed record.
    private static func receivedSpeakerComponentKeys(from mutations: [UserDataSyncMutation]) -> Set<String> {
        var keys = Set<String>()
        for mutation in mutations {
            switch mutation {
            case .upsertHistoryTranscript(let transcript):
                keys.insert(speakerComponentKey(recordID: transcript.recordID, component: .transcript))
            case .upsertHistorySpeakers(let speakers):
                keys.insert(speakerComponentKey(recordID: speakers.recordID, component: .speakers))
            case .deleteHistory(let recordID):
                keys.insert(speakerComponentKey(recordID: recordID, component: .transcript))
                keys.insert(speakerComponentKey(recordID: recordID, component: .speakers))
            default:
                continue
            }
        }
        return keys
    }

    /// Speaker names whose merge kept names this device had and the other
    /// did not: the stored names are newer than the ones applied.
    private static func speakerKeysRequiringRepublish(
        afterApplying mutations: [UserDataSyncMutation],
        records: [String: CloudFolderSyncRecord]
    ) -> Set<String> {
        Set(mutations.compactMap { mutation in
            guard case .upsertHistorySpeakers(let speakers) = mutation else { return nil }
            let key = speakerComponentKey(recordID: speakers.recordID, component: .speakers)
            guard let record = records[key], record.version != versionString(for: speakers.updatedAt) else {
                return nil
            }
            return key
        })
    }

    private static func speakerComponentKey(recordID: UUID, component: UserDataSyncHistoryComponent) -> String {
        UserDataSyncIdentity.historyStateKey(
            itemID: UserDataSyncIdentity.historyItemID(recordID: recordID),
            component: component
        )
    }

    private static func dictionaryItemIDsRequiringRepublish(
        afterApplying mutations: [UserDataSyncMutation],
        legacyRegexEntries: [UserDataSyncDictionaryEntry]
    ) -> Set<String> {
        Set(mutations.compactMap { mutation in
            guard case .upsertDictionary(let entry) = mutation else { return nil }
            let missingField = entry.entryType == .term
                ? !entry.ctcMinSimilarityFieldPresent
                : !entry.isRegexFieldPresent
            let migratedRegex = entry.isRegex && legacyRegexEntries.contains {
                $0.original.utf8.elementsEqual(entry.original.utf8)
            }
            guard missingField || migratedRegex else { return nil }
            return UserDataSyncIdentity.dictionaryItemID(
                entryType: entry.entryType,
                original: entry.original,
                isRegex: entry.isRegex
            )
        })
    }

    private static func iso8601String(from date: Date) -> String {
        CloudFolderSyncDateFormatters.shared.string(from: date)
    }

    private static func iso8601Date(from string: String) -> Date? {
        CloudFolderSyncDateFormatters.shared.date(from: string)
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
    let operationId: String
    let deviceId: String
    let itemId: String
    let collection: EnumValue
    let kind: EnumValue
    let updatedAt: Date
    let historyComponent: String?

    var isReadable: Bool {
        schemaVersion >= 1 &&
            [operationId, deviceId, itemId].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
            (schemaVersion > 2 || kind.isKnownOperationKind)
    }

    // Match Windows' string and integer enum encodings without interpreting
    // future collection names, operation kinds, or payloads.
    enum EnumValue: Decodable, Equatable {
        case string(String)
        case integer(Int32)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Empty sync enum value")
                }
                self = .string(value)
            } else {
                self = .integer(try container.decode(Int32.self))
            }
        }

        var isKnownOperationKind: Bool {
            switch self {
            case .string(let value): CloudFolderSyncOperation.Kind(rawValue: value) != nil
            case .integer(let value): value == 0 || value == 1
            }
        }
    }
}

/// Shared ISO 8601 formatters for sync payloads. Creating a formatter per date dominated
/// snapshot conversion; ISO8601DateFormatter wraps a CFDateFormatter, which is not
/// thread-safe, so the shared instances are only used under the lock.
private final class CloudFolderSyncDateFormatters: @unchecked Sendable {
    static let shared = CloudFolderSyncDateFormatters()

    private let lock = NSLock()
    private let fractionalFormatter: ISO8601DateFormatter
    private let wholeSecondFormatter: ISO8601DateFormatter

    private init() {
        fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeSecondFormatter = ISO8601DateFormatter()
        wholeSecondFormatter.formatOptions = [.withInternetDateTime]
    }

    func string(from date: Date) -> String {
        lock.withLock { fractionalFormatter.string(from: date) }
    }

    func date(from string: String) -> Date? {
        lock.withLock {
            fractionalFormatter.date(from: string) ?? wholeSecondFormatter.date(from: string)
        }
    }
}

/// Size and modification date of a file, used to reuse work for files that did not change.
struct CloudFolderSyncFileStamp: Equatable, Sendable {
    static let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]

    let byteCount: Int
    let modificationDate: Date

    init?(_ values: URLResourceValues) {
        guard let byteCount = values.fileSize,
              let modificationDate = values.contentModificationDate else {
            return nil
        }
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }

    /// Reads fresh metadata instead of values cached on a long-lived URL.
    init?(fileAt url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let byteCount = (attributes[.size] as? NSNumber)?.intValue,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }
}

struct CloudFolderSyncPackageFingerprint: Equatable, Sendable {
    let files: [String: CloudFolderSyncFileStamp?]
    let deviceFileNames: Set<String>
}

/// Caches owned by the sync controller so repeated syncs skip unchanged files. Entries are
/// keyed by path and only reused while the file keeps the stamp it had when it was read.
final class CloudFolderSyncCache: @unchecked Sendable {
    private struct CachedOperation {
        let stamp: CloudFolderSyncFileStamp
        let operation: CloudFolderSyncOperation
    }

    private struct CachedDigest {
        let stamp: CloudFolderSyncFileStamp
        let sha256: String
        let byteCount: Int64
    }

    private let lock = NSLock()
    private var operations: [String: CachedOperation] = [:]
    private var digests: [String: CachedDigest] = [:]

    func operation(atPath path: String, stamp: CloudFolderSyncFileStamp?) -> CloudFolderSyncOperation? {
        guard let stamp else { return nil }
        return lock.withLock {
            guard let cached = operations[path], cached.stamp == stamp else { return nil }
            return cached.operation
        }
    }

    func storeOperation(
        _ operation: CloudFolderSyncOperation,
        atPath path: String,
        stamp: CloudFolderSyncFileStamp?,
        byteCount: Int
    ) {
        guard let stamp, stamp.byteCount == byteCount else { return }
        lock.withLock {
            operations[path] = CachedOperation(stamp: stamp, operation: operation)
        }
    }

    func retainOperations(atPaths paths: Set<String>) {
        lock.withLock {
            operations = operations.filter { paths.contains($0.key) }
        }
    }

    func digest(
        of url: URL,
        compute: (URL) throws -> (sha256: String, byteCount: Int64)
    ) rethrows -> (sha256: String, byteCount: Int64) {
        let path = url.path
        let stamp = CloudFolderSyncFileStamp(fileAt: url)
        if let stamp,
           let cached = lock.withLock({ digests[path] }),
           cached.stamp == stamp {
            return (cached.sha256, cached.byteCount)
        }
        let digest = try compute(url)
        // Only remember digests of files that did not change while they were hashed.
        if let stamp,
           Int64(stamp.byteCount) == digest.byteCount,
           CloudFolderSyncFileStamp(fileAt: url) == stamp {
            lock.withLock {
                digests[path] = CachedDigest(stamp: stamp, sha256: digest.sha256, byteCount: digest.byteCount)
            }
        }
        return digest
    }

    func retainDigests(atPaths paths: Set<String>) {
        lock.withLock {
            digests = digests.filter { paths.contains($0.key) }
        }
    }
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
    var historyTranscript: UserDataSyncHistoryTranscriptV1? = nil
    var historySpeakers: UserDataSyncHistorySpeakersV1? = nil

    var stateKey: String {
        guard let historyComponent else { return itemID }
        return UserDataSyncIdentity.historyStateKey(
            itemID: itemID,
            component: historyComponent
        )
    }
}
