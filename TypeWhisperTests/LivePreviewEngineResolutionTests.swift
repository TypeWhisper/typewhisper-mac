import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class LivePreviewEngineResolutionTests: XCTestCase {
    func testNoPreferenceFollowsDictationEngine() {
        XCTAssertEqual(
            DictationViewModel.resolvePreviewEngine(
                preferredPreviewEngineId: nil,
                dictationEngineOverrideId: nil,
                selectedProviderId: "groq",
                isEngineAvailable: { _ in true }
            ),
            .followsDictationEngine
        )
    }

    func testNoPreferenceKeepsProfileEngineOverride() {
        XCTAssertEqual(
            DictationViewModel.resolvePreviewEngine(
                preferredPreviewEngineId: nil,
                dictationEngineOverrideId: "profile-engine",
                selectedProviderId: "groq",
                isEngineAvailable: { _ in true }
            ),
            .followsDictationEngine
        )
    }

    func testEmptyPreferenceFollowsDictationEngine() {
        XCTAssertEqual(
            DictationViewModel.resolvePreviewEngine(
                preferredPreviewEngineId: "",
                dictationEngineOverrideId: nil,
                selectedProviderId: "groq",
                isEngineAvailable: { _ in true }
            ),
            .followsDictationEngine
        )
    }

    func testUnavailablePreferenceSuppressesPreviewInsteadOfMeteredFallback() {
        // Error class: silently falling back to the (possibly metered cloud)
        // dictation engine when the explicitly selected preview engine cannot
        // run — the preview must be suppressed instead (review finding on #943).
        XCTAssertEqual(
            DictationViewModel.resolvePreviewEngine(
                preferredPreviewEngineId: "parakeet",
                dictationEngineOverrideId: nil,
                selectedProviderId: "groq",
                isEngineAvailable: { _ in false }
            ),
            .previewUnavailable
        )
    }

    func testDistinctAvailablePreferenceWins() {
        XCTAssertEqual(
            DictationViewModel.resolvePreviewEngine(
                preferredPreviewEngineId: "speechanalyzer",
                dictationEngineOverrideId: nil,
                selectedProviderId: "groq",
                isEngineAvailable: { $0 == "speechanalyzer" }
            ),
            .overrideEngine("speechanalyzer")
        )
    }

    func testPreferenceMatchingSelectedProviderStaysOnDictationPath() {
        // Following the dictation path (rather than an override) keeps the cloud
        // model override flowing on the unchanged prior-behavior code path.
        XCTAssertEqual(
            DictationViewModel.resolvePreviewEngine(
                preferredPreviewEngineId: "groq",
                dictationEngineOverrideId: nil,
                selectedProviderId: "groq",
                isEngineAvailable: { _ in true }
            ),
            .followsDictationEngine
        )
    }

    func testPreferenceMatchingProfileOverrideStaysOnDictationPath() {
        XCTAssertEqual(
            DictationViewModel.resolvePreviewEngine(
                preferredPreviewEngineId: "profile-engine",
                dictationEngineOverrideId: "profile-engine",
                selectedProviderId: "groq",
                isEngineAvailable: { _ in true }
            ),
            .followsDictationEngine
        )
    }

    func testPreferenceDistinctFromProfileOverrideWins() {
        XCTAssertEqual(
            DictationViewModel.resolvePreviewEngine(
                preferredPreviewEngineId: "speechanalyzer",
                dictationEngineOverrideId: "profile-engine",
                selectedProviderId: "groq",
                isEngineAvailable: { _ in true }
            ),
            .overrideEngine("speechanalyzer")
        )
    }

    // MARK: - Ready-or-restorable predicate

    func testAutoUnloadedLocalEngineWithPersistedLoadedModelIsRestorable() throws {
        // Error class: rejecting an installed local preview engine whose model
        // was AUTO-UNLOADED even though its persisted loadedModel state restores
        // at session start via triggerRestoreModel — which silently re-routed
        // the preview to the metered dictation engine (review finding on #943).
        let plugin = LivePreviewReadinessPlugin(isConfigured: false)
        let modelManager = try installReadinessPlugin(plugin)
        preserveStandardDefault(
            key: LivePreviewReadinessPlugin.loadedModelDefaultsKey,
            value: "restorable-model"
        )

        XCTAssertTrue(modelManager.canPrepareForTranscription(plugin))
    }

    func testManuallyUnloadedEngineIsNotRestorable() throws {
        // Error class: treating a retained model SELECTION as restorable after a
        // MANUAL unload — plugins keep selectedModel but clear the persisted
        // loadedModel default, so triggerRestoreModel is a no-op and a preview
        // session can never become ready; the engine must resolve as
        // unavailable (suppressed preview), not as an override that fails
        // every fallback poll (second-round review finding on #943).
        let plugin = LivePreviewReadinessPlugin(
            isConfigured: false,
            selectedModelId: "retained-selection"
        )
        let modelManager = try installReadinessPlugin(plugin)
        preserveStandardDefault(
            key: LivePreviewReadinessPlugin.loadedModelDefaultsKey,
            value: nil
        )

        XCTAssertFalse(modelManager.canPrepareForTranscription(plugin))
    }

    func testHasPersistedRestorableModelReadsPluginScopedKey() {
        let suite = "LivePreviewEngineResolutionTests-restore"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        XCTAssertFalse(
            TranscriptionEngineReadiness.hasPersistedRestorableModel(
                pluginId: "com.typewhisper.parakeet", defaults: defaults
            )
        )
        defaults.set("parakeet-tdt-0.6b-v3", forKey: "plugin.com.typewhisper.parakeet.loadedModel")
        XCTAssertTrue(
            TranscriptionEngineReadiness.hasPersistedRestorableModel(
                pluginId: "com.typewhisper.parakeet", defaults: defaults
            )
        )
        defaults.removePersistentDomain(forName: suite)
    }

    /// `HostServicesImpl` writes `plugin.<manifest.id>.loadedModel`, and a plugin's
    /// manifest id is NOT its engine `providerId` ("com.typewhisper.parakeet" vs
    /// "parakeet"). Looking the key up under the provider id silently never matches,
    /// which would make every auto-unloaded local preview engine resolve as
    /// unavailable. Lock the distinction so the lookup cannot regress to a provider id.
    func testPersistedRestorableModelUsesManifestIdInsteadOfProviderId() throws {
        let plugin = LivePreviewReadinessPlugin(isConfigured: false)
        let modelManager = try installReadinessPlugin(plugin)
        preserveStandardDefaults(keys: [
            LivePreviewReadinessPlugin.loadedModelDefaultsKey,
            LivePreviewReadinessPlugin.providerLoadedModelDefaultsKey
        ])

        UserDefaults.standard.set(
            "restorable-model",
            forKey: LivePreviewReadinessPlugin.providerLoadedModelDefaultsKey
        )
        XCTAssertFalse(
            modelManager.canPrepareForTranscription(plugin),
            "a providerId-shaped key must not make the engine restorable"
        )

        UserDefaults.standard.set(
            "restorable-model",
            forKey: LivePreviewReadinessPlugin.loadedModelDefaultsKey
        )
        XCTAssertTrue(
            modelManager.canPrepareForTranscription(plugin),
            "the owning plugin's manifest-id key must make the engine restorable"
        )
    }

    func testConfiguredEngineIsReady() throws {
        let plugin = LivePreviewReadinessPlugin(isConfigured: true)
        let modelManager = try installReadinessPlugin(plugin)
        preserveStandardDefault(
            key: LivePreviewReadinessPlugin.loadedModelDefaultsKey,
            value: nil
        )

        XCTAssertTrue(modelManager.canPrepareForTranscription(plugin))
    }

    func testAppleCatalogGraceStillApplies() {
        // Apple Speech may have no selected model yet still be preparable from
        // its catalog — canPrepareForTranscription's existing grace is preserved.
        let plugin = LivePreviewReadinessPlugin(
            providerId: AppleSpeechModelSelection.providerId,
            isConfigured: false,
            availableModels: [PluginModelInfo(id: "speechanalyzer-en_US", displayName: "English")]
        )
        let modelManager = ModelManagerService()

        XCTAssertTrue(modelManager.canPrepareForTranscription(plugin))
    }

    func testNeverConfiguredEngineIsUnavailable() throws {
        let plugin = LivePreviewReadinessPlugin(isConfigured: false)
        let modelManager = try installReadinessPlugin(plugin)
        preserveStandardDefault(
            key: LivePreviewReadinessPlugin.loadedModelDefaultsKey,
            value: nil
        )

        XCTAssertFalse(modelManager.canPrepareForTranscription(plugin))
    }

    func testAuthUnavailableRejectsEvenConfiguredEngines() throws {
        let plugin = LivePreviewReadinessPlugin(
            isConfigured: true,
            authAvailable: false
        )
        let modelManager = try installReadinessPlugin(plugin)
        preserveStandardDefault(
            key: LivePreviewReadinessPlugin.loadedModelDefaultsKey,
            value: "restorable-model"
        )

        XCTAssertFalse(modelManager.canPrepareForTranscription(plugin))
    }

    // MARK: - Persistence

    func testLoadPersistRoundTrip() {
        let defaults = UserDefaults(suiteName: "LivePreviewEngineResolutionTests")!
        defaults.removePersistentDomain(forName: "LivePreviewEngineResolutionTests")

        XCTAssertNil(DictationViewModel.loadLivePreviewEngineId(defaults: defaults))

        DictationViewModel.persistLivePreviewEngineId("speechanalyzer", defaults: defaults)
        XCTAssertEqual(DictationViewModel.loadLivePreviewEngineId(defaults: defaults), "speechanalyzer")

        DictationViewModel.persistLivePreviewEngineId(nil, defaults: defaults)
        XCTAssertNil(DictationViewModel.loadLivePreviewEngineId(defaults: defaults))

        DictationViewModel.persistLivePreviewEngineId("", defaults: defaults)
        XCTAssertNil(DictationViewModel.loadLivePreviewEngineId(defaults: defaults))

        defaults.removePersistentDomain(forName: "LivePreviewEngineResolutionTests")
    }

    private func installReadinessPlugin(
        _ plugin: LivePreviewReadinessPlugin
    ) throws -> ModelManagerService {
        let previousPluginManager = PluginManager.shared
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock {
            PluginManager.shared = previousPluginManager
            TestSupport.remove(appSupportDirectory)
        }

        let pluginManager = PluginManager(appSupportDirectory: appSupportDirectory)
        pluginManager.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: LivePreviewReadinessPlugin.pluginId,
                    name: LivePreviewReadinessPlugin.pluginName,
                    version: "1.0.0",
                    principalClass: "LivePreviewReadinessPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]
        PluginManager.shared = pluginManager
        return ModelManagerService()
    }

    private func preserveStandardDefault(key: String, value: Any?) {
        preserveStandardDefaults(keys: [key])
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private func preserveStandardDefaults(keys: [String]) {
        let originals = Dictionary(
            uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        )
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        addTeardownBlock {
            for (key, value) in originals {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }
}

private final class LivePreviewReadinessPlugin: NSObject, TranscriptionModelCatalogProviding, PluginAuthRoleStatusProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.live-preview-readiness"
    static let pluginName = "Live Preview Readiness Mock"
    static let defaultProviderId = "live-preview-readiness"
    static let loadedModelDefaultsKey = "plugin.\(pluginId).loadedModel"
    static let providerLoadedModelDefaultsKey = "plugin.\(defaultProviderId).loadedModel"

    let providerId: String
    let isConfigured: Bool
    let selectedModelId: String?
    let availableModels: [PluginModelInfo]
    let authAvailable: Bool
    let providerDisplayName = "Live Preview Readiness"
    let transcriptionModels: [PluginModelInfo] = []
    let supportsTranslation = false

    init(
        providerId: String = defaultProviderId,
        isConfigured: Bool,
        selectedModelId: String? = nil,
        availableModels: [PluginModelInfo] = [],
        authAvailable: Bool = true
    ) {
        self.providerId = providerId
        self.isConfigured = isConfigured
        self.selectedModelId = selectedModelId
        self.availableModels = availableModels
        self.authAvailable = authAvailable
        super.init()
    }

    required override init() {
        self.providerId = Self.defaultProviderId
        self.isConfigured = false
        self.selectedModelId = nil
        self.availableModels = []
        self.authAvailable = true
        super.init()
    }

    func activate(host: HostServices) {}
    func deactivate() {}
    func selectModel(_ modelId: String) {}

    func authStatus(for role: PluginAuthRole) -> PluginAuthRoleStatus {
        role == .transcription && !authAvailable
            ? .unavailable(reason: "Transcription authentication is unavailable.")
            : .available
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "preview", detectedLanguage: language)
    }
}
