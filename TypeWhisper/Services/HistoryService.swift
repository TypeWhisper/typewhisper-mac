import Foundation
import SwiftData
import Combine
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "HistoryService")

struct HistoryPage {
    let records: [TranscriptionRecord]
    let totalCount: Int
    let offset: Int

    var hasMore: Bool { offset + records.count < totalCount }
}

struct HistoryQuery {
    enum Collection {
        case all
        case inbox
        case withAudio
        case failed
    }

    enum SortOrder {
        case newest
        case oldest
        case duration
        case appName
    }

    var searchText = ""
    var appBundleIdentifier: String?
    var cutoffDate: Date?
    var collection: Collection = .all
    var originDeviceID: String?
    var includeLegacyCurrentMacRecords = false
    var source: RecordingSource?
    var sortOrder: SortOrder = .newest
}

struct HistoryAppFacet: Hashable {
    let bundleID: String
    let name: String
    let count: Int
}

struct HistoryDeviceFacet: Hashable {
    let deviceID: String
    let platform: String
    let source: RecordingSource
    let count: Int
}

struct HistoryFacets {
    let totalCount: Int
    let inboxCount: Int
    let audioCount: Int
    let failedCount: Int
    let apps: [HistoryAppFacet]
    let devices: [HistoryDeviceFacet]
}

@MainActor
final class HistoryService: ObservableObject {
    static let pluginSyncActionID = "com.typewhisper.history.transcription-updated"
    static let recentRecordsLimit = 20

    private struct PluginSyncPayload: Codable {
        let id: UUID
        let rawText: String
        let finalText: String
        let language: String?
        let engineUsed: String
        let modelUsed: String?
        let durationSeconds: Double
        let appName: String?
        let bundleIdentifier: String?
        let url: String?
        let pipelineSteps: [String]
    }

    /// A deliberately bounded cache for surfaces that only need recent history.
    /// Consumers requiring completeness must use `fetchPage`, `record(withID:)`,
    /// `recordCount`, or `allRecords` instead.
    @Published private(set) var recentRecords: [TranscriptionRecord] = []

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let eventEmitter: @MainActor (TypeWhisperEvent) -> Void
    private let historySyncPreferences: HistorySyncPreferences?

    private(set) var totalRecords: Int = 0

    private let audioDirectory: URL

    init(
        appSupportDirectory: URL = AppConstants.appSupportDirectory,
        historySyncPreferences: HistorySyncPreferences? = nil,
        eventEmitter: @escaping @MainActor (TypeWhisperEvent) -> Void = { event in
            EventBus.shared?.emit(event)
        }
    ) {
        let storeDir = appSupportDirectory
        self.eventEmitter = eventEmitter
        self.historySyncPreferences = historySyncPreferences

        let audioDir = storeDir.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        self.audioDirectory = audioDir

        do {
            let (container, context) = try SwiftDataStoreFactory.create(
                for: [TranscriptionRecord.self],
                storeName: "history",
                in: appSupportDirectory
            )
            modelContainer = container
            modelContext = context
        } catch {
            fatalError("Failed to initialize history store: \(error)")
        }

        migrateWordsCountIfNeeded()
        refreshRecentRecords()
    }

    @discardableResult
    func addRecord(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        finalText: String,
        appName: String?,
        appBundleIdentifier: String?,
        appURL: String? = nil,
        durationSeconds: Double,
        language: String?,
        engineUsed: String,
        modelUsed: String? = nil,
        audioSamples: [Float]? = nil,
        pipelineSteps: [String]? = nil
    ) -> Bool {
        let sanitizedRaw = Self.sanitize(rawText)
        let sanitizedFinal = Self.sanitize(finalText)
        guard !sanitizedRaw.isEmpty, !sanitizedFinal.isEmpty else {
            logger.warning("Skipping history record: empty text after sanitization")
            return false
        }
        guard durationSeconds.isFinite, durationSeconds >= 0 else {
            logger.warning("Skipping history record: invalid duration \(durationSeconds)")
            return false
        }
        let recordId = id
        var audioFileName: String?

        if let samples = audioSamples, !samples.isEmpty {
            let fileName = "\(recordId.uuidString).wav"
            let fileURL = audioDirectory.appendingPathComponent(fileName)
            let wavData = WavEncoder.encode(samples)
            do {
                try wavData.write(to: fileURL, options: .atomic)
                audioFileName = fileName
                logger.info("Saved audio file: \(fileName)")
            } catch {
                logger.error("Failed to save audio file: \(error.localizedDescription)")
            }
        }

        let record = TranscriptionRecord(
            id: recordId,
            timestamp: timestamp,
            rawText: sanitizedRaw,
            finalText: sanitizedFinal,
            appName: appName.flatMap { let s = Self.sanitize($0); return s.isEmpty ? nil : s },
            appBundleIdentifier: appBundleIdentifier,
            appURL: appURL,
            durationSeconds: durationSeconds,
            language: language,
            engineUsed: engineUsed.isEmpty ? "unknown" : engineUsed,
            modelUsed: modelUsed,
            audioFileName: audioFileName
        )
        record.pipelineStepList = pipelineSteps ?? []
        record.originDeviceID = historySyncPreferences?.deviceID ?? ""
        record.originPlatformRaw = "macOS"
        record.source = .mac
        record.historySyncAudioEligible = historySyncPreferences?.isEnabled == true
            && historySyncPreferences?.isAudioEnabled == true
            && audioFileName != nil
        modelContext.insert(record)
        save()
        refreshRecentRecords()
        return true
    }

