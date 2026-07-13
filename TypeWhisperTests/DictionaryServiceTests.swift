import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

private final class BudgetedDictionaryEnginePlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsBudgetProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.budgeted-dictionary-engine"
    static let pluginName = "Budgeted Dictionary Engine"
    var providerIdValue = "budgeted"
    var budgetValue = DictionaryTermsBudget()

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerId: String { providerIdValue }
    var providerDisplayName: String { "Budgeted Mock" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [] }
    var selectedModelId: String? { nil }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }
    var dictionaryTermsBudget: DictionaryTermsBudget { budgetValue }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok", detectedLanguage: language)
    }
}

private final class LegacyDictionaryEnginePlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.legacy-dictionary-engine"
    static let pluginName = "Legacy Dictionary Engine"
    var providerIdValue = "legacy"

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerId: String { providerIdValue }
    var providerDisplayName: String { "Legacy Mock" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [] }
    var selectedModelId: String? { nil }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok", detectedLanguage: language)
    }
}

private final class UnsupportedDictionaryEnginePlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.unsupported-dictionary-engine"
    static let pluginName = "Unsupported Dictionary Engine"
    var providerIdValue = "unsupported"

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerId: String { providerIdValue }
    var providerDisplayName: String { "Unsupported Mock" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [] }
    var selectedModelId: String? { nil }
    var dictionaryTermsSupport: DictionaryTermsSupport { .unsupported }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok", detectedLanguage: language)
    }
}

