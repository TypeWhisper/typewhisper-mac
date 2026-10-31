import XCTest
@testable import TypeWhisperPluginSDK

final class AppleSpeechModelSelectionTests: XCTestCase {
    func testListsRegionalChineseModelsWhoseScriptsDiffer() {
        let modelIds = [
            "speechanalyzer-en_GB",
            "speechanalyzer-en_US",
            "speechanalyzer-yue_CN",
            "speechanalyzer-zh_CN",
            "speechanalyzer-zh_HK",
            "speechanalyzer-zh_TW"
        ]

        XCTAssertEqual(
            AppleSpeechModelSelection.supportedLanguages(fromModelIds: modelIds),
            ["en", "yue", "zh", "zh-CN", "zh-HK", "zh-TW"]
        )
        XCTAssertEqual(
            AppleSpeechModelSelection.preferredModelId(
                fromModelIds: modelIds,
                localeIdentifier: "zh-HK",
                languageCode: "zh-HK",
                fallbackToFirst: false
            ),
            "speechanalyzer-zh_HK"
        )
    }

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

    func testUsesPrimaryLanguageFallbackForLocaleLanguageCode() {
        let modelId = AppleSpeechModelSelection.preferredModelId(
            fromModelIds: [
                "speechanalyzer-en_US",
                "speechanalyzer-de_CH"
            ],
            localeIdentifier: "de-DE",
            languageCode: "de-DE",
            fallbackToFirst: false
        )

        XCTAssertEqual(modelId, "speechanalyzer-de_CH")
    }

    func testGenericLanguagePrefersMatchingSelectedRegionalModel() {
        let modelId = AppleSpeechModelSelection.preferredModelId(
            fromModelIds: [
                "speechanalyzer-en_AU",
                "speechanalyzer-en_US"
            ],
            localeIdentifier: "en",
            languageCode: "en",
            preferredModelId: "speechanalyzer-en_US",
            fallbackLocaleIdentifier: "en_AU",
            fallbackToFirst: false
        )

        XCTAssertEqual(modelId, "speechanalyzer-en_US")
    }

    func testGenericLanguageUsesMatchingFallbackLocaleBeforeFirstLanguageModel() {
        let modelId = AppleSpeechModelSelection.preferredModelId(
            fromModelIds: [
                "speechanalyzer-en_AU",
                "speechanalyzer-en_US"
            ],
            localeIdentifier: "en",
            languageCode: "en",
            fallbackLocaleIdentifier: "en_US",
            fallbackToFirst: false
        )

        XCTAssertEqual(modelId, "speechanalyzer-en_US")
    }

    func testExactRegionalLanguageTakesPrecedenceOverPreferredAndFallbackModels() {
        let modelId = AppleSpeechModelSelection.preferredModelId(
            fromModelIds: [
                "speechanalyzer-en_AU",
                "speechanalyzer-en_GB",
                "speechanalyzer-en_US"
            ],
            localeIdentifier: "en-GB",
            languageCode: "en-GB",
            preferredModelId: "speechanalyzer-en_US",
            fallbackLocaleIdentifier: "en_AU",
            fallbackToFirst: false
        )

        XCTAssertEqual(modelId, "speechanalyzer-en_GB")
    }

    func testGenericLanguageIgnoresPreferredModelFromAnotherLanguage() {
        let modelId = AppleSpeechModelSelection.preferredModelId(
            fromModelIds: [
                "speechanalyzer-en_AU",
                "speechanalyzer-en_US",
                "speechanalyzer-de_DE"
            ],
            localeIdentifier: "en",
            languageCode: "en",
            preferredModelId: "speechanalyzer-de_DE",
            fallbackLocaleIdentifier: "en_US",
            fallbackToFirst: false
        )

        XCTAssertEqual(modelId, "speechanalyzer-en_US")
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
