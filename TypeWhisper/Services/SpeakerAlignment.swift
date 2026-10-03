import Foundation

/// A stretch of audio attributed to one diarized speaker.
struct SpeakerTurn: Equatable, Sendable {
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Combines transcription timing with diarization turns into speaker segments.
///
/// Word timing is preferred: every word goes to the speaker it overlaps most,
/// or the nearest speaker within `maximumDistance`. Words without a nearby
/// speaker inherit the previous speaker (the next one at the start), so no
/// transcript text is dropped. Segment-timed engines fall back to assigning
/// whole segments.
enum SpeakerAlignment {
    static let maximumDistance: TimeInterval = 1

    /// Renames diarizer labels to `S1`, `S2`, … in order of first appearance
    /// and sorts the turns by start time.
    static func normalizedTurns(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        let numbering = speakerNumbering(turns)
        return validTurnsByStart(turns).compactMap { turn in
            numbering[turn.speakerID].map {
                SpeakerTurn(speakerID: $0, start: turn.start, end: turn.end)
            }
        }
    }

    /// Maps each diarizer label to `S1`, `S2`, … in order of first appearance.
    static func speakerNumbering(_ turns: [SpeakerTurn]) -> [String: String] {
        var numbering: [String: String] = [:]
        for turn in validTurnsByStart(turns) where numbering[turn.speakerID] == nil {
            numbering[turn.speakerID] = SpeakerTranscript.speakerID(number: numbering.count + 1)
        }
        return numbering
    }

