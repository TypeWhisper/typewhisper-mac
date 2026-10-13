import Combine
import SwiftData
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class HistoryRetranscriptionTests: XCTestCase {
    @MainActor
    private final class TestFlag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private struct Fixture {
        let directory: URL
        let history: HistoryService
        let record: TranscriptionRecord
        let audioURL: URL
    }

    private func fixture(
        sync: HistorySyncPreferences? = nil,
        writer: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) async throws -> Fixture {
        let directory = try TestSupport.makeTemporaryDirectory()
        let history = HistoryService(appSupportDirectory: directory, historySyncPreferences: sync,
                                     eventEmitter: { _ in }, versionWriter: writer)
        let id = UUID()
        let audio = await history.writeAudioFileInBackground([0.1, 0.2, 0.3], forRecordID: id)
        XCTAssertTrue(history.addRecord(
            id: id, rawText: "original raw", finalText: "original final", appName: "Test",
            appBundleIdentifier: nil, durationSeconds: 12, language: "en",
            engineUsed: "original-engine", modelUsed: "Original Model", audioFileName: audio
        ))
        let record = try XCTUnwrap(history.record(withID: id))
        return Fixture(directory: directory, history: history, record: record,
                       audioURL: try XCTUnwrap(history.audioFileURL(for: record)))
    }

    private func alternative() -> HistoryTranscriptionVersion {
        HistoryTranscriptionVersion(
            rawText: "new raw", finalText: "new final", engineID: "other-engine",
            engineName: "Other Engine", modelID: "other-model", modelName: "Other Model",
            language: "de", requestedLanguage: "de", workflowID: UUID(), workflowName: "Cleanup"
        )
    }

    private func append(_ version: HistoryTranscriptionVersion, to fixture: Fixture) throws {
        try fixture.history.appendTranscriptionVersion(version, to: fixture.record,
                                                      expected: .capture(fixture.record))
    }

    func testSuccessfulRunKeepsOriginalAudioMetadataAndStatisticsAndSurvivesReopen() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        let original = HistoryTranscriptionVersion.capture(f.record)
        let date = f.record.contentUpdatedAt
        let data = try Data(contentsOf: f.audioURL)
        let version = alternative()
        try append(version, to: f)

        XCTAssertEqual(HistoryTranscriptionVersion.capture(f.record), original)
        XCTAssertEqual(f.record.contentUpdatedAt, date)
        XCTAssertNil(f.record.activeTranscriptionVersionID)
        XCTAssertEqual(f.history.totalRecords, 1)
        XCTAssertEqual(f.record.durationSeconds, 12)
        XCTAssertEqual(f.record.wordsCount, 2)
        XCTAssertEqual(try Data(contentsOf: f.audioURL), data)
        XCTAssertEqual(try f.record.savedTranscriptionVersions(), [original, version])
        let reopened = HistoryService(appSupportDirectory: f.directory)
        let restored = try XCTUnwrap(reopened.record(withID: f.record.id))
        XCTAssertEqual(try restored.savedTranscriptionVersions(), [original, version])
        XCTAssertEqual(restored.finalText, "original final")
    }

    func testPromotionSwitchesProvenanceAndAlignmentAndCanRestoreOriginal() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        f.record.timedTextData = Data("original timing".utf8)
        f.record.speakerWordsData = Data("original words".utf8)
        f.record.speakerNamesData = Data("original speakers".utf8)
        f.record.processingState = .failed
        f.record.processingFailureMessage = "Previous processing failed"
        let original = HistoryTranscriptionVersion.capture(f.record)
        let version = alternative()
        try append(version, to: f)
        try f.history.promoteTranscriptionVersion(version.id, in: f.record)
        XCTAssertEqual(f.record.rawText, "new raw")
        XCTAssertEqual(f.record.finalText, "new final")
        XCTAssertEqual(f.record.engineUsed, "other-engine")
        XCTAssertEqual(f.record.modelUsed, "Other Model")
        XCTAssertEqual(f.record.language, "de")
        XCTAssertNil(f.record.timedTextData)
        XCTAssertNil(f.record.speakerWordsData)
        XCTAssertNil(f.record.speakerNamesData)
        XCTAssertEqual(f.record.processingState, .ready)
        XCTAssertNil(f.record.processingFailureMessage)
        XCTAssertEqual(HistoryExporter.exportPlainText(f.record), "new final")
        XCTAssertEqual(f.record.activeTranscriptionVersionID, version.id)
        XCTAssertTrue(version.matchesContent(of: f.record))
        try f.history.promoteTranscriptionVersion(original.id, in: f.record)
        XCTAssertEqual(HistoryTranscriptionVersion.capture(f.record), original)
        XCTAssertEqual(try f.record.savedTranscriptionVersions().count, 2)
    }

    func testSanitizedVersionSurvivesReopenAndPromotion() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        var version = alternative()
        version.rawText = "new\0 raw"
        version.finalText = "new \0final\0"
        try append(version, to: f)

        version.rawText = "new raw"
        version.finalText = "new final"
        XCTAssertEqual(try f.record.savedTranscriptionVersions().last, version)
        XCTAssertEqual(f.record.finalText, "original final")

        let reopened = HistoryService(appSupportDirectory: f.directory)
        let restored = try XCTUnwrap(reopened.record(withID: f.record.id))
        XCTAssertEqual(try restored.savedTranscriptionVersions().last, version)
        try reopened.promoteTranscriptionVersion(version.id, in: restored)
        XCTAssertEqual(restored.rawText, "new raw")
        XCTAssertEqual(restored.finalText, "new final")
        XCTAssertTrue(version.isActive(in: restored))
    }

    func testNullAndWhitespaceOnlyTextCannotBeArchived() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        for keyPath in [\HistoryTranscriptionVersion.rawText, \.finalText] {
            var version = alternative()
            version[keyPath: keyPath] = "\0 \n\0"
            XCTAssertThrowsError(try append(version, to: f))
            XCTAssertNil(f.record.transcriptionVersionsData)
            XCTAssertEqual(f.record.finalText, "original final")
        }
    }

    func testPromotionPreservesManualEditsAndRemoteContentAsAdditionalVersion() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        let version = alternative()
        try append(version, to: f)
        f.history.updateRecord(f.record, finalText: "manual correction")
        try f.history.promoteTranscriptionVersion(version.id, in: f.record)
        let versions = try f.record.savedTranscriptionVersions()
        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(versions.first?.finalText, "original final")
        XCTAssertEqual(versions.last?.finalText, "manual correction")
        XCTAssertEqual(f.record.finalText, "new final")
    }

    func testDiscardProtectsOriginalAndActiveVersionAndEntryDeletionRemovesVersions() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        let version = alternative()
        try append(version, to: f)
        XCTAssertThrowsError(try f.history.discardTranscriptionVersion(f.record.id, in: f.record))
        try f.history.promoteTranscriptionVersion(version.id, in: f.record)
        XCTAssertThrowsError(try f.history.discardTranscriptionVersion(version.id, in: f.record))
        try f.history.promoteTranscriptionVersion(f.record.id, in: f.record)
        try f.history.discardTranscriptionVersion(version.id, in: f.record)
        XCTAssertEqual(try f.record.savedTranscriptionVersions().count, 1)
        let id = f.record.id
        f.history.deleteRecord(withID: id)
        XCTAssertNil(f.history.record(withID: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.audioURL.path))
    }

    func testEmptyStaleDeletedAndCorruptRecordsCannotAcceptAlternative() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        let expected = HistoryTranscriptionVersion.capture(f.record)
        var empty = alternative()
        empty.finalText = " \n"
        XCTAssertThrowsError(try append(empty, to: f))
        XCTAssertNil(f.record.transcriptionVersionsData)
        f.history.updateRecord(f.record, finalText: "edited during processing")
        XCTAssertThrowsError(try f.history.appendTranscriptionVersion(alternative(), to: f.record, expected: expected))
        XCTAssertNil(f.record.transcriptionVersionsData)
        f.record.transcriptionVersionsData = Data("broken".utf8)
        XCTAssertThrowsError(try append(alternative(), to: f))
        XCTAssertEqual(f.record.transcriptionVersionsData, Data("broken".utf8))
        f.history.deleteRecord(withID: f.record.id)
        XCTAssertThrowsError(try append(alternative(), to: f))
    }

    func testPersistenceFailureRollsBackAppendPromotionAndDiscard() async throws {
        let fails = TestFlag(false)
        let f = try await fixture { context in
            if fails.value { throw CocoaError(.fileWriteOutOfSpace) }
            try context.save()
        }
        defer { TestSupport.remove(f.directory) }
        let original = HistoryTranscriptionVersion.capture(f.record)
        let originalDate = f.record.contentUpdatedAt
        let version = alternative()
        fails.value = true
        XCTAssertThrowsError(try append(version, to: f))
        XCTAssertNil(f.record.transcriptionVersionsData)
        fails.value = false
        try append(version, to: f)
        let archive = f.record.transcriptionVersionsData
        fails.value = true
        XCTAssertThrowsError(try f.history.promoteTranscriptionVersion(version.id, in: f.record))
        XCTAssertEqual(HistoryTranscriptionVersion.capture(f.record), original)
        XCTAssertEqual(f.record.contentUpdatedAt, originalDate)
        XCTAssertNil(f.record.activeTranscriptionVersionID)
        XCTAssertEqual(f.record.transcriptionVersionsData, archive)
        XCTAssertThrowsError(try f.history.discardTranscriptionVersion(version.id, in: f.record))
        XCTAssertEqual(f.record.transcriptionVersionsData, archive)
    }

    func testCloudConsentAndDownloadConsentAreRequiredBeforeAnyIO() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        var loads = 0
        var downloads = 0
        var runs = 0
        let version = alternative()
        let service = HistoryRetranscriptionService(
            history: f.history,
            planBuilder: { _ in .init(requiresCloudConfirmation: true, run: { _ in runs += 1; return version }) },
            isBusy: { false }, loadAudio: { _ in loads += 1; return [0.1] },
            canRetrieveAudio: { _ in true }, retrieveAudio: { _ in downloads += 1; return f.audioURL }
        )
        let request = HistoryRetranscriptionService.Request(engineID: "cloud", modelID: "paid", language: "de")
        service.start(record: f.record, request: request, cloudConfirmed: false, downloadConfirmed: true)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertNil(service.runningRecordID)
        try FileManager.default.removeItem(at: f.audioURL)
        service.start(record: f.record, request: request, cloudConfirmed: true, downloadConfirmed: false)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(runs, 0)
        XCTAssertNil(f.record.transcriptionVersionsData)
    }

    func testCancellationRetainsLeaseUntilNonCooperativeProviderFinishesAndDiscardsLateResult() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        let original = HistoryTranscriptionVersion.capture(f.record)
        var continuation: CheckedContinuation<HistoryTranscriptionVersion, Never>?
        let service = HistoryRetranscriptionService(
            history: f.history,
            planBuilder: { _ in .init(requiresCloudConfirmation: false, run: { _ in
                XCTAssertTrue(HistoryRetranscriptionActivity.ownsEngine)
                return await withCheckedContinuation { continuation = $0 }
            }) }, isBusy: { false }, loadAudio: { _ in [0.1] }
        )
        service.start(record: f.record, request: .init(engineID: "local"), cloudConfirmed: false, downloadConfirmed: false)
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try XCTUnwrap(continuation)
        service.cancel()
        XCTAssertEqual(HistoryRetranscriptionActivity.recordID, f.record.id)
        XCTAssertThrowsError(try HistoryRetranscriptionActivity.checkEngineAccess())
        pending.resume(returning: alternative())
        try await wait(service)
        XCTAssertNil(HistoryRetranscriptionActivity.recordID)
        XCTAssertNil(f.record.transcriptionVersionsData)
        XCTAssertEqual(HistoryTranscriptionVersion.capture(f.record), original)
        XCTAssertNil(service.errorMessage)
    }

    func testFileTranscriptionAvailabilityTracksComparisonThroughCancellation() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        let suite = "HistoryComparisonFileAvailability-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var loads = 0
        func makeFileViewModel() -> FileTranscriptionViewModel {
            let viewModel = FileTranscriptionViewModel(
                modelManager: ModelManagerService(), audioFileService: AudioFileService(),
                dictionaryService: DictionaryService(appSupportDirectory: f.directory),
                defaults: defaults,
                audioSamplesLoader: { _, _, _ in loads += 1; return [0.1] },
                engineReadinessChecker: { _ in true }
            )
            viewModel.addFiles([f.audioURL])
            return viewModel
        }
        let fileViewModel = makeFileViewModel()
        var activityChanges: [Bool] = []
        let observation = fileViewModel.$isHistoryRetranscribing.sink { activityChanges.append($0) }
        defer { observation.cancel() }
        XCTAssertTrue(fileViewModel.canTranscribe)

        var continuation: CheckedContinuation<HistoryTranscriptionVersion, Never>?
        let service = HistoryRetranscriptionService(
            history: f.history,
            planBuilder: { _ in .init(requiresCloudConfirmation: false, run: { _ in
                await withCheckedContinuation { continuation = $0 }
            }) }, isBusy: { false }, loadAudio: { _ in [0.1] }
        )
        service.start(record: f.record, request: .init(engineID: "local"), cloudConfirmed: false, downloadConfirmed: false)
        XCTAssertTrue(fileViewModel.isHistoryRetranscribing)
        XCTAssertFalse(fileViewModel.canTranscribe)
        let newlyOpenedFileViewModel = makeFileViewModel()
        XCTAssertTrue(newlyOpenedFileViewModel.isHistoryRetranscribing)
        XCTAssertFalse(newlyOpenedFileViewModel.canTranscribe)

        fileViewModel.transcribeAll()
        newlyOpenedFileViewModel.transcribePending()
        XCTAssertEqual(fileViewModel.batchState, .idle)
        XCTAssertEqual(newlyOpenedFileViewModel.batchState, .idle)
        XCTAssertEqual(loads, 0)
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try XCTUnwrap(continuation)
        service.cancel()
        XCTAssertFalse(fileViewModel.canTranscribe)
        XCTAssertFalse(newlyOpenedFileViewModel.canTranscribe)
        pending.resume(returning: alternative())
        try await wait(service)
        XCTAssertTrue(fileViewModel.canTranscribe)
        XCTAssertTrue(newlyOpenedFileViewModel.canTranscribe)
        XCTAssertEqual(activityChanges, [false, true, false])
        XCTAssertNil(f.record.transcriptionVersionsData)
    }

    func testProviderErrorAndEmptyResultDoNotMutateHistory() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        var shouldThrow = true
        var version = alternative()
        version.rawText = ""
        let service = HistoryRetranscriptionService(
            history: f.history,
            planBuilder: { _ in .init(requiresCloudConfirmation: false, run: { _ in
                if shouldThrow { throw URLError(.notConnectedToInternet) }
                return version
            }) }, isBusy: { false }, loadAudio: { _ in [0.1] }
        )
        for value in [true, false] {
            shouldThrow = value
            service.start(record: f.record, request: .init(engineID: "local"), cloudConfirmed: false, downloadConfirmed: false)
            try await wait(service)
            XCTAssertNil(f.record.transcriptionVersionsData)
            XCTAssertEqual(f.record.finalText, "original final")
            XCTAssertNotNil(service.errorMessage)
        }
    }

    func testBusyAndUnavailableSelectionsFailBeforeAudioLoad() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        let busy = TestFlag(true)
        var loads = 0
        let service = HistoryRetranscriptionService(
            history: f.history,
            planBuilder: { _ in throw HistoryRetranscriptionError.unavailable },
            isBusy: { busy.value }, loadAudio: { _ in loads += 1; return [0.1] }
        )
        for value in [true, false] {
            busy.value = value
            service.start(record: f.record, request: .init(engineID: "removed"), cloudConfirmed: true, downloadConfirmed: true)
            XCTAssertNil(service.runningRecordID)
            XCTAssertNotNil(service.errorMessage)
        }
        XCTAssertEqual(loads, 0)
        XCTAssertNil(f.record.transcriptionVersionsData)
    }

    func testOnlyPromotedTextIsSearchedExportedAndSyncedAndOldAlignmentIsRejected() async throws {
        let suite = "HistoryRetranscriptionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        let f = try await fixture(sync: preferences)
        defer { TestSupport.remove(f.directory) }
        let originalTranscript = SpeakerTranscript(source: .localDiarizer, segments: [
            SpeakerTranscriptSegment(text: "original final", start: 0, end: 12, speakerID: "S1")
        ])
        f.record.speakerTranscript = originalTranscript
        f.record.speakerTranscriptState = .ready
        f.record.speakerTranscriptUpdatedAt = Date(timeIntervalSinceNow: -30)
        let before = try XCTUnwrap(f.history.userDataSyncHistoryRecords().first)
        let version = alternative()
        try append(version, to: f)
        XCTAssertEqual(f.history.userDataSyncHistoryRecords().first?.content, before.content)
        XCTAssertFalse(HistoryExporter.exportJSON(f.record).contains("new final"))
        XCTAssertEqual(f.history.recordCount(query: HistoryQuery(searchText: "new final")), 0)
        try f.history.promoteTranscriptionVersion(version.id, in: f.record)
        XCTAssertEqual(f.history.recordCount(query: HistoryQuery(searchText: "new final")), 1)
        let promoted = try XCTUnwrap(f.history.userDataSyncHistoryRecords().first)
        XCTAssertEqual(promoted.content.finalText, "new final")
        XCTAssertNotNil(promoted.content.alignmentResetAt)
        XCTAssertNil(promoted.transcript)

        let receiverDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(receiverDirectory) }
        let receiver = HistoryService(appSupportDirectory: receiverDirectory, historySyncPreferences: preferences)
        let oldTranscript = try XCTUnwrap(before.transcript)
        try receiver.applyUserDataSyncMutations([.upsertHistoryContent(before.content), .upsertHistoryTranscript(oldTranscript)])
        let remote = try XCTUnwrap(receiver.record(withID: f.record.id))
        XCTAssertNotNil(remote.speakerTranscript)
        try receiver.applyUserDataSyncMutations([.upsertHistoryContent(promoted.content), .upsertHistoryTranscript(oldTranscript)])
        XCTAssertEqual(remote.finalText, "new final")
        XCTAssertNil(remote.speakerTranscript)
        XCTAssertNil(remote.transcriptionVersionsData)
        // Returning to the original sends its matching alignment at the promotion timestamp.
        try f.history.promoteTranscriptionVersion(f.record.id, in: f.record)
        let restored = try XCTUnwrap(f.history.userDataSyncHistoryRecords().first)
        try receiver.applyUserDataSyncMutations([
            .upsertHistoryContent(restored.content), .upsertHistoryTranscript(try XCTUnwrap(restored.transcript))
        ])
        XCTAssertEqual(remote.speakerTranscript?.revision, originalTranscript.revision)
        XCTAssertEqual(remote.finalText, "original final")
    }

    func testAudioRemovedDuringRunAndSecondConcurrentRunCannotCommit() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        var continuation: CheckedContinuation<HistoryTranscriptionVersion, Never>?
        var invocations = 0
        let service = HistoryRetranscriptionService(
            history: f.history,
            planBuilder: { _ in .init(requiresCloudConfirmation: false, run: { _ in
                invocations += 1
                return await withCheckedContinuation { continuation = $0 }
            }) }, isBusy: { false }, loadAudio: { _ in [0.1] }
        )
        let request = HistoryRetranscriptionService.Request(engineID: "local")
        service.start(record: f.record, request: request, cloudConfirmed: false, downloadConfirmed: false)
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try XCTUnwrap(continuation)
        service.start(record: f.record, request: request, cloudConfirmed: false, downloadConfirmed: false)
        XCTAssertEqual(invocations, 1)
        try FileManager.default.removeItem(at: f.audioURL)
        pending.resume(returning: alternative())
        try await wait(service)
        XCTAssertNil(f.record.transcriptionVersionsData)
        XCTAssertNotNil(service.errorMessage)
    }

    func testConfirmedPlanKeepsProviderAndWorkflowChoiceAndDoesNotRebuildFromMutableDefaults() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        var captured: HistoryRetranscriptionService.Request?
        var builds = 0
        let version = alternative()
        let service = HistoryRetranscriptionService(
            history: f.history,
            planBuilder: { request in
                captured = request
                builds += 1
                return .init(requiresCloudConfirmation: true, cloudProviders: ["Explicit Provider"], run: { _ in version })
            }, isBusy: { false }, loadAudio: { _ in [0.1] }
        )
        let workflowID = UUID()
        let request = HistoryRetranscriptionService.Request(engineID: "chosen", modelID: "chosen-model", language: "de", workflowID: workflowID)
        let plan = try service.previewPlan(request)
        var changedRequest = request
        changedRequest.engineID = "unconfirmed-provider"
        service.start(record: f.record, request: changedRequest, cloudConfirmed: true, downloadConfirmed: false, confirmedPlan: plan)
        XCTAssertNil(service.runningRecordID)
        XCTAssertNotNil(service.errorMessage)
        service.start(record: f.record, request: request, cloudConfirmed: true, downloadConfirmed: false, confirmedPlan: plan)
        try await wait(service)
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(captured?.engineID, "chosen")
        XCTAssertEqual(captured?.modelID, "chosen-model")
        XCTAssertEqual(captured?.language, "de")
        XCTAssertEqual(captured?.workflowID, workflowID)
        XCTAssertEqual(try f.record.savedTranscriptionVersions().last, version)
        XCTAssertEqual(f.record.finalText, "original final")
    }

    func testClosingComparisonReloadsEditorWithoutRestoringTheOldDraft() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        let viewModel = HistoryViewModel(
            historyService: f.history, textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: f.directory)
        )
        viewModel.requestRecordSelection([f.record.id])
        XCTAssertEqual(viewModel.editedText, "original final")
        let version = alternative()
        try append(version, to: f)
        try f.history.promoteTranscriptionVersion(version.id, in: f.record)
        viewModel.reloadAfterTranscriptionComparison()
        XCTAssertEqual(viewModel.editedText, "new final")
        XCTAssertFalse(viewModel.isDirty)
        XCTAssertFalse(viewModel.showCorrectionBanner)
    }

    func testClosingComparisonPreservesSelectionBeyondFirstPageAndListIdentity() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        for index in 1...125 {
            XCTAssertTrue(f.history.addRecord(
                timestamp: f.record.timestamp.addingTimeInterval(Double(index)),
                rawText: "Newer entry \(index)", finalText: "Newer entry \(index)",
                appName: "Test", appBundleIdentifier: nil, durationSeconds: 1,
                language: "en", engineUsed: "test"
            ))
        }
        let viewModel = HistoryViewModel(
            historyService: f.history, textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: f.directory)
        )
        viewModel.activate()
        defer { viewModel.deactivate() }
        await viewModel.waitForPendingWork()
        XCTAssertEqual(viewModel.records.count, 100)
        viewModel.loadMoreRecords()
        XCTAssertEqual(viewModel.records.count, 126)
        viewModel.requestRecordSelection([f.record.id])
        let queryID = viewModel.queryID

        viewModel.reloadAfterTranscriptionComparison()
        XCTAssertEqual(viewModel.selectedRecord?.id, f.record.id)
        XCTAssertEqual(viewModel.editedText, "original final")
        XCTAssertEqual(viewModel.records.count, 126)
        XCTAssertEqual(viewModel.queryID, queryID)

        let version = alternative()
        try append(version, to: f)
        try f.history.promoteTranscriptionVersion(version.id, in: f.record)
        viewModel.reloadAfterTranscriptionComparison()
        await viewModel.waitForPendingWork()
        XCTAssertEqual(viewModel.selectedRecord?.id, f.record.id)
        XCTAssertEqual(viewModel.editedText, "new final")
        XCTAssertEqual(viewModel.records.count, 126)
        XCTAssertEqual(viewModel.queryID, queryID)
        XCTAssertFalse(viewModel.isDirty)
    }

    func testWorkflowNumberFormattingOverridesGlobalDefaultDuringRetranscription() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        let previousPluginManager = PluginManager.shared
        let defaults = UserDefaults.standard
        let keys = [UserDefaultsKeys.transcriptionNumberNormalizationEnabled,
                    UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue]
        let savedDefaults = keys.map { defaults.object(forKey: $0) }
        defer {
            PluginManager.shared = previousPluginManager
            for (key, value) in zip(keys, savedDefaults) { defaults.set(value, forKey: key) }
            TestSupport.remove(directory)
        }
        defaults.set(10, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
        let engine = HistoryComparisonNumberEngine()
        PluginManager.shared = PluginManager(appSupportDirectory: directory)
        PluginManager.shared.loadedPlugins = [LoadedPlugin(
            manifest: PluginManifest(id: HistoryComparisonNumberEngine.pluginId,
                                     name: "Number test", version: "1.0.0", principalClass: "HistoryComparisonNumberEngine"),
            instance: engine, bundle: Bundle.main, sourceURL: directory, isEnabled: true
        )]
        let manager = ModelManagerService()
        let request = HistoryRetranscriptionService.Request(engineID: engine.providerId, language: "en")
        for globalEnabled in [false, true] {
            defaults.set(globalEnabled, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
            for mode: WorkflowNumberNormalizationMode? in [nil, .inherit, .enabled, .disabled] {
                let workflow = mode.map { mode in
                    Workflow(name: "Numbers", template: .dictation, trigger: WorkflowTrigger(kind: .manual),
                             output: WorkflowOutput(numberNormalizationModeRaw: mode.rawValue))
                }
                let result = try await HistoryRetranscriptionEnvironment.transcribe(
                    samples: [0.1, -0.1], request: request, modelID: nil,
                    workflow: workflow, manager: manager, dictionaryPrompt: nil, dictionaryHints: []
                )
                let normalizes = mode?.overrideValue ?? globalEnabled
                XCTAssertEqual(result.text, normalizes ? "I counted 42 apples." : "I counted forty two apples.",
                               "global=\(globalEnabled), workflow=\(String(describing: mode))")
            }
        }
    }

    func testIdenticalTextFromAnotherWorkflowStillHasItsOwnActiveVersion() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        var version = HistoryTranscriptionVersion.capture(f.record)
        version.id = UUID()
        version.workflowID = UUID()
        version.workflowName = "Identity Workflow"
        XCTAssertTrue(version.matchesContent(of: f.record))
        XCTAssertFalse(version.isActive(in: f.record))
        try append(version, to: f)
        try f.history.promoteTranscriptionVersion(version.id, in: f.record)
        XCTAssertTrue(version.isActive(in: f.record))
        XCTAssertEqual(f.record.finalText, "original final")
    }

    func testReplacingAudioReferenceDuringPreparationDoesNotSendTheOldAudioToProvider() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        var runs = 0
        let version = alternative()
        let service = HistoryRetranscriptionService(
            history: f.history,
            planBuilder: { _ in .init(requiresCloudConfirmation: false, run: { _ in runs += 1; return version }) },
            isBusy: { false }, loadAudio: { _ in
                f.record.audioFileName = "replacement.wav"
                return [0.1]
            }
        )
        service.start(record: f.record, request: .init(engineID: "local"), cloudConfirmed: false, downloadConfirmed: false)
        try await wait(service)
        XCTAssertEqual(runs, 0)
        XCTAssertNil(f.record.transcriptionVersionsData)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertEqual(f.record.audioFileName, "replacement.wav")
    }

    func testLocalRestoreEnginesDoNotRequireCloudConsentButUnknownEnginesDo() {
        // Parakeet/WhisperKit expose passive restore without the optional cache-deletion API.
        XCTAssertTrue(HistoryRetranscriptionEnvironment.isLocal(HistoryComparisonRestoreEngine()))
        XCTAssertTrue(HistoryRetranscriptionEnvironment.isLocal(HistoryComparisonDownloadedEngine()))
        let apple = HistoryComparisonTestEngine()
        apple.providerID = AppleSpeechModelSelection.providerId
        XCTAssertTrue(HistoryRetranscriptionEnvironment.isLocal(apple))
        XCTAssertFalse(HistoryRetranscriptionEnvironment.isLocal(HistoryComparisonTestEngine()))
    }

    private func wait(_ service: HistoryRetranscriptionService) async throws {
        for _ in 0..<100 {
            if service.runningRecordID == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Comparison did not finish")
    }
}

private class HistoryComparisonTestEngine: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.history-comparison"
    static let pluginName = "History Comparison Test Engine"
    required override init() {}
    var providerID = "unknown-engine"
    var providerId: String { providerID }
    var providerDisplayName: String { "Test Engine" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [] }
    var selectedModelId: String? { nil }
    var supportsTranslation: Bool { false }
    func activate(host: HostServices) {}
    func deactivate() {}
    func selectModel(_ modelId: String) {}
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "test", detectedLanguage: language)
    }
}

private final class HistoryComparisonRestoreEngine: HistoryComparisonTestEngine, PassiveModelRestoreProviding, @unchecked Sendable {
    func requestPassiveModelRestore() {}
}

private final class HistoryComparisonDownloadedEngine: HistoryComparisonTestEngine, PluginDownloadedModelManaging, @unchecked Sendable {
    var downloadedModels: [PluginModelInfo] { [] }
    func deleteDownloadedModel(_ modelId: String) async throws {}
}

private final class HistoryComparisonNumberEngine: HistoryComparisonTestEngine, @unchecked Sendable {
    override func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "I counted forty two apples.", detectedLanguage: "en")
    }
}
