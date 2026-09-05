import XCTest
import SwiftUI
@testable import TypeWhisper
@testable import TypeWhisperPluginSDK

/// Passive startup restore must not load a model for an engine the user has not
/// selected (#1018).
///
/// *** THESE TESTS ASSERT THAT A RESTORE IS NOT SPAWNED, NOT THAT A PREDICATE
/// RETURNS FALSE. *** An earlier fix for this issue shipped with six passing tests
/// over a no-op, because every one of them asserted a predicate's return value.
/// The stub below mirrors the real shape used by the local-model plugins, e.g.
/// Qwen3Plugin.activate:
///
///     if shouldRestoreLoadedModelsPassively {
///         Task { await restoreLoadedModel(allowDownloads: false) }
///     }
///
/// so `didSpawnRestore` is the observable this issue is actually about.
final class PassiveRestoreSelectedEngineTests: XCTestCase {

    /// A local-model transcription plugin, reduced to the one behaviour under test.
    final class RestoreRecordingPlugin: TranscriptionEnginePlugin, @unchecked Sendable {
        static let pluginId = "stub.local.engine"
        static let pluginName = "Stub Local Engine"

        private let engineId: String
        private(set) var didSpawnRestore = false

        init() { self.engineId = "qwen3" }
        init(engineId: String) { self.engineId = engineId }

        var providerId: String { engineId }
        var providerDisplayName: String { "Stub" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [] }
        var selectedModelId: String? { nil }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }
        var supportsStreaming: Bool { false }
        var supportedLanguages: [String] { [] }

        func activate(host: HostServices) {
            // The exact shape every shipped local-model plugin uses.
            if let policyHost = host as? HostModelLifecyclePolicyProviding,
               policyHost.shouldRestoreLoadedModelsPassively {
                didSpawnRestore = true
            }
        }

        func deactivate() {}

