import Foundation

enum TranscriptionNormalizationService {
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
        guard numberNormalizationEnabled(override: normalizeNumbers, defaults: defaults) else {
            return text
        }

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
        guard numberNormalizationEnabled(override: normalizeNumbers, defaults: defaults) else {
            return text
        }

        for language in prioritizedLanguages(primary: nil, candidates: languages) {
            let normalized = NumberWordNormalizer.normalize(text: text, language: language)
            if normalized != text {
                return normalized
            }
        }

        return text
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

    static func normalizationLanguage(
        task: TranscriptionTask,
        detectedLanguage: String?,
        configuredLanguage: String?
    ) -> String? {
        if task == .translate {
            return "en"
        }
        return detectedLanguage ?? configuredLanguage
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
}
