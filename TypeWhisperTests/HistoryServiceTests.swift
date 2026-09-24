import Combine
import SwiftData
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class HistoryServiceTests: XCTestCase {
    @MainActor
    func testRemoteHistoryKeepsStructuredDocumentAndInboxMetadata() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "HistoryRemoteStructured"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let suiteName = "HistoryRemoteStructured-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        let service = HistoryService(
            appSupportDirectory: appSupportDirectory,
            historySyncPreferences: preferences
        )
        let recordID = UUID(uuidString: "83600000-0000-4000-8000-000000000004")!
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let structured = UserDataSyncHistoryStructuredDocumentV1(
            kind: "calendarEvent",
            title: "Project review",
            body: "Discuss the next release.",
            renderedText: "Project review\n\nDiscuss the next release.",
            fields: ["calendar.timeZone": "Europe/Berlin"]
        )

        try service.applyUserDataSyncMutations([
            .upsertHistoryContent(UserDataSyncHistoryContentV1(
                recordID: recordID,
                createdAt: createdAt,
                updatedAt: createdAt.addingTimeInterval(1),
                originDeviceID: "iphone-origin",
                originPlatform: "iOS",
                source: RecordingSource.appleWatch.rawValue,
                processingState: RecordingProcessingState.ready.rawValue,
                rawTranscript: "Create a project review appointment",
                finalText: "Create a project review appointment",
                renderedDocument: structured.renderedText,
                structuredDocument: structured,
                appDisplayName: "TypeWhisper",
                durationSeconds: 5,
                detectedLanguage: "en",
                engineDisplayName: "Apple Speech"
            )),
            .upsertHistoryInbox(UserDataSyncHistoryInboxV1(
                recordID: recordID,
                updatedAt: createdAt.addingTimeInterval(2),
                state: CaptureInboxState.open.rawValue,
                kind: "calendarAction",
                completionPolicy: .afterAction,
                completedAt: nil,
                safeAction: UserDataSyncHistorySafeActionV1(
                    action: "addToCalendar"
                )
            )),
        ])

        let record = try XCTUnwrap(service.recentRecords.first)
        XCTAssertEqual(record.source, .appleWatch)
        XCTAssertEqual(record.inboxState, .open)
        XCTAssertEqual(record.inboxCompletionPolicyRaw, "afterAction")
        XCTAssertEqual(record.synchronizedStructuredDocument, structured)
        XCTAssertEqual(
            service.userDataSyncHistoryRecords().first?.content.structuredDocument,
            structured
        )
    }

    @MainActor
    func testRetentionPruneStaysLocalWhileExplicitDeletionIsJournaled() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "HistoryDeletionSemantics"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let suiteName = "HistoryDeletionSemantics-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        let service = HistoryService(
            appSupportDirectory: appSupportDirectory,
            historySyncPreferences: preferences
        )
        let retentionID = UUID()
        let explicitID = UUID()
        service.addRecord(
            id: retentionID,
            timestamp: Calendar.current.date(byAdding: .day, value: -120, to: Date())!,
            rawText: "Old local record",
            finalText: "Old local record",
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 1,
            language: "en",
            engineUsed: "test"
        )
        service.addRecord(
            id: explicitID,
            rawText: "Delete everywhere",
            finalText: "Delete everywhere",
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 1,
            language: "en",
            engineUsed: "test"
        )

        service.purgeOldRecords(retentionDays: 30)
        XCTAssertTrue(preferences.isSuppressed(retentionID))
        XCTAssertNil(preferences.explicitDeletions[retentionID.uuidString.lowercased()])

        service.deleteRecord(try XCTUnwrap(service.recentRecords.first { $0.id == explicitID }))
        XCTAssertNotNil(preferences.explicitDeletions[explicitID.uuidString.lowercased()])
    }

    @MainActor
    func testHistoryWorkspaceFiltersInboxSourceSearchAudioAndSort() {
        let newest = TranscriptionRecord(
            timestamp: Date(timeIntervalSinceNow: -10),
            rawText: "Raw watch note",
            finalText: "Launch checklist",
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            appURL: "https://example.com/launch",
            durationSeconds: 3,
            language: "en",
            engineUsed: "test",
            audioFileName: "watch-note.wav"
        )
        newest.source = .appleWatch
        newest.inboxState = .open
        newest.inboxCompletionPolicyRaw = UserDataSyncHistoryCompletionPolicy.onOpen.rawValue

        let older = TranscriptionRecord(
            timestamp: Date(timeIntervalSinceNow: -60),
            rawText: "Mac note",
            finalText: "Archive",
            appName: "TextEdit",
            appBundleIdentifier: "com.apple.TextEdit",
            durationSeconds: 12,
            language: "en",
            engineUsed: "test"
        )
        older.source = .mac
        older.remoteAudioRelativePath = "assets/history/history-v1/remote/audio.wav"

        let inbox = HistoryViewModel.applyFilters(
            records: [older, newest],
            query: "launch",
            appFilter: "com.apple.Notes",
            timeRange: .all,
            collectionScope: .inbox,
            sourceScope: .appleWatch,
            sortOrder: .newest
        )
        let audio = HistoryViewModel.applyFilters(
            records: [older, newest],
            query: "",
            appFilter: nil,
            timeRange: .all,
            collectionScope: .withAudio,
            sourceScope: nil,
            sortOrder: .duration
        )

        XCTAssertEqual(inbox.map(\.id), [newest.id])
        XCTAssertEqual(audio.map(\.id), [older.id, newest.id])
        XCTAssertEqual(
            HistoryViewModel.computeSections([newest, older])
                .flatMap(\.records)
                .map(\.id),
            [newest.id, older.id]
        )
    }

    @MainActor
    func testSelectingInboxEntryDoesNotCompleteIt() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "HistoryInboxSelection"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        historyService.addRecord(
            rawText: "Watch note",
            finalText: "Watch note",
            appName: "TypeWhisper",
            appBundleIdentifier: nil,
            durationSeconds: 3,
            language: "en",
            engineUsed: "test"
        )
        let record = try XCTUnwrap(historyService.recentRecords.first)
        record.inboxState = .open
        record.inboxCompletionPolicyRaw = UserDataSyncHistoryCompletionPolicy.onOpen.rawValue

        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory)
        )
        viewModel.selectedRecordIDs = [record.id]

        XCTAssertTrue(record.isOpenInInbox)
        XCTAssertEqual(viewModel.inboxCount, 1)
    }

    @MainActor
    func testSelectingSmartMailboxRefreshesVisibleRecordsImmediately() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "HistoryImmediateNavigation"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        historyService.addRecord(
            rawText: "Regular note",
            finalText: "Regular note",
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 1,
            language: "en",
            engineUsed: "test"
        )
        historyService.addRecord(
            rawText: "Inbox note",
            finalText: "Inbox note",
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 1,
            language: "en",
            engineUsed: "test"
        )
        let inboxRecord = try XCTUnwrap(
            historyService.recentRecords.first { $0.finalText == "Inbox note" }
        )
        inboxRecord.inboxState = .open

        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory)
        )

        XCTAssertEqual(viewModel.filteredRecords.count, 2)
        viewModel.requestNavigationSelection(.smartMailbox(.inbox))

        XCTAssertEqual(viewModel.filteredRecords.map(\.id), [inboxRecord.id])
    }

    @MainActor
    func testDeviceSectionsNestWatchAndKeyboardUnderOriginatingIPhone() {
        let phoneDeviceID = "iphone-history-origin"
        let currentMacID = "current-mac-history-origin"
        let watch = TranscriptionRecord(
            rawText: "Watch note",
            finalText: "Watch note",
            durationSeconds: 2,
            engineUsed: "test"
        )
        watch.source = .appleWatch
        watch.originDeviceID = phoneDeviceID
        watch.originPlatformRaw = "watchOS"

        let keyboard = TranscriptionRecord(
            rawText: "Keyboard note",
            finalText: "Keyboard note",
            durationSeconds: 1,
            engineUsed: "test"
        )
        keyboard.source = .keyboard
        keyboard.originDeviceID = phoneDeviceID
        keyboard.originPlatformRaw = "iOS"

        let mac = TranscriptionRecord(
            rawText: "Mac note",
            finalText: "Mac note",
            durationSeconds: 1,
            engineUsed: "test"
        )
        mac.source = .mac
        mac.originDeviceID = currentMacID
        mac.originPlatformRaw = "macOS"

        let sections = HistoryViewModel.computeDeviceSections(
            records: [watch, keyboard, mac],
            devices: [
                CloudFolderSyncDeviceRecord(
                    deviceId: "transport-phone",
                    historyOriginDeviceID: phoneDeviceID,
                    platform: "iOS",
                    appVersion: "test",
                    updatedAt: Date(),
                    name: "Marco's iPhone"
                ),
                CloudFolderSyncDeviceRecord(
                    deviceId: "transport-mac",
                    historyOriginDeviceID: currentMacID,
                    platform: "macOS",
                    appVersion: "test",
                    updatedAt: Date(),
                    name: "Marco's Mac"
                ),
            ],
            currentDeviceID: currentMacID
        )

        XCTAssertEqual(sections.first?.id, currentMacID)
        let phone = sections.first { $0.id == phoneDeviceID }
        XCTAssertEqual(phone?.count, 2)
        XCTAssertEqual(phone?.sources.map(\.source), [.appleWatch, .keyboard])
        XCTAssertEqual(
            phone?.sources.first { $0.source == .keyboard }?.title,
            String(localized: "iOS Keyboard")
        )
    }

    @MainActor
    func testUnsavedDraftBlocksRecordSwitchUntilDiscarded() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "HistoryUnsavedDraft"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let firstID = UUID()
        let secondID = UUID()
        historyService.addRecord(
            id: firstID,
            rawText: "First",
            finalText: "First",
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 1,
            language: "en",
            engineUsed: "test"
        )
        historyService.addRecord(
            id: secondID,
            rawText: "Second",
            finalText: "Second",
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 1,
            language: "en",
            engineUsed: "test"
        )
        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory)
        )

        viewModel.requestRecordSelection([firstID])
        viewModel.editedText = "Changed but unsaved"
        viewModel.requestRecordSelection([secondID])

        XCTAssertEqual(viewModel.selectedRecordIDs, [firstID])
        XCTAssertTrue(viewModel.showsUnsavedChangesPrompt)
        XCTAssertEqual(historyService.recentRecords.first { $0.id == firstID }?.finalText, "First")

        viewModel.discardAndContinue()

        XCTAssertEqual(viewModel.selectedRecordIDs, [secondID])
        XCTAssertFalse(viewModel.showsUnsavedChangesPrompt)
        XCTAssertEqual(historyService.recentRecords.first { $0.id == firstID }?.finalText, "First")
    }

    @MainActor
    func testDeletingUnselectedContextRecordKeepsCurrentDraftSelection() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "HistoryContextDeletion"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let selectedID = UUID()
        let contextID = UUID()
        for (id, text) in [(selectedID, "Selected"), (contextID, "Context")] {
            historyService.addRecord(
                id: id,
                rawText: text,
                finalText: text,
                appName: nil,
                appBundleIdentifier: nil,
                durationSeconds: 1,
                language: "en",
                engineUsed: "test"
            )
        }
        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory)
        )
        viewModel.requestRecordSelection([selectedID])
        let contextRecord = try XCTUnwrap(historyService.recentRecords.first { $0.id == contextID })

        viewModel.deleteRecords([contextRecord])

        XCTAssertEqual(viewModel.selectedRecordIDs, [selectedID])
        XCTAssertEqual(historyService.recentRecords.map(\.id), [selectedID])
    }

    @MainActor
    func testUpdateRecordEmitsCompletePluginSyncPayloadWithoutChangingSDKABI() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let id = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let timestamp = Date(timeIntervalSince1970: 1_754_668_800)
        var emittedEvents: [TypeWhisperEvent] = []
        let service = HistoryService(appSupportDirectory: appSupportDirectory) { event in
            emittedEvents.append(event)
        }

        service.addRecord(
            id: id,
            timestamp: timestamp,
            rawText: "Original text",
            finalText: "Original text",
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            appURL: "https://example.com",
            durationSeconds: 7.5,
            language: "en",
            engineUsed: "parakeet",
            modelUsed: "TDT",
            pipelineSteps: ["Cleanup"]
        )

        let record = try XCTUnwrap(service.recentRecords.first)
        record.renderedDocument = "Rendered document"
        record.synchronizedStructuredDocument = UserDataSyncHistoryStructuredDocumentV1(
            kind: "note",
            body: "Rendered document",
            renderedText: "Rendered document"
        )
        service.updateRecord(record, finalText: "Corrected text")

        XCTAssertNil(record.renderedDocument)
        XCTAssertNil(record.synchronizedStructuredDocument)
        XCTAssertEqual(record.displayText, "Corrected text")

        XCTAssertEqual(emittedEvents.count, 1)
        guard case .actionCompleted(let event) = try XCTUnwrap(emittedEvents.first) else {
            return XCTFail("Expected an actionCompleted plugin sync envelope")
        }
        XCTAssertEqual(event.actionId, HistoryService.pluginSyncActionID)
        XCTAssertEqual(event.timestamp, timestamp)
        XCTAssertEqual(event.appName, "Notes")
        XCTAssertEqual(event.url, "https://example.com")

        let data = try XCTUnwrap(event.message.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["id"] as? String, id.uuidString)
        XCTAssertEqual(payload["rawText"] as? String, "Original text")
        XCTAssertEqual(payload["finalText"] as? String, "Corrected text")
        XCTAssertEqual(payload["pipelineSteps"] as? [String], ["Cleanup"])
    }

    @MainActor
    func testAddSearchUniqueDomainsAndPurgeHistory() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = HistoryService(appSupportDirectory: appSupportDirectory)
        service.clearAll()
        let usageStatisticsService = UsageStatisticsService(appSupportDirectory: appSupportDirectory)

        service.addRecord(
            rawText: "Weekly planning meeting",
            finalText: "Weekly planning meeting",
            appName: "Safari",
            appBundleIdentifier: "com.apple.Safari",
            appURL: "https://www.github.com/TypeWhisper/typewhisper-mac",
            durationSeconds: 12,
            language: "en",
            engineUsed: "parakeet",
            audioSamples: Array(repeating: 0.25, count: 1600)
        )
        service.addRecord(
            rawText: "Older note",
            finalText: "Older note",
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            durationSeconds: 8,
            language: "en",
            engineUsed: "parakeet"
        )

        XCTAssertEqual(service.recentRecords.count, 2)
        XCTAssertEqual(service.searchRecords(query: "planning").count, 1)
        XCTAssertEqual(service.uniqueDomains(), ["github.com"])
        XCTAssertNotNil(service.audioFileURL(for: service.recentRecords.first { $0.audioFileName != nil }!))

        let staleRecord = try XCTUnwrap(service.recentRecords.first(where: { $0.finalText == "Older note" }))
        staleRecord.timestamp = Calendar.current.date(byAdding: .day, value: -120, to: Date())!
        service.updateRecord(staleRecord, finalText: staleRecord.finalText)
        usageStatisticsService.backfillFromHistoryIfNeeded(service.recentRecords)

        service.purgeOldRecords(retentionDays: 30)

        XCTAssertEqual(service.recentRecords.count, 1)
        XCTAssertEqual(service.totalRecords, 1)
        XCTAssertEqual(service.allRecords().reduce(0) { $0 + $1.wordsCount }, 3)

        let allTimeUsage = usageStatisticsService.summary(from: nil)
        XCTAssertEqual(allTimeUsage.transcriptionCount, 2)
        XCTAssertEqual(allTimeUsage.words, 5)
        XCTAssertEqual(allTimeUsage.appCount, 2)
    }

    @MainActor
    func testRecentCacheIsBoundedWhilePagesCoverCompleteHistory() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "HistoryPagination"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let service = HistoryService(appSupportDirectory: appSupportDirectory)
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        var oldestID: UUID?

        for index in 0..<125 {
            let id = UUID()
            if index == 0 { oldestID = id }
            service.addRecord(
                id: id,
                timestamp: baseDate.addingTimeInterval(Double(index)),
                rawText: "Record \(index)",
                finalText: "Record \(index)",
                appName: "Notes",
                appBundleIdentifier: "com.apple.Notes",
                durationSeconds: Double(index),
                language: "en",
                engineUsed: "test"
            )
        }

        XCTAssertEqual(service.recentRecords.count, HistoryService.recentRecordsLimit)
        XCTAssertEqual(service.recentRecords.first?.finalText, "Record 124")
        XCTAssertEqual(service.totalRecords, 125)

        let firstPage = service.fetchPage(offset: 0, limit: 100)
        let secondPage = service.fetchPage(offset: 100, limit: 100)
        let allIDs = firstPage.records.map(\.id) + secondPage.records.map(\.id)

        XCTAssertEqual(firstPage.totalCount, 125)
        XCTAssertTrue(firstPage.hasMore)
        XCTAssertEqual(firstPage.records.count, 100)
        XCTAssertEqual(secondPage.records.count, 25)
        XCTAssertFalse(secondPage.hasMore)
        XCTAssertEqual(Set(allIDs).count, 125)
        XCTAssertEqual(service.record(withID: try XCTUnwrap(oldestID))?.finalText, "Record 0")
    }

    @MainActor
    func testUserDataSyncIncludesRecordsBeyondRecentCache() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "HistorySyncComplete"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let suiteName = "HistorySyncComplete-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        let service = HistoryService(
            appSupportDirectory: appSupportDirectory,
            historySyncPreferences: preferences
        )

        for index in 0..<25 {
            service.addRecord(
                rawText: "Sync \(index)",
                finalText: "Sync \(index)",
                appName: nil,
                appBundleIdentifier: nil,
                durationSeconds: 1,
                language: "en",
                engineUsed: "test"
            )
        }

        XCTAssertEqual(service.recentRecords.count, HistoryService.recentRecordsLimit)
        XCTAssertEqual(service.userDataSyncHistoryRecords().count, 25)
    }

    @MainActor
    func testSearchAndRetentionIncludeRecordsOutsideRecentCache() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "HistoryCompleteQueries"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let service = HistoryService(appSupportDirectory: appSupportDirectory)
        let now = Date()
        let targetID = UUID()

        service.addRecord(
            id: targetID,
            timestamp: Calendar.current.date(byAdding: .day, value: -120, to: now)!,
            rawText: "Needle outside recent cache",
            finalText: "Needle outside recent cache",
            appName: "Safari",
            appBundleIdentifier: "com.apple.Safari",
            durationSeconds: 2,
            language: "en",
            engineUsed: "test"
        )
        for index in 0..<30 {
            service.addRecord(
                timestamp: now.addingTimeInterval(Double(index)),
                rawText: "Recent \(index)",
                finalText: "Recent \(index)",
                appName: "Notes",
                appBundleIdentifier: "com.apple.Notes",
                durationSeconds: 1,
                language: "en",
                engineUsed: "test"
            )
        }

        XCTAssertFalse(service.recentRecords.contains { $0.id == targetID })
        let searchPage = service.fetchPage(
            query: HistoryQuery(searchText: "needle"),
            offset: 0,
            limit: 100
        )
        XCTAssertEqual(searchPage.records.map(\.id), [targetID])

        service.purgeOldRecords(retentionDays: 30)

        XCTAssertNil(service.record(withID: targetID))
        XCTAssertEqual(service.recordCount(), 30)
    }

    @MainActor
    func testPagedQueryCombinesAppTimeDeviceAndSourceFilters() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "HistoryCombinedQuery"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let service = HistoryService(appSupportDirectory: appSupportDirectory)
        let now = Date()

        func addRecord(
            text: String,
            timestamp: Date,
            appBundleIdentifier: String,
            deviceID: String,
            source: RecordingSource
        ) throws -> UUID {
            let id = UUID()
            service.addRecord(
                id: id,
                timestamp: timestamp,
                rawText: text,
                finalText: text,
                appName: "Test App",
                appBundleIdentifier: appBundleIdentifier,
                durationSeconds: 1,
                language: "en",
                engineUsed: "test"
            )
            let record = try XCTUnwrap(service.record(withID: id))
            record.originDeviceID = deviceID
            record.originPlatformRaw = "iOS"
            record.source = source
            service.updateRecord(record, finalText: text)
            return id
        }

        let targetID = try addRecord(
            text: "Target",
            timestamp: now,
            appBundleIdentifier: "com.apple.Notes",
            deviceID: "phone-1",
            source: .keyboard
        )
        _ = try addRecord(
            text: "Wrong source",
            timestamp: now,
            appBundleIdentifier: "com.apple.Notes",
            deviceID: "phone-1",
            source: .appleWatch
        )
        _ = try addRecord(
            text: "Wrong app",
            timestamp: now,
            appBundleIdentifier: "com.apple.TextEdit",
            deviceID: "phone-1",
            source: .keyboard
        )
        _ = try addRecord(
            text: "Too old",
            timestamp: Calendar.current.date(byAdding: .day, value: -120, to: now)!,
            appBundleIdentifier: "com.apple.Notes",
            deviceID: "phone-1",
            source: .keyboard
        )

        let page = service.fetchPage(
            query: HistoryQuery(
                appBundleIdentifier: "com.apple.Notes",
                cutoffDate: Calendar.current.date(byAdding: .day, value: -30, to: now),
                originDeviceID: "phone-1",
                source: .keyboard
            ),
            offset: 0,
            limit: 100
        )

        XCTAssertEqual(page.records.map(\.id), [targetID])
        XCTAssertEqual(page.totalCount, 1)
        XCTAssertFalse(page.hasMore)
    }

    @MainActor
    func testHistoryViewModelLoadsAdditionalPagesAndReleasesThemWhenInactive() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "HistoryViewPagination"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<125 {
            historyService.addRecord(
                timestamp: baseDate.addingTimeInterval(Double(index)),
                rawText: "Paged \(index)",
                finalText: "Paged \(index)",
                appName: "Notes",
                appBundleIdentifier: "com.apple.Notes",
                durationSeconds: 1,
                language: "en",
                engineUsed: "test"
            )
        }
        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory)
        )

        XCTAssertEqual(viewModel.records.count, HistoryService.recentRecordsLimit)
        viewModel.activate()
        XCTAssertEqual(viewModel.records.count, 100)
        XCTAssertEqual(viewModel.totalMatchingRecordCount, 125)
        XCTAssertTrue(viewModel.hasMoreRecords)

        viewModel.loadMoreRecords()
        XCTAssertEqual(viewModel.records.count, 125)
        XCTAssertFalse(viewModel.hasMoreRecords)

        let queryID = viewModel.queryID
        historyService.addRecord(
            timestamp: baseDate.addingTimeInterval(126),
            rawText: "New record",
            finalText: "New record",
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            durationSeconds: 1,
            language: "en",
            engineUsed: "test"
        )
        await viewModel.waitForPendingWork()
        XCTAssertEqual(viewModel.records.count, 125)
        XCTAssertEqual(viewModel.totalMatchingRecordCount, 126)
        XCTAssertTrue(viewModel.hasMoreRecords)
        XCTAssertEqual(viewModel.queryID, queryID)

        viewModel.deactivate()
        XCTAssertEqual(viewModel.records.count, HistoryService.recentRecordsLimit)
    }

    @MainActor
    func testBatchInboxUpdatesSaveAndPublishOnce() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "HistoryBatchInbox")
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let ids = [UUID(), UUID(), UUID()]
        for (index, id) in ids.enumerated() {
            historyService.addRecord(
                id: id,
                rawText: "Inbox \(index)",
                finalText: "Inbox \(index)",
                appName: nil,
                appBundleIdentifier: nil,
                durationSeconds: 1,
                language: "en",
                engineUsed: "test"
            )
        }
        let records = try ids.map { try XCTUnwrap(historyService.record(withID: $0)) }
        records[0].inboxState = .open
        records[1].inboxState = .open
        // Persist the inbox fixture before counting saves.
        historyService.updateRecord(records[2], finalText: records[2].finalText)

        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory)
        )
        let syncStore = TypeWhisperUserDataSyncStore(
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            snippetService: SnippetService(appSupportDirectory: appSupportDirectory),
            historyService: historyService
        )
        var syncNotifications = 0
        syncStore.observeLocalChanges { syncNotifications += 1 }
        var publishes = 0
        var saves = 0
        let historyStorePath = appSupportDirectory.standardizedFileURL.path
        var cancellables = Set<AnyCancellable>()
        historyService.$recentRecords
            .dropFirst()
            .sink { _ in publishes += 1 }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .sink { notification in
                guard let context = notification.object as? ModelContext,
                      context.container.configurations.contains(where: {
                          $0.url.standardizedFileURL.path.hasPrefix(historyStorePath)
                      }) else { return }
                saves += 1
            }
            .store(in: &cancellables)

        viewModel.markComplete(records)

        XCTAssertEqual(records.map(\.inboxState), [.completed, .completed, CaptureInboxState.none])
        XCTAssertNotNil(records[0].inboxCompletedAt)
        XCTAssertEqual(records[0].inboxUpdatedAt, records[1].inboxUpdatedAt)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(syncNotifications, 1)

        viewModel.reopen(records)

        XCTAssertEqual(records.map(\.inboxState), [.open, .open, CaptureInboxState.none])
        XCTAssertNil(records[0].inboxCompletedAt)
        XCTAssertNil(records[1].inboxCompletedAt)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(publishes, 2)
        XCTAssertEqual(syncNotifications, 2)

        historyService.reopenInbox(records)

        XCTAssertEqual(saves, 2)
        XCTAssertEqual(publishes, 2)
        XCTAssertEqual(syncNotifications, 2)
    }

    @MainActor
    func testSearchStaysCaseInsensitiveAndDiacriticSensitiveInForegroundAndBackground() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "HistorySearchSemantics")
        defer { TestSupport.remove(appSupportDirectory) }
        let service = HistoryService(appSupportDirectory: appSupportDirectory)
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

        func addRecord(
            _ rawText: String,
            finalText: String? = nil,
            appName: String? = nil,
            appURL: String? = nil,
            offset: TimeInterval
        ) -> UUID {
            let id = UUID()
            service.addRecord(
                id: id,
                timestamp: baseDate.addingTimeInterval(offset),
                rawText: rawText,
                finalText: finalText ?? rawText,
                appName: appName,
                appBundleIdentifier: nil,
                appURL: appURL,
                durationSeconds: 1,
                language: "de",
                engineUsed: "test"
            )
            return id
        }

        let meeting = addRecord("Treffen mit Herrn Müller", appName: "Mail", offset: 4)
        let cafe = addRecord("Kaffee bestellen", finalText: "Café bestellen", offset: 3)
        let website = addRecord("Draft", appName: "Safari", appURL: "https://Docs.Example.com/page", offset: 2)
        let watch = addRecord("Erinnerung", offset: 1)
        let watchRecord = try XCTUnwrap(service.record(withID: watch))
        watchRecord.source = .appleWatch
        service.updateRecord(watchRecord, finalText: watchRecord.finalText)

        let expectations: [(searchText: String, ids: [UUID])] = [
            ("MÜLLER", [meeting]),
            ("müller", [meeting]),
            ("Muller", []),
            ("CAFÉ", [cafe]),
            ("cafe", []),
            ("  herrn  ", [meeting]),
            ("MAIL", [meeting]),
            ("docs.example", [website]),
            (RecordingSource.appleWatch.displayName.uppercased(), [watch]),
            ("e", [meeting, cafe, website, watch]),
        ]

        for expectation in expectations {
            let query = HistoryQuery(searchText: expectation.searchText)
            let foreground = service.fetchPage(query: query, offset: 0, limit: 100)
            let background = await service.fetchPageInBackground(query: query, offset: 0, limit: 100)

            XCTAssertEqual(foreground.records.map(\.id), expectation.ids, expectation.searchText)
            XCTAssertEqual(background?.records.map(\.id), expectation.ids, expectation.searchText)
            XCTAssertEqual(background?.totalCount, foreground.totalCount, expectation.searchText)
        }

        let pagedQuery = HistoryQuery(searchText: "e", sortOrder: .oldest)
        let foregroundPage = service.fetchPage(query: pagedQuery, offset: 1, limit: 2)
        let backgroundPage = await service.fetchPageInBackground(query: pagedQuery, offset: 1, limit: 2)
        XCTAssertEqual(foregroundPage.records.map(\.id), [website, cafe])
        XCTAssertEqual(backgroundPage?.records.map(\.id), [website, cafe])
        XCTAssertEqual(backgroundPage?.totalCount, 4)
        XCTAssertEqual(backgroundPage?.hasMore, true)
    }

    @MainActor
    func testHistoryViewModelDropsStaleBackgroundSearchResults() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "HistoryStaleSearch")
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        for text in ["Alpha note", "Beta note"] {
            historyService.addRecord(
                rawText: text,
                finalText: text,
                appName: nil,
                appBundleIdentifier: nil,
                durationSeconds: 1,
                language: "en",
                engineUsed: "test"
            )
        }
        let loader = ControlledHistoryPageLoader(historyService: historyService)
        loader.holdsRequests = true
        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            backgroundPageLoader: { await loader.load($0, offset: $1, limit: $2) }
        )
        viewModel.activate()
        XCTAssertEqual(viewModel.records.count, 2)
        XCTAssertTrue(loader.requests.isEmpty)

        let alphaRequested = loader.expectation(forRequestCount: 1, in: self)
        viewModel.searchQuery = "alpha"
        await fulfillment(of: [alphaRequested], timeout: 5)
        let betaRequested = loader.expectation(forRequestCount: 2, in: self)
        viewModel.searchQuery = "beta"
        await fulfillment(of: [betaRequested], timeout: 5)

        let betaShown = expectation(description: "newer search result shown")
        var cancellables = Set<AnyCancellable>()
        viewModel.$records
            .sink { records in
                if records.map(\.finalText) == ["Beta note"] { betaShown.fulfill() }
            }
            .store(in: &cancellables)
        loader.releaseRequest(searchText: "beta")
        await fulfillment(of: [betaShown], timeout: 5)

        loader.releaseRequest(searchText: "alpha")
        await viewModel.waitForPendingWork()

        XCTAssertEqual(viewModel.records.map(\.finalText), ["Beta note"])
        XCTAssertEqual(viewModel.totalMatchingRecordCount, 1)
    }

    @MainActor
    func testHistoryViewModelCoalescesHistoryPublishesIntoOneReload() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "HistoryCoalescedReload")
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        func addNote(_ text: String) {
            historyService.addRecord(
                rawText: text,
                finalText: text,
                appName: nil,
                appBundleIdentifier: nil,
                durationSeconds: 1,
                language: "en",
                engineUsed: "test"
            )
        }
        addNote("First note")
        addNote("Second note")
        let loader = ControlledHistoryPageLoader(historyService: historyService)
        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            historyRefreshDelay: .milliseconds(10),
            backgroundPageLoader: { await loader.load($0, offset: $1, limit: $2) }
        )
        viewModel.activate()
        let searched = loader.expectation(forRequestCount: 1, in: self)
        viewModel.searchQuery = "note"
        await fulfillment(of: [searched], timeout: 5)
        await viewModel.waitForPendingWork()
        XCTAssertEqual(viewModel.records.count, 2)

        addNote("Third note")
        addNote("Fourth note")
        addNote("Fifth note")
        XCTAssertEqual(viewModel.records.count, 2)

        await viewModel.waitForPendingWork()

        XCTAssertEqual(loader.requests.count, 2)
        XCTAssertEqual(viewModel.records.count, 5)
        XCTAssertEqual(viewModel.totalMatchingRecordCount, 5)
    }

    @MainActor
    func testHistoryViewModelRemovesDeletedRecordsBeforeCoalescedReload() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "HistoryDeletedBeforeReload")
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let keptID = UUID()
        let deletedID = UUID()
        for (id, text) in [(keptID, "Kept"), (deletedID, "Deleted elsewhere")] {
            historyService.addRecord(
                id: id,
                rawText: text,
                finalText: text,
                appName: nil,
                appBundleIdentifier: nil,
                durationSeconds: 1,
                language: "en",
                engineUsed: "test"
            )
        }
        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            historyRefreshDelay: .seconds(60)
        )
        viewModel.activate()
        XCTAssertEqual(viewModel.records.count, 2)

        XCTAssertTrue(historyService.deleteRecord(withID: deletedID))

        XCTAssertEqual(viewModel.records.map(\.id), [keptID])
        XCTAssertEqual(viewModel.totalMatchingRecordCount, 1)
        viewModel.deactivate()
        await viewModel.waitForPendingWork()
    }

    @MainActor
    func testHistoryDiffCacheInvalidatesWhenRecordContentChanges() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "HistoryDiffCache")
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        func addRecord(raw: String, final: String) throws -> TranscriptionRecord {
            let id = UUID()
            historyService.addRecord(
                id: id,
                rawText: raw,
                finalText: final,
                appName: nil,
                appBundleIdentifier: nil,
                durationSeconds: 1,
                language: "en",
                engineUsed: "test"
            )
            return try XCTUnwrap(historyService.record(withID: id))
        }
        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory)
        )

        let short = try addRecord(raw: "hello world", final: "hello brave world")
        XCTAssertEqual(
            viewModel.diffPresentation(for: short),
            .segments([.unchanged("hello"), .added("brave"), .unchanged("world")])
        )
        historyService.updateRecord(short, finalText: "hello world again")
        XCTAssertEqual(
            viewModel.diffPresentation(for: short),
            .segments([.unchanged("hello"), .unchanged("world"), .added("again")])
        )

        let longText = (0..<600).map { "word\($0)" }.joined(separator: " ")
        XCTAssertGreaterThan(longText.utf8.count * 2, HistoryViewModel.inlineDiffInputLimit)
        let long = try addRecord(raw: longText, final: longText + " tail")
        XCTAssertNil(viewModel.diffPresentation(for: long))
        await viewModel.loadDiffPresentation(for: long)
        guard case .segments(let segments) = viewModel.diffPresentation(for: long) else {
            return XCTFail("Expected a cached background diff")
        }
        XCTAssertEqual(segments.last, .added("tail"))

        historyService.updateRecord(long, finalText: longText + " changed")
        XCTAssertNil(viewModel.diffPresentation(for: long))
        await viewModel.loadDiffPresentation(for: long)
        guard case .segments(let updatedSegments) = viewModel.diffPresentation(for: long) else {
            return XCTFail("Expected a recomputed background diff")
        }
        XCTAssertEqual(updatedSegments.last, .added("changed"))

        let wordCount = Int(Double(HistoryViewModel.maxDiffComparisonCells).squareRoot()) + 1
        let oversized = try addRecord(
            raw: (0..<wordCount).map { "a\($0)" }.joined(separator: " "),
            final: (0..<wordCount).map { "b\($0)" }.joined(separator: " ")
        )
        await viewModel.loadDiffPresentation(for: oversized)
        XCTAssertEqual(viewModel.diffPresentation(for: oversized), .tooLarge)
    }

    @MainActor
    func testHistoryViewModelRunsFilteredFullScansThroughBackgroundLoader() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "HistoryFilteredBackground")
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<105 {
            historyService.addRecord(
                timestamp: baseDate.addingTimeInterval(Double(index)),
                rawText: "Notes \(index)",
                finalText: "Notes \(index)",
                appName: "Notes",
                appBundleIdentifier: "com.apple.Notes",
                durationSeconds: 1,
                language: "en",
                engineUsed: "test"
            )
        }
        historyService.addRecord(
            rawText: "Mail",
            finalText: "Mail",
            appName: "Mail",
            appBundleIdentifier: "com.apple.mail",
            durationSeconds: 1,
            language: "en",
            engineUsed: "test"
        )
        let loader = ControlledHistoryPageLoader(historyService: historyService)
        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            backgroundPageLoader: { await loader.load($0, offset: $1, limit: $2) }
        )
        viewModel.activate()
        XCTAssertTrue(loader.requests.isEmpty)

        viewModel.requestAppFilter("com.apple.Notes")
        await viewModel.waitForPendingWork()
        XCTAssertEqual(loader.requests.map(\.appBundleIdentifier), ["com.apple.Notes"])
        XCTAssertEqual(viewModel.records.count, 100)
        XCTAssertEqual(viewModel.totalMatchingRecordCount, 105)

        viewModel.loadMoreRecords()
        await viewModel.waitForPendingWork()
        XCTAssertEqual(loader.requests.count, 2)
        XCTAssertEqual(viewModel.records.count, 105)
        XCTAssertFalse(viewModel.hasMoreRecords)
        XCTAssertFalse(viewModel.isLoadingMore)
    }

    @MainActor
    func testHistoryViewModelReloadsSearchDroppedForUnsavedDraftAfterDiscard() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "HistoryDeferredSearch")
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let alphaID = UUID()
        for (id, text) in [(alphaID, "Alpha note"), (UUID(), "Beta note")] {
            historyService.addRecord(
                id: id,
                rawText: text,
                finalText: text,
                appName: nil,
                appBundleIdentifier: nil,
                durationSeconds: 1,
                language: "en",
                engineUsed: "test"
            )
        }
        let loader = ControlledHistoryPageLoader(historyService: historyService)
        loader.holdsRequests = true
        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            backgroundPageLoader: { await loader.load($0, offset: $1, limit: $2) }
        )
        viewModel.activate()
        viewModel.requestRecordSelection([alphaID])

        let searched = loader.expectation(forRequestCount: 1, in: self)
        viewModel.searchQuery = "beta"
        await fulfillment(of: [searched], timeout: 5)
        viewModel.editedText = "Alpha note, edited"
        XCTAssertTrue(viewModel.isDirty)
        loader.releaseRequest(searchText: "beta")
        await viewModel.waitForPendingWork()
        XCTAssertEqual(viewModel.records.count, 2, "The search result is held back while the draft is dirty")

        loader.holdsRequests = false
        viewModel.discardEditing()
        await viewModel.waitForPendingWork()

        XCTAssertEqual(loader.requests.map(\.searchText), ["beta", "beta"])
        XCTAssertEqual(viewModel.records.map(\.finalText), ["Beta note"])
        XCTAssertEqual(viewModel.totalMatchingRecordCount, 1)
    }

    @MainActor
    func testHistoryDiffIgnoresSupersededAndCancelledComparisons() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "HistoryStaleDiff")
        defer { TestSupport.remove(appSupportDirectory) }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let longText = (0..<600).map { "word\($0)" }.joined(separator: " ")
        let recordID = UUID()
        historyService.addRecord(
            id: recordID,
            rawText: longText,
            finalText: longText + " first",
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 1,
            language: "en",
            engineUsed: "test"
        )
        let record = try XCTUnwrap(historyService.record(withID: recordID))
        let loader = ControlledDiffPresentationLoader()
        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            diffPresentationLoader: { await loader.load(rawText: $0, finalText: $1) }
        )

        // The first comparison is still running when the record's text changes and a
        // second comparison starts. The older result arrives last and must not replace the newer one.
        let firstRequested = loader.expectation(forRequestCount: 1, in: self)
        let first = Task { await viewModel.loadDiffPresentation(for: record) }
        await fulfillment(of: [firstRequested], timeout: 5)
        historyService.updateRecord(record, finalText: longText + " second")
        let secondRequested = loader.expectation(forRequestCount: 2, in: self)
        let second = Task { await viewModel.loadDiffPresentation(for: record) }
        await fulfillment(of: [secondRequested], timeout: 5)

        loader.release(finalText: longText + " second")
        await second.value
        XCTAssertEqual(viewModel.diffPresentation(for: record), .segments([.added("second")]))
        loader.release(finalText: longText + " first")
        await first.value
        XCTAssertEqual(viewModel.diffPresentation(for: record), .segments([.added("second")]))

        // A comparison whose caller was cancelled is not cached, even if it still returns a result.
        historyService.updateRecord(record, finalText: longText + " third")
        let thirdRequested = loader.expectation(forRequestCount: 3, in: self)
        let third = Task { await viewModel.loadDiffPresentation(for: record) }
        await fulfillment(of: [thirdRequested], timeout: 5)
        third.cancel()
        loader.release(finalText: longText + " third")
        await third.value
        XCTAssertNil(viewModel.diffPresentation(for: record))
    }

    @MainActor
    func testBackgroundDiffForwardsCancellationToComparison() async {
        // Just below the comparison cap, so an uncancelled comparison would produce segments.
        let wordCount = 1_500
        XCTAssertLessThanOrEqual(wordCount * wordCount, HistoryViewModel.maxDiffComparisonCells)
        let rawText = (0..<wordCount).map { "a\($0)" }.joined(separator: " ")
        let finalText = (0..<wordCount).map { "b\($0)" }.joined(separator: " ")

        // The task is cancelled before it starts, so the cancellation reaches the detached
        // comparison as soon as it is awaited.
        let comparison = Task {
            await HistoryViewModel.computeDiffPresentationInBackground(rawText: rawText, finalText: finalText)
        }
        comparison.cancel()
        let result = await comparison.value
        XCTAssertNil(result)
    }
}