        func transcribe(audio: AudioData, language: String?, translate: Bool,
                        prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "")
        }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?,
                        onProgress: @Sendable @escaping (String) -> Bool) async throws
            -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "")
        }
    }

    private func host(backsSelected: Bool) -> HostServicesImpl {
        // A constant predicate, for the cases that are not about selection CHANGING.
        HostServicesImpl(
            pluginId: "stub.local.engine",
            eventBus: EventBus.shared,
            ruleNamesProvider: { [] },
            workflowProvider: { [] },
            backsSelectedTranscriptionEngine: { backsSelected }
        )
    }

    private var savedPolicy: Any?

    override func setUp() {
        super.setUp()
        savedPolicy = UserDefaults.standard.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        // 0 is the UI's "Never", the only policy under which passive restore runs
        // at all. Every assertion below is therefore made in the ONE configuration
        // where a restore is actually possible; anywhere else they would pass
        // vacuously.
        UserDefaults.standard.set(0, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
    }

    override func tearDown() {
        if let savedPolicy {
            UserDefaults.standard.set(savedPolicy, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        }
        super.tearDown()
    }

    /// THE POSITIVE CONTROL, and it is not optional. Without it, the suppression
    /// test below cannot be distinguished from a stub that never restores at all.
    func testPluginBackingTheSelectedEngineDoesSpawnARestore() {
        XCTAssertTrue(
            ModelAutoUnloadPolicy.shouldRestoreLoadedModelsPassively(),
            "precondition: the policy must permit restore, or this proves nothing"
        )
        let plugin = RestoreRecordingPlugin(engineId: "qwen3")
        plugin.activate(host: host(backsSelected: true))
        XCTAssertTrue(plugin.didSpawnRestore, "the selected engine must still restore")
    }

    /// The defect: a model loaded for an engine the user never selected.
    func testPluginNotBackingTheSelectedEngineDoesNotSpawnARestore() {
        let plugin = RestoreRecordingPlugin(engineId: "qwen3")
        plugin.activate(host: host(backsSelected: false))
        XCTAssertFalse(
            plugin.didSpawnRestore,
            "an unselected engine must not restore its model at launch"
        )
    }

    /// The policy still wins. With auto-unload NOT "Never", nothing restores
    /// passively regardless of selection, which is pre-existing behaviour.
    func testAPolicyOtherThanNeverStillSuppressesEveryone() {
        UserDefaults.standard.set(300, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        let plugin = RestoreRecordingPlugin(engineId: "qwen3")
        plugin.activate(host: host(backsSelected: true))
        XCTAssertFalse(plugin.didSpawnRestore)
    }

    /// The gate itself, at the host level.
    func testHostGateCombinesPolicyAndSelection() {
        XCTAssertTrue(host(backsSelected: true).shouldRestoreLoadedModelsPassively)
        XCTAssertFalse(host(backsSelected: false).shouldRestoreLoadedModelsPassively)
    }

    // MARK: - The PluginManager computation, end to end
    //
    // A cross-family review noted, correctly, that every test above INJECTS
    // `backsSelected` and so never exercises the provider-id computation that
    // decides it. That is the half where the manifest-id-versus-provider-id
    // mistake would live, so it gets its own coverage rather than static tracing.

    private func selectEngine(_ providerId: String?) -> Any? {
        let saved = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedEngine)
        if let providerId {
            UserDefaults.standard.set(providerId, forKey: UserDefaultsKeys.selectedEngine)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedEngine)
        }
        return saved
    }

    private func restoreEngine(_ saved: Any?) {
        if let saved {
            UserDefaults.standard.set(saved, forKey: UserDefaultsKeys.selectedEngine)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedEngine)
        }
    }

    @MainActor
    func testManagerComputesBackingFromProviderIdNotManifestId() {
        let manager = PluginManager()
        // The manifest id and the providerId differ ON PURPOSE. `selectedEngine`
        // stores a providerId, so a comparison against the manifest id would
        // silently suppress a legitimately selected engine.
        let plugin = LoadedPlugin(
            manifest: PluginManifest(
                id: "com.example.some-manifest-id",
                name: "Stub Local Engine",
                version: "1.0.0",
                principalClass: "RestoreRecordingPlugin"
            ),
            instance: RestoreRecordingPlugin(engineId: "qwen3"),
            bundle: Bundle.main,
            sourceURL: URL(fileURLWithPath: "/tmp/stub"),
            isEnabled: true
        )

        let saved = selectEngine("qwen3")
        XCTAssertTrue(manager.backsSelectedTranscriptionEngine(plugin),
                      "the SELECTED engine must back, matched by providerId")

        _ = selectEngine("groq")
        XCTAssertFalse(manager.backsSelectedTranscriptionEngine(plugin),
                       "a different selected engine must not back")

        // No selection recorded: SUPPRESS. Nothing is selected, so no engine's
        // model should be restored on its behalf.
        _ = selectEngine(nil)
        XCTAssertFalse(manager.backsSelectedTranscriptionEngine(plugin),
                       "an absent selection must suppress, not permit")

        _ = selectEngine("")
        XCTAssertFalse(manager.backsSelectedTranscriptionEngine(plugin),
                       "an empty selection is treated the same as absent")

        restoreEngine(saved)
    }

    /// A host constructed without the new argument keeps the old behaviour, so no
    /// existing call site changes meaning.
    func testDefaultConstructionPreservesPreviousBehaviour() {
        let legacy = HostServicesImpl(
            pluginId: "stub.local.engine",
            eventBus: EventBus.shared,
            ruleNamesProvider: { [] }
        )
        XCTAssertTrue(legacy.backsSelectedTranscriptionEngine)
        XCTAssertTrue(legacy.shouldRestoreLoadedModelsPassively)
    }
}

// MARK: - The selection is read LIVE, not captured
//
// Requested by the maintainer on PR #1270, and the finding was right: the first
// version captured the answer once at host construction. `selectProvider` writes
// `selectedEngine` at any time and notifies no existing host, and at startup
// `restoreProviderSelection()` runs AFTER `scanAndLoadPlugins()` (three lines apart
// in ServiceContainer), so a captured value can be stale before launch finishes.

extension PassiveRestoreSelectedEngineTests {