final class DictionaryServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPacks)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPackStates)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedIndustryPreset)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPacks)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPackStates)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedIndustryPreset)
        PluginManager.shared = nil
        super.tearDown()
    }

    @MainActor
    func testDictionaryTermsCorrectionsAndLearning() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)

        service.addEntry(type: .term, original: "TypeWhisper")
        service.addEntry(type: .term, original: "typewhisper")
        service.addEntry(type: .correction, original: "teh", replacement: "the")

        XCTAssertEqual(service.termsCount, 1)
        XCTAssertEqual(service.correctionsCount, 1)
        XCTAssertEqual(service.getTermsForPrompt(providerId: nil), "TypeWhisper")

        let corrected = service.applyCorrections(to: "teh TypeWhisper")
        XCTAssertEqual(corrected, "the TypeWhisper")
        XCTAssertEqual(service.corrections.first?.usageCount, 1)

        service.learnCorrection(original: "langauge", replacement: "language")
        XCTAssertEqual(service.correctionsCount, 2)
    }

    @MainActor
    func testBatchLearningSkipsDuplicatesAndUndoDeletesOnlyMatchingCreatedEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "teh", replacement: "the")

        let learned = service.learnCorrections([
            CorrectionSuggestion(original: "teh", replacement: "the"),
            CorrectionSuggestion(original: "langauge", replacement: "language"),
            CorrectionSuggestion(original: "recieve", replacement: "receive"),
            CorrectionSuggestion(original: "recieve", replacement: "receipt")
        ])

        XCTAssertEqual(learned.count, 2)
        XCTAssertEqual(learned.map(\.original), ["langauge", "recieve"])
        XCTAssertEqual(service.correctionsCount, 3)
        XCTAssertEqual(
            service.corrections.filter { $0.source == .autoLearned }.map(\.original),
            ["langauge", "recieve"]
        )

        let protectedEntry = try XCTUnwrap(service.corrections.first { $0.original == "langauge" })
        service.updateEntry(
            protectedEntry,
            original: protectedEntry.original,
            replacement: "languages",
            caseSensitive: protectedEntry.caseSensitive
        )

        service.undoLearnedCorrections(learned)

        XCTAssertEqual(service.correctionsCount, 2)
        XCTAssertTrue(service.corrections.contains { $0.original == "teh" })
        XCTAssertTrue(service.corrections.contains { $0.original == "langauge" && $0.replacement == "languages" })
        XCTAssertFalse(service.corrections.contains { $0.original == "recieve" })
    }

    @MainActor
    func testEmptyCorrectionReplacementPersistsAndRemovesText() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "¿", replacement: "")

        XCTAssertEqual(service.correctionsCount, 1)
        XCTAssertEqual(service.corrections.first?.replacement, "")
        XCTAssertEqual(service.applyCorrections(to: "¿Como estas?"), "Como estas?")
        XCTAssertEqual(service.corrections.first?.usageCount, 1)

        let reloadedService = DictionaryService(appSupportDirectory: appSupportDirectory)
        XCTAssertEqual(reloadedService.correctionsCount, 1)
        XCTAssertEqual(reloadedService.corrections.first?.replacement, "")
        XCTAssertEqual(reloadedService.applyCorrections(to: "¿Como estas?"), "Como estas?")
        reloadedService.loadEntries()
        XCTAssertEqual(reloadedService.corrections.first?.usageCount, 2)
    }

    @MainActor
    func testBatchLearningAllowsEmptyReplacementCorrections() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)

        let learned = service.learnCorrections([
            CorrectionSuggestion(original: "filler", replacement: "")
        ])

        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.original, "filler")
        XCTAssertEqual(learned.first?.replacement, "")
        XCTAssertEqual(service.applyCorrections(to: "drop filler text"), "drop text")
    }

    @MainActor
    func testWhitespaceBearingLatinFillerCorrectionsStillApplyAtWordBoundaries() throws {
        let plainDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(plainDirectory) }

        let plainService = DictionaryService(appSupportDirectory: plainDirectory)
        plainService.addEntry(type: .correction, original: "um", replacement: "")

        XCTAssertEqual(plainService.applyCorrections(to: "Um I think this works"), "I think this works")
        XCTAssertEqual(plainService.applyCorrections(to: "I said um today"), "I said today")

        let whitespaceDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(whitespaceDirectory) }

        let service = DictionaryService(appSupportDirectory: whitespaceDirectory)
        service.addEntry(type: .correction, original: "um ", replacement: "")
        service.addEntry(type: .correction, original: " huh", replacement: "")

        XCTAssertEqual(service.applyCorrections(to: "Um I think this works"), "I think this works")
        XCTAssertEqual(service.applyCorrections(to: "I said um today"), "I said today")
        XCTAssertEqual(service.applyCorrections(to: "this was huh"), "this was")
    }

    @MainActor
    func testWhitespaceBearingFillerCorrectionsKeepOneSeparatorBetweenWords() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: " um ", replacement: "")

        XCTAssertEqual(service.applyCorrections(to: "I said um today"), "I said today")
        XCTAssertEqual(service.applyCorrections(to: "I said, um today"), "I said, today")
    }

    @MainActor
    func testLatinCorrectionsMatchWholeWordsOnly() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "rake", replacement: "RAKE")
        service.addEntry(type: .correction, original: "um", replacement: "")
        service.addEntry(type: .correction, original: "um ", replacement: "")

        XCTAssertEqual(service.applyCorrections(to: "rake"), "RAKE")
        XCTAssertEqual(service.applyCorrections(to: "Rake"), "RAKE")
        XCTAssertEqual(service.applyCorrections(to: "brake rakes"), "brake rakes")
        XCTAssertEqual(service.applyCorrections(to: "Use rake, rake/brake, and (rake)."), "Use RAKE, RAKE/brake, and (RAKE).")
        XCTAssertEqual(service.applyCorrections(to: "umbrella stand"), "umbrella stand")
        XCTAssertEqual(service.applyCorrections(to: "album art"), "album art")
    }

    @MainActor
    func testCorrectionsDoNotReplaceInsideLongerKatakanaWords() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "ライン", replacement: "LINE")
        service.addEntry(type: .correction, original: "リフ", replacement: "LIFF")

        XCTAssertEqual(service.applyCorrections(to: "具体的にはオンライン。"), "具体的にはオンライン。")
        XCTAssertEqual(service.applyCorrections(to: "リファレンス。"), "リファレンス。")
        XCTAssertEqual(service.applyCorrections(to: "ラインで送って。"), "LINEで送って。")
    }

    @MainActor
    func testCorrectionsStillApplyForKnownJapaneseNameAndBrandTerms() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "恋ちゃん", replacement: "こいちゃん")
        service.addEntry(type: .correction, original: "鯉フィット", replacement: "Koi-Fit")

        XCTAssertEqual(service.applyCorrections(to: "恋ちゃんです。"), "こいちゃんです。")
        XCTAssertEqual(service.applyCorrections(to: "今日は恋ちゃんです。"), "今日はこいちゃんです。")
        XCTAssertEqual(service.applyCorrections(to: "鯉フィットの件です。"), "Koi-Fitの件です。")
        XCTAssertEqual(service.applyCorrections(to: "今日は鯉フィットの件です。"), "今日はKoi-Fitの件です。")
        XCTAssertEqual(service.applyCorrections(to: "鯉フィットネスではありません。"), "鯉フィットネスではありません。")
    }

    @MainActor
    func testCorrectionsDoNotFoldJapaneseDakutenDifferences() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "ハン", replacement: "HAN")

        XCTAssertEqual(service.applyCorrections(to: "ハンで始まる。"), "HANで始まる。")
        XCTAssertEqual(service.applyCorrections(to: "バンで始まる。"), "バンで始まる。")
    }

    @MainActor
    func testMixedJapaneseCorrectionsDoNotReplaceInsideCompoundWords() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "日本", replacement: "Japan")
        service.addEntry(type: .correction, original: "東京", replacement: "Tokyo")

        XCTAssertEqual(service.applyCorrections(to: "日本です。"), "Japanです。")
        XCTAssertEqual(service.applyCorrections(to: "これは日本です。"), "これはJapanです。")
        XCTAssertEqual(service.applyCorrections(to: "東京へ行く。"), "Tokyoへ行く。")
        XCTAssertEqual(service.applyCorrections(to: "明日は東京へ行く。"), "明日はTokyoへ行く。")
        XCTAssertEqual(service.applyCorrections(to: "日本から出発します。"), "Japanから出発します。")
        XCTAssertEqual(service.applyCorrections(to: "日本まで送ってください。"), "Japanまで送ってください。")
        XCTAssertEqual(service.applyCorrections(to: "日本語です。"), "日本語です。")
        XCTAssertEqual(service.applyCorrections(to: "東京都です。"), "東京都です。")
    }

    @MainActor
    func testShortJapaneseCorrectionsDoNotReplaceInsideWordsContainingParticles() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "だ", replacement: "です")

        XCTAssertEqual(service.applyCorrections(to: "からだです。"), "からだです。")
    }

    @MainActor
    func testSingleCharacterCorrectionsDoNotUseMultiCharacterParticleSuffixesInsideWords() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "ち", replacement: "地")

        XCTAssertEqual(service.applyCorrections(to: "ちからです。"), "ちからです。")
    }

    @MainActor
    func testAPITermHelpersDeleteSingleTermWithoutClearingOthers() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        try service.setAPITerms([" TypeWhisper ", "WhisperKit", "typewhisper"], replaceExisting: true)

        XCTAssertTrue(try service.deleteAPITerm("typewhisper"))
        XCTAssertEqual(service.enabledTerms(), ["WhisperKit"])
        XCTAssertFalse(try service.deleteAPITerm("Missing"))
    }

    @MainActor
    func testAPICorrectionHelpersUpsertCaseInsensitiveAndPreserveUsageCount() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        try service.upsertAPICorrection(original: "teh", replacement: "the", caseSensitive: false)
        XCTAssertEqual(service.applyCorrections(to: "teh"), "the")
        XCTAssertEqual(service.corrections.first?.usageCount, 1)

        try service.upsertAPICorrection(original: "TEH", replacement: "The", caseSensitive: true)

        XCTAssertEqual(service.correctionsCount, 1)
        XCTAssertEqual(service.corrections.first?.original, "TEH")
        XCTAssertEqual(service.corrections.first?.replacement, "The")
        XCTAssertEqual(service.corrections.first?.caseSensitive, true)
        XCTAssertEqual(service.corrections.first?.source, .manual)
        XCTAssertEqual(service.corrections.first?.usageCount, 1)
        XCTAssertTrue(try service.deleteAPICorrection(original: "teh"))
        XCTAssertEqual(service.correctionsCount, 0)
        XCTAssertFalse(try service.deleteAPICorrection(original: "missing"))
    }

    @MainActor
    func testEnabledTermsAreNormalizedAndPromptRendererStaysBackwardCompatible() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .term, original: " Kubernetes ", ctcMinSimilarity: 0.65)
        service.addEntry(type: .term, original: "MLX")
        service.addEntry(type: .term, original: "mlx")
        service.addEntry(type: .term, original: "TypeWhisper")

        XCTAssertEqual(service.enabledTerms(), ["Kubernetes", "MLX", "TypeWhisper"])
        XCTAssertEqual(service.enabledTermHints(), [
            PluginDictionaryTermHint(text: "Kubernetes", ctcMinSimilarity: 0.65),
            PluginDictionaryTermHint(text: "MLX", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "TypeWhisper", ctcMinSimilarity: nil),
        ])
        XCTAssertEqual(
            service.getTermsForPrompt(providerId: nil),
            PluginDictionaryTerms.prompt(from: ["Kubernetes", "MLX", "TypeWhisper"])
        )
    }

    @MainActor
    func testAPITermEntriesPersistThresholdsAndPlainTermsPreserveExistingValues() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        try service.setAPITermEntries(
            [
                (term: " TypeWhisper ", ctcMinSimilarity: 0.65),
                (term: "Reson8", ctcMinSimilarity: nil),
            ],
            replaceExisting: true
        )

        XCTAssertEqual(service.enabledTermHints(), [
            PluginDictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "TypeWhisper", ctcMinSimilarity: 0.65),
        ])

        try service.setAPITerms(["typewhisper", "Caivex"], replaceExisting: false)

        XCTAssertEqual(service.enabledTermHints(), [
            PluginDictionaryTermHint(text: "Caivex", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "typewhisper", ctcMinSimilarity: 0.65),
        ])

        try service.setAPITermEntries(
            [(term: "TypeWhisper", ctcMinSimilarity: nil)],
            replaceExisting: true
        )

        XCTAssertEqual(service.enabledTermHints(), [
            PluginDictionaryTermHint(text: "TypeWhisper", ctcMinSimilarity: nil),
        ])
    }

    @MainActor
    func testGetTermsForPromptUsesLoadedEngineBudget() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.setTerms(["Alpha", "BetaBeta", "Gamma", "alpha"], replaceExisting: true)

        let plugin = BudgetedDictionaryEnginePlugin()
        plugin.providerIdValue = "budgeted"
        plugin.budgetValue = DictionaryTermsBudget(maxTerms: 2, maxCharsPerTerm: 5)
        installPlugins([plugin], appSupportDirectory: appSupportDirectory)

        XCTAssertEqual(service.getTermsForPrompt(providerId: plugin.providerId), "Alpha, Gamma")
        XCTAssertEqual(service.getTermHints(providerId: plugin.providerId), [
            PluginDictionaryTermHint(text: "Alpha", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "Gamma", ctcMinSimilarity: nil),
        ])
    }

    @MainActor
    func testGetTermsForPromptFallsBackToLegacyBudgetForUnknownOrUnbudgetedEngines() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.setTerms(makeLongTerms(count: 40, length: 24), replaceExisting: true)

        let plugin = LegacyDictionaryEnginePlugin()
        plugin.providerIdValue = "legacy"
        installPlugins([plugin], appSupportDirectory: appSupportDirectory)

        let expectedFallback = PluginDictionaryTerms.prompt(from: service.enabledTerms())
        XCTAssertEqual(service.getTermsForPrompt(providerId: nil), expectedFallback)
        XCTAssertEqual(service.getTermsForPrompt(providerId: plugin.providerId), expectedFallback)
        XCTAssertEqual(service.getTermsForPrompt(providerId: "missing"), expectedFallback)
        XCTAssertLessThanOrEqual(expectedFallback?.count ?? 0, 600)
    }

    @MainActor
    func testGetTermsForPromptReturnsNilForUnsupportedEngines() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.setTerms(["Alpha", "Beta"], replaceExisting: true)

        let plugin = UnsupportedDictionaryEnginePlugin()
        installPlugins([plugin], appSupportDirectory: appSupportDirectory)

        XCTAssertNil(service.getTermsForPrompt(providerId: plugin.providerId))
    }

    @MainActor
    func testGetTermsForPromptAllowsBudgetsAboveLegacy600Characters() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.setTerms(makeLongTerms(count: 40, length: 24), replaceExisting: true)

        let plugin = BudgetedDictionaryEnginePlugin()
        plugin.providerIdValue = "budgeted"
        plugin.budgetValue = DictionaryTermsBudget(maxTotalChars: 2_000)
        installPlugins([plugin], appSupportDirectory: appSupportDirectory)

        let prompt = try XCTUnwrap(service.getTermsForPrompt(providerId: plugin.providerId))
        XCTAssertGreaterThan(prompt.count, 600)
    }

    @MainActor
    func testGetTermsForPromptAppliesWordAndCharacterFilters() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.setTerms(
            ["Alpha", "one two three", "123456789012345678901", "Beta Beta", "Gamma"],
            replaceExisting: true
        )

        let plugin = BudgetedDictionaryEnginePlugin()
        plugin.providerIdValue = "budgeted"
        plugin.budgetValue = DictionaryTermsBudget(maxCharsPerTerm: 20, maxWordsPerTerm: 2)
        installPlugins([plugin], appSupportDirectory: appSupportDirectory)

        XCTAssertEqual(service.getTermsForPrompt(providerId: plugin.providerId), "Alpha, Beta Beta, Gamma")
    }

    @MainActor
    func testDictionaryEntryRowsSnapshotLargeFilteredListsWithStableIDs() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let terms = (1...120).map {
            (
                type: DictionaryEntryType.term,
                original: String(format: "Term-%03d", $0),
                replacement: nil as String?,
                caseSensitive: true,
                ctcMinSimilarity: nil as Float?
            )
        }
        let corrections = (1...120).map {
            (
                type: DictionaryEntryType.correction,
                original: String(format: "Wrong-%03d", $0),
                replacement: String(format: "Correct-%03d", $0) as String?,
                caseSensitive: false,
                ctcMinSimilarity: nil as Float?
            )
        }
        service.addEntries(terms + corrections + [
            (
                type: DictionaryEntryType.correction,
                original: "empty-replacement",
                replacement: "" as String?,
                caseSensitive: true,
                ctcMinSimilarity: nil as Float?
            )
        ])

        let viewModel = DictionaryViewModel(dictionaryService: service)
        viewModel.filterTab = .corrections
        let correctionRows = viewModel.filteredEntryRows

        XCTAssertEqual(correctionRows.count, 121)
        XCTAssertTrue(correctionRows.allSatisfy { $0.type == .correction })
        XCTAssertEqual(correctionRows.first { $0.original == "empty-replacement" }?.replacementDisplayText, "\"\"")

        let correctionIDs = correctionRows.map(\.id)
        let searchedOriginalID = try XCTUnwrap(
            correctionRows.first { $0.original == "Wrong-042" }?.id
        )
        viewModel.searchQuery = "WRONG-042"
        XCTAssertEqual(viewModel.filteredEntryRows.map(\.id), [searchedOriginalID])

        viewModel.searchQuery = "correct-042"
        XCTAssertEqual(viewModel.filteredEntryRows.map(\.id), [searchedOriginalID])

        viewModel.searchQuery = ""
        XCTAssertEqual(viewModel.filteredEntryRows.map(\.id), correctionIDs)

        viewModel.filterTab = .all
        let allCorrectionIDs = viewModel.filteredEntryRows
            .filter { $0.type == .correction }
            .map(\.id)
        XCTAssertEqual(allCorrectionIDs, correctionIDs)

        service.learnCorrection(original: "autolearned", replacement: "auto learned")
        let autoLearnedViewModel = DictionaryViewModel(dictionaryService: service)
        autoLearnedViewModel.filterTab = .autoLearned
        let autoLearnedRows = autoLearnedViewModel.filteredEntryRows
        XCTAssertEqual(autoLearnedRows.map(\.original), ["autolearned"])
        XCTAssertTrue(autoLearnedRows.allSatisfy { $0.source == .autoLearned })
    }

    @MainActor
    func testDictionarySearchMatchesOriginalAndReplacementAndComposesWithFilters() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .term, original: "TypeWhisper")
        service.addEntry(type: .term, original: "Podcast")
        service.addEntry(type: .correction, original: "teh", replacement: "the")
        service.learnCorrection(original: "langauge", replacement: "language")

        let entriesBeforeSearch = service.entries.map {
            ($0.id, $0.type, $0.original, $0.replacement, $0.source)
        }
        let viewModel = DictionaryViewModel(dictionaryService: service)

        viewModel.searchQuery = "TYPEWHISPER"
        XCTAssertEqual(viewModel.filteredEntryRows.map(\.original), ["TypeWhisper"])

        viewModel.filterTab = .corrections
        viewModel.searchQuery = "THE"
        XCTAssertEqual(viewModel.filteredEntryRows.map(\.original), ["teh"])

        viewModel.filterTab = .autoLearned
        XCTAssertTrue(viewModel.filteredEntryRows.isEmpty)
        viewModel.searchQuery = "LANGUAGE"
        XCTAssertEqual(viewModel.filteredEntryRows.map(\.original), ["langauge"])

        viewModel.filterTab = .terms
        XCTAssertTrue(viewModel.filteredEntryRows.isEmpty)
        viewModel.searchQuery = "   "
        XCTAssertEqual(viewModel.filteredEntryRows.map(\.original), ["Podcast", "TypeWhisper"])
        XCTAssertFalse(viewModel.hasActiveSearch)

        viewModel.searchQuery = "podcast"
        XCTAssertTrue(viewModel.hasActiveSearch)
        viewModel.filterTab = .termPacks
        XCTAssertEqual(viewModel.searchQuery, "podcast")
        XCTAssertTrue(viewModel.filteredEntryRows.isEmpty)

        viewModel.filterTab = .all
        viewModel.searchQuery = ""
        XCTAssertEqual(viewModel.filteredEntryRows.count, entriesBeforeSearch.count)
        XCTAssertEqual(service.entries.map(\.id), entriesBeforeSearch.map { $0.0 })
        XCTAssertEqual(service.entries.map(\.type), entriesBeforeSearch.map { $0.1 })
        XCTAssertEqual(service.entries.map(\.original), entriesBeforeSearch.map { $0.2 })
        XCTAssertEqual(service.entries.map(\.replacement), entriesBeforeSearch.map { $0.3 })
        XCTAssertEqual(service.entries.map(\.source), entriesBeforeSearch.map { $0.4 })
    }

    @MainActor
    func testDictionaryEntryIDActionsEditSetEnabledToggleAndDeleteMatchingEntry() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "teh", replacement: "the", caseSensitive: true)
        let viewModel = DictionaryViewModel(dictionaryService: service)
        let row = try XCTUnwrap(viewModel.filteredEntryRows.first)

        viewModel.setEntryEnabled(id: row.id, enabled: false)
        XCTAssertFalse(try XCTUnwrap(service.entries.first { $0.id == row.id }).isEnabled)
        viewModel.setEntryEnabled(id: row.id, enabled: false)
        XCTAssertFalse(try XCTUnwrap(service.entries.first { $0.id == row.id }).isEnabled)
        viewModel.setEntryEnabled(id: row.id, enabled: true)
        XCTAssertTrue(try XCTUnwrap(service.entries.first { $0.id == row.id }).isEnabled)
        viewModel.toggleEntry(id: row.id)
        XCTAssertFalse(try XCTUnwrap(service.entries.first { $0.id == row.id }).isEnabled)

        viewModel.startEditingEntry(id: row.id)
        XCTAssertTrue(viewModel.isEditing)
        XCTAssertFalse(viewModel.isCreatingNew)
        XCTAssertEqual(viewModel.editType, .correction)
        XCTAssertEqual(viewModel.editOriginal, "teh")
        XCTAssertEqual(viewModel.editReplacement, "the")
        XCTAssertTrue(viewModel.editCaseSensitive)

        viewModel.deleteEntry(id: row.id)
        XCTAssertFalse(service.entries.contains { $0.id == row.id })
    }

    @MainActor
    func testTermPackActivationPreservesManualEntriesAndDeactivationRemovesOnlyPackEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .term, original: "Rust")

        let viewModel = DictionaryViewModel(dictionaryService: service)
        let pack = TermPack(
            id: "community-rust",
            name: "Rust Terms",
            description: "Rust ecosystem terms",
            icon: "shippingbox",
            terms: ["Rust", "Tokio"],
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )

        viewModel.activatePack(pack)

        XCTAssertEqual(service.entries.filter { $0.type == .term }.map(\.original).sorted(), ["Rust", "Tokio"])
        XCTAssertEqual(service.entries.first(where: { $0.original == "Rust" })?.caseSensitive, false)
        XCTAssertEqual(viewModel.activatedPackStates[pack.id]?.installedTerms, ["Tokio"])

        viewModel.deactivatePack(pack)

        XCTAssertEqual(service.entries.filter { $0.type == .term }.map(\.original), ["Rust"])
        XCTAssertFalse(viewModel.isPackActivated(pack))
    }

    @MainActor
    func testTermPackUpdateReplacesPreviousSnapshotEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let viewModel = DictionaryViewModel(dictionaryService: service)

        let v1 = TermPack(
            id: "community-rust",
            name: "Rust Terms",
            description: "Rust ecosystem terms",
            icon: "shippingbox",
            terms: ["Tokio"],
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )
        let v2 = TermPack(
            id: "community-rust",
            name: "Rust Terms",
            description: "Rust ecosystem terms",
            icon: "shippingbox",
            terms: ["Cargo"],
            corrections: [],
            version: "1.1.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )

        viewModel.activatePack(v1)
        viewModel.updatePack(v2)

        XCTAssertEqual(service.entries.filter { $0.type == .term }.map(\.original), ["Cargo"])
        XCTAssertEqual(viewModel.activatedPackStates[v2.id]?.installedTerms, ["Cargo"])
        XCTAssertEqual(viewModel.activatedPackStates[v2.id]?.installedVersion, "1.1.0")
    }

    @MainActor
    func testClearAutoLearnedResetRequiresConfirmationAndPreservesOtherEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .term, original: "ManualTerm")
        service.addEntry(type: .correction, original: "teh", replacement: "the")
        service.learnCorrection(original: "recieve", replacement: "receive")
        let viewModel = DictionaryViewModel(dictionaryService: service)

        let summary = viewModel.resetRequest(for: .clearAutoLearnedCorrections)
        XCTAssertEqual(summary.entryCount, 1)
        XCTAssertEqual(summary.autoLearnedCorrectionCount, 1)
        XCTAssertTrue(summary.canPerform)

        let originalIDs = service.entries.map(\.id)
        viewModel.requestReset(.clearAutoLearnedCorrections)
        XCTAssertNotNil(viewModel.pendingResetRequest)
        XCTAssertEqual(service.entries.map(\.id), originalIDs)

        viewModel.cancelReset()
        XCTAssertNil(viewModel.pendingResetRequest)
        XCTAssertEqual(service.entries.map(\.id), originalIDs)

        viewModel.requestReset(.clearAutoLearnedCorrections)
        viewModel.confirmReset()

        XCTAssertEqual(Set(service.entries.map(\.original)), ["ManualTerm", "teh"])
        XCTAssertFalse(service.entries.contains { $0.source == .autoLearned })
        XCTAssertNil(viewModel.pendingResetRequest)
        XCTAssertFalse(viewModel.resetRequest(for: .clearAutoLearnedCorrections).canPerform)
    }

    @MainActor
    func testResetCustomDictionaryPreservesActivePackEntriesSnapshotsAndExport() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let suiteName = "DictionaryResetCustom-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .term, original: "ManualTerm")
        service.addEntry(type: .correction, original: "teh", replacement: "the")
        service.learnCorrection(original: "recieve", replacement: "receive")
        let viewModel = DictionaryViewModel(dictionaryService: service, defaults: defaults)
        let pack = TermPack(
            id: "reset-pack",
            name: "Reset Pack",
            description: "Reset test pack",
            icon: "shippingbox",
            terms: ["PackTerm"],
            corrections: [TermPackCorrection(original: "pakc", replacement: "pack")],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )
        viewModel.activatePack(pack)

        let summary = viewModel.resetRequest(for: .resetCustomDictionary)
        XCTAssertEqual(summary.termCount, 1)
        XCTAssertEqual(summary.manualCorrectionCount, 1)
        XCTAssertEqual(summary.autoLearnedCorrectionCount, 1)
        XCTAssertEqual(summary.activePackCount, 1)

        viewModel.requestReset(.resetCustomDictionary)
        viewModel.confirmReset()

        XCTAssertEqual(Set(service.entries.map(\.original)), ["PackTerm", "pakc"])
        XCTAssertNotNil(viewModel.activatedPackStates[pack.id])

        let persistedStatesData = try XCTUnwrap(
            defaults.data(forKey: UserDefaultsKeys.activatedTermPackStates)
        )
        let persistedStates = try JSONDecoder().decode([ActivatedTermPackState].self, from: persistedStatesData)
        XCTAssertEqual(persistedStates.map(\.packID), [pack.id])

        let exported = DictionaryExporter.exportJSON(service.entries)
        XCTAssertTrue(exported.contains("PackTerm"))
        XCTAssertTrue(exported.contains("pakc"))
        XCTAssertFalse(exported.contains("ManualTerm"))
        XCTAssertFalse(exported.contains("recieve"))

        let reloadedViewModel = DictionaryViewModel(dictionaryService: service, defaults: defaults)
        XCTAssertNotNil(reloadedViewModel.activatedPackStates[pack.id])
    }

    @MainActor
    func testDeactivateAllPacksRemovesOnlyTrackedEntriesAndPersistsEmptySnapshots() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let suiteName = "DictionaryDeactivatePacks-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .term, original: "ManualTerm")
        service.addEntry(type: .correction, original: "teh", replacement: "the")
        service.learnCorrection(original: "recieve", replacement: "receive")
        let viewModel = DictionaryViewModel(dictionaryService: service, defaults: defaults)
        let firstPack = TermPack(
            id: "first-reset-pack",
            name: "First Reset Pack",
            description: "First reset test pack",
            icon: "shippingbox",
            terms: ["ManualTerm", "FirstPackTerm"],
            corrections: [TermPackCorrection(original: "frist", replacement: "first")],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )
        let secondPack = TermPack(
            id: "second-reset-pack",
            name: "Second Reset Pack",
            description: "Second reset test pack",
            icon: "shippingbox",
            terms: ["SecondPackTerm"],
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )
        viewModel.activatePack(firstPack)
        viewModel.activatePack(secondPack)

        let summary = viewModel.resetRequest(for: .deactivateAllTermPacks)
        XCTAssertEqual(summary.activePackCount, 2)
        XCTAssertEqual(summary.termCount, 2)
        XCTAssertEqual(summary.correctionCount, 1)

        viewModel.requestReset(.deactivateAllTermPacks)
        viewModel.confirmReset()

        XCTAssertEqual(Set(service.entries.map(\.original)), ["ManualTerm", "teh", "recieve"])
        XCTAssertTrue(viewModel.activatedPackStates.isEmpty)
        let persistedStatesData = try XCTUnwrap(
            defaults.data(forKey: UserDefaultsKeys.activatedTermPackStates)
        )
        XCTAssertTrue(try JSONDecoder().decode([ActivatedTermPackState].self, from: persistedStatesData).isEmpty)
        XCTAssertFalse(viewModel.resetRequest(for: .deactivateAllTermPacks).canPerform)
        XCTAssertTrue(DictionaryExporter.exportJSON(service.entries).contains("recieve"))
    }

    @MainActor
    func testResetActionsAreDisabledForEmptyCategoriesIncludingPackWithNoInstalledEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let viewModel = DictionaryViewModel(dictionaryService: service)

        XCTAssertFalse(viewModel.resetRequest(for: .clearAutoLearnedCorrections).canPerform)
        XCTAssertFalse(viewModel.resetRequest(for: .resetCustomDictionary).canPerform)
        XCTAssertFalse(viewModel.resetRequest(for: .deactivateAllTermPacks).canPerform)
        viewModel.requestReset(.clearAutoLearnedCorrections)
        XCTAssertNil(viewModel.pendingResetRequest)

        service.addEntry(type: .term, original: "ExistingTerm")
        let pack = TermPack(
            id: "duplicate-only-pack",
            name: "Duplicate Only",
            description: "Installs no entries",
            icon: "shippingbox",
            terms: ["ExistingTerm"],
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )
        viewModel.activatePack(pack)

        let packSummary = viewModel.resetRequest(for: .deactivateAllTermPacks)
        XCTAssertTrue(packSummary.canPerform)
        XCTAssertEqual(packSummary.activePackCount, 1)
        XCTAssertEqual(packSummary.entryCount, 0)

        viewModel.requestReset(.deactivateAllTermPacks)
        viewModel.confirmReset()
        XCTAssertEqual(service.entries.map(\.original), ["ExistingTerm"])
        XCTAssertTrue(viewModel.activatedPackStates.isEmpty)
    }

    @MainActor
    func testCommercialIndustryPacksAreHiddenWithoutCommercialLicense() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let license = LicenseService(defaults: UserDefaults(suiteName: #function)!)
        let registry = TermPackRegistryService()
        registry.communityPacks = [
            makeCommercialIndustryPack(id: "real-estate", terms: ["Exposé"]),
            makeCommercialIndustryPack(id: "architecture", terms: ["HOAI"]),
            makeCommercialIndustryPack(id: "legal", terms: ["Mandat"])
        ]
        let viewModel = DictionaryViewModel(
            dictionaryService: service,
            licenseService: license,
            termPackRegistryService: registry
        )

        XCTAssertFalse(viewModel.visibleBuiltInPacks.contains { $0.id == "real-estate" })
        XCTAssertFalse(viewModel.visibleBuiltInPacks.contains { $0.id == "architecture" })
        XCTAssertFalse(viewModel.visibleBuiltInPacks.contains { $0.id == "legal" })
        XCTAssertFalse(viewModel.visibleCommunityPacks.contains { $0.id == "real-estate" })
        XCTAssertFalse(viewModel.visibleCommunityPacks.contains { $0.id == "architecture" })
        XCTAssertFalse(viewModel.visibleCommunityPacks.contains { $0.id == "legal" })
    }

    @MainActor
    func testCommercialIndustryPresetActivatesMatchingPackWhenLicensed() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let defaults = UserDefaults(suiteName: #function)!
        let license = LicenseService(defaults: defaults)
        license.licenseStatus = .active
        license.licenseTier = .team
        let registry = TermPackRegistryService()
        let realEstatePack = makeCommercialIndustryPack(id: "real-estate", terms: ["Exposé", "Grundbuch"])
        registry.communityPacks = [realEstatePack]
        let viewModel = DictionaryViewModel(
            dictionaryService: service,
            licenseService: license,
            termPackRegistryService: registry
        )

        viewModel.applyIndustryPreset(.realEstate)

        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedIndustryPreset), IndustryPreset.realEstate.rawValue)
        XCTAssertTrue(viewModel.isPackActivated(realEstatePack))
        XCTAssertTrue(service.entries.contains { $0.original == "Exposé" })
    }

    @MainActor
    func testIndustryPresetStoresSelectionWithoutActivatingPackWhenUnlicensed() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let license = LicenseService(defaults: UserDefaults(suiteName: #function)!)
        let registry = TermPackRegistryService()
        registry.communityPacks = [makeCommercialIndustryPack(id: "architecture", terms: ["HOAI"])]
        let viewModel = DictionaryViewModel(
            dictionaryService: service,
            licenseService: license,
            termPackRegistryService: registry
        )

        viewModel.applyIndustryPreset(.architecture)

        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedIndustryPreset), IndustryPreset.architecture.rawValue)
        XCTAssertFalse(viewModel.activatedPackStates.keys.contains("architecture"))
        XCTAssertFalse(service.entries.contains { $0.original == "HOAI" })
    }

    private func makeCommercialIndustryPack(id: String, terms: [String]) -> TermPack {
        TermPack(
            id: id,
            name: id,
            description: "Industry test pack",
            icon: "shippingbox",
            terms: terms,
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil,
            requiresCommercialLicense: true
        )
    }

    @MainActor
    private func installPlugins(_ plugins: [any TranscriptionEnginePlugin], appSupportDirectory: URL) {
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = plugins.enumerated().map { index, plugin in
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.tests.\(plugin.providerId).\(index)",
                    name: plugin.providerDisplayName,
                    version: "1.0.0",
                    principalClass: "DictionaryServiceTestsPlugin\(index)"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        }
    }

    private func makeLongTerms(count: Int, length: Int) -> [String] {
        (1...count).map { index in
            let prefix = "Term\(index)-"
            let paddingLength = max(0, length - prefix.count)
            return prefix + String(repeating: "x", count: paddingLength)
        }
    }
}

