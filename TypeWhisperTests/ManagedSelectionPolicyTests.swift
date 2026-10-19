import Foundation
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

private func snapshot(_ forced: [String: ManagedPolicyRawValue]) -> ManagedPolicySnapshot {
    ManagedPolicyValidator.validate(ManagedPolicyReading(forcedValues: forced), revision: 1, readAt: Date())
}

final class ManagedSelectionPolicyTests: XCTestCase {
    func testSnapshotMapsEnforcedAndRecommendedPairs() {
        let policy = ManagedSelectionPolicy(snapshot: snapshot([
            "TranscriptionProviderId": .string("com.typewhisper.parakeet"),
            "TranscriptionModelId": .string("parakeet-tdt-0.6b-v3"),
            "Recommended": .dictionary([
                "LlmProviderId": .string("com.typewhisper.apple-intelligence"),
                "LlmModelId": .string("default"),
            ]),
        ]))

        XCTAssertEqual(policy.enforcedTranscription, ManagedSelectionPair(providerId: "com.typewhisper.parakeet", modelId: "parakeet-tdt-0.6b-v3"))
        XCTAssertEqual(policy.recommendedLlm, ManagedSelectionPair(providerId: "com.typewhisper.apple-intelligence", modelId: "default"))
        XCTAssertNil(policy.enforcedLlm)
        XCTAssertTrue(policy.enforcesTranscription)
        XCTAssertFalse(policy.enforcesLlm)
        XCTAssertEqual(ManagedSelectionPolicy(snapshot: snapshot([:])), .unmanaged)
    }

    func testIncompleteEnforcedPairBlocksItsCapability() {
        let policy = ManagedSelectionPolicy(snapshot: snapshot(["LlmProviderId": .string("com.typewhisper.claude")]))

        XCTAssertNil(policy.enforcedLlm)
        XCTAssertTrue(policy.isLlmBlocked)
        XCTAssertTrue(policy.enforcesLlm)
        XCTAssertFalse(policy.isTranscriptionBlocked)
    }

    func testProviderIdsSplitIntoPluginAndProvider() {
        XCTAssertTrue(ManagedSelectionPair(providerId: "com.typewhisper.parakeet", modelId: "m").components == ("com.typewhisper.parakeet", nil))
        XCTAssertTrue(ManagedSelectionPair(providerId: "com.typewhisper.openai-compatible:office", modelId: "m").components == ("com.typewhisper.openai-compatible", "office"))
        XCTAssertTrue(ManagedSelectionPair(providerId: "com.typewhisper.openai-compatible:", modelId: "m").components == ("com.typewhisper.openai-compatible", nil))
    }
}

@MainActor
final class ManagedSelectionPolicyResolutionTests: XCTestCase {
    private var directory: URL!
    private var previousManager: PluginManager?

    override func setUp() async throws {
        try await super.setUp()
        directory = try TestSupport.makeTemporaryDirectory(prefix: "ManagedSelectionPolicy")
        previousManager = PluginManager.shared
        for key in [UserDefaultsKeys.managedTranscriptionModelRetention, UserDefaultsKeys.managedTranscriptionRecommendationApplied] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        PluginManager.shared = previousManager
        for key in [UserDefaultsKeys.managedTranscriptionModelRetention, UserDefaultsKeys.managedTranscriptionRecommendationApplied] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        TestSupport.remove(directory)
        try await super.tearDown()
    }

