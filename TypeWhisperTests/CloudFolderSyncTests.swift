import XCTest
@testable import TypeWhisper

@MainActor
// @unchecked Sendable is safe here because @MainActor serializes all access in tests,
// so there are no concurrent cross-thread mutations. Revisit this if the store
// gains nonisolated mutable state or loses MainActor isolation.
private final class InMemoryUserDataSyncStore: UserDataSyncStore, @unchecked Sendable {
    var dictionaryEntries: [UserDataSyncDictionaryEntry]
    var snippets: [UserDataSyncSnippet]
    var appliedMutations: [UserDataSyncMutation] = []
    private var observers: [UUID: @MainActor @Sendable () -> Void] = [:]

    init(
        dictionaryEntries: [UserDataSyncDictionaryEntry] = [],
        snippets: [UserDataSyncSnippet] = []
    ) {
        self.dictionaryEntries = dictionaryEntries
        self.snippets = snippets
    }

    func snapshot() -> UserDataSyncSnapshot {
        UserDataSyncSnapshot(dictionaryEntries: dictionaryEntries, snippets: snippets)
    }

    func apply(_ mutations: [UserDataSyncMutation]) throws {
        appliedMutations.append(contentsOf: mutations)

        for mutation in mutations {
            switch mutation {
            case .upsertDictionary(let entry):
                let itemID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original)
                dictionaryEntries.removeAll {
                    UserDataSyncIdentity.dictionaryItemID(entryType: $0.entryType, original: $0.original) == itemID
                }
                dictionaryEntries.append(entry)
            case .deleteDictionary(let itemID):
                dictionaryEntries.removeAll {
                    UserDataSyncIdentity.dictionaryItemID(entryType: $0.entryType, original: $0.original) == itemID
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
            }
        }
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
}

final class CloudFolderSyncTests: XCTestCase {
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
    func testUnpaidSyncDoesNotCreateFiles() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncUnpaid")
        defer { TestSupport.remove(folder) }

        let store = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(10))
        ])
        var state = CloudFolderSyncState(deviceId: "mac-a")

        do {
            _ = try await CloudFolderSyncEngine.sync(
                folderURL: folder,
                store: store,
                state: &state,
                entitlements: PaidEntitlements(canUseCloudFolderSync: false),
                now: Self.date(20)
            )
            XCTFail("Expected unpaid sync to throw")
        } catch CloudFolderSyncError.notEntitled {
            XCTAssertFalse(FileManager.default.fileExists(atPath: CloudFolderSyncEngine.packageURL(for: folder).path))
        }
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
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )
        let operationFile = try XCTUnwrap(Self.operationFiles(folder: folder, deviceId: "mac-a").first)
        let operationJSON = try String(contentsOf: operationFile, encoding: .utf8)
        XCTAssertTrue(operationJSON.contains(".456"))

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
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
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )

        XCTAssertEqual(result.mutationsApplied, 0)
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
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )
        let secondResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
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
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )

        deviceAStore.snippets = []
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceAStore,
            state: &deviceAState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(30)
        )

        let deviceBStore = InMemoryUserDataSyncStore(snippets: [snippet])
        var deviceBState = CloudFolderSyncState(deviceId: "mac-b")
        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
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
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )

        let firstResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(30)
        )
        let secondResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(40)
        )

        XCTAssertEqual(firstResult.mutationsApplied, 1)
        XCTAssertEqual(secondResult.mutationsApplied, 0)
        XCTAssertEqual(deviceBStore.appliedMutations.count, 1)
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
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(10)
        )
        XCTAssertEqual(Self.operationFiles(folder: folder, deviceId: "mac-a").count, 1)

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
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

    private static func dictionaryEntry(
        entryType: UserDataSyncDictionaryEntryType = .term,
        original: String,
        replacement: String? = nil,
        source: DictionaryEntrySource? = nil,
        updatedAt: Date
    ) -> UserDataSyncDictionaryEntry {
        UserDataSyncDictionaryEntry(
            entryType: entryType,
            original: original,
            replacement: replacement,
            caseSensitive: false,
            isEnabled: true,
            source: source,
            createdAt: date(1),
            updatedAt: updatedAt
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

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
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
}
