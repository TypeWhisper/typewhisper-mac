import Foundation
import XCTest
@testable import TypeWhisper

@MainActor
final class FileTranscriptionViewModelTests: XCTestCase {
    func testTranscribeAllUsesFileTranscriptionEngineAndModelOverrides() async throws {
        let defaults = try makeDefaults()
        let fileURL = makeTemporaryFile(named: "last-dictation-recovery.wav")
        var capturedLanguageSelection: LanguageSelection?
        var capturedTask: TranscriptionTask?
        var capturedEngineOverrideId: String?
        var capturedModelOverrideId: String?

        let viewModel = FileTranscriptionViewModel(
            modelManager: ModelManagerService(),
            audioFileService: AudioFileService(),
            defaults: defaults,
            audioSamplesLoader: { url in
                XCTAssertEqual(url, fileURL)
                return [0.1, -0.1]
            },
            transcriptionRunner: { samples, languageSelection, task, engineOverrideId, cloudModelOverride in
                XCTAssertEqual(samples, [0.1, -0.1])
                capturedLanguageSelection = languageSelection
                capturedTask = task
                capturedEngineOverrideId = engineOverrideId
                capturedModelOverrideId = cloudModelOverride
                return TranscriptionResult(
                    text: "Recovered text",
                    detectedLanguage: "de",
                    duration: 1,
                    processingTime: 0.1,
                    engineUsed: engineOverrideId ?? "default",
                    segments: []
                )
            },
            engineReadinessChecker: { engineId in
                engineId == "parakeet"
            }
        )

        viewModel.addFiles([fileURL])
        viewModel.selectedEngine = "parakeet"
        viewModel.selectedModel = "parakeet-large"
        viewModel.languageSelection = .hints(["de", "en"])
        viewModel.selectedTask = .translate

        viewModel.transcribeAll()
        try await waitForBatchToFinish(viewModel)

        XCTAssertEqual(capturedLanguageSelection, .hints(["de", "en"]))
        XCTAssertEqual(capturedTask, .translate)
        XCTAssertEqual(capturedEngineOverrideId, "parakeet")
        XCTAssertEqual(capturedModelOverrideId, "parakeet-large")
        XCTAssertEqual(viewModel.files.first?.state, .done)
        XCTAssertEqual(viewModel.files.first?.result?.text, "Recovered text")
    }

