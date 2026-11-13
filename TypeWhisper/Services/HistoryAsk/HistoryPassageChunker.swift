import Foundation

/// A stretch of a recording that the search index stores, finds and cites as one unit.
struct HistoryPassage: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// What was said.
        case transcript
        /// A document made from the recording, such as an email or meeting notes.
        case result
    }

    var kind: Kind
    var text: String
    /// The speakers in the passage, in order of appearance. Empty without speaker detection.
    var speakers: [String] = []
    var startSeconds: Double?
    var endSeconds: Double?
    /// The passage's place in its source text, in UTF-16 units. Nil for speaker
    /// transcripts, whose passages are found by their time.
    var utf16Range: Range<Int>?
}

/// When a stretch of a text was spoken.
struct HistoryPassageTiming: Equatable, Sendable {
    var utf16Range: Range<Int>
    var start: Double
    var end: Double
}

/// One stretch of a speaker transcript, with the speaker's name as it is shown.
struct HistoryPassageSpeakerSegment: Equatable, Sendable {
    var speaker: String
    var text: String
    var start: Double
    var end: Double
}

/// Cuts recordings into passages for the search index. Lengths are UTF-16 units.
enum HistoryPassageChunker {
    /// Stored with every indexed record. Raise it when an unchanged record would
    /// get other passages, so the index is built again.
    static let version = 1
    /// Full-text ranking prefers short passages, so a last passage shorter than
    /// this takes text from the one before it.
    static let minimumLength = 500
    static let maximumLength = 900

    /// Passages of a text without speakers, cut at sentence ends where possible.
    static func passages(
        of text: String,
        kind: HistoryPassage.Kind = .transcript,
        timing: [HistoryPassageTiming] = []
    ) -> [HistoryPassage] {
        let source = text as NSString
        let timing = timing.sorted { $0.utf16Range.lowerBound < $1.utf16Range.lowerBound }
        var firstTiming = 0
        return ranges(in: source, limit: maximumLength).compactMap { range in
            let range = trimmed(range, in: source)
            guard range.length > 0 else { return nil }
            let bounds = range.location..<NSMaxRange(range)
            while firstTiming < timing.count, timing[firstTiming].utf16Range.upperBound <= bounds.lowerBound {
                firstTiming += 1
            }
            let spoken = timing[firstTiming...].prefix { $0.utf16Range.lowerBound < bounds.upperBound }
            return HistoryPassage(
                kind: kind,
                text: source.substring(with: range),
                startSeconds: spoken.map(\.start).min(),
                endSeconds: spoken.map(\.end).max(),
                utf16Range: bounds
            )
        }
    }

    /// Passages of a speaker transcript. Every line starts with its speaker's name,
    /// and a passage holds whole turns: short ones ("Yes.", "Okay.") join their
    /// neighbours, and only a turn longer than a passage is cut.
    static func passages(ofSpeakerSegments segments: [HistoryPassageSpeakerSegment]) -> [HistoryPassage] {
        var lines: [SpeakerLine] = []
        for segment in segments {
            let prefixLength = (segment.speaker as NSString).length + 2
            let room = max(maximumLength - prefixLength, 1)
            let source = segment.text as NSString
            for range in ranges(in: source, limit: room) {
                let range = trimmed(range, in: source)
                guard range.length > 0 else { continue }
                // A segment cut into several lines has no timing for its parts,
                // so their times follow their place in the text.
                let duration = segment.end - segment.start
                let length = Double(max(source.length, 1))
                let start = segment.start + duration * Double(range.location) / length
                let end = segment.start + duration * Double(NSMaxRange(range)) / length
                let text = source.substring(with: range)
                if let last = lines.last, last.speaker == segment.speaker,
                   last.textLength + 1 + range.length <= room {
                    lines[lines.count - 1].text += " " + text
                    lines[lines.count - 1].textLength += 1 + range.length
                    lines[lines.count - 1].end = max(last.end, end)
                } else {
                    lines.append(SpeakerLine(
                        speaker: segment.speaker, text: text, textLength: range.length,
                        prefixLength: prefixLength, start: start, end: end
                    ))
                }
            }
        }

        return groups(ofLengths: lines.map { $0.prefixLength + $0.textLength }, separatorLength: 1, limit: maximumLength)
            .map { group in
                let lines = lines[group]
                var speakers: [String] = []
                for line in lines where !speakers.contains(line.speaker) { speakers.append(line.speaker) }
                return HistoryPassage(
                    kind: .transcript,
                    text: lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n"),
                    speakers: speakers,
                    startSeconds: lines.map(\.start).min(),
                    endSeconds: lines.map(\.end).max()
                )
            }
    }

