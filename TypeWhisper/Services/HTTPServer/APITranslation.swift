import Foundation
import os

private let apiTranslationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac",
    category: "APITranslation"
)

#if canImport(Translation)
/// Resolved `target_language` translation context for the HTTP API.
///
/// The target/source language pair is resolved once and shared by the
/// full-text and per-segment translation passes, so both translate with
/// identical languages instead of each re-deriving them.
@available(macOS 15, *)
struct APITranslation {
    /// Translation-framework target language.
    let target: Locale.Language
    /// Translation-framework source language; nil lets the framework auto-detect.
    let source: Locale.Language?
    /// Normalized target identifier, reported in the response `language` field
    /// once translation has been applied.
    let targetIdentifier: String

    /// Resolves `targetCode` and the detected source language to framework
    /// languages. Returns nil when `targetCode` is missing or not a valid
    /// language identifier — callers then keep the untranslated
    /// source-language response, matching the previous behavior.
    static func resolve(targetCode: String?, detectedLanguage: String?) -> APITranslation? {
        guard let targetNormalized = TranslationService.normalizedLanguageIdentifier(from: targetCode) else {
            return nil
        }
        if let targetCode, targetCode.caseInsensitiveCompare(targetNormalized) != .orderedSame {
            apiTranslationLogger.info(
                "API translation target normalized \(targetCode, privacy: .public) -> \(targetNormalized, privacy: .public)"
            )
        }
        let sourceRaw = detectedLanguage
        let sourceNormalized = TranslationService.normalizedLanguageIdentifier(from: sourceRaw)
        if let sourceRaw {
            if let sourceNormalized {
                if sourceRaw.caseInsensitiveCompare(sourceNormalized) != .orderedSame {
                    apiTranslationLogger.info(
                        "API translation source normalized \(sourceRaw, privacy: .public) -> \(sourceNormalized, privacy: .public)"
                    )
                }
            } else {
                apiTranslationLogger.warning(
                    "API translation source language \(sourceRaw, privacy: .public) invalid, using auto source"
                )
            }
        }
        return APITranslation(
            target: Locale.Language(identifier: targetNormalized),
            source: sourceNormalized.map { Locale.Language(identifier: $0) },
            targetIdentifier: targetNormalized
        )
    }

    /// Translates every segment's text in a single translation session,
    /// preserving start/end timestamps, speaker metadata, and segment order.
    /// Segments with empty/blank text skip the service call. Batching keeps
    /// long verbose responses from paying the per-request session setup cost
    /// once per segment. A translation failure propagates to the caller (the
    /// API maps it to HTTP 500) — this never returns source-language text
    /// labeled as translated.
    static func translateSegments(
        _ segments: [TranscriptionSegment],
        translation: APITranslation,
        translateBatch: ([String], Locale.Language, Locale.Language?) async throws -> [String]
    ) async throws -> [TranscriptionSegment] {
        var texts: [String?] = Array(repeating: nil, count: segments.count)
        var batchInputs: [String] = []
        var batchIndices: [Int] = []
        for (index, segment) in segments.enumerated() {
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                texts[index] = segment.text
            } else {
                batchIndices.append(index)
                batchInputs.append(segment.text)
            }
        }
        if !batchInputs.isEmpty {
            // The batch contract preserves order; a count mismatch throws.
            let results = try await translateBatch(batchInputs, translation.target, translation.source)
            for (index, result) in zip(batchIndices, results) {
                texts[index] = result
            }
        }
        return segments.enumerated().map { index, segment in
            TranscriptionSegment(
                text: texts[index] ?? segment.text,
                start: segment.start,
                end: segment.end,
                speakerLabel: segment.speakerLabel,
                speakerConfidence: segment.speakerConfidence
            )
        }
    }
}
#endif
