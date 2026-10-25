import AppKit
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

/// 录音器在开始时报出的设备错误都是麦克风问题：语音条显示红色阻断状态，按钮打开通用页。
/// 录音器的开始过程是测试里的替身，识别引擎是测试里的插件，文本插入走私有剪贴板。
@MainActor
final class VoiceBarRecorderErrorTests: XCTestCase {
    private final class Engine: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.dictum.test.recordererror.engine" }
        static var pluginName: String { "Recorder Error Test Engine" }
        required override init() {}
        func activate(host: HostServices) {}
        func deactivate() {}
        var providerId: String { "recorder-error-test-engine" }
        var providerDisplayName: String { "Recorder Error Test Engine" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
        var selectedModelId: String? { "tiny" }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }
        var supportedLanguages: [String] { ["zh", "en"] }
        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "", detectedLanguage: language)
        }
    }

    private var directory: URL!
    private var previousPluginManager: PluginManager?
    private var retained: [AnyObject] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-recorder-error")
        previousPluginManager = PluginManager.shared
    }

    override func tearDown() async throws {
        PluginManager.shared = previousPluginManager
        retained = []
        TestSupport.remove(directory)
        try await super.tearDown()
    }

    private func makeModel(startError: Error) throws -> DictationViewModel {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: directory)
        let engine = Engine()
        PluginManager.shared.loadedPlugins = [LoadedPlugin(
            manifest: PluginManifest(id: "com.dictum.test.recordererror", name: "engine", version: "1.0.0", principalClass: "Engine"),
            instance: engine, bundle: Bundle.main, sourceURL: directory, isEnabled: true)]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(engine.providerId)
        let suite = "dictum-recorder-error-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let recorder = AudioRecordingService()
        recorder.hasMicrophonePermissionOverride = true
        recorder.inputAvailabilityOverride = { _ in true }
        recorder.startRecordingOverride = { throw startError }

        let insertion = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        insertion.pasteboardProvider = { pasteboard }
        insertion.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }
        insertion.accessibilityGrantedOverride = true
        insertion.selectedTextOverride = { nil }
        insertion.pasteSimulatorOverride = {}

        let hotkeys = HotkeyService()
        hotkeys.suspendMonitoring()
        let workflows = WorkflowService(appSupportDirectory: directory)
        let dictionary = DictionaryService(appSupportDirectory: directory)
        let settings = SettingsViewModel(modelManager: modelManager)
        let punctuation = DictationPunctuationProfileStore(defaults: defaults, storageKey: suite)
        let processing = PromptProcessingService(userDefaults: defaults)
        let sounds = SoundService()
        let media = MediaPlaybackService(startListening: false)
        let model = DictationViewModel(
            audioRecordingService: recorder, textInsertionService: insertion, hotkeyService: hotkeys, modelManager: modelManager,
            settingsViewModel: settings, historyService: HistoryService(appSupportDirectory: directory),
            recentTranscriptionStore: RecentTranscriptionStore(),
            profileService: ProfileService(appSupportDirectory: directory), workflowService: workflows, translationService: nil,
            audioDuckingService: AudioDuckingService(), dictionaryService: dictionary,
            targetAppCorrectionLearningService: TargetAppCorrectionLearningService(
                textInsertionService: insertion, textDiffService: TextDiffService(), dictionaryService: dictionary,
                defaults: defaults, persistLatestAttempt: false),
            snippetService: SnippetService(appSupportDirectory: directory), soundService: sounds,
            audioDeviceService: AudioDeviceService(initialInputDevices: [], monitorDeviceChanges: false, probeCompatibilities: false),
            promptActionService: PromptActionService(appSupportDirectory: directory),
            promptProcessingService: processing, appFormatterService: AppFormatterService(),
            punctuationStrategyResolver: PunctuationStrategyResolver(profileStore: punctuation),
            speechPunctuationService: SpeechPunctuationService(rulesLoader: PunctuationRulesLoader()),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(), errorLogService: ErrorLogService(appSupportDirectory: directory),
            mediaPlaybackService: media)
        model.soundFeedbackEnabled = false
        model.audioDuckingEnabled = false
        model.mediaPauseEnabled = false
        model.preserveClipboard = false
        retained = [recorder, insertion, modelManager, settings, processing, sounds, media, dictionary, workflows, hotkeys, engine]
        return model
    }

    func testEveryRecorderDeviceErrorIsABlockingMicrophoneError() async throws {
        typealias RecordingError = AudioRecordingService.AudioRecordingError
        let errors: [RecordingError] = [
            .noMicrophoneDetected,
            .selectedInputDeviceUnavailable,
            .selectedInputDeviceIncompatible(.cannotSetDevice),
            .audioRoutingConflict,
            .engineStartFailed("test"),
            .noAudioData,
        ]
        for error in errors {
            let model = try makeModel(startError: error)
            _ = model.apiStartRecording()
            await model.testingWaitForRecordingStart()

            let presentation = VoiceBarPresentation()
            presentation.refresh(model)
            let message = try XCTUnwrap(model.actionFeedbackMessage, "\(error)")
            XCTAssertFalse(message.isEmpty, "\(error)")
            XCTAssertEqual(presentation.state, .blockingError(message, page: .general), "\(error)")
            XCTAssertTrue(presentation.isActive, "\(error)")
            XCTAssertTrue(VoiceBarPresentation.replacesLegacyIndicator(model), "\(error)")
            model.dismissActionFeedback()
        }
    }

    func testOpenSettingsOnTheBlockingErrorClearsTheMenuBarError() async throws {
        let model = try makeModel(startError: AudioRecordingService.AudioRecordingError.noMicrophoneDetected)
        _ = model.apiStartRecording()
        await model.testingWaitForRecordingStart()
        XCTAssertNotNil(model.lastDictationError)

        var opened: [DictumPage] = []
        VoiceBarState.Destination.page(.general).open(dictation: model, openPage: { opened.append($0) })

        XCTAssertEqual(opened, [.general])
        XCTAssertNil(model.lastDictationError)
    }

    func testOpenSettingsOnATimedFailureClearsTheMenuBarError() async throws {
        struct EngineFailure: LocalizedError { var errorDescription: String? { "引擎失败" } }
        let model = try makeModel(startError: EngineFailure())
        _ = model.apiStartRecording()
        await model.testingWaitForRecordingStart()
        XCTAssertNotNil(model.lastDictationError)

        var opened: [DictumPage] = []
        VoiceBarState.Destination.page(.speech).open(dictation: model, openPage: { opened.append($0) })

        XCTAssertEqual(opened, [.speech])
        XCTAssertNil(model.lastDictationError)
    }

    func testOtherRecordingStartFailureStaysATimedFailure() async throws {
        struct StartFailure: LocalizedError { var errorDescription: String? { "录音启动失败" } }
        let model = try makeModel(startError: StartFailure())
        _ = model.apiStartRecording()
        await model.testingWaitForRecordingStart()

        let presentation = VoiceBarPresentation()
        presentation.refresh(model)
        XCTAssertEqual(presentation.state, .failure("录音启动失败", destination: nil))
        model.dismissActionFeedback()
    }
}
