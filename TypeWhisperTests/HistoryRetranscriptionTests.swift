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

    @MainActor
    private final class SegmentGate {
        var pending: [CheckedContinuation<Void, Never>] = []
        func wait() async { await withCheckedContinuation { pending.append($0) } }
        func releaseFirst() { if !pending.isEmpty { pending.removeFirst().resume() } }
        func releaseAll() { while !pending.isEmpty { releaseFirst() } }
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

    func testPromotionKeepsMicrophoneEvidenceForNewAndPreviouslyArchivedVersions() async throws {
        for hasArchivedEvidence in [false, true] {
            let f = try await fixture()
            defer { TestSupport.remove(f.directory) }
            let evidence = try JSONEncoder().encode([[1.0, 2.0], [4.0, 5.0]])
            f.record.speakerOwnSpeechData = evidence
            let version = alternative()
            try append(version, to: f)
            if hasArchivedEvidence {
                // Older archives included this recording-level field in each snapshot.
                var archive = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: XCTUnwrap(f.record.transcriptionVersionsData)
                ) as? [[String: Any]])
                archive[1]["speakerOwnSpeechData"] = Data("outdated evidence".utf8).base64EncodedString()
                f.record.transcriptionVersionsData = try JSONSerialization.data(withJSONObject: archive)
            }
            try f.history.promoteTranscriptionVersion(version.id, in: f.record)
            XCTAssertEqual(f.record.speakerOwnSpeechData, evidence)
            XCTAssertTrue(try XCTUnwrap(f.record.savedTranscriptionVersions().last).isActive(in: f.record))
            let reopened = HistoryService(appSupportDirectory: f.directory)
            XCTAssertEqual(reopened.record(withID: f.record.id)?.speakerOwnSpeechData, evidence)
            try f.history.promoteTranscriptionVersion(f.record.id, in: f.record)
            XCTAssertEqual(f.record.speakerOwnSpeechData, evidence)
            XCTAssertEqual(try f.record.savedTranscriptionVersions().count, 2)
        }
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

    func testArchivedEditsKeepTheirSourceProvenanceWithoutMisattributingSyncedReplacements() async throws {
        for synchronize in [false, true] {
            let f = try await fixture()
            defer { TestSupport.remove(f.directory) }
            var source = alternative()
            source.workflowRecorded = true
            source.workflowConfiguration = Data(#"{"template":"cleanedText"}"#.utf8)
            try append(source, to: f)
            try f.history.promoteTranscriptionVersion(source.id, in: f.record)
            let content = UserDataSyncHistoryContentV1(
                recordID: f.record.id, createdAt: f.record.timestamp.addingTimeInterval(-0.0001),
                updatedAt: Date(timeIntervalSinceNow: 60), originDeviceID: "another-device",
                originPlatform: "macOS", source: f.record.source.rawValue, processingState: "ready",
                rawTranscript: source.rawText, finalText: synchronize ? "replacement text" : source.finalText,
                durationSeconds: f.record.durationSeconds, detectedLanguage: source.language,
                engineDisplayName: source.engineID, modelDisplayName: source.modelName
            )
            try f.history.applyUserDataSyncMutations([.upsertHistoryContent(content)])
            XCTAssertEqual(f.record.activeTranscriptionVersionID, synchronize ? nil : source.id)
            if !synchronize {
                // An unchanged echo with normalized date precision retains the source of a later edit.
                f.history.updateRecord(f.record, finalText: "replacement text")
            }
            let editedAt = f.record.contentUpdatedAt
            try f.history.promoteTranscriptionVersion(f.record.id, in: f.record)
            let edited = try XCTUnwrap(f.record.savedTranscriptionVersions().last)
            XCTAssertNotEqual(edited.id, source.id)
            XCTAssertEqual(edited.createdAt, editedAt)
            XCTAssertEqual(edited.rawText, source.rawText)
            XCTAssertEqual(edited.finalText, "replacement text")
            XCTAssertEqual(edited.engineID, source.engineID)
            XCTAssertEqual(edited.modelName, source.modelName)
            XCTAssertEqual(edited.language, source.language)
            XCTAssertEqual(edited.engineName, synchronize ? nil : source.engineName)
            XCTAssertEqual(edited.modelID, synchronize ? nil : source.modelID)
            XCTAssertEqual(edited.requestedLanguage, synchronize ? nil : source.requestedLanguage)
            XCTAssertEqual(edited.workflowID, synchronize ? nil : source.workflowID)
            XCTAssertEqual(edited.workflowName, synchronize ? nil : source.workflowName)
            XCTAssertEqual(edited.workflowConfiguration, synchronize ? nil : source.workflowConfiguration)
            XCTAssertEqual(edited.workflowRecorded, !synchronize)
            try f.history.promoteTranscriptionVersion(edited.id, in: f.record)
            XCTAssertTrue(edited.isActive(in: f.record))
            let reopened = HistoryService(appSupportDirectory: f.directory)
            let restored = try XCTUnwrap(reopened.record(withID: f.record.id))
            XCTAssertEqual(try restored.savedTranscriptionVersions().last, edited)
            XCTAssertTrue(edited.isActive(in: restored))
        }
    }

    func testDiscardProtectsOriginalAndActiveVersionAndEntryDeletionRemovesVersions() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        let version = alternative()
        try append(version, to: f)
        XCTAssertFalse(HistoryTranscriptionVersion.capture(f.record).canDiscard(in: f.record))
        XCTAssertTrue(version.canDiscard(in: f.record))
        XCTAssertThrowsError(try f.history.discardTranscriptionVersion(f.record.id, in: f.record))
        try f.history.promoteTranscriptionVersion(version.id, in: f.record)
        XCTAssertFalse(version.canDiscard(in: f.record))
        XCTAssertThrowsError(try f.history.discardTranscriptionVersion(version.id, in: f.record))
        try f.history.promoteTranscriptionVersion(f.record.id, in: f.record)
        try f.history.discardTranscriptionVersion(version.id, in: f.record)
        XCTAssertEqual(try f.record.savedTranscriptionVersions().count, 1)
        let id = f.record.id
        f.history.deleteRecord(withID: id)
        XCTAssertNil(f.history.record(withID: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.audioURL.path))
    }

    func testComparisonRequiresRunnableAudioOrAnInactiveSavedVersion() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        let retrievable = TestFlag(false)
        let service = HistoryRetranscriptionService(
            history: f.history,
            planBuilder: { _ in throw HistoryRetranscriptionError.unavailable },
            isBusy: { false }, loadAudio: { _ in [] },
            canRetrieveAudio: { _ in retrievable.value }
        )
        XCTAssertTrue(service.canCompare(f.record), "Local audio allows creating a new version")
        let version = alternative()
        try append(version, to: f)
        try FileManager.default.removeItem(at: f.audioURL)
        XCTAssertTrue(service.canCompare(f.record), "Saved alternatives do not require audio")
        try f.history.discardTranscriptionVersion(version.id, in: f.record)
        XCTAssertEqual(try f.record.savedTranscriptionVersions().map(\.id), [f.record.id])
        XCTAssertFalse(service.canCompare(f.record), "The sole active original offers nothing to compare")
        retrievable.value = true
        XCTAssertTrue(service.canCompare(f.record), "Retrievable audio still allows a new version")
        retrievable.value = false
        f.history.updateRecord(f.record, finalText: "Manual replacement")
        XCTAssertTrue(service.canCompare(f.record), "The archived original can be compared with a manual edit")
        f.record.transcriptionVersionsData = Data("invalid archive".utf8)
        XCTAssertFalse(service.canCompare(f.record), "An unreadable archive offers no candidates")
    }

    func testDiscardFormerlyActiveVersionAfterManualEditOrSynchronizedReplacement() async throws {
        for synchronize in [false, true] {
            let f = try await fixture()
            defer { TestSupport.remove(f.directory) }
            let version = alternative()
            try append(version, to: f)
            try f.history.promoteTranscriptionVersion(version.id, in: f.record)
            XCTAssertTrue(version.isActive(in: f.record))
            if synchronize {
                let content = UserDataSyncHistoryContentV1(
                    recordID: f.record.id, createdAt: f.record.timestamp,
                    updatedAt: Date(timeIntervalSinceNow: 60), originDeviceID: "another-device",
                    originPlatform: "macOS", source: f.record.source.rawValue, processingState: "ready",
                    rawTranscript: "remote raw", finalText: "replaced text",
                    durationSeconds: f.record.durationSeconds, engineDisplayName: "remote engine"
                )
                try f.history.applyUserDataSyncMutations([.upsertHistoryContent(content)])
            } else {
                f.history.updateRecord(f.record, finalText: "replaced text")
            }
            XCTAssertFalse(version.isActive(in: f.record))
            XCTAssertTrue(version.canDiscard(in: f.record), "The comparison must offer the discard action")
            let current = HistoryTranscriptionVersion.capture(f.record)
            try f.history.discardTranscriptionVersion(version.id, in: f.record)
            XCTAssertEqual(try f.record.savedTranscriptionVersions().map(\.id), [f.record.id])
            XCTAssertNil(f.record.activeTranscriptionVersionID)
            XCTAssertEqual(HistoryTranscriptionVersion.capture(f.record), current)

            let reopened = HistoryService(appSupportDirectory: f.directory)
            let restored = try XCTUnwrap(reopened.record(withID: f.record.id))
            XCTAssertNil(restored.activeTranscriptionVersionID)
            XCTAssertEqual(try restored.savedTranscriptionVersions().map(\.id), [f.record.id])
            XCTAssertEqual(restored.finalText, "replaced text")
        }
    }

    func testFailedDiscardRestoresFormerlyActiveVersionAndItsIdentifier() async throws {
        let fails = TestFlag(false)
        let f = try await fixture { context in
            if fails.value { throw CocoaError(.fileWriteOutOfSpace) }
            try context.save()
        }
        defer { TestSupport.remove(f.directory) }
        let version = alternative()
        try append(version, to: f)
        try f.history.promoteTranscriptionVersion(version.id, in: f.record)
        f.history.updateRecord(f.record, finalText: "manual replacement")
        let archive = f.record.transcriptionVersionsData
        fails.value = true
        XCTAssertThrowsError(try f.history.discardTranscriptionVersion(version.id, in: f.record)) {
            XCTAssertEqual(($0 as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        XCTAssertEqual(f.record.transcriptionVersionsData, archive)
        XCTAssertEqual(f.record.activeTranscriptionVersionID, version.id)
        XCTAssertEqual(f.record.finalText, "manual replacement")
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
        let engine = HistoryComparisonTestEngine()
        let environment = try makeEnvironment(plugins: [engine])
        let original = HistoryTranscriptionVersion.capture(f.record)
        var continuation: CheckedContinuation<HistoryTranscriptionVersion, Never>?
        let service = HistoryRetranscriptionService(
            history: f.history,
            planBuilder: { _ in .init(requiresCloudConfirmation: false, run: { _ in
                XCTAssertTrue(HistoryRetranscriptionActivity.ownsEngine)
                try await self.runEngineRequest(.batch, manager: environment.manager, engineID: engine.providerId)
                return await withCheckedContinuation { continuation = $0 }
            }) }, isBusy: { false }, loadAudio: { _ in [0.1] }
        )
        defer { service.cancel() }
        service.start(record: f.record, request: .init(engineID: "local"), cloudConfirmed: false, downloadConfirmed: false)
        for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pending = try XCTUnwrap(continuation)
        service.cancel()
        XCTAssertEqual(HistoryRetranscriptionActivity.recordID, f.record.id)
        let finished = TestFlag(false)
        let backgroundJob = Task {
            defer { finished.value = true }
            try await runEngineRequest(.batch, manager: environment.manager, engineID: engine.providerId)
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(finished.value, "Cancellation must not release the provider before it stops")
        pending.resume(returning: alternative())
        try await wait(service)
        try await backgroundJob.value
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
        let sourceEvidence = try JSONEncoder().encode([[1.0, 2.0]])
        f.record.speakerOwnSpeechData = sourceEvidence
        let before = try XCTUnwrap(f.history.userDataSyncHistoryRecords().first)
        let version = alternative()
        try append(version, to: f)
        XCTAssertEqual(f.history.userDataSyncHistoryRecords().first?.content, before.content)
        XCTAssertFalse(HistoryExporter.exportJSON(f.record).contains("new final"))
        XCTAssertEqual(f.history.recordCount(query: HistoryQuery(searchText: "new final")), 0)
        try f.history.promoteTranscriptionVersion(version.id, in: f.record)
        XCTAssertEqual(f.history.recordCount(query: HistoryQuery(searchText: "new final")), 1)
        XCTAssertEqual(f.record.speakerOwnSpeechData, sourceEvidence)
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
        // Local microphone evidence belongs to the audio, not to synchronized text alignment.
        let receiverEvidence = try JSONEncoder().encode([[3.0, 4.0]])
        remote.speakerOwnSpeechData = receiverEvidence
        remote.timedTextData = try JSONEncoder().encode([
            TimedTextEntry(text: "original final", start: 0, end: 12, utf16Location: 0, utf16Length: 14)
        ])
        remote.timedTextGranularityRaw = TimedTextGranularity.segment.rawValue
        remote.speakerWordsData = try JSONEncoder().encode([TranscriptionWord(text: "original", start: 0, end: 1)])
        remote.speakerWordsAreFromSecondPass = true
        var names = SpeakerNameTable(transcriptRevision: originalTranscript.revision)
        names.setName("Me", for: "S1")
        remote.speakerNamesData = try JSONEncoder().encode(names)
        try receiver.applyUserDataSyncMutations([.upsertHistoryContent(promoted.content), .upsertHistoryTranscript(oldTranscript)])
        XCTAssertEqual(remote.finalText, "new final")
        XCTAssertNil(remote.speakerTranscript)
        XCTAssertNil(remote.speakerTranscriptStateRaw)
        XCTAssertNil(remote.speakerNamesData)
        XCTAssertNil(remote.timedTextData)
        XCTAssertNil(remote.timedTextGranularityRaw)
        XCTAssertNil(remote.speakerWordsData)
        XCTAssertNil(remote.speakerWordsAreFromSecondPass)
        XCTAssertEqual(remote.speakerOwnSpeechData, receiverEvidence)
        XCTAssertNil(remote.transcriptionVersionsData)
        try receiver.applyUserDataSyncMutations([.upsertHistoryContent(promoted.content)])
        XCTAssertEqual(remote.speakerOwnSpeechData, receiverEvidence, "Replaying a reset must preserve audio evidence")
        // Returning to the original sends its matching alignment at the promotion timestamp.
        try f.history.promoteTranscriptionVersion(f.record.id, in: f.record)
        let restored = try XCTUnwrap(f.history.userDataSyncHistoryRecords().first)
        try receiver.applyUserDataSyncMutations([
            .upsertHistoryContent(restored.content), .upsertHistoryTranscript(try XCTUnwrap(restored.transcript))
        ])
        XCTAssertEqual(remote.speakerTranscript?.revision, originalTranscript.revision)
        XCTAssertEqual(remote.finalText, "original final")
        XCTAssertEqual(f.record.speakerOwnSpeechData, sourceEvidence)
        XCTAssertEqual(remote.speakerOwnSpeechData, receiverEvidence)
        let reopened = HistoryService(appSupportDirectory: receiverDirectory, historySyncPreferences: preferences)
        XCTAssertEqual(reopened.record(withID: f.record.id)?.speakerOwnSpeechData, receiverEvidence)
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

    func testAllEngineEntryPointsWaitForAnActiveComparison() async throws {
        let engine = HistoryComparisonTestEngine()
        let environment = try makeEnvironment(plugins: [engine])
        let previousActivity = HistoryRetranscriptionActivity.recordID
        defer { HistoryRetranscriptionActivity.recordID = previousActivity }
        for entryPoint in EngineEntryPoint.allCases {
            HistoryRetranscriptionActivity.recordID = UUID()
            let finished = TestFlag(false)
            let task = Task {
                defer { finished.value = true }
                try await runEngineRequest(entryPoint, manager: environment.manager, engineID: engine.providerId)
            }
            for _ in 0..<100 { await Task.yield() }
            XCTAssertFalse(finished.value, "\(entryPoint) must wait rather than fail")
            XCTAssertFalse(environment.manager.hasProtectedEngineUse)
            HistoryRetranscriptionActivity.recordID = nil
            do { try await task.value }
            catch { XCTFail("\(entryPoint) failed after the comparison released its engine: \(error)") }
        }
    }

    func testWaitingEngineRequestsCanBeCancelledWithoutReleasingTheComparison() async throws {
        let engine = HistoryComparisonTestEngine()
        let environment = try makeEnvironment(plugins: [engine])
        let previousActivity = HistoryRetranscriptionActivity.recordID
        defer { HistoryRetranscriptionActivity.recordID = previousActivity }
        let comparisonID = UUID()
        HistoryRetranscriptionActivity.recordID = comparisonID
        for entryPoint in EngineEntryPoint.allCases {
            let task = Task {
                try await runEngineRequest(entryPoint, manager: environment.manager, engineID: engine.providerId)
            }
            for _ in 0..<100 { await Task.yield() }
            task.cancel()
            do {
                try await task.value
                XCTFail("A cancelled \(entryPoint) request must not reach the engine")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(entryPoint): \(error)")
            }
            XCTAssertEqual(HistoryRetranscriptionActivity.recordID, comparisonID)
            XCTAssertFalse(environment.manager.hasProtectedEngineUse)
        }
    }

    private enum EngineEntryPoint: CaseIterable {
        case batch, progress, live
    }

    private func runEngineRequest(
        _ entryPoint: EngineEntryPoint, manager: ModelManagerService, engineID: String
    ) async throws {
        switch entryPoint {
        case .batch:
            let result = try await manager.transcribe(
                audioSamples: [0.1], language: "en", task: .transcribe, engineOverrideId: engineID
            )
            XCTAssertEqual(result.text, "test")
        case .progress:
            let result = try await manager.transcribe(
                audioSamples: [0.1], language: "en", task: .transcribe, engineOverrideId: engineID,
                onProgress: { _ in true }, onSourceProgress: { _ in true }
            )
            XCTAssertEqual(result.text, "test")
        case .live:
            let session = try await manager.createLiveTranscriptionSession(
                language: "en", task: .transcribe, engineOverrideId: engineID, onProgress: { _ in true }
            )
            XCTAssertNil(session, "The fixture engine uses batch fallback")
        }
    }

    func testPreparingAnotherComparisonClearsPriorRunErrorsEvenIfItsPlanIsUnavailable() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        let version = alternative()
        let service = HistoryRetranscriptionService(
            history: f.history, planBuilder: { request in
                if request.engineID == "missing" { throw HistoryRetranscriptionError.unavailable }
                return .init(requiresCloudConfirmation: true, run: { _ in version })
            }, isBusy: { false }, loadAudio: { _ in [0.1] }
        )
        let request = HistoryRetranscriptionService.Request(engineID: "cloud")
        for nextRequest in [request, .init(engineID: "missing")] {
            service.start(record: f.record, request: request, cloudConfirmed: false, downloadConfirmed: false)
            XCTAssertEqual(service.errorMessage, HistoryRetranscriptionError.confirmationRequired.localizedDescription)
            if nextRequest.engineID == "missing" {
                XCTAssertThrowsError(try service.previewPlan(nextRequest)) {
                    XCTAssertEqual($0.localizedDescription, HistoryRetranscriptionError.unavailable.localizedDescription)
                }
            } else {
                XCTAssertEqual(try service.previewPlan(nextRequest).confirmedRequest, nextRequest)
            }
            XCTAssertNil(service.errorMessage)
        }
    }

    func testComparisonRetainsRequestedLanguageWhenEngineDoesNotDetectOne() async throws {
        let engine = HistoryComparisonTestEngine()
        let environment = try makeEnvironment(plugins: [engine])
        let suite = "HistoryComparisonLanguage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        let cases: [(String?, String?)] = [("de", nil), ("de", "en"), (nil, nil)]
        for (requested, detected) in cases {
            let f = try await fixture(sync: preferences)
            defer { TestSupport.remove(f.directory) }
            engine.resultOverride = PluginTranscriptionResult(text: "language test", detectedLanguage: detected)
            let plan = try HistoryRetranscriptionEnvironment.plan(
                .init(engineID: engine.providerId, language: requested),
                manager: environment.manager, dictionary: environment.dictionary,
                workflows: [], promptProcessing: environment.promptProcessing
            )
            let version = try await plan.run([0.1])
            XCTAssertEqual(version.language, detected ?? requested)
            XCTAssertEqual(version.requestedLanguage, requested)
            try append(version, to: f)
            try f.history.promoteTranscriptionVersion(version.id, in: f.record)
            XCTAssertEqual(f.record.language, detected ?? requested)
            XCTAssertEqual(try XCTUnwrap(f.history.userDataSyncHistoryRecords().first).content.detectedLanguage, detected ?? requested)
            let reopened = HistoryService(appSupportDirectory: f.directory)
            XCTAssertEqual(reopened.record(withID: f.record.id)?.language, detected ?? requested)
        }
    }

    func testHistoryWorkflowAppliesRegexOnlyAfterFinalOutput() async throws {
        let engine = HistoryComparisonTestEngine()
        let raw = (0..<75).map { "Sentence \($0) keeps teh Dr and token together." }.joined(separator: " ")
        engine.resultOverride = PluginTranscriptionResult(text: raw)
        let llm = HistoryComparisonLLM()
        llm.handler = { $0.replacingOccurrences(of: "token", with: "Dr") }
        let environment = try makeEnvironment(plugins: [engine, llm])
        environment.dictionary.addEntry(type: .correction, original: "teh", replacement: "the")
        environment.dictionary.addEntry(type: .correction, original: #"\bDr\b"#, replacement: "Dr.", isRegex: true)
        for segmented in [false, true] {
            let workflow = Workflow(name: "Cleanup", template: .cleanedText, trigger: .manual(),
                behavior: WorkflowBehavior(providerId: llm.providerName, cloudModel: "test", segmentedPostProcessingEnabled: segmented),
                output: WorkflowOutput(format: "plaintext"))
            let plan = try HistoryRetranscriptionEnvironment.plan(.init(engineID: engine.providerId, workflowID: workflow.id),
                manager: environment.manager, dictionary: environment.dictionary, workflows: [workflow], promptProcessing: environment.promptProcessing)
            let before = llm.inputs.count
            let version = try await plan.run([0.1])
            let inputs = Array(llm.inputs.dropFirst(before))
            XCTAssertFalse(inputs.contains { $0.contains("Dr.") || $0.contains("teh") })
            XCTAssertEqual(version.finalText, raw.replacingOccurrences(of: "teh", with: "the")
                .replacingOccurrences(of: "token", with: "Dr").replacingOccurrences(of: "Dr", with: "Dr."))
            XCTAssertFalse(version.finalText.contains("Dr.."))
            if segmented { XCTAssertGreaterThan(inputs.count, 1) }
            let steps = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(version.pipelineSteps).utf8))
            XCTAssertEqual(steps, ["Corrections", "Cleanup", "Corrections"])
            XCTAssertTrue(environment.dictionary.entries.allSatisfy { $0.usageCount == 0 })
        }
        engine.resultOverride = PluginTranscriptionResult(text: "teh Dr")
        let plain = try HistoryRetranscriptionEnvironment.plan(.init(engineID: engine.providerId),
            manager: environment.manager, dictionary: environment.dictionary, workflows: [], promptProcessing: environment.promptProcessing)
        let version = try await plain.run([0.1])
        XCTAssertEqual(version.finalText, "the Dr.")
    }

    func testHistoryWorkflowPreservesCorrectionComposition() async throws {
        let engine = HistoryComparisonTestEngine()
        let raw = (0..<75).map { "Sentence \($0) keeps seed foo and source together." }.joined(separator: " ")
        engine.resultOverride = PluginTranscriptionResult(text: raw)
        let llm = HistoryComparisonLLM()
        llm.handler = { $0.replacingOccurrences(of: "source", with: "teh") }
        let environment = try makeEnvironment(plugins: [engine, llm])
        environment.dictionary.addEntry(type: .correction, original: "seed", replacement: "Seeded")
        environment.dictionary.addEntry(type: .correction, original: #"\bfoo\b"#, replacement: "teh", isRegex: true)
        environment.dictionary.addEntry(type: .correction, original: "teh", replacement: "the")
        for segmented in [false, true] {
            let workflow = Workflow(name: "Cleanup", template: .cleanedText, trigger: .manual(),
                behavior: WorkflowBehavior(providerId: llm.providerName, cloudModel: "test", segmentedPostProcessingEnabled: segmented),
                output: WorkflowOutput(format: "plaintext"))
            let plan = try HistoryRetranscriptionEnvironment.plan(.init(engineID: engine.providerId, workflowID: workflow.id),
                manager: environment.manager, dictionary: environment.dictionary, workflows: [workflow], promptProcessing: environment.promptProcessing)
            let before = llm.inputs.count
            let version = try await plan.run([0.1])
            let inputs = Array(llm.inputs.dropFirst(before))
            XCTAssertTrue(inputs.allSatisfy { $0.contains("foo") && !$0.contains("seed") && !$0.contains("teh") })
            XCTAssertEqual(version.finalText, raw.replacingOccurrences(of: "seed", with: "Seeded")
                .replacingOccurrences(of: "foo", with: "the").replacingOccurrences(of: "source", with: "the"))
            if segmented { XCTAssertGreaterThan(inputs.count, 1) }
            XCTAssertTrue(environment.dictionary.entries.allSatisfy { $0.usageCount == 0 })
        }
    }

    func testComparisonHonorsSegmentedWorkflowSettingsAndOutputEligibility() async throws {
        let engine = HistoryComparisonTestEngine()
        let text = (0..<75).map { "Sentence \($0) keeps TypeWhisper vocabulary and the original order." }.joined(separator: " ")
        engine.resultOverride = PluginTranscriptionResult(text: text)
        let llm = HistoryComparisonLLM()
        llm.handler = { $0.uppercased() }
        let environment = try makeEnvironment(plugins: [engine, llm])
        environment.dictionary.addEntry(type: .term, original: "TypeWhisper")
        let cases: [(enabled: Bool, format: String, app: String?, local: Bool, splits: Bool)] = [
            (true, "plaintext", nil, false, true),
            (false, "plaintext", nil, false, false),
            (true, "json", nil, false, false),
            (true, "auto", "com.apple.mail", false, false),
            (true, "plaintext", nil, true, false)
        ]
        for c in cases {
            llm.requiresExternalCredentials = !c.local
            let workflow = Workflow(
                name: "Segmented Cleanup", template: .cleanedText, trigger: .manual(),
                behavior: WorkflowBehavior(providerId: llm.providerName, cloudModel: "test",
                                           segmentedPostProcessingEnabled: c.enabled),
                output: WorkflowOutput(format: c.format)
            )
            let plan = try HistoryRetranscriptionEnvironment.plan(
                .init(engineID: engine.providerId, workflowID: workflow.id, appBundleIdentifier: c.app),
                manager: environment.manager, dictionary: environment.dictionary,
                workflows: [workflow], promptProcessing: environment.promptProcessing
            )
            workflow.behavior.segmentedPostProcessingEnabled = false
            let before = llm.inputs.count
            let version = try await plan.run([0.1])
            let inputs = Array(llm.inputs.dropFirst(before))
            XCTAssertEqual(version.finalText, text.uppercased())
            if c.splits {
                XCTAssertGreaterThan(inputs.count, 1)
                XCTAssertTrue(inputs.allSatisfy { $0.count < text.count })
            } else {
                XCTAssertEqual(inputs.count, 1)
                XCTAssertTrue(inputs.first?.contains(text) == true)
            }
            XCTAssertTrue(try XCTUnwrap(llm.lastSystemPrompt).contains("Protected vocabulary:"))
            XCTAssertEqual(version.workflowID, workflow.id)
        }
    }

    func testSegmentedComparisonCancellationRetainsLeaseUntilEveryRequestFinishes() async throws {
        let f = try await fixture()
        defer { TestSupport.remove(f.directory) }
        let engine = HistoryComparisonTestEngine()
        engine.resultOverride = PluginTranscriptionResult(
            text: (0..<75).map { "Sentence \($0) keeps TypeWhisper vocabulary and the original order." }.joined(separator: " ")
        )
        let llm = HistoryComparisonLLM()
        let gate = SegmentGate()
        llm.handler = { text in await gate.wait(); return text }
        let environment = try makeEnvironment(plugins: [engine, llm])
        let workflow = Workflow(
            name: "Segmented Cleanup", template: .cleanedText, trigger: .manual(),
            behavior: WorkflowBehavior(providerId: llm.providerName, cloudModel: "test",
                                       segmentedPostProcessingEnabled: true)
        )
        let service = HistoryRetranscriptionService(
            history: f.history,
            planBuilder: { request in
                try HistoryRetranscriptionEnvironment.plan(
                    request, manager: environment.manager, dictionary: environment.dictionary,
                    workflows: [workflow], promptProcessing: environment.promptProcessing
                )
            }, isBusy: { false }, loadAudio: { _ in [0.1] }
        )
        defer { service.cancel(); gate.releaseAll() }
        service.start(record: f.record, request: .init(engineID: engine.providerId, workflowID: workflow.id),
                      cloudConfirmed: true, downloadConfirmed: false)
        for _ in 0..<100 where gate.pending.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(gate.pending.count, 1)
        service.cancel()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(HistoryRetranscriptionActivity.recordID, f.record.id)
        XCTAssertEqual(service.runningRecordID, f.record.id)
        gate.releaseFirst()
        if !gate.pending.isEmpty {
            for _ in 0..<100 { await Task.yield() }
            XCTAssertEqual(HistoryRetranscriptionActivity.recordID, f.record.id)
        }
        gate.releaseAll()
        try await wait(service)
        XCTAssertNil(HistoryRetranscriptionActivity.recordID)
        XCTAssertNil(f.record.transcriptionVersionsData)
        XCTAssertNil(service.errorMessage)
    }

    func testModelChangeClearsUnsupportedLanguageAndKeepsSupportedOrAutomaticSelection() {
        let engine = HistoryComparisonLanguageEngine()
        XCTAssertEqual(HistoryRetranscriptionEnvironment.supportedLanguage("ar", modelID: "nova-3", engine: engine), "ar")
        XCTAssertNil(HistoryRetranscriptionEnvironment.supportedLanguage("ar", modelID: "nova-2", engine: engine))
        XCTAssertEqual(HistoryRetranscriptionEnvironment.supportedLanguage("en", modelID: "nova-2", engine: engine), "en")
        XCTAssertNil(HistoryRetranscriptionEnvironment.supportedLanguage(nil, modelID: "nova-2", engine: engine))
        XCTAssertNil(HistoryRetranscriptionEnvironment.supportedLanguage("en", modelID: "nova-2", engine: nil))
    }

    func testComparisonRestoresDownloadedLocalModelWithoutOfferingUndownloadedModels() async throws {
        let engine = HistoryComparisonCachedEngine()
        let environment = try makeEnvironment(plugins: [engine])
        let key = "plugin.\(HistoryComparisonCachedEngine.pluginId).loadedModel"
        let previousModel = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previousModel, forKey: key) }
        UserDefaults.standard.set("cached", forKey: key)
        XCTAssertFalse(engine.isConfigured)
        XCTAssertTrue(engine.transcriptionModels.isEmpty)
        XCTAssertTrue(environment.manager.canPrepareForTranscription(engine))
        XCTAssertEqual(HistoryRetranscriptionEnvironment.models(for: engine).map(\.id), ["cached"])

        let request = HistoryRetranscriptionService.Request(engineID: engine.providerId, modelID: "cached", language: "en")
        let plan = try HistoryRetranscriptionEnvironment.plan(
            request, manager: environment.manager, dictionary: environment.dictionary,
            workflows: [], promptProcessing: environment.promptProcessing
        )
        XCTAssertFalse(plan.requiresCloudConfirmation)
        let version = try await plan.run([0.1, -0.1])
        XCTAssertTrue(engine.isConfigured)
        XCTAssertEqual(engine.restoreCount, 1)
        XCTAssertEqual(version.modelID, "cached")
        XCTAssertEqual(version.modelName, "Cached Model")
        XCTAssertEqual(engine.selectedModelId, "cached")
        var undownloaded = request
        undownloaded.modelID = "not-downloaded"
        XCTAssertThrowsError(try HistoryRetranscriptionEnvironment.plan(
            undownloaded, manager: environment.manager, dictionary: environment.dictionary,
            workflows: [], promptProcessing: environment.promptProcessing
        ))
        XCTAssertEqual(engine.selectedModelId, "cached")
        XCTAssertEqual(engine.restoreCount, 1)
    }

    func testComparisonWorkflowReceivesProtectedTermsAndCorrectionTargets() async throws {
        let engine = HistoryComparisonTestEngine()
        let llm = HistoryComparisonLLM()
        let environment = try makeEnvironment(plugins: [engine, llm])
        environment.dictionary.addEntry(type: .term, original: "DEVONthink")
        environment.dictionary.addEntry(type: .correction, original: "type whisper", replacement: "TypeWhisper")
        let workflow = Workflow(
            name: "Cleanup", template: .cleanedText, trigger: WorkflowTrigger(kind: .manual),
            behavior: WorkflowBehavior(providerId: llm.providerName, cloudModel: "test")
        )
        let plan = try HistoryRetranscriptionEnvironment.plan(
            .init(engineID: engine.providerId, workflowID: workflow.id),
            manager: environment.manager, dictionary: environment.dictionary,
            workflows: [workflow], promptProcessing: environment.promptProcessing
        )
        // The confirmed plan freezes its vocabulary just like its workflow and provider.
        environment.dictionary.addEntry(type: .term, original: "AddedAfterConfirmation")
        let version = try await plan.run([0.1, -0.1])
        let prompt = try XCTUnwrap(llm.lastSystemPrompt)
        XCTAssertTrue(prompt.contains("Protected vocabulary:"))
        XCTAssertTrue(prompt.contains("DEVONthink"))
        XCTAssertTrue(prompt.contains("TypeWhisper"))
        XCTAssertFalse(prompt.contains("AddedAfterConfirmation"))
        XCTAssertEqual(version.workflowID, workflow.id)
        XCTAssertEqual(version.finalText, "cleaned test")
    }

    func testComparisonCorrectionsDoNotCountUsageOnSuccessOrWorkflowFailure() async throws {
        let engine = HistoryComparisonTestEngine()
        let llm = HistoryComparisonLLM()
        let environment = try makeEnvironment(plugins: [engine, llm])
        environment.dictionary.addEntry(type: .correction, original: "test", replacement: "TypeWhisper")
        let correction = try XCTUnwrap(environment.dictionary.corrections.first)
        let plan = try HistoryRetranscriptionEnvironment.plan(
            .init(engineID: engine.providerId), manager: environment.manager,
            dictionary: environment.dictionary, workflows: [], promptProcessing: environment.promptProcessing
        )
        let version = try await plan.run([0.1])
        XCTAssertEqual(version.rawText, "test")
        XCTAssertEqual(version.finalText, "TypeWhisper")
        XCTAssertEqual(correction.usageCount, 0)

        llm.error = CocoaError(.fileReadCorruptFile)
        let workflow = Workflow(
            name: "Failing Cleanup", template: .cleanedText, trigger: .manual(),
            behavior: WorkflowBehavior(providerId: llm.providerName, cloudModel: "test")
        )
        let failingPlan = try HistoryRetranscriptionEnvironment.plan(
            .init(engineID: engine.providerId, workflowID: workflow.id), manager: environment.manager,
            dictionary: environment.dictionary, workflows: [workflow], promptProcessing: environment.promptProcessing
        )
        do {
            _ = try await failingPlan.run([0.1])
            XCTFail("The workflow should fail after corrections are previewed")
        } catch {}
        XCTAssertEqual(correction.usageCount, 0)
    }

    func testAutomaticWorkflowFormatUsesSavedAppAndWebsiteContext() async throws {
        let engine = HistoryComparisonTestEngine()
        let llm = HistoryComparisonLLM()
        let environment = try makeEnvironment(plugins: [engine, llm])
        let workflow = Workflow(
            name: "Formatted Cleanup", template: .cleanedText, trigger: .manual(),
            behavior: WorkflowBehavior(providerId: llm.providerName, cloudModel: "test"),
            output: WorkflowOutput(format: "auto")
        )
        let richTextInstruction = "Return Markdown-compatible text for rich-text conversion."
        let cases: [(String?, String?, String)] = [
            ("com.apple.mail", nil, "Return the result as html."),
            ("com.apple.iWork.Pages", nil, richTextInstruction),
            ("com.google.Chrome", "https://docs.google.com/document/d/test/edit", richTextInstruction),
            ("com.google.Chrome", "https://mail.google.com/mail/u/0", "Return the result as html."),
            (nil, nil, "Return the result as plaintext.")
        ]
        for (bundleID, url, instruction) in cases {
            let plan = try HistoryRetranscriptionEnvironment.plan(
                .init(engineID: engine.providerId, workflowID: workflow.id,
                      appBundleIdentifier: bundleID, appURL: url),
                manager: environment.manager, dictionary: environment.dictionary,
                workflows: [workflow], promptProcessing: environment.promptProcessing
            )
            _ = try await plan.run([0.1])
            XCTAssertTrue(try XCTUnwrap(llm.lastSystemPrompt).contains(instruction), "Wrong format for \(bundleID ?? "unknown app") / \(url ?? "no URL")")
        }
        workflow.output.format = "markdown"
        let explicitPlan = try HistoryRetranscriptionEnvironment.plan(
            .init(engineID: engine.providerId, workflowID: workflow.id, appBundleIdentifier: "com.apple.mail"),
            manager: environment.manager, dictionary: environment.dictionary,
            workflows: [workflow], promptProcessing: environment.promptProcessing
        )
        _ = try await explicitPlan.run([0.1])
        XCTAssertTrue(try XCTUnwrap(llm.lastSystemPrompt).contains("Return the result as markdown."))
    }

    func testAppleTranslatePlanRejectsMissingOrIncompatibleServiceAndAcceptsAvailableService() throws {
        let engine = HistoryComparisonRestoreEngine()
        let environment = try makeEnvironment(plugins: [engine])
        let workflow = Workflow(
            name: "Apple Translate", template: .translation, trigger: .manual(),
            behavior: WorkflowBehavior(settings: [
                "translationProcessor": WorkflowTranslationProcessor.appleTranslate.rawValue, "targetLanguage": "de"
            ])
        )
        let request = HistoryRetranscriptionService.Request(engineID: engine.providerId, workflowID: workflow.id)
        for unavailableService: AnyObject? in [nil, NSObject()] {
            XCTAssertThrowsError(try HistoryRetranscriptionEnvironment.plan(
                request, manager: environment.manager, dictionary: environment.dictionary,
                workflows: [workflow], promptProcessing: environment.promptProcessing,
                translationService: unavailableService
            )) {
                XCTAssertEqual($0.localizedDescription, HistoryRetranscriptionError.unavailable.localizedDescription)
            }
        }
        #if canImport(Translation)
        if #available(macOS 15, *) {
            let service = TranslationService()
            let plan = try HistoryRetranscriptionEnvironment.plan(
                request, manager: environment.manager, dictionary: environment.dictionary,
                workflows: [workflow], promptProcessing: environment.promptProcessing, translationService: service
            )
            XCTAssertFalse(plan.requiresCloudConfirmation)
            workflow.behavior.settings.removeValue(forKey: "targetLanguage")
            XCTAssertThrowsError(try HistoryRetranscriptionEnvironment.plan(
                request, manager: environment.manager, dictionary: environment.dictionary,
                workflows: [workflow], promptProcessing: environment.promptProcessing, translationService: service
            ))
        }
        #endif
    }

    func testAppleTranslatePlanRejectsInvalidTargetsAndAcceptsNormalizedLanguageAliases() throws {
        #if canImport(Translation)
        guard #available(macOS 15, *) else { throw XCTSkip("Apple Translate requires macOS 15") }
        let engine = HistoryComparisonRestoreEngine()
        let environment = try makeEnvironment(plugins: [engine])
        let service = TranslationService()
        let workflow = Workflow(
            name: "Apple Translate", template: .translation, trigger: .manual(),
            behavior: WorkflowBehavior(settings: [
                "translationProcessor": WorkflowTranslationProcessor.appleTranslate.rawValue
            ])
        )
        let request = HistoryRetranscriptionService.Request(engineID: engine.providerId, workflowID: workflow.id)
        for target in ["auto", "zz", "not a language", " "] {
            workflow.behavior.settings["targetLanguage"] = target
            XCTAssertThrowsError(try HistoryRetranscriptionEnvironment.plan(
                request, manager: environment.manager, dictionary: environment.dictionary,
                workflows: [workflow], promptProcessing: environment.promptProcessing, translationService: service
            )) {
                XCTAssertEqual($0.localizedDescription, HistoryRetranscriptionError.unavailable.localizedDescription)
            }
        }
        for target in ["de", "de_DE", "German", "zh_Hant"] {
            workflow.behavior.settings["targetLanguage"] = target
            XCTAssertNoThrow(try HistoryRetranscriptionEnvironment.plan(
                request, manager: environment.manager, dictionary: environment.dictionary,
                workflows: [workflow], promptProcessing: environment.promptProcessing, translationService: service
            ))
        }
        #endif
    }

    private func makeEnvironment(plugins: [any TypeWhisperPlugin]) throws -> (
        manager: ModelManagerService, dictionary: DictionaryService, promptProcessing: PromptProcessingService
    ) {
        let directory = try TestSupport.makeTemporaryDirectory()
        let previousPluginManager = PluginManager.shared
        let suite = "HistoryComparisonEnvironment-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { @MainActor in
            PluginManager.shared = previousPluginManager
            defaults.removePersistentDomain(forName: suite)
            TestSupport.remove(directory)
        }
        let pluginManager = PluginManager(appSupportDirectory: directory)
        pluginManager.loadedPlugins = plugins.map { plugin in
            LoadedPlugin(
                manifest: PluginManifest(id: type(of: plugin).pluginId, name: type(of: plugin).pluginName,
                                         version: "1.0.0", principalClass: "TestPlugin"),
                instance: plugin, bundle: Bundle.main, sourceURL: directory, isEnabled: true
            )
        }
        PluginManager.shared = pluginManager
        let manager = ModelManagerService()
        manager.setPluginRestoreWaitConfigurationForTesting(initialAttempts: 1, busyAttempts: 1, pollInterval: .milliseconds(1))
        return (manager, DictionaryService(appSupportDirectory: directory), PromptProcessingService(userDefaults: defaults))
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
    var resultOverride: PluginTranscriptionResult?
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
        resultOverride ?? PluginTranscriptionResult(text: "test", detectedLanguage: language)
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

private final class HistoryComparisonLanguageEngine: HistoryComparisonTestEngine, @unchecked Sendable {
    @objc func supportedLanguagesForModelId(_ modelId: String) -> [String] {
        modelId == "nova-3" ? ["en", "ar"] : ["en"]
    }
}

private final class HistoryComparisonCachedEngine: HistoryComparisonTestEngine, TranscriptionModelCatalogProviding,
    PassiveModelRestoreProviding, PluginDownloadedModelManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var configured = false
    private var restores = 0
    override var selectedModelId: String? { "cached" }
    override var isConfigured: Bool { lock.withLock { configured } }
    var restoreCount: Int { lock.withLock { restores } }
    override var transcriptionModels: [PluginModelInfo] { isConfigured ? downloadedModels : [] }
    var downloadedModels: [PluginModelInfo] { [PluginModelInfo(id: "cached", displayName: "Cached Model", downloaded: true)] }
    var availableModels: [PluginModelInfo] {
        downloadedModels + [PluginModelInfo(id: "not-downloaded", displayName: "Not Downloaded", downloaded: false)]
    }
    func deleteDownloadedModel(_ modelId: String) async throws {}
    func requestPassiveModelRestore() {}
    @objc func triggerRestoreModel() {
        lock.withLock {
            configured = true
            restores += 1
        }
    }
}

private final class HistoryComparisonLLM: LLMProviderPlugin, LLMProviderSetupStatusProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.history-comparison-llm"
    static let pluginName = "History Comparison LLM"
    let providerName = "History Comparison LLM"
    var isAvailable: Bool { true }
    var requiresExternalCredentials = true
    var unavailableReason: String? { nil }
    var supportedModels: [PluginModelInfo] { [PluginModelInfo(id: "test", displayName: "Test Model")] }
    private let lock = NSLock()
    private var systemPrompt: String?
    private var receivedInputs: [String] = []
    var inputs: [String] { lock.withLock { receivedInputs } }
    var handler: (@MainActor @Sendable (String) async throws -> String)?
    var error: Error?
    var lastSystemPrompt: String? { lock.withLock { systemPrompt } }
    required init() {}
    func activate(host: HostServices) {}
    func deactivate() {}
    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        lock.withLock {
            self.systemPrompt = systemPrompt
            receivedInputs.append(userText)
        }
        if let error { throw error }
        if let handler { return try await handler(userText) }
        return "cleaned test"
    }
}