    private struct SpeakerLine {
        var speaker: String
        var text: String
        var textLength: Int
        var prefixLength: Int
        var start: Double
        var end: Double
    }

    /// Ranges of at most `limit` units that together cover the text, each ending
    /// at a sentence end where possible.
    private static func ranges(in source: NSString, limit: Int) -> [NSRange] {
        var pieces: [NSRange] = []
        source.enumerateSubstrings(
            in: NSRange(location: 0, length: source.length),
            options: [.bySentences, .substringNotRequired]
        ) { _, _, sentence, _ in
            pieces.append(contentsOf: split(sentence, in: source, limit: limit))
        }
        return groups(ofLengths: pieces.map(\.length), separatorLength: 0, limit: limit).map { group in
            NSUnionRange(pieces[group.lowerBound], pieces[group.upperBound - 1])
        }
    }

    /// Breaks a sentence longer than the limit after spaces, or inside a word
    /// that is longer than the limit itself.
    private static func split(_ range: NSRange, in source: NSString, limit: Int) -> [NSRange] {
        var pieces: [NSRange] = []
        var location = range.location
        let end = NSMaxRange(range)
        while end - location > limit {
            let window = NSRange(location: location, length: limit)
            let space = source.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: window)
            var cut = NSMaxRange(space)
            if space.location == NSNotFound {
                // Never between the two halves of an emoji or another composed character.
                cut = source.rangeOfComposedCharacterSequence(at: location + limit).location
                if cut <= location { cut = location + limit }
            }
            pieces.append(NSRange(location: location, length: cut - location))
            location = cut
        }
        if end > location { pieces.append(NSRange(location: location, length: end - location)) }
        return pieces
    }

    /// Groups consecutive units into passages of at most `limit`, as index ranges.
    private static func groups(ofLengths lengths: [Int], separatorLength: Int, limit: Int) -> [Range<Int>] {
        func length(of group: Range<Int>) -> Int {
            lengths[group].reduce(0, +) + separatorLength * max(group.count - 1, 0)
        }

        var groups: [Range<Int>] = []
        var start = 0
        var current = 0
        for (index, unit) in lengths.enumerated() {
            let joined = index == start ? unit : current + separatorLength + unit
            if index > start, joined > limit {
                groups.append(start..<index)
                start = index
                current = unit
            } else {
                current = joined
            }
        }
        if start < lengths.count { groups.append(start..<lengths.count) }

        guard groups.count >= 2, let last = groups.last, length(of: last) < minimumLength else {
            return groups
        }
        // Move the border between the last two groups back while that makes them more equal.
        let previous = groups[groups.count - 2]
        var border = last.lowerBound
        while border - 1 > previous.lowerBound {
            let moved = length(of: (border - 1)..<last.upperBound)
            let difference = abs(length(of: previous.lowerBound..<border) - length(of: border..<last.upperBound))
            let movedDifference = abs(length(of: previous.lowerBound..<(border - 1)) - moved)
            guard moved <= limit, movedDifference < difference else { break }
            border -= 1
        }
        groups[groups.count - 2] = previous.lowerBound..<border
        groups[groups.count - 1] = border..<last.upperBound
        return groups
    }

    private static func trimmed(_ range: NSRange, in source: NSString) -> NSRange {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, let scalar = Unicode.Scalar(source.character(at: start)), whitespace.contains(scalar) {
            start += 1
        }
        while end > start, let scalar = Unicode.Scalar(source.character(at: end - 1)), whitespace.contains(scalar) {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }
}
