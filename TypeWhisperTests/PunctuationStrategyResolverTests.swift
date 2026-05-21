import XCTest
@testable import TypeWhisper

final class PunctuationStrategyResolverTests: XCTestCase {
    @MainActor
    func testResolverUsesUserOverrideOverDefault() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let store = DictationPunctuationProfileStore(defaults: defaults, storageKey: #function)
        store.saveUserOverride(
            engineId: "parakeet",
            modelId: "v3",
            languageCode: "de-DE",
            defaultStrategy: .automatic,
            strategy: .fallbackOnly,
            verificationState: .userVerifiedBad,
            updateVerificationDate: false
        )

        let resolver = PunctuationStrategyResolver(profileStore: store)
        let resolved = resolver.resolve(
            engineId: "parakeet",
            modelId: "v3",
            configuredLanguage: "de-DE",
            detectedLanguage: nil
        )

        XCTAssertEqual(resolved?.languageCode, "de")
        XCTAssertEqual(resolved?.strategy, .fallbackOnly)
        XCTAssertEqual(resolved?.profile.verificationState, .userVerifiedBad)
    }

    @MainActor
    func testResolverProvidesVendorHintForParakeetGerman() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let store = DictationPunctuationProfileStore(defaults: defaults, storageKey: #function)
        let resolver = PunctuationStrategyResolver(profileStore: store)

        let resolved = resolver.resolve(
            engineId: "parakeet",
            modelId: "v3",
            configuredLanguage: "de",
            detectedLanguage: nil
        )

        XCTAssertEqual(resolved?.strategy, .automatic)
        XCTAssertEqual(resolved?.profile.verificationState, .vendorHint)
    }
}
