import Foundation
import NaturalLanguage

struct TranscriptionSegment {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let speakerLabel: String?
    let speakerConfidence: Double?

    init(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        speakerLabel: String? = nil,
        speakerConfidence: Double? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.speakerLabel = speakerLabel
        self.speakerConfidence = speakerConfidence
    }
}

struct TranscriptionResult {
    let text: String
    let detectedLanguage: String?
    let duration: TimeInterval
    let processingTime: TimeInterval
    let engineUsed: String
    let segments: [TranscriptionSegment]

    var realTimeFactor: Double {
        guard duration > 0 else { return 0 }
        return duration / processingTime
    }

    /// Diagnostic measurements only: valid-looking provider timestamps and a
    /// plausible word rate do not prove that all speech was transcribed (#1352).
    func diagnosticSummary(audioDuration: TimeInterval) -> String {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var wordCount = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                wordCount += 1
            }
            return true
        }
        let duration = audioDuration.isFinite && audioDuration > 0 ? audioDuration : 0
        let validSegments = segments.filter {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= duration + 0.5
        }
        let lastEnd = validSegments.map(\.end).max()
        let invalidSegments = segments.count - validSegments.count
        let endText = lastEnd.map { String(format: "%.3f", $0) } ?? "n/a"
        let tailText = lastEnd.map { String(format: "%.3f", max(0, duration - $0)) } ?? "n/a"
        return "audioDuration=\(String(format: "%.3f", duration)) words=\(wordCount)"
            + " wordsPerSecond=\(String(format: "%.3f", duration > 0 ? Double(wordCount) / duration : 0))"
            + " segments=\(segments.count) lastSegmentEnd=\(endText) uncoveredTail=\(tailText)"
            + " invalidSegmentTimestamps=\(invalidSegments)"
    }
}

enum TranscriptionTask: String, CaseIterable, Identifiable {
    case transcribe
    case translate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transcribe: String(localized: "Transcribe")
        case .translate: String(localized: "Translate to English")
        }
    }
}
