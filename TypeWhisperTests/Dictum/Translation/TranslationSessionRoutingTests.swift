import AppKit
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

/// 翻译会话在 `DictationViewModel` 里的完整流程：识别、AI 模型链、插入和历史。
/// 识别引擎和 AI 供应商是测试里的替身，文本插入走私有剪贴板，不产生全局输入。
@MainActor
final class TranslationSessionRoutingTests: XCTestCase {
    private final class Engine: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.dictum.test.translation.engine" }
        static var pluginName: String { "Translation Test Engine" }
        var text = "嗯，我到楼下了"
        private(set) var languages: [String?] = []
        required override init() {}
        func activate(host: HostServices) {}
        func deactivate() {}
        var providerId: String { "translation-test-engine" }
        var providerDisplayName: String { "Translation Test Engine" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
        var selectedModelId: String? { "tiny" }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }
        var supportedLanguages: [String] { ["zh", "en", "ja"] }
        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            languages.append(language)
            return PluginTranscriptionResult(text: text, detectedLanguage: language)
        }
    }

    private final class Chain: NSObject, LLMProviderPlugin, @unchecked Sendable {
        static var pluginId: String { "com.dictum.test.translation.chain" }
        static var pluginName: String { "Translation Test Chain" }
        private let lock = NSLock()
        private var _prompts: [String] = []
        private var _texts: [String] = []
        var reply: Result<String, Error> = .success("下に着きました。")
        required override init() {}
        func activate(host: HostServices) {}
        func deactivate() {}
        var providerName: String { "Translation Test Chain" }
        var isAvailable: Bool { true }
        var supportedModels: [PluginModelInfo] { [] }
        var prompts: [String] { lock.withLock { _prompts } }
        var texts: [String] { lock.withLock { _texts } }
        func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
            lock.withLock { _prompts.append(systemPrompt); _texts.append(userText) }
            return try reply.get()
        }
    }

    private struct ChainFailure: Error, LocalizedError { var errorDescription: String? { "所有供应商都失败了" } }

    private struct Fixture {
        let model: DictationViewModel
        let engine: Engine
        let chain: Chain
        let history: HistoryService
        let workflows: WorkflowService
        let hotkeys: HotkeyService
        let pasteboard: NSPasteboard
        let retained: [AnyObject]
    }

    private static let languageKeys = [
        TranslationLanguageStore.Keys.spoken, TranslationLanguageStore.Keys.targets, TranslationLanguageStore.Keys.current,
        TranslationLanguageStore.Keys.migrated, TranslationLanguageStore.Keys.legacyTarget, TranslationLanguageStore.Keys.legacyTargets,
        UserDefaultsKeys.historyEnabled, UserDefaultsKeys.preserveClipboard
    ]

    private var directory: URL!
    private var savedDefaults: [String: Any] = [:]
    private var previousPluginManager: PluginManager?

    override func setUp() async throws {
        try await super.setUp()
        directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-translation-routing")
        previousPluginManager = PluginManager.shared
        let defaults = UserDefaults.standard
        savedDefaults = Dictionary(uniqueKeysWithValues: Self.languageKeys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        defaults.set(true, forKey: UserDefaultsKeys.historyEnabled)
        defaults.set(false, forKey: UserDefaultsKeys.preserveClipboard)
        defaults.set(true, forKey: TranslationLanguageStore.Keys.migrated)
        for key in [TranslationLanguageStore.Keys.spoken, TranslationLanguageStore.Keys.targets, TranslationLanguageStore.Keys.current] {
            defaults.removeObject(forKey: key)
        }
        TranslationLanguageStore.shared.reload()
    }

    override func tearDown() async throws {
        let defaults = UserDefaults.standard
        for key in Self.languageKeys {
            if let value = savedDefaults[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        TranslationLanguageStore.shared.reload()
        PluginManager.shared = previousPluginManager
        TestSupport.remove(directory)
        try await super.tearDown()
    }

    private func setLanguages(spoken: String, targets: [String], current: String? = nil) {
        let defaults = UserDefaults.standard
        defaults.set(spoken, forKey: TranslationLanguageStore.Keys.spoken)
        defaults.set(targets, forKey: TranslationLanguageStore.Keys.targets)
        if let current { defaults.set(current, forKey: TranslationLanguageStore.Keys.current) }
        TranslationLanguageStore.shared.reload()
    }

    private func makeFixture(withModel: Bool = true) throws -> Fixture {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: directory)
        let engine = Engine()
        let chain = Chain()
        func loaded(_ id: String, _ instance: any TypeWhisperPlugin) -> LoadedPlugin {
            LoadedPlugin(
                manifest: PluginManifest(id: id, name: id, version: "1.0.0", principalClass: "TranslationRoutingTestPlugin"),
                instance: instance, bundle: Bundle.main, sourceURL: directory, isEnabled: true)
        }
        PluginManager.shared.loadedPlugins = [loaded("com.dictum.test.engine", engine), loaded("com.dictum.test.chain", chain)]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(engine.providerId)
        let suite = "dictum-translation-routing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        if withModel {
            defaults.set(try JSONEncoder().encode([LLMFallbackPriorityItem(providerId: chain.providerName)]), forKey: UserDefaultsKeys.llmFallbackPriorityList)
        } else {
            defaults.set(Data("[]".utf8), forKey: UserDefaultsKeys.llmFallbackPriorityList)
        }

        let recorder = AudioRecordingService()
        recorder.hasMicrophonePermissionOverride = true
        recorder.inputAvailabilityOverride = { _ in true }
        recorder.startRecordingOverride = {}
        recorder.stopRecordingOverride = { _ in Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate)) }

        let insertion = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        insertion.pasteboardProvider = { pasteboard }
        insertion.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }
        insertion.accessibilityGrantedOverride = true
        insertion.selectedTextOverride = { nil }
        insertion.pasteSimulatorOverride = {}

        let hotkeys = HotkeyService()
        hotkeys.suspendMonitoring()
        let history = HistoryService(appSupportDirectory: directory)
        let workflows = WorkflowService(appSupportDirectory: directory)
        let dictionary = DictionaryService(appSupportDirectory: directory)
        let settings = SettingsViewModel(modelManager: modelManager)
        let punctuation = DictationPunctuationProfileStore(defaults: defaults, storageKey: suite)
        let processing = PromptProcessingService(userDefaults: defaults)
        let sounds = SoundService()
        let media = MediaPlaybackService(startListening: false)
        let model = DictationViewModel(
            audioRecordingService: recorder, textInsertionService: insertion, hotkeyService: hotkeys, modelManager: modelManager,
            settingsViewModel: settings, historyService: history, recentTranscriptionStore: RecentTranscriptionStore(),
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
        return Fixture(model: model, engine: engine, chain: chain, history: history, workflows: workflows, hotkeys: hotkeys,
                       pasteboard: pasteboard, retained: [recorder, insertion, modelManager, settings, processing, sounds, media, dictionary])
    }

    /// 开始一次会话并说完，等到历史记录写入。
    @discardableResult
    private func runSession(_ fixture: Fixture, mode: DictationMode) async throws -> DictationSessionSnapshot? {
        let model = fixture.model
        let sessionID = model.apiStartRecording(mode: mode)
        await model.testingWaitForRecordingStart()
        _ = model.apiStopRecording()
        for _ in 0..<80 {
            if model.apiDictationSession(id: sessionID)?.status == .completed { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        await model.testingWaitForPostInsertionPersistence()
        return model.apiDictationSession(id: sessionID)
    }

    // MARK: - 路由

    func testTranslationSessionCallsTheModelChainWithThePair() async throws {
        setLanguages(spoken: "zh-Hans", targets: ["ja"])
        let fixture = try makeFixture()
        _ = try await runSession(fixture, mode: .translation)
        XCTAssertEqual(fixture.chain.texts.count, 1)
        let text = try XCTUnwrap(fixture.chain.texts.first)
        let prompt = try XCTUnwrap(fixture.chain.prompts.first)
        XCTAssertTrue(text.contains("嗯，我到楼下了"))
        XCTAssertTrue(prompt.contains("Japanese (ja)"))
        XCTAssertTrue(prompt.contains("Chinese, Simplified (zh-Hans)"))
        XCTAssertEqual(fixture.engine.languages, ["zh"], "识别引擎收到说话语言作为提示")
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "下に着きました。")
        XCTAssertEqual(fixture.model.sessionMode, .translation)
        XCTAssertNil(fixture.model.translationFailure)
        let record = try XCTUnwrap(fixture.history.recentRecords.first)
        XCTAssertEqual(record.mode, .translation)
        XCTAssertEqual(record.targetLanguage, "ja")
        XCTAssertEqual(record.spokenLanguage, "zh-Hans")
        XCTAssertEqual(record.rawText, "嗯，我到楼下了")
        XCTAssertEqual(record.finalText, "下に着きました。")
        XCTAssertNil(record.processingFailureMessage)
    }

    func testDictationSessionNeverCallsTheTranslationPrompt() async throws {
        setLanguages(spoken: "zh-Hans", targets: ["ja"])
        let fixture = try makeFixture()
        fixture.chain.reply = .success("我到楼下了。")
        _ = try await runSession(fixture, mode: .dictation)
        XCTAssertFalse(fixture.chain.prompts.contains { $0.contains("Translate a speech transcript") })
        XCTAssertEqual(fixture.chain.prompts.count, 1, "听写会话只运行润色提示词")
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "我到楼下了。")
        XCTAssertNil(fixture.model.sessionPair)
        let record = try XCTUnwrap(fixture.history.recentRecords.first)
        XCTAssertEqual(record.mode, .dictation)
        XCTAssertNil(record.targetLanguage)
    }

    func testFailureInsertsTheOriginalAndShowsTheTranslationFailedState() async throws {
        setLanguages(spoken: "zh-Hans", targets: ["en"])
        let fixture = try makeFixture()
        fixture.chain.reply = .failure(ChainFailure())
        _ = try await runSession(fixture, mode: .translation)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "嗯，我到楼下了")
        XCTAssertEqual(fixture.model.translationFailure, TranslationStrings.failedInserted)
        XCTAssertEqual(fixture.model.actionFeedbackIcon, "exclamationmark.triangle.fill")
        XCTAssertEqual(fixture.model.actionFeedbackMessage, TranslationStrings.failedInserted)
        guard case .translationFailed = VoiceBarState.Input.Outcome.warning(translation: fixture.model.sessionMode == .translation) else {
            return XCTFail("翻译会话的警告必须是翻译失败")
        }
        XCTAssertNotNil(fixture.model.polishFailure, "失败后可以重试")
        let record = try XCTUnwrap(fixture.history.recentRecords.first)
        XCTAssertEqual(record.mode, .translation)
        XCTAssertEqual(record.processingFailureMessage, TranslationStrings.failedInserted)
        XCTAssertEqual(record.finalText, "嗯，我到楼下了")
    }

    func testWithoutAModelTheOriginalIsInsertedAndNothingIsSent() async throws {
        let fixture = try makeFixture(withModel: false)
        _ = try await runSession(fixture, mode: .translation)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "嗯，我到楼下了")
        XCTAssertTrue(fixture.chain.prompts.isEmpty)
        XCTAssertEqual(fixture.model.translationFailure, TranslationStrings.noModel)
        XCTAssertEqual(fixture.history.recentRecords.first?.processingFailureMessage, TranslationStrings.noModel)
    }

    func testTargetsEqualToTheSpokenLanguageFallBackToTheDefaultTarget() async throws {
        setLanguages(spoken: "zh-Hans", targets: ["zh-Hans"])
        let fixture = try makeFixture()
        fixture.chain.reply = .success("I'm downstairs.")
        _ = try await runSession(fixture, mode: .translation)
        XCTAssertEqual(fixture.chain.prompts.count, 1)
        let prompt = try XCTUnwrap(fixture.chain.prompts.first)
        XCTAssertTrue(prompt.contains("English (en)"))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "I'm downstairs.")
        XCTAssertEqual(fixture.history.recentRecords.first?.targetLanguage, "en")
    }

    func testUpgradingADictationSessionClearsTheMatchedWorkflow() async throws {
        setLanguages(spoken: "zh-Hans", targets: ["en"])
        let fixture = try makeFixture()
        _ = fixture.workflows.addWorkflow(
            name: "笔记整理", template: .summary,
            trigger: WorkflowTrigger(kind: .app, appBundleIdentifiers: ["com.apple.Notes"]))
        let model = fixture.model
        let sessionID = model.apiStartRecording(mode: .dictation)
        await model.testingWaitForRecordingStart()
        XCTAssertEqual(model.sessionMode, .dictation)
        XCTAssertEqual(model.activeRuleName, "笔记整理", "听写会话匹配到应用工作流")
        fixture.hotkeys.onDictationModeUpgrade?()
        XCTAssertEqual(model.sessionMode, .translation)
        XCTAssertEqual(model.sessionPair, TranslationPair(spoken: "zh-Hans", target: "en"))
        XCTAssertNil(model.activeRuleName, "翻译会话不运行用户工作流")
        _ = model.apiStopRecording()
        for _ in 0..<80 where model.apiDictationSession(id: sessionID)?.status != .completed {
            try await Task.sleep(for: .milliseconds(25))
        }
        await model.testingWaitForPostInsertionPersistence()
        XCTAssertTrue(fixture.chain.prompts.allSatisfy { $0.contains("Translate a speech transcript") }, "只运行翻译提示词")
    }
}
