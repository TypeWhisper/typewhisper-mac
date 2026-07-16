import AudioToolbox
import AVFoundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

private actor RecorderStopFinalizationGate {
    private var continuation: CheckedContinuation<URL?, any Error>?
    private var started = false
    private var outputURL: URL?

    func wait(outputURL: URL) async throws -> URL? {
        started = true
        self.outputURL = outputURL
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func resume() {
        continuation?.resume(returning: outputURL)
        continuation = nil
    }
}

@MainActor
final class AudioRecorderViewModelTests: XCTestCase {
    func testRecorderSelectionPersistsSeparatelyFromGlobalDefault() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)

        viewModel.selectedEngine = "assemblyai"
        viewModel.selectedModel = "universal-3-pro"

        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine), "assemblyai")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel), "universal-3-pro")
        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine), "groq")
        XCTAssertEqual(viewModel.effectiveProviderId, "assemblyai")
        XCTAssertEqual(viewModel.effectiveModelId, "universal-3-pro")
    }

    func testRecorderSelectionFallsBackToGlobalDefaultWhenUnset() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertNil(viewModel.selectedModel)
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
        XCTAssertEqual(viewModel.effectiveModelId, "whisper-large-v3")
        XCTAssertEqual(viewModel.resolvedEngine?.providerId, "groq")
    }

    func testRecorderSelectionUsesModelOverrideWithDefaultEngine() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)
        viewModel.selectedModel = "whisper-small"

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
        XCTAssertEqual(viewModel.effectiveModelId, "whisper-small")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel), "whisper-small")
        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine), "groq")
    }

    func testDefaultEngineModelOverrideClearsWhenGlobalProviderChanges() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")

        let viewModel = makeViewModel(defaults: defaults, modelManager: modelManager)
        viewModel.selectedModel = "whisper-small"
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
        XCTAssertEqual(viewModel.effectiveModelId, "whisper-small")

        modelManager.selectProvider("assemblyai")
        viewModel.reconcileSelectionWithAvailablePlugins()

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertNil(viewModel.selectedModel)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel))
        XCTAssertEqual(viewModel.effectiveProviderId, "assemblyai")
        XCTAssertEqual(viewModel.effectiveModelId, "universal-2")
    }

    func testRecorderSelectionClearsMissingSavedEngineAndModel() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        defaults.set("missing-engine", forKey: UserDefaultsKeys.recorderTranscriptionEngine)
        defaults.set("old-model", forKey: UserDefaultsKeys.recorderTranscriptionModel)
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)
        viewModel.reconcileSelectionWithAvailablePlugins()

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertNil(viewModel.selectedModel)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine))
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel))
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
    }

    func testRecorderLivePreviewDefaultsOffAndPersistsSeparately() throws {
        let defaults = try makeDefaults()

        let viewModel = makeViewModel(defaults: defaults)

        XCTAssertFalse(viewModel.livePreviewEnabled)
        XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.recorderLivePreviewEnabled))

        viewModel.livePreviewEnabled = true

        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.recorderLivePreviewEnabled))
    }

    func testLivePreviewStartsOnlyWhenTranscriptAndPreviewAreEnabled() async throws {
        try preserveStandardDefaults()
        setupPluginManager()

        let disabledCount = try await livePreviewStartCount(
            transcriptionEnabled: false,
            livePreviewEnabled: true
        )
        let transcriptOnlyCount = try await livePreviewStartCount(
            transcriptionEnabled: true,
            livePreviewEnabled: false
        )
        let splitEnabledCount = try await livePreviewStartCount(
            transcriptionEnabled: true,
            livePreviewEnabled: true
        )

        XCTAssertEqual(disabledCount, 0)
        XCTAssertEqual(transcriptOnlyCount, 0)
        XCTAssertEqual(splitEnabledCount, 1)
    }

    func testRecorderStartPassesResolvedMicrophonePrioritySelection() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let recordingsDirectory = makeTemporaryDirectory()
        let usbDeviceID = AudioDeviceID(620)
        let usbDevice = AudioInputDevice(deviceID: usbDeviceID, name: "USB Mic", uid: "usb-input")
        let audioDeviceService = AudioDeviceService(
            initialInputDevices: [usbDevice],
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )
        audioDeviceService.audioDeviceIDResolverOverride = { uid in
            uid == "usb-input" ? usbDeviceID : nil
        }
        audioDeviceService.addInputDeviceToPriorityList(usbDevice)

        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = recordingsDirectory
        var capturedSelection: ResolvedRecordingInputSelection?
        recorderService.startRecordingOverride = { _, _, _, outputURL, microphoneSelection in
            capturedSelection = microphoneSelection
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }

        let viewModel = makeViewModel(
            defaults: defaults,
            recorderService: recorderService,
            audioDeviceService: audioDeviceService
        )

        _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)

        XCTAssertEqual(capturedSelection?.deviceUID, "usb-input")
        XCTAssertEqual(capturedSelection?.deviceID, usbDeviceID)
        XCTAssertTrue(capturedSelection?.hasExplicitDeviceSelection == true)
    }

    func testRecorderStartIgnoresMicrophonePriorityWhenMicDisabled() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let recordingsDirectory = makeTemporaryDirectory()
        let usbDeviceID = AudioDeviceID(621)
        let usbDevice = AudioInputDevice(deviceID: usbDeviceID, name: "USB Mic", uid: "usb-input")
        let audioDeviceService = AudioDeviceService(
            initialInputDevices: [usbDevice],
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )
        audioDeviceService.addInputDeviceToPriorityList(usbDevice)

        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = recordingsDirectory
        var capturedSelection: ResolvedRecordingInputSelection?
        recorderService.startRecordingOverride = { _, _, _, outputURL, microphoneSelection in
            capturedSelection = microphoneSelection
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }

        let viewModel = makeViewModel(
            defaults: defaults,
            recorderService: recorderService,
            audioDeviceService: audioDeviceService
        )

        _ = try await viewModel.apiStartRecording(micEnabled: false, systemAudioEnabled: true)

        XCTAssertNil(capturedSelection?.deviceUID)
        XCTAssertNil(capturedSelection?.deviceID)
        XCTAssertFalse(capturedSelection?.hasExplicitDeviceSelection == true)
    }

    func testFinalTranscriptionFailurePersistsRecorderFailureAndFailsAPISession() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .failure("HTTP 413: payload too large"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeFinalTranscriptionViewModel(defaults: defaults, modelManager: modelManager)

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        XCTAssertEqual(try viewModel.apiStopRecording(), sessionID)

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .failed)
        let outputFile = try XCTUnwrap(session.outputFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile))
        XCTAssertNil(session.text)
        XCTAssertTrue(session.error?.contains("HTTP 413") == true)

        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertEqual(
            recording.url.resolvingSymlinksInPath().path,
            URL(fileURLWithPath: outputFile).resolvingSymlinksInPath().path
        )
        XCTAssertNil(recording.transcript)
        let failure = try XCTUnwrap(recording.transcriptionFailure)
        XCTAssertEqual(failure.phase, .finalTranscription)
        XCTAssertEqual(failure.engineName, "Groq")
        XCTAssertEqual(failure.modelName, "Whisper Large V3")
        XCTAssertTrue(failure.providerError.contains("HTTP 413"))
        XCTAssertTrue(session.error?.contains(failure.phase.displayName) == true)

        let summary = try XCTUnwrap(viewModel.transcriptionFailureSummary(for: recording))
        XCTAssertTrue(summary.contains(viewModel.formattedDuration(recording.duration)))
        XCTAssertTrue(summary.contains(viewModel.formattedFileSize(recording.fileSize)))
        XCTAssertTrue(summary.contains(failure.phase.displayName))
        XCTAssertTrue(summary.contains("HTTP 413"))
    }

    func testEmptyFinalTranscriptionPersistsRecorderFailure() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .empty)
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeFinalTranscriptionViewModel(defaults: defaults, modelManager: modelManager)

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .failed)
        XCTAssertNotNil(session.outputFile)
        XCTAssertNil(session.text)

        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertNil(recording.transcript)
        let failure = try XCTUnwrap(recording.transcriptionFailure)
        XCTAssertEqual(failure.phase, .emptyResult)
        XCTAssertFalse(failure.providerError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(session.error?.contains(failure.phase.displayName) == true)
        XCTAssertTrue(session.error?.contains(failure.providerError) == true)
    }

    func testSuccessfulTranscriptSaveClearsPriorRecorderFailure() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("fresh transcript"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let outputURL = recordingsDirectory.appendingPathComponent("Recording success.wav")
        let failureURL = failureSidecarURL(for: outputURL)
        let oldFailure = AudioRecorderViewModel.RecordingTranscriptionFailure(
            phase: .finalTranscription,
            providerError: "old error",
            engineName: "Groq",
            modelName: "Whisper Large V3",
            failedAt: Date.distantPast
        )
        try JSONEncoder().encode(oldFailure).write(to: failureURL, options: .atomic)

        let recorderService = makeRecorderService(
            recordingsDirectory: recordingsDirectory,
            outputURL: outputURL
        )
        let viewModel = makeViewModel(defaults: defaults, modelManager: modelManager, recorderService: recorderService)
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        XCTAssertEqual(session.text, "fresh transcript")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failureURL.path))

        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertEqual(recording.transcript, "fresh transcript")
        XCTAssertNil(recording.transcriptionFailure)
    }

    func testFinalTranscriptionDoesNotForceGlobalDefaultModelAsRecorderOverride() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let appSupportDirectory = makeTemporaryDirectory()
        let previousPluginManager = PluginManager.shared
        addTeardownBlock {
            PluginManager.shared = previousPluginManager
        }

        let plugin = RecorderOverrideMarkerTranscriptionPlugin()
        let pluginManager = PluginManager(appSupportDirectory: appSupportDirectory)
        pluginManager.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: RecorderOverrideMarkerTranscriptionPlugin.pluginId,
                    name: RecorderOverrideMarkerTranscriptionPlugin.pluginName,
                    version: "1.0.0",
                    principalClass: "RecorderOverrideMarkerTranscriptionPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]
        PluginManager.shared = pluginManager

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)
        let viewModel = makeFinalTranscriptionViewModel(defaults: defaults, modelManager: modelManager)

        XCTAssertNil(viewModel.selectedModel)

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        XCTAssertEqual(session.text, "unforced whisper-large-v3")
        XCTAssertEqual(plugin.selectedModelOverrides, [])
    }

    func testFailureSidecarWriteErrorStillShowsRecorderFailure() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .failure("HTTP 500: provider unavailable"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let outputURL = recordingsDirectory.appendingPathComponent("Recording write-error.wav")
        let failureURL = failureSidecarURL(for: outputURL)
        try FileManager.default.createDirectory(at: failureURL, withIntermediateDirectories: true)

        let recorderService = makeRecorderService(
            recordingsDirectory: recordingsDirectory,
            outputURL: outputURL
        )
        let viewModel = makeViewModel(defaults: defaults, modelManager: modelManager, recorderService: recorderService)
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .failed)
        XCTAssertTrue(session.error?.contains("HTTP 500") == true)

        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertNil(recording.transcript)
        let failure = try XCTUnwrap(recording.transcriptionFailure)
        XCTAssertEqual(failure.phase, .finalTranscription)
        XCTAssertTrue(failure.providerError.contains("HTTP 500"))
        XCTAssertGreaterThan(failure.providerError.count, "API error: HTTP 500: provider unavailable".count)
        let sidecarValues = try failureURL.resourceValues(forKeys: [.isDirectoryKey])
        XCTAssertEqual(sidecarValues.isDirectory, true)
    }

    func testRetranscriptionUsesRecorderOverridesAndReplacesTranscriptAfterSuccess() async throws {
        try preserveStandardDefaults()
        setupPluginManager(
            groqBehavior: .success("wrong engine"),
            assemblyAIBehavior: .success("fresh retranscription")
        )
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.m4a")
        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        let failureURL = failureSidecarURL(for: audioURL)
        try Data("audio".utf8).write(to: audioURL)
        try "old transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let oldFailure = AudioRecorderViewModel.RecordingTranscriptionFailure(
            phase: .finalTranscription,
            providerError: "old failure",
            engineName: "Groq",
            modelName: "Whisper Large V3",
            failedAt: .distantPast
        )
        try JSONEncoder().encode(oldFailure).write(to: failureURL, options: .atomic)

        let dictionaryService = DictionaryService(appSupportDirectory: makeTemporaryDirectory())
        dictionaryService.addEntry(type: .term, original: "TypeWhisper")
        var loadedURL: URL?
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            dictionaryService: dictionaryService,
            audioSamplesLoader: { url in
                loadedURL = url
                return [0.25, -0.25]
            }
        )
        viewModel.selectedEngine = "assemblyai"
        viewModel.selectedModel = "universal-3-pro"
        viewModel.languageSelection = .exact("de")
        viewModel.selectedTask = .translate
        viewModel.loadRecordings()

        let recording = try XCTUnwrap(viewModel.recordings.first)
        viewModel.transcribeRecording(recording)
        XCTAssertFalse(viewModel.canToggleRecording)
        try await waitForRetranscriptionToFinish(viewModel)

        XCTAssertEqual(loadedURL?.standardizedFileURL, audioURL.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "fresh retranscription")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failureURL.path))
        XCTAssertEqual(viewModel.recordings.first?.transcript, "fresh retranscription")
        XCTAssertNil(viewModel.recordings.first?.transcriptionFailure)
        XCTAssertTrue(viewModel.canToggleRecording)

        let plugin = try XCTUnwrap(
            PluginManager.shared.transcriptionEngine(for: "assemblyai") as? AudioRecorderMockTranscriptionPlugin
        )
        let request = try XCTUnwrap(plugin.lastRequest)
        XCTAssertEqual(request.language, "de")
        XCTAssertTrue(request.translate)
        XCTAssertTrue(request.prompt?.contains("TypeWhisper") == true)
        XCTAssertTrue(plugin.selectedModelOverrides.contains("universal-3-pro"))
    }

    func testRetranscriptionAudioLoadFailurePreservesExistingTranscript() async throws {
        try preserveStandardDefaults()
        setupPluginManager()
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.wav")
        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        try Data("audio".utf8).write(to: audioURL)
        try "keep me".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in throw AudioFileService.AudioFileError.unsupportedFormat }
        )
        viewModel.loadRecordings()

        viewModel.transcribeRecording(try XCTUnwrap(viewModel.recordings.first))
        try await waitForRetranscriptionToFinish(viewModel)

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "keep me")
        XCTAssertEqual(viewModel.recordings.first?.transcriptionFailure?.phase, .preparingFinalAudio)
        XCTAssertNil(viewModel.retranscribingRecordingURL)
    }

    func testRetranscriptionEngineFailurePreservesExistingTranscript() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .failure("provider unavailable"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.wav")
        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        try Data("audio".utf8).write(to: audioURL)
        try "keep me".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in [0.25, -0.25] }
        )
        viewModel.loadRecordings()

        viewModel.transcribeRecording(try XCTUnwrap(viewModel.recordings.first))
        try await waitForRetranscriptionToFinish(viewModel)

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "keep me")
        XCTAssertEqual(viewModel.recordings.first?.transcriptionFailure?.phase, .finalTranscription)
        XCTAssertTrue(viewModel.recordings.first?.transcriptionFailure?.providerError.contains("provider unavailable") == true)
    }

    func testEmptyRetranscriptionPersistsFailureWithoutTranscript() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .empty)
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.wav")
        try Data("audio".utf8).write(to: audioURL)
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in [0.25, -0.25] }
        )
        viewModel.loadRecordings()

        viewModel.transcribeRecording(try XCTUnwrap(viewModel.recordings.first))
        try await waitForRetranscriptionToFinish(viewModel)

        XCTAssertNil(viewModel.recordings.first?.transcript)
        XCTAssertEqual(viewModel.recordings.first?.transcriptionFailure?.phase, .emptyResult)
    }

    func testRetranscriptionSaveFailurePreservesExistingTranscriptAndRecordsFailure() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("replacement"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.wav")
        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        let failureURL = failureSidecarURL(for: audioURL)
        try Data("audio".utf8).write(to: audioURL)
        try "keep me".write(to: transcriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: transcriptURL.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: transcriptURL.path)
        }
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in [0.25, -0.25] }
        )
        viewModel.loadRecordings()

        viewModel.transcribeRecording(try XCTUnwrap(viewModel.recordings.first))
        try await waitForRetranscriptionToFinish(viewModel)

        XCTAssertEqual(viewModel.recordings.first?.transcriptionFailure?.phase, .savingTranscript)
        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "keep me")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failureURL.path))
    }

    func testRetranscriptionRejectsConcurrentRetryAndRecordingStart() async throws {
        try preserveStandardDefaults()
        setupPluginManager()
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let firstURL = recordingsDirectory.appendingPathComponent("First.wav")
        let secondURL = recordingsDirectory.appendingPathComponent("Second.wav")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        var continuation: CheckedContinuation<[Float], Never>?
        var loadCount = 0
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in
                loadCount += 1
                return await withCheckedContinuation { continuation = $0 }
            }
        )
        viewModel.loadRecordings()
        XCTAssertEqual(viewModel.recordings.count, 2)
        let first = try XCTUnwrap(viewModel.recordings.first)
        let second = try XCTUnwrap(viewModel.recordings.dropFirst().first)

        viewModel.transcribeRecording(first)
        for _ in 0..<20 where continuation == nil {
            await Task.yield()
        }
        XCTAssertNotNil(continuation)
        XCTAssertFalse(viewModel.canToggleRecording)
        XCTAssertFalse(viewModel.canTranscribeRecording(second))

        viewModel.transcribeRecording(second)
        XCTAssertEqual(loadCount, 1)

        viewModel.deleteRecording(first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(viewModel.recordings.count, 2)

        do {
            _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
            XCTFail("Expected recording start to be rejected while retranscribing")
        } catch let error as AudioRecorderViewModel.RecorderAPIError {
            guard case .retranscribing = error else {
                return XCTFail("Expected retranscribing error, got \(error)")
            }
        }

        continuation?.resume(returning: [0.25, -0.25])
        try await waitForRetranscriptionToFinish(viewModel)
        XCTAssertTrue(viewModel.canToggleRecording)
    }

    func testRecorderRetranscriptionCopyIsLocalized() throws {
        for key in [
            "recorder.retranscribe",
            "recorder.retranscribing",
            "recorder.retranscribeConfirmation.title",
            "recorder.retranscribeConfirmation.message"
        ] {
            for language in ["de", "en", "ja"] {
                XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: language).isEmpty)
            }
        }
    }

    func testRecorderStopEntersFinalizingBeforeAudioFinalizationCompletes() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let recordingsDirectory = makeTemporaryDirectory()
        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = recordingsDirectory
        recorderService.startRecordingOverride = { _, _, _, outputURL, _ in
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }
        let gate = RecorderStopFinalizationGate()
        recorderService.stopRecordingOverride = { outputURL in
            try await gate.wait(outputURL: outputURL)
        }

        let viewModel = makeViewModel(defaults: defaults, recorderService: recorderService)
        viewModel.transcriptionEnabled = false
        _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)

        viewModel.stopRecording()

        XCTAssertEqual(viewModel.state, .finalizing)
        XCTAssertFalse(viewModel.canToggleRecording)
        for _ in 0..<100 where !(await gate.hasStarted()) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finalizationStarted = await gate.hasStarted()
        XCTAssertTrue(finalizationStarted)

        await gate.resume()
        for _ in 0..<100 where viewModel.state != .idle {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testRecorderFinalizationStreamsMixedAudioAcrossChunkBoundaries() async throws {
        let directory = makeTemporaryDirectory()
        let micURL = directory.appendingPathComponent("mic.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        let outputURL = directory.appendingPathComponent("mixed.wav")
        let outputFrameCount = Int(AudioRecorderService.finalizationChunkFrameCount) * 3 + 137
        let micFrameCount = Int(
            (Double(outputFrameCount) * 44_100 / 48_000).rounded(.up)
        )

        try writePCMFile(
            at: micURL,
            frameCount: micFrameCount,
            sampleRate: 44_100,
            channelCount: 1,
            sample: 0.1
        )
        try writePCMFile(
            at: systemURL,
            frameCount: outputFrameCount,
            sampleRate: 48_000,
            channelCount: 2,
            sample: 0.2
        )

        let recorderService = AudioRecorderService()
        let resultURL = await recorderService.finalizeRecording(.init(
            finalOutputURL: outputURL,
            micTempURL: micURL,
            systemTempURL: systemURL,
            outputFormat: .wav,
            trackMode: .mixed,
            micDuckingMode: .aggressive,
            transcriptionSamples: [],
            usesFinalizationOverride: false
        ))

        XCTAssertEqual(resultURL, outputURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))

        let outputFile = try AVAudioFile(forReading: outputURL)
        XCTAssertLessThanOrEqual(abs(Int(outputFile.length) - outputFrameCount), 1)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFile.processingFormat,
            frameCapacity: AVAudioFrameCount(outputFile.length)
        ) else {
            return XCTFail("Could not allocate mixed-audio verification buffer")
        }
        try outputFile.read(into: outputBuffer)
        let leftChannel = try XCTUnwrap(outputBuffer.floatChannelData?[0])
        let rightChannel = try XCTUnwrap(outputBuffer.floatChannelData?[1])
        XCTAssertEqual(leftChannel[0], 0.3, accuracy: 0.01)
        XCTAssertEqual(rightChannel[0], 0.3, accuracy: 0.01)
        let chunkSize = Int(AudioRecorderService.finalizationChunkFrameCount)
        for boundary in [chunkSize, chunkSize * 2] {
            XCTAssertEqual(leftChannel[boundary - 1], leftChannel[boundary], accuracy: 0.002)
            XCTAssertEqual(rightChannel[boundary - 1], rightChannel[boundary], accuracy: 0.002)
            XCTAssertLessThan(leftChannel[boundary], 0.23)
            XCTAssertLessThan(rightChannel[boundary], 0.23)
        }
        XCTAssertEqual(leftChannel[outputFrameCount - 1], 0.218, accuracy: 0.002)
        XCTAssertEqual(rightChannel[outputFrameCount - 1], 0.218, accuracy: 0.002)
    }

    func testRecorderFinalizationStreamsSingleSourceM4AConversion() async throws {
        let directory = makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("mic.wav")
        let outputURL = directory.appendingPathComponent("recording.m4a")
        let frameCount = Int(AudioRecorderService.finalizationChunkFrameCount) * 3 + 137
        try writePCMFile(
            at: sourceURL,
            frameCount: frameCount,
            sampleRate: 48_000,
            channelCount: 2,
            sample: 0.1
        )

        let recorderService = AudioRecorderService()
        let resultURL = await recorderService.finalizeRecording(.init(
            finalOutputURL: outputURL,
            micTempURL: sourceURL,
            systemTempURL: nil,
            outputFormat: .m4a,
            trackMode: .mixed,
            micDuckingMode: .off,
            transcriptionSamples: [],
            usesFinalizationOverride: false
        ))

        XCTAssertEqual(resultURL, outputURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        let outputFile = try AVAudioFile(forReading: outputURL)
        let outputDuration = Double(outputFile.length) / outputFile.processingFormat.sampleRate
        XCTAssertEqual(outputDuration, Double(frameCount) / 48_000, accuracy: 0.05)
    }

    private func makeViewModel(
        defaults: UserDefaults,
        modelManager: ModelManagerService = ModelManagerService(),
        recorderService: AudioRecorderService? = nil,
        dictionaryService: DictionaryService? = nil,
        audioDeviceService: AudioDeviceService = AudioDeviceService(initialInputDevices: [], monitorDeviceChanges: false),
        audioSamplesLoader: AudioRecorderViewModel.AudioSamplesLoader? = nil,
        livePreviewStartObserver: (() -> Void)? = nil
    ) -> AudioRecorderViewModel {
        setupEventBus()
        let resolvedRecorderService = recorderService ?? {
            let service = AudioRecorderService()
            service.recordingsDirectoryOverride = makeTemporaryDirectory()
            return service
        }()
        return AudioRecorderViewModel(
            recorderService: resolvedRecorderService,
            modelManager: modelManager,
            dictionaryService: dictionaryService ?? DictionaryService(appSupportDirectory: makeTemporaryDirectory()),
            audioDeviceService: audioDeviceService,
            defaults: defaults,
            audioSamplesLoader: audioSamplesLoader,
            livePreviewStartObserver: livePreviewStartObserver
        )
    }

    private func writePCMFile(
        at url: URL,
        frameCount: Int,
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        sample: Float
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return XCTFail("Could not allocate recorder finalization fixture")
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<Int(channelCount) {
            buffer.floatChannelData?[channel].update(repeating: sample, count: frameCount)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    private func makeFinalTranscriptionViewModel(
        defaults: UserDefaults,
        modelManager: ModelManagerService,
        recordingsDirectory: URL? = nil
    ) -> AudioRecorderViewModel {
        let recorderService = makeRecorderService(
            recordingsDirectory: recordingsDirectory ?? makeTemporaryDirectory()
        )
        let viewModel = makeViewModel(defaults: defaults, modelManager: modelManager, recorderService: recorderService)
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false
        return viewModel
    }

    private func makeRecorderService(
        recordingsDirectory: URL,
        outputURL: URL? = nil,
        samples: [Float] = Array(repeating: 0.25, count: Int(AudioRecorderService.transcriptionSampleRate))
    ) -> AudioRecorderService {
        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = recordingsDirectory
        recorderService.startRecordingOverride = { _, _, _, proposedOutputURL, _ in
            let resolvedOutputURL = outputURL ?? proposedOutputURL
            try FileManager.default.createDirectory(
                at: resolvedOutputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("placeholder".utf8).write(to: resolvedOutputURL)
            return resolvedOutputURL
        }
        recorderService.stopRecordingOverride = { resolvedOutputURL in
            try Data("recorded".utf8).write(to: resolvedOutputURL)
            return resolvedOutputURL
        }
        recorderService.currentBufferOverride = { samples }
        return recorderService
    }

    private func failureSidecarURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("transcription-failure.json")
    }

    private func waitForRetranscriptionToFinish(
        _ viewModel: AudioRecorderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if viewModel.retranscribingRecordingURL == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Recorder retranscription did not finish", file: file, line: line)
    }

    private func livePreviewStartCount(
        transcriptionEnabled: Bool,
        livePreviewEnabled: Bool
    ) async throws -> Int {
        let defaults = try makeDefaults()
        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = makeTemporaryDirectory()
        recorderService.startRecordingOverride = { _, _, _, outputURL, _ in
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        var startCount = 0
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: recorderService,
            livePreviewStartObserver: { startCount += 1 }
        )
        viewModel.transcriptionEnabled = transcriptionEnabled
        viewModel.livePreviewEnabled = livePreviewEnabled

        _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)

        return startCount
    }

    private func waitForRecorderSession(
        _ viewModel: AudioRecorderViewModel,
        id: UUID,
        status: AudioRecorderViewModel.RecorderAPISessionStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AudioRecorderViewModel.RecorderAPISessionSnapshot {
        for _ in 0..<40 {
            if let session = viewModel.apiRecorderSession(id: id), session.status == status {
                return session
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let session = viewModel.apiRecorderSession(id: id)
        XCTFail("Recorder session \(id) did not reach \(status.rawValue). Current status: \(session?.status.rawValue ?? "missing")", file: file, line: line)
        return try XCTUnwrap(session, file: file, line: line)
    }

    private func setupEventBus() {
        let previousEventBus: EventBus? = EventBus.shared
        EventBus.shared = EventBus()
        addTeardownBlock {
            EventBus.shared = previousEventBus
        }
    }

    private func setupPluginManager(
        groqBehavior: AudioRecorderMockTranscriptionPlugin.TranscriptionBehavior = .success("mock transcription"),
        assemblyAIBehavior: AudioRecorderMockTranscriptionPlugin.TranscriptionBehavior = .success("mock transcription")
    ) {
        let previousPluginManager = PluginManager.shared
        addTeardownBlock {
            PluginManager.shared = previousPluginManager
        }

        let appSupportDirectory = makeTemporaryDirectory()
        let pluginManager = PluginManager(appSupportDirectory: appSupportDirectory)
        pluginManager.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.groq",
                    name: "Groq",
                    version: "1.0.0",
                    principalClass: "AudioRecorderMockTranscriptionPlugin"
                ),
                instance: AudioRecorderMockTranscriptionPlugin(
                    providerId: "groq",
                    displayName: "Groq",
                    models: [
                        PluginModelInfo(id: "whisper-large-v3", displayName: "Whisper Large V3"),
                        PluginModelInfo(id: "whisper-small", displayName: "Whisper Small")
                    ],
                    selectedModelId: "whisper-large-v3",
                    behavior: groqBehavior
                ),
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.assemblyai",
                    name: "AssemblyAI",
                    version: "1.0.0",
                    principalClass: "AudioRecorderMockTranscriptionPlugin"
                ),
                instance: AudioRecorderMockTranscriptionPlugin(
                    providerId: "assemblyai",
                    displayName: "AssemblyAI",
                    models: [
                        PluginModelInfo(id: "universal-3-pro", displayName: "Universal-3 Pro"),
                        PluginModelInfo(id: "universal-2", displayName: "Universal-2")
                    ],
                    selectedModelId: "universal-2",
                    behavior: assemblyAIBehavior
                ),
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]
        PluginManager.shared = pluginManager
    }

    private func preserveStandardDefaults() throws {
        let keys = [
            UserDefaultsKeys.selectedEngine,
            UserDefaultsKeys.selectedModelId,
            UserDefaultsKeys.selectedInputDeviceUID,
            UserDefaultsKeys.inputDevicePriorityList
        ]
        let originals = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        addTeardownBlock {
            for key in keys {
                if let value = originals[key] {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "AudioRecorderViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRecorderViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

private final class AudioRecorderMockTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    struct Request: Sendable {
        let language: String?
        let translate: Bool
        let prompt: String?
    }

    enum TranscriptionBehavior {
        case success(String)
        case empty
        case failure(String)
    }

    static let pluginId = "com.typewhisper.mock.audio-recorder"
    static let pluginName = "Audio Recorder Mock"

    let providerId: String
    let providerDisplayName: String
    let transcriptionModels: [PluginModelInfo]
    var selectedModelId: String?
    var isConfigured = true
    var supportsTranslation = true
    private let behavior: TranscriptionBehavior
    private(set) var lastRequest: Request?
    private(set) var selectedModelOverrides: [String] = []

    required override init() {
        self.providerId = "mock"
        self.providerDisplayName = "Mock"
        self.transcriptionModels = []
        self.selectedModelId = nil
        self.behavior = .success("mock transcription")
        super.init()
    }

    init(
        providerId: String,
        displayName: String,
        models: [PluginModelInfo],
        selectedModelId: String?,
        behavior: TranscriptionBehavior = .success("mock transcription")
    ) {
        self.providerId = providerId
        self.providerDisplayName = displayName
        self.transcriptionModels = models
        self.selectedModelId = selectedModelId
        self.behavior = behavior
        super.init()
    }

    func activate(host: HostServices) {}
    func deactivate() {}

    func selectModel(_ modelId: String) {
        selectedModelOverrides.append(modelId)
        selectedModelId = modelId
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        lastRequest = Request(language: language, translate: translate, prompt: prompt)
        return switch behavior {
        case .success(let text):
            PluginTranscriptionResult(text: text)
        case .empty:
            PluginTranscriptionResult(text: "")
        case .failure(let message):
            throw PluginTranscriptionError.apiError(message)
        }
    }
}

private final class RecorderOverrideMarkerTranscriptionPlugin: NSObject, TranscriptionModelCatalogProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.recorder-override-marker"
    static let pluginName = "Recorder Override Marker"

    private let models = [
        PluginModelInfo(id: "whisper-large-v3", displayName: "Whisper Large V3"),
        PluginModelInfo(id: "whisper-small", displayName: "Whisper Small")
    ]
    private var selectedModelReadCount = 0
    private var currentModelId = "whisper-large-v3"
    private(set) var selectedModelOverrides: [String] = []

    var providerId: String { "recorder-override-marker" }
    var providerDisplayName: String { Self.pluginName }
    var isConfigured: Bool { true }
    var selectedModelId: String? {
        selectedModelReadCount += 1
        if selectedModelReadCount == 1 {
            currentModelId = "whisper-small"
            return "whisper-large-v3"
        }
        return currentModelId
    }
    var availableModels: [PluginModelInfo] { models }
    var transcriptionModels: [PluginModelInfo] { models }
    var supportsTranslation: Bool { true }

    func activate(host: HostServices) {}
    func deactivate() {}

    func selectModel(_ modelId: String) {
        selectedModelOverrides.append(modelId)
        currentModelId = modelId
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        let mode = selectedModelOverrides.isEmpty ? "unforced" : "forced"
        return PluginTranscriptionResult(text: "\(mode) \(currentModelId)")
    }
}
