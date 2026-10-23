import CryptoKit
import XCTest
@testable import TypeWhisper

@MainActor
// @unchecked Sendable is safe here because @MainActor serializes all access in tests,
// so there are no concurrent cross-thread mutations. Revisit this if the store
// gains nonisolated mutable state or loses MainActor isolation.
private final class InMemoryUserDataSyncStore: UserDataSyncStore, @unchecked Sendable {
    var dictionaryEntries: [UserDataSyncDictionaryEntry]
    var snippets: [UserDataSyncSnippet]
    var historyRecords: [UserDataSyncHistoryRecord]
    var deletedHistoryRecords: [UserDataSyncHistoryDeletion]
    var appliedMutations: [UserDataSyncMutation] = []
    private(set) var snapshotCount = 0
    private var observers: [UUID: @MainActor @Sendable () -> Void] = [:]

    init(
        dictionaryEntries: [UserDataSyncDictionaryEntry] = [],
        snippets: [UserDataSyncSnippet] = [],
        historyRecords: [UserDataSyncHistoryRecord] = [],
        deletedHistoryRecords: [UserDataSyncHistoryDeletion] = []
    ) {
        self.dictionaryEntries = dictionaryEntries
        self.snippets = snippets
        self.historyRecords = historyRecords
        self.deletedHistoryRecords = deletedHistoryRecords
    }

    func snapshot() -> UserDataSyncSnapshot {
        snapshotCount += 1
        return UserDataSyncSnapshot(
            dictionaryEntries: dictionaryEntries,
            snippets: snippets,
            historyRecords: historyRecords,
            deletedHistoryRecords: deletedHistoryRecords
        )
    }

    func apply(_ mutations: [UserDataSyncMutation]) throws {
        appliedMutations.append(contentsOf: mutations)

        for mutation in mutations {
            switch mutation {
            case .restoreLegacyDictionaryRegex(let entry):
                if let index = dictionaryEntries.firstIndex(where: { $0.isLegacyLiteralCopy(of: entry) }) {
                    dictionaryEntries[index] = dictionaryEntries[index].preservingRegexMode(true)
                }
            case .upsertDictionary(let entry):
                let itemID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original, isRegex: entry.isRegex)
                let existing = dictionaryEntries.first {
                    UserDataSyncIdentity.dictionaryItemID(
                        entryType: $0.entryType,
                        original: $0.original, isRegex: $0.isRegex
                    ) == itemID
                }
                dictionaryEntries.removeAll {
                    UserDataSyncIdentity.dictionaryItemID(entryType: $0.entryType, original: $0.original, isRegex: $0.isRegex) == itemID
                }
                dictionaryEntries.append(UserDataSyncDictionaryEntry(
                    entryType: entry.entryType, original: entry.original, replacement: entry.replacement,
                    caseSensitive: entry.caseSensitive, isEnabled: entry.isEnabled,
                    isRegex: entry.isRegexFieldPresent ? entry.isRegex : (existing?.isRegex ?? false),
                    source: entry.source,
                    ctcMinSimilarity: entry.ctcMinSimilarityFieldPresent ? entry.ctcMinSimilarity : existing?.ctcMinSimilarity,
                    createdAt: entry.createdAt, updatedAt: entry.updatedAt
                ))
            case .deleteDictionary(let itemID):
                dictionaryEntries.removeAll {
                    UserDataSyncIdentity.dictionaryItemID(entryType: $0.entryType, original: $0.original, isRegex: $0.isRegex) == itemID
                }
            case .upsertSnippet(let snippet):
                let itemID = UserDataSyncIdentity.snippetItemID(trigger: snippet.trigger)
                snippets.removeAll {
                    UserDataSyncIdentity.snippetItemID(trigger: $0.trigger) == itemID
                }
                snippets.append(snippet)
            case .deleteSnippet(let itemID):
                snippets.removeAll {
                    UserDataSyncIdentity.snippetItemID(trigger: $0.trigger) == itemID
                }
            case .upsertHistoryContent(let content):
                upsertHistory(content: content)
            case .upsertHistoryInbox(let inbox):
                upsertHistory(inbox: inbox)
            case .upsertHistoryAudio(let audio):
                upsertHistory(audio: audio)
            case .upsertHistoryTranscript(let transcript):
                upsertHistory(recordID: transcript.recordID, updatedAt: transcript.updatedAt, transcript: transcript)
            case .upsertHistorySpeakers(let speakers):
                upsertHistory(recordID: speakers.recordID, updatedAt: speakers.updatedAt, speakers: speakers)
            case .deleteHistory(let recordID):
                historyRecords.removeAll { $0.content.recordID == recordID }
            }
        }
    }

    private func upsertHistory(content: UserDataSyncHistoryContentV1) {
        let existing = historyRecords.first { $0.content.recordID == content.recordID }
        replaceHistory(
            UserDataSyncHistoryRecord(
                content: content,
                inbox: existing?.inbox ?? Self.placeholderInbox(
                    recordID: content.recordID,
                    updatedAt: content.createdAt
                ),
                audio: existing?.audio,
                transcript: existing?.transcript,
                speakers: existing?.speakers,
                localAudioFileURL: existing?.localAudioFileURL,
                audioEligible: existing?.audioEligible ?? false
            )
        )
    }

    private func upsertHistory(inbox: UserDataSyncHistoryInboxV1) {
        let existing = historyRecords.first { $0.content.recordID == inbox.recordID }
        replaceHistory(
            UserDataSyncHistoryRecord(
                content: existing?.content ?? Self.placeholderContent(
                    recordID: inbox.recordID,
                    updatedAt: inbox.updatedAt
                ),
                inbox: inbox,
                audio: existing?.audio,
                transcript: existing?.transcript,
                speakers: existing?.speakers,
                localAudioFileURL: existing?.localAudioFileURL,
                audioEligible: existing?.audioEligible ?? false
            )
        )
    }

    private func upsertHistory(audio: UserDataSyncHistoryAudioV1) {
        let existing = historyRecords.first { $0.content.recordID == audio.recordID }
        replaceHistory(
            UserDataSyncHistoryRecord(
                content: existing?.content ?? Self.placeholderContent(
                    recordID: audio.recordID,
                    updatedAt: audio.createdAt
                ),
                inbox: existing?.inbox ?? Self.placeholderInbox(
                    recordID: audio.recordID,
                    updatedAt: audio.createdAt
                ),
                audio: audio,
                transcript: existing?.transcript,
                speakers: existing?.speakers,
                localAudioFileURL: existing?.localAudioFileURL,
                audioEligible: false
            )
        )
    }

    private func upsertHistory(
        recordID: UUID,
        updatedAt: Date,
        transcript: UserDataSyncHistoryTranscriptV1? = nil,
        speakers: UserDataSyncHistorySpeakersV1? = nil
    ) {
        let existing = historyRecords.first { $0.content.recordID == recordID }
        replaceHistory(
            UserDataSyncHistoryRecord(
                content: existing?.content ?? Self.placeholderContent(recordID: recordID, updatedAt: updatedAt),
                inbox: existing?.inbox ?? Self.placeholderInbox(recordID: recordID, updatedAt: updatedAt),
                audio: existing?.audio,
                transcript: transcript ?? existing?.transcript,
                speakers: speakers ?? existing?.speakers,
                localAudioFileURL: existing?.localAudioFileURL,
                audioEligible: existing?.audioEligible ?? false
            )
        )
    }

    private func replaceHistory(_ record: UserDataSyncHistoryRecord) {
        historyRecords.removeAll { $0.content.recordID == record.content.recordID }
        historyRecords.append(record)
    }

    private static func placeholderContent(
        recordID: UUID,
        updatedAt: Date
    ) -> UserDataSyncHistoryContentV1 {
        UserDataSyncHistoryContentV1(
            recordID: recordID,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            originDeviceID: "remote",
            originPlatform: "unknown",
            source: "other",
            processingState: "importing",
            rawTranscript: "",
            finalText: "",
            durationSeconds: 0,
            engineDisplayName: "remote"
        )
    }

    private static func placeholderInbox(
        recordID: UUID,
        updatedAt: Date
    ) -> UserDataSyncHistoryInboxV1 {
        UserDataSyncHistoryInboxV1(
            recordID: recordID,
            updatedAt: updatedAt,
            state: "none",
            kind: nil,
            completionPolicy: .explicit,
            completedAt: nil,
            safeAction: nil
        )
    }

    @discardableResult
    func observeLocalChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeLocalChangeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func notifyLocalChange() {
        for observer in Array(observers.values) {
            observer()
        }
    }
}

private final class RecordingPremiumICloudBridge: PremiumICloudBridging, @unchecked Sendable {
    let isAvailable = true
    let localFolderURL: URL?

    private let lock = NSLock()
    private var storedSynchronizeCount = 0
    private var storedDeleteCount = 0
    private var storedRemovedDeviceIDs: [String] = []

    var synchronizeCount: Int { lock.withLock { storedSynchronizeCount } }
    var deleteCount: Int { lock.withLock { storedDeleteCount } }
    var removedDeviceIDs: [String] { lock.withLock { storedRemovedDeviceIDs } }

    init(localFolderURL: URL) {
        self.localFolderURL = localFolderURL
    }

    func synchronize() async throws {
        lock.withLock { storedSynchronizeCount += 1 }
    }

    func deleteRemotePackage() async throws {
        lock.withLock { storedDeleteCount += 1 }
    }

    func removeDevice(_ deviceID: String) async throws {
        lock.withLock { storedRemovedDeviceIDs.append(deviceID) }
        if let removalGate {
            await removalGate.wait()
        }
    }

    /// Holds removals until opened, to request a sync while one is running.
    var removalGate: RemovalGate?
}

private actor RemovalGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

final class CloudFolderSyncTests: XCTestCase {
    @MainActor
    func testAutomaticSyncStateSurvivesModeToggle() async throws {
        let suiteName = "PremiumSyncModeState-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expectedState = CloudFolderSyncState(
            deviceId: "mac-existing",
            knownLocalItemIDs: ["dictionary:term:typewhisper"],
            exportedItemVersions: ["dictionary:term:typewhisper": "v1"],
            appliedOperationIDs: ["remote-operation"],
            lastSyncAt: Self.date(20)
        )
        defaults.set(
            try Self.stateEncoder.encode(expectedState),
            forKey: "premiumSync.iCloudState"
        )
        defaults.set(PremiumSyncMode.off.rawValue, forKey: "premiumSync.mode")

        let store = InMemoryUserDataSyncStore()
        let controller = CloudFolderSyncController(
            syncStore: store,
            defaults: defaults
        )
        defer { controller.deactivate() }

        await controller.setMode(.automaticICloud)

