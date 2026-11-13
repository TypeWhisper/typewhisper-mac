import Combine
import CryptoKit
import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "HistorySearchIndexer")

/// Keeps the search index in line with History.
///
/// Changes from History's feed are applied in the background: deletions at once,
/// new and changed records shortly after the last change. Records are read on a
/// context of their own and never on the main actor.
@MainActor
final class HistorySearchIndexer {
    /// Records read and written in one step, so a deletion never waits long.
    static let batchSize = 50
    private static let contentCheckBatchSize = 200
    /// How often a batch that could not be read or written is tried again.
    /// After that the next check adds its records.
    private static let upsertRetries = 3
    /// How often per launch the index is built again after it was deleted for
    /// damage, so a file that keeps breaking does not keep the Mac busy.
    private static let rebuildsAfterDamage = 3

    private let index: HistorySearchIndex
    private let reader: HistorySearchRecordReader
    private let readRecords: @Sendable ([UUID]) throws -> [HistorySearchRecord]
    private let isEnabled: @MainActor () -> Bool
    private let isBusy: @MainActor () -> Bool
    private let upsertDelay: Duration
    private let busyRetryDelay: Duration

    private var subscription: AnyCancellable?
    /// Changed records that wait for `upsertDelay` to pass without another change.
    private var waitingUpserts = Set<UUID>()
    private var dueUpserts = Set<UUID>()
    private var removals = Set<UUID>()
    private var deletesIndex = false
    /// The index could not be deleted or emptied. The next change to History tries again.
    private var deletionFailed = false
    /// False once no index file was found, so History changes cost nothing
    /// while no index is kept.
    private var indexMayExist = true
    /// A batch that failed, how often it was tried, and when it is tried again.
    /// No other batch starts before it.
    private var retry: (ids: Set<UUID>, attempt: Int, notBefore: ContinuousClock.Instant)?
    private var rebuilds = 0
    /// What was removed while a batch was read or written. A failed batch must
    /// not bring these records back when it is tried again.
    private var removedDuringUpsert = Set<UUID>()
    private var clearedDuringUpsert = false
    /// The worker's wait while the app is busy or before a retry. Deletions end it.
    private var pause: Task<Void, Never>?
    private var isStopped = false
    private var upsertTimer: Task<Void, Never>?
    private var worker: Task<Void, Never>?

    /// - Parameters:
    ///   - isEnabled: Whether records are added. While it returns false, an existing index
    ///     only loses records: those that were deleted and those that changed, so it never
    ///     holds text that History no longer has.
    ///   - isBusy: True while indexing would compete with a dictation or a recording.
    ///   - readRecords: Reads the records to index in place of History's reader, so
    ///     tests can make a read fail or wait.
    init(
        historyService: HistoryService,
        index: HistorySearchIndex = HistorySearchIndex(),
        isEnabled: @escaping @MainActor () -> Bool,
        isBusy: @escaping @MainActor () -> Bool = { false },
        upsertDelay: Duration = .seconds(2),
        busyRetryDelay: Duration = .seconds(2),
        readRecords: (@Sendable ([UUID]) throws -> [HistorySearchRecord])? = nil
    ) {
        self.index = index
        let reader = historyService.searchRecordReader
        self.reader = reader
        self.readRecords = readRecords ?? { try reader.records(withIDs: $0) }
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.upsertDelay = upsertDelay
        self.busyRetryDelay = busyRetryDelay
        subscription = historyService.changes.sink { [weak self] in self?.handle($0) }
        Task { [weak self] in
            await index.setDamageHandler {
                Task { @MainActor in self?.rebuildAfterDamage() }
            }
        }
    }

