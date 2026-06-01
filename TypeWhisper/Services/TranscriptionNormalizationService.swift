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
        normalizeNumbers: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> String {
        guard numberNormalizationEnabled(override: normalizeNumbers, defaults: defaults) else {
            return text
        }

        return NumberWordNormalizer.normalize(text: text, language: language)
    }

    static func normalizeResult(
        text: String,
        detectedLanguage: String?,
        configuredLanguage: String?,
        duration: TimeInterval,
        processingTime: TimeInterval,
        engineUsed: String,
        segments: [TranscriptionSegment],
        task: TranscriptionTask,
        normalizeNumbers: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> TranscriptionResult {
        let language = normalizationLanguage(
            task: task,
            detectedLanguage: detectedLanguage,
            configuredLanguage: configuredLanguage
        )
        return TranscriptionResult(
            text: normalizeText(text, language: language, normalizeNumbers: normalizeNumbers, defaults: defaults),
            detectedLanguage: detectedLanguage,
            duration: duration,
            processingTime: processingTime,
            engineUsed: engineUsed,
            segments: segments.map {
                TranscriptionSegment(
                    text: normalizeText($0.text, language: language, normalizeNumbers: normalizeNumbers, defaults: defaults),
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
        task: TranscriptionTask,
        normalizeNumbers: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> TranscriptionResult {
        normalizeResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            configuredLanguage: configuredLanguage,
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
}