    private func liveHost(exposing exposed: Set<String>) -> HostServicesImpl {
        HostServicesImpl(
            pluginId: "stub.local.engine",
            eventBus: EventBus.shared,
            ruleNamesProvider: { [] },
            workflowProvider: { [] },
            backsSelectedTranscriptionEngine: PluginManager.selectionMatcher(
                forEnginesExposedBy: exposed
            )
        )
    }

    private func withSelection(_ providerId: String?, _ body: () -> Void) {
        let saved = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedEngine)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: UserDefaultsKeys.selectedEngine)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedEngine)
            }
        }
        if let providerId {
            UserDefaults.standard.set(providerId, forKey: UserDefaultsKeys.selectedEngine)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedEngine)
        }
        body()
    }

    /// THE REGRESSION THE MAINTAINER ASKED FOR: change the selection AFTER the host
    /// exists, then check the restore path. ONE host object throughout, because the
    /// defect was that a new host is not created when the selection changes.
    func testSelectionChangeAfterHostCreationIsHonoured() {
        let host = liveHost(exposing: ["qwen3"])

        withSelection("qwen3") {
            XCTAssertTrue(host.shouldRestoreLoadedModelsPassively,
                          "selected at this moment: must restore")
            let plugin = RestoreRecordingPlugin(engineId: "qwen3")
            plugin.activate(host: host)
            XCTAssertTrue(plugin.didSpawnRestore)
        }

        // The user switches engines. The SAME host must now answer differently.
        withSelection("groq") {
            XCTAssertFalse(host.shouldRestoreLoadedModelsPassively,
                           "deselected since: must NOT restore")
            let plugin = RestoreRecordingPlugin(engineId: "qwen3")
            plugin.activate(host: host)
            XCTAssertFalse(plugin.didSpawnRestore,
                           "a host created while selected must stop restoring once deselected")
        }

        // ...and back again, so this cannot pass by latching to false.
        withSelection("qwen3") {
            XCTAssertTrue(host.shouldRestoreLoadedModelsPassively,
                          "re-selected: must restore again")
        }
    }

    /// The startup ordering specifically: activation happens BEFORE
    /// restoreProviderSelection(), so a host is built while the selection is absent
    /// and must honour the selection that arrives afterwards.
    ///
    /// ⚠️ The FIRST assertion is the one a cross-family reviewer corrected. It used to
    /// assert `true` here, on the reasoning that an unrecorded selection is not
    /// evidence a plugin is unselected. But this is precisely the window in which
    /// activation SPAWNS a restore task, and no later selection can cancel a task
    /// that already exists, so permitting here defeated the whole fix.
    func testSelectionRestoredAfterActivationIsHonoured() {
        var host: HostServicesImpl?
        withSelection(nil) {
            host = liveHost(exposing: ["qwen3"])
            XCTAssertFalse(host!.shouldRestoreLoadedModelsPassively,
                           "the unhydrated window must SUPPRESS: a task spawned here is uncancellable")
        }
        withSelection("groq") {
            XCTAssertFalse(host!.shouldRestoreLoadedModelsPassively,
                           "the selection restored after activation must be honoured")
        }
    }

    /// A plugin exposing no transcription engines is unaffected by any selection.
    func testNonTranscriptionPluginIsUnaffectedBySelection() {
        let host = liveHost(exposing: [])
        for engine in ["groq", "qwen3", ""] {
            withSelection(engine.isEmpty ? nil : engine) {
                XCTAssertTrue(host.shouldRestoreLoadedModelsPassively,
                              "no exposed engines: selection is irrelevant")
            }
        }
    }

    /// A plugin exposing SEVERAL engines backs the selection if any of them matches.
    func testMultiEnginePluginMatchesAnyExposedEngine() {
        let host = liveHost(exposing: ["qwen3", "qwen3-flash"])
        withSelection("qwen3-flash") {
            XCTAssertTrue(host.shouldRestoreLoadedModelsPassively)
        }
        withSelection("groq") {
            XCTAssertFalse(host.shouldRestoreLoadedModelsPassively)
        }
    }
}

// MARK: - The startup window, asserted on the RESTORE, not the predicate
//
// Requested by an automated reviewer on PR #1270, and the request was fair: every
// other test here asserts what the PREDICATE returns. None asserted that no restore
// TASK was spawned, which is the thing that actually cannot be undone. A predicate
// that flips after the task exists fixes nothing.

