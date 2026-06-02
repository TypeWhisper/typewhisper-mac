import XCTest
@testable import TypeWhisperPluginSDK

final class AppleSpeechModelSelectionTests: XCTestCase {
    func testPrefersExactLocaleModel() {
        let modelId = AppleSpeechModelSelection.preferredModelId(
            fromModelIds: [
                "speechanalyzer-en_US",
                "speechanalyzer-de_DE"
            ],
            localeIdentifier: "de_DE",
            languageCode: "de"
        )

        XCTAssertEqual(modelId, "speechanalyzer-de_DE")
    }

    func testMatchesLocaleSeparatorVariant() {
        let modelId = AppleSpeechModelSelection.preferredModelId(
            fromModelIds: [
                "speechanalyzer-de-DE",
                "speechanalyzer-en_US"
            ],
            localeIdentifier: "de_DE",
            languageCode: "de"
        )

        XCTAssertEqual(modelId, "speechanalyzer-de-DE")
    }

    func testUsesLanguageModelWhenExactLocaleIsMissing() {
        let modelId = AppleSpeechModelSelection.preferredModelId(
            fromModelIds: [
                "speechanalyzer-en_US",
                "speechanalyzer-de_CH"
            ],
            localeIdentifier: "de_DE",
            languageCode: "de"
        )

        XCTAssertEqual(modelId, "speechanalyzer-de_CH")
    }

    func testReturnsNilForEmptyModelCatalog() {
        let modelId = AppleSpeechModelSelection.preferredModelId(
            fromModelIds: [],
            localeIdentifier: "de_DE",
            languageCode: "de"
        )

        XCTAssertNil(modelId)
    }

    func testUsesFirstModelWhenLocaleCannotMatch() {
        let modelId = AppleSpeechModelSelection.preferredModelId(
            fromModelIds: [
                "speechanalyzer-fr_FR",
                "speechanalyzer-en_US"
            ],
            localeIdentifier: "de_DE",
            languageCode: "de"
        )

        XCTAssertEqual(modelId, "speechanalyzer-fr_FR")
    }

    func testCanDisableFallbackForExactLanguagePreparation() {
        let modelId = AppleSpeechModelSelection.preferredModelId(
            fromModelIds: [
                "speechanalyzer-fr_FR",
                "speechanalyzer-en_US"
            ],
            localeIdentifier: "de_DE",
            languageCode: "de",
            fallbackToFirst: false
        )

        XCTAssertNil(modelId)
    }
}
