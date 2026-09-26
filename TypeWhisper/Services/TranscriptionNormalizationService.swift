import Foundation

enum TranscriptionNormalizationService {
    static let defaultNumberNormalizationMinimumValue = 10

    static func numberNormalizationMinimumValue(defaults: UserDefaults = .standard) -> Int {
        guard let value = defaults.object(forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue) as? Int,
              [0, 10, 100].contains(value) else {
            return defaultNumberNormalizationMinimumValue
        }
        return value
    }

    static func numberNormalizationEnabled(
        override: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let override {
            return override
        }

        if defaults.object(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled) == nil {
            return true
        }

        return defaults.bool(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
    }

    static func normalizeText(
        _ text: String,
        language: String?,
        languageCandidates: [String] = [],
        normalizeNumbers: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> String {
        // No early return on the number-normalization setting here: the time
        // rewrite runs independently of it, and normalizeNumberWords already
        // checks the setting itself.
        return normalizeText(
            text,
            languages: prioritizedLanguages(primary: language, candidates: languageCandidates),
            normalizeNumbers: normalizeNumbers,
            defaults: defaults
        )
    }

    static func normalizeText(
        _ text: String,
        languages: [String],
        normalizeNumbers: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> String {
        let numberNormalized = normalizeNumberWords(
            text,
            languages: languages,
            normalizeNumbers: normalizeNumbers,
            defaults: defaults
        )
        let dateNormalized = normalizeSpokenDates(
            numberNormalized,
            languages: languages,
            normalizeNumbers: normalizeNumbers,
            defaults: defaults
        )

        return normalizeTimeNotation(dateNormalized, languages: languages)
    }

    private static func normalizeNumberWords(
        _ text: String,
        languages: [String],
        normalizeNumbers: Bool?,
        defaults: UserDefaults
    ) -> String {
        guard numberNormalizationEnabled(override: normalizeNumbers, defaults: defaults) else {
            return text
        }

        let minimumValue = numberNormalizationMinimumValue(defaults: defaults)
        for language in prioritizedLanguages(primary: nil, candidates: languages) {
            let normalized = NumberWordNormalizer.normalize(text: text, language: language, minimumValue: minimumValue)
            if normalized != text {
                return normalized
            }
        }

        return text
    }

    /// Rewrites German clock times that use a period as the hour/minute separator,
    /// such as `20.45 Uhr`, to the colon form `20:45 Uhr` required by DIN 5008.
    ///
    /// Only a time written directly in front of the word `Uhr` is considered, and only when both
    /// groups hold a valid hour and minute. Dates (`19.04.2026`), thousands separators
    /// (`20.450`), version numbers and plain decimals therefore stay unchanged, as does
    /// anything whose minutes are not spelled with two digits. Words that merely start
    /// with `Uhr` (`Uhren`, `Uhrzeit`, `Uhrwerk`) do not count either.
    ///
    /// Time ranges linked by `bis`, `und`, `-` or `–` are rewritten on both sides:
    /// `von 9.00 bis 17.00 Uhr` becomes `von 9:00 bis 17:00 Uhr`.
    ///
    /// This runs independently of the number normalization setting: turning spoken-number
    /// cleanup off must not restore a separator that DIN 5008 treats as incorrect.
    static func normalizeTimeNotation(_ text: String, languages: [String]) -> String {
        guard !text.isEmpty,
              languages.contains(where: { PunctuationLanguageNormalizer.normalize($0) == "de" }) else {
            return text
        }

        return GermanTimeNotation.normalize(text)
    }

    /// Rewrites English month + spoken-day phrases to a compact date form, such as
    /// `July twenty eighth` -> `July 28`. The month context is required, so bare
    /// ordinals elsewhere (`first, let's start`) are never touched.
    ///
    /// This rides the number-normalization setting and runs after the cardinal,
    /// ordinal, and digit-sequence handling: by this point `twenty eighth` has
    /// already become `28th`, while `first` and small cardinals such as `two`
    /// still arrive as words, so both shapes are recognized. Years (`July 2026`)
    /// and out-of-range days (`July 32nd`) are left alone.
    static func normalizeSpokenDates(
        _ text: String,
        languages: [String],
        normalizeNumbers: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> String {
        guard !text.isEmpty,
              numberNormalizationEnabled(override: normalizeNumbers, defaults: defaults),
              languages.contains(where: { PunctuationLanguageNormalizer.normalize($0) == "en" }) else {
            return text
        }

        return EnglishDateNormalization.normalize(text)
    }

    static func normalizeResult(
        text: String,
        detectedLanguage: String?,
        configuredLanguage: String?,
        configuredLanguageCandidates: [String] = [],
        duration: TimeInterval,
        processingTime: TimeInterval,
        engineUsed: String,
        segments: [TranscriptionSegment],
        task: TranscriptionTask,
        normalizeNumbers: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> TranscriptionResult {
        let languages = normalizationLanguages(
            task: task,
            detectedLanguage: detectedLanguage,
            configuredLanguage: configuredLanguage,
            configuredLanguageCandidates: configuredLanguageCandidates
        )
        return TranscriptionResult(
            text: normalizeText(text, languages: languages, normalizeNumbers: normalizeNumbers, defaults: defaults),
            detectedLanguage: detectedLanguage,
            duration: duration,
            processingTime: processingTime,
            engineUsed: engineUsed,
            segments: segments.map {
                TranscriptionSegment(
                    text: normalizeText($0.text, languages: languages, normalizeNumbers: normalizeNumbers, defaults: defaults),
                    start: $0.start,
                    end: $0.end,
                    speakerLabel: $0.speakerLabel,
                    speakerConfidence: $0.speakerConfidence
                )
            }
        )
    }

    static func normalizeResult(
        _ result: TranscriptionResult,
        configuredLanguage: String?,
        configuredLanguageCandidates: [String] = [],
        task: TranscriptionTask,
        normalizeNumbers: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> TranscriptionResult {
        normalizeResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            configuredLanguage: configuredLanguage,
            configuredLanguageCandidates: configuredLanguageCandidates,
            duration: result.duration,
            processingTime: result.processingTime,
            engineUsed: result.engineUsed,
            segments: result.segments,
            task: task,
            normalizeNumbers: normalizeNumbers,
            defaults: defaults
        )
    }

    static func normalizationLanguages(
        task: TranscriptionTask,
        detectedLanguage: String?,
        configuredLanguage: String?,
        configuredLanguageCandidates: [String] = []
    ) -> [String] {
        if task == .translate {
            return ["en"]
        }

        return prioritizedLanguages(
            primary: detectedLanguage,
            candidates: [configuredLanguage].compactMap { $0 } + configuredLanguageCandidates
        )
    }

    private static func prioritizedLanguages(primary: String?, candidates: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for rawLanguage in [primary].compactMap({ $0 }) + candidates {
            guard let normalized = PunctuationLanguageNormalizer.normalize(rawLanguage),
                  seen.insert(normalized).inserted else {
                continue
            }
            result.append(normalized)
        }

        return result
    }

    private enum GermanTimeNotation {
        /// `HH.MM` that is not part of a longer dotted run and is followed by the word `Uhr`.
        /// The hour and minute alternatives keep `24.00 Uhr` and `20.75 Uhr` untouched.
        private static let expression = try? NSRegularExpression(
            pattern: #"(?<![\d.])((?:[01]?\d)|(?:2[0-3]))\.([0-5]\d)(?=[ \t]*Uhr\b)"#,
            options: [.caseInsensitive]
        )

        /// `HH.MM` linked to a following clock time by `bis`, `und`, `-` or `–`,
        /// as in `von 9.00 bis 17.00 Uhr`. Runs before `expression` so the second
        /// time is still written with a period when this matches.
        private static let rangeExpression = try? NSRegularExpression(
            pattern: #"(?<![\d.])((?:[01]?\d)|(?:2[0-3]))\.([0-5]\d)(?=[ \t]*(?:bis|und|-|–)[ \t]*(?:[01]?\d|2[0-3])\.[0-5]\d[ \t]*Uhr\b)"#,
            options: [.caseInsensitive]
        )

        static func normalize(_ text: String) -> String {
            guard let expression, let rangeExpression else {
                return text
            }

            let mutable = NSMutableString(string: text)
            let rangeReplacements = rangeExpression.replaceMatches(
                in: mutable,
                options: [],
                range: NSRange(location: 0, length: mutable.length),
                withTemplate: "$1:$2"
            )
            let replacements = expression.replaceMatches(
                in: mutable,
                options: [],
                range: NSRange(location: 0, length: mutable.length),
                withTemplate: "$1:$2"
            )

            return rangeReplacements + replacements > 0 ? (mutable as String) : text
        }
    }

    /// Month + day phrases in English dictation, such as `July 28th` or
    /// `June first`, rewritten to the compact `July 28` / `June 1` form.
    ///
    /// The day phrase may be digits with an optional ordinal suffix, a single
    /// word (`first`, `tenth`, `twenty`), or a compound (`twenty eighth`,
    /// `thirty-first`). The word tables are the real gate: a noun following the
    /// month (`April showers`) simply does not map to a day and is left alone.
    private enum EnglishDateNormalization {
        /// A month name or abbreviation followed by a plausible day phrase.
        private static let expression = try? NSRegularExpression(
            pattern: #"\b(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)\b\s+(\d{1,2}(?:st|nd|rd|th)?|[A-Za-z]+(?:[\s-]+[A-Za-z]+)?)"#,
            options: [.caseInsensitive]
        )

        /// Single-word day phrases: `first` -> 1, `tenth` -> 10, `twenty` -> 20.
        private static let singleWordDays: [String: Int] = [
            "first": 1, "one": 1, "second": 2, "two": 2, "third": 3, "three": 3,
            "fourth": 4, "four": 4, "fifth": 5, "five": 5, "sixth": 6, "six": 6,
            "seventh": 7, "seven": 7, "eighth": 8, "eight": 8, "ninth": 9, "nine": 9,
            "tenth": 10, "ten": 10, "eleventh": 11, "eleven": 11,
            "twelfth": 12, "twelve": 12, "thirteenth": 13, "thirteen": 13,
            "fourteenth": 14, "fourteen": 14, "fifteenth": 15, "fifteen": 15,
            "sixteenth": 16, "sixteen": 16, "seventeenth": 17, "seventeen": 17,
            "eighteenth": 18, "eighteen": 18, "nineteenth": 19, "nineteen": 19,
            "twentieth": 20, "twenty": 20, "thirtieth": 30, "thirty": 30,
        ]

        private static let tensDays = ["twenty": 20, "thirty": 30]

        private static let unitDays: [String: Int] = [
            "first": 1, "one": 1, "second": 2, "two": 2, "third": 3, "three": 3,
            "fourth": 4, "four": 4, "fifth": 5, "five": 5, "sixth": 6, "six": 6,
            "seventh": 7, "seven": 7, "eighth": 8, "eight": 8, "ninth": 9, "nine": 9,
        ]

        static func normalize(_ text: String) -> String {
            guard let expression else { return text }
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = expression.matches(in: text, options: [], range: fullRange)
            guard !matches.isEmpty else { return text }

            var result = ""
            var cursor = text.startIndex
            for match in matches {
                guard let monthRange = Range(match.range(at: 1), in: text),
                      let dayRange = Range(match.range(at: 2), in: text),
                      monthAllowsConversion(String(text[monthRange])),
                      let day = dayNumber(for: String(text[dayRange])) else {
                    continue
                }
                result.append(contentsOf: text[cursor..<monthRange.lowerBound])
                result.append(contentsOf: text[monthRange])
                result += " \(day)"
                cursor = dayRange.upperBound
            }
            result.append(contentsOf: text[cursor...])
            return result
        }

        /// `May` and `March` double as verbs (`you may first try`), so only the
        /// capitalized form counts as a month. Transcription models capitalize
        /// proper nouns reliably; the verb mid-sentence stays lowercase.
        private static func monthAllowsConversion(_ month: String) -> Bool {
            switch month.lowercased() {
            case "may", "march":
                return month.first?.isUppercase == true
            default:
                return true
            }
        }

        /// Turns a day phrase into its day-of-month number, or nil when it is not
        /// one: `28th` -> 28, `twenty eighth` -> 28, `first` -> 1. Only 1...31
        /// counts, so years and out-of-range ordinals are rejected.
        private static func dayNumber(for phrase: String) -> Int? {
            if let day = numericDay(phrase) {
                return day
            }
            let words = phrase.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "-" }).map(String.init)
            switch words.count {
            case 1:
                return singleWordDays[words[0]]
            case 2:
                guard let tens = tensDays[words[0]], let unit = unitDays[words[1]] else {
                    return nil
                }
                let day = tens + unit
                return day <= 31 ? day : nil
            default:
                return nil
            }
        }

        private static func numericDay(_ phrase: String) -> Int? {
            var digits = phrase.lowercased()
            for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) {
                digits = String(digits.dropLast(2))
                break
            }
            guard let day = Int(digits), (1...31).contains(day) else {
                return nil
            }
            return day
        }
    }
}
