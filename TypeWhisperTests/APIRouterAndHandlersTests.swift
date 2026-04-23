import AppKit
import CoreAudio
import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class APIRouterAndHandlersTests: XCTestCase {
    @objc(APIRouterMockLLMProviderPlugin)
    private final class MockLLMProviderPlugin: NSObject, LLMProviderPlugin, LLMProviderSetupStatusProviding, LLMTemperatureControllableProvider, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.llm" }
        static var pluginName: String { "Mock LLM" }

        private let requestLock = NSLock()
        var models: [PluginModelInfo] = []
        var responseText = "processed"
        var available = true
        var configuredProviderName = "Gemini"
        var requiresExternalCredentials = true
        var unavailableReason: String?
        nonisolated(unsafe) private var _lastRequestedModel: String?
        nonisolated(unsafe) private var _lastTemperatureDirective: PluginLLMTemperatureDirective?

        var lastRequestedModel: String? {
            requestLock.withLock { _lastRequestedModel }
        }

        var lastTemperatureDirective: PluginLLMTemperatureDirective? {
            requestLock.withLock { _lastTemperatureDirective }
        }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerName: String { configuredProviderName }
        var isAvailable: Bool { available }
        var supportedModels: [PluginModelInfo] { models }

        func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
            requestLock.withLock {
                _lastRequestedModel = model
            }
            return responseText
        }

        func process(
            systemPrompt: String,
            userText: String,
            model: String?,
            temperatureDirective: PluginLLMTemperatureDirective
        ) async throws -> String {
            requestLock.withLock {
                _lastRequestedModel = model
                _lastTemperatureDirective = temperatureDirective
            }
            return responseText
        }
    }

    @objc(APIRouterMockLegacyLLMProviderPlugin)
    private final class MockLegacyLLMProviderPlugin: NSObject, LLMProviderPlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.legacy-llm" }
        static var pluginName: String { "Mock Legacy LLM" }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerName: String { "Legacy LLM" }
        var isAvailable: Bool { true }
        var supportedModels: [PluginModelInfo] { [] }

        func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
            "processed"
        }
    }

    @objc(APIRouterMockTranscriptionPlugin)
    private final class MockTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, LanguageHintTranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.transcription" }
        static var pluginName: String { "Mock Transcription" }
        private static let promptLock = NSLock()
        nonisolated(unsafe) private static var _lastPrompt: String?
        nonisolated(unsafe) private static var _lastLanguageSelection = PluginLanguageSelection()

        static var lastPrompt: String? {
            promptLock.withLock { _lastPrompt }
        }

        static var lastLanguageSelection: PluginLanguageSelection {
            promptLock.withLock { _lastLanguageSelection }
        }

        static func reset() {
            promptLock.withLock {
                _lastPrompt = nil
                _lastLanguageSelection = PluginLanguageSelection()
            }
        }

        var languages: [String] = []

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "mock" }
        var providerDisplayName: String { "Mock" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
        var selectedModelId: String? { "tiny" }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }
        var supportedLanguages: [String] { languages }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            Self.promptLock.withLock {
                Self._lastPrompt = prompt
                Self._lastLanguageSelection = PluginLanguageSelection(requestedLanguage: language)
            }
            return PluginTranscriptionResult(text: "transcribed", detectedLanguage: language)
        }

        func transcribe(
            audio: AudioData,
            languageSelection: PluginLanguageSelection,
            translate: Bool,
            prompt: String?
        ) async throws -> PluginTranscriptionResult {
            Self.promptLock.withLock {
                Self._lastPrompt = prompt
                Self._lastLanguageSelection = languageSelection
            }
            return PluginTranscriptionResult(
                text: "transcribed",
                detectedLanguage: languageSelection.requestedLanguage ?? languageSelection.languageHints.first
            )
        }
    }

    @objc(APIRouterBudgetedTranscriptionPlugin)
    private final class BudgetedTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsBudgetProviding, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.budgeted-transcription" }
        static var pluginName: String { "Budgeted Mock Transcription" }
        private static let promptLock = NSLock()
        nonisolated(unsafe) private static var _lastPrompt: String?

        static var lastPrompt: String? {
            promptLock.withLock { _lastPrompt }
        }

        static func reset() {
            promptLock.withLock {
                _lastPrompt = nil
            }
        }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "budgeted-mock" }
        var providerDisplayName: String { "Budgeted Mock" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "large", displayName: "Large")] }
        var selectedModelId: String? { "large" }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }
        var dictionaryTermsBudget: DictionaryTermsBudget { DictionaryTermsBudget(maxTotalChars: 2_000) }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            Self.promptLock.withLock {
                Self._lastPrompt = prompt
            }
            return PluginTranscriptionResult(text: "transcribed", detectedLanguage: language)
        }
    }

    @objc(APIRouterConfigurableTranscriptionPlugin)
    private final class ConfigurableTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.configurable-transcription" }
        static var pluginName: String { "Configurable Mock Transcription" }

        var configured = false
        var currentModelId: String?

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "configurable-mock" }
        var providerDisplayName: String { "Configurable Mock" }
        var isConfigured: Bool { configured }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
        var selectedModelId: String? { currentModelId }
        func selectModel(_ modelId: String) {
            currentModelId = modelId
            configured = true
        }
        var supportsTranslation: Bool { false }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "transcribed", detectedLanguage: language)
        }
    }

    @objc(APIRouterCatalogTranscriptionPlugin)
    private final class CatalogTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.catalog-transcription" }
        static var pluginName: String { "Catalog Mock Transcription" }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "catalog-mock" }
        var providerDisplayName: String { "Catalog Mock" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] {
            [PluginModelInfo(id: "tiny", displayName: "Tiny")]
        }
        var availableModels: [PluginModelInfo] {
            [
                PluginModelInfo(id: "tiny", displayName: "Tiny"),
                PluginModelInfo(id: "large", displayName: "Large")
            ]
        }
        var selectedModelId: String? { "tiny" }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "transcribed", detectedLanguage: language)
        }
    }

    @objc(APIRouterMockTTSPlugin)
    private final class MockTTSProviderPlugin: NSObject, TTSProviderPlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.tts" }
        static var pluginName: String { "Mock TTS" }

        private let requestsLock = NSLock()
        private var requests: [TTSSpeakRequest] = []
        var onSpeak: ((TTSSpeakRequest) -> Void)?

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "mock-tts" }
        var providerDisplayName: String { "Mock TTS" }
        var isConfigured: Bool { true }
        var availableVoices: [PluginVoiceInfo] { [] }
        var selectedVoiceId: String? { nil }
        var settingsSummary: String? { "Mock Summary" }
        var recordedRequests: [TTSSpeakRequest] {
            requestsLock.withLock { requests }
        }

        func selectVoice(_ voiceId: String?) {}

        func speak(_ request: TTSSpeakRequest) async throws -> any TTSPlaybackSession {
            requestsLock.withLock {
                requests.append(request)
            }
            onSpeak?(request)
            return MockTTSPlaybackSession()
        }
    }

    private final class MockTTSPlaybackSession: TTSPlaybackSession, @unchecked Sendable {
        var isActive: Bool = true
        var onFinish: (@Sendable () -> Void)?

        func stop() {
            guard isActive else { return }
            isActive = false
            onFinish?()
        }
    }

    private final class MockEventBus: EventBusProtocol, @unchecked Sendable {
        @discardableResult
        func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID {
            UUID()
        }

        func unsubscribe(id: UUID) {}
    }

    private final class MockHostServices: HostServices, @unchecked Sendable {
        private var secrets: [String: String]
        private var defaults: [String: Any]

        let pluginDataDirectory: URL
        let eventBus: EventBusProtocol = MockEventBus()
        var activeAppBundleId: String?
        var activeAppName: String?
        var availableRuleNames: [String]
        private(set) var capabilitiesChangedCount = 0
        private(set) var streamingDisplayActiveValues: [Bool] = []

        init(
            pluginDataDirectory: URL,
            secrets: [String: String] = [:],
            defaults: [String: Any] = [:],
            availableRuleNames: [String] = []
        ) {
            self.pluginDataDirectory = pluginDataDirectory
            self.secrets = secrets
            self.defaults = defaults
            self.availableRuleNames = availableRuleNames
        }

        func storeSecret(key: String, value: String) throws {
            secrets[key] = value
        }

        func loadSecret(key: String) -> String? {
            secrets[key]
        }

        func userDefault(forKey key: String) -> Any? {
            defaults[key]
        }

        func setUserDefault(_ value: Any?, forKey key: String) {
            defaults[key] = value
        }

        func notifyCapabilitiesChanged() {
            capabilitiesChangedCount += 1
        }

        func setStreamingDisplayActive(_ active: Bool) {
            streamingDisplayActiveValues.append(active)
        }
    }

    private final class APIContext: @unchecked Sendable {
        let router: APIRouter
        let modelManager: ModelManagerService
        let historyService: HistoryService
        let profileService: ProfileService
        let dictionaryService: DictionaryService
        let dictationViewModel: DictationViewModel
        let audioRecordingService: AudioRecordingService
        let textInsertionService: TextInsertionService
        let ttsProvider: MockTTSProviderPlugin
        private let retainedObjects: [AnyObject]

        init(
            router: APIRouter,
            modelManager: ModelManagerService,
            historyService: HistoryService,
            profileService: ProfileService,
            dictionaryService: DictionaryService,
            dictationViewModel: DictationViewModel,
            audioRecordingService: AudioRecordingService,
            textInsertionService: TextInsertionService,
            ttsProvider: MockTTSProviderPlugin,
            retainedObjects: [AnyObject]
        ) {
            self.router = router
            self.modelManager = modelManager
            self.historyService = historyService
            self.profileService = profileService
            self.dictionaryService = dictionaryService
            self.dictationViewModel = dictationViewModel
            self.audioRecordingService = audioRecordingService
            self.textInsertionService = textInsertionService
            self.ttsProvider = ttsProvider
            self.retainedObjects = retainedObjects
        }
    }

    @MainActor
    private final class MockMediaPlaybackService: MediaPlaybackService {
        let onPause: () -> Void
        let onResume: () -> Void

        init(
            onPause: @escaping () -> Void = {},
            onResume: @escaping () -> Void = {}
        ) {
            self.onPause = onPause
            self.onResume = onResume
            super.init(startListening: false)
        }

        override func pauseIfPlaying() {
            onPause()
        }

        override func resumeIfWePaused() {
            onResume()
        }
    }

    @MainActor
    private final class MockAudioDuckingService: AudioDuckingService {
        let onRestore: () -> Void

        init(onRestore: @escaping () -> Void = {}) {
            self.onRestore = onRestore
        }

        override func restoreAudio() {
            onRestore()
        }
    }

    #if !APPSTORE
    private final class FakeMediaPlaybackController: MediaPlaybackControlling {
        var returnedSnapshot: (isPlaying: Bool, bundleIdentifier: String?) = (false, nil)
        var onGetPlaybackSnapshot: ((@escaping (_ isPlaying: Bool, _ bundleIdentifier: String?) -> Void) -> Void)?
        private(set) var pauseCalls = 0
        private(set) var playCalls = 0

        func getPlaybackSnapshot(_ onReceive: @escaping (_ isPlaying: Bool, _ bundleIdentifier: String?) -> Void) {
            if let onGetPlaybackSnapshot {
                onGetPlaybackSnapshot(onReceive)
                return
            }
            onReceive(returnedSnapshot.isPlaying, returnedSnapshot.bundleIdentifier)
        }

        func play() {
            playCalls += 1
        }

        func pause() {
            pauseCalls += 1
        }
    }

    @MainActor
    private final class TestMediaPlaybackResumeScheduler {
        private(set) var scheduledDelays: [TimeInterval] = []
        private var actions: [@MainActor () -> Void] = []

        func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
            scheduledDelays.append(delay)
            actions.append(action)
        }

        func runPendingActions() {
            let pendingActions = actions
            actions.removeAll()
            for action in pendingActions {
                action()
            }
        }
    }
    #endif

    func testRouterHandlesOptionsAndNotFound() async {
        let router = APIRouter()

        let optionsResponse = await router.route(
            HTTPRequest(method: "OPTIONS", path: "/v1/status", queryParams: [:], headers: [:], body: Data())
        )
        let notFoundResponse = await router.route(
            HTTPRequest(method: "GET", path: "/missing", queryParams: [:], headers: [:], body: Data())
        )

        XCTAssertEqual(optionsResponse.status, 200)
        XCTAssertEqual(notFoundResponse.status, 404)
    }

    func testAPIHandlersExposeStatusHistoryAndRules() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { () -> APIContext in
            let context = Self.makeAPIContext(appSupportDirectory: appSupportDirectory)
            context.historyService.addRecord(
                rawText: "Sprint planning",
                finalText: "Sprint planning",
                appName: "Notes",
                appBundleIdentifier: "com.apple.Notes",
                durationSeconds: 5,
                language: "en",
                engineUsed: "parakeet"
            )
            context.profileService.addProfile(
                name: "Docs",
                urlPatterns: ["docs.github.com"],
                inputLanguage: #"["de","en"]"#,
                priority: 1
            )
            return context
        }

        let router = try XCTUnwrap(context?.router)

        let status = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/status", queryParams: [:], headers: [:], body: Data()))
        )
        let history = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/history", queryParams: [:], headers: [:], body: Data()))
        )
        let rules = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/rules", queryParams: [:], headers: [:], body: Data()))
        )
        let legacyProfiles = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/profiles", queryParams: [:], headers: [:], body: Data()))
        )

        XCTAssertEqual(status["status"] as? String, "no_model")
        XCTAssertEqual((history["entries"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((rules["rules"] as? [[String: Any]])?.first?["name"] as? String, "Docs")
        XCTAssertEqual((rules["rules"] as? [[String: Any]])?.first?["language_mode"] as? String, "multiple")
        XCTAssertEqual((rules["rules"] as? [[String: Any]])?.first?["language_hints"] as? [String], ["de", "en"])
        XCTAssertNil((rules["rules"] as? [[String: Any]])?.first?["input_language"] as? String)
        XCTAssertEqual((legacyProfiles["profiles"] as? [[String: Any]])?.first?["name"] as? String, "Docs")
    }

    func testDictionaryTermsEndpointsReplaceNormalizeAndClearTerms() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let apiContext = try XCTUnwrap(context)
        let router = apiContext.router

        let putBody = try JSONSerialization.data(withJSONObject: [
            "terms": [" TypeWhisper ", "WhisperKit", "typewhisper", "", "Qwen3 "],
            "replace": true
        ])
        let putResponse = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "PUT",
                path: "/v1/dictionary/terms",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: putBody
            )
        ))
        let expectedTerms = ["Qwen3", "TypeWhisper", "WhisperKit"]
        XCTAssertEqual(putResponse["count"] as? Int, 3)
        XCTAssertEqual(putResponse["terms"] as? [String], expectedTerms)

        let getResponse = try Self.jsonObject(await router.route(
            HTTPRequest(method: "GET", path: "/v1/dictionary/terms", queryParams: [:], headers: [:], body: Data())
        ))
        XCTAssertEqual(getResponse["terms"] as? [String], expectedTerms)
        let enabledTerms = await MainActor.run { apiContext.dictionaryService.enabledTerms() }
        XCTAssertEqual(enabledTerms, expectedTerms)

        let deleteResponse = try Self.jsonObject(await router.route(
            HTTPRequest(method: "DELETE", path: "/v1/dictionary/terms", queryParams: [:], headers: [:], body: Data())
        ))
        XCTAssertEqual(deleteResponse["deleted"] as? Bool, true)
        XCTAssertEqual(deleteResponse["count"] as? Int, 0)

        let finalGet = try Self.jsonObject(await router.route(
            HTTPRequest(method: "GET", path: "/v1/dictionary/terms", queryParams: [:], headers: [:], body: Data())
        ))
        XCTAssertEqual(finalGet["terms"] as? [String], [])
    }

    func testTranscribeEndpointPassesDictionaryTermsAsPrompt() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        context = await MainActor.run {
            let context = Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
            context.dictionaryService.setTerms([" TypeWhisper ", "WhisperKit", "typewhisper"], replaceExisting: true)
            return context
        }

        let router = try XCTUnwrap(context?.router)
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("en\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        ))

        XCTAssertEqual(response["text"] as? String, "transcribed")
        XCTAssertEqual(MockTranscriptionPlugin.lastPrompt, "TypeWhisper, WhisperKit")
    }

    func testTranscribeEndpointUsesOverrideEngineBudgetForDictionaryPrompt() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        BudgetedTranscriptionPlugin.reset()
        context = await MainActor.run {
            let context = Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
            PluginManager.shared.loadedPlugins.append(
                LoadedPlugin(
                    manifest: PluginManifest(
                        id: "com.typewhisper.mock.budgeted-transcription",
                        name: "Budgeted Mock Transcription",
                        version: "1.0.0",
                        principalClass: "APIRouterBudgetedTranscriptionPlugin"
                    ),
                    instance: BudgetedTranscriptionPlugin(),
                    bundle: Bundle.main,
                    sourceURL: appSupportDirectory,
                    isEnabled: true
                )
            )
            context.dictionaryService.setTerms(Self.makeLongTerms(count: 40, length: 24), replaceExisting: true)
            return context
        }

        let router = try XCTUnwrap(context?.router)
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))

        let response = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: [
                    "content-type": "audio/wav",
                    "x-engine": "budgeted-mock",
                ],
                body: wavData
            )
        ))

        XCTAssertEqual(response["text"] as? String, "transcribed")
        XCTAssertNil(MockTranscriptionPlugin.lastPrompt)
        XCTAssertGreaterThan(try XCTUnwrap(BudgetedTranscriptionPlugin.lastPrompt).count, 600)
    }

    func testTranscribeEndpointUsesSelectedEngineBudgetWhenNoOverrideIsProvided() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        BudgetedTranscriptionPlugin.reset()
        context = await MainActor.run {
            let context = Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
            let budgetedPlugin = BudgetedTranscriptionPlugin()
            PluginManager.shared.loadedPlugins.append(
                LoadedPlugin(
                    manifest: PluginManifest(
                        id: "com.typewhisper.mock.budgeted-transcription",
                        name: "Budgeted Mock Transcription",
                        version: "1.0.0",
                        principalClass: "APIRouterBudgetedTranscriptionPlugin"
                    ),
                    instance: budgetedPlugin,
                    bundle: Bundle.main,
                    sourceURL: appSupportDirectory,
                    isEnabled: true
                )
            )
            context.modelManager.selectProvider(budgetedPlugin.providerId)
            context.dictionaryService.setTerms(Self.makeLongTerms(count: 40, length: 24), replaceExisting: true)
            return context
        }

        let router = try XCTUnwrap(context?.router)
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))

        let response = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "audio/wav"],
                body: wavData
            )
        ))

        XCTAssertEqual(response["text"] as? String, "transcribed")
        XCTAssertNil(MockTranscriptionPlugin.lastPrompt)
        XCTAssertGreaterThan(try XCTUnwrap(BudgetedTranscriptionPlugin.lastPrompt).count, 600)
    }

    func testTranscribeEndpointAcceptsRepeatedLanguageHints() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }

        let router = try XCTUnwrap(context?.router)
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        for hint in ["de", "en"] {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language_hint\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(hint)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        ))

        XCTAssertEqual(response["text"] as? String, "transcribed")
        XCTAssertEqual(MockTranscriptionPlugin.lastLanguageSelection.languageHints, ["de", "en"])
        XCTAssertNil(MockTranscriptionPlugin.lastLanguageSelection.requestedLanguage)
    }

    func testTranscribeEndpointRejectsMixedLanguageAndHints() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }

        let router = try XCTUnwrap(context?.router)
        let response = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: [
                    "content-type": "audio/wav",
                    "x-language": "de",
                    "x-language-hints": "en,nl"
                ],
                body: WavEncoder.encode(Array(repeating: Float(0), count: 1600))
            )
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, "Use either 'language' or 'language_hint', not both")
    }

    func testDictationStartReturnsConflictWhenRecordingCannotStart() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let router = try XCTUnwrap(context?.router)

        let response = await router.route(
            HTTPRequest(method: "POST", path: "/v1/dictation/start", queryParams: [:], headers: [:], body: Data())
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, TranscriptionEngineError.modelNotLoaded.localizedDescription)
    }

    func testDictationEndpointsReturnSessionIDAndCompletedTranscription() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let historyEnabledKey = UserDefaultsKeys.historyEnabled
        let originalHistoryEnabled = UserDefaults.standard.object(forKey: historyEnabledKey)
        var context: APIContext?
        defer {
            context = nil
            if let originalHistoryEnabled {
                UserDefaults.standard.set(originalHistoryEnabled, forKey: historyEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: historyEnabledKey)
            }
            TestSupport.remove(appSupportDirectory)
        }

        UserDefaults.standard.set(true, forKey: historyEnabledKey)

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let apiContext = try XCTUnwrap(context)
        let router = apiContext.router

        await MainActor.run {
            apiContext.audioRecordingService.hasMicrophonePermissionOverride = true
            apiContext.audioRecordingService.inputAvailabilityOverride = { _ in true }
            apiContext.audioRecordingService.startRecordingOverride = {}
            apiContext.audioRecordingService.stopRecordingOverride = { _ in
                Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate))
            }
            apiContext.textInsertionService.accessibilityGrantedOverride = true
            apiContext.textInsertionService.captureActiveAppOverride = {
                ("Notes", "com.apple.Notes", nil)
            }
            apiContext.textInsertionService.selectedTextOverride = { nil }
            apiContext.textInsertionService.pasteSimulatorOverride = {}
        }

        let start = try Self.jsonObject(
            await router.route(HTTPRequest(method: "POST", path: "/v1/dictation/start", queryParams: [:], headers: [:], body: Data()))
        )
        let startID = try XCTUnwrap(start["id"] as? String)
        XCTAssertEqual(start["status"] as? String, "recording")
        XCTAssertNotNil(UUID(uuidString: startID))

        await MainActor.run {
            apiContext.dictationViewModel.partialText = "transcribed"
        }

        let stop = try Self.jsonObject(
            await router.route(HTTPRequest(method: "POST", path: "/v1/dictation/stop", queryParams: [:], headers: [:], body: Data()))
        )
        XCTAssertEqual(stop["id"] as? String, startID)
        XCTAssertEqual(stop["status"] as? String, "stopped")

        var completedResponse: [String: Any]?
        for _ in 0..<40 {
            let response = try Self.jsonObject(
                await router.route(
                    HTTPRequest(
                        method: "GET",
                        path: "/v1/dictation/transcription",
                        queryParams: ["id": startID],
                        headers: [:],
                        body: Data()
                    )
                )
            )
            if response["status"] as? String == "completed" {
                completedResponse = response
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let completedPayload = try XCTUnwrap(completedResponse)
        XCTAssertEqual(completedPayload["id"] as? String, startID)
        XCTAssertEqual(completedPayload["status"] as? String, "completed")

        let transcription = try XCTUnwrap(completedPayload["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["text"] as? String, "transcribed")
        XCTAssertEqual(transcription["raw_text"] as? String, "transcribed")
        XCTAssertEqual(transcription["app_name"] as? String, "Notes")
        XCTAssertEqual(transcription["app_bundle_id"] as? String, "com.apple.Notes")
        XCTAssertEqual(transcription["words_count"] as? Int, 1)

        let recordID = await MainActor.run { apiContext.historyService.records.first?.id.uuidString }
        XCTAssertEqual(recordID, startID)
    }

    func testDictationEndpointsSpeakCompletedTranscriptionOnly() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let apiContext = try XCTUnwrap(context)
        let router = apiContext.router
        let ttsExpectation = expectation(description: "tts speak called")

        await MainActor.run {
            apiContext.ttsProvider.onSpeak = { request in
                if request.purpose == .transcription {
                    ttsExpectation.fulfill()
                }
            }
            apiContext.dictationViewModel.spokenFeedbackEnabled = true
            apiContext.audioRecordingService.hasMicrophonePermissionOverride = true
            apiContext.audioRecordingService.inputAvailabilityOverride = { _ in true }
            apiContext.audioRecordingService.startRecordingOverride = {}
            apiContext.audioRecordingService.stopRecordingOverride = { _ in
                Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate))
            }
            apiContext.textInsertionService.accessibilityGrantedOverride = true
            apiContext.textInsertionService.captureActiveAppOverride = {
                ("Notes", "com.apple.Notes", nil)
            }
            apiContext.textInsertionService.selectedTextOverride = { nil }
            apiContext.textInsertionService.pasteSimulatorOverride = {}
        }

        let start = try Self.jsonObject(
            await router.route(HTTPRequest(method: "POST", path: "/v1/dictation/start", queryParams: [:], headers: [:], body: Data()))
        )
        let startID = try XCTUnwrap(start["id"] as? String)
        let initialRequestsAreEmpty = await MainActor.run { apiContext.ttsProvider.recordedRequests.isEmpty }
        XCTAssertTrue(initialRequestsAreEmpty)

        await MainActor.run {
            apiContext.dictationViewModel.partialText = "transcribed"
        }

        _ = try Self.jsonObject(
            await router.route(HTTPRequest(method: "POST", path: "/v1/dictation/stop", queryParams: [:], headers: [:], body: Data()))
        )

        var completedResponse: [String: Any]?
        for _ in 0..<40 {
            let response = try Self.jsonObject(
                await router.route(
                    HTTPRequest(
                        method: "GET",
                        path: "/v1/dictation/transcription",
                        queryParams: ["id": startID],
                        headers: [:],
                        body: Data()
                    )
                )
            )
            if response["status"] as? String == "completed" {
                completedResponse = response
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        _ = try XCTUnwrap(completedResponse)
        await fulfillment(of: [ttsExpectation], timeout: 1.0)

        let requests = await MainActor.run { apiContext.ttsProvider.recordedRequests }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.purpose, .transcription)
        XCTAssertEqual(requests.first?.text, "transcribed")
    }

    @MainActor
    func testClipboardSnapshotRoundTripsMultiplePasteboardItems() {
        let firstItem = NSPasteboardItem()
        firstItem.setString("first", forType: .string)
        firstItem.setData(Data([0x01, 0x02]), forType: .png)

        let secondItem = NSPasteboardItem()
        secondItem.setString("second", forType: .string)
        secondItem.setData(Data([0x03, 0x04]), forType: .tiff)

        let snapshot = TextInsertionService.clipboardSnapshot(from: [firstItem, secondItem])
        let restoredItems = TextInsertionService.pasteboardItems(from: snapshot)

        XCTAssertEqual(restoredItems.count, 2)
        XCTAssertEqual(restoredItems[0].string(forType: .string), "first")
        XCTAssertEqual(restoredItems[0].data(forType: .png), Data([0x01, 0x02]))
        XCTAssertEqual(restoredItems[1].string(forType: .string), "second")
        XCTAssertEqual(restoredItems[1].data(forType: .tiff), Data([0x03, 0x04]))
    }

    @MainActor
    func testFocusedTextChangeDetectionRequiresAnActualChange() {
        XCTAssertFalse(
            TextInsertionService.focusedTextDidChange(
                from: (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0)),
                to: (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
            )
        )

        XCTAssertTrue(
            TextInsertionService.focusedTextDidChange(
                from: (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0)),
                to: (value: "Hello world", selectedText: nil, selectedRange: NSRange(location: 11, length: 0))
            )
        )
    }

    @MainActor
    func testAutoEnterSkipsReturnWithoutFocusedTextField() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextFieldOverride = { false }

        var didSimulatePaste = false
        service.pasteSimulatorOverride = {
            didSimulatePaste = true
        }

        var didSimulateReturn = false
        service.returnSimulatorOverride = {
            didSimulateReturn = true
        }

        _ = try await service.insertText("Hello", autoEnter: true)

        XCTAssertTrue(didSimulatePaste)
        XCTAssertFalse(didSimulateReturn)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")
    }

    @MainActor
    func testAutoEnterTriggersReturnWithFocusedTextField() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextFieldOverride = { true }
        service.pasteSimulatorOverride = {}

        var didSimulateReturn = false
        service.returnSimulatorOverride = {
            didSimulateReturn = true
        }

        _ = try await service.insertText("Hello", autoEnter: true)

        XCTAssertTrue(didSimulateReturn)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")
    }

    @MainActor
    func testPreserveClipboardAvoidsPasteboardWhenVerifiedAccessibilityInsertionSucceeds() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }

        var stateReadCount = 0
        service.focusedTextStateOverride = { _ in
            defer { stateReadCount += 1 }
            if stateReadCount == 0 {
                return (value: "", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
            }
            return (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }

        var insertedText: String?
        service.insertTextAtOverride = { _, text in
            insertedText = text
            return true
        }

        var didSimulatePaste = false
        service.pasteSimulatorOverride = {
            didSimulatePaste = true
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        _ = try await service.insertText("Hello", preserveClipboard: true)

        XCTAssertEqual(insertedText, "Hello")
        XCTAssertFalse(didSimulatePaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testPreserveClipboardFallsBackToPasteboardWhenVerifiedAccessibilityInsertionFails() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }
        service.focusedTextStateOverride = { _ in
            (value: "", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
        }
        service.insertTextAtOverride = { _, _ in true }

        var didSimulatePaste = false
        service.pasteSimulatorOverride = {
            didSimulatePaste = true
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        _ = try await service.insertText("Hello", preserveClipboard: true)

        XCTAssertTrue(didSimulatePaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testApiStartRecording_startsAudioBeforeDeferredSelectedTextCapture() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)

        var events: [String] = []
        let selectedTextCaptured = expectation(description: "selected text captured")

        context.textInsertionService.captureActiveAppOverride = { () -> (name: String?, bundleId: String?, url: String?) in
            events.append("capture_app")
            return ("Notes", nil, nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {
            events.append("start_audio")
        }
        context.textInsertionService.selectedTextOverride = { () -> String? in
            events.append("selected_text")
            selectedTextCaptured.fulfill()
            return "Already selected"
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, DictationViewModel.State.recording)
        XCTAssertEqual(events, ["capture_app", "start_audio"])

        await fulfillment(of: [selectedTextCaptured], timeout: 1.0)
        XCTAssertEqual(Array(events.prefix(3)), ["capture_app", "start_audio", "selected_text"])
    }

    @MainActor
    func testPushToTalkInterruptionDiscardStopsImmediatelyAndMarksSessionFailedByDefault() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        XCTAssertTrue(context.hotkeyService.discardPushToTalkRecordingOnExtraKeyPress)

        var stopPolicies: [String] = []
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.audioRecordingService.stopRecordingOverride = { policy in
            stopPolicies.append(policy.logDescription)
            return []
        }

        let sessionID = context.dictationViewModel.apiStartRecording()
        XCTAssertEqual(context.dictationViewModel.state, .recording)

        context.hotkeyService.onPushToTalkInterruption?()
        _ = context.dictationViewModel.apiStopRecording()

        for _ in 0..<20 {
            if context.dictationViewModel.apiDictationSession(id: sessionID)?.status == .failed {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(stopPolicies, [AudioRecordingService.StopPolicy.immediate.logDescription])
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            "Recording discarded because additional keys were pressed"
        )
        XCTAssertEqual(context.dictationViewModel.apiDictationSession(id: sessionID)?.status, .failed)
        XCTAssertEqual(
            context.dictationViewModel.apiDictationSession(id: sessionID)?.error,
            "Recording discarded because additional keys were pressed"
        )
    }

    @MainActor
    func testApiStartRecording_appliesBundleProfileBeforeDeferredMetadataCapture() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.profileService.addProfile(name: "Docs", bundleIdentifiers: ["com.typewhisper.tests"])

        let selectedTextCaptured = expectation(description: "selected text captured")
        context.textInsertionService.captureActiveAppOverride = { () -> (name: String?, bundleId: String?, url: String?) in
            ("Docs App", "com.typewhisper.tests", nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.textInsertionService.selectedTextOverride = { () -> String? in
            selectedTextCaptured.fulfill()
            return nil
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, DictationViewModel.State.recording)
        XCTAssertEqual(context.dictationViewModel.activeRuleName, "Docs")

        await fulfillment(of: [selectedTextCaptured], timeout: 1.0)
    }

    @MainActor
    func testApiStartRecording_pausesMediaAfterAudioStart() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var events: [String] = []
        let mediaPlaybackService = MockMediaPlaybackService {
            events.append("pause_media")
        }
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            mediaPlaybackService: mediaPlaybackService
        )
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.mediaPauseEnabled = true

        context.textInsertionService.captureActiveAppOverride = { () -> (name: String?, bundleId: String?, url: String?) in
            events.append("capture_app")
            return ("Music", "com.apple.Music", nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {
            events.append("start_audio")
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(Array(events.prefix(3)), ["capture_app", "start_audio", "pause_media"])
    }

    #if !APPSTORE
    @MainActor
    func testMediaPlaybackServicePausesAndResumesFromOneShotTrackInfo() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.returnedSnapshot = (true, "com.apple.Music")
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()

        XCTAssertEqual(controller.pauseCalls, 1)
        XCTAssertEqual(controller.playCalls, 0)
        XCTAssertEqual(scheduler.scheduledDelays, [0.6])

        scheduler.runPendingActions()

        XCTAssertEqual(controller.playCalls, 1)
    }

    @MainActor
    func testMediaPlaybackServiceSkipsPauseWhenPlaybackIsAlreadyStopped() {
        let controller = FakeMediaPlaybackController()
        controller.returnedSnapshot = (false, nil)
        let service = MediaPlaybackService(startListening: false) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)
    }

    @MainActor
    func testMediaPlaybackServiceIgnoresStalePauseProbeAfterResume() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        var deferredCallback: ((_ isPlaying: Bool, _ bundleIdentifier: String?) -> Void)?
        controller.onGetPlaybackSnapshot = { callback in
            deferredCallback = callback
        }
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()
        deferredCallback?(true, "com.apple.Music")

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)

        scheduler.runPendingActions()

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)
    }

    @MainActor
    func testMediaPlaybackServiceCancelsPendingResumeWhenRecordingRestartsBeforeDelayElapses() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.returnedSnapshot = (true, "com.apple.Music")
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()
        service.pauseIfPlaying()

        scheduler.runPendingActions()

        XCTAssertEqual(controller.pauseCalls, 1)
        XCTAssertEqual(controller.playCalls, 0)

        service.resumeIfWePaused()
        scheduler.runPendingActions()

        XCTAssertEqual(controller.playCalls, 1)
    }

    @MainActor
    func testMediaPlaybackServiceCoalescesDuplicateResumeRequestsIntoSinglePlay() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.returnedSnapshot = (true, "com.apple.Music")
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()
        service.resumeIfWePaused()

        scheduler.runPendingActions()

        XCTAssertEqual(controller.pauseCalls, 1)
        XCTAssertEqual(controller.playCalls, 1)
    }
    #endif

    @MainActor
    func testApiStartRecording_showsSelectModelErrorWhenNoProviderIsSelected() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let modelManager = ModelManagerService()
        let audioRecordingService = AudioRecordingService()
        let hotkeyService = HotkeyService()
        let textInsertionService = TextInsertionService()
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let recentTranscriptionStore = RecentTranscriptionStore()
        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        let audioDuckingService = AudioDuckingService()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        let soundService = SoundService()
        let audioDeviceService = AudioDeviceService()
        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let promptProcessingService = PromptProcessingService()
        let appFormatterService = AppFormatterService()
        let speechFeedbackService = SpeechFeedbackService()
        let accessibilityAnnouncementService = AccessibilityAnnouncementService()
        let errorLogService = ErrorLogService(appSupportDirectory: appSupportDirectory)
        let settingsViewModel = SettingsViewModel(modelManager: modelManager)

        let dictationViewModel = DictationViewModel(
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            hotkeyService: hotkeyService,
            modelManager: modelManager,
            settingsViewModel: settingsViewModel,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: profileService,
            workflowService: workflowService,
            translationService: nil,
            audioDuckingService: audioDuckingService,
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            soundService: soundService,
            audioDeviceService: audioDeviceService,
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            appFormatterService: appFormatterService,
            speechFeedbackService: speechFeedbackService,
            accessibilityAnnouncementService: accessibilityAnnouncementService,
            errorLogService: errorLogService,
            mediaPlaybackService: MediaPlaybackService(startListening: false)
        )
        dictationViewModel.soundFeedbackEnabled = false
        dictationViewModel.spokenFeedbackEnabled = false

        _ = dictationViewModel.apiStartRecording()

        XCTAssertEqual(dictationViewModel.state, .inserting)
        XCTAssertEqual(
            dictationViewModel.actionFeedbackMessage,
            TranscriptionEngineError.modelNotLoaded.localizedDescription
        )
    }

    @MainActor
    func testApiStartRecording_showsNoMicDetectedErrorWhenNoInputAvailable() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in false }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "No mic detected.")
        )
        XCTAssertTrue(context.ttsProvider.recordedRequests.isEmpty)
    }

    @MainActor
    func testApiStartRecording_preservesPermissionDeniedError() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.audioRecordingService.hasMicrophonePermissionOverride = false

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            "Microphone permission required."
        )
        XCTAssertTrue(context.ttsProvider.recordedRequests.isEmpty)
    }

    @MainActor
    func testApiStartRecording_doesNotSpeakStatusFeedback() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.spokenFeedbackEnabled = true
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.textInsertionService.captureActiveAppOverride = { ("Notes", nil, nil) }
        context.textInsertionService.selectedTextOverride = { nil }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .recording)
        XCTAssertTrue(context.ttsProvider.recordedRequests.isEmpty)
    }

    @MainActor
    func testApiStartRecordingError_doesNotSpeakStatusFeedback() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.spokenFeedbackEnabled = true
        context.audioRecordingService.hasMicrophonePermissionOverride = false

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertTrue(context.ttsProvider.recordedRequests.isEmpty)
    }

    @MainActor
    func testModelManagerAutoSelectsConfiguredEngineAfterPluginCapabilityChange() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = ConfigurableTranscriptionPlugin()
        let manifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.observePluginManager()
        XCTAssertNil(modelManager.selectedProviderId)

        plugin.currentModelId = "tiny"
        plugin.configured = true
        PluginManager.shared.notifyPluginStateChanged()

        let propagation = expectation(description: "plugin capability propagation")
        DispatchQueue.main.async {
            propagation.fulfill()
        }
        await fulfillment(of: [propagation], timeout: 1.0)

        XCTAssertEqual(modelManager.selectedProviderId, plugin.providerId)
    }

    @MainActor
    func testTranslationTargetLanguagesKeepScriptVariantsDistinct() {
        guard #available(macOS 15.0, *) else { return }

        let namesByCode = Dictionary(uniqueKeysWithValues: TranslationService.availableTargetLanguages.map { ($0.code, $0.name) })

        XCTAssertNotEqual(namesByCode["zh-Hans"], namesByCode["zh-Hant"])
    }

    func testLocalizedAppLanguageNameKeepsScriptVariantsDistinct() {
        XCTAssertNotEqual(localizedAppLanguageName(for: "zh-Hans"), localizedAppLanguageName(for: "zh-Hant"))
    }

    func testLocalizedAppLanguageFlagUsesDefaultsAndRegionOverrides() {
        XCTAssertEqual(localizedAppLanguageFlag(for: "en"), "🇺🇸")
        XCTAssertEqual(localizedAppLanguageFlag(for: "en-GB"), "🇬🇧")
        XCTAssertEqual(localizedAppLanguageFlag(for: "en-US"), "🇺🇸")
        XCTAssertEqual(localizedAppLanguageFlag(for: "zh"), "🇨🇳")
        XCTAssertNil(localizedAppLanguageFlag(for: "zh-Hans"))
    }

    func testFeaturedAppLanguageRankPromotesCommonLanguages() {
        XCTAssertEqual(featuredAppLanguageRank(for: "de"), 0)
        XCTAssertEqual(featuredAppLanguageRank(for: "en"), 1)
        XCTAssertEqual(featuredAppLanguageRank(for: "fr"), 2)
        XCTAssertEqual(featuredAppLanguageRank(for: "es"), 3)
        XCTAssertEqual(featuredAppLanguageRank(for: "zh-Hans"), 4)
        XCTAssertNil(featuredAppLanguageRank(for: "cs"))
    }

    func testLanguageSelectionCodecSupportsLegacyAndHintValues() {
        XCTAssertEqual(LanguageSelection(storedValue: nil, nilBehavior: .auto), .auto)
        XCTAssertEqual(LanguageSelection(storedValue: nil, nilBehavior: .inheritGlobal), .inheritGlobal)
        XCTAssertEqual(LanguageSelection(storedValue: "auto", nilBehavior: .auto), .auto)
        XCTAssertEqual(LanguageSelection(storedValue: "de", nilBehavior: .auto), .exact("de"))
        XCTAssertEqual(
            LanguageSelection(storedValue: #"["de","en"]"#, nilBehavior: .auto),
            .hints(["de", "en"])
        )
    }

    func testProfileLanguageSelectionPersistsHintListsWithoutSchemaChanges() {
        let profile = Profile(name: "Hints")
        profile.inputLanguageSelection = .hints(["de", "en"])

        XCTAssertEqual(profile.inputLanguage, #"["de","en"]"#)
        XCTAssertEqual(profile.inputLanguageSelection, .hints(["de", "en"]))
    }

    func testLanguageSelectionNormalizesAgainstSupportedLanguages() {
        XCTAssertEqual(
            LanguageSelection.hints(["de", "en", "nl"]).normalizedForSupportedLanguages(["de", "nl"]),
            .hints(["de", "nl"])
        )
        XCTAssertEqual(
            LanguageSelection.hints(["de", "en"]).normalizedForSupportedLanguages(["de"]),
            .exact("de")
        )
        XCTAssertEqual(
            LanguageSelection.hints(["de", "en"]).normalizedForSupportedLanguages(["fr"]),
            .auto
        )
    }

    @MainActor
    func testSettingsViewModelAvailableLanguagesKeepsRegionalAndScriptVariantsDistinct() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockTranscriptionPlugin()
        plugin.languages = ["zh-Hans", "zh-Hant", "pt-BR", "pt-PT"]
        let manifest = PluginManifest(
            id: "com.typewhisper.mock.transcription",
            name: "Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterMockTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let settingsViewModel = SettingsViewModel(modelManager: ModelManagerService())
        let namesByCode = Dictionary(uniqueKeysWithValues: settingsViewModel.availableLanguages.map { ($0.code, $0.name) })

        XCTAssertNotEqual(namesByCode["zh-Hans"], namesByCode["zh-Hant"])
        XCTAssertNotEqual(namesByCode["pt-BR"], namesByCode["pt-PT"])
    }

    @MainActor
    private static func makeAPIContext(appSupportDirectory: URL, withMockTranscriptionPlugin: Bool = false) -> APIContext {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        let ttsProvider = MockTTSProviderPlugin()
        let ttsManifest = PluginManifest(
            id: "com.typewhisper.mock.tts",
            name: "Mock TTS",
            version: "1.0.0",
            principalClass: "APIRouterMockTTSPlugin",
            category: "tts"
        )

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: ttsManifest,
                instance: ttsProvider,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        if withMockTranscriptionPlugin {
            let mockPlugin = MockTranscriptionPlugin()
            let manifest = PluginManifest(
                id: "com.typewhisper.mock.transcription",
                name: "Mock Transcription",
                version: "1.0.0",
                principalClass: "APIRouterMockTranscriptionPlugin"
            )
            PluginManager.shared.loadedPlugins.append(
                LoadedPlugin(
                    manifest: manifest,
                    instance: mockPlugin,
                    bundle: Bundle.main,
                    sourceURL: appSupportDirectory,
                    isEnabled: true
                )
            )
            modelManager.selectProvider(mockPlugin.providerId)
        }
        let audioFileService = AudioFileService()
        let audioRecordingService = AudioRecordingService()
        let hotkeyService = HotkeyService()
        let textInsertionService = TextInsertionService()
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let recentTranscriptionStore = RecentTranscriptionStore()
        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        let audioDuckingService = AudioDuckingService()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        let soundService = SoundService()
        let audioDeviceService = AudioDeviceService()
        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let promptProcessingService = PromptProcessingService()
        let appFormatterService = AppFormatterService()
        let speechFeedbackService = SpeechFeedbackService()
        let accessibilityAnnouncementService = AccessibilityAnnouncementService()
        let errorLogService = ErrorLogService(appSupportDirectory: appSupportDirectory)
        let settingsViewModel = SettingsViewModel(modelManager: modelManager)

        let dictationViewModel = DictationViewModel(
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            hotkeyService: hotkeyService,
            modelManager: modelManager,
            settingsViewModel: settingsViewModel,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: profileService,
            workflowService: workflowService,
            translationService: nil,
            audioDuckingService: audioDuckingService,
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            soundService: soundService,
            audioDeviceService: audioDeviceService,
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            appFormatterService: appFormatterService,
            speechFeedbackService: speechFeedbackService,
            accessibilityAnnouncementService: accessibilityAnnouncementService,
            errorLogService: errorLogService,
            mediaPlaybackService: MediaPlaybackService(startListening: false)
        )

        let router = APIRouter()
        let handlers = APIHandlers(
            modelManager: modelManager,
            audioFileService: audioFileService,
            translationService: nil,
            historyService: historyService,
            profileService: profileService,
            dictionaryService: dictionaryService,
            dictationViewModel: dictationViewModel
        )
        handlers.register(on: router)

        return APIContext(
            router: router,
            modelManager: modelManager,
            historyService: historyService,
            profileService: profileService,
            dictionaryService: dictionaryService,
            dictationViewModel: dictationViewModel,
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            ttsProvider: ttsProvider,
            retainedObjects: [
                PluginManager.shared,
                ttsProvider,
                modelManager,
                audioFileService,
                audioRecordingService,
                hotkeyService,
                textInsertionService,
                historyService,
                profileService,
                audioDuckingService,
                dictionaryService,
                snippetService,
                soundService,
                audioDeviceService,
                promptActionService,
                promptProcessingService,
                appFormatterService,
                speechFeedbackService,
                accessibilityAnnouncementService,
                errorLogService,
                settingsViewModel,
                dictationViewModel,
                router,
                handlers
            ]
        )
    }

    private static func makeLongTerms(count: Int, length: Int) -> [String] {
        (1...count).map { index in
            let prefix = "Term\(index)-"
            let paddingLength = max(0, length - prefix.count)
            return prefix + String(repeating: "x", count: paddingLength)
        }
    }

    @MainActor
    func testCopyLastTranscriptionToClipboardUsesNewestSessionEntry() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        let pasteboard = NSPasteboard.withUniqueName()
        context.dictationViewModel.pasteboardProvider = { pasteboard }

        context.recentTranscriptionStore.recordTranscription(
            id: UUID(),
            finalText: "Newest session text",
            timestamp: Date(),
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes"
        )

        context.dictationViewModel.copyLastTranscriptionToClipboard()

        XCTAssertEqual(pasteboard.string(forType: .string), "Newest session text")
    }

    @MainActor
    func testCopyLastTranscriptionToClipboardFallsBackToHistory() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        let pasteboard = NSPasteboard.withUniqueName()
        context.dictationViewModel.pasteboardProvider = { pasteboard }

        context.historyService.addRecord(
            id: UUID(),
            rawText: "raw history text",
            finalText: "History fallback text",
            appName: "Safari",
            appBundleIdentifier: "com.apple.Safari",
            durationSeconds: 1,
            language: "en",
            engineUsed: "mock"
        )

        context.dictationViewModel.copyLastTranscriptionToClipboard()

        XCTAssertEqual(pasteboard.string(forType: .string), "History fallback text")
    }

    @MainActor
    func testCopyLastTranscriptionToClipboardIsNoOpWithoutEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)
        context.dictationViewModel.pasteboardProvider = { pasteboard }

        context.dictationViewModel.copyLastTranscriptionToClipboard()

        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    private final class DictationContext: @unchecked Sendable {
        let dictationViewModel: DictationViewModel
        let audioRecordingService: AudioRecordingService
        let hotkeyService: HotkeyService
        let audioDeviceService: AudioDeviceService
        let audioDuckingService: AudioDuckingService
        let textInsertionService: TextInsertionService
        let historyService: HistoryService
        let recentTranscriptionStore: RecentTranscriptionStore
        let profileService: ProfileService
        let ttsProvider: MockTTSProviderPlugin
        private let retainedObjects: [AnyObject]

        init(
            dictationViewModel: DictationViewModel,
            audioRecordingService: AudioRecordingService,
            hotkeyService: HotkeyService,
            audioDeviceService: AudioDeviceService,
            audioDuckingService: AudioDuckingService,
            textInsertionService: TextInsertionService,
            historyService: HistoryService,
            recentTranscriptionStore: RecentTranscriptionStore,
            profileService: ProfileService,
            ttsProvider: MockTTSProviderPlugin,
            retainedObjects: [AnyObject]
        ) {
            self.dictationViewModel = dictationViewModel
            self.audioRecordingService = audioRecordingService
            self.hotkeyService = hotkeyService
            self.audioDeviceService = audioDeviceService
            self.audioDuckingService = audioDuckingService
            self.textInsertionService = textInsertionService
            self.historyService = historyService
            self.recentTranscriptionStore = recentTranscriptionStore
            self.profileService = profileService
            self.ttsProvider = ttsProvider
            self.retainedObjects = retainedObjects
        }
    }

    @MainActor
    private static func makeDictationContext(
        appSupportDirectory: URL,
        audioDuckingService: AudioDuckingService? = nil,
        mediaPlaybackService: MediaPlaybackService? = nil
    ) -> DictationContext {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let mockPlugin = MockTranscriptionPlugin()
        let ttsProvider = MockTTSProviderPlugin()
        let manifest = PluginManifest(
            id: "com.typewhisper.mock.transcription",
            name: "Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterMockTranscriptionPlugin"
        )
        let ttsManifest = PluginManifest(
            id: "com.typewhisper.mock.tts",
            name: "Mock TTS",
            version: "1.0.0",
            principalClass: "APIRouterMockTTSPlugin",
            category: "tts"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: ttsManifest,
                instance: ttsProvider,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
            LoadedPlugin(
                manifest: manifest,
                instance: mockPlugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(mockPlugin.providerId)

        let audioRecordingService = AudioRecordingService()
        let hotkeyService = HotkeyService()
        let textInsertionService = TextInsertionService()
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let recentTranscriptionStore = RecentTranscriptionStore()
        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        let audioDuckingService = audioDuckingService ?? AudioDuckingService()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        let soundService = SoundService()
        let audioDeviceService = AudioDeviceService()
        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let promptProcessingService = PromptProcessingService()
        let appFormatterService = AppFormatterService()
        let speechFeedbackService = SpeechFeedbackService()
        let accessibilityAnnouncementService = AccessibilityAnnouncementService()
        let errorLogService = ErrorLogService(appSupportDirectory: appSupportDirectory)
        let settingsViewModel = SettingsViewModel(modelManager: modelManager)
        let mediaPlaybackService = mediaPlaybackService ?? MediaPlaybackService(startListening: false)

        let dictationViewModel = DictationViewModel(
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            hotkeyService: hotkeyService,
            modelManager: modelManager,
            settingsViewModel: settingsViewModel,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: profileService,
            workflowService: workflowService,
            translationService: nil,
            audioDuckingService: audioDuckingService,
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            soundService: soundService,
            audioDeviceService: audioDeviceService,
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            appFormatterService: appFormatterService,
            speechFeedbackService: speechFeedbackService,
            accessibilityAnnouncementService: accessibilityAnnouncementService,
            errorLogService: errorLogService,
            mediaPlaybackService: mediaPlaybackService
        )
        dictationViewModel.soundFeedbackEnabled = false
        dictationViewModel.spokenFeedbackEnabled = false
        dictationViewModel.audioDuckingEnabled = false
        dictationViewModel.mediaPauseEnabled = false

        return DictationContext(
            dictationViewModel: dictationViewModel,
            audioRecordingService: audioRecordingService,
            hotkeyService: hotkeyService,
            audioDeviceService: audioDeviceService,
            audioDuckingService: audioDuckingService,
            textInsertionService: textInsertionService,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: profileService,
            ttsProvider: ttsProvider,
            retainedObjects: [
                EventBus.shared,
                PluginManager.shared,
                modelManager,
                audioRecordingService,
                hotkeyService,
                textInsertionService,
                historyService,
                recentTranscriptionStore,
                profileService,
                audioDuckingService,
                dictionaryService,
                snippetService,
                soundService,
                audioDeviceService,
                promptActionService,
                promptProcessingService,
                appFormatterService,
                speechFeedbackService,
                ttsProvider,
                accessibilityAnnouncementService,
                errorLogService,
                settingsViewModel,
                mediaPlaybackService,
                dictationViewModel
            ]
        )
    }

    private static func jsonObject(_ response: HTTPResponse) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: response.body)
        return try XCTUnwrap(object as? [String: Any])
    }

    @MainActor
    func testPromptProcessingRepairsInvalidGlobalCloudModelBeforeRequest() async throws {
        let providerKey = "llmProviderType"
        let modelKey = "llmCloudModel"
        let originalProvider = UserDefaults.standard.object(forKey: providerKey)
        let originalModel = UserDefaults.standard.object(forKey: modelKey)
        defer {
            if let originalProvider {
                UserDefaults.standard.set(originalProvider, forKey: providerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: providerKey)
            }
            if let originalModel {
                UserDefaults.standard.set(originalModel, forKey: modelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: modelKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        UserDefaults.standard.set("Gemini", forKey: providerKey)
        UserDefaults.standard.set("legacy-direct-model", forKey: modelKey)

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.models = [
            PluginModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
            PluginModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro")
        ]

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.llm",
            name: "Mock LLM",
            version: "1.0.0",
            principalClass: "APIRouterMockLLMProviderPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let service = PromptProcessingService()
        let result = try await service.process(prompt: "Fix grammar", text: "hello world")

        XCTAssertEqual(result, "processed")
        XCTAssertEqual(plugin.lastRequestedModel, "gemini-2.5-flash")
        XCTAssertEqual(service.selectedCloudModel, "gemini-2.5-flash")
        XCTAssertEqual(UserDefaults.standard.string(forKey: modelKey), "gemini-2.5-flash")
    }

    @MainActor
    func testPromptProcessingIgnoresInvalidPromptOverrideWithoutPersistingIt() async throws {
        let providerKey = "llmProviderType"
        let modelKey = "llmCloudModel"
        let originalProvider = UserDefaults.standard.object(forKey: providerKey)
        let originalModel = UserDefaults.standard.object(forKey: modelKey)
        defer {
            if let originalProvider {
                UserDefaults.standard.set(originalProvider, forKey: providerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: providerKey)
            }
            if let originalModel {
                UserDefaults.standard.set(originalModel, forKey: modelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: modelKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        UserDefaults.standard.set("Gemini", forKey: providerKey)
        UserDefaults.standard.set("gemini-2.5-pro", forKey: modelKey)

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.models = [
            PluginModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
            PluginModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro")
        ]

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.llm",
            name: "Mock LLM",
            version: "1.0.0",
            principalClass: "APIRouterMockLLMProviderPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let service = PromptProcessingService()
        let result = try await service.process(
            prompt: "Fix grammar",
            text: "hello world",
            cloudModelOverride: "legacy-direct-model"
        )

        XCTAssertEqual(result, "processed")
        XCTAssertEqual(plugin.lastRequestedModel, "gemini-2.5-pro")
        XCTAssertEqual(service.selectedCloudModel, "gemini-2.5-pro")
        XCTAssertEqual(UserDefaults.standard.string(forKey: modelKey), "gemini-2.5-pro")
    }

    @MainActor
    func testPromptProcessingPassesTemperatureDirectiveToTemperatureAwareProvider() async throws {
        let providerKey = "llmProviderType"
        let modelKey = "llmCloudModel"
        let originalProvider = UserDefaults.standard.object(forKey: providerKey)
        let originalModel = UserDefaults.standard.object(forKey: modelKey)
        defer {
            if let originalProvider {
                UserDefaults.standard.set(originalProvider, forKey: providerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: providerKey)
            }
            if let originalModel {
                UserDefaults.standard.set(originalModel, forKey: modelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: modelKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        UserDefaults.standard.set("Gemini", forKey: providerKey)
        UserDefaults.standard.set("gemini-2.5-pro", forKey: modelKey)

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.models = [PluginModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro")]

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.llm",
            name: "Mock LLM",
            version: "1.0.0",
            principalClass: "APIRouterMockLLMProviderPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let service = PromptProcessingService()
        _ = try await service.process(
            prompt: "Fix grammar",
            text: "hello world",
            temperatureDirective: .custom(0.8)
        )

        XCTAssertEqual(plugin.lastRequestedModel, "gemini-2.5-pro")
        XCTAssertEqual(plugin.lastTemperatureDirective, .custom(0.8))
    }

    @MainActor
    func testPromptProcessingReturnsSetupRequiredForLocalProviderWithoutLoadedModel() async throws {
        let providerKey = "llmProviderType"
        let modelKey = "llmCloudModel"
        let originalProvider = UserDefaults.standard.object(forKey: providerKey)
        let originalModel = UserDefaults.standard.object(forKey: modelKey)
        defer {
            if let originalProvider {
                UserDefaults.standard.set(originalProvider, forKey: providerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: providerKey)
            }
            if let originalModel {
                UserDefaults.standard.set(originalModel, forKey: modelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: modelKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        UserDefaults.standard.set("Gemma 4 (MLX)", forKey: providerKey)
        UserDefaults.standard.removeObject(forKey: modelKey)

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.available = false
        plugin.configuredProviderName = "Gemma 4 (MLX)"
        plugin.requiresExternalCredentials = false
        plugin.unavailableReason = "Load a Gemma 4 model in Integrations before using it for prompts."

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.local-llm",
            name: "Mock Local LLM",
            version: "1.0.0",
            principalClass: "APIRouterMockLLMProviderPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let service = PromptProcessingService()

        do {
            _ = try await service.process(prompt: "Fix grammar", text: "hello world")
            XCTFail("Expected local provider setup error")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Load a Gemma 4 model in Integrations before using it for prompts."
            )
        }
    }

    @MainActor
    func testPromptProcessingRequiresForegroundActivationOnlyForLocalProviders() {
        let remotePlugin = MockLLMProviderPlugin()
        remotePlugin.requiresExternalCredentials = true

        let localPlugin = MockLLMProviderPlugin()
        localPlugin.requiresExternalCredentials = false

        let legacyPlugin = MockLegacyLLMProviderPlugin()

        XCTAssertFalse(PromptProcessingService.requiresForegroundActivation(for: remotePlugin))
        XCTAssertTrue(PromptProcessingService.requiresForegroundActivation(for: localPlugin))
        XCTAssertFalse(PromptProcessingService.requiresForegroundActivation(for: legacyPlugin))
    }

    @MainActor
    func testGeminiPluginCompatibleModelDecodingNormalizesIdsAndFiltersToChatModels() throws {
        let response = Data(
            """
            {
              "object": "list",
              "data": [
                { "id": "models/gemini-2.5-pro", "object": "model", "display_name": "Gemini 2.5 Pro" },
                { "id": "models/gemini-3-flash-preview", "object": "model", "display_name": "Gemini 3 Flash Preview" },
                { "id": "models/gemini-2.5-flash-image", "object": "model", "display_name": "Nano Banana" },
                { "id": "models/gemini-embedding-2-preview", "object": "model", "display_name": "Gemini Embedding 2 Preview" },
                { "id": "models/gemini-2.5-flash-native-audio-latest", "object": "model", "display_name": "Gemini 2.5 Flash Native Audio Latest" },
                { "id": "models/gemma-4-31b-it", "object": "model", "display_name": "Gemma 4 31B IT" }
              ]
            }
            """.utf8
        )

        let models = try GeminiPlugin.decodeCompatibleLLMModels(from: response)

        XCTAssertEqual(models.map(\.id), ["gemini-2.5-pro", "gemini-3-flash-preview"])
        XCTAssertEqual(models.first?.displayName, "Gemini 2.5 Pro")
        XCTAssertEqual(models.last?.displayName, "Gemini 3 Flash Preview")
    }

    @MainActor
    func testGeminiPluginActivationIgnoresLegacyCacheAndRepairsInvalidSelection() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let legacyCache = try JSONEncoder().encode([
            GeminiFetchedModel(id: "gemini-1.5-pro", displayName: "Gemini 1.5 Pro")
        ])
        let host = MockHostServices(
            pluginDataDirectory: appSupportDirectory,
            defaults: [
                "fetchedLLMModels": legacyCache,
                "selectedLLMModel": "gemini-1.5-pro"
            ]
        )
        let plugin = GeminiPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.supportedModels.map(\.id), ["gemini-flash-latest", "gemini-pro-latest", "gemini-flash-lite-latest"])
        XCTAssertEqual(plugin.selectedLLMModelId, "gemini-flash-latest")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "gemini-flash-latest")
    }

    @MainActor
    func testCloudModelOverrideDoesNotPersistPluginDefault() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = ConfigurableTranscriptionPlugin()
        plugin.currentModelId = "alpha"
        plugin.configured = true

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        XCTAssertEqual(plugin.selectedModelId, "alpha")

        _ = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 16_000),
            language: nil,
            task: .transcribe,
            engineOverrideId: nil,
            cloudModelOverride: "beta",
            prompt: nil
        )

        XCTAssertEqual(plugin.selectedModelId, "alpha", "cloudModelOverride must not persist the plugin's default model")
    }

    @MainActor
    func testTranscribeRejectsUnknownEngineOverride() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        MockTranscriptionPlugin.reset()
        let context = Self.makeAPIContext(
            appSupportDirectory: appSupportDirectory,
            withMockTranscriptionPlugin: true
        )

        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"engine\"\r\n\r\n".data(using: .utf8)!)
        body.append("nonexistent-engine\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = await context.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        )

        XCTAssertEqual(response.status, 400)
        let json = try Self.jsonObject(response)
        let message = (json["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("Unknown engine"), "Expected 'Unknown engine' in message, got: \(message)")
    }

    @MainActor
    func testTranscribeRejectsUnknownModelOverride() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        MockTranscriptionPlugin.reset()
        let context = Self.makeAPIContext(
            appSupportDirectory: appSupportDirectory,
            withMockTranscriptionPlugin: true
        )

        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("definitely-not-a-real-model\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = await context.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        )

        XCTAssertEqual(response.status, 400)
        let json = try Self.jsonObject(response)
        let message = (json["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("Unknown model"), "Expected 'Unknown model' in message, got: \(message)")
    }

    @MainActor
    func testTranscribeRejectsAmbiguousModelOverride() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        MockTranscriptionPlugin.reset()
        let context = Self.makeAPIContext(
            appSupportDirectory: appSupportDirectory,
            withMockTranscriptionPlugin: true
        )

        // Add a second plugin that advertises the same model id "tiny", making it ambiguous.
        let configurable = ConfigurableTranscriptionPlugin()
        configurable.currentModelId = "tiny"
        configurable.configured = true
        let configurableManifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins.append(
            LoadedPlugin(
                manifest: configurableManifest,
                instance: configurable,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        )

        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("tiny\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = await context.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        )

        XCTAssertEqual(response.status, 400)
        let json = try Self.jsonObject(response)
        let message = (json["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("Ambiguous"), "Expected 'Ambiguous' in message, got: \(message)")
    }

    @MainActor
    func testTranscribeRejectsUnconfiguredEngineOverrideWithConflict() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        MockTranscriptionPlugin.reset()
        let context = Self.makeAPIContext(
            appSupportDirectory: appSupportDirectory,
            withMockTranscriptionPlugin: true
        )

        let configurable = ConfigurableTranscriptionPlugin()
        configurable.configured = false
        let configurableManifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins.append(
            LoadedPlugin(
                manifest: configurableManifest,
                instance: configurable,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        )

        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"engine\"\r\n\r\n".data(using: .utf8)!)
        body.append("configurable-mock\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = await context.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        )

        XCTAssertEqual(response.status, 409)
        let json = try Self.jsonObject(response)
        let message = (json["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("not configured"), "Expected 'not configured' in message, got: \(message)")
    }

    @MainActor
    func testModelsEndpointUsesExpandedCatalogOnlyForCatalogProvidingPlugins() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let context = Self.makeAPIContext(
            appSupportDirectory: appSupportDirectory,
            withMockTranscriptionPlugin: false
        )
        let legacyPlugin = MockTranscriptionPlugin()
        let catalogPlugin = CatalogTranscriptionPlugin()
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.transcription",
                    name: "Mock Transcription",
                    version: "1.0.0",
                    sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
                    principalClass: "APIRouterMockTranscriptionPlugin"
                ),
                instance: legacyPlugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.catalog-transcription",
                    name: "Catalog Mock Transcription",
                    version: "1.0.0",
                    sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
                    principalClass: "APIRouterCatalogTranscriptionPlugin"
                ),
                instance: catalogPlugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let response = await context.router.route(
            HTTPRequest(method: "GET", path: "/v1/models", queryParams: [:], headers: [:], body: Data())
        )
        let json = try Self.jsonObject(response)
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])

        let legacyIds = models
            .filter { ($0["engine"] as? String) == legacyPlugin.providerId }
            .compactMap { $0["id"] as? String }
        let catalogIds = models
            .filter { ($0["engine"] as? String) == catalogPlugin.providerId }
            .compactMap { $0["id"] as? String }

        XCTAssertEqual(legacyIds, ["tiny"])
        XCTAssertEqual(catalogIds.sorted(), ["large", "tiny"])
    }

    @MainActor
    func testTranscribeWithEngineOverrideRoutesToOverrideEngine() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        MockTranscriptionPlugin.reset()
        let context = Self.makeAPIContext(
            appSupportDirectory: appSupportDirectory,
            withMockTranscriptionPlugin: true
        )

        let configurable = ConfigurableTranscriptionPlugin()
        configurable.configured = true
        configurable.currentModelId = "alpha"
        let configurableManifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins.append(
            LoadedPlugin(
                manifest: configurableManifest,
                instance: configurable,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        )

        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"engine\"\r\n\r\n".data(using: .utf8)!)
        body.append("configurable-mock\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = try Self.jsonObject(await context.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        ))

        XCTAssertEqual(response["engine"] as? String, "configurable-mock")
        XCTAssertEqual(response["model"] as? String, "alpha")
        XCTAssertEqual(response["text"] as? String, "transcribed")
    }

    @MainActor
    func testTranscribeWithoutOverrideLeavesSelectionUntouched() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = ConfigurableTranscriptionPlugin()
        plugin.currentModelId = "alpha"
        plugin.configured = true

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        _ = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 16_000),
            language: nil,
            task: .transcribe,
            engineOverrideId: nil,
            cloudModelOverride: nil,
            prompt: nil
        )

        XCTAssertEqual(plugin.selectedModelId, "alpha")
    }

    @MainActor
    func testHandleCancelHotkey_firstEscapeDuringRecordingShowsWarningWithoutCancelling() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.state = .recording

        context.dictationViewModel.handleCancelHotkey()

        XCTAssertEqual(context.dictationViewModel.state, .recording)
        XCTAssertEqual(
            context.dictationViewModel.recordingCancelWarningMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "Press Esc again to cancel recording")
        )
        XCTAssertNil(context.dictationViewModel.actionFeedbackMessage)
    }

    @MainActor
    func testHandleCancelHotkey_secondEscapeDuringRecordingCancels() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.state = .recording

        context.dictationViewModel.handleCancelHotkey()
        context.dictationViewModel.handleCancelHotkey()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertNil(context.dictationViewModel.recordingCancelWarningMessage)
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "Cancelled")
        )
    }

    @MainActor
    func testHandleCancelHotkey_secondEscapeDuringRecordingRestoresAudioThenResumesMediaBeforeImmediateStop() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var events: [String] = []
        let stopRecordingCalled = expectation(description: "stop recording called")
        let audioDuckingService = MockAudioDuckingService {
            events.append("restore_audio")
        }
        let mediaPlaybackService = MockMediaPlaybackService(
            onResume: {
                events.append("resume_media")
            }
        )
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            audioDuckingService: audioDuckingService,
            mediaPlaybackService: mediaPlaybackService
        )
        let context = try XCTUnwrap(dictationContext)
        context.audioRecordingService.stopRecordingOverride = { policy in
            events.append("stop_recording_\(policy.logDescription)")
            stopRecordingCalled.fulfill()
            return []
        }
        context.dictationViewModel.state = .recording

        context.dictationViewModel.handleCancelHotkey()
        context.dictationViewModel.handleCancelHotkey()

        await fulfillment(of: [stopRecordingCalled], timeout: 1.0)

        XCTAssertEqual(
            events,
            ["restore_audio", "resume_media", "stop_recording_immediate"]
        )
    }

    @MainActor
    func testHandleCancelHotkey_processingStillCancelsImmediately() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.state = .processing

        context.dictationViewModel.handleCancelHotkey()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertNil(context.dictationViewModel.recordingCancelWarningMessage)
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "Cancelled")
        )
    }

    @MainActor
    func testDisconnectedDeviceDuringRecordingRestoresAudioThenResumesMediaBeforeImmediateStop() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var events: [String] = []
        let stopRecordingCalled = expectation(description: "stop recording called")
        let audioDuckingService = MockAudioDuckingService {
            events.append("restore_audio")
        }
        let mediaPlaybackService = MockMediaPlaybackService(
            onResume: {
                events.append("resume_media")
            }
        )
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            audioDuckingService: audioDuckingService,
            mediaPlaybackService: mediaPlaybackService
        )
        let context = try XCTUnwrap(dictationContext)
        context.audioRecordingService.stopRecordingOverride = { policy in
            events.append("stop_recording_\(policy.logDescription)")
            stopRecordingCalled.fulfill()
            return []
        }
        context.dictationViewModel.state = .recording

        context.audioDeviceService.disconnectedDeviceName = "USB Mic"

        await fulfillment(of: [stopRecordingCalled], timeout: 1.0)

        XCTAssertEqual(
            events,
            ["restore_audio", "resume_media", "stop_recording_immediate"]
        )
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "Microphone disconnected")
        )
    }

    @MainActor
    func testRecordingCancelWarningClearsWhenStateLeavesRecording() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.state = .recording

        context.dictationViewModel.handleCancelHotkey()
        context.dictationViewModel.state = .processing

        XCTAssertNil(context.dictationViewModel.recordingCancelWarningMessage)
    }
}