/// Stands in for the background search so tests control when each result arrives.
@MainActor
private final class ControlledHistoryPageLoader {
    private struct HeldRequest {
        let searchText: String
        let continuation: CheckedContinuation<Void, Never>
    }

    var holdsRequests = false
    private(set) var requests: [HistoryQuery] = []
    private let historyService: HistoryService
    private var heldRequests: [HeldRequest] = []
    private var requestExpectation: (count: Int, expectation: XCTestExpectation)?

    init(historyService: HistoryService) {
        self.historyService = historyService
    }

    func load(_ query: HistoryQuery, offset: Int, limit: Int) async -> HistoryPage? {
        requests.append(query)
        if let pending = requestExpectation, requests.count >= pending.count {
            requestExpectation = nil
            pending.expectation.fulfill()
        }
        if holdsRequests {
            await withCheckedContinuation { continuation in
                heldRequests.append(HeldRequest(searchText: query.searchText, continuation: continuation))
            }
        }
        return historyService.fetchPage(query: query, offset: offset, limit: limit)
    }

    func expectation(forRequestCount count: Int, in testCase: XCTestCase) -> XCTestExpectation {
        let expectation = testCase.expectation(description: "History page request \(count)")
        if requests.count >= count {
            expectation.fulfill()
        } else {
            requestExpectation = (count, expectation)
        }
        return expectation
    }