        let persistedData = try XCTUnwrap(defaults.data(forKey: "premiumSync.iCloudState"))
        XCTAssertEqual(try Self.stateDecoder.decode(CloudFolderSyncState.self, from: persistedData), expectedState)
    }

    @MainActor
    func testAutomaticSyncMirrorsThroughBridgeBeforeAndAfterEngine() async throws {
        let suiteName = "PremiumSyncBridge-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "PremiumSyncBridge")
        defer { TestSupport.remove(folder) }

        defaults.set(PremiumSyncMode.off.rawValue, forKey: "premiumSync.mode")

        let store = InMemoryUserDataSyncStore(dictionaryEntries: [
            UserDataSyncDictionaryEntry(
                entryType: .term,
                original: "bridge-test",
                replacement: "Bridge Test",
                caseSensitive: false,
                isEnabled: true,
                source: .manual,
                ctcMinSimilarity: nil,
                createdAt: Self.date(10),
                updatedAt: Self.date(10)
            ),
        ])
        let bridge = RecordingPremiumICloudBridge(localFolderURL: folder)
        let controller = CloudFolderSyncController(
            syncStore: store,
            defaults: defaults,
            automaticICloudBridge: bridge,
            automaticICloudAvailable: true
        )
        defer { controller.deactivate() }

        await controller.setMode(.automaticICloud)

        XCTAssertEqual(bridge.synchronizeCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: CloudFolderSyncEngine.packageURL(for: folder).path
        ))
        XCTAssertNil(controller.errorMessage)
    }

    func testDeviceRemovalRemovesTheRecordsOfOneInstallationOnly() throws {
        let package = try TestSupport.makeTemporaryDirectory(prefix: "PremiumSyncDeviceRemoval")
        defer { TestSupport.remove(package) }
        try Self.writeDeviceRecord("phone-new", origin: "phone-origin", in: package)
        try Self.writeDeviceRecord("phone-old", origin: " phone-origin ", in: package)
        try Self.writeDeviceRecord("ipad", origin: "ipad-origin", in: package)
        try Self.writeDeviceRecord("mac", origin: nil, in: package)

        try PremiumSyncDeviceRemoval.removeRecords(of: "phone-new", inPackages: [package])
        XCTAssertEqual(try Self.deviceRecordNames(in: package), ["ipad.json", "mac.json"])

        try PremiumSyncDeviceRemoval.removeRecords(of: "mac", inPackages: [package])
        XCTAssertEqual(try Self.deviceRecordNames(in: package), ["ipad.json"])

        XCTAssertThrowsError(try PremiumSyncDeviceRemoval.removeRecords(of: "../ipad", inPackages: [package]))
        // An unreadable or missing record fails instead of reporting a removal.
        XCTAssertThrowsError(try PremiumSyncDeviceRemoval.removeRecords(of: "unknown", inPackages: [package])) {
            XCTAssertEqual($0 as? PremiumSyncDeviceRemoval.Failure, .recordUnreadable)
        }
        XCTAssertEqual(try Self.deviceRecordNames(in: package), ["ipad.json"])
    }

    func testDeviceRemovalUsesTheInstallationFromEitherSide() throws {
        let mirror = try TestSupport.makeTemporaryDirectory(prefix: "PremiumSyncDeviceRemovalMirror")
        let cloud = try TestSupport.makeTemporaryDirectory(prefix: "PremiumSyncDeviceRemovalCloud")
        defer {
            TestSupport.remove(mirror)
            TestSupport.remove(cloud)
        }
        // The record is only in the mirror; iCloud has an older record of the same installation.
        try Self.writeDeviceRecord("phone-new", origin: "phone-origin", in: mirror)
        try Self.writeDeviceRecord("phone-old", origin: "phone-origin", in: cloud)
        try Self.writeDeviceRecord("mac", origin: "mac-origin", in: cloud)

        try PremiumSyncDeviceRemoval.removeRecords(of: "phone-new", inPackages: [mirror, cloud])

        XCTAssertEqual(try Self.deviceRecordNames(in: mirror), [])
        XCTAssertEqual(try Self.deviceRecordNames(in: cloud), ["mac.json"])
    }

    private static func writeDeviceRecord(_ deviceID: String, origin: String?, in package: URL) throws {
        let devices = package.appendingPathComponent("devices", isDirectory: true)
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        var record: [String: Any] = ["deviceId": deviceID, "platform": "iOS", "appVersion": "1.2"]
        if let origin { record["historyOriginDeviceID"] = origin }
        try JSONSerialization.data(withJSONObject: record)
            .write(to: devices.appendingPathComponent("\(deviceID).json"))
    }

    private static func deviceRecordNames(in package: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(
            atPath: package.appendingPathComponent("devices", isDirectory: true).path
        ))
    }

    @MainActor
    func testAutomaticSyncRemovesOtherDevicesThroughTheBridge() async throws {
        let suiteName = "PremiumSyncRemoveDevice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "PremiumSyncRemoveDevice")
        defer { TestSupport.remove(folder) }

        defaults.set(PremiumSyncMode.off.rawValue, forKey: "premiumSync.mode")
        let bridge = RecordingPremiumICloudBridge(localFolderURL: folder)
        let controller = CloudFolderSyncController(
            syncStore: InMemoryUserDataSyncStore(),
            defaults: defaults,
            automaticICloudBridge: bridge,
            automaticICloudAvailable: true
        )
        defer { controller.deactivate() }
        await controller.setMode(.automaticICloud)

        let phone = CloudFolderSyncDeviceRecord(
            deviceId: "phone",
            historyOriginDeviceID: "phone-origin",
            platform: "iOS",
            appVersion: "1.2",
            updatedAt: Self.date(20),
            name: "iPhone"
        )
        let devicesURL = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("devices", isDirectory: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(phone).write(to: devicesURL.appendingPathComponent("phone.json"))
        await controller.syncNow()

        let mac = try XCTUnwrap(controller.devices.first { $0.platform == "macOS" })
        XCTAssertTrue(controller.isCurrentDevice(mac))
        XCTAssertFalse(controller.isCurrentDevice(phone))

        await controller.removeDevice(mac)
        XCTAssertEqual(bridge.removedDeviceIDs, [])

        await controller.removeDevice(phone)
        XCTAssertEqual(bridge.removedDeviceIDs, ["phone"])
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.isSyncing)

        // A sync requested while a removal runs is not lost.
        let gate = RemovalGate()
        bridge.removalGate = gate
        let synchronizationsBefore = bridge.synchronizeCount
        let removal = Task { await controller.removeDevice(phone) }
        while bridge.removedDeviceIDs.count < 2 { await Task.yield() }
        await controller.syncNow()
        XCTAssertEqual(bridge.synchronizeCount, synchronizationsBefore)
        await gate.open()
        await removal.value
        for _ in 0..<200 where bridge.synchronizeCount == synchronizationsBefore {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(bridge.synchronizeCount, synchronizationsBefore)
    }

    @MainActor
    func testLaunchSyncsOnceAndIdlePollsOnlySyncAfterChanges() async throws {
        let suiteName = "PremiumSyncIdlePoll-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "PremiumSyncIdlePoll")
        defer { TestSupport.remove(folder) }

        defaults.set(PremiumSyncMode.automaticICloud.rawValue, forKey: "premiumSync.mode")
        let store = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "Launch", updatedAt: Self.date(10)),
        ])
        let bridge = RecordingPremiumICloudBridge(localFolderURL: folder)
        let controller = CloudFolderSyncController(
            syncStore: store,
            defaults: defaults,
            automaticICloudBridge: bridge,
            automaticICloudAvailable: true
        )
        defer { controller.deactivate() }

        // The controller's launch sync, then the app delegate's launch and activation hooks.
        let initialSync = try XCTUnwrap(controller.initialSyncTask)
        await initialSync.value
        await controller.syncIfNeeded()
        await controller.handleApplicationDidBecomeActive()

        XCTAssertEqual(store.snapshotCount, 1)
        XCTAssertEqual(bridge.synchronizeCount, 4)
        XCTAssertNil(controller.errorMessage)

        // Idle polls only mirror and list the package.
        await controller.automaticPollTick()
        await controller.automaticPollTick()
        XCTAssertEqual(bridge.synchronizeCount, 6)
        XCTAssertEqual(store.snapshotCount, 1)

        // Another Mac's operation reaches the package and the next poll imports it.
        let remoteStore = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "Remote", updatedAt: Self.date(20)),
        ])
        var remoteState = CloudFolderSyncState(deviceId: "mac-remote")
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: remoteStore,
            state: &remoteState,
            now: Self.date(200)
        )
        await controller.automaticPollTick()
        XCTAssertEqual(store.dictionaryEntries.map(\.original).sorted(), ["Launch", "Remote"])
        XCTAssertEqual(store.snapshotCount, 3)

        // The unchanged package is not synced again.
        await controller.automaticPollTick()
        XCTAssertEqual(store.snapshotCount, 3)

        // A local edit is synced by the next check even though the package is unchanged.
        store.notifyLocalChange()
        await controller.syncIfNeeded()
        XCTAssertEqual(store.snapshotCount, 4)
    }

    @MainActor
    func testIdlePollRetriesPackageAfterTransientReadFailure() async throws {
        let suiteName = "PremiumSyncTransientRead-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "PremiumSyncTransientRead")
        defer { TestSupport.remove(folder) }
        let store = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "Launch", updatedAt: Self.date(10)),
        ])
        let controller = try Self.makeAutomaticSyncController(
            suiteName: suiteName,
            defaults: defaults,
            folder: folder,
            store: store
        )
        defer { controller.deactivate() }
        try await XCTUnwrap(controller.initialSyncTask).value

        let remoteStore = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "Remote", updatedAt: Self.date(20)),
        ])
        var remoteState = CloudFolderSyncState(deviceId: "mac-remote")
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: remoteStore,
            state: &remoteState,
            now: Self.date(200)
        )
        let remoteFiles = try FileManager.default.contentsOfDirectory(
            at: CloudFolderSyncEngine.packageURL(for: folder)
                .appendingPathComponent("ops/mac-remote", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(remoteFiles.isEmpty)
        func setPermissions(_ permissions: Int) throws {
            for file in remoteFiles {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: permissions)],
                    ofItemAtPath: file.path
                )
            }
        }
        defer { try? setPermissions(0o600) }

        // The remote operation is not readable yet, so the poll cannot import it.
        try setPermissions(0)
        await controller.automaticPollTick()
        XCTAssertEqual(store.dictionaryEntries.map(\.original), ["Launch"])

        // Restoring access keeps size and modification date, so only a retry imports it.
        try setPermissions(0o600)
        await controller.automaticPollTick()
        XCTAssertEqual(store.dictionaryEntries.map(\.original).sorted(), ["Launch", "Remote"])
    }

    @MainActor
    func testIdlePollRunsRequestedLegacyDictionaryRepublish() async throws {
        let suiteName = "PremiumSyncLegacyRepublish-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "PremiumSyncLegacyRepublish")
        defer { TestSupport.remove(folder) }
        let itemID = UserDataSyncIdentity.dictionaryItemID(
            entryType: UserDataSyncDictionaryEntryType.term,
            original: "TypeWhisper"
        )
        try Self.writeLegacyOperation(
            CloudFolderSyncOperation.upsertDictionary(
                Self.dictionaryEntry(
                    original: "TypeWhisper",
                    updatedAt: Self.date(20),
                    ctcMinSimilarityFieldPresent: false
                ),
                itemID: itemID,
                deviceId: "legacy-ios",
                operationId: "legacy"
            ),
            to: folder
        )
        let store = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(10),
                ctcMinSimilarity: 0.8
            ),
        ])
        let controller = try Self.makeAutomaticSyncController(
            suiteName: suiteName,
            defaults: defaults,
            folder: folder,
            store: store
        )
        defer { controller.deactivate() }
        func exportedVersion() throws -> String? {
            let data = try XCTUnwrap(defaults.data(forKey: "premiumSync.iCloudState"))
            return try Self.stateDecoder.decode(CloudFolderSyncState.self, from: data)
                .exportedItemVersions[itemID]
        }

        // The launch sync applies the legacy operation and asks for a republish.
        try await XCTUnwrap(controller.initialSyncTask).value
        XCTAssertEqual(store.dictionaryEntries.first?.ctcMinSimilarity, 0.8)
        XCTAssertNil(try exportedVersion())

        // The package is unchanged, but the next poll still publishes the explicit field.
        await controller.automaticPollTick()
        XCTAssertNotNil(try exportedVersion())
    }

    @MainActor
    func testIdlePollRefreshesRewrittenDeviceRecords() async throws {
        let suiteName = "PremiumSyncDeviceRefresh-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "PremiumSyncDeviceRefresh")
        defer { TestSupport.remove(folder) }
        let store = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "Launch", updatedAt: Self.date(10)),
        ])
        let controller = try Self.makeAutomaticSyncController(
            suiteName: suiteName,
            defaults: defaults,
            folder: folder,
            store: store
        )
        defer { controller.deactivate() }
        try await XCTUnwrap(controller.initialSyncTask).value

        var remoteState = CloudFolderSyncState(deviceId: "mac-remote")
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: InMemoryUserDataSyncStore(),
            state: &remoteState,
            now: Self.date(200)
        )
        await controller.automaticPollTick()
        XCTAssertTrue(controller.devices.contains { $0.deviceId == "mac-remote" })
        let snapshotCount = store.snapshotCount

        // The other Mac rewrites its device file in place without publishing an operation.
        try Self.entitlementEncoder.encode(CloudFolderSyncDeviceRecord(
            deviceId: "mac-remote",
            platform: "macOS",
            appVersion: "1.7.0",
            updatedAt: Self.date(300),
            name: "Renamed Mac"
        )).write(to: CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("devices/mac-remote.json"))
        await controller.automaticPollTick()

        XCTAssertEqual(store.snapshotCount, snapshotCount)
        XCTAssertEqual(
            controller.devices.first { $0.deviceId == "mac-remote" }?.name,
            "Renamed Mac"
        )
    }

    @MainActor
    func testNoICloudBuildHidesAutomaticModeWithoutOverwritingStoredChoice() async throws {
        let suiteName = "PremiumSyncNoICloud-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(PremiumSyncMode.automaticICloud.rawValue, forKey: "premiumSync.mode")

        let controller = CloudFolderSyncController(
            syncStore: InMemoryUserDataSyncStore(),
            defaults: defaults,
            automaticICloudAvailable: false
        )
        defer { controller.deactivate() }

        XCTAssertEqual(controller.availableModes, [.off, .cloudFolder])
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(defaults.string(forKey: "premiumSync.mode"), PremiumSyncMode.automaticICloud.rawValue)

        await controller.setMode(.automaticICloud)

        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(defaults.string(forKey: "premiumSync.mode"), PremiumSyncMode.automaticICloud.rawValue)
    }

    @MainActor
    func testDeletingPrivateFolderStopsSyncBeforeRemovingPackage() async throws {
        let suiteName = "PremiumSyncDelete-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "PremiumSyncDelete")
        defer { TestSupport.remove(folder) }

        let bookmark = try folder.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: "cloudFolderSync.folderBookmark")
        defaults.set(PremiumSyncMode.cloudFolder.rawValue, forKey: "premiumSync.mode")
        let packageURL = CloudFolderSyncEngine.packageURL(for: folder)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let store = InMemoryUserDataSyncStore()
        let controller = CloudFolderSyncController(
            syncStore: store,
            defaults: defaults
        )
        defer { controller.deactivate() }
        controller.errorMessage = "The last sync failed."

        await controller.deletePrivateSyncFolder()
        store.notifyLocalChange()
        await Task.yield()

        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
        // The earlier error no longer applies, so the deletion result is shown and announced.
        XCTAssertNil(controller.errorMessage)
        XCTAssertNotNil(controller.statusMessage)
    }

    func testICloudBridgeMirrorCopiesBothDirectionsAndKeepsNewestContent() throws {
        let localRoot = try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeLocal")
        let remoteRoot = try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeRemote")
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }

        let localPackage = localRoot.appendingPathComponent("dictum-sync", isDirectory: true)
        let remotePackage = remoteRoot.appendingPathComponent("dictum-sync", isDirectory: true)
        let localOnly = localPackage.appendingPathComponent("ops/mac/local.json")
        let remoteOnly = remotePackage.appendingPathComponent("ops/ios/remote.json")
        let localManifest = localPackage.appendingPathComponent("manifest.json")
        let remoteManifest = remotePackage.appendingPathComponent("manifest.json")

        for file in [localOnly, remoteOnly, localManifest, remoteManifest] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try Data("local-operation".utf8).write(to: localOnly)
        try Data("remote-operation".utf8).write(to: remoteOnly)
        try Data("old-local".utf8).write(to: localManifest)
        try Data("new-remote".utf8).write(to: remoteManifest)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.date(10)],
            ofItemAtPath: localManifest.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Self.date(20)],
            ofItemAtPath: remoteManifest.path
        )

        try PremiumICloudBridgeFileMirror.synchronize(
            localRoot: localRoot,
            remoteRoot: remoteRoot
        )

        XCTAssertEqual(try Data(contentsOf: remotePackage.appendingPathComponent("ops/mac/local.json")), Data("local-operation".utf8))
        XCTAssertEqual(try Data(contentsOf: localPackage.appendingPathComponent("ops/ios/remote.json")), Data("remote-operation".utf8))
        XCTAssertEqual(try Data(contentsOf: localManifest), Data("new-remote".utf8))
        XCTAssertEqual(try Data(contentsOf: remoteManifest), Data("new-remote".utf8))

        try Data("newest-local".utf8).write(to: localManifest)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.date(30)],
            ofItemAtPath: localManifest.path
        )
        try PremiumICloudBridgeFileMirror.synchronize(
            localRoot: localRoot,
            remoteRoot: remoteRoot
        )

        XCTAssertEqual(try Data(contentsOf: remoteManifest), Data("newest-local".utf8))
    }

    func testICloudBridgeComparesMetadataBeforeReadingFiles() throws {
        let localRoot = try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeMetadataLocal")
        let remoteRoot = try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeMetadataRemote")
        let localFile = localRoot.appendingPathComponent("dictum-sync/ops/mac/operation.json")
        let remoteFile = remoteRoot.appendingPathComponent("dictum-sync/ops/mac/operation.json")
        defer {
            for file in [localFile, remoteFile] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: file.path
                )
            }
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }

        try FileManager.default.createDirectory(
            at: localFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("operation-v1".utf8).write(to: localFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.date(10)],
            ofItemAtPath: localFile.path
        )
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)
        XCTAssertEqual(try Data(contentsOf: remoteFile), Data("operation-v1".utf8))

        // Unreadable copies prove that an already mirrored pair is not read again.
        for file in [localFile, remoteFile] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0)],
                ofItemAtPath: file.path
            )
        }
        XCTAssertNoThrow(
            try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)
        )
        for file in [localFile, remoteFile] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: file.path
            )
        }

        // Equal sizes with a newer source fall back to comparing and copying the contents.
        try Data("operation-v2".utf8).write(to: localFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.date(20)],
            ofItemAtPath: localFile.path
        )
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)
        XCTAssertEqual(try Data(contentsOf: remoteFile), Data("operation-v2".utf8))
        XCTAssertEqual(try Data(contentsOf: localFile), Data("operation-v2".utf8))
    }

    func testICloudBridgeComparesContentsOfRewrittenMetadata() throws {
        let localRoot = try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeRewrittenLocal")
        let remoteRoot = try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeRewrittenRemote")
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }

        // Manifest and device files are rewritten in place, so equal size and date do not
        // prove equal contents.
        for relativePath in ["dictum-sync/manifest.json", "dictum-sync/devices/mac.json"] {
            let localFile = localRoot.appendingPathComponent(relativePath)
            let remoteFile = remoteRoot.appendingPathComponent(relativePath)
            for (file, contents) in [(localFile, "metadata-a"), (remoteFile, "metadata-b")] {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(contents.utf8).write(to: file)
                try FileManager.default.setAttributes(
                    [.modificationDate: Self.date(10)],
                    ofItemAtPath: file.path
                )
            }
        }

        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)

        for relativePath in ["dictum-sync/manifest.json", "dictum-sync/devices/mac.json"] {
            XCTAssertEqual(
                try Data(contentsOf: localRoot.appendingPathComponent(relativePath)),
                try Data(contentsOf: remoteRoot.appendingPathComponent(relativePath)),
                relativePath
            )
        }
    }

    func testICloudBridgeFirstSyncWithoutBaseOnlyMergesAndRecordsBase() throws {
        let (localRoot, remoteRoot) = try Self.makeBridgeRoots()
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }
        try Self.writeBridgeFile("ops/mac/local.json", in: localRoot, seconds: 10)
        try Self.writeBridgeFile("ops/ios/remote.json", in: remoteRoot, seconds: 10)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: PremiumICloudBridgeFileMirror.mirrorStateURL(localRoot: localRoot).path
        ))

        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)

        for root in [localRoot, remoteRoot] {
            XCTAssertTrue(Self.bridgeFileExists("ops/mac/local.json", in: root))
            XCTAssertTrue(Self.bridgeFileExists("ops/ios/remote.json", in: root))
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: PremiumICloudBridgeFileMirror.mirrorStateURL(localRoot: localRoot).path
        ))
        // The hidden state file stays out of both packages.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: remoteRoot.appendingPathComponent(PremiumICloudBridgeConstants.mirrorStateFileName).path
        ))
        XCTAssertFalse(Self.bridgeFileExists(PremiumICloudBridgeConstants.mirrorStateFileName, in: remoteRoot))
    }

    func testICloudBridgePropagatesRemoteDeletionToLocalMirror() throws {
        let (localRoot, remoteRoot) = try Self.makeBridgeRoots()
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }
        try Self.writeBridgeFile("ops/ios/expired.json", in: remoteRoot, seconds: 10)
        try Self.writeBridgeFile("devices/iphone.json", in: remoteRoot, seconds: 10)
        try Self.writeBridgeFile("manifest.json", in: remoteRoot, seconds: 10)
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)
        XCTAssertTrue(Self.bridgeFileExists("ops/ios/expired.json", in: localRoot))

        for path in ["ops/ios/expired.json", "devices/iphone.json"] {
            try FileManager.default.removeItem(at: Self.bridgeFileURL(path, in: remoteRoot))
        }
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)

        for root in [localRoot, remoteRoot] {
            XCTAssertFalse(Self.bridgeFileExists("ops/ios/expired.json", in: root))
            XCTAssertFalse(Self.bridgeFileExists("devices/iphone.json", in: root))
            XCTAssertTrue(Self.bridgeFileExists("manifest.json", in: root))
        }
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)
        XCTAssertFalse(Self.bridgeFileExists("devices/iphone.json", in: remoteRoot))
    }

    func testICloudBridgePropagatesLocalDeletionToICloud() throws {
        let (localRoot, remoteRoot) = try Self.makeBridgeRoots()
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }
        try Self.writeBridgeFile("devices/iphone.json", in: localRoot, seconds: 10)
        try Self.writeBridgeFile("ops/mac/expired.json", in: localRoot, seconds: 10)
        try Self.writeBridgeFile("manifest.json", in: localRoot, seconds: 10)
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)
        XCTAssertTrue(Self.bridgeFileExists("devices/iphone.json", in: remoteRoot))

        for path in ["devices/iphone.json", "ops/mac/expired.json"] {
            try FileManager.default.removeItem(at: Self.bridgeFileURL(path, in: localRoot))
        }
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)

        for root in [localRoot, remoteRoot] {
            XCTAssertFalse(Self.bridgeFileExists("devices/iphone.json", in: root))
            XCTAssertFalse(Self.bridgeFileExists("ops/mac/expired.json", in: root))
            XCTAssertTrue(Self.bridgeFileExists("manifest.json", in: root))
        }
    }

    func testICloudBridgeRestoresFilesRewrittenAfterTheirDeletionOnTheOtherSide() throws {
        let (localRoot, remoteRoot) = try Self.makeBridgeRoots()
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }
        try Self.writeBridgeFile("manifest.json", in: localRoot, seconds: 10)
        try Self.writeBridgeFile("devices/iphone.json", in: localRoot, seconds: 10)
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)

        // Deleted remotely, rewritten locally.
        try FileManager.default.removeItem(at: Self.bridgeFileURL("manifest.json", in: remoteRoot))
        try Self.writeBridgeFile("manifest.json", in: localRoot, contents: "local-v2", seconds: 20)
        // Deleted locally, rewritten remotely.
        try FileManager.default.removeItem(at: Self.bridgeFileURL("devices/iphone.json", in: localRoot))
        try Self.writeBridgeFile("devices/iphone.json", in: remoteRoot, contents: "remote-v2", seconds: 20)

        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)

        for root in [localRoot, remoteRoot] {
            XCTAssertEqual(
                try Data(contentsOf: Self.bridgeFileURL("manifest.json", in: root)),
                Data("local-v2".utf8)
            )
            XCTAssertEqual(
                try Data(contentsOf: Self.bridgeFileURL("devices/iphone.json", in: root)),
                Data("remote-v2".utf8)
            )
        }
    }

    func testICloudBridgeDeletedRemotePackageRemovesOnlyMirroredLocalFiles() throws {
        let (localRoot, remoteRoot) = try Self.makeBridgeRoots()
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }
        try Self.writeBridgeFile("manifest.json", in: remoteRoot, seconds: 10)
        try Self.writeBridgeFile("ops/ios/operation.json", in: remoteRoot, seconds: 10)
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)
        XCTAssertTrue(Self.bridgeFileExists("ops/ios/operation.json", in: localRoot))

        try FileManager.default.removeItem(
            at: remoteRoot.appendingPathComponent("dictum-sync", isDirectory: true)
        )
        try Self.writeBridgeFile("ops/mac/new.json", in: localRoot, seconds: 20)
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)

        for root in [localRoot, remoteRoot] {
            XCTAssertFalse(Self.bridgeFileExists("manifest.json", in: root))
            XCTAssertFalse(Self.bridgeFileExists("ops/ios/operation.json", in: root))
            XCTAssertTrue(Self.bridgeFileExists("ops/mac/new.json", in: root))
        }
        // The emptied ops/ios directory is not recreated as an empty skeleton in iCloud.
        XCTAssertFalse(Self.bridgeFileExists("ops/ios", in: remoteRoot))
    }

    func testICloudBridgeResetLocalMirrorDoesNotEmptyICloud() throws {
        let (localRoot, remoteRoot) = try Self.makeBridgeRoots()
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }
        try Self.writeBridgeFile("manifest.json", in: remoteRoot, seconds: 10)
        try Self.writeBridgeFile("ops/ios/operation.json", in: remoteRoot, seconds: 10)
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)

        // Erasing all data removes the local package; other devices' data must survive.
        try FileManager.default.removeItem(
            at: localRoot.appendingPathComponent("dictum-sync", isDirectory: true)
        )
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)

        for root in [localRoot, remoteRoot] {
            XCTAssertTrue(Self.bridgeFileExists("manifest.json", in: root))
            XCTAssertTrue(Self.bridgeFileExists("ops/ios/operation.json", in: root))
        }
    }

    func testICloudBridgeCopiesNewFilesOnBothSidesAfterBaseIsRecorded() throws {
        let (localRoot, remoteRoot) = try Self.makeBridgeRoots()
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }
        try Self.writeBridgeFile("manifest.json", in: localRoot, seconds: 10)
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)

        try Self.writeBridgeFile("ops/mac/new.json", in: localRoot, seconds: 20)
        try Self.writeBridgeFile("ops/ios/new.json", in: remoteRoot, seconds: 20)
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)

        for root in [localRoot, remoteRoot] {
            XCTAssertTrue(Self.bridgeFileExists("manifest.json", in: root))
            XCTAssertTrue(Self.bridgeFileExists("ops/mac/new.json", in: root))
            XCTAssertTrue(Self.bridgeFileExists("ops/ios/new.json", in: root))
        }
    }

    func testICloudBridgeDeletesNothingWhenICloudCannotBeListed() throws {
        let (localRoot, remoteRoot) = try Self.makeBridgeRoots()
        let unreadable = Self.bridgeFileURL("devices", in: remoteRoot)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: unreadable.path
            )
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }
        try Self.writeBridgeFile("ops/ios/operation.json", in: remoteRoot, seconds: 10)
        try Self.writeBridgeFile("devices/iphone.json", in: remoteRoot, seconds: 10)
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)

        try FileManager.default.removeItem(at: Self.bridgeFileURL("ops/ios/operation.json", in: remoteRoot))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0)],
            ofItemAtPath: unreadable.path
        )
        XCTAssertThrowsError(
            try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)
        )
        XCTAssertTrue(Self.bridgeFileExists("ops/ios/operation.json", in: localRoot))
    }

    func testICloudBridgeDeletingPackagesClearsMirrorState() throws {
        let (localRoot, remoteRoot) = try Self.makeBridgeRoots()
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }
        try Self.writeBridgeFile("manifest.json", in: localRoot, seconds: 10)
        try PremiumICloudBridgeFileMirror.synchronize(localRoot: localRoot, remoteRoot: remoteRoot)
        let stateURL = PremiumICloudBridgeFileMirror.mirrorStateURL(localRoot: localRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        try PremiumICloudBridgeFileMirror.deletePackages(localRoot: localRoot, remoteRoot: remoteRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testICloudBridgeUsesConfiguredContainerIdentifier() {
        XCTAssertEqual(
            PremiumICloudBridgeConstants.containerIdentifier(
                infoDictionary: [
                    PremiumICloudBridgeConstants.containerIdentifierInfoKey:
                        "iCloud.com.typewhisper.sync.dev"
                ]
            ),
            "iCloud.com.typewhisper.sync.dev"
        )
        XCTAssertEqual(
            PremiumICloudBridgeConstants.containerIdentifier(
                infoDictionary: [
                    PremiumICloudBridgeConstants.containerIdentifierInfoKey:
                        "$(ICLOUD_CONTAINER_ID)"
                ]
            ),
            PremiumICloudBridgeConstants.productionContainerIdentifier
        )
        XCTAssertEqual(
            PremiumICloudBridgeConstants.containerIdentifier(
                infoDictionary: nil
            ),
            PremiumICloudBridgeConstants.productionContainerIdentifier
        )
        XCTAssertEqual(
            PremiumICloudBridgeConstants.serviceBundleIdentifier(
                infoDictionary: [
                    PremiumICloudBridgeConstants
                        .serviceBundleIdentifierInfoKey:
                        "com.typewhisper.mac.dev.icloudbridge"
                ]
            ),
            "com.typewhisper.mac.dev.icloudbridge"
        )
        XCTAssertEqual(
            PremiumICloudBridgeConstants.serviceBundleIdentifier(
                infoDictionary: nil
            ),
            PremiumICloudBridgeConstants.productionServiceBundleIdentifier
        )
    }

    func testICloudBridgeSeparatesNonProductionLocalMirror() {
        XCTAssertNil(
            PremiumICloudBridgeConstants.localMirrorNamespace(
                infoDictionary: [
                    PremiumICloudBridgeConstants.containerIdentifierInfoKey:
                        PremiumICloudBridgeConstants.productionContainerIdentifier,
                ]
            )
        )
        XCTAssertEqual(
            PremiumICloudBridgeConstants.localMirrorNamespace(
                infoDictionary: [
                    PremiumICloudBridgeConstants.containerIdentifierInfoKey:
                        "iCloud.com.typewhisper.sync.dev",
                ]
            ),
            "iCloud.com.typewhisper.sync.dev"
        )
        for invalidIdentifier in [".", "..", "nested/container", "nested\\container"] {
            XCTAssertNil(
                PremiumICloudBridgeConstants.localMirrorNamespace(
                    infoDictionary: [
                        PremiumICloudBridgeConstants.containerIdentifierInfoKey:
                            invalidIdentifier,
                    ]
                )
            )
        }
    }

    func testICloudBridgeDeletionRemovesOnlySyncPackages() throws {
        let localRoot = try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeDeleteLocal")
        let remoteRoot = try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeDeleteRemote")
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }
        let unrelated = remoteRoot.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        for root in [localRoot, remoteRoot] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("dictum-sync", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        try PremiumICloudBridgeFileMirror.deletePackages(
            localRoot: localRoot,
            remoteRoot: remoteRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: localRoot.appendingPathComponent("dictum-sync").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: remoteRoot.appendingPathComponent("dictum-sync").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCrossPlatformGoldenFixturesDecode() throws {
        let upsert: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-v1")
        XCTAssertEqual(upsert.dictionary?.source, .autoLearned)

        let deletion: CloudFolderSyncOperation = try Self.decodeFixture("delete-snippet-v1")
        XCTAssertEqual(deletion.kind, .delete)
        XCTAssertEqual(deletion.deviceId, "fixture-iphone")

        let device: CloudFolderSyncDeviceRecord = try Self.decodeFixture("device-v1")
        XCTAssertEqual(device.platform, "macOS")
        XCTAssertNil(device.historyOriginDeviceID)

        let legacy: CloudFolderSyncOperation = try Self.decodeFixture("upsert-snippet-legacy-v1")
        XCTAssertEqual(legacy.snippet?.tags, [])

        let ctc: CloudFolderSyncOperation = try Self.decodeFixture(
            "upsert-dictionary-ctc-v1"
        )
        XCTAssertEqual(ctc.dictionary?.ctcMinSimilarity, 0.65)
        XCTAssertEqual(
            ctc.dictionary?.ctcMinSimilarityFieldPresent,
            true
        )

        let unknown: CloudFolderSyncOperation = try Self.decodeFixture("unknown-schema")
        XCTAssertEqual(unknown.schemaVersion, 2)
        XCTAssertTrue(CloudFolderSyncEngine.winningOperations(from: [unknown]).isEmpty)
    }

    @MainActor
    func testDeviceMetadataKeepsTransportAndHistoryOriginIDsSeparate() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncDeviceIdentity")
        defer { TestSupport.remove(folder) }
        let store = InMemoryUserDataSyncStore()
        var state = CloudFolderSyncState(deviceId: "mac-transport")

        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            historyOriginDeviceID: "mac-history-origin",
            now: Self.date(20)
        )

        let device = try XCTUnwrap(result.devices.first)
        XCTAssertEqual(device.deviceId, "mac-transport")
        XCTAssertEqual(device.historyOriginDeviceID, "mac-history-origin")
        XCTAssertEqual(device.platform, "macOS")
    }

    func testDeviceCatalogDeduplicatesHistoryIdentityAndSkipsMalformedFiles() throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncDeviceCatalog")
        defer { TestSupport.remove(folder) }
        let devicesURL = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("devices", isDirectory: true)
        try FileManager.default.createDirectory(at: devicesURL, withIntermediateDirectories: true)
        let older = CloudFolderSyncDeviceRecord(
            deviceId: "transport-old",
            historyOriginDeviceID: "history-device",
            platform: "iOS",
            appVersion: "1",
            updatedAt: Self.date(10),
            name: "Old Name"
        )
        let newer = CloudFolderSyncDeviceRecord(
            deviceId: "transport-new",
            historyOriginDeviceID: "history-device",
            platform: "iOS",
            appVersion: "2",
            updatedAt: Self.date(20),
            name: "Marco's iPhone"
        )
        try Self.entitlementEncoder.encode(older).write(
            to: devicesURL.appendingPathComponent("old.json")
        )
        try Self.entitlementEncoder.encode(newer).write(
            to: devicesURL.appendingPathComponent("new.json")
        )
        try Data("not-json".utf8).write(
            to: devicesURL.appendingPathComponent("broken.json")
        )

        let result = try CloudFolderSyncEngine.readDevices(from: devicesURL)

        XCTAssertEqual(result.devices, [newer])
        XCTAssertEqual(result.diagnostics, [
            .init(kind: .malformedDevice, fileName: "broken.json"),
        ])
    }

    @MainActor
    func testDeterministicItemIDsUseNaturalKeys() {
        XCTAssertEqual(
            UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: " TypeWhisper "),
            UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: "typewhisper")
        )
        XCTAssertEqual(
            UserDataSyncIdentity.snippetItemID(trigger: "Résumé"),
            UserDataSyncIdentity.snippetItemID(trigger: "resume")
        )
        XCTAssertNotEqual(
            UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: "same"),
            UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.correction, original: "same")
        )
    }

    @MainActor
    func testProviderDetectionFromFolderPath() {
        XCTAssertEqual(
            CloudFolderSyncProvider.detect(folderURL: URL(fileURLWithPath: "/Users/marco/Library/Mobile Documents/com~apple~CloudDocs")),
            .iCloudDrive
        )
        XCTAssertEqual(
            CloudFolderSyncProvider.detect(folderURL: URL(fileURLWithPath: "/Users/marco/OneDrive - Example")),
            .oneDrive
        )
        XCTAssertEqual(
            CloudFolderSyncProvider.detect(folderURL: URL(fileURLWithPath: "/Users/marco/Dropbox/TypeWhisper")),
            .dropbox
        )
        XCTAssertEqual(
            CloudFolderSyncProvider.detect(folderURL: URL(fileURLWithPath: "/Volumes/Sync")),
            .custom
        )
    }

    @MainActor
    func testSnippetPlaceholderCompatibilityKeepsBothDialects() {
        let currentYear = Calendar.current.component(.year, from: Date()).description
        let snippet = Snippet(
            trigger: ";date",
            replacement: "{{DATE:yyyy}}|{date:yyyy}|{year}|{day}"
        )

        let output = snippet.processedReplacement()
        let parts = output.split(separator: "|").map(String.init)

        XCTAssertEqual(parts[0], currentYear)
        XCTAssertEqual(parts[1], currentYear)
        XCTAssertEqual(parts[2], currentYear)
        XCTAssertFalse(output.contains("{{DATE"))
        XCTAssertFalse(output.contains("{date"))
        XCTAssertFalse(output.contains("{day}"))
    }

    @MainActor
    func testSyncCreatesFilesWithoutAnAccount() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncFree")
        defer { TestSupport.remove(folder) }

        let store = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(10))
        ])
        var state = CloudFolderSyncState(deviceId: "mac-a")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(20)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("manifest.json").path
        ))
    }

    @MainActor
    func testExportCollapsesDuplicateNaturalKeysToNewestRecord() {
        let older = Self.snippet(trigger: ";SIG", replacement: "Old", updatedAt: Self.date(10))
        let newer = Self.snippet(trigger: ";sig", replacement: "New", updatedAt: Self.date(20))

        let records = CloudFolderSyncEngine.records(
            from: UserDataSyncSnapshot(snippets: [older, newer])
        )

        let itemID = UserDataSyncIdentity.snippetItemID(trigger: ";sig")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[itemID]?.snippet?.replacement, "New")
    }

    @MainActor
    func testOperationEncodingPreservesFractionalSeconds() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncFractional")
        defer { TestSupport.remove(folder) }

        let updatedAt = Date(timeIntervalSince1970: 1_700_000_010.456)
        let deviceAStore = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: updatedAt)
        ])
        let deviceBStore = InMemoryUserDataSyncStore()
        var deviceAState = CloudFolderSyncState(deviceId: "mac-a")
        var deviceBState = CloudFolderSyncState(deviceId: "mac-b")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceAStore,
            state: &deviceAState,
            now: Self.date(20)
        )
        let operationFile = try XCTUnwrap(Self.operationFiles(folder: folder, deviceId: "mac-a").first)
        let operationJSON = try String(contentsOf: operationFile, encoding: .utf8)
        XCTAssertTrue(operationJSON.contains(".456"))

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            now: Self.date(30)
        )

        let syncedUpdatedAt = try XCTUnwrap(deviceBStore.dictionaryEntries.first?.updatedAt)
        XCTAssertEqual(syncedUpdatedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    @MainActor
    func testMalformedOperationFileIsSkipped() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncMalformed")
        defer { TestSupport.remove(folder) }

        let remoteDirectory = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("ops/remote-device", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: remoteDirectory.appendingPathComponent("bad.json"))

        let store = InMemoryUserDataSyncStore()
        var state = CloudFolderSyncState(deviceId: "mac-a")

        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(20)
        )

        XCTAssertEqual(result.mutationsApplied, 0)
        XCTAssertEqual(result.diagnostics.map(\.kind), [.malformedOperation])
    }

    @MainActor
    func testHistoryComponentFromANewerClientIsIgnoredWithoutDiagnostic() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncNewComponent")
        defer { TestSupport.remove(folder) }

        let remoteDirectory = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("ops/remote-device", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        let recordID = UUID().uuidString
        let operation = """
        {"schemaVersion":1,"operationId":"op-1","deviceId":"remote-device","collection":"history",
         "itemId":"history:\(recordID)","kind":"upsert","updatedAt":"2026-09-26T14:02:11Z",
         "historyPayloadVersion":1,"historyGeneration":"g1","historyComponent":"summary",
         "historySummary":{"recordID":"\(recordID)","text":"A summary"}}
        """
        try Data(operation.utf8).write(to: remoteDirectory.appendingPathComponent("summary.json"))

        let store = InMemoryUserDataSyncStore()
        var state = CloudFolderSyncState(deviceId: "mac-a")

        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(20)
        )

        XCTAssertEqual(result.mutationsApplied, 0)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    @MainActor
    func testIncompleteSchemaEnvelopeIsDiagnosedAsMalformed() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncFutureSchema")
        defer { TestSupport.remove(folder) }

        let remoteDirectory = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("ops/remote-device", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":2}"#.utf8)
            .write(to: remoteDirectory.appendingPathComponent("future.json"))

        let store = InMemoryUserDataSyncStore()
        var state = CloudFolderSyncState(deviceId: "mac-a")

        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(20)
        )

        XCTAssertEqual(result.diagnostics.map(\.kind), [.malformedOperation])
    }

    func testMissingOperationsDirectoryThrowsInsteadOfReportingEmptySync() throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncMissingOperations")
        defer { TestSupport.remove(folder) }

        XCTAssertThrowsError(
            try CloudFolderSyncEngine.readOperations(
                from: folder.appendingPathComponent("missing", isDirectory: true)
            )
        )
    }

    func testUnreadableDeviceDirectoryProducesDiagnostic() throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncUnreadableDevice")
        defer { TestSupport.remove(folder) }
        let deviceDirectory = folder.appendingPathComponent("remote-device", isDirectory: true)
        try FileManager.default.createDirectory(at: deviceDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0)],
            ofItemAtPath: deviceDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: deviceDirectory.path
            )
        }

        let result = try CloudFolderSyncEngine.readOperations(from: folder)

        XCTAssertEqual(
            result.diagnostics,
            [.init(kind: .unreadableFile, fileName: "remote-device")]
        )
    }

    @MainActor
    func testConcurrentLocalEditRemainsPendingForNextSync() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncConcurrentEdit")
        defer { TestSupport.remove(folder) }

        let original = Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(10))
        let edited = Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(30))
        let store = InMemoryUserDataSyncStore(dictionaryEntries: [original])
        let editDuringFileIO: @Sendable () async -> Void = {
            await MainActor.run {
                store.dictionaryEntries = [edited]
            }
        }
        var state = CloudFolderSyncState(deviceId: "mac-a")

        let firstResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(20),
            afterFileIO: editDuringFileIO
        )
        let secondResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(40)
        )

        XCTAssertEqual(firstResult.operationsWritten, 1)
        XCTAssertEqual(secondResult.operationsWritten, 1)
        XCTAssertEqual(
            state.exportedItemVersions[
                UserDataSyncIdentity.dictionaryItemID(
                    entryType: UserDataSyncDictionaryEntryType.term,
                    original: "TypeWhisper"
                )
            ],
            CloudFolderSyncEngine.records(from: store.snapshot()).values.first?.version
        )
    }

    @MainActor
    func testConcurrentLocalChangesRemainPendingWhenRemoteChangesAreApplied() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncConcurrentMerge")
        defer { TestSupport.remove(folder) }

        let store = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "Edited", updatedAt: Self.date(10)),
            Self.dictionaryEntry(original: "Deleted", updatedAt: Self.date(10)),
        ])
        var state = CloudFolderSyncState(deviceId: "mac-a")
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(20)
        )
        let remoteStore = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "Remote", updatedAt: Self.date(30)),
        ])
        var remoteState = CloudFolderSyncState(deviceId: "mac-b")
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: remoteStore,
            state: &remoteState,
            now: Self.date(40)
        )

        // Unrelated local edits land while the remote entry is being read.
        let editDuringFileIO: @Sendable () async -> Void = {
            await MainActor.run {
                store.dictionaryEntries = [
                    Self.dictionaryEntry(original: "Edited", updatedAt: Self.date(50)),
                ]
            }
        }
        let merged = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(60),
            afterFileIO: editDuringFileIO
        )
        let followUp = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(70)
        )

        XCTAssertEqual(merged.mutationsApplied, 1)
        XCTAssertEqual(store.dictionaryEntries.map(\.original).sorted(), ["Edited", "Remote"])
        XCTAssertEqual(followUp.operationsWritten, 2)
        let published = try CloudFolderSyncEngine.readOperations(
            from: CloudFolderSyncEngine.packageURL(for: folder)
                .appendingPathComponent("ops", isDirectory: true)
        ).operations.filter { $0.deviceId == "mac-a" }
        XCTAssertTrue(published.contains {
            $0.kind == .upsert && $0.dictionary?.updatedAt == Self.date(50)
        })
        XCTAssertTrue(published.contains {
            $0.kind == .delete && $0.itemId == UserDataSyncIdentity.dictionaryItemID(
                entryType: UserDataSyncDictionaryEntryType.term,
                original: "Deleted"
            )
        })
    }

    @MainActor
    func testTwoSimulatedDevicesShareAppendOnlyOperations() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncTwoDevices")
        defer { TestSupport.remove(folder) }

        let firstEntry = Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(10))
        let deviceAStore = InMemoryUserDataSyncStore(dictionaryEntries: [firstEntry])
        let deviceBStore = InMemoryUserDataSyncStore()
        var deviceAState = CloudFolderSyncState(deviceId: "mac-a")
        var deviceBState = CloudFolderSyncState(deviceId: "mac-b")

        let firstResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceAStore,
            state: &deviceAState,
            now: Self.date(20)
        )
        let secondResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            now: Self.date(30)
        )

        XCTAssertEqual(firstResult.operationsWritten, 1)
        XCTAssertEqual(secondResult.mutationsApplied, 1)
        XCTAssertEqual(deviceBStore.dictionaryEntries.map(\.original), ["TypeWhisper"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: CloudFolderSyncEngine.packageURL(for: folder)
                    .appendingPathComponent("ops/mac-a", isDirectory: true)
                    .path
            )
        )
    }

    @MainActor
    func testSpeakerSyncGoldenFixturesDecodeAndRoundTrip() throws {
        let recordID = UUID(uuidString: "7F0C2D6E-2B1A-4C59-9B55-0A6F3C1D2E4F")!
        let revision = UUID(uuidString: "C1D9A3B2-5E6F-4A7B-8C9D-0E1F2A3B4C5D")!

        let transcriptOperation: CloudFolderSyncOperation = try Self.decodeFixture("upsert-history-transcript-v1")
        let transcript = try XCTUnwrap(transcriptOperation.historyTranscript)
        XCTAssertEqual(transcriptOperation.historyComponent, .transcript)
        XCTAssertEqual(transcriptOperation.updatedAt, transcript.updatedAt)
        XCTAssertEqual(transcript.recordID, recordID)
        XCTAssertEqual(transcript.revision, revision)
        XCTAssertEqual(transcript.requestedSpeakerCount, 2)
        XCTAssertEqual(transcript.source, .init(kind: "local", engine: "fluidaudio-offline-diarizer", modelVersion: nil))
        XCTAssertEqual(transcript.segments.map(\.speakerID), ["S1", "S2", nil])
        XCTAssertEqual(transcript.segments.map(\.speakerConfidence), [0.75, nil, nil])
        XCTAssertEqual(transcript.segments.map(\.start), [0, 4.5, 10])
        XCTAssertEqual(transcript.segments[0].text, "Let's start with the budget.")
        XCTAssertTrue(transcript.isValid)
        XCTAssertEqual(CloudFolderSyncEngine.winningOperations(from: [transcriptOperation]).count, 1)

        let speakersOperation: CloudFolderSyncOperation = try Self.decodeFixture("upsert-history-speakers-v1")
        let speakers = try XCTUnwrap(speakersOperation.historySpeakers)
        XCTAssertEqual(speakersOperation.historyComponent, .speakers)
        XCTAssertEqual(speakers.recordID, recordID)
        XCTAssertEqual(speakers.transcriptRevision, revision)
        XCTAssertEqual(speakers.names.map(\.displayName), ["Anna", "Marco"])
        XCTAssertEqual(speakers.names.map(\.speakerID), ["S1", "S2"])
        XCTAssertEqual(speakers.names[0].profileID, UUID(uuidString: "9A8B7C6D-5E4F-4A3B-9C2D-1E0F9A8B7C6D"))
        XCTAssertNil(speakers.names[1].profileID)
        XCTAssertEqual(speakers.names[0].updatedAt, ISO8601DateFormatter().date(from: "2026-09-26T14:10:30Z"))
        // A name without its own date takes the payload's date.
        XCTAssertNil(speakers.names[1].updatedAt)
        XCTAssertEqual(speakers.entries[1].updatedAt, speakers.updatedAt)
        XCTAssertEqual(speakers.cleared, [.init(speakerID: "S3", updatedAt: ISO8601DateFormatter().date(from: "2026-09-26T14:10:35Z")!)])
        XCTAssertTrue(speakers.isValid)
        XCTAssertEqual(CloudFolderSyncEngine.winningOperations(from: [speakersOperation]).count, 1)

        let device: CloudFolderSyncDeviceRecord = try Self.decodeFixture("device-capabilities-v1")
        XCTAssertEqual(device.capabilities, ["history.transcript.v1"])
        XCTAssertTrue(device.syncsSpeakerTranscripts)
        let olderDevice: CloudFolderSyncDeviceRecord = try Self.decodeFixture("device-v1")
        XCTAssertNil(olderDevice.capabilities)
        XCTAssertFalse(olderDevice.syncsSpeakerTranscripts)

        // What this app writes decodes to the same values again.
        for operation in [transcriptOperation, speakersOperation] {
            let data = try Self.entitlementEncoder.encode(operation)
            XCTAssertEqual(try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: data), operation)
        }
        // The local model and the wire payload convert without loss.
        XCTAssertEqual(
            UserDataSyncHistoryTranscriptV1(
                recordID: recordID,
                updatedAt: transcript.updatedAt,
                transcript: transcript.speakerTranscript
            ),
            transcript
        )
        // Converting back writes the payload's date into names that had none.
        let converted = UserDataSyncHistorySpeakersV1(
            recordID: recordID,
            updatedAt: speakers.updatedAt,
            transcriptRevision: revision,
            table: speakers.nameTable(keepingSuggestionsFrom: nil)
        )
        XCTAssertEqual(converted.entries, speakers.entries)
        XCTAssertEqual(converted.cleared, speakers.cleared)
        XCTAssertEqual(converted.updatedAt, speakers.updatedAt)
    }

    func testSpeakerPayloadsWithBadValuesAreNotApplied() throws {
        let transcriptOperation: CloudFolderSyncOperation = try Self.decodeFixture("upsert-history-transcript-v1")
        let speakersOperation: CloudFolderSyncOperation = try Self.decodeFixture("upsert-history-speakers-v1")
        let recordID = try XCTUnwrap(transcriptOperation.historyTranscript?.recordID)
        let revision = try XCTUnwrap(transcriptOperation.historyTranscript?.revision)

        func speakers(_ names: [UserDataSyncHistorySpeakersV1.Name]) throws -> UserDataSyncHistorySpeakersV1 {
            let json = try JSONSerialization.data(withJSONObject: [
                "recordID": recordID.uuidString,
                "updatedAt": "2026-09-26T14:10:40.000Z",
                "transcriptRevision": revision.uuidString,
                "names": names.map { ["speakerID": $0.speakerID, "displayName": $0.displayName] },
            ])
            return try Self.fixtureDecoder.decode(UserDataSyncHistorySpeakersV1.self, from: json)
        }
        XCTAssertFalse(try speakers([.init(speakerID: "X1", displayName: "Anna", profileID: nil)]).isValid)
        XCTAssertFalse(try speakers([.init(speakerID: "S1", displayName: "  ", profileID: nil)]).isValid)
        XCTAssertFalse(try speakers([.init(speakerID: "S1", displayName: String(repeating: "a", count: 101), profileID: nil)]).isValid)
        XCTAssertFalse(try speakers([
            .init(speakerID: "S1", displayName: "Anna", profileID: nil),
            .init(speakerID: "S1", displayName: "Ben", profileID: nil),
        ]).isValid)
        XCTAssertTrue(try speakers([]).isValid)

        // Two payloads in one operation, or a payload for another record, are rejected.
        var mixed = transcriptOperation
        mixed.historySpeakers = speakersOperation.historySpeakers
        XCTAssertTrue(CloudFolderSyncEngine.winningOperations(from: [mixed]).isEmpty)

        let otherItem = try Self.fixtureDecoder.decode(
            CloudFolderSyncOperation.self,
            from: Data(String(
                decoding: try Self.entitlementEncoder.encode(speakersOperation),
                as: UTF8.self
            ).replacingOccurrences(
                of: "history:7f0c2d6e-2b1a-4c59-9b55-0a6f3c1d2e4f",
                with: "history:00000000-0000-4000-8000-000000000001"
            ).utf8)
        )
        XCTAssertTrue(CloudFolderSyncEngine.winningOperations(from: [otherItem]).isEmpty)
    }

    @MainActor
    func testSpeakerTranscriptAndNamesSyncAsIndependentComponents() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncSpeakers")
        defer { TestSupport.remove(folder) }

        let recordID = UUID(uuidString: "83600000-0000-4000-8000-0000000000A1")!
        let transcript = UserDataSyncHistoryTranscriptV1(
            recordID: recordID,
            updatedAt: Self.date(10),
            transcript: SpeakerTranscript(source: .localDiarizer, segments: [
                SpeakerTranscriptSegment(text: "Good morning.", start: 0, end: 1, speakerID: "S1"),
                SpeakerTranscriptSegment(text: "Morning.", start: 1, end: 2, speakerID: "S2"),
            ])
        )
        var table = SpeakerNameTable(transcriptRevision: transcript.revision)
        table.setName("Anna", for: "S1")
        table.setName("Guess", for: "S2", profileID: UUID(), isSuggestion: true)
        let base = Self.historyRecord(
            recordID: recordID,
            finalText: "Good morning. Morning.",
            contentUpdatedAt: Self.date(10),
            inboxState: "none",
            inboxUpdatedAt: Self.date(10)
        )
        let phone = InMemoryUserDataSyncStore(historyRecords: [UserDataSyncHistoryRecord(
            content: base.content,
            inbox: base.inbox,
            audio: nil,
            transcript: transcript,
            speakers: UserDataSyncHistorySpeakersV1(
                recordID: recordID,
                updatedAt: Self.date(11),
                transcriptRevision: transcript.revision,
                table: table
            ),
            localAudioFileURL: nil,
            audioEligible: false
        )])
        let mac = InMemoryUserDataSyncStore()
        var phoneState = CloudFolderSyncState(deviceId: "ios-phone")
        var macState = CloudFolderSyncState(deviceId: "mac-main")
        func sync(_ store: InMemoryUserDataSyncStore, _ state: inout CloudFolderSyncState, at seconds: TimeInterval) async throws -> CloudFolderSyncResult {
            try await CloudFolderSyncEngine.sync(
                folderURL: folder,
                store: store,
                state: &state,
                now: Self.date(seconds)
            )
        }

        let exported = try await sync(phone, &phoneState, at: 20)
        let imported = try await sync(mac, &macState, at: 30)

        XCTAssertEqual(exported.operationsWritten, 4)
        XCTAssertEqual(imported.mutationsApplied, 4)
        XCTAssertEqual(mac.historyRecords.first?.transcript, transcript)
        // The suggestion stays on the phone; only the confirmed name arrives.
        XCTAssertEqual(mac.historyRecords.first?.speakers?.names.map(\.displayName), ["Anna"])
        XCTAssertEqual(
            mac.appliedMutations.suffix(2).map { mutation -> String in
                switch mutation {
                case .upsertHistoryTranscript: "transcript"
                case .upsertHistorySpeakers: "speakers"
                default: "other"
                }
            },
            ["transcript", "speakers"]
        )
        let idle = try await sync(phone, &phoneState, at: 35)
        XCTAssertEqual(idle.operationsWritten, 0)

        // Renaming on the Mac uploads the names only; the transcript is not written again.
        let received = try XCTUnwrap(mac.historyRecords.first)
        var renamed = SpeakerNameTable(transcriptRevision: transcript.revision)
        renamed.setName("Anna Schmidt", for: "S1")
        renamed.setName("Marco", for: "S2")
        mac.historyRecords = [UserDataSyncHistoryRecord(
            content: received.content,
            inbox: received.inbox,
            audio: nil,
            transcript: received.transcript,
            speakers: UserDataSyncHistorySpeakersV1(
                recordID: recordID,
                updatedAt: Self.date(40),
                transcriptRevision: transcript.revision,
                table: renamed
            ),
            localAudioFileURL: nil,
            audioEligible: false
        )]
        let renameExport = try await sync(mac, &macState, at: 50)
        let renameImport = try await sync(phone, &phoneState, at: 60)

        XCTAssertEqual(renameExport.operationsWritten, 1)
        XCTAssertEqual(renameImport.mutationsApplied, 1)
        XCTAssertEqual(phone.historyRecords.first?.speakers?.names.map(\.displayName), ["Anna Schmidt", "Marco"])
        XCTAssertEqual(phone.historyRecords.first?.transcript, transcript)

        // An older rename from another device loses against the newer one.
        let staleDirectory = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("ops/old-device", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: true)
        var stale = SpeakerNameTable(transcriptRevision: transcript.revision)
        stale.setName("Stale", for: "S1")
        let staleOperation = CloudFolderSyncOperation.upsertHistory(
            itemID: UserDataSyncIdentity.historyItemID(recordID: recordID),
            component: .speakers,
            generation: phoneState.historyGeneration,
            deviceId: "old-device",
            speakers: UserDataSyncHistorySpeakersV1(
                recordID: recordID,
                updatedAt: Self.date(39),
                transcriptRevision: transcript.revision,
                table: stale
            )
        )
        try Self.entitlementEncoder.encode(staleOperation)
            .write(to: staleDirectory.appendingPathComponent("stale.json"))
        let staleImport = try await sync(phone, &phoneState, at: 70)
        XCTAssertEqual(staleImport.mutationsApplied, 0)
        XCTAssertEqual(phone.historyRecords.first?.speakers?.names.map(\.displayName), ["Anna Schmidt", "Marco"])

        // Deleting the record removes it with all of its components.
        mac.historyRecords = []
        mac.deletedHistoryRecords = [UserDataSyncHistoryDeletion(recordID: recordID, deletedAt: Self.date(80))]
        _ = try await sync(mac, &macState, at: 90)
        _ = try await sync(phone, &phoneState, at: 100)
        XCTAssertTrue(phone.historyRecords.isEmpty)
    }

    @MainActor
    func testSpeakerComponentsWaitUntilEveryRecentDeviceUnderstandsThem() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncSpeakerGate")
        defer { TestSupport.remove(folder) }

        let recordID = UUID(uuidString: "83600000-0000-4000-8000-0000000000A2")!
        let transcript = UserDataSyncHistoryTranscriptV1(
            recordID: recordID,
            updatedAt: Self.date(10),
            transcript: SpeakerTranscript(source: .localDiarizer, segments: [
                SpeakerTranscriptSegment(text: "Good morning.", start: 0, end: 1, speakerID: "S1"),
            ])
        )
        var table = SpeakerNameTable(transcriptRevision: transcript.revision)
        table.setName("Anna", for: "S1")
        let base = Self.historyRecord(
            recordID: recordID,
            finalText: "Good morning.",
            contentUpdatedAt: Self.date(10),
            inboxState: "none",
            inboxUpdatedAt: Self.date(10)
        )
        let mac = InMemoryUserDataSyncStore(historyRecords: [UserDataSyncHistoryRecord(
            content: base.content,
            inbox: base.inbox,
            audio: nil,
            transcript: transcript,
            speakers: UserDataSyncHistorySpeakersV1(
                recordID: recordID,
                updatedAt: Self.date(11),
                transcriptRevision: transcript.revision,
                table: table
            ),
            localAudioFileURL: nil,
            audioEligible: false
        )])
        var macState = CloudFolderSyncState(deviceId: "mac-main")
        let devicesURL = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("devices", isDirectory: true)
        try FileManager.default.createDirectory(at: devicesURL, withIntermediateDirectories: true)
        func writePhone(capabilities: [String]?, updatedAt: Date) throws {
            try Self.entitlementEncoder.encode(CloudFolderSyncDeviceRecord(
                deviceId: "ios-phone",
                platform: "iOS",
                appVersion: "1.1.0",
                updatedAt: updatedAt,
                capabilities: capabilities
            )).write(to: devicesURL.appendingPathComponent("ios-phone.json"))
        }
        func syncMac(at seconds: TimeInterval) async throws -> CloudFolderSyncResult {
            try await CloudFolderSyncEngine.sync(
                folderURL: folder,
                store: mac,
                state: &macState,
                now: Self.date(seconds)
            )
        }

        // A phone without the capability synced recently: only content and inbox are written.
        try writePhone(capabilities: nil, updatedAt: Self.date(15))
        let withheld = try await syncMac(at: 20)
        XCTAssertEqual(withheld.operationsWritten, 2)
        let again = try await syncMac(at: 30)
        XCTAssertEqual(again.operationsWritten, 0)

        // An edit of the same record's text from the phone does not count as
        // receiving the held-back components.
        let phoneOperations = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("ops/ios-phone", isDirectory: true)
        try FileManager.default.createDirectory(at: phoneOperations, withIntermediateDirectories: true)
        let edited = Self.historyRecord(
            recordID: recordID,
            finalText: "Good morning, Anna.",
            contentUpdatedAt: Self.date(31),
            inboxState: "none",
            inboxUpdatedAt: Self.date(10)
        )
        try Self.entitlementEncoder.encode(CloudFolderSyncOperation.upsertHistory(
            itemID: UserDataSyncIdentity.historyItemID(recordID: recordID),
            component: .content,
            generation: macState.historyGeneration,
            deviceId: "ios-phone",
            content: edited.content
        )).write(to: phoneOperations.appendingPathComponent("edit.json"))
        let phoneEdit = try await syncMac(at: 33)
        XCTAssertEqual(phoneEdit.mutationsApplied, 1)

        // After the phone's update the pending components are uploaded.
        try writePhone(capabilities: [CloudFolderSyncDeviceRecord.speakerTranscriptCapability], updatedAt: Self.date(35))
        let released = try await syncMac(at: 40)
        XCTAssertEqual(released.operationsWritten, 2)

        XCTAssertTrue(CloudFolderSyncEngine.speakerComponentsCanBeWritten(devices: [], ownDeviceId: "mac-main", now: Self.date(0)))
        let stalePhone = CloudFolderSyncDeviceRecord(deviceId: "old", platform: "iOS", appVersion: "1.0", updatedAt: Self.date(0))
        XCTAssertFalse(CloudFolderSyncEngine.speakerComponentsCanBeWritten(
            devices: [stalePhone],
            ownDeviceId: "mac-main",
            now: Self.date(29 * 24 * 60 * 60)
        ))
        XCTAssertTrue(CloudFolderSyncEngine.speakerComponentsCanBeWritten(
            devices: [stalePhone],
            ownDeviceId: "mac-main",
            now: Self.date(31 * 24 * 60 * 60)
        ))
    }

    @MainActor
    func testHistoryContentAndInboxSyncAsIndependentComponents() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncHistoryComponents")
        defer { TestSupport.remove(folder) }

        let recordID = UUID(uuidString: "83600000-0000-4000-8000-000000000001")!
        let initial = Self.historyRecord(
            recordID: recordID,
            finalText: "Watch capture",
            contentUpdatedAt: Self.date(10),
            inboxState: "open",
            inboxUpdatedAt: Self.date(10)
        )
        let watch = InMemoryUserDataSyncStore(historyRecords: [initial])
        let mac = InMemoryUserDataSyncStore()
        var watchState = CloudFolderSyncState(deviceId: "ios-watch")
        var macState = CloudFolderSyncState(deviceId: "mac-main")

        let exported = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: watch,
            state: &watchState,
            now: Self.date(20)
        )
        let imported = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: mac,
            state: &macState,
            now: Self.date(30)
        )

        XCTAssertEqual(exported.operationsWritten, 2)
        XCTAssertEqual(imported.mutationsApplied, 2)
        XCTAssertEqual(mac.historyRecords.first?.content.finalText, "Watch capture")
        XCTAssertEqual(mac.historyRecords.first?.inbox.state, "open")

        let importedRecord = try XCTUnwrap(mac.historyRecords.first)
        mac.historyRecords = [UserDataSyncHistoryRecord(
            content: importedRecord.content,
            inbox: UserDataSyncHistoryInboxV1(
                recordID: recordID,
                updatedAt: Self.date(40),
                state: "completed",
                kind: "watchRecording",
                completionPolicy: .onOpen,
                completedAt: Self.date(40),
                safeAction: nil
            ),
            audio: importedRecord.audio,
            localAudioFileURL: nil,
            audioEligible: false
        )]

        let completionExport = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: mac,
            state: &macState,
            now: Self.date(50)
        )
        let completionImport = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: watch,
            state: &watchState,
            now: Self.date(60)
        )

        XCTAssertEqual(completionExport.operationsWritten, 1)
        XCTAssertEqual(completionImport.mutationsApplied, 1)
        XCTAssertEqual(watch.historyRecords.first?.content.finalText, "Watch capture")
        XCTAssertEqual(watch.historyRecords.first?.inbox.state, "completed")
    }

    @MainActor
    func testHistoryRetentionAbsenceDoesNotDeleteButExplicitJournalDoes() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncHistoryDeletion")
        defer { TestSupport.remove(folder) }

        let recordID = UUID(uuidString: "83600000-0000-4000-8000-000000000002")!
        let record = Self.historyRecord(
            recordID: recordID,
            finalText: "Keep on the other device",
            contentUpdatedAt: Self.date(10),
            inboxState: "none",
            inboxUpdatedAt: Self.date(10)
        )
        let first = InMemoryUserDataSyncStore(historyRecords: [record])
        let second = InMemoryUserDataSyncStore()
        var firstState = CloudFolderSyncState(deviceId: "ios-a")
        var secondState = CloudFolderSyncState(deviceId: "mac-b")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: first,
            state: &firstState,
            now: Self.date(20)
        )
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: second,
            state: &secondState,
            now: Self.date(30)
        )
        XCTAssertEqual(second.historyRecords.count, 1)

        first.historyRecords = []
        let retentionPass = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: first,
            state: &firstState,
            now: Self.date(35)
        )
        XCTAssertEqual(retentionPass.operationsWritten, 0)

        first.deletedHistoryRecords = [
            UserDataSyncHistoryDeletion(recordID: recordID, deletedAt: Self.date(40))
        ]
        let deletionPass = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: first,
            state: &firstState,
            now: Self.date(45)
        )
        let deletionImport = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: second,
            state: &secondState,
            now: Self.date(50)
        )

        XCTAssertEqual(deletionPass.operationsWritten, 1)
        XCTAssertEqual(deletionImport.mutationsApplied, 1)
        XCTAssertTrue(second.historyRecords.isEmpty)
    }

    func testHistoryAudioAssetsUseContentAddressingAndVerifyIntegrity() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncHistoryAudio")
        defer { TestSupport.remove(folder) }
        let packageURL = CloudFolderSyncEngine.packageURL(for: folder)
        let sourceURL = folder.appendingPathComponent("capture.wav")
        try Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02, 0x03]).write(to: sourceURL)
        let recordID = UUID(uuidString: "83600000-0000-4000-8000-000000000003")!

        let descriptor = try HistorySyncAssetStore.publish(
            sourceURL: sourceURL,
            packageURL: packageURL,
            generation: "history-v1",
            recordID: recordID,
            updatedAt: Self.date(10),
            durationSeconds: 1.25
        )
        let verified = try await HistorySyncAssetStore.verifiedAssetURL(
            packageURL: packageURL,
            descriptor: descriptor
        )

        XCTAssertTrue(descriptor.isValid)
        XCTAssertEqual(descriptor.byteCount, 7)
        XCTAssertTrue(descriptor.relativeAssetPath.hasSuffix("/\(descriptor.sha256).wav"))
        XCTAssertEqual(try Data(contentsOf: verified), try Data(contentsOf: sourceURL))

        let unsafe = UserDataSyncHistoryAudioV1(
            recordID: recordID,
            updatedAt: Self.date(10),
            relativeAssetPath: "../capture.wav",
            mediaType: "audio/wav",
            byteCount: 7,
            sha256: descriptor.sha256,
            createdAt: Self.date(10),
            durationSeconds: 1.25
        )
        do {
            _ = try await HistorySyncAssetStore.verifiedAssetURL(
                packageURL: packageURL,
                descriptor: unsafe
            )
            XCTFail("Expected an unsafe asset path to be rejected")
        } catch HistorySyncAssetStoreError.invalidDescriptor {
            // Expected.
        }

        let outsideURL = folder.appendingPathComponent("outside.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: outsideURL)
        let symlinkURL = packageURL
            .appendingPathComponent("assets/history", isDirectory: true)
            .appendingPathComponent("escaped.wav")
        try FileManager.default.createDirectory(
            at: symlinkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: outsideURL
        )
        let outsideDigest = try HistorySyncAssetStore.sha256AndSize(of: outsideURL)
        let symlinkDescriptor = UserDataSyncHistoryAudioV1(
            recordID: recordID,
            updatedAt: Self.date(10),
            relativeAssetPath: "assets/history/escaped.wav",
            mediaType: "audio/wav",
            byteCount: outsideDigest.byteCount,
            sha256: outsideDigest.sha256,
            createdAt: Self.date(10),
            durationSeconds: 1.25
        )
        do {
            _ = try await HistorySyncAssetStore.verifiedAssetURL(
                packageURL: packageURL,
                descriptor: symlinkDescriptor
            )
            XCTFail("Expected a symlink outside the sync package to be rejected")
        } catch HistorySyncAssetStoreError.invalidDescriptor {
            // Expected.
        }
    }

    @MainActor
    func testHistoryAudioPublishFailureDoesNotAbortTextSync() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncAudioFailure")
        defer { TestSupport.remove(folder) }
        let record = Self.historyRecord(
            recordID: UUID(),
            finalText: "Text survives missing audio",
            contentUpdatedAt: Self.date(10),
            inboxState: "none",
            inboxUpdatedAt: Self.date(10)
        )
        let missingAudio = folder.appendingPathComponent("missing.wav")
        let store = InMemoryUserDataSyncStore(historyRecords: [
            UserDataSyncHistoryRecord(
                content: record.content,
                inbox: record.inbox,
                audio: nil,
                localAudioFileURL: missingAudio,
                audioEligible: true
            ),
        ])
        var state = CloudFolderSyncState(deviceId: "mac-audio-failure")

        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(20)
        )

        XCTAssertEqual(result.operationsWritten, 2)
        XCTAssertEqual(
            result.diagnostics,
            [CloudFolderSyncDiagnostic(kind: .audioTransferFailed, fileName: "missing.wav")]
        )
    }

    @MainActor
    func testControllerKeepsSynchronizedAudioRemote() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncAutomaticAudio")
        defer { TestSupport.remove(folder) }
        let historyDirectory = folder.appendingPathComponent("history", isDirectory: true)
        let suiteName = "CloudFolderSyncAutomaticAudio-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        preferences.isAudioEnabled = true
        let historyService = HistoryService(
            appSupportDirectory: historyDirectory,
            historySyncPreferences: preferences
        )
        let recordID = UUID(uuidString: "83600000-0000-4000-8000-000000000030")!
        let sourceURL = folder.appendingPathComponent("capture.wav")
        try Data([0x52, 0x49, 0x46, 0x46, 0x09, 0x08, 0x07]).write(to: sourceURL)
        let descriptor = try HistorySyncAssetStore.publish(
            sourceURL: sourceURL,
            packageURL: CloudFolderSyncEngine.packageURL(for: folder),
            generation: "history-v1",
            recordID: recordID,
            updatedAt: Date(),
            durationSeconds: 1.5
        )
        try historyService.applyUserDataSyncMutations([
            .upsertHistoryContent(UserDataSyncHistoryContentV1(
                recordID: recordID,
                createdAt: Self.date(1),
                updatedAt: Self.date(10),
                originDeviceID: "ios-history-origin",
                originPlatform: "iOS",
                source: RecordingSource.iPhone.rawValue,
                processingState: RecordingProcessingState.ready.rawValue,
                rawTranscript: "Audio note",
                finalText: "Audio note",
                durationSeconds: 1.5,
                detectedLanguage: "en",
                engineDisplayName: "Apple Speech"
            )),
            .upsertHistoryAudio(descriptor),
        ])
        let controller = CloudFolderSyncController(
            syncStore: InMemoryUserDataSyncStore(),
            historyService: historyService,
            historySyncPreferences: preferences,
            defaults: defaults,
            automaticICloudAvailable: false
        )
        defer { controller.deactivate() }

        let diagnostics = await controller.installPendingSynchronizedAudio(in: folder)

        XCTAssertTrue(diagnostics.isEmpty)
        let record = try XCTUnwrap(historyService.recentRecords.first { $0.id == recordID })
        XCTAssertNil(historyService.audioFileURL(for: record))
        XCTAssertFalse(preferences.isAudioEnabled)
    }

    @MainActor
    func testControllerDoesNotBackfillAudioFromBeforeAudioSyncWasEnabled() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncNoAudioBackfill")
        defer { TestSupport.remove(folder) }
        let historyDirectory = folder.appendingPathComponent("history", isDirectory: true)
        let suiteName = "CloudFolderSyncNoAudioBackfill-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        preferences.isAudioEnabled = false
        let historyService = HistoryService(
            appSupportDirectory: historyDirectory,
            historySyncPreferences: preferences
        )
        let recordID = UUID(uuidString: "83600000-0000-4000-8000-000000000031")!
        let sourceURL = folder.appendingPathComponent("old-capture.wav")
        try Data([0x52, 0x49, 0x46, 0x46, 0x01]).write(to: sourceURL)
        let oldDate = Date().addingTimeInterval(-24 * 60 * 60)
        let descriptor = try HistorySyncAssetStore.publish(
            sourceURL: sourceURL,
            packageURL: CloudFolderSyncEngine.packageURL(for: folder),
            generation: "history-v1",
            recordID: recordID,
            updatedAt: oldDate,
            durationSeconds: 1
        )
        try historyService.applyUserDataSyncMutations([
            .upsertHistoryContent(UserDataSyncHistoryContentV1(
                recordID: recordID,
                createdAt: oldDate,
                updatedAt: oldDate,
                originDeviceID: "ios-history-origin",
                originPlatform: "iOS",
                source: RecordingSource.iPhone.rawValue,
                processingState: RecordingProcessingState.ready.rawValue,
                rawTranscript: "Old audio note",
                finalText: "Old audio note",
                durationSeconds: 1,
                engineDisplayName: "Apple Speech"
            )),
            .upsertHistoryAudio(descriptor),
        ])
        preferences.isAudioEnabled = true
        let controller = CloudFolderSyncController(
            syncStore: InMemoryUserDataSyncStore(),
            historyService: historyService,
            historySyncPreferences: preferences,
            defaults: defaults,
            automaticICloudAvailable: false
        )
        defer { controller.deactivate() }

        let diagnostics = await controller.installPendingSynchronizedAudio(in: folder)

        XCTAssertTrue(diagnostics.isEmpty)
        let record = try XCTUnwrap(historyService.recentRecords.first { $0.id == recordID })
        XCTAssertNil(historyService.audioFileURL(for: record))
    }

    @MainActor
    func testDeleteTombstoneWinsOverOlderLocalItem() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncDelete")
        defer { TestSupport.remove(folder) }

        let snippet = Self.snippet(trigger: ";sig", replacement: "Regards", updatedAt: Self.date(10))
        let deviceAStore = InMemoryUserDataSyncStore(snippets: [snippet])
        var deviceAState = CloudFolderSyncState(deviceId: "mac-a")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceAStore,
            state: &deviceAState,
            now: Self.date(20)
        )

        deviceAStore.snippets = []
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceAStore,
            state: &deviceAState,
            now: Self.date(30)
        )

        let deviceBStore = InMemoryUserDataSyncStore(snippets: [snippet])
        var deviceBState = CloudFolderSyncState(deviceId: "mac-b")
        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            now: Self.date(40)
        )

        XCTAssertEqual(result.mutationsApplied, 1)
        XCTAssertTrue(deviceBStore.snippets.isEmpty)
    }

    @MainActor
    func testAlreadyAppliedRemoteOperationIsNotAppliedAgain() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncApplied")
        defer { TestSupport.remove(folder) }

        let entry = Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(10))
        let deviceAStore = InMemoryUserDataSyncStore(dictionaryEntries: [entry])
        let deviceBStore = InMemoryUserDataSyncStore()
        var deviceAState = CloudFolderSyncState(deviceId: "mac-z")
        var deviceBState = CloudFolderSyncState(deviceId: "mac-b")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceAStore,
            state: &deviceAState,
            now: Self.date(20)
        )

        let firstResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            now: Self.date(30)
        )
        let secondResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            now: Self.date(40)
        )

        XCTAssertEqual(firstResult.mutationsApplied, 1)
        XCTAssertEqual(secondResult.mutationsApplied, 0)
        XCTAssertEqual(deviceBStore.appliedMutations.count, 1)
    }

    @MainActor
    func testSyncCacheSkipsRereadingUnchangedOperationFiles() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncOperationCache")
        defer { TestSupport.remove(folder) }

        let remoteStore = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(10)),
        ])
        var remoteState = CloudFolderSyncState(deviceId: "mac-remote")
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: remoteStore,
            state: &remoteState,
            now: Self.date(20)
        )
        let remoteFile = try XCTUnwrap(Self.operationFiles(folder: folder, deviceId: "mac-remote").first)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: remoteFile.path
            )
        }

        let cache = CloudFolderSyncCache()
        let store = InMemoryUserDataSyncStore()
        var state = CloudFolderSyncState(deviceId: "mac-local")
        let first = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(30),
            cache: cache
        )
        XCTAssertEqual(first.mutationsApplied, 1)

        // An unreadable file with unchanged metadata is served from the cache.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0)],
            ofItemAtPath: remoteFile.path
        )
        let cached = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(40),
            cache: cache
        )
        XCTAssertEqual(cached.operationsRead, first.operationsRead)
        XCTAssertTrue(cached.diagnostics.isEmpty)

        var uncachedState = state
        let uncached = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &uncachedState,
            now: Self.date(50)
        )
        XCTAssertEqual(uncached.diagnostics.map(\.kind), [.unreadableFile])

        // A changed modification date invalidates the cached operation.
        try FileManager.default.setAttributes(
            [.modificationDate: Self.date(60)],
            ofItemAtPath: remoteFile.path
        )
        let changed = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(70),
            cache: cache
        )
        XCTAssertEqual(changed.diagnostics.map(\.kind), [.unreadableFile])
    }

    @MainActor
    func testPublishedLocalAudioIsNotRepublishedByLaterSyncs() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncAudioRepublish")
        defer { TestSupport.remove(folder) }
        let audioURL = folder.appendingPathComponent("capture.wav")
        try Data([0x52, 0x49, 0x46, 0x46, 0x0A, 0x0B, 0x0C]).write(to: audioURL)
        let record = Self.historyRecord(
            recordID: UUID(uuidString: "83600000-0000-4000-8000-000000000040")!,
            finalText: "Local audio note",
            contentUpdatedAt: Self.date(10),
            inboxState: "none",
            inboxUpdatedAt: Self.date(10)
        )
        let store = InMemoryUserDataSyncStore(historyRecords: [
            UserDataSyncHistoryRecord(
                content: record.content,
                inbox: record.inbox,
                audio: nil,
                localAudioFileURL: audioURL,
                audioEligible: true
            ),
        ])
        var state = CloudFolderSyncState(deviceId: "mac-audio")

        func sync(_ seconds: TimeInterval) async throws -> CloudFolderSyncResult {
            try await CloudFolderSyncEngine.sync(
                folderURL: folder,
                store: store,
                state: &state,
                now: Self.date(seconds)
            )
        }

        let published = try await sync(20)
        let unchanged = try await sync(30)
        XCTAssertEqual(published.operationsWritten, 3)
        XCTAssertEqual(unchanged.operationsWritten, 0)

        // Applying a remote change rebuilds the snapshot without the local audio descriptor.
        let remoteStore = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "Remote", updatedAt: Self.date(35)),
        ])
        var remoteState = CloudFolderSyncState(deviceId: "mac-remote")
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: remoteStore,
            state: &remoteState,
            now: Self.date(36)
        )
        let importing = try await sync(40)
        let afterImport = try await sync(50)
        XCTAssertEqual(importing.mutationsApplied, 1)
        XCTAssertEqual(importing.operationsWritten, 0)
        XCTAssertEqual(afterImport.operationsWritten, 0)
        XCTAssertEqual(Self.operationFiles(folder: folder, deviceId: "mac-audio").count, 3)
    }

    @MainActor
    func testSyncCacheSkipsRehashingUnchangedAudio() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncAudioDigest")
        let audioURL = folder.appendingPathComponent("capture.wav")
        let audioData = Data([0x52, 0x49, 0x46, 0x46, 0x0D, 0x0E, 0x0F])
        try audioData.write(to: audioURL)
        let recordID = UUID(uuidString: "83600000-0000-4000-8000-000000000041")!
        let digest = try HistorySyncAssetStore.sha256AndSize(of: audioURL)
        let publishedURL = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("assets/history/history-v1")
            .appendingPathComponent(recordID.uuidString.lowercased())
            .appendingPathComponent("\(digest.sha256).wav")
        defer {
            for file in [audioURL, publishedURL] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: file.path
                )
            }
            TestSupport.remove(folder)
        }
        let record = Self.historyRecord(
            recordID: recordID,
            finalText: "Hashed once",
            contentUpdatedAt: Self.date(10),
            inboxState: "none",
            inboxUpdatedAt: Self.date(10)
        )
        let store = InMemoryUserDataSyncStore(historyRecords: [
            UserDataSyncHistoryRecord(
                content: record.content,
                inbox: record.inbox,
                audio: nil,
                localAudioFileURL: audioURL,
                audioEligible: true
            ),
        ])
        let cache = CloudFolderSyncCache()
        var state = CloudFolderSyncState(deviceId: "mac-digest")

        let first = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(20),
            cache: cache
        )
        XCTAssertEqual(first.operationsWritten, 3)
        XCTAssertEqual(try Data(contentsOf: publishedURL), audioData)

        // Neither the recording nor its published copy can be read without the cache.
        for file in [audioURL, publishedURL] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0)],
                ofItemAtPath: file.path
            )
        }
        let cached = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(30),
            cache: cache
        )
        XCTAssertTrue(cached.diagnostics.isEmpty)
        XCTAssertEqual(cached.operationsWritten, 0)

        var uncachedState = state
        let uncached = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &uncachedState,
            now: Self.date(40)
        )
        XCTAssertEqual(uncached.diagnostics.map(\.kind), [.audioTransferFailed])
    }

    @MainActor
    func testHistoryOperationsAreGroupedPerItem() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncHistoryGrouping")
        defer { TestSupport.remove(folder) }

        let records = ["0a", "0b", "0c"].map { suffix in
            Self.historyRecord(
                recordID: UUID(uuidString: "83600000-0000-4000-8000-0000000000\(suffix)")!,
                finalText: "Record \(suffix)",
                contentUpdatedAt: Self.date(10),
                inboxState: "open",
                inboxUpdatedAt: Self.date(10)
            )
        }
        let remote = InMemoryUserDataSyncStore(historyRecords: records)
        var remoteState = CloudFolderSyncState(deviceId: "ios-remote")
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: remote,
            state: &remoteState,
            now: Self.date(20)
        )
        remote.historyRecords = [records[0], records[2]]
        remote.deletedHistoryRecords = [
            UserDataSyncHistoryDeletion(recordID: records[1].content.recordID, deletedAt: Self.date(40)),
        ]
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: remote,
            state: &remoteState,
            now: Self.date(45)
        )

        let local = InMemoryUserDataSyncStore(historyRecords: [records[1]])
        var localState = CloudFolderSyncState(deviceId: "mac-local")
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: local,
            state: &localState,
            now: Self.date(50)
        )

        XCTAssertEqual(local.appliedMutations, [
            .upsertHistoryContent(records[0].content),
            .upsertHistoryInbox(records[0].inbox),
            .deleteHistory(recordID: records[1].content.recordID),
            .upsertHistoryContent(records[2].content),
            .upsertHistoryInbox(records[2].inbox),
        ])
        XCTAssertEqual(
            local.historyRecords.map(\.content.recordID),
            [records[0].content.recordID, records[2].content.recordID]
        )
    }

    func testSharedDateFormattersKeepEncodedDatesIdentical() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dates = [
            0,
            1_700_000_010,
            1_700_000_010.456,
            1_700_000_010.4567,
            1_700_000_010.9996,
            -86_400.25,
        ].map(Date.init(timeIntervalSince1970:))
        let snapshot = UserDataSyncSnapshot(snippets: dates.enumerated().map { index, date in
            Self.snippet(trigger: ";date\(index)", replacement: "Date", updatedAt: date)
        })

        // Convert concurrently so the shared formatters are used from several threads.
        let conversions = await withTaskGroup(of: [String: CloudFolderSyncRecord].self) { group in
            for _ in 0..<8 {
                group.addTask { CloudFolderSyncEngine.records(from: snapshot) }
            }
            var results: [[String: CloudFolderSyncRecord]] = []
            for await records in group {
                results.append(records)
            }
            return results
        }
        for records in conversions {
            for (index, date) in dates.enumerated() {
                XCTAssertEqual(
                    records[UserDataSyncIdentity.snippetItemID(trigger: ";date\(index)")]?.version,
                    formatter.string(from: date)
                )
            }
        }

        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncDateFormatting")
        defer { TestSupport.remove(folder) }
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_010.4567)
        let store = await InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: updatedAt),
        ])
        var state = CloudFolderSyncState(deviceId: "mac-dates")
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(20)
        )
        let operationFile = try XCTUnwrap(Self.operationFiles(folder: folder, deviceId: "mac-dates").first)
        let operation = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: operationFile)) as? [String: Any]
        )
        let dictionary = try XCTUnwrap(operation["dictionary"] as? [String: Any])
        XCTAssertEqual(operation["updatedAt"] as? String, formatter.string(from: updatedAt))
        XCTAssertEqual(dictionary["updatedAt"] as? String, formatter.string(from: updatedAt))
        XCTAssertEqual(dictionary["createdAt"] as? String, formatter.string(from: Self.date(1)))

        // Whole-second dates from other writers still decode.
        let wholeSecondEncoder = JSONEncoder()
        wholeSecondEncoder.dateEncodingStrategy = .iso8601
        let remoteSnippet = Self.snippet(trigger: ";whole", replacement: "Whole", updatedAt: Self.date(30))
        let remoteDirectory = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("ops/remote-device", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        try wholeSecondEncoder.encode(CloudFolderSyncOperation.upsertSnippet(
            remoteSnippet,
            itemID: UserDataSyncIdentity.snippetItemID(trigger: ";whole"),
            deviceId: "remote-device"
        )).write(to: remoteDirectory.appendingPathComponent("whole-second.json"))
        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(40)
        )
        XCTAssertEqual(result.mutationsApplied, 1)
        let importedSnippets = await store.snippets
        XCTAssertEqual(importedSnippets, [remoteSnippet])
    }

    @MainActor
    func testExpiredLocalTombstonesArePrunedAfterRetentionWindow() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncTombstoneRetention")
        defer { TestSupport.remove(folder) }

        let itemID = UserDataSyncIdentity.snippetItemID(trigger: ";sig")
        let store = InMemoryUserDataSyncStore()
        var state = CloudFolderSyncState(deviceId: "mac-a", knownLocalItemIDs: [itemID])

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(10)
        )
        XCTAssertEqual(Self.operationFiles(folder: folder, deviceId: "mac-a").count, 1)

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(10 + 91 * 24 * 60 * 60)
        )

        XCTAssertTrue(Self.operationFiles(folder: folder, deviceId: "mac-a").isEmpty)
    }

    @MainActor
    func testConflictTieBreakerUsesUpdatedAtThenDeviceId() {
        let older = CloudFolderSyncOperation.upsertDictionary(
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(10)),
            itemID: UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: "TypeWhisper"),
            deviceId: "mac-z",
            operationId: "older"
        )
        let newer = CloudFolderSyncOperation.upsertDictionary(
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(20)),
            itemID: UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: "TypeWhisper"),
            deviceId: "mac-a",
            operationId: "newer"
        )
        let sameTimeHigherDevice = CloudFolderSyncOperation.upsertDictionary(
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(20)),
            itemID: UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: "TypeWhisper"),
            deviceId: "mac-z",
            operationId: "tie"
        )

        let winner = CloudFolderSyncEngine.winningOperations(from: [older, newer, sameTimeHigherDevice]).values.first
        XCTAssertEqual(winner?.operationId, "tie")
    }

    func testTermEncodingUsesExplicitNullAndLegacyDecodingTracksAbsence()
        throws
    {
        let automatic = Self.dictionaryEntry(
            original: "Automatic",
            updatedAt: Self.date(10)
        )
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Self.entitlementEncoder.encode(automatic)
            ) as? [String: Any]
        )
        XCTAssertTrue(encoded["ctcMinSimilarity"] is NSNull)

        let legacyData = Data(
            """
            {
              "entryType": "term",
              "original": "Legacy",
              "caseSensitive": false,
              "isEnabled": true,
              "createdAt": "2023-11-14T22:13:21.000Z",
              "updatedAt": "2023-11-14T22:13:30.000Z"
            }
            """.utf8
        )
        let legacy = try Self.fixtureDecoder.decode(
            UserDataSyncDictionaryEntry.self,
            from: legacyData
        )
        XCTAssertNil(legacy.ctcMinSimilarity)
        XCTAssertFalse(legacy.ctcMinSimilarityFieldPresent)
    }

    @MainActor
    func testExplicitCTCFieldWinsEqualTimestampBeforeDeviceID() {
        let itemID = UserDataSyncIdentity.dictionaryItemID(
            entryType: UserDataSyncDictionaryEntryType.term,
            original: "TypeWhisper"
        )
        let explicit = CloudFolderSyncOperation.upsertDictionary(
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(20),
                ctcMinSimilarity: 0.65
            ),
            itemID: itemID,
            deviceId: "mac-a",
            operationId: "explicit"
        )
        let legacy = CloudFolderSyncOperation.upsertDictionary(
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(20),
                ctcMinSimilarityFieldPresent: false
            ),
            itemID: itemID,
            deviceId: "mac-z",
            operationId: "legacy"
        )

        XCTAssertEqual(
            CloudFolderSyncEngine.winningOperations(
                from: [legacy, explicit]
            )[itemID]?.operationId,
            "explicit"
        )
    }

    @MainActor
    func testCTCValueAndExplicitNullRoundTripAcrossTwoDevices()
        async throws
    {
        let folder = try TestSupport.makeTemporaryDirectory(
            prefix: "CloudFolderSyncCTCRoundTrip"
        )
        defer { TestSupport.remove(folder) }
        let first = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(10),
                ctcMinSimilarity: 0.65
            )
        ])
        let second = InMemoryUserDataSyncStore()
        var firstState = CloudFolderSyncState(deviceId: "mac-a")
        var secondState = CloudFolderSyncState(deviceId: "ios-b")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: first,
            state: &firstState,
            now: Self.date(20)
        )
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: second,
            state: &secondState,
            now: Self.date(30)
        )
        XCTAssertEqual(
            second.dictionaryEntries.first?.ctcMinSimilarity,
            0.65
        )

        second.dictionaryEntries = [
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(40)
            )
        ]
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: second,
            state: &secondState,
            now: Self.date(50)
        )
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: first,
            state: &firstState,
            now: Self.date(60)
        )

        XCTAssertNil(first.dictionaryEntries.first?.ctcMinSimilarity)
        XCTAssertEqual(
            first.dictionaryEntries.first?.ctcMinSimilarityFieldPresent,
            true
        )
    }

    @MainActor
    func testLegacyCTCFieldPreservesValueAndRepublishesOnce()
        async throws
    {
        let folder = try TestSupport.makeTemporaryDirectory(
            prefix: "CloudFolderSyncLegacyCTC"
        )
        defer { TestSupport.remove(folder) }
        let store = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(10),
                ctcMinSimilarity: 0.8
            )
        ])
        let legacy = CloudFolderSyncOperation.upsertDictionary(
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(20),
                ctcMinSimilarityFieldPresent: false
            ),
            itemID: UserDataSyncIdentity.dictionaryItemID(
                entryType: UserDataSyncDictionaryEntryType.term,
                original: "TypeWhisper"
            ),
            deviceId: "legacy-ios",
            operationId: "legacy"
        )
        try Self.writeLegacyOperation(legacy, to: folder)
        var state = CloudFolderSyncState(deviceId: "mac-a")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(25)
        )
        XCTAssertEqual(
            store.dictionaryEntries.first?.ctcMinSimilarity,
            0.8
        )
        let itemID = UserDataSyncIdentity.dictionaryItemID(
            entryType: UserDataSyncDictionaryEntryType.term,
            original: "TypeWhisper"
        )
        XCTAssertNil(state.exportedItemVersions[itemID])

        let republish = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(30)
        )
        let repeated = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            now: Self.date(35)
        )
        XCTAssertEqual(republish.operationsWritten, 1)
        XCTAssertEqual(repeated.operationsWritten, 0)
    }

    @MainActor
    func testLegacyMutationDoesNotOverwriteStoredCTC() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "CloudFolderSyncStoredCTC"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let service = DictionaryService(
            appSupportDirectory: appSupportDirectory
        )
        service.addEntry(
            type: .term,
            original: "TypeWhisper",
            ctcMinSimilarity: 0.8
        )
        try service.applyUserDataSyncMutations([
            .upsertDictionary(
                Self.dictionaryEntry(
                    original: "TypeWhisper",
                    updatedAt: Self.date(20),
                    ctcMinSimilarityFieldPresent: false
                )
            )
        ])

        XCTAssertEqual(service.entries.first?.ctcMinSimilarity, 0.8)
        XCTAssertTrue(
            service.userDataSyncEntries().first?
                .ctcMinSimilarityFieldPresent == true
        )
    }

    @MainActor
    func testHostStoreSnapshotsObserversBeforeNotifying() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncObservers")
        defer { TestSupport.remove(appSupportDirectory) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionaryService,
            snippetService: snippetService
        )

        var firstObserverID: UUID?
        var firstCalls = 0
        var secondCalls = 0

        firstObserverID = store.observeLocalChanges {
            firstCalls += 1
            if let firstObserverID {
                store.removeLocalChangeObserver(firstObserverID)
            }
        }
        store.observeLocalChanges {
            secondCalls += 1
        }

        dictionaryService.addEntry(type: .term, original: "First")
        dictionaryService.addEntry(type: .term, original: "Second")

        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(secondCalls, 2)
    }

    @MainActor
    func testHistoryJournalObserverSeesPostChangeSnapshot() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "CloudFolderSyncHistoryJournalObserver"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let suiteName = "CloudFolderSyncHistoryJournalObserver-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        let historyService = HistoryService(
            appSupportDirectory: appSupportDirectory,
            historySyncPreferences: preferences
        )
        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            snippetService: SnippetService(appSupportDirectory: appSupportDirectory),
            historyService: historyService,
            historySyncPreferences: preferences,
            defaults: defaults
        )
        let recordID = UUID()
        let notified = expectation(description: "Journal change notification")
        var observedDeletion = false
        let observerID = store.observeLocalChanges {
            observedDeletion = store.snapshot().deletedHistoryRecords.contains {
                $0.recordID == recordID
            }
            notified.fulfill()
        }
        defer { store.removeLocalChangeObserver(observerID) }

        preferences.recordExplicitDeletion(recordID)
        await fulfillment(of: [notified], timeout: 1)

        XCTAssertTrue(observedDeletion)
    }

    @MainActor
    func testHistorySyncPreferencesDefaultAudioOffAndPruneExpiredSuppressions() throws {
        let suiteName = "CloudFolderSyncHistoryPreferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expiredID = UUID()
        let expiredSuppressions = [
            expiredID.uuidString.lowercased(): Date().addingTimeInterval(-91 * 24 * 60 * 60),
        ]
        defaults.set(
            try JSONEncoder().encode(expiredSuppressions),
            forKey: "premiumSync.historySuppressedRecordIDs"
        )

        let preferences = HistorySyncPreferences(defaults: defaults)

        XCTAssertFalse(preferences.isAudioEnabled)
        XCTAssertFalse(preferences.isSuppressed(expiredID))
    }

    func testHistoryPayloadDecodingSanitizesForwardCompatibleValues() throws {
        let recordID = UUID()
        let content = UserDataSyncHistoryContentV1(
            recordID: recordID,
            createdAt: Self.date(1),
            updatedAt: Self.date(2),
            originDeviceID: "ios-origin",
            originPlatform: "iOS",
            source: "iPhone",
            processingState: "ready",
            rawTranscript: "Test",
            finalText: "Test",
            durationSeconds: 5,
            engineDisplayName: "test"
        )
        var contentJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any]
        )
        contentJSON["durationSeconds"] = -5
        let decodedContent = try JSONDecoder().decode(
            UserDataSyncHistoryContentV1.self,
            from: JSONSerialization.data(withJSONObject: contentJSON)
        )

        let inbox = UserDataSyncHistoryInboxV1(
            recordID: recordID,
            updatedAt: Self.date(2),
            state: "open",
            kind: nil,
            completionPolicy: .explicit,
            completedAt: nil,
            safeAction: nil
        )
        var inboxJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(inbox)) as? [String: Any]
        )
        inboxJSON["completionPolicy"] = "futurePolicy"
        let decodedInbox = try JSONDecoder().decode(
            UserDataSyncHistoryInboxV1.self,
            from: JSONSerialization.data(withJSONObject: inboxJSON)
        )
        let localRecord = UserDataSyncHistoryRecord(
            content: content,
            inbox: inbox,
            audio: nil,
            localAudioFileURL: URL(fileURLWithPath: "/private/local.wav"),
            audioEligible: true
        )
        let encodedRecord = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(localRecord)) as? [String: Any]
        )

        XCTAssertEqual(decodedContent.durationSeconds, 0)
        XCTAssertEqual(decodedInbox.completionPolicy, .explicit)
        XCTAssertNil(encodedRecord["localAudioFileURL"])
        XCTAssertNil(encodedRecord["audioEligible"])
    }

    @MainActor
    func testHostStoreExcludesManagedEntriesAndPreservesUserAuthoredData() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncHostStore")
        defer { TestSupport.remove(appSupportDirectory) }

        let suiteName = "CloudFolderSyncHostStore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        dictionaryService.addEntry(type: .term, original: "ManualTerm")
        dictionaryService.addEntry(type: .term, original: "ManagedTerm")
        dictionaryService.addEntry(type: .correction, original: "filler", replacement: "")
        snippetService.addSnippet(trigger: ";sig", replacement: "{date:yyyy}")
        _ = dictionaryService.applyCorrections(to: "filler")
        _ = snippetService.applySnippets(to: ";sig")

        let state = ActivatedTermPackState(
            packID: "managed-pack",
            source: "test",
            installedVersion: "1",
            installedTerms: ["ManagedTerm"],
            installedCorrections: [],
            requiresCommercialLicense: false
        )
        defaults.set(try JSONEncoder().encode([state]), forKey: UserDefaultsKeys.activatedTermPackStates)

        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            defaults: defaults
        )
        let snapshot = store.snapshot()

        XCTAssertEqual(snapshot.dictionaryEntries.filter { $0.original == "ManualTerm" }.count, 1)
        XCTAssertFalse(snapshot.dictionaryEntries.contains { $0.original == "ManagedTerm" })
        XCTAssertEqual(snapshot.dictionaryEntries.first { $0.original == "filler" }?.replacement, "")
        XCTAssertEqual(snapshot.snippets.first?.replacement, "{date:yyyy}")
    }

    @MainActor
    func testHostStorePreservesAutoLearnedDictionarySource() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncAutoLearnedSource")
        defer { TestSupport.remove(appSupportDirectory) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        dictionaryService.learnCorrection(original: "recieve", replacement: "receive")

        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionaryService,
            snippetService: snippetService
        )

        XCTAssertEqual(store.snapshot().dictionaryEntries.first?.source, .autoLearned)

        try store.apply([
            .upsertDictionary(Self.dictionaryEntry(
                entryType: .correction,
                original: "langauge",
                replacement: "language",
                source: .autoLearned,
                updatedAt: Self.date(30)
            ))
        ])

        XCTAssertEqual(
            dictionaryService.entries.first { $0.original == "langauge" }?.source,
            .autoLearned
        )
    }

    @MainActor
    func testDictionaryResetActionsKeepHostSnapshotConsistent() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncDictionaryReset")
        defer { TestSupport.remove(appSupportDirectory) }

        let suiteName = "CloudFolderSyncDictionaryReset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        dictionaryService.addEntry(type: .term, original: "ManualBeforeReset")
        dictionaryService.learnCorrection(original: "recieve", replacement: "receive")

        let viewModel = DictionaryViewModel(dictionaryService: dictionaryService, defaults: defaults)
        let pack = TermPack(
            id: "sync-reset-pack",
            name: "Sync Reset Pack",
            description: "Sync reset test pack",
            icon: "shippingbox",
            terms: ["ManagedPackTerm"],
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )
        viewModel.activatePack(pack)

        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            defaults: defaults
        )

        viewModel.requestReset(.resetCustomDictionary)
        viewModel.confirmReset()
        XCTAssertTrue(store.snapshot().dictionaryEntries.isEmpty)
        XCTAssertEqual(dictionaryService.entries.map(\.original), ["ManagedPackTerm"])

        dictionaryService.addEntry(type: .term, original: "ManualAfterReset")
        dictionaryService.learnCorrection(original: "langauge", replacement: "language")
        viewModel.requestReset(.deactivateAllTermPacks)
        viewModel.confirmReset()

        let snapshot = store.snapshot()
        XCTAssertEqual(Set(snapshot.dictionaryEntries.map(\.original)), ["ManualAfterReset", "langauge"])
        XCTAssertFalse(dictionaryService.entries.contains { $0.original == "ManagedPackTerm" })
        XCTAssertTrue(viewModel.activatedPackStates.isEmpty)
    }

    @MainActor
    func testHostApplyMergesDuplicateNaturalKeys() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncMerge")
        defer { TestSupport.remove(appSupportDirectory) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        dictionaryService.addEntry(type: .term, original: "TypeWhisper")
        snippetService.addSnippet(trigger: ";sig", replacement: "Old")

        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionaryService,
            snippetService: snippetService
        )

        try store.apply([
            .upsertDictionary(Self.dictionaryEntry(original: " typewhisper ", updatedAt: Self.date(30))),
            .upsertSnippet(Self.snippet(trigger: ";SIG", replacement: "New", updatedAt: Self.date(30)))
        ])

        let dictionaryMatches = dictionaryService.entries.filter {
            UserDataSyncIdentity.dictionaryItemID(entryType: $0.type, original: $0.original)
                == UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: "typewhisper")
        }
        let snippetMatches = snippetService.snippets.filter {
            UserDataSyncIdentity.snippetItemID(trigger: $0.trigger)
                == UserDataSyncIdentity.snippetItemID(trigger: ";sig")
        }

        XCTAssertEqual(dictionaryMatches.count, 1)
        XCTAssertEqual(dictionaryMatches.first?.original, " typewhisper ")
        XCTAssertEqual(snippetMatches.count, 1)
        XCTAssertEqual(snippetMatches.first?.replacement, "New")
    }

    @MainActor
    func testRegexIdentitiesAndVersionedOperationsMatchSharedFixtures() throws {
        struct Vector: Decodable { let pattern: String; let itemId: String }
        let vectors: [Vector] = try Self.decodeFixture("regex-dictionary-identities-v2")
        for vector in vectors {
            XCTAssertEqual(UserDataSyncIdentity.dictionaryItemID(
                entryType: UserDataSyncDictionaryEntryType.correction, original: vector.pattern, isRegex: true
            ), vector.itemId)
        }
        XCTAssertEqual(Set(vectors.map(\.itemId)).count, vectors.count)
        let operation: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v2")
        XCTAssertEqual(CloudFolderSyncEngine.winningOperations(from: [operation])[operation.itemId], operation)
        XCTAssertEqual(operation.schemaVersion, 2)
        let delete = CloudFolderSyncOperation.delete(collection: .dictionary, itemID: operation.itemId, deviceId: "mac", deletedAt: Self.date(30))
        XCTAssertEqual(delete.schemaVersion, 2)
        XCTAssertEqual(CloudFolderSyncEngine.winningOperations(from: [operation, delete])[operation.itemId]?.kind, .delete)
    }

    @MainActor
    func testRegexRulesSyncIndependentlyAndDeletingOneKeepsLiteralAndOtherPattern() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(folder) }
        let entries = [
            Self.dictionaryEntry(entryType: .correction, original: #"\d"#, replacement: "digit", updatedAt: Self.date(10), isRegex: true),
            Self.dictionaryEntry(entryType: .correction, original: #"\D"#, replacement: "other", updatedAt: Self.date(10), isRegex: true),
            Self.dictionaryEntry(entryType: .correction, original: #"\d"#, replacement: "literal", updatedAt: Self.date(10))
        ]
        let first = InMemoryUserDataSyncStore(dictionaryEntries: entries)
        let second = InMemoryUserDataSyncStore()
        var a = CloudFolderSyncState(deviceId: "mac")
        var b = CloudFolderSyncState(deviceId: "windows")
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: first, state: &a, now: Self.date(20))
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: second, state: &b, now: Self.date(30))
        XCTAssertEqual(second.dictionaryEntries.count, 3)
        second.dictionaryEntries.removeAll { $0.isRegex && $0.original == #"\D"# }
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: second, state: &b, now: Self.date(40))
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: first, state: &a, now: Self.date(50))
        XCTAssertEqual(first.dictionaryEntries.count, 2)
        XCTAssertTrue(first.dictionaryEntries.allSatisfy { $0.original == #"\d"# })
        XCTAssertEqual(first.dictionaryEntries.filter(\.isRegex).count, 1)
    }

    @MainActor
    func testUnencodedLegacyUpdatePreservesModeWithoutStealingCoexistingLiteral() async throws {
        for hasLiteral in [false, true] {
            let folder = try TestSupport.makeTemporaryDirectory()
            defer { TestSupport.remove(folder) }
            let regex = Self.dictionaryEntry(entryType: .correction, original: #"\d"#, replacement: "regex", updatedAt: Self.date(10), isRegex: true)
            let literal = Self.dictionaryEntry(entryType: .correction, original: #"\d"#, replacement: "literal", updatedAt: Self.date(10))
            let store = InMemoryUserDataSyncStore(dictionaryEntries: hasLiteral ? [regex, literal] : [regex])
            let legacyEntry = Self.dictionaryEntry(entryType: .correction, original: #"\d"#, replacement: "updated", updatedAt: Self.date(20), isRegexFieldPresent: false)
            let operation = CloudFolderSyncOperation.upsertDictionary(legacyEntry, itemID: #"dictionary:correction:\d"#, deviceId: "legacy")
            try Self.writeLegacyOperation(operation, to: folder)
            var state = CloudFolderSyncState(deviceId: "mac")
            _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state,
                now: Self.date(30))
            XCTAssertEqual(store.dictionaryEntries.count, hasLiteral ? 2 : 1)
            XCTAssertEqual(store.dictionaryEntries.first { $0.isRegex }?.replacement, hasLiteral ? "regex" : "updated")
            if hasLiteral { XCTAssertEqual(store.dictionaryEntries.first { !$0.isRegex }?.replacement, "updated") }
        }
    }

    @MainActor
    func testLegacyRegexModeIsPreservedAndRepublishedOnce() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(folder) }
        let entry = Self.dictionaryEntry(entryType: .correction, original: #"\d"#, replacement: "#", updatedAt: Self.date(10), isRegex: true)
        let store = InMemoryUserDataSyncStore(dictionaryEntries: [entry])
        let legacyEntry = Self.dictionaryEntry(entryType: .correction, original: #"\d"#, replacement: "new", updatedAt: Self.date(20), isRegexFieldPresent: false)
        let legacy = CloudFolderSyncOperation.upsertDictionary(legacyEntry, itemID: UserDataSyncIdentity.dictionaryItemID(
            entryType: legacyEntry.entryType, original: legacyEntry.original
        ), deviceId: "legacy", operationId: "legacy")
        try Self.writeLegacyOperation(legacy, to: folder)
        var state = CloudFolderSyncState(deviceId: "mac")
        let first = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(25))
        XCTAssertEqual(store.dictionaryEntries.count, 1)
        XCTAssertTrue(try XCTUnwrap(store.dictionaryEntries.first).isRegex)
        XCTAssertEqual(store.dictionaryEntries.first?.replacement, "new")
        XCTAssertTrue(first.requiresFollowUpSync)
        let republish = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(30))
        let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(35))
        XCTAssertEqual(republish.operationsWritten, 1)
        XCTAssertEqual(repeated.operationsWritten, 0)
    }

    @MainActor
    func testIncomingUnsupportedRegexDoesNotReplaceStoredCorrections() async throws {
        for schema in [1, 2] {
            for pattern in [#"(?<open>a)(?<-open>b)"#, ""] {
                let folder = try TestSupport.makeTemporaryDirectory()
                defer { TestSupport.remove(folder) }
                let dictionary = DictionaryService(appSupportDirectory: folder)
                dictionary.addEntry(type: .correction, original: "[", replacement: "literal")
                XCTAssertNil(try? NSRegularExpression(pattern: pattern))
                let invalid = Self.dictionaryEntry(entryType: .correction, original: pattern, replacement: "unsupported", updatedAt: Self.date(20), isRegex: true)
                let operation = CloudFolderSyncOperation.upsertDictionary(invalid,
                    itemID: UserDataSyncIdentity.dictionaryItemID(entryType: invalid.entryType, original: pattern, isRegex: schema == 2), deviceId: "windows")
                let remote = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/windows")
                try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
                var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.entitlementEncoder.encode(operation)) as? [String: Any])
                payload["schemaVersion"] = schema
                try JSONSerialization.data(withJSONObject: payload).write(to: remote.appendingPathComponent("unsupported.json"))
                let store = TypeWhisperUserDataSyncStore(dictionaryService: dictionary, snippetService: SnippetService(appSupportDirectory: folder))
                var state = CloudFolderSyncState(deviceId: "mac")
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(30))
                XCTAssertEqual(dictionary.entries.count, 1)
                XCTAssertEqual(dictionary.entries.first?.replacement, "literal")
                XCTAssertFalse(state.appliedOperationIDs.contains(operation.operationId))
                try dictionary.applyUserDataSyncMutations([.upsertDictionary(invalid)])
                XCTAssertEqual(dictionary.entries.count, 1)
            }
        }
    }

    @MainActor
    func testPreviouslyAppliedUnsupportedRegexDoesNotBlockUpgrade() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(folder) }
        let entry = Self.dictionaryEntry(entryType: .correction, original: "[", replacement: "old", updatedAt: Self.date(10), isRegex: true)
        let oldID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original)
        let operation = CloudFolderSyncOperation.upsertDictionary(entry, itemID: oldID, deviceId: "old")
        let remote = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/old")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.entitlementEncoder.encode(operation)) as? [String: Any])
        payload["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: payload).write(to: remote.appendingPathComponent("applied.json"))
        let snippet = Self.snippet(trigger: ";sig", replacement: "Changed", updatedAt: Self.date(20))
        let store = InMemoryUserDataSyncStore(dictionaryEntries: [entry], snippets: [snippet])
        var state = CloudFolderSyncState(deviceId: "mac", knownLocalItemIDs: [oldID],
            exportedItemVersions: [oldID: "dictionary-v2|2023-11-14T22:13:30.000Z"], appliedOperationIDs: [operation.operationId])
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(30))
        XCTAssertEqual(store.dictionaryEntries, [entry])
        let published = try Self.operationFiles(folder: folder, deviceId: "mac").map {
            try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
        }
        XCTAssertTrue(published.contains { $0.snippet == snippet })
        let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(40))
        XCTAssertEqual(repeated.operationsWritten, 0)
    }

    @MainActor
    func testRecoveryPreservesLocalModeChanges() async throws {
        for recovery in [false, true] {
            for previouslyRegex in [false, true] {
                let folder = try TestSupport.makeTemporaryDirectory()
                defer { TestSupport.remove(folder) }
                let previous = Self.dictionaryEntry(entryType: .correction, original: #"\d"#, replacement: "old",
                    updatedAt: Self.date(10), isRegex: previouslyRegex)
                let oldID = UserDataSyncIdentity.dictionaryItemID(entryType: previous.entryType, original: previous.original)
                let synced = CloudFolderSyncOperation.upsertDictionary(previous, itemID: oldID, deviceId: "mac", operationId: "own-rule")
                let peer = CloudFolderSyncOperation.upsertDictionary(previous, itemID: oldID, deviceId: "peer", operationId: "peer-republished-rule")
                let remote = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/peer")
                try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
                for operation in recovery ? [peer] : [peer, synced] {
                    var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.entitlementEncoder.encode(operation)) as? [String: Any])
                    payload["schemaVersion"] = 1
                    try JSONSerialization.data(withJSONObject: payload).write(to: remote.appendingPathComponent("\(operation.operationId).json"))
                }
                let regex = Self.dictionaryEntry(entryType: .correction, original: previous.original, replacement: "current",
                    updatedAt: Self.date(20), isRegex: true)
                let store = InMemoryUserDataSyncStore(dictionaryEntries: [regex])
                var state = CloudFolderSyncState(deviceId: "mac", knownLocalItemIDs: [oldID],
                    exportedItemVersions: [oldID: "dictionary-v2|2023-11-14T22:13:30.000Z"], appliedOperationIDs: [synced.operationId])
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(30))
                XCTAssertEqual(store.dictionaryEntries, [regex])
                let published = try Self.operationFiles(folder: folder, deviceId: "mac").map {
                    try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
                }
                XCTAssertEqual(published.contains { $0.kind == .delete && $0.itemId == oldID }, recovery || !previouslyRegex)
                XCTAssertTrue(published.contains { $0.schemaVersion == 2 && $0.dictionary == regex })
                let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(40))
                XCTAssertEqual(repeated.operationsWritten, 0)
                XCTAssertEqual(store.dictionaryEntries, [regex])
            }
        }
    }

    @MainActor
    func testLegacyModeChangeDoesNotRestoreSupersededRule() async throws {
        for latestIsRegex in [false, true] {
            for unencodedID in [false, true] {
                let folder = try TestSupport.makeTemporaryDirectory()
                defer { TestSupport.remove(folder) }
                let previous = Self.dictionaryEntry(entryType: .correction, original: #"\d"#, replacement: "old", updatedAt: Self.date(10), isRegex: !latestIsRegex)
                let current = Self.dictionaryEntry(entryType: .correction, original: previous.original, replacement: "current", updatedAt: Self.date(20), isRegex: latestIsRegex)
                let oldID = unencodedID ? #"dictionary:correction:\d"# : UserDataSyncIdentity.dictionaryItemID(entryType: previous.entryType, original: previous.original)
                let old = CloudFolderSyncOperation.upsertDictionary(previous, itemID: oldID, deviceId: "old", operationId: "previous")
                let newer = CloudFolderSyncOperation.upsertDictionary(current, itemID: oldID, deviceId: "old", operationId: "current")
                let remote = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/old")
                try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
                for operation in [old, newer] {
                    var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.entitlementEncoder.encode(operation)) as? [String: Any])
                    payload["schemaVersion"] = 1
                    try JSONSerialization.data(withJSONObject: payload).write(to: remote.appendingPathComponent("\(operation.operationId).json"))
                }
                let store = InMemoryUserDataSyncStore()
                var state = CloudFolderSyncState(deviceId: "mac")
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(30))
                XCTAssertEqual(store.dictionaryEntries, [current])
                XCTAssertTrue(state.appliedOperationIDs.contains(old.operationId))
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(40))
                try FileManager.default.removeItem(at: remote.appendingPathComponent("current.json"))
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(50))
                XCTAssertEqual(store.dictionaryEntries, [current])
            }
        }
    }

    @MainActor
    func testPackageRecoveryPreservesKnownLocalDeletions() async throws {
        for kind in ["snippet", "term", "literal", "exactRegex"] {
            let folder = try TestSupport.makeTemporaryDirectory()
            defer { TestSupport.remove(folder) }
            let local = Self.dictionaryEntry(entryType: .correction, original: "teh", replacement: "the", updatedAt: Self.date(10))
            let oldID = UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.correction, original: local.original)
            let removed: CloudFolderSyncOperation
            if kind == "snippet" {
                let snippet = Self.snippet(trigger: ";sig", replacement: "Signature", updatedAt: Self.date(10))
                removed = .upsertSnippet(snippet, itemID: UserDataSyncIdentity.snippetItemID(trigger: snippet.trigger), deviceId: "peer")
            } else {
                let entry = Self.dictionaryEntry(entryType: kind == "term" ? .term : .correction,
                    original: "removed", replacement: kind == "term" ? nil : "replacement", updatedAt: Self.date(10), isRegex: kind == "exactRegex")
                removed = .upsertDictionary(entry, itemID: UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original, isRegex: entry.isRegex), deviceId: "peer")
            }
            let remote = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/peer")
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            try Self.entitlementEncoder.encode(removed).write(to: remote.appendingPathComponent("recreated.json"))
            let store = InMemoryUserDataSyncStore(dictionaryEntries: [local])
            var state = CloudFolderSyncState(deviceId: "mac", knownLocalItemIDs: [oldID, removed.itemId],
                exportedItemVersions: [oldID: "dictionary-v2|2023-11-14T22:13:30.000Z", removed.itemId: "2023-11-14T22:13:30.000Z"],
                appliedOperationIDs: ["removed-local-upsert", "removed-peer-upsert"])
            _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(30))
            XCTAssertEqual(store.dictionaryEntries, [local])
            XCTAssertTrue(store.snippets.isEmpty)
            let published = try Self.operationFiles(folder: folder, deviceId: "mac").map {
                try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
            }
            XCTAssertTrue(published.contains { $0.kind == .delete && $0.itemId == removed.itemId })
            let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(40))
            XCTAssertEqual(repeated.operationsWritten, 0)
            XCTAssertEqual(store.dictionaryEntries, [local])
            XCTAssertTrue(store.snippets.isEmpty)
        }
    }

    @MainActor
    func testUpgradeUsesExportedCorrectionVersionDespiteClockSkew() async throws {
        for mode in ["literal", "regex", "misimportedRegex", "deletedRegex"] {
            let folder = try TestSupport.makeTemporaryDirectory()
            defer { TestSupport.remove(folder) }
            let entry = Self.dictionaryEntry(entryType: .correction, original: #"\d"#, replacement: "current", updatedAt: Self.date(10), isRegex: mode != "literal")
            let oldID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original)
            let current = CloudFolderSyncOperation.upsertDictionary(entry, itemID: oldID, deviceId: "old", operationId: "current-upsert")
            var oldEntry = Self.dictionaryEntry(entryType: .correction, original: entry.original, replacement: "old", updatedAt: Self.date(15))
            oldEntry = oldEntry.preservingRegexMode(mode == "literal")
            let old = CloudFolderSyncOperation.upsertDictionary(oldEntry, itemID: oldID, deviceId: "old", operationId: "older-upsert-future-clock")
            let deleted = CloudFolderSyncOperation.delete(collection: .dictionary, itemID: oldID, deviceId: "old", deletedAt: Self.date(20), operationId: "already-applied-delete")
            let remote = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/old")
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            for operation in [old, deleted, current] {
                var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.entitlementEncoder.encode(operation)) as? [String: Any])
                payload["schemaVersion"] = 1
                try JSONSerialization.data(withJSONObject: payload).write(to: remote.appendingPathComponent("\(operation.operationId).json"))
            }
            let local = mode == "misimportedRegex" ? entry.preservingRegexMode(false) : entry
            let store = InMemoryUserDataSyncStore(dictionaryEntries: mode == "deletedRegex" ? [] : [local])
            var state = CloudFolderSyncState(deviceId: "mac", knownLocalItemIDs: [oldID],
                exportedItemVersions: [oldID: "dictionary-v2|2023-11-14T22:13:30.000Z"],
                appliedOperationIDs: [old.operationId, deleted.operationId, current.operationId])
            _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(30))
            XCTAssertEqual(store.dictionaryEntries, mode == "deletedRegex" ? [] : [entry])
            let published = try Self.operationFiles(folder: folder, deviceId: "mac").map {
                try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
            }
            XCTAssertEqual(published.contains { $0.kind == .delete }, mode == "deletedRegex")
            if mode == "deletedRegex" { XCTAssertTrue(published.contains { $0.schemaVersion == 2 && $0.kind == .delete }) }
            let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(40))
            XCTAssertEqual(repeated.operationsWritten, 0)
        }
    }

    @MainActor
    func testUpgradeRebuildsMissingOrReplacedPackage() async throws {
        for package in ["missing", "empty", "replaced"] {
            for isRegex in [false, true] {
                let folder = try TestSupport.makeTemporaryDirectory()
                defer { TestSupport.remove(folder) }
                let entry = Self.dictionaryEntry(entryType: .correction, original: isRegex ? #"\d"# : "teh",
                    replacement: "fixed", updatedAt: Self.date(10), isRegex: isRegex)
                let snippet = Self.snippet(trigger: ";sig", replacement: "Signature", updatedAt: Self.date(10))
                let oldID = UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.correction, original: entry.original)
                let snippetID = UserDataSyncIdentity.snippetItemID(trigger: snippet.trigger)
                let operationsFolder = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops")
                if package != "missing" {
                    try FileManager.default.createDirectory(at: operationsFolder, withIntermediateDirectories: true)
                }
                if package == "replaced" {
                    let peer: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v2")
                    try Self.writeLegacyOperation(peer, to: folder)
                }
                let store = InMemoryUserDataSyncStore(dictionaryEntries: [entry], snippets: [snippet])
                var state = CloudFolderSyncState(deviceId: "mac", knownLocalItemIDs: [oldID, snippetID],
                    exportedItemVersions: [oldID: "dictionary-v2|2023-11-14T22:13:30.000Z", snippetID: "2023-11-14T22:13:30.000Z"],
                    appliedOperationIDs: ["removed-dictionary", "removed-snippet"])
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(30))
                let published = try Self.operationFiles(folder: folder, deviceId: "mac").map {
                    try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
                }
                XCTAssertEqual(published.count, 2)
                XCTAssertTrue(published.allSatisfy { $0.kind == .upsert })
                XCTAssertEqual(published.first { $0.dictionary != nil }?.schemaVersion, isRegex ? 2 : 1)
                XCTAssertTrue(published.contains { $0.snippet == snippet })
                XCTAssertTrue(store.dictionaryEntries.contains(entry))
                XCTAssertEqual(store.dictionaryEntries.count, package == "replaced" ? 2 : 1)
                for now in [Self.date(40), Self.date(50)] {
                    let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: now)
                    XCTAssertEqual(repeated.operationsWritten, 0)
                }
            }
        }
    }

    @MainActor
    func testRegexUpgradeIgnoresPrunedOperationsAndUnrelatedUnreadableFiles() async throws {
        for prefix in ["", "dictionary-v2|"] {
            for deleted in [false, true] {
                let folder = try TestSupport.makeTemporaryDirectory()
                defer { TestSupport.remove(folder) }
                let legacy: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v1")
                try Self.writeLegacyOperation(legacy, to: folder)
                let remote = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/\(legacy.deviceId)")
                try Data("{".utf8).write(to: remote.appendingPathComponent("unrelated-partial.json"))
                let history = CloudFolderSyncOperation.deleteHistory(recordID: UUID(), generation: "history-v1",
                    deviceId: legacy.deviceId, deletedAt: Self.date(5), operationId: "readable-history")
                try Self.entitlementEncoder.encode(history).write(to: remote.appendingPathComponent("history.json"))
                let entry = try XCTUnwrap(legacy.dictionary)
                let snippet = Self.snippet(trigger: ";sig", replacement: "Signature", updatedAt: Self.date(15))
                let store = InMemoryUserDataSyncStore(dictionaryEntries: deleted ? [] : [entry], snippets: [snippet])
                var state = CloudFolderSyncState(deviceId: "mac", knownLocalItemIDs: [legacy.itemId],
                    exportedItemVersions: [legacy.itemId: prefix + "2023-11-14T22:13:30.000Z"],
                    appliedOperationIDs: [legacy.operationId, history.operationId, "expired-dictionary-delete", "expired-snippet-delete", "expired-history-delete"])
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(30))
                let published = try Self.operationFiles(folder: folder, deviceId: "mac").map {
                    try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
                }
                let dictionaryOperations = published.filter { $0.collection == .dictionary }
                if deleted {
                    XCTAssertTrue(store.dictionaryEntries.isEmpty)
                    XCTAssertEqual(dictionaryOperations.count, 2)
                    XCTAssertTrue(dictionaryOperations.allSatisfy { $0.kind == .delete })
                    XCTAssertTrue(dictionaryOperations.contains { $0.schemaVersion == 2 })
                } else {
                    XCTAssertEqual(store.dictionaryEntries, [entry])
                    XCTAssertEqual(dictionaryOperations.count, 1)
                    XCTAssertEqual(dictionaryOperations.first?.schemaVersion, 2)
                    XCTAssertEqual(dictionaryOperations.first?.kind, .upsert)
                }
                XCTAssertTrue(published.contains { $0.snippet == snippet })
                for now in [Self.date(40), Self.date(50)] {
                    let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: now)
                    XCTAssertEqual(repeated.operationsWritten, 0)
                }
            }
        }
    }

    @MainActor
    func testIncompleteIgnoredEnvelopesBlockRecoveryUntilLegacyHistoryArrives() async throws {
        for category in ["history", "future"] {
            let defects = ["minimal", "schemaVersion", "operationId", "deviceId", "itemId", "collection", "kind", "updatedAt",
                "invalidSchema", "invalidDate", "blankId", "blankCollection", "blankKind", "invalidKind", "invalidCollection"]
                + (category == "history" ? ["unknownKind"] : [])
            for defect in defects {
                for deleted in [false, true] {
                    let context = "\(category)/\(defect)/deleted=\(deleted)"
                    let folder = try TestSupport.makeTemporaryDirectory()
                    defer { TestSupport.remove(folder) }
                    let legacy: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v1")
                    let entry = try XCTUnwrap(legacy.dictionary)
                    let directory = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/peer")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    var object = Self.ignoredOperationEnvelope(category: category)
                    switch defect {
                    case "minimal":
                        object = category == "history"
                            ? ["schemaVersion": 1, "collection": "history", "historyComponent": "summary"]
                            : ["schemaVersion": 3]
                    case "invalidSchema": object["schemaVersion"] = 0
                    case "invalidDate": object["updatedAt"] = "not-a-date"
                    case "blankId": object["operationId"] = " \n"
                    case "blankCollection": object["collection"] = " "
                    case "blankKind": object["kind"] = " "
                    case "invalidKind": object["kind"] = [String]()
                    case "invalidCollection": object["collection"] = [String]()
                    case "unknownKind": object["kind"] = "futureKind"
                    default: object.removeValue(forKey: defect)
                    }
                    try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("partial.json"))
                    let store = InMemoryUserDataSyncStore(dictionaryEntries: deleted ? [] : [Self.dictionaryEntry(
                        entryType: .correction, original: entry.original, replacement: "literal", updatedAt: Self.date(20))])
                    let snapshot = store.dictionaryEntries
                    var state = CloudFolderSyncState(deviceId: "mac", knownLocalItemIDs: [legacy.itemId],
                        exportedItemVersions: [legacy.itemId: "dictionary-v2|2023-11-14T22:13:30.000Z"],
                        appliedOperationIDs: [legacy.operationId])
                    let previousState = state
                    let cache = CloudFolderSyncCache()
                    do {
                        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state,
                            now: Self.date(30), cache: cache)
                        XCTFail("Incomplete envelope must postpone migration: \(context)")
                    } catch CloudFolderSyncError.incompleteMigrationHistory {
                        // The pending deletion or mode change still needs the legacy pattern identity.
                    }
                    XCTAssertEqual(state, previousState, context)
                    XCTAssertEqual(store.dictionaryEntries, snapshot, context)
                    XCTAssertTrue(store.appliedMutations.isEmpty, context)
                    XCTAssertTrue(Self.operationFiles(folder: folder, deviceId: "mac").isEmpty, context)

                    // Unrelated malformed files must not block once the required history arrives.
                    try Self.writeLegacyOperation(legacy, to: folder)
                    let recovered = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state,
                        now: Self.date(40), cache: cache)
                    XCTAssertEqual(recovered.diagnostics.map(\.kind), [.malformedOperation], context)
                    let published = try Self.operationFiles(folder: folder, deviceId: "mac").map {
                        try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
                    }
                    let regexID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original, isRegex: true)
                    XCTAssertTrue(published.contains { $0.schemaVersion == 2 && $0.kind == .delete && $0.itemId == regexID }, context)
                    XCTAssertEqual(store.dictionaryEntries, snapshot, context)
                    XCTAssertFalse(state.appliedOperationIDs.contains("ignored"), context)
                    let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state,
                        now: Self.date(50), cache: cache)
                    XCTAssertEqual(repeated.operationsWritten, 0, context)
                }
            }
        }
    }

    @MainActor
    func testCompleteIgnoredEnvelopesAllowPackageRecovery() async throws {
        for category in ["history", "future", "future-unknown", "future-numeric"] {
            for updatedAt in ["2023-11-14T22:13:25Z", "2023-11-14T22:13:25.000Z"] {
                let folder = try TestSupport.makeTemporaryDirectory()
                defer { TestSupport.remove(folder) }
                let legacy: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v1")
                let entry = try XCTUnwrap(legacy.dictionary)
                let directory = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/peer")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var object = Self.ignoredOperationEnvelope(category: category)
                object["updatedAt"] = updatedAt
                try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("ignored.json"))
                let store = InMemoryUserDataSyncStore(dictionaryEntries: [entry])
                var state = CloudFolderSyncState(deviceId: "mac", knownLocalItemIDs: [legacy.itemId],
                    exportedItemVersions: [legacy.itemId: "dictionary-v2|2023-11-14T22:13:30.000Z"],
                    appliedOperationIDs: [legacy.operationId])
                let recovered = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state,
                    now: Self.date(30))
                XCTAssertEqual(recovered.operationsWritten, 1, category)
                XCTAssertEqual(recovered.diagnostics.map(\.kind), category == "history" ? [] : [.unsupportedSchema], category)
                let published = try Self.operationFiles(folder: folder, deviceId: "mac").map {
                    try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
                }
                XCTAssertEqual(published.count, 1, category)
                XCTAssertEqual(published.first?.schemaVersion, 2, category)
                XCTAssertEqual(published.first?.kind, .upsert, category)
                XCTAssertEqual(store.dictionaryEntries, [entry], category)
                XCTAssertFalse(state.appliedOperationIDs.contains("ignored"), category)
                let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state,
                    now: Self.date(40))
                XCTAssertEqual(repeated.operationsWritten, 0, category)
            }
        }
    }

    @MainActor
    func testRegexUpgradeWaitsForAppliedLegacyFilesBeforeChangingDataOrState() async throws {
        for mode in ["regex", "deleted", "misimportedLiteral", "missingFile", "onlyPartial"] {
            let folder = try TestSupport.makeTemporaryDirectory()
            defer { TestSupport.remove(folder) }
            let legacy: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v1")
            let entry = try XCTUnwrap(legacy.dictionary)
            try Self.writeLegacyOperation(legacy, to: folder)
            let operationsFolder = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops")
            let legacyFile = operationsFolder.appendingPathComponent("\(legacy.deviceId)/legacy.json")
            let data = try Data(contentsOf: legacyFile)
            if mode == "missingFile" {
                try FileManager.default.removeItem(at: legacyFile)
            } else {
                try Data("{".utf8).write(to: legacyFile)
            }
            // An older readable literal must not be mistaken for the latest applied mode.
            let older = CloudFolderSyncOperation.upsertDictionary(
                Self.dictionaryEntry(entryType: .correction, original: entry.original, replacement: "old", updatedAt: Self.date(5)),
                itemID: legacy.itemId, deviceId: "old-peer", operationId: "older-literal")
            if mode != "onlyPartial" { try Self.writeLegacyOperation(older, to: folder) }
            try FileManager.default.createDirectory(at: operationsFolder.appendingPathComponent("mac"), withIntermediateDirectories: true)
            let store = InMemoryUserDataSyncStore(dictionaryEntries: mode == "deleted" ? []
                : [mode == "misimportedLiteral" ? entry.preservingRegexMode(false) : entry])
            let snapshot = store.dictionaryEntries
            var state = CloudFolderSyncState(deviceId: "mac", knownLocalItemIDs: [legacy.itemId],
                exportedItemVersions: [legacy.itemId: "dictionary-v2|2023-11-14T22:13:30.000Z"],
                appliedOperationIDs: [legacy.operationId, older.operationId])
            let previousState = state
            do {
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(20))
                XCTFail("Migration must wait for the applied operation to become readable")
            } catch CloudFolderSyncError.incompleteMigrationHistory {
                XCTAssertEqual(state.knownLocalItemIDs, previousState.knownLocalItemIDs)
                XCTAssertEqual(state.exportedItemVersions, previousState.exportedItemVersions)
                XCTAssertEqual(state.appliedOperationIDs, previousState.appliedOperationIDs)
            } catch {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(store.dictionaryEntries, snapshot)
            XCTAssertTrue(Self.operationFiles(folder: folder, deviceId: "mac").isEmpty)
            try data.write(to: legacyFile)
            // Unrelated partial files are harmless once the applied history is readable.
            try Data("{".utf8).write(to: legacyFile.deletingLastPathComponent().appendingPathComponent("unapplied-partial.json"))
            _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(30))
            let published = try Self.operationFiles(folder: folder, deviceId: "mac").map {
                try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
            }
            if mode == "deleted" {
                XCTAssertTrue(store.dictionaryEntries.isEmpty)
                XCTAssertTrue(published.contains { $0.schemaVersion == 2 && $0.kind == .delete })
            } else {
                XCTAssertTrue(try XCTUnwrap(store.dictionaryEntries.first).isRegex)
                XCTAssertEqual(published.count, 1)
                XCTAssertTrue(published.allSatisfy { $0.schemaVersion == 2 && $0.kind == .upsert })
            }
            let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(40))
            XCTAssertEqual(repeated.operationsWritten, 0)
        }
    }

    @MainActor
    func testMigratedRegexEditsDoNotRepublishBecauseOfOldOperationFiles() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(folder) }
        let legacy: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v1")
        try Self.writeLegacyOperation(legacy, to: folder)
        let store = InMemoryUserDataSyncStore()
        var state = CloudFolderSyncState(deviceId: "mac")
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(20))
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(25))
        let updated = Self.dictionaryEntry(entryType: .correction, original: try XCTUnwrap(legacy.dictionary).original,
            replacement: "edited", updatedAt: Self.date(30), isRegex: true)
        let operation = CloudFolderSyncOperation.upsertDictionary(updated,
            itemID: UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.correction, original: updated.original, isRegex: true), deviceId: "peer")
        try Self.writeLegacyOperation(operation, to: folder)
        let received = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(40))
        XCTAssertEqual(store.dictionaryEntries.first?.replacement, "edited")
        XCTAssertFalse(received.requiresFollowUpSync)
        let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(50))
        XCTAssertEqual(repeated.operationsWritten, 0)
    }

    @MainActor
    func testLiteralToRegexBeforeFirstUpgradeSyncDeletesTheOldLiteral() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(folder) }
        let entry = Self.dictionaryEntry(entryType: .correction, original: "foo", replacement: "bar", updatedAt: Self.date(10))
        let oldID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original)
        let legacy = CloudFolderSyncOperation.upsertDictionary(entry, itemID: oldID, deviceId: "legacy", operationId: "old-literal")
        try Self.writeLegacyOperation(legacy, to: folder)
        func oldState(_ device: String) -> CloudFolderSyncState {
            CloudFolderSyncState(deviceId: device, knownLocalItemIDs: [oldID],
                exportedItemVersions: [oldID: "dictionary-v2|2023-11-14T22:13:30.000Z"], appliedOperationIDs: [legacy.operationId])
        }
        var a = oldState("a")
        var b = oldState("b")
        let first = InMemoryUserDataSyncStore(dictionaryEntries: [entry])
        let changed = InMemoryUserDataSyncStore(dictionaryEntries: [Self.dictionaryEntry(
            entryType: .correction, original: "foo", replacement: "bar", updatedAt: Self.date(20), isRegex: true)])
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: first, state: &a, now: Self.date(30))
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: changed, state: &b, now: Self.date(40))
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: first, state: &a, now: Self.date(50))
        for store in [first, changed] {
            XCTAssertEqual(store.dictionaryEntries.count, 1)
            XCTAssertTrue(try XCTUnwrap(store.dictionaryEntries.first).isRegex)
        }
        let published = try Self.operationFiles(folder: folder, deviceId: "b").map {
            try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
        }
        XCTAssertTrue(published.contains { $0.kind == .delete && $0.itemId == oldID && $0.schemaVersion == 1 })
    }

    @MainActor
    func testRemovingRegexBeforeFirstUpgradeSyncDeletesItsMigratedIdentity() async throws {
        for (renamePattern, laterLegacyDelete, convertToLiteral) in [(false, false, false), (true, false, false), (false, true, false), (false, false, true)] {
            let folder = try TestSupport.makeTemporaryDirectory()
            defer { TestSupport.remove(folder) }
            let legacy: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v1")
            let entry = try XCTUnwrap(legacy.dictionary)
            try Self.writeLegacyOperation(legacy, to: folder)
            func oldState(_ device: String) -> CloudFolderSyncState {
                CloudFolderSyncState(deviceId: device, knownLocalItemIDs: [legacy.itemId],
                    exportedItemVersions: [legacy.itemId: "dictionary-v2|2023-11-14T22:13:30.000Z"], appliedOperationIDs: [legacy.operationId])
            }
            var a = oldState("a")
            var b = oldState("b")
            let first = InMemoryUserDataSyncStore(dictionaryEntries: [entry])
            let removed = InMemoryUserDataSyncStore(dictionaryEntries: renamePattern ? [Self.dictionaryEntry(
                entryType: .correction, original: #"\D+"#, replacement: "#", updatedAt: Self.date(35), isRegex: true)]
                : convertToLiteral ? [Self.dictionaryEntry(entryType: .correction, original: entry.original,
                    replacement: entry.replacement, updatedAt: Self.date(35))] : [])
            _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: first, state: &a, now: Self.date(30))
            if laterLegacyDelete {
                let deletion = CloudFolderSyncOperation.delete(collection: .dictionary, itemID: legacy.itemId, deviceId: "old-peer", deletedAt: Self.date(35))
                let path = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/\(legacy.deviceId)/other-delete.json")
                try Self.entitlementEncoder.encode(deletion).write(to: path)
            }
            _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: removed, state: &b, now: Self.date(40))
            _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: first, state: &a, now: Self.date(50))
            for store in [first, removed] {
                XCTAssertFalse(store.dictionaryEntries.contains { $0.isRegex && $0.original == entry.original })
                XCTAssertEqual(store.dictionaryEntries.count, renamePattern || convertToLiteral ? 1 : 0)
                if renamePattern { XCTAssertEqual(store.dictionaryEntries.first?.original, #"\D+"#) }
                if convertToLiteral { XCTAssertFalse(try XCTUnwrap(store.dictionaryEntries.first).isRegex) }
            }
            let rawID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original, isRegex: true)
            let published = try Self.operationFiles(folder: folder, deviceId: "b").map {
                try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
            }
            XCTAssertEqual(published.contains { $0.kind == .delete && $0.itemId == legacy.itemId && $0.schemaVersion == 1 }, !convertToLiteral)
            XCTAssertTrue(published.contains { $0.kind == .delete && $0.itemId == rawID && $0.schemaVersion == 2 })
            let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: removed, state: &b, now: Self.date(60))
            XCTAssertEqual(repeated.operationsWritten, 0)
        }
    }

    @MainActor
    func testUpgradeRestoresAlreadyAppliedWindowsRegexBeforePublishing() async throws {
        for deviceID in ["aaa-mac", "zzz-mac"] {
            let folder = try TestSupport.makeTemporaryDirectory()
            defer { TestSupport.remove(folder) }
            let legacy: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v1")
            let regex = try XCTUnwrap(legacy.dictionary)
            try Self.writeLegacyOperation(legacy, to: folder)
            if deviceID == "zzz-mac" {
                let migrated: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v2")
                let peerFolder = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/upgraded-peer")
                try FileManager.default.createDirectory(at: peerFolder, withIntermediateDirectories: true)
                try Self.entitlementEncoder.encode(migrated).write(to: peerFolder.appendingPathComponent("v2.json"))
            }
            let dictionary = DictionaryService(appSupportDirectory: folder.appendingPathComponent("dictionary"))
            try dictionary.applyUserDataSyncMutations([.upsertDictionary(regex.preservingRegexMode(false))])
            let oldEntry = try XCTUnwrap(dictionary.corrections.first)
            oldEntry.usageCount = 7
            let oldUUID = oldEntry.id
            let store = TypeWhisperUserDataSyncStore(dictionaryService: dictionary,
                snippetService: SnippetService(appSupportDirectory: folder.appendingPathComponent("snippets")))
            var state = CloudFolderSyncState(deviceId: deviceID, knownLocalItemIDs: [legacy.itemId],
                exportedItemVersions: [legacy.itemId: "dictionary-v2|2023-11-14T22:13:30.000Z"],
                appliedOperationIDs: [legacy.operationId])
            _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state,
                now: Self.date(30))
            XCTAssertEqual(dictionary.corrections.count, 1)
            XCTAssertTrue(try XCTUnwrap(dictionary.corrections.first).isRegex)
            XCTAssertEqual(dictionary.corrections.first?.id, oldUUID)
            XCTAssertEqual(dictionary.corrections.first?.usageCount, 7)
            let published = try Self.operationFiles(folder: folder, deviceId: deviceID).map {
                try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
            }
            XCTAssertEqual(published.count, 1)
            XCTAssertTrue(published.allSatisfy { $0.schemaVersion == 2 && $0.kind == .upsert && $0.dictionary?.isRegex == true })
            XCTAssertFalse(state.knownLocalItemIDs.contains(legacy.itemId))
            let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state,
                now: Self.date(40))
            XCTAssertEqual(repeated.operationsWritten, 0)

            dictionary.addEntry(type: .correction, original: regex.original, replacement: "literal")
            _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state,
                now: Self.date(50))
            dictionary.deleteEntry(try XCTUnwrap(dictionary.corrections.first { !$0.isRegex }))
            _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state,
                now: Self.date(60))
            let allOperations = try Self.operationFiles(folder: folder, deviceId: deviceID).map {
                try Self.fixtureDecoder.decode(CloudFolderSyncOperation.self, from: Data(contentsOf: $0))
            }
            XCTAssertTrue(allOperations.contains { $0.kind == .delete && $0.itemId == legacy.itemId })
            XCTAssertEqual(dictionary.corrections.count, 1)
        }
    }

    @MainActor
    func testUpgradeKeepsLocallyEditedLegacyLiteral() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(folder) }
        let legacy: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v1")
        try Self.writeLegacyOperation(legacy, to: folder)
        let literal = Self.dictionaryEntry(entryType: .correction, original: #"\d+"#,
            replacement: "edited", updatedAt: Self.date(20))
        let store = InMemoryUserDataSyncStore(dictionaryEntries: [literal])
        var state = CloudFolderSyncState(deviceId: "mac", knownLocalItemIDs: [legacy.itemId],
            exportedItemVersions: [legacy.itemId: "dictionary-v2|2023-11-14T22:13:30.000Z"],
            appliedOperationIDs: [legacy.operationId])
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state,
            now: Self.date(30))
        XCTAssertEqual(store.dictionaryEntries, [literal])
    }

    @MainActor
    func testSchemaOneRawRegexPrefixTombstoneNeverDeletesSchemaTwoRegex() async throws {
        for hasLocalEntries in [false, true] {
            for hasLegacyUpsert in [false, true] {
                let folder = try TestSupport.makeTemporaryDirectory()
                defer { TestSupport.remove(folder) }
                let regex = Self.dictionaryEntry(entryType: .correction, original: #"\d+"#, replacement: "regex", updatedAt: Self.date(20), isRegex: true)
                let regexID = UserDataSyncIdentity.dictionaryItemID(entryType: regex.entryType, original: regex.original, isRegex: true)
                let literal = Self.dictionaryEntry(entryType: .correction, original: String(regexID.dropFirst("dictionary:correction:".count)), replacement: "literal", updatedAt: Self.date(10))
                let directory = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/legacy")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if hasLegacyUpsert {
                    let upsert = CloudFolderSyncOperation.upsertDictionary(literal, itemID: regexID, deviceId: "legacy", operationId: "raw-literal")
                    try Self.entitlementEncoder.encode(upsert).write(to: directory.appendingPathComponent("literal.json"))
                }
                let deletion = CloudFolderSyncOperation.delete(collection: .dictionary, itemID: regexID, deviceId: "legacy", deletedAt: Self.date(30))
                var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.entitlementEncoder.encode(deletion)) as? [String: Any])
                raw["schemaVersion"] = 1
                try JSONSerialization.data(withJSONObject: raw).write(to: directory.appendingPathComponent("delete-literal.json"))
                let upsert = CloudFolderSyncOperation.upsertDictionary(regex, itemID: regexID, deviceId: "modern")
                try Self.entitlementEncoder.encode(upsert).write(to: directory.appendingPathComponent("regex.json"))
                let store = InMemoryUserDataSyncStore(dictionaryEntries: hasLocalEntries ? [literal, regex] : [])
                var state = CloudFolderSyncState(deviceId: "mac")
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(35))
                XCTAssertEqual(store.dictionaryEntries, [regex])
                // A first-time exporter can still publish its deleted local literal's
                // tombstone on the next sync. Check that publication then settles.
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(40))
                let repeated = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(42))
                XCTAssertEqual(repeated.operationsWritten, 0)
                let newcomer = InMemoryUserDataSyncStore()
                var newcomerState = CloudFolderSyncState(deviceId: "newcomer")
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: newcomer, state: &newcomerState, now: Self.date(45))
                XCTAssertEqual(newcomer.dictionaryEntries, [regex])
                let exactDelete = CloudFolderSyncOperation.delete(collection: .dictionary, itemID: regexID, deviceId: "modern", deletedAt: Self.date(50))
                try Self.entitlementEncoder.encode(exactDelete).write(to: directory.appendingPathComponent("delete-regex.json"))
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(60))
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: newcomer, state: &newcomerState, now: Self.date(65))
                XCTAssertTrue(store.dictionaryEntries.isEmpty)
                XCTAssertTrue(newcomer.dictionaryEntries.isEmpty)
                let afterDeletion = InMemoryUserDataSyncStore()
                var afterDeletionState = CloudFolderSyncState(deviceId: "after-deletion")
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: afterDeletion, state: &afterDeletionState, now: Self.date(70))
                XCTAssertTrue(afterDeletion.dictionaryEntries.isEmpty)
            }
        }
    }

    @MainActor
    func testSupersededUppercaseLegacyUpsertsStillSupplyDeletionAliases() async throws {
        for entryType in [UserDataSyncDictionaryEntryType.correction, .term] {
            for hasLocalEntry in [false, true] {
                let folder = try TestSupport.makeTemporaryDirectory()
                defer { TestSupport.remove(folder) }
                let entry = Self.dictionaryEntry(entryType: entryType, original: "TEH", replacement: entryType == .correction ? "the" : nil, updatedAt: Self.date(10))
                let rawID = "dictionary:\(entryType.rawValue):TEH"
                let upsert = CloudFolderSyncOperation.upsertDictionary(entry, itemID: rawID, deviceId: "legacy", operationId: "uppercase-upsert")
                try Self.writeLegacyOperation(upsert, to: folder)
                let deletion = CloudFolderSyncOperation.delete(collection: .dictionary, itemID: rawID, deviceId: "legacy", deletedAt: Self.date(20))
                let deletionURL = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/legacy/delete.json")
                try Self.entitlementEncoder.encode(deletion).write(to: deletionURL)
                let store = InMemoryUserDataSyncStore(dictionaryEntries: hasLocalEntry ? [entry] : [])
                var state = CloudFolderSyncState(deviceId: "mac")
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(30))
                XCTAssertTrue(store.dictionaryEntries.isEmpty)
                XCTAssertTrue(state.appliedOperationIDs.contains(upsert.operationId))
                try FileManager.default.removeItem(at: deletionURL)
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(40))
                XCTAssertTrue(store.dictionaryEntries.isEmpty)
            }
        }
    }

    @MainActor
    func testUnencodedLegacyLiteralTombstonesDoNotResurrectEntries() async throws {
        for entryType in [UserDataSyncDictionaryEntryType.correction, .term] {
            for hasLocalEntry in [false, true] {
                let folder = try TestSupport.makeTemporaryDirectory()
                defer { TestSupport.remove(folder) }
                let entry = Self.dictionaryEntry(entryType: entryType, original: "recieve", replacement: "receive", updatedAt: Self.date(10))
                let rawID = "dictionary:\(entryType.rawValue):recieve"
                let upsert = CloudFolderSyncOperation.upsertDictionary(entry, itemID: rawID, deviceId: "legacy", operationId: "old-upsert")
                try Self.writeLegacyOperation(upsert, to: folder)
                let deletion = CloudFolderSyncOperation.delete(collection: .dictionary, itemID: rawID, deviceId: "legacy", deletedAt: Self.date(20))
                let deletionURL = CloudFolderSyncEngine.packageURL(for: folder).appendingPathComponent("ops/legacy/delete.json")
                try Self.entitlementEncoder.encode(deletion).write(to: deletionURL)
                let store = InMemoryUserDataSyncStore(dictionaryEntries: hasLocalEntry ? [entry] : [])
                var state = CloudFolderSyncState(deviceId: "mac")
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(30))
                XCTAssertTrue(store.dictionaryEntries.isEmpty)
                XCTAssertTrue(state.appliedOperationIDs.contains(upsert.operationId))
                try FileManager.default.removeItem(at: deletionURL)
                _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: store, state: &state, now: Self.date(40))
                XCTAssertTrue(store.dictionaryEntries.isEmpty)
            }
        }
    }

    @MainActor
    func testLegacyTombstoneSuppressesLegacyRegexWithoutDeletingMigratedRule() throws {
        var legacy: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v1")
        let oldID = legacy.itemId
        let rawID = UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.correction, original: #"\d+"#, isRegex: true)
        let oldDelete = CloudFolderSyncOperation.delete(collection: .dictionary, itemID: oldID, deviceId: "old", deletedAt: Self.date(90))
        let winners = CloudFolderSyncEngine.winningOperations(from: [legacy, oldDelete])
        XCTAssertNil(winners[rawID])
        XCTAssertEqual(winners[oldID]?.kind, .delete)
        var unencodedLegacy = legacy
        unencodedLegacy.itemId = #"dictionary:correction:\d+"#
        let unencodedDelete = CloudFolderSyncOperation.delete(collection: .dictionary, itemID: unencodedLegacy.itemId, deviceId: "old", deletedAt: Self.date(90))
        XCTAssertNil(CloudFolderSyncEngine.winningOperations(from: [unencodedLegacy, unencodedDelete])[rawID])
        let migrated: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-regex-v2")
        XCTAssertEqual(CloudFolderSyncEngine.winningOperations(from: [legacy, migrated, oldDelete])[rawID]?.kind, .upsert)
        legacy.itemId = rawID
        let rawDelete = CloudFolderSyncOperation.delete(collection: .dictionary, itemID: rawID, deviceId: "new", deletedAt: Self.date(90))
        XCTAssertEqual(CloudFolderSyncEngine.winningOperations(from: [legacy, rawDelete])[rawID]?.kind, .delete)
    }

    private static func dictionaryEntry(
        entryType: UserDataSyncDictionaryEntryType = .term,
        original: String,
        replacement: String? = nil,
        source: DictionaryEntrySource? = nil,
        updatedAt: Date,
        ctcMinSimilarity: Float? = nil,
        ctcMinSimilarityFieldPresent: Bool? = nil,
        isRegex: Bool = false,
        isRegexFieldPresent: Bool? = nil
    ) -> UserDataSyncDictionaryEntry {
        UserDataSyncDictionaryEntry(
            entryType: entryType,
            original: original,
            replacement: replacement,
            caseSensitive: false,
            isEnabled: true,
            isRegex: isRegex,
            isRegexFieldPresent: isRegexFieldPresent,
            source: source,
            ctcMinSimilarity: ctcMinSimilarity,
            ctcMinSimilarityFieldPresent:
                ctcMinSimilarityFieldPresent,
            createdAt: date(1),
            updatedAt: updatedAt
        )
    }

    private static func ignoredOperationEnvelope(category: String) -> [String: Any] {
        let history = category == "history"
        var object: [String: Any] = [
            "schemaVersion": history ? 1 : 3,
            "operationId": "ignored", "deviceId": "peer", "itemId": "history:00000000-0000-0000-0000-000000000001",
            "collection": history ? "history" : "dictionary", "kind": "upsert", "updatedAt": "2023-11-14T22:13:25Z",
        ]
        if history {
            object["historyPayloadVersion"] = 1
            object["historyGeneration"] = "history-v1"
            object["historyComponent"] = "summary"
            object["historySummary"] = ["recordID": "00000000-0000-0000-0000-000000000001", "text": "Summary"]
        } else if category == "future-unknown" {
            object["collection"] = "futureCollection"
            object["kind"] = "futureKind"
        } else if category == "future-numeric" {
            object["collection"] = 17
            object["kind"] = 23
        }
        return object
    }

    private static func writeLegacyOperation(
        _ operation: CloudFolderSyncOperation,
        to folder: URL
    ) throws {
        let directory = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent(
                "ops/\(operation.deviceId)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoded = try entitlementEncoder.encode(operation)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var dictionary = try XCTUnwrap(
            object["dictionary"] as? [String: Any]
        )
        dictionary.removeValue(forKey: "ctcMinSimilarity")
        object["dictionary"] = dictionary
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: directory.appendingPathComponent("legacy.json"),
            options: [.atomic]
        )
    }

    private static func snippet(
        trigger: String,
        replacement: String,
        updatedAt: Date
    ) -> UserDataSyncSnippet {
        UserDataSyncSnippet(
            trigger: trigger,
            replacement: replacement,
            caseSensitive: false,
            isEnabled: true,
            createdAt: date(1),
            updatedAt: updatedAt
        )
    }

    private static func historyRecord(
        recordID: UUID,
        finalText: String,
        contentUpdatedAt: Date,
        inboxState: String,
        inboxUpdatedAt: Date
    ) -> UserDataSyncHistoryRecord {
        UserDataSyncHistoryRecord(
            content: UserDataSyncHistoryContentV1(
                recordID: recordID,
                createdAt: date(1),
                updatedAt: contentUpdatedAt,
                originDeviceID: "watch-origin",
                originPlatform: "watchOS",
                source: "appleWatch",
                processingState: "ready",
                rawTranscript: finalText,
                finalText: finalText,
                durationSeconds: 4,
                detectedLanguage: "en",
                engineDisplayName: "Apple Speech"
            ),
            inbox: UserDataSyncHistoryInboxV1(
                recordID: recordID,
                updatedAt: inboxUpdatedAt,
                state: inboxState,
                kind: "watchRecording",
                completionPolicy: .onOpen,
                completedAt: nil,
                safeAction: nil
            ),
            audio: nil,
            localAudioFileURL: nil,
            audioEligible: false
        )
    }

    @MainActor
    private static func makeAutomaticSyncController(
        suiteName: String,
        defaults: UserDefaults,
        folder: URL,
        store: InMemoryUserDataSyncStore
    ) throws -> CloudFolderSyncController {
        defaults.set(PremiumSyncMode.automaticICloud.rawValue, forKey: "premiumSync.mode")
        return CloudFolderSyncController(
            syncStore: store,
            defaults: defaults,
            automaticICloudBridge: RecordingPremiumICloudBridge(localFolderURL: folder),
            automaticICloudAvailable: true
        )
    }

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    private static func makeBridgeRoots() throws -> (local: URL, remote: URL) {
        (
            try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeLocal"),
            try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeRemote")
        )
    }

    private static func bridgeFileURL(_ path: String, in root: URL) -> URL {
        root.appendingPathComponent("dictum-sync", isDirectory: true)
            .appendingPathComponent(path)
    }

    private static func bridgeFileExists(_ path: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: bridgeFileURL(path, in: root).path)
    }

    private static func writeBridgeFile(
        _ path: String,
        in root: URL,
        contents: String? = nil,
        seconds: TimeInterval
    ) throws {
        let file = bridgeFileURL(path, in: root)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data((contents ?? path).utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: date(seconds)],
            ofItemAtPath: file.path
        )
    }

    private static func operationFiles(folder: URL, deviceId: String) -> [URL] {
        let directory = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("ops", isDirectory: true)
            .appendingPathComponent(deviceId, isDirectory: true)

        return (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func decodeFixture<T: Decodable>(_ name: String) throws -> T {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PremiumSync/\(name).json")
        return try fixtureDecoder.decode(T.self, from: Data(contentsOf: fixtureURL))
    }

    private static let fixtureDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: value))
            }
            return date
        }
        return decoder
    }()

    private static let entitlementEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }()

    private static let stateEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let stateDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// A failing background sync is announced once, and again after a sync succeeded.
final class SyncErrorAnnouncementFilterTests: XCTestCase {
    func testRepeatedErrorIsAnnouncedOnceUntilASyncSucceeds() {
        var filter = SyncErrorAnnouncementFilter()

        XCTAssertTrue(filter.shouldAnnounce("The network connection was lost."))
        // Each retry clears the error first; the same failure is not repeated.
        XCTAssertFalse(filter.shouldAnnounce(nil))
        XCTAssertFalse(filter.shouldAnnounce("The network connection was lost."))
        XCTAssertTrue(filter.shouldAnnounce("The sync folder is not available."))

        // After a successful sync the same failure is new again.
        filter.reset()
        XCTAssertTrue(filter.shouldAnnounce("The sync folder is not available."))
    }
}
