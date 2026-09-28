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
    /// already become `28th`, while ordinals such as `first` still arrive as
    /// words, so both shapes are recognized. Years (`July 2026`) and
    /// out-of-range days (`July 32nd`) are left alone.
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
    /// ordinal word (`first`, `ninth`, `twentieth`), or a tens+ordinal compound
    /// (`twenty eighth`, `thirty-first`). Only ordinal words convert: cardinals
    /// after a month (`July two people`) are counts, not dates. Abbreviated
    /// months (`Jan`, `Sep`) only pair with numeric days, since `Jan` is also a
    /// first name. Days already written as digits (`Jul 07`) are left alone, so
    /// normalization is idempotent, and the month-day gap never crosses a
    /// newline.
    private enum EnglishDateNormalization {
        /// Full month names with their maximum day count. February allows 29;
        /// the year is unknown, so leap days are never rejected.
        private static let fullMonths: [String: Int] = [
            "january": 31, "february": 29, "march": 31, "april": 30, "may": 31,
            "june": 30, "july": 31, "august": 31, "september": 30, "october": 31,
            "november": 30, "december": 31,
        ]

        /// Abbreviated month names with their maximum day count. These accept
        /// an optional trailing period (`Jan. 5th`).
        private static let abbreviatedMonths: [String: Int] = [
            "jan": 31, "feb": 29, "mar": 31, "apr": 30, "jun": 30, "jul": 31,
            "aug": 31, "sep": 30, "sept": 30, "oct": 31, "nov": 30, "dec": 31,
        ]

        /// Ordinal day words: `first` -> 1 ... `thirtieth` -> 30. Cardinals are
        /// deliberately absent — after a month they read as counts, not dates.
        private static let ordinalDayValues: [String: Int] = [
            "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
            "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
            "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
            "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
            "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
        ]

        private static let tensDays = ["twenty": 20, "thirty": 30]

        /// Compound tails (`twenty eighth`): an ordinal unit 1...9, derived from
        /// the ordinal table so the two can't drift apart.
        private static let ordinalUnitValues: [String: Int] =
            ordinalDayValues.filter { $0.value <= 9 }

        /// A month name or abbreviation followed by a plausible day phrase. The
        /// day alternatives enumerate the ordinal tables instead of matching a
        /// bare word class, so a following month name (`we may June first`) can
        /// never be swallowed into a failed match. The `(?![-'\w])` tail is
        /// grouped over every day alternative, so hyphenated compounds
        /// (`first-rate`, `5th-place`) and possessives stay intact, and the
        /// month-day gap is spaces/tabs only, never a newline.
        private static let expression: NSRegularExpression? = {
            let full = fullMonths.keys.sorted { $0.count > $1.count }.joined(separator: "|")
            let abbreviated = abbreviatedMonths.keys.sorted { $0.count > $1.count }
                .map { $0 + "\\.?" }.joined(separator: "|")
            let ordinals = ordinalDayValues.keys.sorted().joined(separator: "|")
            let units = ordinalUnitValues.keys.sorted().joined(separator: "|")
            let dayAlternatives =
                "\\d{1,2}(?:st|nd|rd|th)?|(?:twenty|thirty)[ \\t-](?:\(units))|(?:\(ordinals))"
            return try? NSRegularExpression(
                pattern: "\\b(\(full)|\(abbreviated))[ \\t]+((?:\(dayAlternatives))(?![-'\\w]))",
                options: [.caseInsensitive]
            )
        }()

        static func normalize(_ text: String) -> String {
            guard let expression else { return text }
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = expression.matches(in: text, options: [], range: fullRange)
            guard !matches.isEmpty else { return text }

            var result = ""
            var cursor = text.startIndex
            for match in matches {
                guard let monthRange = Range(match.range(at: 1), in: text),
                      let dayRange = Range(match.range(at: 2), in: text) else {
                    continue
                }
                let month = String(text[monthRange])
                let dayPhrase = String(text[dayRange])
                guard monthAllowsConversion(month),
                      !isAlreadyNumeric(dayPhrase),
                      let day = dayNumber(for: dayPhrase),
                      dayIsValid(month: month, day: day),
                      dayPhraseAllowed(month: month, dayPhrase: dayPhrase) else {
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

        /// A day already written as plain digits (`Jul 07`) is left exactly as
        /// written, which also makes normalization idempotent.
        private static func isAlreadyNumeric(_ dayPhrase: String) -> Bool {
            !dayPhrase.isEmpty && dayPhrase.allSatisfy(\.isNumber)
        }

        /// Abbreviated months only pair with numeric days: `Jan` is a common
        /// first name, so `Ask Jan first` must not become a date.
        private static func dayPhraseAllowed(month: String, dayPhrase: String) -> Bool {
            guard abbreviatedMonths[monthKey(month)] != nil else { return true }
            return dayPhrase.range(
                of: #"^\d{1,2}(?:st|nd|rd|th)?$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }

        /// The month's real calendar limit.
        private static func dayIsValid(month: String, day: Int) -> Bool {
            let key = monthKey(month)
            let maxDay = fullMonths[key] ?? abbreviatedMonths[key] ?? 31
            return day <= maxDay
        }

        private static func monthKey(_ month: String) -> String {
            month.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }

        /// Turns a day phrase into its day-of-month number, or nil when it is not
        /// one: `28th` -> 28, `twenty eighth` -> 28, `first` -> 1.
        private static func dayNumber(for phrase: String) -> Int? {
            if let day = numericDay(phrase) {
                return day
            }
            let words = phrase.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "-" }).map(String.init)
            switch words.count {
            case 1:
                return ordinalDayValues[words[0]]
            case 2:
                guard let tens = tensDays[words[0]], let unit = ordinalUnitValues[words[1]] else {
                    return nil
                }
                return tens + unit
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