    func releaseRequest(searchText: String) {
        guard let index = heldRequests.firstIndex(where: { $0.searchText == searchText }) else {
            return XCTFail("No held history request for \(searchText)")
        }
        heldRequests.remove(at: index).continuation.resume()
    }
}

/// Stands in for the background diff so tests control when each comparison finishes.
/// Each result names the last word of the compared final text.
@MainActor
private final class ControlledDiffPresentationLoader {
    private struct HeldRequest {
        let finalText: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var requestCount = 0
    private var heldRequests: [HeldRequest] = []
    private var requestExpectation: (count: Int, expectation: XCTestExpectation)?

    func load(rawText: String, finalText: String) async -> HistoryDiffPresentation? {
        requestCount += 1
        if let pending = requestExpectation, requestCount >= pending.count {
            requestExpectation = nil
            pending.expectation.fulfill()
        }
        await withCheckedContinuation { continuation in
            heldRequests.append(HeldRequest(finalText: finalText, continuation: continuation))
        }
        let lastWord = finalText.split(separator: " ").last.map(String.init) ?? ""
        return .segments([.added(lastWord)])
    }

    func expectation(forRequestCount count: Int, in testCase: XCTestCase) -> XCTestExpectation {
        let expectation = testCase.expectation(description: "Diff request \(count)")
        if requestCount >= count {
            expectation.fulfill()
        } else {
            requestExpectation = (count, expectation)
        }
        return expectation
    }

    func release(finalText: String) {
        guard let index = heldRequests.firstIndex(where: { $0.finalText == finalText }) else {
            return XCTFail("No held diff request for \(finalText)")
        }
        heldRequests.remove(at: index).continuation.resume()
    }
}
