import XCTest
@testable import TypeWhisper

final class DictationPunctuationProfileStoreTests: XCTestCase {
    @MainActor
    func testProfileLookupNormalizesLanguageCode() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let store = DictationPunctuationProfileStore(defaults: defaults, storageKey: #function)
        store.upsert(
            DictationPunctuationProfile(
                engineId: "parakeet",
                modelId: "v3",
                languageCode: "de-DE",
                defaultStrategy: .automatic,
                userOverride: .nativeOnly,
                verificationState: .userVerifiedGood,
                lastVerifiedAt: nil
            )
        )

        let profile = store.profile(engineId: "parakeet", modelId: "v3", languageCode: "de")
        XCTAssertEqual(profile?.languageCode, "de")
        XCTAssertEqual(profile?.effectiveStrategy, .nativeOnly)
    }
}
