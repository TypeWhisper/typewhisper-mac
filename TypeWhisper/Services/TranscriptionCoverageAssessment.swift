import Foundation
import NaturalLanguage

/// Result of comparing a final transcription against the audio it was produced from.
///
/// A provider can return a response that covers only part of the audio (#1352). The
/// assessment does not block anything: the caller still inserts the text, but a
/// suspicious result warns the user and keeps the recovery recording instead of
/// discarding it.
struct TranscriptionCoverageAssessment: Equatable, Sendable {
    enum Reason: String, Sendable, Comparable {
        case uncoveredTail
        case lowWordRate

        static func < (lhs: Reason, rhs: Reason) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let audioDuration: TimeInterval
    /// Maximum `end` of all returned segments; nil when the provider returned no segments.
    let lastSegmentEnd: TimeInterval?
    /// `max(0, audioDuration - lastSegmentEnd)`; nil when the provider returned no segments.
    let uncoveredTailSeconds: TimeInterval?
    let wordCount: Int
    let wordsPerSecond: Double
    let reasons: Set<Reason>

    var isSuspicious: Bool { !reasons.isEmpty }

    var logDescription: String {
        let lastSegmentEndText = lastSegmentEnd.map { String(format: "%.2fs", $0) } ?? "n/a"
        let uncoveredTailText = uncoveredTailSeconds.map { String(format: "%.2fs", $0) } ?? "n/a"
        let reasonsText = reasons.isEmpty
            ? "none"
            : reasons.sorted().map(\.rawValue).joined(separator: ",")
        return "audioDuration=\(String(format: "%.2fs", audioDuration))"
            + " lastSegmentEnd=\(lastSegmentEndText)"
            + " uncoveredTail=\(uncoveredTailText)"
            + " words=\(wordCount)"
            + " wordsPerSecond=\(String(format: "%.2f", wordsPerSecond))"
            + " suspicious=\(isSuspicious)"
            + " reasons=\(reasonsText)"
    }
}

enum TranscriptionCoverageAssessor {
    struct Thresholds: Sendable, Equatable {
        /// Word-rate check only applies to recordings at least this long.
        var minimumDurationForWordRate: TimeInterval = 20
        /// Below this rate a long recording is considered suspicious.
        /// Calibrated against 2.18 words/s baseline speech; affected cases were below 1.2 words/s.
        var minimumWordsPerSecond: Double = 0.8
        /// Tail check only applies to recordings at least this long.
        var minimumDurationForTailCheck: TimeInterval = 15
        /// Uncovered tail must be at least this many seconds ...
        var uncoveredTailFloorSeconds: TimeInterval = 6
        /// ... and at least this fraction of the audio duration.
        var uncoveredTailFraction: Double = 0.2

        static let `default` = Thresholds()
    }

    static func assess(
        text: String,
        segments: [TranscriptionSegment],
        audioDuration: TimeInterval,
        thresholds: Thresholds = .default
    ) -> TranscriptionCoverageAssessment {
        let words = wordCount(in: text)
        let safeDuration = audioDuration.isFinite ? audioDuration : 0
        let wordsPerSecond = safeDuration > 0 ? Double(words) / safeDuration : 0

        let lastSegmentEnd = segments.map(\.end).filter(\.isFinite).max()
        let uncoveredTail = lastSegmentEnd.map { max(0, safeDuration - $0) }

        var reasons = Set<TranscriptionCoverageAssessment.Reason>()
        if safeDuration > 0 {
            if safeDuration >= thresholds.minimumDurationForWordRate,
               wordsPerSecond < thresholds.minimumWordsPerSecond {
                reasons.insert(.lowWordRate)
            }
            if let uncoveredTail,
               safeDuration >= thresholds.minimumDurationForTailCheck {
                let requiredTail = max(
                    thresholds.uncoveredTailFloorSeconds,
                    thresholds.uncoveredTailFraction * safeDuration
                )
                if uncoveredTail >= requiredTail {
                    reasons.insert(.uncoveredTail)
                }
            }
        }

        return TranscriptionCoverageAssessment(
            audioDuration: safeDuration,
            lastSegmentEnd: lastSegmentEnd,
            uncoveredTailSeconds: uncoveredTail,
            wordCount: words,
            wordsPerSecond: wordsPerSecond,
            reasons: reasons
        )
    }

    /// Counts word tokens with `NLTokenizer` so that scripts without spaces (ja, zh)
    /// are not counted as a single word. Tokens without a letter or digit are ignored.
    static func wordCount(in text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                count += 1
            }
            return true
        }
        return count
    }
}