extension PassiveRestoreSelectedEngineTests {

    /// Activate while the selection is unhydrated, THEN hydrate a different one, and
    /// assert no restore was spawned at activation time.
    ///
    /// This models the real startup order: ServiceContainer runs
    /// scanAndLoadPlugins() (which activates) and only then
    /// restoreProviderSelection(), which WRITES a selection when the saved one is
    /// missing or unusable.
    func testNoRestoreIsSpawnedWhenActivatingBeforeSelectionIsHydrated() {
        let host = liveHost(exposing: ["qwen3"])
        let plugin = RestoreRecordingPlugin(engineId: "qwen3")

        // Activation happens here, with no selection yet recorded.
        withSelection(nil) {
            plugin.activate(host: host)
        }
        XCTAssertFalse(
            plugin.didSpawnRestore,
            "activation during the unhydrated window must not spawn a restore"
        )

        // restoreProviderSelection() now writes a DIFFERENT engine. The already-made
        // decision cannot be revisited, which is exactly why it had to be correct.
        withSelection("groq") {
            XCTAssertFalse(plugin.didSpawnRestore,
                           "and nothing may retroactively appear")
            XCTAssertFalse(host.shouldRestoreLoadedModelsPassively,
                           "the host now also reports the hydrated selection correctly")
        }
    }

    /// The positive half: hydrated to THIS engine before activation, a restore is
    /// spawned. Without this, the test above cannot be told apart from a stub that
    /// never restores.
    func testRestoreIsSpawnedWhenTheSelectionIsAlreadyHydratedToThisEngine() {
        let host = liveHost(exposing: ["qwen3"])
        let plugin = RestoreRecordingPlugin(engineId: "qwen3")
        withSelection("qwen3") {
            plugin.activate(host: host)
        }
        XCTAssertTrue(plugin.didSpawnRestore,
                      "the selected engine must still restore at launch")
    }
}

// MARK: - Reconciliation after activation (#1279)