    func testTranscriptionPairResolvesTheEngineAndTheCatalogModel() {
        let manager = makeManager()

        XCTAssertEqual(
            manager.resolveTranscriptionPair(ManagedSelectionPair(providerId: "COM.TYPEWHISPER.TESTS.PAIR.LOCAL", modelId: "LARGE")),
            .resolved(providerId: "local-engine", modelId: "large")
        )
        XCTAssertEqual(
            manager.resolveTranscriptionPair(ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.local:local-engine", modelId: "small")),
            .resolved(providerId: "local-engine", modelId: "small")
        )
        XCTAssertNotNil(manager.resolveTranscriptionPair(ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.local", modelId: "missing")).unavailableReason)
        XCTAssertNotNil(manager.resolveTranscriptionPair(ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.local:other", modelId: "small")).unavailableReason)
        XCTAssertNotNil(manager.resolveTranscriptionPair(ManagedSelectionPair(providerId: "com.typewhisper.tests.missing", modelId: "small")).unavailableReason)
    }

    func testPairRefusedByAnotherRestrictionStaysUnavailable() {
        let manager = makeManager()
        manager.applyProviderPolicy(ManagedProviderPolicy(allowsCloudTranscription: false))

        let resolution = manager.resolveTranscriptionPair(ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.cloud", modelId: "nova"))

        XCTAssertNotNil(resolution.unavailableReason)
    }

    func testLlmPairResolvesPluginsAndAppleIntelligence() {
        let manager = makeManager()

        XCTAssertEqual(
            manager.resolveLlmPair(ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.llm", modelId: "MODEL-A")),
            .resolved(providerId: "Pair LLM", modelId: "model-a")
        )
        XCTAssertEqual(
            manager.resolveLlmPair(ManagedSelectionPair(providerId: "com.typewhisper.apple-intelligence", modelId: "default")),
            .resolved(providerId: PromptProcessingService.appleIntelligenceId, modelId: "default")
        )
        XCTAssertNotNil(manager.resolveLlmPair(ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.llm", modelId: "unknown")).unavailableReason)
    }

    func testEnforcedPairDecidesTheEngineAndModelAndRestoresTheUsersModel() {
        let manager = makeManager()
        PluginManager.shared = manager
        let modelManager = ModelManagerService()
        modelManager.selectProvider("cloud-engine")
        localEngine(manager).selectModel("small")

        manager.applySelectionPolicy(ManagedSelectionPolicy(
            enforcedTranscription: ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.local", modelId: "large")
        ))
        modelManager.restoreProviderSelection()

        XCTAssertEqual(modelManager.selectedProviderId, "local-engine")
        XCTAssertEqual(modelManager.effectiveEngineId("cloud-engine"), "local-engine", "Overrides cannot pick another engine")
        XCTAssertNil(modelManager.effectiveModelOverride("other-model"))
        XCTAssertEqual(localEngine(manager).selectedModelId, "large")
        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine), "cloud-engine", "The user's choice is kept")

        modelManager.selectProvider("cloud-engine")
        XCTAssertEqual(modelManager.selectedProviderId, "local-engine")

        manager.applySelectionPolicy(.unmanaged)
        modelManager.restoreProviderSelection()

        XCTAssertEqual(modelManager.selectedProviderId, "cloud-engine")
        XCTAssertEqual(localEngine(manager).selectedModelId, "small")
        XCTAssertTrue((UserDefaults.standard.dictionary(forKey: UserDefaultsKeys.managedTranscriptionModelRetention) ?? [:]).isEmpty)
    }

    func testUnavailableEnforcedPairBlocksWithoutFallingBack() {
        let manager = makeManager()
        PluginManager.shared = manager
        let modelManager = ModelManagerService()
        modelManager.selectProvider("local-engine")

        manager.applySelectionPolicy(ManagedSelectionPolicy(
            enforcedTranscription: ManagedSelectionPair(providerId: "com.typewhisper.tests.missing", modelId: "x")
        ))
        modelManager.restoreProviderSelection()

        XCTAssertNil(modelManager.selectedProviderId)
        XCTAssertNil(modelManager.effectiveEngineId("local-engine"))
        guard case .managedPolicyRefused? = modelManager.transcriptionReadinessError(providerId: nil) else {
            return XCTFail("Expected a policy refusal")
        }
        manager.applySelectionPolicy(.unmanaged)
    }

    func testRecommendedPairBecomesTheInitialSelectionOnce() {
        let manager = makeManager()
        PluginManager.shared = manager
        let modelManager = ModelManagerService()
        modelManager.clearProviderSelection()
        manager.applySelectionPolicy(ManagedSelectionPolicy(
            recommendedTranscription: ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.local", modelId: "large")
        ))

        modelManager.restoreProviderSelection()

        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine), "local-engine")
        XCTAssertEqual(localEngine(manager).selectedModelId, "large")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: UserDefaultsKeys.managedTranscriptionRecommendationApplied))

        modelManager.selectProvider("cloud-engine")
        modelManager.restoreProviderSelection()
        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine), "cloud-engine", "A later choice is kept")
        manager.applySelectionPolicy(.unmanaged)
    }

    func testEnforcedLlmPairReplacesTheRequestedProvider() async throws {
        let manager = makeManager()
        PluginManager.shared = manager
        manager.applySelectionPolicy(ManagedSelectionPolicy(
            enforcedLlm: ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.llm", modelId: "model-a")
        ))
        let suite = "TypeWhisperTests.ManagedPairs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            manager.applySelectionPolicy(.unmanaged)
        }
        let service = PromptProcessingService(userDefaults: defaults)
        PairTestLLM.models = []

        let result = try await service.process(prompt: "Fix", text: "hello", providerOverride: "Other LLM", skipMemoryInjection: true)

        XCTAssertEqual(result, "hello")
        XCTAssertEqual(PairTestLLM.models, ["model-a"])

        manager.applySelectionPolicy(ManagedSelectionPolicy(
            enforcedLlm: ManagedSelectionPair(providerId: "com.typewhisper.tests.missing", modelId: "x")
        ))
        do {
            _ = try await service.process(prompt: "Fix", text: "hello", skipMemoryInjection: true)
            XCTFail("An unavailable enforced pair must refuse")
        } catch {
            XCTAssertTrue(error is ManagedPolicyRefusal)
        }
    }

