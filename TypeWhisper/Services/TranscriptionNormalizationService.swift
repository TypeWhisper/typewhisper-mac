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

        return normalizeTimeNotation(numberNormalized, languages: languages)
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
}
