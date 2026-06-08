import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class SpeechPunctuationServiceTests: XCTestCase {
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
            "今日はいい天気です。"
        )
        XCTAssertEqual(
            service.normalize(text: "予約は明日ですか疑問符", language: "ja"),
            "予約は明日ですか？"
        )
        XCTAssertEqual(
            service.normalize(text: "こんにちは読点よろしくお願いします", language: "ja-JP"),
            "こんにちは、よろしくお願いします"
        )
        XCTAssertEqual(
            service.normalize(text: "タイトルコロン確認事項", language: "ja"),
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
            service.normalize(text: "メモ かっこ開く 重要 かっこ閉じる", language: "ja"),
            "メモ（重要）"
        )
    }

    @MainActor
    func testJapanesePunctuationCommandsAvoidCommonWordSubstrings() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        XCTAssertEqual(
            service.normalize(text: "疑問符号の説明を確認します", language: "ja"),
            "疑問符号の説明を確認します"
        )
        XCTAssertEqual(
            service.normalize(text: "コロンビアの予定を確認します", language: "ja"),
            "コロンビアの予定を確認します"
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