    func testRecommendedLlmPairReplacesOnlyTheBuiltInDefault() throws {
        let manager = makeManager()
        PluginManager.shared = manager
        manager.applySelectionPolicy(ManagedSelectionPolicy(
            recommendedLlm: ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.llm", modelId: "model-a")
        ))
        let suite = "TypeWhisperTests.ManagedPairs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            manager.applySelectionPolicy(.unmanaged)
        }
        let service = PromptProcessingService(userDefaults: defaults)

        service.applyRecommendedLlmPairIfNeeded()

        XCTAssertEqual(service.fallbackPriorityList.map(\.providerId), ["Pair LLM"])
        XCTAssertEqual(service.fallbackPriorityList.map(\.modelId), ["model-a"])
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.managedLlmRecommendationApplied))
    }

    func testRecommendedModelIsSelectedOnlyOnceItIsDownloaded() {
        let engine = DownloadingPairEngine(downloaded: [])
        let manager = PluginManager(appSupportDirectory: directory)
        manager.loadedPlugins = [
            loaded(engine, id: "com.typewhisper.tests.pair.downloads", locality: "local", categories: ["transcription"]),
        ]
        PluginManager.shared = manager
        let modelManager = ModelManagerService()
        modelManager.clearProviderSelection()
        manager.applySelectionPolicy(ManagedSelectionPolicy(
            recommendedTranscription: ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.downloads", modelId: "large")
        ))
        defer { manager.applySelectionPolicy(.unmanaged) }

        modelManager.restoreProviderSelection()
        modelManager.restoreProviderSelection()

        XCTAssertEqual(engine.selections, [], "Checking readiness must not load the recommended model")
        XCTAssertNil(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: UserDefaultsKeys.managedTranscriptionRecommendationApplied))

        engine.downloaded = ["large"]
        modelManager.restoreProviderSelection()

        XCTAssertEqual(engine.selections, ["large"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine), "downloads-engine")
    }

    func testFallbackWhileTheRecommendationIsPendingIsNotSaved() {
        let pending = DownloadingPairEngine(downloaded: [])
        let manager = PluginManager(appSupportDirectory: directory)
        manager.loadedPlugins = [
            loaded(PairTestEngine(providerID: "ready-engine", models: ["base"]), id: "com.typewhisper.tests.pair.ready", locality: "local", categories: ["transcription"]),
            loaded(pending, id: "com.typewhisper.tests.pair.downloads", locality: "local", categories: ["transcription"]),
        ]
        PluginManager.shared = manager
        let modelManager = ModelManagerService()
        modelManager.clearProviderSelection()
        manager.applySelectionPolicy(ManagedSelectionPolicy(
            recommendedTranscription: ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.downloads", modelId: "large")
        ))
        defer {
            manager.applySelectionPolicy(.unmanaged)
            PluginManager.temporaryFallbackEngine.withLock { $0 = nil }
        }

        modelManager.restoreProviderSelection()

        XCTAssertEqual(modelManager.selectedProviderId, "ready-engine", "Dictation works in the meantime")
        XCTAssertNil(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine), "The fallback is not the user's choice")

        pending.downloaded = ["large"]
        modelManager.restoreProviderSelection()

        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine), "downloads-engine")
        XCTAssertEqual(modelManager.selectedProviderId, "downloads-engine")
        XCTAssertEqual(pending.selections, ["large"])
    }

    func testRecommendedLlmPairWaitsForAReadyProvider() throws {
        let manager = makeManager()
        PluginManager.shared = manager
        manager.applySelectionPolicy(ManagedSelectionPolicy(
            recommendedLlm: ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.llm", modelId: "model-a")
        ))
        let suite = "TypeWhisperTests.ManagedPairs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        PairTestLLM.available = false
        defer {
            PairTestLLM.available = true
            defaults.removePersistentDomain(forName: suite)
            manager.applySelectionPolicy(.unmanaged)
        }
        let service = PromptProcessingService(userDefaults: defaults)
        let builtInDefault = service.fallbackPriorityList

        service.applyRecommendedLlmPairIfNeeded()

        XCTAssertEqual(service.fallbackPriorityList, builtInDefault)
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.managedLlmRecommendationApplied))

        PairTestLLM.available = true
        service.applyRecommendedLlmPairIfNeeded()

        XCTAssertEqual(service.fallbackPriorityList.map(\.providerId), ["Pair LLM"])
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.managedLlmRecommendationApplied))
    }

    func testEnforcedPairKeepsAStaleWorkflowOverrideFromBlockingSaves() {
        let manager = makeManager()
        let workflowDirectory = directory.appendingPathComponent("Workflows", isDirectory: true)
        let workflowService = WorkflowService(appSupportDirectory: workflowDirectory)
        let hotkeyService = HotkeyService()
        var draft = WorkflowDraft(template: .dictation)
        draft.transcriptionEngineId = "removed-engine"
        let missingEngine = "The selected transcription engine is not installed."

        let unmanaged = draft.validationError(
            hotkeyService: hotkeyService, workflowService: workflowService, pluginManager: manager, existingWorkflowId: nil
        )
        XCTAssertEqual(unmanaged, missingEngine)

        manager.applySelectionPolicy(ManagedSelectionPolicy(
            enforcedTranscription: ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.local", modelId: "large")
        ))
        let enforced = draft.validationError(
            hotkeyService: hotkeyService, workflowService: workflowService, pluginManager: manager, existingWorkflowId: nil
        )
        XCTAssertNotEqual(enforced, missingEngine, "The locked pickers cannot clear the override")
        XCTAssertEqual(draft.transcriptionEngineId, "removed-engine", "The override is kept for later")
    }

    private func makeManager() -> PluginManager {
        let manager = PluginManager(appSupportDirectory: directory)
        manager.loadedPlugins = [
            loaded(PairTestEngine(providerID: "local-engine", models: ["small", "large"]), id: "com.typewhisper.tests.pair.local", locality: "local", categories: ["transcription"]),
            loaded(PairTestEngine(providerID: "cloud-engine", models: ["nova"]), id: "com.typewhisper.tests.pair.cloud", locality: "cloud", categories: ["transcription", "llm"]),
            loaded(PairTestLLM(), id: "com.typewhisper.tests.pair.llm", locality: "local", categories: ["llm"]),
        ]
        return manager
    }

    private func localEngine(_ manager: PluginManager) -> PairTestEngine {
        manager.loadedPlugins.first { $0.id == "com.typewhisper.tests.pair.local" }!.instance as! PairTestEngine
    }

    private func loaded(_ instance: TypeWhisperPlugin, id: String, locality: String, categories: [String]) -> LoadedPlugin {
        LoadedPlugin(
            manifest: PluginManifest(id: id, name: id, version: "1.0.0", principalClass: "Test", categories: categories, locality: locality),
            instance: instance,
            bundle: Bundle.main,
            sourceURL: directory,
            isEnabled: true
        )
    }
}