@MainActor
final class PassiveRestoreReconciliationTests: XCTestCase {
    private func withManager(
        selected: String?,
        _ test: (PluginManager, ModelManagerService) async throws -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let savedSelection = defaults.object(forKey: UserDefaultsKeys.selectedEngine)
        let savedPolicy = defaults.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        let savedManager = PluginManager.shared
        let savedBus = EventBus.shared
        let directory = try TestSupport.makeTemporaryDirectory()
        defer {
            PluginManager.shared = savedManager
            EventBus.shared = savedBus
            defaults.set(savedSelection, forKey: UserDefaultsKeys.selectedEngine)
            defaults.set(savedPolicy, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            TestSupport.remove(directory)
        }
        defaults.set(selected, forKey: UserDefaultsKeys.selectedEngine)
        defaults.set(0, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        EventBus.shared = EventBus()
        let manager = PluginManager(appSupportDirectory: directory)
        PluginManager.shared = manager
        let modelManager = ModelManagerService()
        try await test(manager, modelManager)
    }

    private func install(_ plugin: ReconciledRestorePlugin, in manager: PluginManager) {
        let host = HostServicesImpl(
            pluginId: plugin.providerId,
            eventBus: EventBus.shared,
            ruleNamesProvider: { [] },
            backsSelectedTranscriptionEngine: PluginManager.selectionMatcher(
                forEnginesExposedBy: [plugin.providerId]
            )
        )
        plugin.activate(host: host)
        manager.loadedPlugins.append(LoadedPlugin(
            manifest: PluginManifest(id: plugin.providerId, name: plugin.providerId,
                                     version: "1.0.0", principalClass: "ReconciledRestorePlugin"),
            instance: plugin,
            bundle: Bundle.main,
            sourceURL: manager.pluginsDirectory.appendingPathComponent(plugin.providerId),
            isEnabled: true
        ))
    }

    func testMissingStartupSelectionRestoresFallbackAfterActivationDeclined() async throws {
        try await withManager(selected: "missing") { manager, modelManager in
            let fallback = ReconciledRestorePlugin(id: "local")
            install(fallback, in: manager)
            XCTAssertEqual(fallback.restores, 0)
            modelManager.restoreProviderSelection()
            XCTAssertEqual(modelManager.selectedProviderId, "local")
            XCTAssertEqual(fallback.restores, 1)
            XCTAssertEqual(fallback.selectionAtRestore, "local")
        }
    }

    func testAbsentStartupSelectionRestoresChosenLocalEngine() async throws {
        try await withManager(selected: nil) { manager, modelManager in
            let fallback = ReconciledRestorePlugin(id: "local")
            install(fallback, in: manager)
            XCTAssertEqual(fallback.restores, 0)
            modelManager.restoreProviderSelection()
            XCTAssertEqual(fallback.restores, 1)
        }
    }

    func testObservedRemovalAndClearedSelectionRestoreFallbackInSession() async throws {
        try await withManager(selected: "removed") { manager, modelManager in
            let removed = ReconciledRestorePlugin(id: "removed")
            let fallback = ReconciledRestorePlugin(id: "local")
            install(removed, in: manager)
            install(fallback, in: manager)
            modelManager.restoreProviderSelection()
            XCTAssertEqual(fallback.restores, 0)
            modelManager.observePluginManager()
            // With no configured alternative, disable/uninstall clears the selection
            // before publishing the changed plugin list. Exercise that observer route.
            modelManager.clearProviderSelection()
            removed.deactivate()
            manager.loadedPlugins.removeFirst()
            await drainMainQueue()
            XCTAssertEqual(modelManager.selectedProviderId, "local")
            XCTAssertEqual(fallback.restores, 1)
        }
    }

    func testDisablingSelectedPluginThroughManagerRestoresLocalFallback() async throws {
        let container = ServiceContainer.shared
        let manager = container.pluginManager
        let modelManager = container.modelManagerService
        let savedManager = PluginManager.shared
        let savedPlugins = manager.loadedPlugins
        let savedSelection = modelManager.selectedProviderId
        let defaults = UserDefaults.standard
        let savedPersistedSelection = defaults.object(forKey: UserDefaultsKeys.selectedEngine)
        let savedPolicy = defaults.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        let savedEnabled = defaults.object(forKey: "plugin.removed.enabled")
        defer {
            defaults.set(savedPersistedSelection, forKey: UserDefaultsKeys.selectedEngine)
            defaults.set(savedPolicy, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            defaults.set(savedEnabled, forKey: "plugin.removed.enabled")
            PluginManager.shared = savedManager
        }
        PluginManager.shared = manager
        manager.loadedPlugins = []
        defaults.set(0, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        modelManager.selectProvider("removed")
        let removed = ReconciledRestorePlugin(id: "removed")
        let fallback = ReconciledRestorePlugin(id: "local")
        install(removed, in: manager)
        install(fallback, in: manager)
        // A valid bundle lets disable convert the runtime to an unloaded placeholder.
        manager.loadedPlugins[0] = LoadedPlugin(
            manifest: manager.loadedPlugins[0].manifest, instance: removed,
            bundle: Bundle.main, sourceURL: Bundle.main.bundleURL, isEnabled: true
        )
        XCTAssertEqual(fallback.restores, 0)
        manager.setPluginEnabled("removed", enabled: false)
        XCTAssertNil(modelManager.selectedProviderId)
        await drainMainQueue()
        XCTAssertEqual(modelManager.selectedProviderId, "local")
        XCTAssertEqual(fallback.restores, 1)
        XCTAssertFalse(manager.loadedPlugins[0].isEnabled)
        XCTAssertFalse(manager.loadedPlugins[0].isRuntimeLoaded)

        defaults.set(savedPolicy, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        manager.loadedPlugins = savedPlugins
        await drainMainQueue()
        if let savedSelection { modelManager.selectProvider(savedSelection) }
        else { modelManager.clearProviderSelection() }
        // The shared container survives this test. Drain its queued observer work
        // before restoring the previous (possibly nil) global plugin manager.
        await drainMainQueue()
    }

    func testAuthenticationBecomingAvailableRetriesReconciliation() async throws {
        try await withManager(selected: nil) { manager, modelManager in
            let plugin = ReconciledRestorePlugin(id: "local")
            plugin.authAvailable = false
            install(plugin, in: manager)
            modelManager.selectProvider("local")
            XCTAssertEqual(plugin.requests, 0)

            plugin.authAvailable = true
            modelManager.restoreProviderSelection()
            XCTAssertEqual(plugin.requests, 1)
            XCTAssertEqual(plugin.restores, 1)
        }
    }

    func testReadinessChangesDoNotRetryFailedRestore() async throws {
        try await withManager(selected: "missing") { manager, modelManager in
            let fallback = ReconciledRestorePlugin(id: "local")
            install(fallback, in: manager)
            modelManager.observePluginManager()
            modelManager.restoreProviderSelection()
            let requests = fallback.requests
            for _ in 0..<5 {
                manager.notifyPluginStateChanged()
            }
            await drainMainQueue()
            XCTAssertEqual(fallback.requests, requests)
            XCTAssertEqual(fallback.restores, 1)
        }
    }

    func testSelectionSwitchNotifiesNewEngineAndRuntimeReplacementNotifiesAgain() async throws {
        try await withManager(selected: "one") { manager, modelManager in
            let one = ReconciledRestorePlugin(id: "one")
            let two = ReconciledRestorePlugin(id: "two")
            install(one, in: manager)
            install(two, in: manager)
            modelManager.restoreProviderSelection()
            modelManager.selectProvider("two")
            XCTAssertEqual(two.restores, 1)
            let requests = two.requests
            modelManager.selectProvider("two")
            XCTAssertEqual(two.requests, requests)
            manager.loadedPlugins.removeLast()
            let replacement = ReconciledRestorePlugin(id: "two")
            install(replacement, in: manager)
            let activationRequests = replacement.requests
            modelManager.restoreProviderSelection()
            XCTAssertEqual(replacement.requests, activationRequests + 1)
        }
    }

    func testConfiguredCloudFallbackWinsAndTimedPolicyDoesNotRestoreLocalModel() async throws {
        try await withManager(selected: "missing") { manager, modelManager in
            let local = ReconciledRestorePlugin(id: "local")
            let cloud = ReconciledRestorePlugin(id: "cloud", configured: true)
            install(local, in: manager)
            install(cloud, in: manager)
            modelManager.restoreProviderSelection()
            XCTAssertEqual(modelManager.selectedProviderId, "cloud")
            XCTAssertEqual(local.restores, 0)
            UserDefaults.standard.set(600, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            modelManager.selectProvider("local")
            XCTAssertEqual(local.restores, 0)
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class ReconciledRestorePlugin: TranscriptionEnginePlugin, PassiveModelRestoreProviding, PluginAuthRoleStatusProviding, @unchecked Sendable {
    static let pluginId = "test.reconciled.restore"
    static let pluginName = "Reconciled Restore"
    let providerId: String
    let isConfigured: Bool
    var authAvailable = true
    func authStatus(for role: PluginAuthRole) -> PluginAuthRoleStatus {
        authAvailable ? .available : .unavailable(reason: "Sign in required")
    }
    private var host: (any HostServices)?
    private(set) var requests = 0
    private(set) var restores = 0
    private(set) var selectionAtRestore: String?

    init() { providerId = "local"; isConfigured = false }
    init(id: String, configured: Bool = false) { providerId = id; isConfigured = configured }
    func activate(host: any HostServices) {
        self.host = host
        if host.shouldRestoreLoadedModelsPassively { requestPassiveModelRestore() }
    }
    func deactivate() { host = nil }
    func requestPassiveModelRestore() {
        requests += 1
        guard host?.shouldRestoreLoadedModelsPassively == true, !isConfigured else { return }
        restores += 1
        selectionAtRestore = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine)
        // Remain unconfigured, like a missing asset or a failed load.
    }
    var providerDisplayName: String { providerId }
    var transcriptionModels: [PluginModelInfo] { [] }
    var selectedModelId: String? { nil }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { false }
    var supportedLanguages: [String] { [] }
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "")
    }
}
