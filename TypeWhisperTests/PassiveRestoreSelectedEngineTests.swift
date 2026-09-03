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

        // No selection recorded: conservative, keep the previous behaviour.
        _ = selectEngine(nil)
        XCTAssertTrue(manager.backsSelectedTranscriptionEngine(plugin),
                      "an absent selection is not evidence that this plugin is unselected")

        _ = selectEngine("")
        XCTAssertTrue(manager.backsSelectedTranscriptionEngine(plugin),
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
    func testSelectionRestoredAfterActivationIsHonoured() {
        var host: HostServicesImpl?
        withSelection(nil) {
            host = liveHost(exposing: ["qwen3"])
            XCTAssertTrue(host!.shouldRestoreLoadedModelsPassively,
                          "no selection recorded yet: conservative, previous behaviour")
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
