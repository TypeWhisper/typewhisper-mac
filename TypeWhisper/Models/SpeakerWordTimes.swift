import Foundation

/// A word of a paragraph with the time it is spoken at.
struct SpeakerTimedWord: Identifiable, Equatable, Sendable {
    /// Position in the paragraph.
    let id: Int
    let text: String
    let start: TimeInterval
    /// False when the next word follows without a space, as in Japanese.
    let isFollowedBySpace: Bool
}

extension SpeakerTranscriptPresentation {
    /// How far outside a paragraph's time word timing is still looked at;
    /// engines do not agree on where a sentence starts.
    static let wordTimingSlack: TimeInterval = 2

    /// The paragraph's words with their times, for marking the spoken word
    /// and for playing from a word.
    ///
    /// `words` is word timing of the recording and may come from another
    /// engine than the text, so both are compared as word sequences: words
    /// both have get their exact time, the ones between are spread evenly.
    /// Without any word timing the times are spread over each segment.
    static func timedWords(
        of paragraph: SpeakerParagraph,
        segments: [SpeakerTranscriptSegment],
        words: [TranscriptionWord]
    ) -> [SpeakerTimedWord] {
        let source = paragraph.text as NSString
        let nearby = words.filter {
            $0.start >= paragraph.start - wordTimingSlack && $0.start <= paragraph.end + wordTimingSlack
        }
        let ranges = wordRanges(in: source)
        // Text without spaces between words cannot be compared word by word.
        if ranges.count <= 1, nearby.count > 1 {
            return wordsCutAtTimedWords(of: paragraph, words: nearby)
        }

        let estimates = estimatedTimes(of: ranges, in: paragraph, segments: segments)
        let keys = ranges.map { comparisonKey(source.substring(with: $0)) }
        let wordKeys = nearby.map { comparisonKey($0.text) }
        var anchors: [Int: TimeInterval] = [:]
        if !nearby.isEmpty {
            // What is neither removed nor inserted is common to both, in order.
            var removed = Set<Int>()
            var inserted = Set<Int>()
            for change in keys.difference(from: wordKeys) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            let commonWords = wordKeys.indices.filter { !removed.contains($0) }
            let commonTokens = keys.indices.filter { !inserted.contains($0) }
            for (token, word) in zip(commonTokens, commonWords) where !keys[token].isEmpty {
                anchors[token] = nearby[word].start
            }
        }

        let anchored = anchors.keys.sorted()
        var result: [SpeakerTimedWord] = []
        for (index, range) in ranges.enumerated() {
            let time: TimeInterval
            if let exact = anchors[index] {
                time = exact
            } else {
                let before = anchored.last { $0 < index }
                let after = anchored.first { $0 > index }
                switch (before, after) {
                case let (before?, after?):
                    let share = Double(index - before) / Double(after - before)
                    time = anchors[before]! + (anchors[after]! - anchors[before]!) * share
                case let (before?, nil):
                    time = max(estimates[index], anchors[before]!)
                case let (nil, after?):
                    time = min(estimates[index], anchors[after]!)
                case (nil, nil):
                    time = estimates[index]
                }
            }
            result.append(SpeakerTimedWord(
                id: index,
                text: source.substring(with: range),
                start: max(time, result.last?.start ?? 0),
                isFollowedBySpace: true
            ))
        }
        return result
    }

    private static func wordRanges(in source: NSString) -> [NSRange] {
        let separators = CharacterSet.whitespacesAndNewlines
        var ranges: [NSRange] = []
        var location = 0
        while location < source.length {
            let rest = NSRange(location: location, length: source.length - location)
            let word = source.rangeOfCharacter(from: separators.inverted, options: [], range: rest)
            guard word.location != NSNotFound else { break }
            let after = NSRange(location: word.location, length: source.length - word.location)
            let gap = source.rangeOfCharacter(from: separators, options: [], range: after)
            let end = gap.location == NSNotFound ? source.length : gap.location
            ranges.append(NSRange(location: word.location, length: end - word.location))
            location = end
        }
        return ranges
    }

    /// Letters and digits only, without case and accents: "TV." equals "tv".
    private static func comparisonKey(_ word: String) -> String {
        String(String.UnicodeScalarView(
            word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        ))
    }

    /// Times by text position inside the segment a word belongs to, which the
    /// engine did time.
    private static func estimatedTimes(
        of ranges: [NSRange],
        in paragraph: SpeakerParagraph,
        segments: [SpeakerTranscriptSegment]
    ) -> [TimeInterval] {
        let source = paragraph.text as NSString
        var spans: [(range: NSRange, start: TimeInterval, end: TimeInterval)] = []
        var search = 0
        for index in paragraph.segmentRange where segments.indices.contains(index) {
            let text = segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = NSRange(location: search, length: source.length - search)
            let range = source.range(of: text, options: [], range: rest)
            guard !text.isEmpty, range.location != NSNotFound else { continue }
            spans.append((range, segments[index].start, segments[index].end))
            search = NSMaxRange(range)
        }
        if spans.isEmpty {
            spans = [(NSRange(location: 0, length: source.length), paragraph.start, paragraph.end)]
        }
        return ranges.map { range in
            let span = spans.last { $0.range.location <= range.location } ?? spans[0]
            return span.start + max(0, span.end - span.start)
                * Double(range.location - span.range.location) / Double(max(span.range.length, 1))
        }
    }

    /// For text without spaces: a word runs from one timed word to the next.
    private static func wordsCutAtTimedWords(
        of paragraph: SpeakerParagraph,
        words: [TranscriptionWord]
    ) -> [SpeakerTimedWord] {
        let source = paragraph.text as NSString
        let timed = TimedTextEntry.map(
            textParts: words.map { ($0.text, $0.start, $0.end) },
            in: paragraph.text
        ).sorted { $0.utf16Location < $1.utf16Location }
        var starts: [(location: Int, time: TimeInterval)] = []
        for entry in timed where starts.last?.location != entry.utf16Location {
            starts.append((starts.isEmpty ? 0 : entry.utf16Location, entry.start))
        }
        if starts.isEmpty { starts = [(0, paragraph.start)] }

        var result: [SpeakerTimedWord] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].location : source.length
            let raw = source.substring(with: NSRange(location: start.location, length: end - start.location))
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result.append(SpeakerTimedWord(
                id: result.count,
                text: text,
                start: max(start.time, result.last?.start ?? 0),
                isFollowedBySpace: raw.count != text.count
            ))
        }
        return result
    }
}
