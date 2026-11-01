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

/// One spoken word with its time, from engines that report word timing.
struct TranscriptionWord: Equatable, Codable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct TranscriptionResult {
    let text: String
    let detectedLanguage: String?
    let duration: TimeInterval
    let processingTime: TimeInterval
    let engineUsed: String
    let segments: [TranscriptionSegment]
    /// Empty when the engine reports no word timing.
    var words: [TranscriptionWord] = []

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

/// A transcription in the HTTP API's `verbose_json` format: text, segments with their
/// speakers and the engine's word timestamps. The API returns it, and
/// `<recording>.timestamps.json` next to a transcribed file holds the same, where tools
/// such as the REAPER scripts find the times of the words.
struct VerboseTranscript: Encodable {
    struct Segment: Encodable {
        let start: Double
        let end: Double
        let text: String
        let speaker: String?
        let speakerConfidence: Double?

        enum CodingKeys: String, CodingKey {
            case start
            case end
            case text
            case speaker
            case speakerConfidence = "speaker_confidence"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(speaker, forKey: .speaker)
            try container.encodeIfPresent(speakerConfidence, forKey: .speakerConfidence)
        }
    }

    struct Word: Encodable {
        let word: String
        let start: Double
        let end: Double
    }

    let text: String
    let language: String?
    let duration: Double
    let processingTime: Double
    let engine: String
    let model: String?
    let segments: [Segment]
    /// Only when word timestamps were requested; empty when the engine has none.
    let words: [Word]?

    enum CodingKeys: String, CodingKey {
        case text
        case language
        case duration
        case processingTime = "processing_time"
        case engine
        case model
        case segments
        case words
    }

    /// `text` and `segments` can differ from the result's after corrections or a
    /// translation; the words are always the engine's own.
    init(
        text: String,
        language: String?,
        result: TranscriptionResult,
        model: String?,
        segments: [TranscriptionSegment],
        includesWords: Bool
    ) {
        self.text = text
        self.language = language
        self.duration = result.duration
        self.processingTime = result.processingTime
        self.engine = result.engineUsed
        self.model = model
        self.segments = segments.map {
            Segment(
                start: $0.start,
                end: $0.end,
                text: $0.text,
                speaker: $0.speakerLabel,
                speakerConfidence: $0.speakerConfidence
            )
        }
        self.words = includesWords
            ? result.words.map { Word(word: $0.text, start: $0.start, end: $0.end) }
            : nil
    }
}

/// `<recording>.timestamps.json`: the word timestamps of a transcribed file, next to it.
enum TranscriptTimestampsFile {
    static func url(besideAudio audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("timestamps.json")
    }

    /// The file's content, or `nil` when the engine reported no word timestamps.
    /// Words and segments without valid times are left out, as JSON cannot hold them.
    static func data(text: String, result: TranscriptionResult, model: String?) throws -> Data? {
        let timed = TranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            duration: result.duration.isFinite ? result.duration : 0,
            processingTime: result.processingTime.isFinite ? result.processingTime : 0,
            engineUsed: result.engineUsed,
            segments: result.segments.filter { $0.start.isFinite && $0.end.isFinite },
            words: result.words.filter { $0.start.isFinite && $0.end.isFinite }
        )
        guard !timed.words.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(VerboseTranscript(
            text: text,
            language: timed.detectedLanguage,
            result: timed,
            model: model,
            segments: timed.segments,
            includesWords: true
        ))
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

    /// The task as its picker shows it: Translate names the target an engine translates into.
    func displayName(translationTarget: String?) -> String {
        guard self == .translate, let translationTarget, translationTarget != "en" else { return displayName }
        let language = localizedAppLanguageName(for: translationTarget)
        return localizedAppText(
            "Translate to \(language)",
            de: "Übersetzen nach \(language)",
            ja: "\(language)に翻訳",
            zh: "翻译为\(language)",
            es: "Traducir al \(language)"
        )
    }
}
