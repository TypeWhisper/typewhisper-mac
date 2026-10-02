import Foundation

/// A stretch of one turn shown as its own paragraph with its own time.
struct SpeakerParagraph: Equatable, Identifiable, Sendable {
    let turnIndex: Int
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// The transcript segments this paragraph joins.
    let segmentRange: Range<Int>

    var id: Int { segmentRange.lowerBound }
}

extension SpeakerTranscriptPresentation {
    /// A pause this long inside a turn starts a new paragraph.
    static let paragraphPause: TimeInterval = 1.5
    /// A paragraph this long ends with the segment that exceeds it, in characters.
    static let paragraphLength = 450

    /// Breaks a turn into paragraphs at pauses and after long stretches, so a
    /// monologue is not one block with a single time.
    static func paragraphs(of turn: SpeakerTranscriptTurn, in transcript: SpeakerTranscript) -> [SpeakerParagraph] {
        var paragraphs: [SpeakerParagraph] = []
        var first: Int?
        var texts: [String] = []
        var start: TimeInterval = 0
        var end: TimeInterval = 0

        func close(before index: Int) {
            guard let lowerBound = first, !texts.isEmpty else { return }
            paragraphs.append(SpeakerParagraph(
                turnIndex: turn.index,
                speakerID: turn.speakerID,
                start: start,
                end: end,
                text: texts.joined(separator: " "),
                segmentRange: lowerBound..<index
            ))
            first = nil
            texts = []
        }

        for index in turn.segmentRange where transcript.segments.indices.contains(index) {
            let segment = transcript.segments[index]
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if first != nil,
               segment.start - end >= paragraphPause || texts.reduce(0, { $0 + $1.count }) >= paragraphLength {
                close(before: index)
            }
            if first == nil {
                first = index
                start = segment.start
            }
            texts.append(text)
            end = max(end, segment.end)
        }
        close(before: turn.segmentRange.upperBound)
        return paragraphs
    }

    /// The turn spoken at `time`. A turn stays active only while it is
    /// spoken, not through the silence after it.
    static func spokenTurn(in turns: [SpeakerTranscriptTurn], at time: TimeInterval, tolerance: TimeInterval = 0.4) -> SpeakerTranscriptTurn? {
        turns.last { $0.start <= time && time < $0.end + tolerance }
    }
}

/// Which parts of a recording play: everything, only some speakers, or
/// without the stretches where nobody speaks.
enum SpeakerPlaybackPlan {
    /// Audio kept before and after each played stretch.
    static let padding: TimeInterval = 0.2
    /// Stretches closer than this play through.
    static let minimumGap: TimeInterval = 1

    /// The stretches to play, sorted and without overlap. Without a speaker
    /// filter and with silence kept, the whole recording plays.
    /// - Parameter audibleSpeakers: Speakers to play, or nil for all.
    static func ranges(
        turns: [SpeakerTranscriptTurn],
        audibleSpeakers: Set<String>?,
        skipsSilence: Bool,
        duration: TimeInterval
    ) -> [ClosedRange<TimeInterval>] {
        guard duration > 0 else { return [] }
        guard audibleSpeakers != nil || skipsSilence else { return [0...duration] }

        let stretches = turns
            .filter { audibleSpeakers?.contains($0.speakerID) ?? true }
            .map { (start: max(0, $0.start - padding), end: min(duration, $0.end + padding)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }

        var merged: [(start: TimeInterval, end: TimeInterval)] = []
        for stretch in stretches {
            if let last = merged.last, stretch.start - last.end < minimumGap {
                merged[merged.count - 1].end = max(last.end, stretch.end)
            } else {
                merged.append(stretch)
            }
        }
        return merged.map { $0.start...$0.end }
    }

    /// Where playback continues from `time`: `time` itself inside a played
    /// stretch, the start of the next stretch otherwise, or nil at the end.
    static func position(from time: TimeInterval, in ranges: [ClosedRange<TimeInterval>]) -> TimeInterval? {
        for range in ranges {
            if time < range.lowerBound { return range.lowerBound }
            if time < range.upperBound { return time }
        }
        return nil
    }
}

/// Keeps speaker names when speakers are detected again.
enum SpeakerCarryOver {
    /// A new speaker takes an old speaker's name when most of the new
    /// speaker's time was that old speaker's.
    static let minimumShare = 0.6