final class AudioRecordingServiceInputAvailabilityTests: XCTestCase {
    func testStartRecording_throwsNoMicrophoneDetectedBeforeStartingOverride() {
        let service = AudioRecordingService()
        var didReachStartOverride = false

        service.hasMicrophonePermissionOverride = true
        service.selectedDeviceID = AudioDeviceID(42)
        service.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, AudioDeviceID(42))
            return false
        }
        service.startRecordingOverride = {
            didReachStartOverride = true
        }

        XCTAssertThrowsError(try service.startRecording()) { error in
            guard case AudioRecordingService.AudioRecordingError.noMicrophoneDetected = error else {
                return XCTFail("Expected noMicrophoneDetected, got \(error)")
            }
        }
        XCTAssertFalse(didReachStartOverride)
    }
}

final class HotkeyServiceCompatibilityTests: XCTestCase {
    @MainActor
    func testEscapeKeyStillInvokesCancelHandlerWithoutSuppression() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        var cancelCount = 0
        service.onCancelPressed = {
            cancelCount += 1
        }

        let escape = try makeKeyboardEvent(keyCode: 0x35, keyDown: true, flags: [])

        XCTAssertFalse(service.processEventForTesting(escape, source: .monitor))
        XCTAssertEqual(cancelCount, 1)
    }

    @MainActor
    func testMonitorFallbackStartsToggleHotkey() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testEventTapDispatchDedupesFollowingMonitorDispatch() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .eventTap))
        await Task.yield()
        XCTAssertEqual(startCount, 1)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testMonitorFallbackStopsPushToTalkOnKeyUp() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = {
            startCount += 1
        }
        service.onDictationStop = {
            stopCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let keyUp = try makeKeyboardEvent(keyCode: 0x31, keyDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testModifierComboPushToTalkDoesNotStopOnTransientFlagsChangedLoss() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let comboDown = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])
        let transientLoss = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command])
        let comboRestored = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])
        let fullRelease = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [])

        XCTAssertTrue(service.processEventForTesting(comboDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(transientLoss, source: .monitor))
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(comboRestored, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(fullRelease, source: .monitor))
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testRightSideModifierComboPushToTalkStaysActiveUntilFinalRelease() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let rightCommandDown = try makeFlagsChangedEvent(keyCode: 0x36, modifierFlags: [.command])
        let rightOptionDown = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])
        let transientRightCommandLoss = try makeFlagsChangedEvent(keyCode: 0x36, modifierFlags: [.option])
        let comboRestored = try makeFlagsChangedEvent(keyCode: 0x36, modifierFlags: [.command, .option])
        let finalRelease = try makeFlagsChangedEvent(keyCode: 0x36, modifierFlags: [])

        XCTAssertFalse(service.processEventForTesting(rightCommandDown, source: .monitor))
        XCTAssertEqual(startCount, 0)

        XCTAssertTrue(service.processEventForTesting(rightOptionDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(transientRightCommandLoss, source: .monitor))
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(comboRestored, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(finalRelease, source: .monitor))
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testPushToTalkExtraKeyInterruptionSignalsDiscardWithoutImmediateStop() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .pushToTalk)
        service.discardPushToTalkRecordingOnExtraKeyPress = true

        var startCount = 0
        var stopCount = 0
        var interruptionCount = 0
        service.onDictationStart = { startCount += 1 }
        service.onDictationStop = { stopCount += 1 }
        service.onPushToTalkInterruption = { interruptionCount += 1 }

        let comboDown = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])
        let extraKeyDown = try makeKeyboardEvent(keyCode: 0x25, keyDown: true, flags: [.maskCommand, .maskAlternate])
        let extraKeyUp = try makeKeyboardEvent(keyCode: 0x25, keyDown: false, flags: [.maskCommand, .maskAlternate])
        let fullRelease = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [])

        XCTAssertTrue(service.processEventForTesting(comboDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertFalse(service.processEventForTesting(extraKeyDown, source: .monitor))
        XCTAssertEqual(interruptionCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertFalse(service.processEventForTesting(extraKeyUp, source: .monitor))
        XCTAssertEqual(interruptionCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(fullRelease, source: .monitor))
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testPushToTalkExtraKeyInterruptionDoesNothingWhenPolicyDisabled() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .pushToTalk)
        service.discardPushToTalkRecordingOnExtraKeyPress = false

        var interruptionCount = 0
        service.onPushToTalkInterruption = { interruptionCount += 1 }

        let comboDown = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])
        let extraKeyDown = try makeKeyboardEvent(keyCode: 0x25, keyDown: true, flags: [.maskCommand, .maskAlternate])

        XCTAssertTrue(service.processEventForTesting(comboDown, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(extraKeyDown, source: .monitor))
        XCTAssertEqual(interruptionCount, 0)
    }

    @MainActor
    func testCapsLockOriginSuppressesModifierComboHotkey() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let capsLockEvent = try makeFlagsChangedEvent(keyCode: 0x39, modifierFlags: [.capsLock])
        let comboEvent = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])

        XCTAssertFalse(service.processEventForTesting(capsLockEvent, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(comboEvent, source: .monitor))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testCapsLockOriginSuppressesKeyWithModifiersHotkey() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionAHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let capsLockEvent = try makeFlagsChangedEvent(keyCode: 0x39, modifierFlags: [.capsLock])
        let keyDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])
        let keyUp = try makeKeyboardEvent(keyCode: 0x00, keyDown: false, flags: [.maskCommand, .maskAlternate])

        XCTAssertFalse(service.processEventForTesting(capsLockEvent, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testModifierComboStillWorksWithoutCapsLockOrigin() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let comboEvent = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])

        XCTAssertTrue(service.processEventForTesting(comboEvent, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testKeyWithModifiersStillWorksWithoutCapsLockOrigin() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionAHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testBareKeyHotkeyRemainsAllowedAfterCapsLockOrigin() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(bareSpaceHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let capsLockEvent = try makeFlagsChangedEvent(keyCode: 0x39, modifierFlags: [.capsLock])
        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true, flags: [])

        XCTAssertFalse(service.processEventForTesting(capsLockEvent, source: .monitor))
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testMonitorFallbackStartsPushToTalkOnFnPress() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(fnHotkey(), for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeFnEvent(isDown: true)
        let keyUp = try makeFnEvent(isDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testMonitorFallbackStartsHybridOnFnPress() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(fnHotkey(), for: .hybrid)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeFnEvent(isDown: true)
        let keyUp = try makeFnEvent(isDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .toggle)
    }

    @MainActor
    func testMonitorFallbackStartsHybridLongPressAndStopsAfterRelease() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(fnHotkey(), for: .hybrid)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeFnEvent(isDown: true)
        let keyUp = try makeFnEvent(isDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)

        try await Task.sleep(nanoseconds: 1_150_000_000)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(startCount, 1)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testMonitorFallbackToggleFnStillWorksOnRelease() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(fnHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { startCount += 1 }

        let keyDown = try makeFnEvent(isDown: true)
        let keyUp = try makeFnEvent(isDown: false)

        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 0)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testRecentTranscriptionsHotkeyInvokesDedicatedCallbackOnKeyDown() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .recentTranscriptions)

        var callbackCount = 0
        var startCount = 0
        service.onRecentTranscriptionsToggle = { callbackCount += 1 }
        service.onDictationStart = { startCount += 1 }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testRecentTranscriptionsHotkeyDoesNotStopActiveDictation() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)
        service.setHotkeyForTesting(commandOptionAHotkey(), for: .recentTranscriptions)

        var startCount = 0
        var stopCount = 0
        var callbackCount = 0
        service.onDictationStart = { startCount += 1 }
        service.onDictationStop = { stopCount += 1 }
        service.onRecentTranscriptionsToggle = { callbackCount += 1 }

        let toggleDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let recentDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])

        XCTAssertTrue(service.processEventForTesting(toggleDown, source: .monitor))
        XCTAssertEqual(startCount, 1)

        XCTAssertTrue(service.processEventForTesting(recentDown, source: .monitor))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .toggle)
    }

    @MainActor
    func testCopyLastTranscriptionHotkeyInvokesDedicatedCallbackOnKeyDown() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandShiftCHotkey(), for: .copyLastTranscription)

        var callbackCount = 0
        var startCount = 0
        service.onCopyLastTranscription = { callbackCount += 1 }
        service.onDictationStart = { startCount += 1 }

        let keyDown = try makeKeyboardEvent(keyCode: 0x08, keyDown: true, flags: [.maskCommand, .maskShift])

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testCopyLastTranscriptionHotkeyDoesNotStopActiveDictation() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)
        service.setHotkeyForTesting(commandShiftCHotkey(), for: .copyLastTranscription)

        var startCount = 0
        var stopCount = 0
        var callbackCount = 0
        service.onDictationStart = { startCount += 1 }
        service.onDictationStop = { stopCount += 1 }
        service.onCopyLastTranscription = { callbackCount += 1 }

        let toggleDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let copyDown = try makeKeyboardEvent(keyCode: 0x08, keyDown: true, flags: [.maskCommand, .maskShift])

        XCTAssertTrue(service.processEventForTesting(toggleDown, source: .monitor))
        XCTAssertEqual(startCount, 1)

        XCTAssertTrue(service.processEventForTesting(copyDown, source: .monitor))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .toggle)
    }

    @MainActor
    func testMenuShortcutDescriptorSupportsPrintableKeyboardShortcut() {
        let descriptor = HotkeyService.menuShortcutDescriptor(for: commandShiftCHotkey())

        XCTAssertEqual(descriptor?.keyEquivalent, "c")
        XCTAssertEqual(descriptor?.modifiers, [.command, .shift])
    }

    @MainActor
    func testMenuShortcutDescriptorSupportsFunctionKeyShortcut() {
        let hotkey = UnifiedHotkey(
            keyCode: 0x64,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            isFn: false
        )

        let descriptor = HotkeyService.menuShortcutDescriptor(for: hotkey)

        XCTAssertEqual(descriptor?.keyEquivalent, Character(UnicodeScalar(NSF8FunctionKey)!))
        XCTAssertEqual(descriptor?.modifiers, [.function])
    }

    @MainActor
    func testMenuShortcutDescriptorSkipsUnsupportedModifierOnlyShortcut() {
        let descriptor = HotkeyService.menuShortcutDescriptor(for: fnHotkey())

        XCTAssertNil(descriptor)
    }

    @MainActor
    func testWorkflowHotkeyInvokesDedicatedWorkflowCallback() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        let workflowId = UUID()
        service.registerWorkflowHotkeys([(id: workflowId, hotkey: spaceHotkey())])

        var startedWorkflowId: UUID?
        service.onWorkflowDictationStart = { startedWorkflowId = $0 }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let keyUp = try makeKeyboardEvent(keyCode: 0x31, keyDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startedWorkflowId, workflowId)
        XCTAssertEqual(service.currentMode, .pushToTalk)
        XCTAssertEqual(service.activeWorkflowId, workflowId)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(service.currentMode, .toggle)
        XCTAssertEqual(service.activeWorkflowId, workflowId)
    }

    @MainActor
    func testWorkflowCanRegisterMultipleHotkeysForSameWorkflow() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        let workflowId = UUID()
        service.registerWorkflowHotkeys([
            (id: workflowId, hotkey: spaceHotkey()),
            (id: workflowId, hotkey: alternateSpaceHotkey())
        ])

        var startedWorkflowIds: [UUID] = []
        service.onWorkflowDictationStart = { startedWorkflowIds.append($0) }

        let firstDown = try makeKeyboardEvent(
            keyCode: 0x31,
            keyDown: true,
            flags: [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        )
        let secondDown = try makeKeyboardEvent(
            keyCode: 0x31,
            keyDown: true,
            flags: [.maskCommand, .maskAlternate]
        )

        XCTAssertTrue(service.processEventForTesting(firstDown, source: .monitor))
        service.cancelDictation()
        XCTAssertTrue(service.processEventForTesting(secondDown, source: .monitor))
        XCTAssertEqual(startedWorkflowIds, [workflowId, workflowId])
    }

    @MainActor
    private func spaceHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x31,
            modifierFlags: NSEvent.ModifierFlags([.control, .option, .shift, .command]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func alternateSpaceHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x31,
            modifierFlags: NSEvent.ModifierFlags([.option, .command]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func commandOptionComboHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func commandOptionAHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x00,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func commandShiftCHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x08,
            modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func bareSpaceHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x31,
            modifierFlags: 0,
            isFn: false
        )
    }

    @MainActor
    private func fnHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x00,
            modifierFlags: 0,
            isFn: true
        )
    }

    private func makeKeyboardEvent(
        keyCode: UInt16,
        keyDown: Bool,
        flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    ) throws -> NSEvent {
        let event = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        )
        event.flags = flags
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func makeFlagsChangedEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    private func makeFnEvent(isDown: Bool) throws -> NSEvent {
        try makeFlagsChangedEvent(
            keyCode: 0x3F,
            modifierFlags: isDown ? [.function] : []
        )
    }
}
