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

    func testTranscriptionPairUsesTheFullModelCatalog() {
        let manager = PluginManager(appSupportDirectory: directory)
        manager.loadedPlugins = [
            loaded(CatalogPairEngine(), id: "com.typewhisper.tests.pair.catalog", locality: "local", categories: ["transcription"]),
        ]

        // Nothing is loaded, so the engine lists no models; the catalog still names both.
        XCTAssertEqual(
            manager.resolveTranscriptionPair(ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.catalog", modelId: "LARGE")),
            .resolved(providerId: "catalog-engine", modelId: "large")
        )
        XCTAssertNotNil(manager.resolveTranscriptionPair(ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.catalog", modelId: "missing")).unavailableReason)
    }

    func testFeatureEnginesFollowTheEnforcedPair() throws {
        let manager = makeManager()
        PluginManager.shared = manager
        defer { manager.applySelectionPolicy(.unmanaged) }
        let suite = "TypeWhisperTests.ManagedPairs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = FileTranscriptionViewModel(
            modelManager: ModelManagerService(),
            audioFileService: AudioFileService(),
            dictionaryService: DictionaryService(appSupportDirectory: directory),
            defaults: defaults
        )
        files.selectedEngine = "cloud-engine"
        XCTAssertEqual(files.resolvedEngine?.providerId, "cloud-engine")

        // Readiness follows the engine that will run, not the feature's own choice.
        manager.applySelectionPolicy(ManagedSelectionPolicy(
            enforcedTranscription: ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.local", modelId: "small")
        ))
        XCTAssertEqual(files.resolvedEngine?.providerId, "local-engine")

        manager.applySelectionPolicy(ManagedSelectionPolicy(
            enforcedTranscription: ManagedSelectionPair(providerId: "com.typewhisper.tests.missing", modelId: "small")
        ))
        XCTAssertNil(files.resolvedEngine, "An unusable pair leaves nothing ready")
    }

    func testEnforcedLlmPairLocksTheFallbackList() throws {
        let manager = makeManager()
        PluginManager.shared = manager
        let suite = "TypeWhisperTests.ManagedPairs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            manager.applySelectionPolicy(.unmanaged)
        }
        let service = PromptProcessingService(userDefaults: defaults)
        service.addLLMFallback(providerId: "Pair LLM", modelId: "model-a")
        let saved = service.fallbackPriorityList
        let first = try XCTUnwrap(saved.first)

        manager.applySelectionPolicy(ManagedSelectionPolicy(
            enforcedLlm: ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.llm", modelId: "model-b")
        ))
        XCTAssertTrue(service.isFallbackListLocked)
        service.addLLMFallback(providerId: "Pair LLM", modelId: "model-b")
        service.updateLLMFallback(first, providerId: "Pair LLM", modelId: "model-b")
        service.moveLLMFallbacks(from: IndexSet(integer: 0), to: saved.count)
        service.removeLLMFallback(first)
        XCTAssertEqual(service.fallbackPriorityList, saved)

        manager.applySelectionPolicy(.unmanaged)
        XCTAssertFalse(service.isFallbackListLocked)
        service.addLLMFallback(providerId: "Pair LLM", modelId: "model-b")
        XCTAssertEqual(service.fallbackPriorityList.count, saved.count + 1)
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

    func testDefaultEngineIsTheEnforcedEngineAndTheSavedOneIsNotNamedApart() {
        let manager = makeManager()
        PluginManager.shared = manager
        defer { manager.applySelectionPolicy(.unmanaged) }
        let modelManager = ModelManagerService()
        modelManager.selectProvider("cloud-engine")

        manager.applySelectionPolicy(ManagedSelectionPolicy(
            enforcedTranscription: ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.local", modelId: "large")
        ))
        modelManager.restoreProviderSelection()

        XCTAssertEqual(modelManager.defaultEngine?.providerId, "local-engine")
        XCTAssertNil(modelManager.unavailableSavedEngine, "Managed settings decide the engine, not a fallback")
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

    // MARK: Transient model selections

    func testRemovingThePairRestoresNoSelectionThroughATransientSelection() {
        let engine = TransientPairEngine(savedModelId: nil)
        let (manager, modelManager) = makeTransientManager([engine])

        enforce(manager, "large")
        modelManager.restoreProviderSelection()

        XCTAssertEqual(modelManager.selectedProviderId, "transient-engine")
        XCTAssertEqual(engine.selectedModelId, "large")
        XCTAssertEqual(engine.transientModelId, "large")
        XCTAssertNil(engine.savedModelId, "The enforced model is not saved as the user's selection")
        XCTAssertTrue(retainedModels().isEmpty, "Nothing is retained for an engine with a transient selection")

        manager.applySelectionPolicy(.unmanaged)
        modelManager.restoreProviderSelection()

        XCTAssertNil(engine.selectedModelId, "No model is selected again")
        XCTAssertNil(engine.transientModelId)
        XCTAssertEqual(engine.savedSelections, [], "The host never selected a model")
        XCTAssertTrue(retainedModels().isEmpty)
    }

    func testRemovingThePairRestoresTheUsersModelThroughATransientSelection() {
        let engine = TransientPairEngine(savedModelId: "small")
        let (manager, modelManager) = makeTransientManager([engine])

        enforce(manager, "large")
        modelManager.restoreProviderSelection()
        XCTAssertEqual(engine.selectedModelId, "large")
        XCTAssertEqual(engine.savedModelId, "small")

        manager.applySelectionPolicy(.unmanaged)
        modelManager.restoreProviderSelection()

        XCTAssertEqual(engine.selectedModelId, "small")
        XCTAssertNil(engine.transientModelId)
        XCTAssertEqual(engine.savedSelections, [])
    }

    func testEngineWithoutTransientSelectionKeepsTheRetainedSelection() {
        let manager = makeManager()
        PluginManager.shared = manager
        let modelManager = ModelManagerService()
        let engine = PairTestEngine(providerID: "local-engine", models: ["small", "large"], selectedModelId: nil)
        manager.loadedPlugins[0] = loaded(engine, id: "com.typewhisper.tests.pair.local", locality: "local", categories: ["transcription"])
        defer { manager.applySelectionPolicy(.unmanaged) }

        manager.applySelectionPolicy(ManagedSelectionPolicy(
            enforcedTranscription: ManagedSelectionPair(providerId: "com.typewhisper.tests.pair.local", modelId: "large")
        ))
        modelManager.restoreProviderSelection()
        XCTAssertEqual(engine.selectedModelId, "large")
        XCTAssertEqual(retainedModels(), ["local-engine": ""], "Plugins without the capability keep the retention")

        manager.applySelectionPolicy(.unmanaged)
        modelManager.restoreProviderSelection()

        XCTAssertEqual(engine.selectedModelId, "large", "Without a transient selection the enforced model stays selected")
        XCTAssertTrue(retainedModels().isEmpty)
    }

    func testRelaunchAppliesTheTransientSelectionAgainWhileThePairLasts() {
        let engine = TransientPairEngine(savedModelId: "small")
        let (manager, modelManager) = makeTransientManager([engine])
        enforce(manager, "large")
        modelManager.restoreProviderSelection()

        // A relaunch or reload starts a new plugin instance from what the plugin saved.
        let relaunched = TransientPairEngine(savedModelId: engine.savedModelId)
        manager.loadedPlugins = [loaded(relaunched, id: TransientPairEngine.pluginId, locality: "local", categories: ["transcription"])]
        ModelManagerService().restoreProviderSelection()

        XCTAssertEqual(relaunched.selectedModelId, "large")
        XCTAssertEqual(relaunched.savedModelId, "small")
        XCTAssertEqual(relaunched.savedSelections, [])
    }

    func testRelaunchAfterThePairWasRemovedKeepsNothingEnforced() {
        let engine = TransientPairEngine(savedModelId: nil)
        let (manager, modelManager) = makeTransientManager([engine])
        enforce(manager, "large")
        modelManager.restoreProviderSelection()

        // The profile was removed while TypeWhisper was not running.
        manager.applySelectionPolicy(.unmanaged)
        let relaunched = TransientPairEngine(savedModelId: engine.savedModelId)
        manager.loadedPlugins = [loaded(relaunched, id: TransientPairEngine.pluginId, locality: "local", categories: ["transcription"])]
        ModelManagerService().restoreProviderSelection()

        XCTAssertNil(relaunched.selectedModelId)
        XCTAssertNil(relaunched.transientModelId)
        XCTAssertTrue(retainedModels().isEmpty)
    }

    func testDeactivatedPluginGetsTheTransientSelectionAgain() {
        let engine = TransientPairEngine(savedModelId: "small")
        let (manager, modelManager) = makeTransientManager([engine])
        enforce(manager, "large")
        modelManager.restoreProviderSelection()

        engine.deactivate()
        XCTAssertEqual(engine.selectedModelId, "small", "Deactivation drops the transient selection")
        modelManager.restoreProviderSelection()

        XCTAssertEqual(engine.selectedModelId, "large")
        XCTAssertEqual(engine.savedModelId, "small")
    }

    func testChangingThePairMovesTheTransientSelection() {
        let first = TransientPairEngine(savedModelId: "small")
        let second = TransientPairEngine(providerID: "second-engine", savedModelId: nil)
        let (manager, modelManager) = makeTransientManager([first, second])

        enforce(manager, "large")
        modelManager.restoreProviderSelection()
        XCTAssertEqual(first.transientModelId, "large")

        enforce(manager, "small")
        modelManager.restoreProviderSelection()
        XCTAssertEqual(first.transientModelId, "small", "Another model of the same engine replaces the transient one")
        XCTAssertEqual(first.savedModelId, "small")

        enforce(manager, "large", engine: "second-engine")
        modelManager.restoreProviderSelection()

        XCTAssertEqual(modelManager.selectedProviderId, "second-engine")
        XCTAssertNil(first.transientModelId, "The engine the pair no longer names returns to its selection")
        XCTAssertEqual(first.selectedModelId, "small")
        XCTAssertEqual(second.selectedModelId, "large")
        XCTAssertNil(second.savedModelId)
        XCTAssertEqual(first.savedSelections + second.savedSelections, [])
    }

    func testUnusablePairEndsTransientSelections() {
        let engine = TransientPairEngine(savedModelId: nil)
        let (manager, modelManager) = makeTransientManager([engine])
        enforce(manager, "large")
        modelManager.restoreProviderSelection()

        enforce(manager, "missing")
        modelManager.restoreProviderSelection()

        XCTAssertNil(modelManager.selectedProviderId, "The unusable pair still blocks")
        XCTAssertNil(engine.transientModelId)
        XCTAssertNil(engine.selectedModelId)
    }

    func testTransientSelectionNeitherSelectsNorLoadsAModel() {
        let engine = TransientPairEngine(savedModelId: nil)
        let (manager, modelManager) = makeTransientManager([engine])
        XCTAssertFalse(modelManager.canPrepareForTranscription(engine), "No model to restore yet")

        enforce(manager, "large")
        modelManager.restoreProviderSelection()
        modelManager.restoreProviderSelection()

        XCTAssertEqual(engine.beginCount, 1, "A transient selection already in effect is not begun again")
        XCTAssertEqual(engine.savedSelections, [], "selectModel(_:) can start a download in some plugins")
        XCTAssertEqual(engine.restoreRequests, 0, "Applying the pair does not load the model")
        XCTAssertTrue(modelManager.canPrepareForTranscription(engine), "The transient model loads on first use")

        manager.applySelectionPolicy(.unmanaged)
        modelManager.restoreProviderSelection()

        XCTAssertEqual(engine.restoreRequests, 0)
        XCTAssertFalse(modelManager.canPrepareForTranscription(engine))
    }

    func testModelRetainedBeforeTheTransientSelectionIsSavedAgain() {
        // The earlier approach saved the enforced model as the user's selection and retained theirs.
        UserDefaults.standard.set(["transient-engine": "small", "second-engine": ""], forKey: UserDefaultsKeys.managedTranscriptionModelRetention)
        let engine = TransientPairEngine(savedModelId: "large")
        let second = TransientPairEngine(providerID: "second-engine", savedModelId: "large")
        let (manager, modelManager) = makeTransientManager([engine, second])

        enforce(manager, "large")
        modelManager.restoreProviderSelection()

        XCTAssertEqual(engine.savedModelId, "small", "The retained model is saved again")
        XCTAssertEqual(engine.selectedModelId, "large", "The enforced model stays in use")
        XCTAssertEqual(retainedModels(), ["second-engine": ""], "Entries of engines the pair does not use wait")

        enforce(manager, "large", engine: "second-engine")
        modelManager.restoreProviderSelection()
        XCTAssertTrue(retainedModels().isEmpty)
        XCTAssertEqual(second.savedModelId, "large", "An empty entry cannot clear the saved selection")

        manager.applySelectionPolicy(.unmanaged)
        modelManager.restoreProviderSelection()

        XCTAssertEqual(engine.selectedModelId, "small")
        XCTAssertNil(engine.transientModelId)
    }

    /// The host's pass and the bundled plugins' own code, with the plugin's saved values in a
    /// store that stands in for its `plugin.<id>.*` defaults.
    func testBundledEnginesReturnToTheirSavedSelectionWhenThePairIsRemoved() throws {
        let cases: [(id: String, providerId: String, users: String, enforced: String, make: () -> TranscriptionEnginePlugin)] = [
            ("com.typewhisper.parakeet", "parakeet", "parakeet-tdt-0.6b-v2", "parakeet-tdt-0.6b-v3", {
                let plugin = ParakeetPlugin()
                plugin.restoresModelOnActivate = false
                return plugin
            }),
            ("com.typewhisper.whisperkit", "whisper", "openai_whisper-tiny", "openai_whisper-large-v3_turbo", { WhisperKitPlugin() }),
        ]
        for testCase in cases {
            for saved in [nil, testCase.users] {
                let host = PairPluginHost(directory: directory, defaults: saved.map { ["selectedModel": $0] } ?? [:])
                let manager = PluginManager(appSupportDirectory: directory)
                PluginManager.shared = manager
                func launch() -> TranscriptionEnginePlugin {
                    let plugin = testCase.make()
                    plugin.activate(host: host)
                    manager.loadedPlugins = [loaded(plugin, id: testCase.id, locality: "local", categories: ["transcription"])]
                    return plugin
                }
                var plugin = launch()
                let modelManager = ModelManagerService()
                modelManager.selectProvider(testCase.providerId)

                manager.applySelectionPolicy(ManagedSelectionPolicy(
                    enforcedTranscription: ManagedSelectionPair(providerId: testCase.id, modelId: testCase.enforced)
                ))
                modelManager.restoreProviderSelection()
                XCTAssertEqual(plugin.selectedModelId, testCase.enforced, testCase.id)

                // A relaunch while the profile is installed applies the model again.
                plugin.deactivate()
                plugin = launch()
                XCTAssertEqual(plugin.selectedModelId, saved, "\(testCase.id): the enforced model was saved")
                ModelManagerService().restoreProviderSelection()
                XCTAssertEqual(plugin.selectedModelId, testCase.enforced, testCase.id)

                manager.applySelectionPolicy(.unmanaged)
                ModelManagerService().restoreProviderSelection()

                XCTAssertEqual(plugin.selectedModelId, saved, testCase.id)
                XCTAssertEqual(host.value(forKey: "selectedModel"), saved, testCase.id)
                XCTAssertNil(host.value(forKey: "loadedModel"), testCase.id)
                XCTAssertTrue(retainedModels().isEmpty, testCase.id)
                plugin.deactivate()
            }
        }
    }

    private func makeTransientManager(_ engines: [TransientPairEngine]) -> (PluginManager, ModelManagerService) {
        let manager = PluginManager(appSupportDirectory: directory)
        let main = engines[0]
        main.additionalEngines = Array(engines.dropFirst())
        manager.loadedPlugins = [loaded(main, id: TransientPairEngine.pluginId, locality: "local", categories: ["transcription"])]
        PluginManager.shared = manager
        let modelManager = ModelManagerService()
        modelManager.selectProvider(main.providerId)
        return (manager, modelManager)
    }

    private func enforce(_ manager: PluginManager, _ modelId: String, engine: String = "transient-engine") {
        manager.applySelectionPolicy(ManagedSelectionPolicy(
            enforcedTranscription: ManagedSelectionPair(providerId: "\(TransientPairEngine.pluginId):\(engine)", modelId: modelId)
        ))
    }

    private func retainedModels() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: UserDefaultsKeys.managedTranscriptionModelRetention) as? [String: String] ?? [:]
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

    init(providerID: String, models: [String], selectedModelId: String?) {
        self.providerID = providerID
        self.models = models
        self.selectedModelId = selectedModelId
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

private final class CatalogPairEngine: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.pair-catalog"
    static let pluginName = "Catalog Pair Engine"
    private(set) var selectedModelId: String?

    required override init() {}

    var providerId: String { "catalog-engine" }
    var providerDisplayName: String { "Catalog Engine" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [] }
    var availableModels: [PluginModelInfo] { ["small", "large"].map { PluginModelInfo(id: $0, displayName: $0) } }
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

/// Stands in for Parakeet and WhisperKit: `savedModelId` is the selection the plugin saves for the user.
private final class TransientPairEngine: NSObject, TransientModelSelectionProviding, AdditionalTranscriptionEnginesProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.pair-transient"
    static let pluginName = "Transient Pair Engine"

    private let providerID: String
    private let transient = PluginTransientModelSelection()
    var savedModelId: String?
    var additionalEngines: [TransientPairEngine] = []
    private(set) var savedSelections: [String] = []
    private(set) var beginCount = 0
    private(set) var restoreRequests = 0

    init(providerID: String = "transient-engine", savedModelId: String?) {
        self.providerID = providerID
        self.savedModelId = savedModelId
    }

    required override init() {
        providerID = "transient-engine"
    }

    var providerId: String { providerID }
    var providerDisplayName: String { providerID }
    var isConfigured: Bool { false }
    var transcriptionModels: [PluginModelInfo] { ["small", "large"].map { PluginModelInfo(id: $0, displayName: $0) } }
    var additionalTranscriptionEngines: [any TranscriptionEnginePlugin] { additionalEngines }
    var supportsTranslation: Bool { false }
    var selectedModelId: String? { transient.modelId ?? savedModelId }
    var transientModelId: String? { transient.modelId }

    func activate(host: HostServices) {}
    func deactivate() { transient.end() }

    func selectModel(_ modelId: String) {
        savedSelections.append(modelId)
        savedModelId = modelId
    }

    func beginTransientModelSelection(_ modelId: String) {
        guard transcriptionModels.contains(where: { $0.id == modelId }) else { return }
        beginCount += 1
        transient.begin(modelId)
    }

    func endTransientModelSelection() {
        transient.end()
    }

    @objc func triggerRestoreModel() {
        restoreRequests += 1
    }

    @objc(triggerRestoreModelForModel:)
    func triggerRestoreModel(forModel modelId: NSString?) {
        restoreRequests += 1
    }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok", detectedLanguage: language)
    }
}

/// Stands in for the host services of a bundled plugin; nothing reaches the keychain or real defaults.
private final class PairPluginHost: HostServices, HostModelLifecyclePolicyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var defaults: [String: Any]
    let pluginDataDirectory: URL
    let eventBus: EventBusProtocol = PairPluginEventBus()
    var activeAppBundleId: String? { nil }
    var activeAppName: String? { nil }
    var availableRuleNames: [String] { [] }
    var shouldRestoreLoadedModelsPassively: Bool { false }

    init(directory: URL, defaults: [String: Any]) {
        pluginDataDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.defaults = defaults
    }

    func value(forKey key: String) -> String? {
        userDefault(forKey: key) as? String
    }

    func storeSecret(key: String, value: String) throws {}
    func loadSecret(key: String) -> String? { nil }
    func userDefault(forKey key: String) -> Any? { lock.withLock { defaults[key] } }
    func setUserDefault(_ value: Any?, forKey key: String) { lock.withLock { defaults[key] = value } }
    func notifyCapabilitiesChanged() {}
    func setStreamingDisplayActive(_ active: Bool) {}
}

private final class PairPluginEventBus: EventBusProtocol, @unchecked Sendable {
    @discardableResult
    func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID { UUID() }
    func unsubscribe(id: UUID) {}
}