    func testRecoveryTranscribeUsesRecoveryEngineAndModelOverrides() async throws {
        let defaults = try makeDefaults()
        let directory = makeTemporaryDirectory()
        let historyService = HistoryService(appSupportDirectory: makeTemporaryDirectory())
        let store = DictationRecoveryAudioStore(directory: directory)
        store.startNewRecording()
        store.append([0.1])
        let olderRecoveryURL = try XCTUnwrap(store.preserveActiveRecording())
        store.startNewRecording()
        store.append([0.2, -0.2])
        let selectedRecoveryURL = try XCTUnwrap(store.preserveActiveRecording())
        let audioRecordingService = AudioRecordingService(recoveryAudioStore: store)
        var capturedLanguageSelection: LanguageSelection?
        var capturedTask: TranscriptionTask?
        var capturedEngineOverrideId: String?
        var capturedModelOverrideId: String?

        let viewModel = DictationRecoveryViewModel(
            audioRecordingService: audioRecordingService,
            modelManager: ModelManagerService(),
            historyService: historyService,
            audioFileService: AudioFileService(),
            defaults: defaults,
            audioSamplesLoader: { url in
                XCTAssertEqual(url, selectedRecoveryURL)
                return [0.2, -0.2]
            },
            transcriptionRunner: { samples, languageSelection, task, engineOverrideId, cloudModelOverride in
                XCTAssertEqual(samples, [0.2, -0.2])
                capturedLanguageSelection = languageSelection
                capturedTask = task
                capturedEngineOverrideId = engineOverrideId
                capturedModelOverrideId = cloudModelOverride
                return TranscriptionResult(
                    text: "Recovered dictation",
                    detectedLanguage: "de",
                    duration: 2,
                    processingTime: 0.2,
                    engineUsed: engineOverrideId ?? "default",
                    segments: []
                )
            },
            engineReadinessChecker: { engineId in
                engineId == "parakeet"
            }
        )

        viewModel.selectedEngine = "parakeet"
        viewModel.selectedModel = "parakeet-large"
        viewModel.languageSelection = .hints(["de", "en"])
        viewModel.selectedTask = .translate
        viewModel.selectedRecoveryID = selectedRecoveryURL.path

        XCTAssertEqual(Set(viewModel.recoveries.map(\.url)), Set([olderRecoveryURL, selectedRecoveryURL]))
        viewModel.transcribe()
        try await waitForRecoveryToSave(viewModel, historyService: historyService)

        XCTAssertEqual(capturedLanguageSelection, .hints(["de", "en"]))
        XCTAssertEqual(capturedTask, .translate)
        XCTAssertEqual(capturedEngineOverrideId, "parakeet")
        XCTAssertEqual(capturedModelOverrideId, "parakeet-large")
        let historyRecord = try XCTUnwrap(historyService.records.first)
        XCTAssertEqual(historyRecord.rawText, "Recovered dictation")
        XCTAssertEqual(historyRecord.finalText, "Recovered dictation")
        XCTAssertEqual(historyRecord.language, "de")
        XCTAssertEqual(historyRecord.engineUsed, "parakeet")
        XCTAssertNotNil(historyService.audioFileURL(for: historyRecord))
        XCTAssertEqual(viewModel.recoveries.map(\.url), [olderRecoveryURL])
        XCTAssertEqual(audioRecordingService.latestRecoveryRecordingURL, olderRecoveryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selectedRecoveryURL.path))
    }

    func testRecoveryDiscardDeletesOnlySelectedRecoveryFile() throws {
        let defaults = try makeDefaults()
        let directory = makeTemporaryDirectory()
        let historyService = HistoryService(appSupportDirectory: makeTemporaryDirectory())
        let store = DictationRecoveryAudioStore(directory: directory)
        store.startNewRecording()
        store.append([0.1])
        let olderRecoveryURL = try XCTUnwrap(store.preserveActiveRecording())
        store.startNewRecording()
        store.append([0.2])
        let newerRecoveryURL = try XCTUnwrap(store.preserveActiveRecording())
        let audioRecordingService = AudioRecordingService(recoveryAudioStore: store)
        let viewModel = DictationRecoveryViewModel(
            audioRecordingService: audioRecordingService,
            modelManager: ModelManagerService(),
            historyService: historyService,
            audioFileService: AudioFileService(),
            defaults: defaults
        )

        viewModel.selectedRecoveryID = olderRecoveryURL.path
        viewModel.discardSelectedRecovery()

        XCTAssertEqual(viewModel.recoveries.map(\.url), [newerRecoveryURL])
        XCTAssertEqual(viewModel.recoveryURL, newerRecoveryURL)
        XCTAssertEqual(audioRecordingService.recoveryRecordingURLs, [newerRecoveryURL])
        XCTAssertEqual(audioRecordingService.latestRecoveryRecordingURL, newerRecoveryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: olderRecoveryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newerRecoveryURL.path))
    }

    func testRecoverySettingsTabFallsBackWhenRecoveryIsUnavailable() {
        XCTAssertEqual(SettingsView.availableTab(.dictationRecovery, hasRecoveryContent: false), .recording)
        XCTAssertEqual(SettingsView.availableTab(.dictationRecovery, hasRecoveryContent: true), .dictationRecovery)
        XCTAssertEqual(SettingsView.availableTab(.fileTranscription, hasRecoveryContent: false), .fileTranscription)
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "FileTranscriptionViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    private func makeTemporaryFile(named name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTranscriptionViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return url
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTranscriptionViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func waitForBatchToFinish(_ viewModel: FileTranscriptionViewModel) async throws {
        for _ in 0..<50 {
            if viewModel.batchState == .done {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("File transcription batch did not finish")
    }

    private func waitForRecoveryToSave(
        _ viewModel: DictationRecoveryViewModel,
        historyService: HistoryService
    ) async throws {
        for _ in 0..<50 {
            if viewModel.lastSavedHistoryRecordID != nil, !historyService.records.isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Recovery transcription was not saved to history")
    }
}
