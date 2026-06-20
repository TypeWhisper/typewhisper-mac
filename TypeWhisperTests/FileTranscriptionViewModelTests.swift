import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class FileTranscriptionViewModelTests: XCTestCase {
    func testFileTranscriptionCanStartWithPrepareableAppleSpeechCatalog() async throws {
        let previousPluginManager = PluginManager.shared
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer {
            PluginManager.shared = previousPluginManager
            TestSupport.remove(appSupportDirectory)
        }

        let plugin = FileTranscriptionAppleSpeechCatalogPlugin()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: AppleSpeechModelSelection.manifestId,
                    name: "Apple Speech",
                    version: "1.0.0",
                    principalClass: "FileTranscriptionAppleSpeechCatalogPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let defaults = try makeDefaults()
        let fileURL = makeTemporaryFile(named: "apple-speech-first-use.wav")
        let viewModel = FileTranscriptionViewModel(
            modelManager: ModelManagerService(),
            audioFileService: AudioFileService(),
            defaults: defaults
        )

        viewModel.addFiles([fileURL])
        viewModel.selectedEngine = AppleSpeechModelSelection.providerId

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertTrue(viewModel.canTranscribe)
    }

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
            audioSamplesLoader: { url, _, _ in
                XCTAssertEqual(url, fileURL)
                return [0.1, -0.1]
            },
            transcriptionRunner: { samples, languageSelection, task, engineOverrideId, cloudModelOverride, _, _, _ in
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

    func testTranscribeAllExposesLoadingProgressAndElapsedTime() async throws {
        let defaults = try makeDefaults()
        let fileURL = makeTemporaryFile(named: "long-video.mp4")
        let progressReported = AsyncGate()
        let finishLoading = AsyncGate()

        let viewModel = FileTranscriptionViewModel(
            modelManager: ModelManagerService(),
            audioFileService: AudioFileService(),
            defaults: defaults,
            audioSamplesLoader: { url, onProgress, _ in
                XCTAssertEqual(url, fileURL)
                XCTAssertTrue(onProgress(AudioFileLoadProgress(
                    fraction: 0.25,
                    currentTime: 60,
                    duration: 240
                )))
                await progressReported.open()
                let didFinishLoading = await finishLoading.wait()
                XCTAssertTrue(didFinishLoading, "Timed out waiting for loading gate")
                return [0.1, -0.1]
            },
            transcriptionRunner: { _, _, _, engineOverrideId, _, _, _, _ in
                TranscriptionResult(
                    text: "Done",
                    detectedLanguage: "en",
                    duration: 1,
                    processingTime: 0.1,
                    engineUsed: engineOverrideId ?? "default",
                    segments: []
                )
            },
            engineReadinessChecker: { _ in true }
        )

        viewModel.addFiles([fileURL])
        viewModel.selectedEngine = "whisper"

        viewModel.transcribeAll()
        let didReportProgress = await progressReported.wait()
        XCTAssertTrue(didReportProgress, "Timed out waiting for loading progress callback")

        let item = try XCTUnwrap(viewModel.files.first)
        XCTAssertEqual(item.phaseDescription, "Loading audio 25%")
        XCTAssertNotNil(viewModel.elapsedTime(for: item))

        await finishLoading.open()
        try await waitForBatchToFinish(viewModel)
    }

    func testCancelTranscriptionMarksActiveFileCancelledAndStopsBatch() async throws {
        let defaults = try makeDefaults()
        let firstURL = makeTemporaryFile(named: "large-video.mp4")
        let secondURL = makeTemporaryFile(named: "queued-video.mp4")
        let started = AsyncGate()

        let viewModel = FileTranscriptionViewModel(
            modelManager: ModelManagerService(),
            audioFileService: AudioFileService(),
            defaults: defaults,
            audioSamplesLoader: { _, _, isCancelled in
                await started.open()
                while !isCancelled() {
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw CancellationError()
            },
            transcriptionRunner: { _, _, _, engineOverrideId, _, _, _, _ in
                TranscriptionResult(
                    text: "Should not complete",
                    detectedLanguage: "en",
                    duration: 1,
                    processingTime: 0.1,
                    engineUsed: engineOverrideId ?? "default",
                    segments: []
                )
            },
            engineReadinessChecker: { _ in true }
        )

        viewModel.addFiles([firstURL, secondURL])
        viewModel.selectedEngine = "whisper"

        viewModel.transcribeAll()
        let didStart = await started.wait()
        XCTAssertTrue(didStart, "Timed out waiting for cancellation loader start")
        viewModel.cancelTranscription()
        try await waitUntil {
            viewModel.batchState == .cancelled
        }

        XCTAssertEqual(viewModel.files.first?.state, .cancelled)
        XCTAssertEqual(viewModel.files.dropFirst().first?.state, .pending)
        XCTAssertTrue(viewModel.canTranscribe)
    }

    func testRunnerProgressUpdatesActiveFileStatus() async throws {
        let defaults = try makeDefaults()
        let fileURL = makeTemporaryFile(named: "progress-video.mp4")
        let progressReported = AsyncGate()
        let finishRunner = AsyncGate()

        let viewModel = FileTranscriptionViewModel(
            modelManager: ModelManagerService(),
            audioFileService: AudioFileService(),
            defaults: defaults,
            audioSamplesLoader: { _, _, _ in [0.1, -0.1] },
            transcriptionRunner: { _, _, _, engineOverrideId, _, onProgress, _, _ in
                XCTAssertTrue(onProgress("Partial transcript"))
                await progressReported.open()
                let didFinishRunner = await finishRunner.wait()
                XCTAssertTrue(didFinishRunner, "Timed out waiting for runner gate")
                return TranscriptionResult(
                    text: "Final transcript",
                    detectedLanguage: "en",
                    duration: 1,
                    processingTime: 0.1,
                    engineUsed: engineOverrideId ?? "default",
                    segments: []
                )
            },
            engineReadinessChecker: { _ in true }
        )

        viewModel.addFiles([fileURL])
        viewModel.selectedEngine = "whisper"

        viewModel.transcribeAll()
        let didReportProgress = await progressReported.wait()
        XCTAssertTrue(didReportProgress, "Timed out waiting for transcription progress callback")

        XCTAssertEqual(viewModel.files.first?.phaseDescription, "Transcribing")
        XCTAssertEqual(viewModel.files.first?.progressText, "Partial transcript")
        await finishRunner.open()
        try await waitForBatchToFinish(viewModel)
    }

    func testRunnerSourceProgressUpdatesActiveFileStatus() async throws {
        let defaults = try makeDefaults()
        let fileURL = makeTemporaryFile(named: "source-progress-video.mp4")
        let progressReported = AsyncGate()
        let finishRunner = AsyncGate()

        let viewModel = FileTranscriptionViewModel(
            modelManager: ModelManagerService(),
            audioFileService: AudioFileService(),
            defaults: defaults,
            audioSamplesLoader: { _, _, _ in [0.1, -0.1] },
            transcriptionRunner: { _, _, _, engineOverrideId, _, _, onSourceProgress, _ in
                XCTAssertTrue(onSourceProgress(PluginTranscriptionSourceProgress(
                    processedDuration: 60,
                    totalDuration: 240,
                    previewText: "Minute one"
                )))
                await progressReported.open()
                let didFinishRunner = await finishRunner.wait()
                XCTAssertTrue(didFinishRunner, "Timed out waiting for runner gate")
                return TranscriptionResult(
                    text: "Final transcript",
                    detectedLanguage: "en",
                    duration: 240,
                    processingTime: 0.1,
                    engineUsed: engineOverrideId ?? "default",
                    segments: []
                )
            },
            engineReadinessChecker: { _ in true }
        )

        viewModel.addFiles([fileURL])
        viewModel.selectedEngine = "whisper"

        viewModel.transcribeAll()
        let didReportProgress = await progressReported.wait()
        XCTAssertTrue(didReportProgress, "Timed out waiting for source progress callback")

        let item = try XCTUnwrap(viewModel.files.first)
        XCTAssertEqual(item.phaseDescription, "Transcribing")
        XCTAssertEqual(item.progressFraction, 0.25)
        XCTAssertEqual(item.progressText, "Minute one")
        XCTAssertEqual(item.sourceProgress?.processedDuration, 60)
        XCTAssertEqual(item.sourceProgress?.totalDuration, 240)

        await finishRunner.open()
        try await waitForBatchToFinish(viewModel)
    }

    func testExportAllSubtitlesSavesTextOnlyResultAsSingleSRTCue() throws {
        let defaults = try makeDefaults()
        let fileURL = makeTemporaryFile(named: "team-meeting.wav")
        var savedContent: String?
        var savedFormat: SubtitleFormat?
        var savedSuggestedName: String?
        let viewModel = FileTranscriptionViewModel(
            modelManager: ModelManagerService(),
            audioFileService: AudioFileService(),
            defaults: defaults,
            subtitleFileSaver: { content, format, suggestedName in
                savedContent = content
                savedFormat = format
                savedSuggestedName = suggestedName
            },
            subtitleFolderPicker: {
                XCTFail("Single-file export should use the save panel path")
                return nil
            }
        )

        viewModel.addFiles([fileURL])
        viewModel.files[0].state = .done
        viewModel.files[0].result = makeTranscriptionResult(
            text: "  Full meeting transcript  ",
            duration: 12.5,
            segments: []
        )

        viewModel.exportAllSubtitles(format: .srt)

        XCTAssertEqual(savedFormat, .srt)
        XCTAssertEqual(savedSuggestedName, "team-meeting")
        XCTAssertEqual(savedContent, "1\n00:00:00,000 --> 00:00:12,500\nFull meeting transcript")
    }

    func testExportAllSubtitlesWritesMultipleTextOnlyVTTFiles() throws {
        let defaults = try makeDefaults()
        let firstURL = makeTemporaryFile(named: "first-call.wav")
        let secondURL = makeTemporaryFile(named: "second-call.wav")
        let exportFolder = makeTemporaryDirectory()
        var folderPickerCalls = 0
        let viewModel = FileTranscriptionViewModel(
            modelManager: ModelManagerService(),
            audioFileService: AudioFileService(),
            defaults: defaults,
            subtitleFileSaver: { _, _, _ in
                XCTFail("Multi-file export should use the folder export path")
            },
            subtitleFolderPicker: {
                folderPickerCalls += 1
                return exportFolder
            }
        )

        viewModel.addFiles([firstURL, secondURL])
        viewModel.files[0].state = .done
        viewModel.files[0].result = makeTranscriptionResult(
            text: "First transcript",
            duration: 1,
            segments: []
        )
        viewModel.files[1].state = .done
        viewModel.files[1].result = makeTranscriptionResult(
            text: "Second transcript",
            duration: 2.25,
            segments: []
        )

        viewModel.exportAllSubtitles(format: .vtt)

        XCTAssertEqual(folderPickerCalls, 1)
        let firstContent = try String(contentsOf: exportFolder.appendingPathComponent("first-call.vtt"))
        let secondContent = try String(contentsOf: exportFolder.appendingPathComponent("second-call.vtt"))
        XCTAssertEqual(firstContent, "WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.000\nFirst transcript\n")
        XCTAssertEqual(secondContent, "WEBVTT\n\n1\n00:00:00.000 --> 00:00:02.250\nSecond transcript\n")
    }

    func testExportSubtitlesPreservesTimestampedSegments() throws {
        let defaults = try makeDefaults()
        let fileURL = makeTemporaryFile(named: "captioned.wav")
        var savedContent: String?
        let viewModel = FileTranscriptionViewModel(
            modelManager: ModelManagerService(),
            audioFileService: AudioFileService(),
            defaults: defaults,
            subtitleFileSaver: { content, _, _ in
                savedContent = content
            }
        )

        viewModel.addFiles([fileURL])
        viewModel.files[0].state = .done
        viewModel.files[0].result = makeTranscriptionResult(
            text: "Fallback text should not be used",
            duration: 60,
            segments: [
                TranscriptionSegment(text: "First segment", start: 0.25, end: 1.5),
                TranscriptionSegment(text: "Second segment", start: 1.5, end: 2.75)
            ]
        )
        let item = try XCTUnwrap(viewModel.files.first)

        viewModel.exportSubtitles(for: item, format: .vtt)

        XCTAssertEqual(
            savedContent,
            "WEBVTT\n\n1\n00:00:00.250 --> 00:00:01.500\nFirst segment\n\n2\n00:00:01.500 --> 00:00:02.750\nSecond segment\n"
        )
    }

    func testTextOnlySubtitleExportUsesOneSecondCueForInvalidDuration() {
        let content = SubtitleExporter.exportContent(
            for: makeTranscriptionResult(text: "No duration transcript", duration: .nan),
            format: .srt
        )

        XCTAssertEqual(content, "1\n00:00:00,000 --> 00:00:01,000\nNo duration transcript")
    }

    func testStableProgressPreviewIgnoresDisjointReplacementText() {
        let current = "Basically, Deepgram, Whisper, Speechmatics, and Assembly."
        let candidate = "use Whisper through OpenAI APIs. They are a Mac file size"

        XCTAssertEqual(
            FileTranscriptionViewModel.stableProgressPreviewText(
                current: current,
                candidate: candidate
            ),
            current
        )
    }

    func testStableProgressPreviewAcceptsLongerContinuation() {
        let current = "Basically, Deepgram, Whisper"
        let candidate = "Basically, Deepgram, Whisper, Speechmatics, and Assembly."

        XCTAssertEqual(
            FileTranscriptionViewModel.stableProgressPreviewText(
                current: current,
                candidate: candidate
            ),
            candidate
        )
    }

    func testCancellationDuringAudioLoadingIsNotReportedAsError() async throws {
        let defaults = try makeDefaults()
        let fileURL = makeTemporaryFile(named: "cancel-loading.mp4")

        let viewModel = FileTranscriptionViewModel(
            modelManager: ModelManagerService(),
            audioFileService: AudioFileService(),
            defaults: defaults,
            audioSamplesLoader: { _, onProgress, isCancelled in
                while !isCancelled() {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertFalse(onProgress(AudioFileLoadProgress(
                    fraction: 0.5,
                    currentTime: 30,
                    duration: 60
                )))
                throw CancellationError()
            },
            transcriptionRunner: { _, _, _, engineOverrideId, _, _, _, _ in
                TranscriptionResult(
                    text: "Should not complete",
                    detectedLanguage: "en",
                    duration: 1,
                    processingTime: 0.1,
                    engineUsed: engineOverrideId ?? "default",
                    segments: []
                )
            },
            engineReadinessChecker: { _ in true }
        )

        viewModel.addFiles([fileURL])
        viewModel.selectedEngine = "whisper"

        viewModel.transcribeAll()
        try await waitUntil {
            viewModel.files.first?.state == .loading
        }
        viewModel.cancelTranscription()
        try await waitUntil {
            viewModel.batchState == .cancelled
        }

        XCTAssertEqual(viewModel.files.first?.state, .cancelled)
        XCTAssertNil(viewModel.files.first?.errorMessage)
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

    private func makeTranscriptionResult(
        text: String,
        duration: TimeInterval,
        segments: [TranscriptionSegment] = []
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            detectedLanguage: "en",
            duration: duration,
            processingTime: 0.1,
            engineUsed: "test",
            segments: segments
        )
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

    private func waitUntil(
        timeoutAttempts: Int = 100,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<timeoutAttempts {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition was not met")
    }
}

private actor AsyncGate {
    private var isOpen = false

    func open() {
        isOpen = true
    }

    func wait(timeoutAttempts: Int = 300) async -> Bool {
        for _ in 0..<timeoutAttempts {
            if isOpen { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isOpen
    }
}

private final class FileTranscriptionAppleSpeechCatalogPlugin: NSObject, TranscriptionModelCatalogProviding, @unchecked Sendable {
    static let pluginId = AppleSpeechModelSelection.manifestId
    static let pluginName = "Apple Speech"

    var providerId: String { AppleSpeechModelSelection.providerId }
    var providerDisplayName: String { "Apple Speech" }
    var isConfigured: Bool { false }
    var transcriptionModels: [PluginModelInfo] { [] }
    var availableModels: [PluginModelInfo] {
        [PluginModelInfo(id: "speechanalyzer-en_US", displayName: "English")]
    }
    var selectedModelId: String? { nil }
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { false }
    var supportedLanguages: [String] { ["en"] }

    func activate(host: HostServices) {}
    func deactivate() {}
    func selectModel(_ modelId: String) {}

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        throw PluginTranscriptionError.notConfigured
    }
}
