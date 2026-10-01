import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class SpeechPunctuationServiceTests: XCTestCase {
    private var originalNumberNormalizationMinimumValue: Any?

    override func setUp() {
        super.setUp()
        originalNumberNormalizationMinimumValue = UserDefaults.standard.object(forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
        UserDefaults.standard.set(10, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
    }

    override func tearDown() {
        if let originalNumberNormalizationMinimumValue {
            UserDefaults.standard.set(originalNumberNormalizationMinimumValue, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
        }
        super.tearDown()
    }

    @MainActor
    func testRepeatedNormalizationKeepsLanguageRulesAndAliasesSeparate() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())
        for _ in 0..<3 {
            XCTAssertEqual(service.normalize(text: "ciao virgola mondo", language: "it-IT"), "ciao, mondo")
            XCTAssertEqual(service.normalize(text: "メモ 鍵かっこ開く 重要 鍵かっこ閉じる", language: "ja_JP"), "メモ「重要」")
            XCTAssertEqual(service.normalize(text: "ciao virgola mondo", language: "it"), "ciao, mondo")
            XCTAssertEqual(service.normalize(text: "unchanged", language: "unknown"), "unchanged")
        }
    }

    @MainActor
    func testLongWhitespaceRunsPreserveMixedScriptSpacing() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())
        let spaces = String(repeating: " \t\n", count: 1000)
        XCTAssertEqual(service.normalize(text: "ciao\(spaces)mondo", language: "it"), "ciao mondo")
        XCTAssertEqual(service.normalize(text: "ciao\(spaces)mondo", language: "it", mode: .selectiveFallback), "ciao\(spaces)mondo")
        XCTAssertEqual(service.normalize(text: "メモ（\(spaces)重要\(spaces)）", language: "ja"), "メモ（重要）")
        XCTAssertEqual(service.normalize(text: "確認？\(spaces)next", language: "ja"), "確認？ next")
    }

    private func makeRulesLoader() -> PunctuationRulesLoader {
        PunctuationRulesLoader { languageCode in
            switch languageCode {
            case "it":
                return """
                {
                  "language": "it",
                  "rules": [
                    { "phrase": "punto interrogativo", "replacement": "?", "category": "punctuation" },
                    { "phrase": "punto esclamativo", "replacement": "!", "category": "punctuation" },
                    { "phrase": "aperta parentesi", "replacement": "(", "category": "brackets" },
                    { "phrase": "chiusa parentesi", "replacement": ")", "category": "brackets" },
                    { "phrase": "virgola", "replacement": ",", "category": "punctuation" }
                  ],
                  "verificationScenarios": []
                }
                """.data(using: .utf8)
            case "ja":
                return """
                {
                  "language": "ja",
                  "rules": [
                    { "phrase": "句点", "replacement": "。", "category": "punctuation" },
                    { "phrase": "読点", "replacement": "、", "category": "punctuation" },
                    { "phrase": "疑問符", "replacement": "？", "category": "punctuation" },
                    { "phrase": "コロン", "replacement": "：", "category": "punctuation" },
                    { "phrase": "セミコロン", "replacement": "；", "category": "punctuation" },
                    { "phrase": "かっこ開く", "replacement": "（", "category": "brackets" },
                    { "phrase": "かっこ閉じる", "replacement": "）", "category": "brackets" },
                    { "phrase": "鍵かっこ開く", "replacement": "「", "category": "quotes" },
                    { "phrase": "鍵かっこ閉じる", "replacement": "」", "category": "quotes" }
                  ],
                  "verificationScenarios": []
                }
                """.data(using: .utf8)
            default:
                return nil
            }
        }
    }

    @MainActor
    func testItalianParenthesesCommandsNormalizeToSymbols() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        let output = service.normalize(
            text: "ciao aperta parentesi mondo chiusa parentesi",
            language: "it"
        )

        XCTAssertEqual(output, "ciao (mondo)")
    }

    @MainActor
    func testItalianRegionalLanguageCodeUsesSameRules() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        let output = service.normalize(
            text: "ciao punto interrogativo",
            language: "it-IT"
        )

        XCTAssertEqual(output, "ciao?")
    }

    @MainActor
    func testUnsupportedOrMissingLanguageIsNoOp() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        XCTAssertEqual(service.normalize(text: "ciao aperta parentesi mondo", language: "en"), "ciao aperta parentesi mondo")
        XCTAssertEqual(service.normalize(text: "ciao aperta parentesi mondo", language: nil), "ciao aperta parentesi mondo")
    }

    @MainActor
    func testWordBoundariesPreventPartialMatches() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        let output = service.normalize(
            text: "virgolare virgola puntuale",
            language: "it"
        )

        XCTAssertEqual(output, "virgolare, puntuale")
    }

    @MainActor
    func testJapanesePunctuationCommandsRequireCommandBoundaries() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        XCTAssertEqual(
            service.normalize(text: "今日はいい天気です 句点", language: "ja"),
            "今日はいい天気です。"
        )
        XCTAssertEqual(
            service.normalize(text: "今日はいい天気です句点", language: "ja"),
            "今日はいい天気です句点"
        )
        XCTAssertEqual(
            service.normalize(text: "予約は明日ですか 疑問符", language: "ja"),
            "予約は明日ですか？"
        )
        XCTAssertEqual(
            service.normalize(text: "こんにちは 読点 よろしくお願いします", language: "ja-JP"),
            "こんにちは、よろしくお願いします"
        )
        XCTAssertEqual(
            service.normalize(text: "タイトル コロン 確認事項", language: "ja"),
            "タイトル：確認事項"
        )
        XCTAssertEqual(
            service.normalize(text: "メモ かっこ開く 重要 かっこ閉じる", language: "ja"),
            "メモ（重要）"
        )
    }

    @MainActor
    func testJapanesePunctuationCommandsRemoveRecognizerInsertedSpaces() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        XCTAssertEqual(
            service.normalize(text: "こんにちは 読点 よろしくお願いします", language: "ja"),
            "こんにちは、よろしくお願いします"
        )
        XCTAssertEqual(
            service.normalize(text: "こんにちは 読点   よろしくお願いします", language: "ja"),
            "こんにちは、よろしくお願いします"
        )
        XCTAssertEqual(
            service.normalize(text: "メモ かっこ開く 重要 かっこ閉じる", language: "ja"),
            "メモ（重要）"
        )
    }

    @MainActor
    func testJapanesePunctuationPreservesSpaceBeforeLatinText() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        XCTAssertEqual(
            service.normalize(text: "これは TypeWhisper 疑問符 next", language: "ja"),
            "これは TypeWhisper？ next"
        )
        XCTAssertEqual(
            service.normalize(text: "これは TypeWhisper 疑問符 2026", language: "ja"),
            "これは TypeWhisper？ 2026"
        )
        XCTAssertEqual(
            service.normalize(text: "これは TypeWhisper 疑問符 𠮷田さん", language: "ja"),
            "これは TypeWhisper？𠮷田さん"
        )
    }

    @MainActor
    func testJapanesePunctuationCommandsAvoidCommonWordSubstrings() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        XCTAssertEqual(
            service.normalize(text: "句点の使い方を説明します", language: "ja"),
            "句点の使い方を説明します"
        )
        XCTAssertEqual(
            service.normalize(text: "疑問符の説明を確認します", language: "ja"),
            "疑問符の説明を確認します"
        )
        XCTAssertEqual(
            service.normalize(text: "読点を入力する方法です", language: "ja"),
            "読点を入力する方法です"
        )
        XCTAssertEqual(
            service.normalize(text: "読点は文の区切りです", language: "ja"),
            "読点は文の区切りです"
        )
        XCTAssertEqual(
            service.normalize(text: "コロンの使い方を説明します", language: "ja"),
            "コロンの使い方を説明します"
        )
        XCTAssertEqual(
            service.normalize(text: "コロンを説明します", language: "ja"),
            "コロンを説明します"
        )
        XCTAssertEqual(
            service.normalize(text: "マイクロコロン", language: "ja"),
            "マイクロコロン"
        )
        XCTAssertEqual(
            service.normalize(text: "セミコロンを入力する方法です", language: "ja"),
            "セミコロンを入力する方法です"
        )
        XCTAssertEqual(
            service.normalize(text: "疑問符号の説明を確認します", language: "ja"),
            "疑問符号の説明を確認します"
        )
        XCTAssertEqual(
            service.normalize(text: "コロンビアの予定を確認します", language: "ja"),
            "コロンビアの予定を確認します"
        )
        XCTAssertEqual(
            service.normalize(text: "かっこ開く方法を説明します", language: "ja"),
            "かっこ開く方法を説明します"
        )
        XCTAssertEqual(
            service.normalize(text: "鍵かっこ閉じる方法を説明します", language: "ja"),
            "鍵かっこ閉じる方法を説明します"
        )
    }

    @MainActor
    func testJapaneseLongerBracketPhrasesTakePrecedence() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        XCTAssertEqual(
            service.normalize(text: "メモ 鍵かっこ開く 重要 鍵かっこ閉じる", language: "ja"),
            "メモ「重要」"
        )
        XCTAssertEqual(
            service.normalize(text: "メモ 鍵かっこ開く 重要 鍵かっこ閉じる", language: "ja-JP"),
            "メモ「重要」"
        )
    }

    @MainActor
    func testSpacingRulesHandleInlineAndClosingPunctuation() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        let output = service.normalize(
            text: "ciao virgola mondo punto esclamativo",
            language: "it"
        )

        XCTAssertEqual(output, "ciao, mondo!")
    }

    @MainActor
    func testSelectiveFallbackAvoidsDuplicatePunctuationWhenNativePunctuationIsAfterPhrase() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        let output = service.normalize(
            text: "come stai punto interrogativo?",
            language: "it",
            mode: .selectiveFallback
        )

        XCTAssertEqual(output, "come stai?")
    }

    @MainActor
    func testSelectiveFallbackAvoidsDuplicatePunctuationWhenNativePunctuationIsBeforePhrase() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        let output = service.normalize(
            text: "come stai? punto interrogativo",
            language: "it",
            mode: .selectiveFallback
        )

        XCTAssertEqual(output, "come stai?")
    }

    @MainActor
    func testSelectiveFallbackAvoidsDuplicateJapanesePunctuationWithASCIIEquivalents() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        XCTAssertEqual(
            service.normalize(
                text: "予約は明日ですか 疑問符?",
                language: "ja",
                mode: .selectiveFallback
            ),
            "予約は明日ですか?"
        )
        XCTAssertEqual(
            service.normalize(
                text: "予約は明日ですか? 疑問符",
                language: "ja",
                mode: .selectiveFallback
            ),
            "予約は明日ですか?"
        )
    }

    @MainActor
    func testSelectiveFallbackKeepsRepeatedExplicitPunctuationPhrases() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        let output = service.normalize(
            text: "punto interrogativo punto interrogativo",
            language: "it",
            mode: .selectiveFallback
        )

        XCTAssertEqual(output, "??")
    }

    @MainActor
    func testPipelineAppliesSpeechPunctuationBeforeDictionaryCorrections() async throws {
        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        let profileStore = DictationPunctuationProfileStore(defaults: UserDefaults(suiteName: #function)!, storageKey: #function)
        let strategyResolver = PunctuationStrategyResolver(profileStore: profileStore)
        dictionaryService.addEntry(type: .correction, original: "(", replacement: "[", caseSensitive: true)
        dictionaryService.addEntry(type: .correction, original: ")", replacement: "]", caseSensitive: true)

        let pipeline = PostProcessingPipeline(
            snippetService: SnippetService(),
            dictionaryService: dictionaryService,
            appFormatterService: nil,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: makeRulesLoader()),
            punctuationStrategyResolver: strategyResolver
        )

        let result = try await pipeline.process(
            text: "ciao aperta parentesi mondo chiusa parentesi",
            context: PostProcessingContext(language: "it"),
            dictationContext: DictationRuntimeContext(
                engineId: "parakeet",
                modelId: "parakeet-v3",
                configuredLanguage: "it",
                detectedLanguage: nil
            )
        )

        XCTAssertEqual(result.text, "ciao [mondo]")
        XCTAssertEqual(result.appliedSteps, ["Speech Punctuation", "Corrections"])
    }

    @MainActor
    func testPipelineAppliesDictionaryCorrectionsBeforeAndAfterLLMStep() async throws {
        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        let profileStore = DictationPunctuationProfileStore(defaults: UserDefaults(suiteName: #function)!, storageKey: #function)
        let strategyResolver = PunctuationStrategyResolver(profileStore: profileStore)
        dictionaryService.addEntry(type: .correction, original: "dev and think", replacement: "DEVONthink")

        let pipeline = PostProcessingPipeline(
            snippetService: SnippetService(),
            dictionaryService: dictionaryService,
            appFormatterService: nil,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: makeRulesLoader()),
            punctuationStrategyResolver: strategyResolver
        )

        var llmInput: String?
        let result = try await pipeline.process(
            text: "go into dev and think for me",
            context: PostProcessingContext(language: "en"),
            dictationContext: DictationRuntimeContext(
                engineId: "parakeet",
                modelId: "parakeet-v3",
                configuredLanguage: "en",
                detectedLanguage: nil
            ),
            llmHandler: { input in
                llmInput = input
                // The LLM re-punctuates and introduces a fresh misrecognition of its own.
                return input.replacingOccurrences(of: "DEVONthink for me", with: "DEVONthink, for me, in dev and think")
            },
            llmStepName: "Workflow"
        )

        XCTAssertEqual(llmInput, "go into DEVONthink for me")
        XCTAssertEqual(result.text, "go into DEVONthink, for me, in DEVONthink")
        XCTAssertEqual(result.appliedSteps, ["Corrections", "Workflow"])
    }

    @MainActor
    func testTextBeforeLLMStepIncludesPreLLMCorrectionsWithoutCountingUsage() async throws {
        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        let profileStore = DictationPunctuationProfileStore(defaults: UserDefaults(suiteName: #function)!, storageKey: #function)
        let strategyResolver = PunctuationStrategyResolver(profileStore: profileStore)
        dictionaryService.addEntry(type: .correction, original: "dev and think", replacement: "DEVONthink")

        let pipeline = PostProcessingPipeline(
            snippetService: SnippetService(),
            dictionaryService: dictionaryService,
            appFormatterService: nil,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: makeRulesLoader()),
            punctuationStrategyResolver: strategyResolver
        )
        let context = PostProcessingContext(language: "en")
        let dictationContext = DictationRuntimeContext(
            engineId: "parakeet",
            modelId: "parakeet-v3",
            configuredLanguage: "en",
            detectedLanguage: nil
        )

        // Segmented workflow processing prepares text during recording with this path;
        // it must match the final LLM input, or the prefix check at stop discards the work.
        let prepared = pipeline.textBeforeLLMStep(
            "go into dev and think for me",
            context: context,
            dictationContext: dictationContext,
            outputFormat: nil,
            normalizeNumbers: nil
        )
        XCTAssertEqual(dictionaryService.corrections.first?.usageCount, 0)

        var llmInput: String?
        _ = try await pipeline.process(
            text: "go into dev and think for me",
            context: context,
            dictationContext: dictationContext,
            llmHandler: { input in
                llmInput = input
                return input
            },
            llmStepName: "Workflow"
        )

        XCTAssertEqual(prepared, "go into DEVONthink for me")
        XCTAssertEqual(prepared, llmInput)
        XCTAssertEqual(dictionaryService.corrections.first?.usageCount, 1)
    }

    @MainActor
    private func makeCorrectionPipeline(
        original: String,
        replacement: String,
        function: String = #function
    ) throws -> (pipeline: PostProcessingPipeline, dictionaryService: DictionaryService, cleanup: () -> Void) {
        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        let profileStore = DictationPunctuationProfileStore(defaults: UserDefaults(suiteName: function)!, storageKey: function)
        dictionaryService.addEntry(type: .correction, original: original, replacement: replacement)

        let pipeline = PostProcessingPipeline(
            snippetService: SnippetService(),
            dictionaryService: dictionaryService,
            appFormatterService: nil,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: makeRulesLoader()),
            punctuationStrategyResolver: PunctuationStrategyResolver(profileStore: profileStore)
        )
        return (pipeline, dictionaryService, { try? FileManager.default.removeItem(at: appSupportDirectory) })
    }

    @MainActor
    func testPipelineDoesNotReexpandCorrectionWhoseReplacementContainsItsOriginal() async throws {
        let setup = try makeCorrectionPipeline(original: "GitHub", replacement: "GitHub.com")
        defer { setup.cleanup() }
        let dictationContext = DictationRuntimeContext(
            engineId: "parakeet",
            modelId: "parakeet-v3",
            configuredLanguage: "en",
            detectedLanguage: nil
        )

        var llmInput: String?
        let withLLM = try await setup.pipeline.process(
            text: "Visit GitHub",
            context: PostProcessingContext(language: "en"),
            dictationContext: dictationContext,
            llmHandler: { input in
                llmInput = input
                return input
            },
            llmStepName: "Workflow"
        )
        let withoutLLM = try await setup.pipeline.process(
            text: "Visit GitHub",
            context: PostProcessingContext(language: "en"),
            dictationContext: dictationContext
        )

        XCTAssertEqual(llmInput, "Visit GitHub.com")
        XCTAssertEqual(withLLM.text, "Visit GitHub.com")
        XCTAssertEqual(withoutLLM.text, "Visit GitHub.com")
    }

    @MainActor
    func testPipelineCountsCorrectionUsageOncePerDictationAcrossBothPasses() async throws {
        let setup = try makeCorrectionPipeline(original: "dev and think", replacement: "DEVONthink")
        defer { setup.cleanup() }
        let dictationContext = DictationRuntimeContext(
            engineId: "parakeet",
            modelId: "parakeet-v3",
            configuredLanguage: "en",
            detectedLanguage: nil
        )

        // The LLM reintroduces the misrecognition, so both passes apply the correction.
        let reverted = try await setup.pipeline.process(
            text: "use dev and think",
            context: PostProcessingContext(language: "en"),
            dictationContext: dictationContext,
            llmHandler: { _ in "use dev and think" },
            llmStepName: "Workflow"
        )
        XCTAssertEqual(reverted.text, "use DEVONthink")
        XCTAssertEqual(setup.dictionaryService.corrections.first?.usageCount, 1)

        // The LLM keeps the corrected text, so only the pre-LLM pass applies; it still counts.
        let kept = try await setup.pipeline.process(
            text: "use dev and think",
            context: PostProcessingContext(language: "en"),
            dictationContext: dictationContext,
            llmHandler: { input in input },
            llmStepName: "Workflow"
        )
        XCTAssertEqual(kept.text, "use DEVONthink")
        XCTAssertEqual(setup.dictionaryService.corrections.first?.usageCount, 2)
    }

    @MainActor
    func testPipelineDoesNotReexpandCaseFoldEquivalentOriginal() async throws {
        // Case-insensitive matching finds `Strasse` inside `Straße.` although both have seven
        // characters, so the post-LLM pass must still treat the corrected text as corrected.
        let setup = try makeCorrectionPipeline(original: "Strasse", replacement: "Straße.")
        defer { setup.cleanup() }
        let dictationContext = DictationRuntimeContext(
            engineId: "parakeet",
            modelId: "parakeet-v3",
            configuredLanguage: "de",
            detectedLanguage: nil
        )

        var llmInput: String?
        let withLLM = try await setup.pipeline.process(
            text: "Die Strasse",
            context: PostProcessingContext(language: "de"),
            dictationContext: dictationContext,
            llmHandler: { input in
                llmInput = input
                return input
            },
            llmStepName: "Workflow"
        )
        let withoutLLM = try await setup.pipeline.process(
            text: "Die Strasse",
            context: PostProcessingContext(language: "de"),
            dictationContext: dictationContext
        )

        XCTAssertEqual(llmInput, "Die Straße.")
        XCTAssertEqual(withLLM.text, "Die Straße.")
        XCTAssertEqual(withoutLLM.text, "Die Straße.")
    }

    @MainActor
    func testPipelineDoesNotExpandRepeatedCharacterReplacementAcrossBothPasses() async throws {
        let setup = try makeCorrectionPipeline(original: "--", replacement: "---")
        defer { setup.cleanup() }

        let result = try await setup.pipeline.process(
            text: "a -- b -- c",
            context: PostProcessingContext(language: "en"),
            dictationContext: DictationRuntimeContext(
                engineId: "parakeet",
                modelId: "parakeet-v3",
                configuredLanguage: "en",
                detectedLanguage: nil
            ),
            llmHandler: { input in input },
            llmStepName: "Workflow"
        )

        XCTAssertEqual(result.text, "a --- b --- c")
    }

    @MainActor
    func testPreLLMCorrectionUsageIsNotCountedWhenRawFallbackIsInserted() async throws {
        let setup = try makeCorrectionPipeline(original: "dev and think", replacement: "DEVONthink")
        defer { setup.cleanup() }

        let result = try await setup.pipeline.process(
            text: "use dev and think",
            context: PostProcessingContext(language: "en"),
            dictationContext: DictationRuntimeContext(
                engineId: "parakeet",
                modelId: "parakeet-v3",
                configuredLanguage: "en",
                detectedLanguage: nil
            ),
            llmHandler: { _ in throw URLError(.badServerResponse) },
            llmStepName: "Workflow",
            llmFailureFallbackText: "use dev and think"
        )

        XCTAssertNotNil(result.fallback)
        XCTAssertEqual(result.text, "use dev and think")
        XCTAssertEqual(setup.dictionaryService.corrections.first?.usageCount, 0)
    }

    @MainActor
    func testPreLLMCorrectionUsageIsNotCountedWhenProcessingIsCancelled() async throws {
        let setup = try makeCorrectionPipeline(original: "dev and think", replacement: "DEVONthink")
        defer { setup.cleanup() }

        do {
            _ = try await setup.pipeline.process(
                text: "use dev and think",
                context: PostProcessingContext(language: "en"),
                dictationContext: DictationRuntimeContext(
                    engineId: "parakeet",
                    modelId: "parakeet-v3",
                    configuredLanguage: "en",
                    detectedLanguage: nil
                ),
                llmHandler: { _ in throw CancellationError() },
                llmStepName: "Workflow",
                llmFailureFallbackText: "use dev and think"
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }

        XCTAssertEqual(setup.dictionaryService.corrections.first?.usageCount, 0)
    }

    @MainActor
    func testPipelineAppliesWhitespaceFillerCorrections() async throws {
        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        let profileStore = DictationPunctuationProfileStore(defaults: UserDefaults(suiteName: #function)!, storageKey: #function)
        let strategyResolver = PunctuationStrategyResolver(profileStore: profileStore)
        dictionaryService.addEntry(type: .correction, original: "um", replacement: "")

        let pipeline = PostProcessingPipeline(
            snippetService: SnippetService(),
            dictionaryService: dictionaryService,
            appFormatterService: nil,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: makeRulesLoader()),
            punctuationStrategyResolver: strategyResolver
        )

        let result = try await pipeline.process(
            text: "Um this still works",
            context: PostProcessingContext(language: "en"),
            dictationContext: DictationRuntimeContext(
                engineId: "parakeet",
                modelId: "parakeet-v3",
                configuredLanguage: "en",
                detectedLanguage: nil
            )
        )

        XCTAssertEqual(result.text, "this still works")
        XCTAssertEqual(result.appliedSteps, ["Corrections"])
    }

    @MainActor
    func testPipelineNormalizesNumbersBeforeLaterPostProcessing() async throws {
        let previousDefault = UserDefaults.standard.object(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        defer {
            if let previousDefault {
                UserDefaults.standard.set(previousDefault, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
            }
        }

        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let pipeline = makePipeline(appSupportDirectory: appSupportDirectory)

        let result = try await pipeline.process(
            text: "twenty three",
            context: PostProcessingContext(language: "en"),
            dictationContext: DictationRuntimeContext(
                engineId: "mock",
                modelId: "tiny",
                configuredLanguage: "en",
                detectedLanguage: nil
            )
        )

        XCTAssertEqual(result.text, "23")
        XCTAssertEqual(result.appliedSteps, ["Number Normalization"])
    }

    @MainActor
    func testPipelineNumberNormalizationOverrideOffWinsOverGlobalOn() async throws {
        let previousDefault = UserDefaults.standard.object(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        defer {
            if let previousDefault {
                UserDefaults.standard.set(previousDefault, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
            }
        }

        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let pipeline = makePipeline(appSupportDirectory: appSupportDirectory)

        let result = try await pipeline.process(
            text: "twenty three",
            context: PostProcessingContext(language: "en"),
            dictationContext: DictationRuntimeContext(
                engineId: "mock",
                modelId: "tiny",
                configuredLanguage: "en",
                detectedLanguage: nil
            ),
            normalizeNumbers: false
        )

        XCTAssertEqual(result.text, "twenty three")
        XCTAssertFalse(result.appliedSteps.contains("Number Normalization"))
    }

    @MainActor
    func testPipelineReturnsRawFallbackWhenLLMProcessingFails() async throws {
        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let pipeline = makePipeline(appSupportDirectory: appSupportDirectory)
        let rawText = "twenty three"

        let result = try await pipeline.process(
            text: rawText,
            context: PostProcessingContext(language: "en"),
            dictationContext: DictationRuntimeContext(
                engineId: "mock",
                modelId: "tiny",
                configuredLanguage: "en",
                detectedLanguage: nil
            ),
            llmHandler: { intermediateText in
                XCTAssertEqual(intermediateText, "23")
                throw NSError(
                    domain: "PostProcessingPipelineTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Provider unavailable"]
                )
            },
            llmStepName: "Workflow",
            normalizeNumbers: true,
            llmFailureFallbackText: rawText
        )

        XCTAssertEqual(result.text, rawText)
        XCTAssertEqual(result.appliedSteps, [])
        XCTAssertEqual(
            result.fallback,
            PostProcessingFallback(failedStep: "Workflow", reason: "Provider unavailable")
        )
    }

    @MainActor
    func testPipelineDoesNotTreatCancellationAsRawFallback() async throws {
        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let pipeline = makePipeline(appSupportDirectory: appSupportDirectory)

        do {
            _ = try await pipeline.process(
                text: "Keep this text",
                context: PostProcessingContext(language: "en"),
                llmHandler: { _ in throw CancellationError() },
                llmStepName: "Workflow",
                llmFailureFallbackText: "Keep this text"
            )
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected: cancellation must not continue into text insertion.
        }
    }

    @MainActor
    func testPipelineDoesNotTreatCancelledURLErrorAsRawFallback() async throws {
        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let pipeline = makePipeline(appSupportDirectory: appSupportDirectory)

        do {
            _ = try await pipeline.process(
                text: "Keep this text",
                context: PostProcessingContext(language: "en"),
                llmHandler: { _ in throw URLError(.cancelled) },
                llmStepName: "Workflow",
                llmFailureFallbackText: "Keep this text"
            )
            XCTFail("Expected URL cancellation to propagate")
        } catch is CancellationError {
            // Expected: provider cancellation must not continue into text insertion.
        }
    }

    @MainActor
    private func makePipeline(appSupportDirectory: URL) -> PostProcessingPipeline {
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        let profileStore = DictationPunctuationProfileStore(defaults: UserDefaults(suiteName: #function)!, storageKey: #function)
        return PostProcessingPipeline(
            snippetService: SnippetService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            appFormatterService: nil,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: makeRulesLoader()),
            punctuationStrategyResolver: PunctuationStrategyResolver(profileStore: profileStore)
        )
    }
}