    /// - Returns: The names for the new transcript, and the names that no new
    ///   speaker took over.
    static func names(
        from oldTranscript: SpeakerTranscript,
        names oldNames: SpeakerNameTable?,
        to newTranscript: SpeakerTranscript
    ) -> (names: SpeakerNameTable?, lost: [String]) {
        guard let oldNames, !oldNames.entries.isEmpty else { return (nil, []) }

        // Seconds each new speaker shares with each old speaker.
        var shared: [String: [String: TimeInterval]] = [:]
        var oldIndex = 0
        let oldSegments = oldTranscript.segments
        for segment in newTranscript.segments {
            guard let newID = segment.speakerID else { continue }
            while oldIndex < oldSegments.count, oldSegments[oldIndex].end <= segment.start { oldIndex += 1 }
            var index = oldIndex
            while index < oldSegments.count, oldSegments[index].start < segment.end {
                let old = oldSegments[index]
                let overlap = min(old.end, segment.end) - max(old.start, segment.start)
                if overlap > 0, let oldID = old.speakerID {
                    shared[newID, default: [:]][oldID, default: 0] += overlap
                }
                index += 1
            }
        }

        var candidates: [(newID: String, oldID: String, seconds: TimeInterval)] = []
        for (newID, overlaps) in shared {
            let total = newTranscript.speakingTime(of: newID)
            guard total > 0,
                  let best = overlaps.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
                  best.value / total >= minimumShare else { continue }
            candidates.append((newID, best.key, best.value))
        }

        var table = SpeakerNameTable(transcriptRevision: newTranscript.revision)
        var takenOldIDs = Set<String>()
        for candidate in candidates.sorted(by: { ($0.seconds, $1.newID) > ($1.seconds, $0.newID) })
        where !takenOldIDs.contains(candidate.oldID) {
            guard let name = oldNames.displayName(for: candidate.oldID) else { continue }
            takenOldIDs.insert(candidate.oldID)
            table.setName(
                name,
                for: candidate.newID,
                profileID: oldNames.profileID(for: candidate.oldID),
                isSuggestion: oldNames.isSuggestion(for: candidate.oldID)
            )
        }
        let lost = oldNames.entries.filter { !takenOldIDs.contains($0.speakerID) }.map(\.displayName)
        return (table.entries.isEmpty ? nil : table, lost)
    }
}

extension SpeakerTranscript {
    /// The same revision with the segments in `range` replaced by one segment
    /// with the edited text. An empty text removes them.
    func replacingText(ofSegmentsIn range: Range<Int>, with text: String) -> SpeakerTranscript {
        let range = range.clamped(to: segments.indices)
        guard let first = segments[range].first, let last = segments[range].last else { return self }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var edited = Array(segments[..<range.lowerBound])
        if !text.isEmpty {
            edited.append(SpeakerTranscriptSegment(
                text: text,
                start: first.start,
                end: max(first.start, last.end),
                speakerID: first.speakerID,
                speakerConfidence: first.speakerConfidence
            ))
        }
        edited.append(contentsOf: segments[range.upperBound...])
        return SpeakerTranscript(
            revision: revision,
            source: source,
            segments: edited,
            requestedSpeakerCount: requestedSpeakerCount
        )
    }

    /// All segment texts in order, for the record's plain text after an edit.
    var joinedText: String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Writes a speaker transcript with names for other apps.
enum SpeakerTranscriptExportFormat: String, CaseIterable, Identifiable {
    case plainText
    case markdown
    case srt
    case vtt
    case json

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .markdown: "md"
        case .srt: "srt"
        case .vtt: "vtt"
        case .json: "json"
        }
    }

    var displayName: String {
        switch self {
        case .plainText: String(localized: "speakers.export.plainText")
        case .markdown: "Markdown"
        case .srt: "SRT"
        case .vtt: "WebVTT"
        case .json: "JSON"
        }
    }
}

enum SpeakerTranscriptExporter {
    static func content(
        of transcript: SpeakerTranscript,
        names: SpeakerNameTable?,
        title: String?,
        format: SpeakerTranscriptExportFormat
    ) -> String {
        let turns = SpeakerTranscriptPresentation.turns(of: transcript)
        func name(_ speakerID: String) -> String {
            SpeakerTranscriptPresentation.name(for: speakerID, names: names)
        }

        switch format {
        case .plainText:
            return turns
                .map { "[\(SpeakerTranscriptPresentation.timestamp($0.start))] \(name($0.speakerID)): \($0.text)" }
                .joined(separator: "\n\n")
        case .markdown:
            let heading = title.map { "# \($0)\n\n" } ?? ""
            return heading + turns
                .map { "**\(name($0.speakerID))** (\(SpeakerTranscriptPresentation.timestamp($0.start)))\n\n\($0.text)" }
                .joined(separator: "\n\n")
        case .srt:
            return SubtitleExporter.exportSRT(segments: subtitleSegments(of: transcript, name: name))
        case .vtt:
            return SubtitleExporter.exportVTT(segments: subtitleSegments(of: transcript, name: name))
        case .json:
            let document = JSONDocument(
                title: title,
                speakers: transcript.speakerIDs.map { .init(id: $0, name: name($0)) },
                segments: transcript.segments.map {
                    .init(start: $0.start, end: $0.end, speaker: $0.speakerID, text: $0.text)
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(document)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
    }

    private static func subtitleSegments(
        of transcript: SpeakerTranscript,
        name: (String) -> String
    ) -> [TranscriptionSegment] {
        transcript.segments.map {
            TranscriptionSegment(
                text: $0.text,
                start: $0.start,
                end: $0.end,
                speakerLabel: $0.speakerID.map(name)
            )
        }
    }

    private struct JSONDocument: Encodable {
        struct Speaker: Encodable {
            let id: String
            let name: String
        }

        struct Segment: Encodable {
            let start: TimeInterval
            let end: TimeInterval
            let speaker: String?
            let text: String
        }

        let title: String?
        let speakers: [Speaker]
        let segments: [Segment]
    }
}