private final class PairTestEngine: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.pair-engine"
    static let pluginName = "Pair Engine"

    private let providerID: String
    private let models: [String]
    private(set) var selectedModelId: String?

    init(providerID: String, models: [String]) {
        self.providerID = providerID
        self.models = models
        self.selectedModelId = models.first
    }

    required override init() {
        providerID = "engine"
        models = []
    }

    var providerId: String { providerID }
    var providerDisplayName: String { providerID }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { models.map { PluginModelInfo(id: $0, displayName: $0) } }
    var supportsTranslation: Bool { false }
    func activate(host: HostServices) {}
    func deactivate() {}
    func selectModel(_ modelId: String) { selectedModelId = modelId }
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok", detectedLanguage: language)
    }
}

private final class PairTestLLM: NSObject, LLMProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.pair-llm"
    static let pluginName = "Pair LLM"
    nonisolated(unsafe) static var models: [String?] = []
    nonisolated(unsafe) static var available = true

    required override init() {}

    var providerName: String { "Pair LLM" }
    var isAvailable: Bool { Self.available }
    var supportedModels: [PluginModelInfo] { [PluginModelInfo(id: "model-a", displayName: "A"), PluginModelInfo(id: "model-b", displayName: "B")] }
    func activate(host: HostServices) {}
    func deactivate() {}
    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        Self.models.append(model)
        return userText
    }
}

private final class DownloadingPairEngine: NSObject, TranscriptionEnginePlugin, PluginDownloadedModelManaging, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.pair-downloads"
    static let pluginName = "Downloading Pair Engine"

    var downloaded: [String]
    private(set) var selections: [String] = []

    init(downloaded: [String]) {
        self.downloaded = downloaded
    }

    required override init() {
        downloaded = []
    }

    var providerId: String { "downloads-engine" }
    var providerDisplayName: String { "Downloads Engine" }
    var isConfigured: Bool { false }
    var selectedModelId: String? { selections.last ?? "small" }
    var transcriptionModels: [PluginModelInfo] { ["small", "large"].map { PluginModelInfo(id: $0, displayName: $0) } }
    var downloadedModels: [PluginModelInfo] { downloaded.map { PluginModelInfo(id: $0, displayName: $0) } }
    var supportsTranslation: Bool { false }
    func activate(host: HostServices) {}
    func deactivate() {}
    func deleteDownloadedModel(_ modelId: String) async throws {}
    func selectModel(_ modelId: String) { selections.append(modelId) }
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok", detectedLanguage: language)
    }
}
