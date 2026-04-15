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
    func testSpacingRulesHandleInlineAndClosingPunctuation() {
        let service = SpeechPunctuationService(rulesLoader: makeRulesLoader())

        let output = service.normalize(
            text: "ciao virgola mondo punto esclamativo",
            language: "it"
        )

        XCTAssertEqual(output, "ciao, mondo!")
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
}
