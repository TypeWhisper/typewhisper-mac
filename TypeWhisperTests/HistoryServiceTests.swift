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
    func testHistoryViewModelLoadsAdditionalPagesAndReleasesThemWhenInactive() throws {
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

        viewModel.deactivate()
        XCTAssertEqual(viewModel.records.count, HistoryService.recentRecordsLimit)
    }
}
