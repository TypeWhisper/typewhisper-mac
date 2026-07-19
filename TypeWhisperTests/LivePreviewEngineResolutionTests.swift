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

    func testAutoUnloadedLocalEngineWithPersistedSelectionIsRestorable() {
        // Error class: rejecting an installed local preview engine whose model
        // was AUTO-UNLOADED (isConfigured == false, canPrepareForTranscription
        // == false for non-Apple engines) even though its persisted model
        // selection restores at session start via triggerRestoreModel — which
        // silently re-routed the preview to the metered dictation engine
        // (review finding on #943).
        XCTAssertTrue(
            DictationViewModel.engineIsReadyOrRestorableForPreview(
                authAvailable: true,
                isConfigured: false,
                selectedModelId: "parakeet-tdt-0.6b-v3",
                canPrepare: false
            )
        )
    }

    func testConfiguredEngineIsReady() {
        XCTAssertTrue(
            DictationViewModel.engineIsReadyOrRestorableForPreview(
                authAvailable: true,
                isConfigured: true,
                selectedModelId: nil,
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
                selectedModelId: nil,
                canPrepare: true
            )
        )
    }

    func testNeverConfiguredEngineIsUnavailable() {
        XCTAssertFalse(
            DictationViewModel.engineIsReadyOrRestorableForPreview(
                authAvailable: true,
                isConfigured: false,
                selectedModelId: nil,
                canPrepare: false
            )
        )
    }

    func testAuthUnavailableRejectsEvenConfiguredEngines() {
        XCTAssertFalse(
            DictationViewModel.engineIsReadyOrRestorableForPreview(
                authAvailable: false,
                isConfigured: true,
                selectedModelId: "some-model",
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