    /// Checks the whole index once, some time after launch, so it costs the launch nothing.
    func checkAfterLaunch(delay: Duration = .seconds(30)) {
        Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.reconcile(checkingContent: true)
        }
    }

    /// Waits until the queued records are written. Waits longer while a
    /// dictation or recording runs, and returns when the caller is cancelled.
    func waitForQueuedWork() async {
        while worker != nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Ends all index work for good and waits for the running step, so nothing
    /// writes the index while the user's data is deleted.
    func stop() async {
        isStopped = true
        subscription = nil
        upsertTimer?.cancel()
        pause?.cancel()
        await worker?.value
    }

    /// Adds records the index lacks, updates those whose change dates differ and
    /// removes those History no longer has. `checkingContent` also compares the
    /// content of the other records, which reads every record once.
    func reconcile(checkingContent: Bool = false) async {
        retryFailedDeletion()
        guard isEnabled(), !isStopped else { return }
        do {
            // The index first: a record History gets in between is then added, not removed.
            let indexed = try await index.fingerprints()
            let reader = reader
            let versions = try await Task.detached(priority: .utility) { try reader.versions() }.value
            guard isEnabled() else { return }

            removals.formUnion(Set(indexed.keys).subtracting(versions.keys))
            var unchanged: [UUID] = []
            for (id, version) in versions {
                if indexed[id]?.version == version {
                    unchanged.append(id)
                } else {
                    dueUpserts.insert(id)
                }
            }
            startWorker()
            guard checkingContent else { return }

            do {
                try await index.checkIntegrity()
            } catch {
                logger.error("Search index is inconsistent, building it again: \(String(describing: error), privacy: .public)")
                // Changes that arrived during the check stay queued.
                deletesIndex = true
                dueUpserts.formUnion(versions.keys)
                startWorker()
                return
            }
            for start in stride(from: 0, to: unchanged.count, by: Self.contentCheckBatchSize) {
                while isBusy() { try await Task.sleep(for: busyRetryDelay) }
                let ids = Array(unchanged[start..<min(start + Self.contentCheckBatchSize, unchanged.count)])
                let hashes = try await Task.detached(priority: .utility) {
                    try reader.contentHashes(ofRecordsWithIDs: ids)
                }.value
                let changed = hashes.filter { indexed[$0.key]?.contentHash != $0.value }.keys
                guard !changed.isEmpty else { continue }
                dueUpserts.formUnion(changed)
                startWorker()
            }
        } catch {
            logger.error("Failed to check the search index: \(String(describing: error), privacy: .public)")
        }
    }

    private func handle(_ change: HistoryRecordChange) {
        retryFailedDeletion()
        switch change {
        case .upserted(let ids):
            guard isEnabled() else {
                remove(ids)
                return
            }
            waitingUpserts.formUnion(ids)
            upsertTimer?.cancel()
            upsertTimer = Task { [weak self, upsertDelay] in
                try? await Task.sleep(for: upsertDelay)
                guard !Task.isCancelled, let self else { return }
                self.dueUpserts.formUnion(self.waitingUpserts)
                self.waitingUpserts = []
                self.startWorker()
            }
        case .removed(let ids):
            remove(ids)
        case .cleared:
            deleteIndex()
        }
    }

    private func remove(_ ids: Set<UUID>) {
        waitingUpserts.subtract(ids)
        dueUpserts.subtract(ids)
        retry?.ids.subtract(ids)
        removedDuringUpsert.formUnion(ids)
        guard indexMayExist else { return }
        removals.formUnion(ids)
        pause?.cancel()
        startWorker()
    }

    private func retryFailedDeletion() {
        guard deletionFailed else { return }
        deletionFailed = false
        deletesIndex = true
        startWorker()
    }

    private func destroyIndex() async {
        let isGone = await index.destroy()
        indexMayExist = !isGone
        deletionFailed = !isGone
        if !isGone { logger.error("Failed to delete the search index") }
    }

    private func deleteIndex() {
        upsertTimer?.cancel()
        waitingUpserts = []
        dueUpserts = []
        removals = []
        clearedDuringUpsert = true
        retry = nil
        guard indexMayExist else { return }
        deletesIndex = true
        pause?.cancel()
        startWorker()
    }

    // MARK: - Worker

    private enum Job {
        case deleteIndex
        case remove(Set<UUID>)
        case upsert([UUID], attempt: Int)
        case wait(Duration)
    }

    private func startWorker() {
        guard worker == nil, !isStopped else { return }
        worker = Task(priority: .utility) { [weak self] in
            // One job at a time, so a record is never written after its removal.
            while let job = self?.nextJob() {
                await self?.perform(job)
            }
        }
    }

    /// Deletions come first. Returns nil, and frees the worker, when nothing is left.
    private func nextJob() -> Job? {
        guard !isStopped else {
            worker = nil
            return nil
        }
        if deletesIndex {
            deletesIndex = false
            return .deleteIndex
        }
        if !removals.isEmpty {
            defer { removals = [] }
            return .remove(removals)
        }
        if retry?.ids.isEmpty == true { retry = nil }
        guard !dueUpserts.isEmpty || retry != nil else {
            worker = nil
            return nil
        }
        guard isEnabled() else {
            defer {
                dueUpserts = []
                retry = nil
            }
            return .remove(dueUpserts.union(retry?.ids ?? []))
        }
        if isBusy() { return .wait(busyRetryDelay) }
        if let retry, ContinuousClock.now < retry.notBefore { return .wait(retry.notBefore - .now) }
        removedDuringUpsert = []
        clearedDuringUpsert = false
        indexMayExist = true
        if let retry {
            self.retry = nil
            return .upsert(Array(retry.ids), attempt: retry.attempt)
        }
        let batch = Array(dueUpserts.prefix(Self.batchSize))
        dueUpserts.subtract(batch)
        return .upsert(batch, attempt: 0)
    }

    /// Adds every record again after the index lost its file.
    private func rebuildAfterDamage() {
        guard rebuilds < Self.rebuildsAfterDamage else { return }
        rebuilds += 1
        Task(priority: .utility) { [weak self] in await self?.reconcile() }
    }

    private func perform(_ job: Job) async {
        switch job {
        case .deleteIndex:
            await destroyIndex()
        case .remove(let ids):
            do {
                try await index.remove(ids)
                indexMayExist = await index.exists
            } catch {
                // A deleted record must not stay searchable, so the index is built again without it.
                // A damaged file was already deleted by the index, which asks for the rebuild itself.
                logger.error("Failed to remove records from the search index: \(String(describing: error), privacy: .public)")
                guard (error as? HistorySearchIndexError)?.isUnusableFile != true else { return }
                await destroyIndex()
                rebuildAfterDamage()
            }
        case .upsert(let ids, let attempt):
            do {
                let readRecords = readRecords
                let records = try await Task.detached(priority: .utility) { try readRecords(ids) }.value
                // Deleted since the change, or no longer ready.
                try await index.remove(Set(ids).subtracting(records.map(\.id)))
                guard !isStopped else { return }
                guard isEnabled() else {
                    // Turned off during the read: the index must not gain these records.
                    removals.formUnion(ids)
                    return
                }
                try await index.upsert(records)
            } catch {
                logger.error("Failed to update the search index: \(String(describing: error), privacy: .public)")
                // The index deleted its damaged file and asks for the rebuild itself.
                if (error as? HistorySearchIndexError)?.isUnusableFile == true { return }
                let remaining = clearedDuringUpsert ? [] : Set(ids).subtracting(removedDuringUpsert)
                guard attempt < Self.upsertRetries, !remaining.isEmpty else { return }
                retry = (remaining, attempt + 1, .now + busyRetryDelay)
            }
        case .wait(let duration):
            // A task of its own, so a deletion can end the wait.
            let pause = Task<Void, Never> { try? await Task.sleep(for: duration) }
            self.pause = pause
            await pause.value
            self.pause = nil
        }
    }
}