final class TermPackRegistryServiceTests: XCTestCase {
    @MainActor
    func testBackgroundCheckDoesNotRecordTimestampWhenFetchFails() async {
        let suiteName = "TermPackRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TermPackRegistryService(
            userDefaults: defaults,
            fetchData: { _ in throw URLError(.notConnectedToInternet) }
        )

        service.checkForUpdatesInBackground()

        for _ in 0..<20 {
            if case .error = service.fetchState {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(defaults.double(forKey: UserDefaultsKeys.termPackRegistryLastUpdateCheck), 0)
    }

    @MainActor
    func testBackgroundCheckRecordsTimestampWhenFetchSucceeds() async throws {
        let suiteName = "TermPackRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let payload = """
        {
          "schemaVersion": 1,
          "packs": [
            {
              "id": "community-rust",
              "name": "Rust Terms",
              "description": "Rust ecosystem terms",
              "icon": "shippingbox",
              "version": "1.0.0",
              "author": "Tests",
              "requiresCommercialLicense": true,
              "terms": ["Tokio"]
            }
          ]
        }
        """.data(using: .utf8)!

        let service = TermPackRegistryService(
            userDefaults: defaults,
            fetchData: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://example.com/termpacks.json")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (payload, response)
            }
        )

        service.checkForUpdatesInBackground()

        for _ in 0..<20 {
            if service.fetchState == .loaded {
                break
            }
            await Task.yield()
        }

        XCTAssertGreaterThan(defaults.double(forKey: UserDefaultsKeys.termPackRegistryLastUpdateCheck), 0)
        XCTAssertEqual(service.communityPacks.map(\.id), ["community-rust"])
        XCTAssertEqual(service.communityPacks.first?.requiresCommercialLicense, true)
    }
}
