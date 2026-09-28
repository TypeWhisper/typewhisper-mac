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

    // MARK: - English spoken dates

    @MainActor
    func testSpokenDatesNormalizeMonthAndDayPhrases() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeText("July twenty eighth", language: "en", defaults: defaults),
            "July 28"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeText("May twenty third", language: "en", defaults: defaults),
            "May 23"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeText("June first", language: "en", defaults: defaults),
            "June 1"
        )
        // Cardinals after a month are counts, not dates — only ordinals convert.
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeText("January two", language: "en", defaults: defaults),
            "January two"
        )
    }

    @MainActor
    func testSpokenDatesLeaveCardinalCountsAlone() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        for text in [
            "In July two people left",
            "In June fifteen engineers joined",
            "May one of you help?",
            "Sep second half",
            "Tell Jan one thing",
        ] {
            XCTAssertEqual(
                TranscriptionNormalizationService.normalizeText(text, language: "en", defaults: defaults),
                text
            )
        }
    }

    @MainActor
    func testSpokenDatesRequireNumericDayAfterAbbreviatedMonth() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        // `Jan` is a first name too: only a numeric day makes it a date.
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeText("Ask Jan first", language: "en", defaults: defaults),
            "Ask Jan first"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeText("Jan 5", language: "en", defaults: defaults),
            "Jan 5"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeText("Jan. 5th", language: "en", defaults: defaults),
            "Jan. 5"
        )
    }

    func testSpokenDatesRecognizeDigitAndWordDayForms() {
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates("December 25th", languages: ["en"]),
            "December 25"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates("March 31st", languages: ["en"]),
            "March 31"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates("April ninth", languages: ["en"]),
            "April 9"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates("July twenty-first", languages: ["en"]),
            "July 21"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates("Sept 1st", languages: ["en"]),
            "Sept 1"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates("jun 3rd", languages: ["en"]),
            "jun 3"
        )
    }

    func testSpokenDatesConvertInsideSentences() {
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates(
                "meet me July 28th at noon and August first",
                languages: ["en"]
            ),
            "meet me July 28 at noon and August 1"
        )
        // A word following the day must not be swallowed into a failed match:
        // `first at` is not a day, but `first` on its own is.
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates(
                "June first at noon",
                languages: ["en"]
            ),
            "June 1 at noon"
        )
    }

    func testSpokenDatesAreIdempotent() {
        for text in ["July 28", "August 1", "February 30", "Jul 07"] {
            XCTAssertEqual(
                TranscriptionNormalizationService.normalizeSpokenDates(text, languages: ["en"]),
                text
            )
        }
        let once = TranscriptionNormalizationService.normalizeSpokenDates("October 3rd", languages: ["en"])
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates(once, languages: ["en"]),
            once
        )
    }

    func testSpokenDatesLeaveNonDatesAlone() {
        for text in [
            "first, let's start",
            "the eighth day",
            "July 2026",
            "July 32nd",
            "December 100th",
            "April showers",
            "07/28/2026",
            "next Tuesday",
            // Not a real calendar day.
            "February thirtieth",
            // Hyphenated compounds are not dates.
            "In May one-on-one meetings dropped",
            "May first-rate service",
            // The month-day gap never crosses a newline.
            "Report for July\n12 items shipped",
        ] {
            XCTAssertEqual(
                TranscriptionNormalizationService.normalizeSpokenDates(text, languages: ["en"]),
                text
            )
        }
    }

    func testSpokenDatesDoNotConsumeFollowingMonth() {
        // A rejected `may June` match must not eat `June`: `June first` is
        // still a date.
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates(
                "we may June first",
                languages: ["en"]
            ),
            "we may June 1"
        )
    }

    func testSpokenDatesRequireCapitalizedMayAndMarch() {
        // `may` / `march` double as verbs; only the capitalized form counts as a month.
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates("you may first try again", languages: ["en"]),
            "you may first try again"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates("they march third into battle", languages: ["en"]),
            "they march third into battle"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates("May first", languages: ["en"]),
            "May 1"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates("March 15", languages: ["en"]),
            "March 15"
        )
    }

    func testSpokenDatesSkipOtherLanguages() {
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates("July twenty eighth", languages: ["de"]),
            "July twenty eighth"
        )
        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeSpokenDates("July twenty eighth", languages: []),
            "July twenty eighth"
        )
    }

    @MainActor
    func testSpokenDatesFollowNumberNormalizationSetting() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(false, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        defer { defaults.removePersistentDomain(forName: #function) }

        XCTAssertEqual(
            TranscriptionNormalizationService.normalizeText("July 28th", language: "en", defaults: defaults),
            "July 28th"
        )
    }
}