    func audioFileURL(for record: TranscriptionRecord) -> URL? {
        guard let fileName = record.audioFileName else { return nil }
        let url = audioDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func updateRecord(_ record: TranscriptionRecord, finalText: String) {
        record.finalText = finalText
        record.renderedDocument = nil
        record.synchronizedStructuredDocument = nil
        record.wordsCount = finalText.split(separator: " ").count
        record.contentUpdatedAt = Date()
        save()
        refreshRecentRecords()
        let payload = PluginSyncPayload(
            id: record.id,
            rawText: record.rawText,
            finalText: record.finalText,
            language: record.language,
            engineUsed: record.engineUsed,
            modelUsed: record.modelUsed,
            durationSeconds: record.durationSeconds,
            appName: record.appName,
            bundleIdentifier: record.appBundleIdentifier,
            url: record.appURL,
            pipelineSteps: record.pipelineStepList
        )
        guard let data = try? JSONEncoder().encode(payload),
              let message = String(data: data, encoding: .utf8) else {
            logger.error("Failed to encode history plugin sync payload")
            return
        }
        // Keep the public plugin SDK on compatibility line v1 by using its existing
        // action-completed envelope for this private host-to-plugin notification.
        eventEmitter(.actionCompleted(ActionCompletedPayload(
            timestamp: record.timestamp,
            actionId: Self.pluginSyncActionID,
            success: true,
            message: message,
            url: record.appURL,
            appName: record.appName,
            bundleIdentifier: record.appBundleIdentifier
        )))
    }

    func deleteRecord(_ record: TranscriptionRecord) {
        historySyncPreferences?.recordExplicitDeletion(record.id)
        deleteAudioFile(for: record)
        modelContext.delete(record)
        save()
        refreshRecentRecords()
    }

    func deleteRecords(_ records: [TranscriptionRecord]) {
        historySyncPreferences?.recordExplicitDeletions(records.map(\.id))
        for record in records {
            deleteAudioFile(for: record)
            modelContext.delete(record)
        }
        save()
        refreshRecentRecords()
    }

    func clearAll() {
        do {
            let allRecords = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
            historySyncPreferences?.recordExplicitDeletions(allRecords.map(\.id))
            for record in allRecords {
                deleteAudioFile(for: record)
                modelContext.delete(record)
            }
            save()
            refreshRecentRecords()
        } catch {
            logger.error("Failed to clear records: \(error.localizedDescription)")
        }
    }

    func searchRecords(query: String) -> [TranscriptionRecord] {
        fetchPage(
            query: HistoryQuery(searchText: query),
            offset: 0,
            limit: Int.max
        ).records
    }

    func fetchPage(
        query: HistoryQuery = HistoryQuery(),
        offset: Int,
        limit: Int
    ) -> HistoryPage {
        var descriptor = fetchDescriptor(for: query)
        let requestedOffset = max(offset, 0)
        let requestedLimit = max(limit, 0)

        // Device identity combines persisted fields, and free-text search spans computed
        // values. Enumerate these queries in batches so only the requested page is retained.
        if requiresPostFiltering(query) {
            var records: [TranscriptionRecord] = []
            var totalCount = 0
            do {
                try modelContext.enumerate(descriptor, batchSize: 500) { record in
                    guard matchesPostFilters(record, query: query) else { return }
                    if totalCount >= requestedOffset, records.count < requestedLimit {
                        records.append(record)
                    }
                    totalCount += 1
                }
                return HistoryPage(
                    records: records,
                    totalCount: totalCount,
                    offset: requestedOffset
                )
            } catch {
                logger.error("Failed to enumerate filtered history: \(error.localizedDescription)")
                return HistoryPage(records: [], totalCount: 0, offset: requestedOffset)
            }
        }

        let totalCount: Int
        do {
            totalCount = try modelContext.fetchCount(descriptor)
        } catch {
            logger.error("Failed to count history records: \(error.localizedDescription)")
            return HistoryPage(records: [], totalCount: 0, offset: max(offset, 0))
        }

        let boundedOffset = min(requestedOffset, totalCount)
        descriptor.fetchOffset = boundedOffset
        if limit != Int.max {
            descriptor.fetchLimit = requestedLimit
        }

        do {
            return HistoryPage(
                records: try modelContext.fetch(descriptor),
                totalCount: totalCount,
                offset: requestedOffset
            )
        } catch {
            logger.error("Failed to fetch history page: \(error.localizedDescription)")
            return HistoryPage(records: [], totalCount: totalCount, offset: requestedOffset)
        }
    }

    func recordCount(query: HistoryQuery = HistoryQuery()) -> Int {
        if requiresPostFiltering(query) {
            var count = 0
            do {
                try modelContext.enumerate(fetchDescriptor(for: query), batchSize: 500) { record in
                    if matchesPostFilters(record, query: query) { count += 1 }
                }
                return count
            } catch {
                logger.error("Failed to count filtered history records: \(error.localizedDescription)")
                return 0
            }
        }
        do {
            return try modelContext.fetchCount(fetchDescriptor(for: query))
        } catch {
            logger.error("Failed to count history records: \(error.localizedDescription)")
            return 0
        }
    }

    func facets(currentDeviceID: String?) -> HistoryFacets {
        struct AppAccumulator {
            var name: String
            var count: Int
        }
        struct DeviceKey: Hashable {
            let deviceID: String
            let platform: String
            let source: RecordingSource
        }

        var totalCount = 0
        var inboxCount = 0
        var audioCount = 0
        var failedCount = 0
        var apps: [String: AppAccumulator] = [:]
        var devices: [DeviceKey: Int] = [:]
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<TranscriptionRecord>()
        descriptor.propertiesToFetch = [
            \TranscriptionRecord.appName,
            \TranscriptionRecord.appBundleIdentifier,
            \TranscriptionRecord.originDeviceID,
            \TranscriptionRecord.originPlatformRaw,
            \TranscriptionRecord.sourceRaw,
            \TranscriptionRecord.inboxStateRaw,
            \TranscriptionRecord.processingStateRaw,
            \TranscriptionRecord.audioFileName,
            \TranscriptionRecord.remoteAudioRelativePath,
        ]

        do {
            try context.enumerate(descriptor, batchSize: 500) { record in
                totalCount += 1
                if record.isOpenInInbox { inboxCount += 1 }
                if record.audioFileName != nil || record.hasRemoteAudio { audioCount += 1 }
                if record.processingState == .failed { failedCount += 1 }

                if let bundleID = record.appBundleIdentifier,
                   let name = record.appName,
                   !bundleID.isEmpty,
                   !name.isEmpty {
                    var value = apps[bundleID] ?? AppAccumulator(name: name, count: 0)
                    value.name = name
                    value.count += 1
                    apps[bundleID] = value
                }

                let platform = record.originPlatformRaw
                let trimmedID = record.originDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedPlatform = platform.lowercased()
                let deviceID: String
                if !trimmedID.isEmpty {
                    deviceID = trimmedID
                } else if normalizedPlatform.contains("mac"), let currentDeviceID {
                    deviceID = currentDeviceID
                } else {
                    deviceID = "platform:\(normalizedPlatform.isEmpty ? "unknown" : normalizedPlatform)"
                }
                devices[DeviceKey(deviceID: deviceID, platform: platform, source: record.source), default: 0] += 1
            }
        } catch {
            logger.error("Failed to build history facets: \(error.localizedDescription)")
        }

        return HistoryFacets(
            totalCount: totalCount,
            inboxCount: inboxCount,
            audioCount: audioCount,
            failedCount: failedCount,
            apps: apps.map {
                HistoryAppFacet(bundleID: $0.key, name: $0.value.name, count: $0.value.count)
            },
            devices: devices.map {
                HistoryDeviceFacet(
                    deviceID: $0.key.deviceID,
                    platform: $0.key.platform,
                    source: $0.key.source,
                    count: $0.value
                )
            }
        )
    }

    func allRecords(query: HistoryQuery = HistoryQuery()) -> [TranscriptionRecord] {
        do {
            let records = try modelContext.fetch(fetchDescriptor(for: query))
            guard requiresPostFiltering(query) else { return records }
            return records.filter { matchesPostFilters($0, query: query) }
        } catch {
            logger.error("Failed to fetch complete history: \(error.localizedDescription)")
            return []
        }
    }

    func record(withID id: UUID) -> TranscriptionRecord? {
        var descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            logger.error("Failed to fetch history record by ID: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func deleteRecord(withID id: UUID) -> Bool {
        guard let record = record(withID: id) else { return false }
        deleteRecord(record)
        return true
    }

    func uniqueDomains(limit: Int = 50) -> [String] {
        var counts: [String: Int] = [:]
        for record in allRecords() {
            guard let domain = record.appDomain else { continue }
            let cleaned = domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
            guard !cleaned.isEmpty else { continue }
            counts[cleaned, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    func purgeOldRecords(retentionDays: Int = 90) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate { $0.timestamp < cutoff }
        )
        let old: [TranscriptionRecord]
        do {
            old = try modelContext.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch records for retention: \(error.localizedDescription)")
            return
        }
        guard !old.isEmpty else { return }
        historySyncPreferences?.recordRetentionPrunes(old.map(\.id))
        for record in old {
            deleteAudioFile(for: record)
            modelContext.delete(record)
        }
        save()
        refreshRecentRecords()
    }

    func completeInbox(_ record: TranscriptionRecord) {
        guard record.inboxState == .open else { return }
        record.inboxState = .completed
        record.inboxCompletedAt = Date()
        record.inboxUpdatedAt = Date()
        save()
        refreshRecentRecords()
    }

    func reopenInbox(_ record: TranscriptionRecord) {
        guard record.inboxState == .completed else { return }
        record.inboxState = .open
        record.inboxCompletedAt = nil
        record.inboxUpdatedAt = Date()
        save()
        refreshRecentRecords()
    }

    func userDataSyncHistoryRecords() -> [UserDataSyncHistoryRecord] {
        guard historySyncPreferences?.isEnabled == true else { return [] }
        return allRecords().compactMap { record in
            guard historySyncPreferences?.isSuppressed(record.id) != true,
                  historySyncPreferences?.explicitDeletions[
                    record.id.uuidString.lowercased()
                  ] == nil else {
                return nil
            }
            let content = UserDataSyncHistoryContentV1(
                recordID: record.id,
                createdAt: record.timestamp,
                updatedAt: synchronizedTimestamp(record.contentUpdatedAt, fallback: record.timestamp),
                originDeviceID: record.originDeviceID.isEmpty
                    ? (historySyncPreferences?.deviceID ?? "")
                    : record.originDeviceID,
                originPlatform: record.originPlatformRaw,
                source: record.sourceRaw,
                processingState: record.processingStateRaw,
                rawTranscript: record.rawText,
                finalText: record.finalText,
                renderedDocument: record.renderedDocument,
                structuredDocument: record.synchronizedStructuredDocument,
                appDisplayName: record.appName,
                durationSeconds: record.durationSeconds,
                detectedLanguage: record.language,
                engineDisplayName: record.engineUsed,
                modelDisplayName: record.modelUsed,
                processingFailureCategory: record.processingFailureCategory,
                processingFailureMessage: record.processingFailureMessage
            )
            let inbox = UserDataSyncHistoryInboxV1(
                recordID: record.id,
                updatedAt: synchronizedTimestamp(record.inboxUpdatedAt, fallback: record.timestamp),
                state: record.inboxStateRaw,
                kind: record.inboxKindRaw,
                completionPolicy: UserDataSyncHistoryCompletionPolicy(
                    rawValue: record.inboxCompletionPolicyRaw
                ) ?? .explicit,
                completedAt: record.inboxCompletedAt,
                safeAction: record.inboxSafeActionData.flatMap {
                    try? JSONDecoder().decode(
                        UserDataSyncHistorySafeActionV1.self,
                        from: $0
                    )
                }
            )
            return UserDataSyncHistoryRecord(
                content: content,
                inbox: inbox,
                audio: synchronizedAudioDescriptor(for: record),
                localAudioFileURL: record.historySyncAudioEligible
                    ? audioFileURL(for: record)
                    : nil,
                audioEligible: record.historySyncAudioEligible
            )
        }
    }

    func userDataSyncHistoryDeletions() -> [UserDataSyncHistoryDeletion] {
        guard historySyncPreferences?.isEnabled == true else { return [] }
        return historySyncPreferences?.explicitDeletions.compactMap { key, date in
            UUID(uuidString: key).map {
                UserDataSyncHistoryDeletion(recordID: $0, deletedAt: date)
            }
        } ?? []
    }

    func applyUserDataSyncMutations(_ mutations: [UserDataSyncMutation]) throws {
        for mutation in mutations {
            switch mutation {
            case .upsertHistoryContent(let content):
                guard historySyncPreferences?.isSuppressed(content.recordID) != true else { continue }
                let record = remoteRecord(for: content.recordID, timestamp: content.createdAt)
                guard content.updatedAt >= synchronizedTimestamp(
                    record.contentUpdatedAt,
                    fallback: record.timestamp
                ) else { continue }
                record.timestamp = content.createdAt
                record.rawText = content.rawTranscript
                record.finalText = content.finalText
                record.renderedDocument = content.renderedDocument
                record.synchronizedStructuredDocument = content.structuredDocument
                record.appName = content.appDisplayName
                record.durationSeconds = content.durationSeconds
                record.language = content.detectedLanguage
                record.engineUsed = content.engineDisplayName
                record.modelUsed = content.modelDisplayName
                record.wordsCount = content.finalText.split(whereSeparator: \.isWhitespace).count
                record.originDeviceID = content.originDeviceID
                record.originPlatformRaw = content.originPlatform
                record.sourceRaw = content.source
                record.processingStateRaw = content.processingState
                record.processingFailureCategory = content.processingFailureCategory
                record.processingFailureMessage = content.processingFailureMessage
                record.contentUpdatedAt = content.updatedAt
            case .upsertHistoryInbox(let inbox):
                guard historySyncPreferences?.isSuppressed(inbox.recordID) != true else { continue }
                let record = remoteRecord(for: inbox.recordID, timestamp: inbox.updatedAt)
                guard inbox.updatedAt >= synchronizedTimestamp(
                    record.inboxUpdatedAt,
                    fallback: record.timestamp
                ) else { continue }
                record.inboxStateRaw = inbox.state
                record.inboxKindRaw = inbox.kind
                record.inboxCompletionPolicyRaw = inbox.completionPolicy.rawValue
                record.inboxCompletedAt = inbox.completedAt
                record.inboxSafeActionData = inbox.safeAction.flatMap {
                    try? JSONEncoder().encode($0)
                }
                record.inboxUpdatedAt = inbox.updatedAt
            case .upsertHistoryAudio(let audio):
                guard historySyncPreferences?.isSuppressed(audio.recordID) != true,
                      audio.isValid else { continue }
                let record = remoteRecord(for: audio.recordID, timestamp: audio.createdAt)
                guard audio.updatedAt >= synchronizedTimestamp(
                    record.audioUpdatedAt,
                    fallback: record.timestamp
                ) else { continue }
                record.remoteAudioRelativePath = audio.relativeAssetPath
                record.remoteAudioMediaType = audio.mediaType
                record.remoteAudioByteCount = audio.byteCount
                record.remoteAudioSHA256 = audio.sha256
                record.remoteAudioCreatedAt = audio.createdAt
                record.remoteAudioDurationSeconds = audio.durationSeconds
                record.audioUpdatedAt = audio.updatedAt
                record.historySyncAudioEligible = false
            case .deleteHistory(let recordID):
                if let record = record(withID: recordID) {
                    deleteAudioFile(for: record)
                    modelContext.delete(record)
                }
            case .upsertDictionary,
                 .deleteDictionary,
                 .upsertSnippet,
                 .deleteSnippet:
                continue
            }
        }
        try modelContext.save()
        refreshRecentRecords()
    }

    func installSynchronizedAudio(recordID: UUID, sourceURL: URL) throws {
        guard let record = record(withID: recordID) else { return }
        let fileName = "\(recordID.uuidString.lowercased()).wav"
        let destination = audioDirectory.appendingPathComponent(fileName)
        let temporary = audioDirectory.appendingPathComponent(".\(UUID().uuidString).partial")
        try FileManager.default.copyItem(at: sourceURL, to: temporary)
        defer {
            if FileManager.default.fileExists(atPath: temporary.path) {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        record.audioFileName = fileName
        try modelContext.save()
        refreshRecentRecords()
    }

    func synchronizedAudioDescriptor(
        for record: TranscriptionRecord
    ) -> UserDataSyncHistoryAudioV1? {
        guard let relativeAssetPath = record.remoteAudioRelativePath,
              let mediaType = record.remoteAudioMediaType,
              let sha256 = record.remoteAudioSHA256,
              let createdAt = record.remoteAudioCreatedAt else {
            return nil
        }
        let descriptor = UserDataSyncHistoryAudioV1(
            recordID: record.id,
            updatedAt: synchronizedTimestamp(record.audioUpdatedAt, fallback: record.timestamp),
            relativeAssetPath: relativeAssetPath,
            mediaType: mediaType,
            byteCount: record.remoteAudioByteCount,
            sha256: sha256,
            createdAt: createdAt,
            durationSeconds: record.remoteAudioDurationSeconds
        )
        return descriptor.isValid ? descriptor : nil
    }

    private func remoteRecord(for id: UUID, timestamp: Date) -> TranscriptionRecord {
        if let existing = record(withID: id) { return existing }
        let record = TranscriptionRecord(
            id: id,
            timestamp: timestamp,
            rawText: "",
            finalText: "",
            durationSeconds: 0,
            engineUsed: "remote"
        )
        record.source = .other
        record.processingState = .importing
        record.historySyncAudioEligible = false
        modelContext.insert(record)
        return record
    }

    private func synchronizedTimestamp(_ value: Date, fallback: Date) -> Date {
        value.timeIntervalSince1970 > 0 ? value : fallback
    }

    private func refreshRecentRecords() {
        var descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = Self.recentRecordsLimit
        do {
            recentRecords = try modelContext.fetch(descriptor)
        } catch {
            recentRecords = []
        }
        totalRecords = recordCount()
    }

    private func migrateWordsCountIfNeeded() {
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate { $0.wordsCount == 0 && !$0.finalText.isEmpty }
        )
        let candidates: [TranscriptionRecord]
        do {
            candidates = try modelContext.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch history word-count migration candidates: \(error.localizedDescription)")
            return
        }
        var needsSave = false
        for record in candidates {
            record.wordsCount = record.finalText.split(separator: " ").count
            needsSave = true
        }
        if needsSave {
            save()
        }
    }

    private func fetchDescriptor(for query: HistoryQuery) -> FetchDescriptor<TranscriptionRecord> {
        let openInboxState = CaptureInboxState.open.rawValue
        let failedProcessingState = RecordingProcessingState.failed.rawValue

        // Keep the common mailbox-only path inside SQLite. The remaining optional filters
        // are applied during bounded enumeration to avoid one prohibitively large predicate.
        let predicate: Predicate<TranscriptionRecord>?
        switch query.collection {
        case .all:
            predicate = nil
        case .inbox:
            predicate = #Predicate { $0.inboxStateRaw == openInboxState }
        case .withAudio:
            predicate = #Predicate { $0.audioFileName != nil || $0.remoteAudioRelativePath != nil }
        case .failed:
            predicate = #Predicate { $0.processingStateRaw == failedProcessingState }
        }

        let sortBy: [SortDescriptor<TranscriptionRecord>]
        switch query.sortOrder {
        case .newest:
            sortBy = [
                SortDescriptor(\.timestamp, order: .reverse),
                SortDescriptor(\.id, order: .forward),
            ]
        case .oldest:
            sortBy = [
                SortDescriptor(\.timestamp, order: .forward),
                SortDescriptor(\.id, order: .forward),
            ]
        case .duration:
            sortBy = [
                SortDescriptor(\.durationSeconds, order: .reverse),
                SortDescriptor(\.timestamp, order: .reverse),
                SortDescriptor(\.id, order: .forward),
            ]
        case .appName:
            sortBy = [
                SortDescriptor(\.appName, order: .forward),
                SortDescriptor(\.timestamp, order: .reverse),
                SortDescriptor(\.id, order: .forward),
            ]
        }
        return FetchDescriptor(predicate: predicate, sortBy: sortBy)
    }

    private func requiresPostFiltering(_ query: HistoryQuery) -> Bool {
        !query.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || query.originDeviceID != nil
            || query.appBundleIdentifier != nil
            || query.cutoffDate != nil
            || query.source != nil
    }

    private func matchesPostFilters(_ record: TranscriptionRecord, query: HistoryQuery) -> Bool {
        if let appBundleIdentifier = query.appBundleIdentifier,
           record.appBundleIdentifier != appBundleIdentifier {
            return false
        }
        if let cutoffDate = query.cutoffDate, record.timestamp < cutoffDate { return false }
        if let source = query.source, record.source != source { return false }
        if let originDeviceID = query.originDeviceID,
           !matchesDevice(record, deviceID: originDeviceID, includeLegacyMac: query.includeLegacyCurrentMacRecords) {
            return false
        }

        let searchText = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else { return true }
        let lowered = searchText.lowercased()
        return record.rawText.lowercased().contains(lowered)
            || record.finalText.lowercased().contains(lowered)
            || (record.renderedDocument?.lowercased().contains(lowered) ?? false)
            || (record.appName?.lowercased().contains(lowered) ?? false)
            || (record.appDomain?.lowercased().contains(lowered) ?? false)
            || record.source.displayName.lowercased().contains(lowered)
    }

    private func matchesDevice(
        _ record: TranscriptionRecord,
        deviceID: String,
        includeLegacyMac: Bool
    ) -> Bool {
        let storedID = record.originDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if storedID == deviceID { return true }
        guard storedID.isEmpty else { return false }

        let normalizedPlatform = record.originPlatformRaw.lowercased()
        if includeLegacyMac, normalizedPlatform.contains("mac") { return true }
        return deviceID == "platform:\(normalizedPlatform.isEmpty ? "unknown" : normalizedPlatform)"
    }

    private func deleteAudioFile(for record: TranscriptionRecord) {
        guard let fileName = record.audioFileName else { return }
        let fileURL = audioDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Remove null bytes and other control characters that can crash CoreData/SQLite.
    private static func sanitize(_ string: String) -> String {
        string.unicodeScalars.filter { $0 != "\0" }.map(String.init).joined()
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Demo Data (DEBUG only)

    #if DEBUG
    func seedDemoData() {
        // Clear existing data first
        clearAll()

        let calendar = Calendar.current
        let now = Date()

        struct DemoEntry {
            let dayOffset: Int     // days ago
            let hourOffset: Int    // hour of day
            let rawText: String
            let finalText: String
            let appName: String
            let bundleId: String
            let appURL: String?
            let duration: Double
            let language: String
            let engine: String
        }

        let entries: [DemoEntry] = [
            // Today
            DemoEntry(dayOffset: 0, hourOffset: 10, rawText: "Quick note about the meeting tomorrow. Need to prepare slides for the product review.", finalText: "Quick note about the meeting tomorrow. Need to prepare slides for the product review.", appName: "Notes", bundleId: "com.apple.Notes", appURL: nil, duration: 6.2, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 0, hourOffset: 11, rawText: "Fix the authentication bug in the login controller. The session token expires too early and users get logged out.", finalText: "Fix the authentication bug in the login controller. The session token expires too early and users get logged out.", appName: "Visual Studio Code", bundleId: "com.microsoft.VSCode", appURL: nil, duration: 8.5, language: "en", engine: "parakeet"),
            DemoEntry(dayOffset: 0, hourOffset: 14, rawText: "Hey team the new release is ready for testing. Please check the staging environment and report any issues.", finalText: "Hey team, the new release is ready for testing. Please check the staging environment and report any issues.", appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", appURL: nil, duration: 7.8, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 0, hourOffset: 15, rawText: "The API response time improved from 250 milliseconds to 80 milliseconds after adding the Redis cache layer.", finalText: "The API response time improved from 250 milliseconds to 80 milliseconds after adding the Redis cache layer.", appName: "Notes", bundleId: "com.apple.Notes", appURL: nil, duration: 8.1, language: "en", engine: "whisper"),

            // Yesterday
            DemoEntry(dayOffset: 1, hourOffset: 9, rawText: "Dear Sarah thanks for the feedback on the proposal. I've updated the budget section as discussed.", finalText: "Dear Sarah, thanks for the feedback on the proposal. I've updated the budget section as discussed.", appName: "Mail", bundleId: "com.apple.mail", appURL: nil, duration: 7.4, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 1, hourOffset: 10, rawText: "Add error handling for the API timeout scenario. Retry up to three times with exponential backoff.", finalText: "Add error handling for the API timeout scenario. Retry up to three times with exponential backoff.", appName: "Visual Studio Code", bundleId: "com.microsoft.VSCode", appURL: nil, duration: 7.9, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 1, hourOffset: 13, rawText: "Heute Nachmittag Termin mit dem Kunden. Bitte Präsentation vorbereiten und die aktuellen Zahlen einbauen.", finalText: "Heute Nachmittag Termin mit dem Kunden. Bitte Präsentation vorbereiten und die aktuellen Zahlen einbauen.", appName: "Notes", bundleId: "com.apple.Notes", appURL: nil, duration: 7.2, language: "de", engine: "whisper"),
            DemoEntry(dayOffset: 1, hourOffset: 15, rawText: "Review the pull request from Alex. Focus on the database migration and the new API endpoints.", finalText: "Review the pull request from Alex. Focus on the database migration and the new API endpoints.", appName: "Safari", bundleId: "com.apple.Safari", appURL: "https://github.com/pulls", duration: 7.0, language: "en", engine: "parakeet"),
            DemoEntry(dayOffset: 1, hourOffset: 16, rawText: "Schedule the deployment for Friday at six PM. Make sure all tests pass before merging to main.", finalText: "Schedule the deployment for Friday at 6 PM. Make sure all tests pass before merging to main.", appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", appURL: nil, duration: 7.5, language: "en", engine: "whisper"),

            // 2 days ago
            DemoEntry(dayOffset: 2, hourOffset: 9, rawText: "The quarterly report shows a fifteen percent increase in user engagement. Mobile sessions are up by twenty percent.", finalText: "The quarterly report shows a 15% increase in user engagement. Mobile sessions are up by 20%.", appName: "Pages", bundleId: "com.apple.iWork.Pages", appURL: nil, duration: 9.2, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 2, hourOffset: 11, rawText: "Update the README with the new installation instructions and system requirements for Apple Silicon.", finalText: "Update the README with the new installation instructions and system requirements for Apple Silicon.", appName: "Visual Studio Code", bundleId: "com.microsoft.VSCode", appURL: nil, duration: 7.6, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 2, hourOffset: 14, rawText: "Implement the dark mode toggle. Use the system preference as default and allow manual override in settings.", finalText: "Implement the dark mode toggle. Use the system preference as default and allow manual override in settings.", appName: "Xcode", bundleId: "com.apple.dt.Xcode", appURL: nil, duration: 8.3, language: "en", engine: "parakeet"),
            DemoEntry(dayOffset: 2, hourOffset: 16, rawText: "Hey everyone standup notes. Backend team completed the migration. Frontend is working on the redesign.", finalText: "Hey everyone, standup notes. Backend team completed the migration. Frontend is working on the redesign.", appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", appURL: nil, duration: 8.0, language: "en", engine: "whisper"),

            // 3 days ago
            DemoEntry(dayOffset: 3, hourOffset: 10, rawText: "The performance tests show a thirty percent improvement after switching to the new caching strategy.", finalText: "The performance tests show a 30% improvement after switching to the new caching strategy.", appName: "Notes", bundleId: "com.apple.Notes", appURL: nil, duration: 7.1, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 3, hourOffset: 11, rawText: "Write unit tests for the payment processing module. Cover edge cases like currency conversion and rounding.", finalText: "Write unit tests for the payment processing module. Cover edge cases like currency conversion and rounding.", appName: "Visual Studio Code", bundleId: "com.microsoft.VSCode", appURL: nil, duration: 8.4, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 3, hourOffset: 14, rawText: "Lieber Herr Müller anbei finden Sie die aktualisierten Vertragsbedingungen. Bitte prüfen Sie die Änderungen.", finalText: "Lieber Herr Müller, anbei finden Sie die aktualisierten Vertragsbedingungen. Bitte prüfen Sie die Änderungen.", appName: "Mail", bundleId: "com.apple.mail", appURL: nil, duration: 8.8, language: "de", engine: "whisper"),
            DemoEntry(dayOffset: 3, hourOffset: 15, rawText: "Check the latest design mockups on Figma. The new dashboard layout needs feedback by end of day.", finalText: "Check the latest design mockups on Figma. The new dashboard layout needs feedback by end of day.", appName: "Arc", bundleId: "company.thebrowser.Browser", appURL: "https://figma.com/design", duration: 7.3, language: "en", engine: "parakeet"),

            // 4 days ago
            DemoEntry(dayOffset: 4, hourOffset: 9, rawText: "Meeting notes. Decided to postpone the launch by one week. Need more QA time for the payment flow.", finalText: "Meeting notes. Decided to postpone the launch by one week. Need more QA time for the payment flow.", appName: "Notes", bundleId: "com.apple.Notes", appURL: nil, duration: 7.8, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 4, hourOffset: 11, rawText: "Refactor the networking layer to use async await instead of completion handlers. Start with the user service.", finalText: "Refactor the networking layer to use async/await instead of completion handlers. Start with the user service.", appName: "Xcode", bundleId: "com.apple.dt.Xcode", appURL: nil, duration: 8.6, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 4, hourOffset: 13, rawText: "The new onboarding flow increased conversion by eight percent compared to the previous version.", finalText: "The new onboarding flow increased conversion by 8% compared to the previous version.", appName: "Safari", bundleId: "com.apple.Safari", appURL: "https://analytics.google.com", duration: 6.9, language: "en", engine: "parakeet"),
            DemoEntry(dayOffset: 4, hourOffset: 16, rawText: "Bitte den Entwurf für das Logo bis morgen fertigstellen. Die Farben sollten zum Branding passen.", finalText: "Bitte den Entwurf für das Logo bis morgen fertigstellen. Die Farben sollten zum Branding passen.", appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", appURL: nil, duration: 7.1, language: "de", engine: "whisper"),

            // 5 days ago
            DemoEntry(dayOffset: 5, hourOffset: 9, rawText: "Good morning team. Today's priorities are bug fixes for the release candidate and documentation updates.", finalText: "Good morning team. Today's priorities are bug fixes for the release candidate and documentation updates.", appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", appURL: nil, duration: 7.5, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 5, hourOffset: 11, rawText: "Add input validation for the registration form. Email format phone number and password strength.", finalText: "Add input validation for the registration form. Email format, phone number, and password strength.", appName: "Visual Studio Code", bundleId: "com.microsoft.VSCode", appURL: nil, duration: 7.2, language: "en", engine: "parakeet"),
            DemoEntry(dayOffset: 5, hourOffset: 14, rawText: "The user research report is ready. Key finding most users prefer keyboard shortcuts over menu navigation.", finalText: "The user research report is ready. Key finding: most users prefer keyboard shortcuts over menu navigation.", appName: "Notes", bundleId: "com.apple.Notes", appURL: nil, duration: 8.0, language: "en", engine: "whisper"),

            // 6 days ago
            DemoEntry(dayOffset: 6, hourOffset: 10, rawText: "Initialize the project with Swift Package Manager. Add dependencies for networking and JSON parsing.", finalText: "Initialize the project with Swift Package Manager. Add dependencies for networking and JSON parsing.", appName: "Terminal", bundleId: "com.apple.Terminal", appURL: nil, duration: 7.0, language: "en", engine: "parakeet"),
            DemoEntry(dayOffset: 6, hourOffset: 13, rawText: "Create the database schema for the user profiles. Include fields for name email preferences and avatar.", finalText: "Create the database schema for the user profiles. Include fields for name, email, preferences, and avatar.", appName: "Visual Studio Code", bundleId: "com.microsoft.VSCode", appURL: nil, duration: 8.2, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 6, hourOffset: 15, rawText: "Check the server logs for the memory leak. It seems to happen after about two hours of continuous use.", finalText: "Check the server logs for the memory leak. It seems to happen after about two hours of continuous use.", appName: "Terminal", bundleId: "com.apple.Terminal", appURL: nil, duration: 7.8, language: "en", engine: "parakeet"),
        ]

        for entry in entries {
            let dayStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -entry.dayOffset, to: now)!)
            let timestamp = calendar.date(byAdding: .hour, value: entry.hourOffset, to: dayStart)!

            let record = TranscriptionRecord(
                timestamp: timestamp,
                rawText: entry.rawText,
                finalText: entry.finalText,
                appName: entry.appName,
                appBundleIdentifier: entry.bundleId,
                appURL: entry.appURL,
                durationSeconds: entry.duration,
                language: entry.language,
                engineUsed: entry.engine
            )
            modelContext.insert(record)
        }

        save()
        refreshRecentRecords()
    }
    #endif
}