/// Reads History records for the search index, on a context of its own.
struct HistorySearchRecordReader: Sendable {
    let container: ModelContainer

    /// The change dates of every record that belongs in the index.
    func versions() throws -> [UUID: String] {
        var descriptor = FetchDescriptor<TranscriptionRecord>()
        descriptor.propertiesToFetch = [
            \TranscriptionRecord.id,
            \TranscriptionRecord.timestamp,
            \TranscriptionRecord.contentUpdatedAt,
            \TranscriptionRecord.speakerTranscriptUpdatedAt,
            \TranscriptionRecord.speakerNamesUpdatedAt,
            \TranscriptionRecord.activeTranscriptionVersionID,
            \TranscriptionRecord.processingStateRaw,
            \TranscriptionRecord.speakerTranscriptStateRaw,
        ]
        var versions: [UUID: String] = [:]
        try ModelContext(container).enumerate(descriptor, batchSize: 500) { record in
            guard record.processingState == .ready else { return }
            versions[record.id] = HistorySearchRecord.version(of: record)
        }
        return versions
    }

    /// The records as the index stores them. Records that are gone or not ready are left out.
    func records(withIDs ids: [UUID]) throws -> [HistorySearchRecord] {
        try fetch(ids).compactMap { HistorySearchRecord($0) }
    }

