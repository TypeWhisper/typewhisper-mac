import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class TranscriptionNormalizationServiceTests: XCTestCase {
    @MainActor
    func testDefaultOnPreservesSmallNumbersBeforePostProcessing() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "I have two questions",
            language: "en",
            defaults: defaults
        )

        XCTAssertEqual(result, "I have two questions")
    }

    @MainActor
    func testDutchLocalePreservesSmallNumbersBeforePostProcessing() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "ik heb twee vragen",
            language: "nl-NL",
            defaults: defaults
        )

        XCTAssertEqual(result, "ik heb twee vragen")
    }

    @MainActor
    func testGlobalOffSkipsNormalization() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(false, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "I have twenty three questions",
            language: "en",
            defaults: defaults
        )

        XCTAssertEqual(result, "I have twenty three questions")
    }

    @MainActor
    func testWorkflowOverrideOffWinsOverGlobalOn() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(true, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "I have twenty three questions",
            language: "en",
            normalizeNumbers: false,
            defaults: defaults
        )

        XCTAssertEqual(result, "I have twenty three questions")
    }

    @MainActor
    func testLaterLanguageCandidateNormalizesWhenConfiguredLanguageDoesNotMatch() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "Set the value to twenty three",
            language: "de",
            languageCandidates: ["de", "en"],
            defaults: defaults
        )

        XCTAssertEqual(result, "Set the value to 23")
    }

    @MainActor
    func testNormalizeResultUsesLaterConfiguredLanguageCandidate() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeResult(
            text: "Set the value to twenty three",
            detectedLanguage: nil,
            configuredLanguage: "de",
            configuredLanguageCandidates: ["de", "en"],
            duration: 1,
            processingTime: 0.1,
            engineUsed: "test",
            segments: [
                TranscriptionSegment(text: "twenty three", start: 0, end: 1)
            ],
            task: .transcribe,
            defaults: defaults
        )

        XCTAssertEqual(result.text, "Set the value to 23")
        XCTAssertEqual(result.segments.first?.text, "23")
    }

    func testMinimumValueDefaultsAndInvalidSettings() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        XCTAssertEqual(TranscriptionNormalizationService.numberNormalizationMinimumValue(defaults: defaults), 10)
        for value in [0, 10, 100] {
            defaults.set(value, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
            XCTAssertEqual(TranscriptionNormalizationService.numberNormalizationMinimumValue(defaults: defaults), value)
        }
        for value in [-1, 3, 999] {
            defaults.set(value, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
            XCTAssertEqual(TranscriptionNormalizationService.numberNormalizationMinimumValue(defaults: defaults), 10)
        }
    }

    func testAlwaysRestoresSmallNumberNormalization() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(0, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
        defer { defaults.removePersistentDomain(forName: #function) }

        XCTAssertEqual(TranscriptionNormalizationService.normalizeText("one of my clients", language: "en", defaults: defaults), "1 of my clients")
    }

    func testWorkflowOverrideOnUsesGlobalThresholdEvenWhenGlobalNormalizationIsOff() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(false, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        defaults.set(100, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
        defer { defaults.removePersistentDomain(forName: #function) }

        let text = "three, ten, one hundred"
        XCTAssertEqual(TranscriptionNormalizationService.normalizeText(text, language: "en", defaults: defaults), text)
        XCTAssertEqual(TranscriptionNormalizationService.normalizeText(text, language: "en", normalizeNumbers: true, defaults: defaults), "three, ten, 100")
    }

    func testThresholdAppliesConsistentlyToTextAndSegments() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(100, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeResult(
            text: "Three, twenty-three, one hundred",
            detectedLanguage: "en",
            configuredLanguage: "en",
            duration: 3,
            processingTime: 0.1,
            engineUsed: "test",
            segments: [
                TranscriptionSegment(text: "Three, twenty-three", start: 0, end: 1),
                TranscriptionSegment(text: "one hundred", start: 1, end: 3)
            ],
            task: .transcribe,
            defaults: defaults
        )

        XCTAssertEqual(result.text, "Three, twenty-three, 100")
        XCTAssertEqual(result.segments.map(\.text), ["Three, twenty-three", "100"])
        XCTAssertEqual(result.segments.map(\.start), [0, 1])
        XCTAssertEqual(result.segments.map(\.end), [1, 3])
    }

    // MARK: - German time notation (DIN 5008)

    func testGermanTimeNotationReplacesPeriodWithColon() {
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeTimeNotation(
                "Wir treffen uns um 20.45 Uhr",
                languages: ["de"]
            ),
            "Wir treffen uns um 20:45 Uhr"
        )
    }

    func testGermanTimeNotationAcceptsRegionalCodeAndLetterCase() {
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeTimeNotation("um 9.30 uhr", languages: ["de-DE"]),
            "um 9:30 uhr"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeTimeNotation("09.00 UHR", languages: ["de_DE"]),
            "09:00 UHR"
        )
    }

    func testGermanTimeNotationLeavesDottedNumbersAlone() {
        for text in [
            "Die Kosten betragen 20.450 Euro",
            "Termin am 19.04.2026",
            "Version 20.45.1 ist da",
            "Termin am 19.20.45 Uhr",
            "Er sagt 20.45. zurück"
        ] {
            XCTAssertEqual(
                TranscriptionNormalizationService.normalizeTimeNotation(text, languages: ["de"]),
                text
            )
        }
    }

    func testGermanTimeNotationSkipsInvalidTimesAndPartialMinutes() {
        for text in [
            "99.99 Uhr",
            "20.75 Uhr",
            "24.00 Uhr",
            "9.5 Uhr",
            "20.45",
            "Preis: 12.90"
        ] {
            XCTAssertEqual(
                TranscriptionNormalizationService.normalizeTimeNotation(text, languages: ["de"]),
                text
            )
        }
    }

    func testTimeNotationIsNotAppliedToOtherLanguages() {
        let text = "Meeting um 20.45 Uhr"

        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeTimeNotation(text, languages: ["en"]),
            text
        )
        XCTAssertEqual(TranscriptionNormalizationService.normalizeTimeNotation(text, languages: []), text)
    }

    func testTimeNotationDoesNotRewriteSpelledOutTimes() {
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeTimeNotation("Zwanzig Uhr 45", languages: ["de"]),
            "Zwanzig Uhr 45"
        )
    }

    func testTimeNotationRequiresWordBoundaryAfterUhr() {
        for text in [
            "Der Vortrag beginnt um 12.50 Uhren",
            "Die 20.45 Uhrzeit ist falsch",
            "Sein 9.30 Uhrwerk tickt laut"
        ] {
            XCTAssertEqual(
                TranscriptionNormalizationService.normalizeTimeNotation(text, languages: ["de"]),
                text
            )
        }
        // Uhr followed by punctuation or end of string still rewrites.
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeTimeNotation("Treffen um 20.45 Uhr.", languages: ["de"]),
            "Treffen um 20:45 Uhr."
        )
    }

    func testTimeNotationRewritesTimeRanges() {
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeTimeNotation("von 9.00 bis 17.00 Uhr", languages: ["de"]),
            "von 9:00 bis 17:00 Uhr"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeTimeNotation("zwischen 14.30 und 15.00 Uhr", languages: ["de"]),
            "zwischen 14:30 und 15:00 Uhr"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeTimeNotation("Sprechstunde 9.00-17.00 Uhr", languages: ["de"]),
            "Sprechstunde 9:00-17:00 Uhr"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeTimeNotation("Sprechstunde 9.00–17.00 Uhr", languages: ["de"]),
            "Sprechstunde 9:00–17:00 Uhr"
        )
        // A range without Uhr stays untouched.
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeTimeNotation("von 9.00 bis 17.00", languages: ["de"]),
            "von 9.00 bis 17.00"
        )
    }

    @MainActor
    func testTimeNotationAppliesThroughNormalizeTextWhenNumberNormalizationIsOff() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(false, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "Wir treffen uns um 20.45 Uhr",
            language: "de",
            defaults: defaults
        )

        XCTAssertEqual(result, "Wir treffen uns um 20:45 Uhr")
    }

    @MainActor
    func testTimeNotationAppliesToSegmentsAndTextThroughNormalizeResult() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeResult(
            text: "um 20.45 Uhr",
            detectedLanguage: "de",
            configuredLanguage: "de",
            duration: 2,
            processingTime: 0.1,
            engineUsed: "test",
            segments: [
                TranscriptionSegment(text: "um 20.45 Uhr", start: 0, end: 1),
                TranscriptionSegment(text: "um 9.30 Uhr", start: 1, end: 2)
            ],
            task: .transcribe,
            defaults: defaults
        )

        XCTAssertEqual(result.text, "um 20:45 Uhr")
        XCTAssertEqual(result.segments.map(\.text), ["um 20:45 Uhr", "um 9:30 Uhr"])
    }

    @MainActor
    func testPipelineRewritesTimeIntroducedByCorrections() async throws {
        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)

        let previousPluginManager = PluginManager.shared
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        defer {
            PluginManager.shared = previousPluginManager
            try? FileManager.default.removeItem(at: appSupportDirectory)
        }
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let profileStore = DictationPunctuationProfileStore(defaults: UserDefaults(suiteName: #function)!, storageKey: #function)
        dictionaryService.addEntry(type: .correction, original: "TIME", replacement: "20.45 Uhr")

        let pipeline = PostProcessingPipeline(
            snippetService: SnippetService(),
            dictionaryService: dictionaryService,
            appFormatterService: nil,
            punctuationStrategyResolver: PunctuationStrategyResolver(profileStore: profileStore)
        )

        let result = try await pipeline.process(
            text: "Treffen um TIME",
            context: PostProcessingContext(language: "de"),
            dictationContext: DictationRuntimeContext(
                engineId: nil,
                modelId: nil,
                configuredLanguage: "de",
                detectedLanguage: nil
            )
        )

        XCTAssertEqual(result.text, "Treffen um 20:45 Uhr")
        XCTAssertEqual(result.appliedSteps, ["Corrections", "Time Notation"])
    }
}
