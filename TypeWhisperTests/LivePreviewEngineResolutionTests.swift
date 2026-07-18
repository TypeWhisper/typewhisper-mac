import XCTest
@testable import TypeWhisper

final class LivePreviewEngineResolutionTests: XCTestCase {
    func testNoPreferenceFollowsDictationEngine() {
        XCTAssertNil(
            DictationViewModel.resolvePreviewEngineOverrideId(
                preferredPreviewEngineId: nil,
                dictationEngineOverrideId: nil,
                selectedProviderId: "groq",
                isEngineAvailable: { _ in true }
            )
        )
    }

    func testNoPreferenceKeepsProfileEngineOverride() {
        XCTAssertEqual(
            DictationViewModel.resolvePreviewEngineOverrideId(
                preferredPreviewEngineId: nil,
                dictationEngineOverrideId: "profile-engine",
                selectedProviderId: "groq",
                isEngineAvailable: { _ in true }
            ),
            "profile-engine"
        )
    }

    func testEmptyPreferenceFollowsDictationEngine() {
        XCTAssertNil(
            DictationViewModel.resolvePreviewEngineOverrideId(
                preferredPreviewEngineId: "",
                dictationEngineOverrideId: nil,
                selectedProviderId: "groq",
                isEngineAvailable: { _ in true }
            )
        )
    }

    func testUnavailablePreferenceFollowsDictationEngine() {
        XCTAssertNil(
            DictationViewModel.resolvePreviewEngineOverrideId(
                preferredPreviewEngineId: "speechanalyzer",
                dictationEngineOverrideId: nil,
                selectedProviderId: "groq",
                isEngineAvailable: { _ in false }
            )
        )
    }

    func testDistinctAvailablePreferenceWins() {
        XCTAssertEqual(
            DictationViewModel.resolvePreviewEngineOverrideId(
                preferredPreviewEngineId: "speechanalyzer",
                dictationEngineOverrideId: nil,
                selectedProviderId: "groq",
                isEngineAvailable: { $0 == "speechanalyzer" }
            ),
            "speechanalyzer"
        )
    }

    func testPreferenceMatchingSelectedProviderStaysOnDictationPath() {
        // Returning the dictation override (nil) rather than the preference keeps
        // the cloud model override flowing on the unchanged code path.
        XCTAssertNil(
            DictationViewModel.resolvePreviewEngineOverrideId(
                preferredPreviewEngineId: "groq",
                dictationEngineOverrideId: nil,
                selectedProviderId: "groq",
                isEngineAvailable: { _ in true }
            )
        )
    }

    func testPreferenceMatchingProfileOverrideStaysOnDictationPath() {
        XCTAssertEqual(
            DictationViewModel.resolvePreviewEngineOverrideId(
                preferredPreviewEngineId: "profile-engine",
                dictationEngineOverrideId: "profile-engine",
                selectedProviderId: "groq",
                isEngineAvailable: { _ in true }
            ),
            "profile-engine"
        )
    }

    func testPreferenceDistinctFromProfileOverrideWins() {
        XCTAssertEqual(
            DictationViewModel.resolvePreviewEngineOverrideId(
                preferredPreviewEngineId: "speechanalyzer",
                dictationEngineOverrideId: "profile-engine",
                selectedProviderId: "groq",
                isEngineAvailable: { _ in true }
            ),
            "speechanalyzer"
        )
    }

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
