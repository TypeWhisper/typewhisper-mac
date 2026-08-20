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

        let record = try XCTUnwrap(service.records.first)
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

        service.deleteRecord(try XCTUnwrap(service.records.first { $0.id == explicitID }))
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
        let record = try XCTUnwrap(historyService.records.first)
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
            historyService.records.first { $0.finalText == "Inbox note" }
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
        XCTAssertEqual(historyService.records.first { $0.id == firstID }?.finalText, "First")

        viewModel.discardAndContinue()

        XCTAssertEqual(viewModel.selectedRecordIDs, [secondID])
        XCTAssertFalse(viewModel.showsUnsavedChangesPrompt)
        XCTAssertEqual(historyService.records.first { $0.id == firstID }?.finalText, "First")
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
        let contextRecord = try XCTUnwrap(historyService.records.first { $0.id == contextID })

        viewModel.deleteRecords([contextRecord])

        XCTAssertEqual(viewModel.selectedRecordIDs, [selectedID])
        XCTAssertEqual(historyService.records.map(\.id), [selectedID])
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

        let record = try XCTUnwrap(service.records.first)
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

        XCTAssertEqual(service.records.count, 2)
        XCTAssertEqual(service.searchRecords(query: "planning").count, 1)
        XCTAssertEqual(service.uniqueDomains(), ["github.com"])
        XCTAssertNotNil(service.audioFileURL(for: service.records.first { $0.audioFileName != nil }!))

        let staleRecord = try XCTUnwrap(service.records.first(where: { $0.finalText == "Older note" }))
        staleRecord.timestamp = Calendar.current.date(byAdding: .day, value: -120, to: Date())!
        service.updateRecord(staleRecord, finalText: staleRecord.finalText)
        usageStatisticsService.backfillFromHistoryIfNeeded(service.records)

        service.purgeOldRecords(retentionDays: 30)

        XCTAssertEqual(service.records.count, 1)
        XCTAssertEqual(service.totalRecords, 1)
        XCTAssertEqual(service.totalWords, 3)

        let allTimeUsage = usageStatisticsService.summary(from: nil)
        XCTAssertEqual(allTimeUsage.transcriptionCount, 2)
        XCTAssertEqual(allTimeUsage.words, 5)
        XCTAssertEqual(allTimeUsage.appCount, 2)
    }
}