    private static func validTurnsByStart(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        turns
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Builds the speaker transcript for a stored recording. Returns nil when
    /// the engine produced no timing or diarization found no speaker.
    static func transcript(
        text: String,
        timedText: [TimedTextEntry],
        granularity: TimedTextGranularity,
        turns: [SpeakerTurn],
        words: [TranscriptionWord] = [],
        source: SpeakerTranscript.Source = .localDiarizer,
        requestedSpeakerCount: Int? = nil
    ) -> SpeakerTranscript? {
        let segments: [SpeakerTranscriptSegment] = switch granularity {
        case .word:
            Self.segments(words: timedText, turns: turns, transcript: text)
        case .segment:
            Self.segments(
                sentences: timedText.map { SpeakerTranscriptSegment(text: $0.text, start: $0.start, end: $0.end) },
                words: words,
                turns: turns
            )
        case .none:
            []
        }
        guard !segments.isEmpty else { return nil }
        return SpeakerTranscript(
            source: source,
            segments: segments,
            requestedSpeakerCount: requestedSpeakerCount
        )
    }

    /// Builds speaker segments from word-timed text. Each segment's text runs
    /// from its first word to the next segment's first word, so punctuation
    /// and spacing of `transcript` are preserved and the segments together
    /// cover the whole transcript.
    static func segments(
        words: [TimedTextEntry],
        turns: [SpeakerTurn],
        transcript: String
    ) -> [SpeakerTranscriptSegment] {
        let words = words.sorted { $0.utf16Location < $1.utf16Location }
        guard !words.isEmpty, !turns.isEmpty else { return [] }

        let assignments = words.map { assignment(for: $0.start...max($0.start, $0.end), in: turns) }
        let speakers = filledSpeakers(assignments.map(\.speaker))

        var groups: [(speakerID: String, range: Range<Int>)] = []
        for index in words.indices {
            if let last = groups.last, last.speakerID == speakers[index] {
                groups[groups.count - 1].range = last.range.lowerBound..<(index + 1)
            } else {
                groups.append((speakers[index], index..<(index + 1)))
            }
        }

        let source = transcript as NSString
        return groups.enumerated().map { offset, group in
            let first = words[group.range.lowerBound]
            let last = words[group.range.upperBound - 1]
            let textStart = offset == 0 ? 0 : first.utf16Location
            let textEnd = offset + 1 < groups.count
                ? words[groups[offset + 1].range.lowerBound].utf16Location
                : source.length
            let text = source
                .substring(with: NSRange(location: textStart, length: max(0, textEnd - textStart)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let direct = assignments[group.range].filter(\.isDirect).count
            return SpeakerTranscriptSegment(
                text: text,
                start: first.start,
                end: max(first.start, last.end),
                speakerID: group.speakerID,
                speakerConfidence: Double(direct) / Double(group.range.count)
            )
        }
    }

    /// Assigns whole transcription segments for engines without word timing.
    static func segments(
        segments: [SpeakerTranscriptSegment],
        turns: [SpeakerTurn]
    ) -> [SpeakerTranscriptSegment] {
        guard !segments.isEmpty, !turns.isEmpty else { return [] }
        let assignments = segments.map { assignment(for: $0.start...max($0.start, $0.end), in: turns) }
        let speakers = filledSpeakers(assignments.map(\.speaker))
        return segments.indices.map { index in
            SpeakerTranscriptSegment(
                text: segments[index].text,
                start: segments[index].start,
                end: segments[index].end,
                speakerID: speakers[index],
                speakerConfidence: assignments[index].isDirect ? 1 : 0
            )
        }
    }

    /// Words given to another speaker than their neighbours only count from
    /// this many in a row; a single word is overlap noise at a turn boundary.
    static let minimumWordRun = 2

    /// Assigns sentence segments and splits a segment where the speaker
    /// changes between two of its words. Segments stay sentences, so a turn
    /// can still be broken into paragraphs; without words for a segment the
    /// whole segment is assigned.
    static func segments(
        sentences: [SpeakerTranscriptSegment],
        words: [TranscriptionWord],
        turns: [SpeakerTurn]
    ) -> [SpeakerTranscriptSegment] {
        guard !sentences.isEmpty, !turns.isEmpty else { return [] }
        guard !words.isEmpty else { return segments(segments: sentences, turns: turns) }
        let words = words.sorted { $0.start < $1.start }

        struct Piece {
            let text: String
            let start: TimeInterval
            let end: TimeInterval
            let assignment: Assignment
        }
        var pieces: [Piece] = []
        var wordIndex = 0

        for sentence in sentences {
            while wordIndex < words.count, words[wordIndex].end <= sentence.start - 0.05 { wordIndex += 1 }
            var spoken: [TranscriptionWord] = []
            var index = wordIndex
            while index < words.count, words[index].start < sentence.end + 0.05 {
                spoken.append(words[index])
                index += 1
            }
            let mapped = TimedTextEntry.map(
                textParts: spoken.map { ($0.text, $0.start, $0.end) },
                in: sentence.text
            )
            let whole = Piece(
                text: sentence.text,
                start: sentence.start,
                end: sentence.end,
                assignment: assignment(for: sentence.start...max(sentence.start, sentence.end), in: turns)
            )
            // Only split when every word was found; otherwise text positions are unreliable.
            guard mapped.count == spoken.count, mapped.count >= 2 * minimumWordRun else {
                pieces.append(whole)
                continue
            }

            var speakers = mapped.map { assignment(for: $0.start...max($0.start, $0.end), in: turns).speaker }
            // Fill unassigned words and absorb runs that are too short.
            var last = speakers.compactMap { $0 }.first
            guard last != nil else {
                pieces.append(whole)
                continue
            }
            for position in speakers.indices {
                if let speaker = speakers[position] { last = speaker } else { speakers[position] = last }
            }
            var runs: [(speaker: String, range: Range<Int>)] = []
            for position in speakers.indices {
                let speaker = speakers[position]!
                if let run = runs.last, run.speaker == speaker {
                    runs[runs.count - 1].range = run.range.lowerBound..<(position + 1)
                } else {
                    runs.append((speaker, position..<(position + 1)))
                }
            }
            var merged: [(speaker: String, range: Range<Int>)] = []
            for run in runs {
                if run.range.count < minimumWordRun, let previous = merged.last {
                    merged[merged.count - 1].range = previous.range.lowerBound..<run.range.upperBound
                } else if let previous = merged.last, previous.speaker == run.speaker {
                    merged[merged.count - 1].range = previous.range.lowerBound..<run.range.upperBound
                } else {
                    merged.append(run)
                }
            }
            if merged.count > 1, merged[0].range.count < minimumWordRun {
                merged[1].range = merged[0].range.lowerBound..<merged[1].range.upperBound
                merged.removeFirst()
            }
            guard merged.count > 1 else {
                pieces.append(Piece(
                    text: sentence.text,
                    start: sentence.start,
                    end: sentence.end,
                    assignment: Assignment(speaker: merged.first?.speaker, isDirect: true)
                ))
                continue
            }

            let source = sentence.text as NSString
            for (offset, run) in merged.enumerated() {
                let textStart = offset == 0 ? 0 : mapped[run.range.lowerBound].utf16Location
                let textEnd = offset + 1 < merged.count
                    ? mapped[merged[offset + 1].range.lowerBound].utf16Location
                    : source.length
                let text = source
                    .substring(with: NSRange(location: textStart, length: max(0, textEnd - textStart)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                pieces.append(Piece(
                    text: text,
                    start: offset == 0 ? sentence.start : mapped[run.range.lowerBound].start,
                    end: offset + 1 < merged.count ? mapped[run.range.upperBound - 1].end : sentence.end,
                    assignment: Assignment(speaker: run.speaker, isDirect: true)
                ))
            }
        }

        let speakers = filledSpeakers(pieces.map(\.assignment.speaker))
        return pieces.indices.map { index in
            SpeakerTranscriptSegment(
                text: pieces[index].text,
                start: pieces[index].start,
                end: max(pieces[index].start, pieces[index].end),
                speakerID: speakers[index],
                speakerConfidence: pieces[index].assignment.isDirect ? 1 : 0
            )
        }
    }

    // MARK: - Assignment

    private struct Assignment {
        let speaker: String?
        /// True when the interval overlaps the chosen speaker's turn.
        let isDirect: Bool
    }

    private static func assignment(for interval: ClosedRange<TimeInterval>, in turns: [SpeakerTurn]) -> Assignment {
        var overlap: [String: TimeInterval] = [:]
        for turn in turns {
            let shared = min(turn.end, interval.upperBound) - max(turn.start, interval.lowerBound)
            if shared > 0 { overlap[turn.speakerID, default: 0] += shared }
        }
        if let best = overlap.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
            return Assignment(speaker: best.key, isDirect: true)
        }
        let nearest = turns.min { distance($0, interval) < distance($1, interval) }
        guard let nearest, distance(nearest, interval) <= maximumDistance else {
            return Assignment(speaker: nil, isDirect: false)
        }
        return Assignment(speaker: nearest.speakerID, isDirect: false)
    }

    private static func distance(_ turn: SpeakerTurn, _ interval: ClosedRange<TimeInterval>) -> TimeInterval {
        max(0, max(turn.start - interval.upperBound, interval.lowerBound - turn.end))
    }

    /// Fills gaps with the previous speaker, or the next one before the first
    /// assignment. Requires at least one assigned speaker.
    private static func filledSpeakers(_ speakers: [String?]) -> [String] {
        let fallback = speakers.compactMap { $0 }.first ?? SpeakerTranscript.speakerID(number: 1)
        var current = fallback
        return speakers.map { speaker in
            if let speaker { current = speaker }
            return current
        }
    }
}