    func contentHashes(ofRecordsWithIDs ids: [UUID]) throws -> [UUID: String] {
        Dictionary(
            try fetch(ids).map { ($0.id, HistorySearchRecord.contentHash(of: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The records among `ids` that History still has.
    func existingIDs(among ids: Set<UUID>) throws -> Set<UUID> {
        let ids = Array(ids)
        var descriptor = FetchDescriptor<TranscriptionRecord>(predicate: #Predicate { ids.contains($0.id) })
        descriptor.propertiesToFetch = [\TranscriptionRecord.id]
        return Set(try ModelContext(container).fetch(descriptor).map(\.id))
    }

    private func fetch(_ ids: [UUID]) throws -> [TranscriptionRecord] {
        try ModelContext(container).fetch(
            FetchDescriptor<TranscriptionRecord>(predicate: #Predicate { ids.contains($0.id) })
        )
    }
}

extension HistorySearchRecord {
    /// The share of the spoken words a visible text must keep to count as the same
    /// text after corrections, and not as a document written from it.
    private static let sameTextWordShare = 0.7

    /// The record as the index stores it. Nil while it is transcribed and after that failed.
    init?(_ record: TranscriptionRecord) {
        guard record.processingState == .ready else { return nil }
        let bundleID = record.appBundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        let name = record.appName.flatMap { $0.isEmpty ? nil : $0 }
        let documentTitle = record.synchronizedStructuredDocument?.title.flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            id: record.id,
            recordedAt: record.timestamp,
            source: record.sourceRaw,
            originDeviceID: record.originDeviceID,
            language: record.language,
            durationSeconds: record.durationSeconds,
            // Recordings keep their name where dictations keep the app they were made in.
            title: documentTitle ?? (bundleID == nil ? name : nil),
            appName: bundleID == nil ? nil : name,
            bundleID: bundleID,
            domain: record.appDomain,
            versionID: record.activeTranscriptionVersionID,
            fingerprint: HistorySearchFingerprint(
                version: Self.version(of: record),
                contentHash: Self.contentHash(of: record)
            ),
            passages: Self.passages(of: record)
        )
    }

    /// Reads only the properties `HistorySearchRecordReader.versions()` fetches.
    static func version(of record: TranscriptionRecord) -> String {
        let dates = [
            record.timestamp, record.contentUpdatedAt,
            record.speakerTranscriptUpdatedAt, record.speakerNamesUpdatedAt,
        ]
        return (dates.map { String($0.timeIntervalSince1970) } + [
            record.activeTranscriptionVersionID?.uuidString ?? "",
            record.speakerTranscriptStateRaw ?? "",
            String(HistoryPassageChunker.version),
        ]).joined(separator: "|")
    }

    static func contentHash(of record: TranscriptionRecord) -> String {
        var hasher = SHA256()
        func add(_ data: Data?) {
            // The length keeps neighbouring fields apart.
            withUnsafeBytes(of: UInt64(data?.count ?? 0)) { hasher.update(bufferPointer: $0) }
            if let data { hasher.update(data: data) }
        }
        let texts: [String?] = [
            record.rawText, record.finalText, record.renderedDocument, record.appName,
            record.appBundleIdentifier, record.appURL, record.sourceRaw, record.originDeviceID,
            record.language, record.speakerTranscriptStateRaw,
            String(record.durationSeconds), String(record.timestamp.timeIntervalSince1970),
        ]
        for text in texts { add(text.map { Data($0.utf8) }) }
        for data in [
            record.structuredDocumentData, record.timedTextData,
            record.speakerTranscriptData, record.speakerNamesData,
        ] {
            add(data)
        }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func passages(of record: TranscriptionRecord) -> [HistoryPassage] {
        let spoken = record.rawText
        let visible = record.displayText
        let visibleIsSpokenText = isSameText(spoken: spoken, visible: visible)

        var passages: [HistoryPassage] = []
        if record.speakerTranscriptState == .ready, let transcript = record.speakerTranscript {
            passages = HistoryPassageChunker.passages(
                ofSpeakerSegments: speakerSegments(of: transcript, namesData: record.speakerNamesData)
            )
        }
        guard passages.isEmpty else {
            // The speaker transcript holds the spoken words, so a visible text with
            // any other wording is indexed too: a correction as much as written notes.
            let whitespace = CharacterSet.whitespacesAndNewlines
            if visible.trimmingCharacters(in: whitespace) != spoken.trimmingCharacters(in: whitespace) {
                passages += HistoryPassageChunker.passages(of: visible, kind: .result)
            }
            return passages
        }
        let text = visibleIsSpokenText ? visible : spoken
        passages = HistoryPassageChunker.passages(of: text, timing: timing(record.timedText, in: text))
        if !visibleIsSpokenText {
            // An email, a translation or notes written from the recording.
            passages += HistoryPassageChunker.passages(of: visible, kind: .result)
        }
        return passages
    }

    private static func isSameText(spoken: String, visible: String) -> Bool {
        guard spoken != visible else { return true }
        func words(of text: String) -> [Substring] {
            text.lowercased().split { !$0.isLetter && !$0.isNumber }
        }
        let visibleWords = Set(words(of: visible))
        let spokenWords = words(of: spoken)
        let kept = spokenWords.filter(visibleWords.contains).count
        return Double(kept) >= sameTextWordShare * Double(spokenWords.count)
    }

    /// Word and segment times that still point at their words. The times belong
    /// to the engine's text, and a corrected text can have other words there.
    private static func timing(_ entries: [TimedTextEntry], in text: String) -> [HistoryPassageTiming] {
        guard !entries.isEmpty else { return [] }
        let source = text as NSString
        return entries.compactMap { entry in
            let range = entry.range
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= source.length,
                  source.substring(with: range) == entry.text else { return nil }
            return HistoryPassageTiming(
                utf16Range: range.location..<NSMaxRange(range), start: entry.start, end: entry.end
            )
        }
    }

    private static func speakerSegments(
        of transcript: SpeakerTranscript,
        namesData: Data?
    ) -> [HistoryPassageSpeakerSegment] {
        // Decoded here and not through `record.speakerNames`, which decodes the transcript again.
        let names = namesData
            .flatMap { try? JSONDecoder().decode(SpeakerNameTable.self, from: $0) }
            .flatMap { $0.applies(to: transcript) ? $0 : nil }
        var currentSpeakerID = SpeakerTranscript.speakerID(number: 1)
        return transcript.segments.map { segment in
            // A segment without a speaker belongs to the turn around it, as in the transcript view.
            currentSpeakerID = segment.speakerID ?? currentSpeakerID
            return HistoryPassageSpeakerSegment(
                speaker: SpeakerTranscriptPresentation.name(for: currentSpeakerID, names: names),
                text: segment.text,
                start: segment.start,
                end: segment.end
            )
        }
    }
}
