import AudioToolbox
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

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

    private func makeViewModel(
        defaults: UserDefaults,
        modelManager: ModelManagerService = ModelManagerService(),
        recorderService: AudioRecorderService? = nil,
        audioDeviceService: AudioDeviceService = AudioDeviceService(initialInputDevices: [], monitorDeviceChanges: false),
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
            dictionaryService: DictionaryService(appSupportDirectory: makeTemporaryDirectory()),
            audioDeviceService: audioDeviceService,
            defaults: defaults,
            livePreviewStartObserver: livePreviewStartObserver
        )
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
        selectedModelId = modelId
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        switch behavior {
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
