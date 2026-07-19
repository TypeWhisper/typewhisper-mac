import XCTest
@testable import TypeWhisper

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

    func testAutoUnloadedLocalEngineWithPersistedLoadedModelIsRestorable() {
        // Error class: rejecting an installed local preview engine whose model
        // was AUTO-UNLOADED (isConfigured == false, canPrepareForTranscription
        // == false for non-Apple engines) even though its persisted loadedModel
        // state restores at session start via triggerRestoreModel — which
        // silently re-routed the preview to the metered dictation engine
        // (review finding on #943).
        XCTAssertTrue(
            DictationViewModel.engineIsReadyOrRestorableForPreview(
                authAvailable: true,
                isConfigured: false,
                hasPersistedRestorableModel: true,
                canPrepare: false
            )
        )
    }

    func testManuallyUnloadedEngineIsNotRestorable() {
        // Error class: treating a retained model SELECTION as restorable after a
        // MANUAL unload — plugins keep selectedModel but clear the persisted
        // loadedModel default, so triggerRestoreModel is a no-op and a preview
        // session can never become ready; the engine must resolve as
        // unavailable (suppressed preview), not as an override that fails
        // every fallback poll (second-round review finding on #943).
        XCTAssertFalse(
            DictationViewModel.engineIsReadyOrRestorableForPreview(
                authAvailable: true,
                isConfigured: false,
                hasPersistedRestorableModel: false,
                canPrepare: false
            )
        )
    }

    func testHasPersistedRestorableModelReadsPluginScopedKey() {
        let suite = "LivePreviewEngineResolutionTests-restore"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        XCTAssertFalse(
            DictationViewModel.hasPersistedRestorableModel(
                providerId: "com.typewhisper.parakeet", defaults: defaults
            )
        )
        defaults.set("parakeet-tdt-0.6b-v3", forKey: "plugin.com.typewhisper.parakeet.loadedModel")
        XCTAssertTrue(
            DictationViewModel.hasPersistedRestorableModel(
                providerId: "com.typewhisper.parakeet", defaults: defaults
            )
        )
        defaults.removePersistentDomain(forName: suite)
    }

    func testConfiguredEngineIsReady() {
        XCTAssertTrue(
            DictationViewModel.engineIsReadyOrRestorableForPreview(
                authAvailable: true,
                isConfigured: true,
                hasPersistedRestorableModel: false,
                canPrepare: true
            )
        )
    }

    func testAppleCatalogGraceStillApplies() {
        // Apple Speech may have no selected model yet still be preparable from
        // its catalog — canPrepareForTranscription's existing grace is preserved.
        XCTAssertTrue(
            DictationViewModel.engineIsReadyOrRestorableForPreview(
                authAvailable: true,
                isConfigured: false,
                hasPersistedRestorableModel: false,
                canPrepare: true
            )
        )
    }

    func testNeverConfiguredEngineIsUnavailable() {
        XCTAssertFalse(
            DictationViewModel.engineIsReadyOrRestorableForPreview(
                authAvailable: true,
                isConfigured: false,
                hasPersistedRestorableModel: false,
                canPrepare: false
            )
        )
    }

    func testAuthUnavailableRejectsEvenConfiguredEngines() {
        XCTAssertFalse(
            DictationViewModel.engineIsReadyOrRestorableForPreview(
                authAvailable: false,
                isConfigured: true,
                hasPersistedRestorableModel: true,
                canPrepare: true
            )
        )
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
}
