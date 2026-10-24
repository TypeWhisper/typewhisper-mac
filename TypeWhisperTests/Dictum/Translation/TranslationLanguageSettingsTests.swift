import XCTest
@testable import TypeWhisper

@MainActor
final class TranslationLanguageSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.schneidervvv.dictum.dev.tests.translation-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func testFreshInstallUsesSimplifiedChineseToEnglish() {
        let store = TranslationLanguageStore(defaults: defaults)
        XCTAssertEqual(store.settings.spokenLanguage, "zh-Hans")
        XCTAssertEqual(store.settings.offeredTargets, ["en"])
        XCTAssertEqual(store.settings.pair, TranslationPair(spoken: "zh-Hans", target: "en"))
    }

    func testMigratesSingleTargetAndVoiceBarListOnce() {
        defaults.set("ja", forKey: TranslationLanguageStore.Keys.legacyTarget)
        defaults.set(["en", "ko", "ja"], forKey: TranslationLanguageStore.Keys.legacyTargets)
        let store = TranslationLanguageStore(defaults: defaults)
        XCTAssertEqual(store.settings.offeredTargets, ["ja", "en", "ko"])
        XCTAssertEqual(store.settings.currentTarget, "ja")
        XCTAssertNil(defaults.stringArray(forKey: TranslationLanguageStore.Keys.legacyTargets))

        store.removeTarget("ja")
        defaults.set("fr", forKey: TranslationLanguageStore.Keys.legacyTarget)
        let reopened = TranslationLanguageStore(defaults: defaults)
        XCTAssertEqual(reopened.settings.offeredTargets, ["en", "ko"], "迁移只运行一次")
    }

    func testMigrationKeepsLegacySingleTargetWithoutList() {
        defaults.set("de", forKey: TranslationLanguageStore.Keys.legacyTarget)
        let store = TranslationLanguageStore(defaults: defaults)
        XCTAssertEqual(store.settings.offeredTargets, ["de"])
        XCTAssertEqual(store.settings.pair?.target, "de")
    }

    func testCurrentTargetFallsBackToFirstWhenRemoved() {
        let store = TranslationLanguageStore(defaults: defaults)
        store.addTarget("ja")
        store.addTarget("ko")
        store.selectCurrentTarget("ko")
        XCTAssertEqual(store.settings.currentTarget, "ko")
        store.removeTarget("ko")
        XCTAssertEqual(store.settings.currentTarget, "en")
    }

    func testSpokenLanguageIsNeverOfferedAsTarget() {
        let store = TranslationLanguageStore(defaults: defaults)
        store.addTarget("ja")
        store.addTarget("zh-Hant")
        XCTAssertEqual(store.settings.offeredTargets, ["en", "ja", "zh-Hant"], "繁体不同于简体说话语言")
        store.setSpokenLanguage("ja")
        XCTAssertEqual(store.settings.offeredTargets, ["en", "zh-Hant"])
        store.setSpokenLanguage("zh-Hans")
        XCTAssertEqual(store.settings.offeredTargets, ["en", "ja", "zh-Hant"], "切回后重新出现")
    }

    func testAutomaticSpokenLanguageExcludesNothingAndHasNoSource() {
        let store = TranslationLanguageStore(defaults: defaults)
        store.addTarget("zh-Hans")
        store.setSpokenLanguage(TranslationLanguageSettings.automatic)
        XCTAssertEqual(store.settings.offeredTargets, ["en", "zh-Hans"])
        XCTAssertNil(store.settings.pair?.spoken)
        XCTAssertTrue(store.settings.isAutomatic)
    }

    func testSpokenLanguageMatchingOnlyTargetSwapsPair() {
        let store = TranslationLanguageStore(defaults: defaults)
        store.setSpokenLanguage("en")
        XCTAssertEqual(store.settings.pair, TranslationPair(spoken: "en", target: "zh-Hans"))
    }

    func testEnglishToSimplifiedChinesePairIsConfigurable() {
        let store = TranslationLanguageStore(defaults: defaults)
        store.addTarget("zh-Hans")
        store.setSpokenLanguage("en")
        store.removeTarget("en")
        XCTAssertEqual(store.settings.pair, TranslationPair(spoken: "en", target: "zh-Hans"))
    }

    func testLastTargetCannotBeRemovedAndOrderCanChange() {
        let store = TranslationLanguageStore(defaults: defaults)
        store.removeTarget("en")
        XCTAssertEqual(store.settings.offeredTargets, ["en"])
        store.addTarget("ja")
        store.addTarget("ko")
        store.moveTargets(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.settings.offeredTargets, ["ko", "en", "ja"])
        let reopened = TranslationLanguageStore(defaults: defaults)
        XCTAssertEqual(reopened.settings.offeredTargets, ["ko", "en", "ja"])
    }

    func testRegionVariantsOfSpokenLanguageAreExcluded() {
        var settings = TranslationLanguageSettings()
        settings.spokenLanguage = "en-US"
        settings.targets = ["en", "fr"]
        XCTAssertEqual(settings.offeredTargets, ["fr"])
    }

    func testEngineHintFallsBackToPrimaryLanguage() {
        XCTAssertEqual(TranslationLanguageCatalog.engineHint(for: "zh-Hans", engineCodes: ["zh", "en"]), "zh")
        XCTAssertEqual(TranslationLanguageCatalog.engineHint(for: "pt-BR", engineCodes: ["pt-BR", "pt"]), "pt-BR")
    }

    func testSpokenOptionsComeFromEngineAndSplitChineseScripts() {
        let options = TranslationLanguageCatalog.spokenOptions(engineCodes: ["zh", "en", "ja"], selected: "zh-Hans")
        XCTAssertEqual(Set(options), ["zh-Hans", "zh-Hant", "en", "ja"])
        let extra = TranslationLanguageCatalog.spokenOptions(engineCodes: ["en"], selected: "ko")
        XCTAssertEqual(Set(extra), ["en", "ko"], "已选语言即使引擎不支持也保留")
    }

    func testPracticeSentencesExistPerSpokenLanguageAndFallBackToTheDefault() {
        let chinese = TranslationPractice.sentence(for: TranslationLanguageSettings.defaultSpokenLanguage)
        XCTAssertFalse(chinese.text.isEmpty)
        XCTAssertFalse(chinese.isFallback)
        for code in ["en", "ja", "ko", "fr", "de", "es", "zh-Hant"] {
            let sentence = TranslationPractice.sentence(for: code)
            XCTAssertFalse(sentence.isFallback, code)
            XCTAssertNotEqual(sentence.text, chinese.text, code)
        }
        let regional = TranslationPractice.sentence(for: "fr-CA")
        XCTAssertFalse(regional.isFallback)
        let missing = TranslationPractice.sentence(for: "sw")
        XCTAssertTrue(missing.isFallback)
        XCTAssertEqual(missing.text, chinese.text)
        XCTAssertEqual(TranslationPractice.sentence(for: nil), TranslationPractice.Sentence(text: chinese.text, isFallback: false))
    }

    func testTargetCandidatesExcludeExistingLanguages() {
        let candidates = TranslationLanguageCatalog.targetCandidates(excluding: ["en", "zh-Hans"])
        XCTAssertFalse(candidates.contains("en"))
        XCTAssertFalse(candidates.contains("zh-Hans"))
        XCTAssertTrue(candidates.contains("zh-Hant"))
        XCTAssertTrue(candidates.contains("ja"))
    }
}
