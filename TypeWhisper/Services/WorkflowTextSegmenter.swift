import Foundation

/// Tuning for splitting a workflow LLM input into independently processed segments.
struct WorkflowSegmentationPolicy: Equatable, Sendable {
    /// Preferred segment length in characters.
    var targetSegmentLength: Int
    /// A cut is skipped when it would leave a segment shorter than this.
    var minimumSegmentLength: Int
    /// Inputs shorter than this are sent as a single request.
    var minimumSplitLength: Int
    /// Upper bound for concurrent LLM requests of one dictation.
    var maximumConcurrentRequests: Int
    /// Characters of newer confirmed text required after a sentence boundary before
    /// incremental processing treats the text in front of it as stable.
    var incrementalStabilityMargin: Int
    /// Whether the workflow LLM runs on this Mac. On-device models work through
    /// requests one after another, so text still unprocessed at stop is sent as
    /// one request instead of being split into chunks.
    var isLocalProvider = false

    static let `default` = WorkflowSegmentationPolicy(
        targetSegmentLength: 1_000,
        minimumSegmentLength: 400,
        minimumSplitLength: 1_500,
        maximumConcurrentRequests: 4,
        incrementalStabilityMargin: 40
    )

    /// The default policy adjusted for the provider that will process the requests.
    /// Local providers keep incremental segments during recording, which overlap
    /// with speaking, but run them one at a time.
    func forLLMProvider(isLocal: Bool) -> WorkflowSegmentationPolicy {
        guard isLocal else { return self }
        var policy = self
        policy.isLocalProvider = true
        policy.maximumConcurrentRequests = 1
        return policy
    }
}

struct WorkflowTextSegment: Equatable, Sendable {
    /// Segment content without surrounding whitespace.
    let text: String
    /// Whitespace that followed the segment in the source. Empty after CJK sentence
    /// ends; for the last segment it holds the trailing whitespace of the source.
    let separator: String
}

struct WorkflowTextSegmentation: Equatable, Sendable {
    let leadingWhitespace: String
    let segments: [WorkflowTextSegment]

    /// Reassembles the source text. Always equal to the segmented input.
    var source: String {
        leadingWhitespace + segments.map { $0.text + $0.separator }.joined()
    }

    /// Joins per-segment outputs in source order with the original separators.
    func joined(outputs: [String]) -> String {
        WorkflowTextSegmenter.join(
            leadingWhitespace: leadingWhitespace,
            pieces: zip(outputs, segments).map { (output: $0, separator: $1.separator) }
        )
    }
}

/// Splits transcripts at sentence and paragraph boundaries without losing or
/// duplicating text, so segments can be processed independently and rejoined.
enum WorkflowTextSegmenter {
    private struct Boundary: Equatable {
        /// Character offset where the segment content ends.
        let contentEnd: Int
        /// Character offset where the next segment starts (after the separator).
        let nextStart: Int
    }

    struct StablePrefix: Equatable {
        /// Whitespace in front of the first stable segment.
        let leadingWhitespace: String
        let segments: [WorkflowTextSegment]
        /// The exact source text covered by `leadingWhitespace` and `segments`.
        let consumedText: String
    }

    /// - Parameter allowsSplitting: When false, the content is returned as a single
    ///   segment regardless of its length.
    static func segment(
        _ text: String,
        policy: WorkflowSegmentationPolicy = .default,
        allowsSplitting: Bool = true
    ) -> WorkflowTextSegmentation {
        let characters = Array(text)
        var start = 0
        while start < characters.count, characters[start].isWhitespace { start += 1 }
        var end = characters.count
        while end > start, characters[end - 1].isWhitespace { end -= 1 }

        let leadingWhitespace = String(characters[0..<start])
        guard start < end else {
            return WorkflowTextSegmentation(leadingWhitespace: text, segments: [])
        }
        let trailingWhitespace = String(characters[end...])

        guard allowsSplitting, end - start >= policy.minimumSplitLength else {
            return WorkflowTextSegmentation(
                leadingWhitespace: leadingWhitespace,
                segments: [WorkflowTextSegment(text: String(characters[start..<end]), separator: trailingWhitespace)]
            )
        }

        var segments: [WorkflowTextSegment] = []
        var segmentStart = start
        for cut in cuts(in: characters, contentStart: start, contentEnd: end, policy: policy) {
            segments.append(WorkflowTextSegment(
                text: String(characters[segmentStart..<cut.contentEnd]),
                separator: String(characters[cut.contentEnd..<cut.nextStart])
            ))
            segmentStart = cut.nextStart
        }
        segments.append(WorkflowTextSegment(
            text: String(characters[segmentStart..<end]),
            separator: trailingWhitespace
        ))
        return WorkflowTextSegmentation(leadingWhitespace: leadingWhitespace, segments: segments)
    }

    /// Finds the longest sentence-aligned prefix of a growing transcript that is
    /// at least one target segment long and followed by enough newer text to be
    /// unlikely to be revised. Returns nil while nothing is stable yet.
    static func stablePrefix(
        in pending: String,
        policy: WorkflowSegmentationPolicy = .default
    ) -> StablePrefix? {
        let characters = Array(pending)
        var start = 0
        while start < characters.count, characters[start].isWhitespace { start += 1 }
        var end = characters.count
        while end > start, characters[end - 1].isWhitespace { end -= 1 }
        guard end - start >= policy.targetSegmentLength else { return nil }

        let candidate = boundaries(in: characters, contentStart: start, contentEnd: end)
            .last { boundary in
                boundary.contentEnd - start >= policy.targetSegmentLength
                    && end - boundary.nextStart >= policy.incrementalStabilityMargin
            }
        guard let candidate else { return nil }

        let stableText = String(characters[start..<candidate.nextStart])
        let segmentation = segment(stableText, policy: policy)
        return StablePrefix(
            leadingWhitespace: String(characters[0..<start]),
            segments: segmentation.segments,
            consumedText: String(characters[0..<candidate.nextStart])
        )
    }

    /// Joins `(output, separatorAfter)` pieces. Outputs are trimmed so the source
    /// separators stay authoritative; empty outputs are dropped together with their
    /// separator so no doubled whitespace remains.
    static func join(leadingWhitespace: String, pieces: [(output: String, separator: String)]) -> String {
        var result = ""
        var separatorBeforeNextOutput: String?
        for piece in pieces {
            let output = piece.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { continue }
            result += separatorBeforeNextOutput ?? leadingWhitespace
            result += output
            separatorBeforeNextOutput = piece.separator
        }
        guard separatorBeforeNextOutput != nil, let trailingSeparator = pieces.last?.separator else {
            return ""
        }
        return result + trailingSeparator
    }

    // MARK: - Boundaries

    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…", "‼", "⁇", "⁈", "⁉",
        "。", "！", "？", "｡", "．",
        "؟", "۔", "।", "॥", "։", "።", "။"
    ]

    /// Terminators that end a sentence even without following whitespace.
    private static let unspacedSentenceTerminators: Set<Character> = ["。", "！", "？", "｡"]

    private static let closingPunctuation: Set<Character> = [
        "\"", "'", "”", "’", "»", "«", ")", "]", "}",
        "」", "』", "）", "】", "》", "〉", "〕", "］", "｝"
    ]

    /// Lower-cased tokens that are usually abbreviations when followed by a period.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "e.g", "i.e", "inc", "ltd", "jr", "sr",
        "no", "nr", "ca", "co", "approx", "dept", "fig", "vol",
        "bzw", "usw", "z.b", "d.h", "u.a", "ggf", "evtl", "inkl", "vgl", "bspw", "sog", "str", "tel", "abs", "hr", "fr"
    ]

    private static func cuts(
        in characters: [Character],
        contentStart: Int,
        contentEnd: Int,
        policy: WorkflowSegmentationPolicy
    ) -> [Boundary] {
        // The end of the content acts as a virtual final boundary.
        let endBoundary = Boundary(contentEnd: contentEnd, nextStart: contentEnd)
        let candidates = boundaries(in: characters, contentStart: contentStart, contentEnd: contentEnd) + [endBoundary]

        var cuts: [Boundary] = []
        var segmentStart = contentStart
        var lastBoundaryBelowTarget: Boundary?
        var index = 0
        while index < candidates.count {
            let boundary = candidates[index]
            guard boundary.contentEnd > segmentStart else {
                index += 1
                continue
            }

            let length = boundary.contentEnd - segmentStart
            if length < policy.targetSegmentLength {
                // The rest of the text fits into one segment.
                if boundary == endBoundary { break }
                lastBoundaryBelowTarget = boundary
                index += 1
                continue
            }

            // Cut at whichever boundary lands closer to the target length.
            var cut = boundary
            if let previous = lastBoundaryBelowTarget {
                let previousLength = previous.contentEnd - segmentStart
                if previousLength >= policy.minimumSegmentLength,
                   policy.targetSegmentLength - previousLength <= length - policy.targetSegmentLength {
                    cut = previous
                }
            }

            guard cut != endBoundary, contentEnd - cut.nextStart >= policy.minimumSegmentLength else { break }
            cuts.append(cut)
            segmentStart = cut.nextStart
            lastBoundaryBelowTarget = nil
            if cut == boundary {
                index += 1
            }
        }
        return cuts
    }

    /// Sentence and paragraph boundaries strictly inside the content range, in order.
    private static func boundaries(in characters: [Character], contentStart: Int, contentEnd: Int) -> [Boundary] {
        var result: [Boundary] = []
        var index = contentStart
        while index < contentEnd {
            let character = characters[index]

            if character.isWhitespace {
                var runEnd = index
                var containsLineBreak = false
                while runEnd < contentEnd, characters[runEnd].isWhitespace {
                    containsLineBreak = containsLineBreak || characters[runEnd].isNewline
                    runEnd += 1
                }
                if index > contentStart, runEnd < contentEnd,
                   containsLineBreak || endsSentence(before: index, nextContentIndex: runEnd, in: characters, contentStart: contentStart) {
                    result.append(Boundary(contentEnd: index, nextStart: runEnd))
                }
                index = runEnd
                continue
            }

            if unspacedSentenceTerminators.contains(character) {
                var boundaryEnd = index + 1
                while boundaryEnd < contentEnd, closingPunctuation.contains(characters[boundaryEnd]) {
                    boundaryEnd += 1
                }
                if boundaryEnd < contentEnd,
                   !characters[boundaryEnd].isWhitespace,
                   !sentenceTerminators.contains(characters[boundaryEnd]) {
                    result.append(Boundary(contentEnd: boundaryEnd, nextStart: boundaryEnd))
                }
                index = boundaryEnd
                continue
            }

            index += 1
        }
        return result
    }

    /// Whether the text in front of a whitespace run ends a sentence.
    private static func endsSentence(
        before whitespaceStart: Int,
        nextContentIndex: Int,
        in characters: [Character],
        contentStart: Int
    ) -> Bool {
        var terminatorIndex = whitespaceStart - 1
        while terminatorIndex >= contentStart, closingPunctuation.contains(characters[terminatorIndex]) {
            terminatorIndex -= 1
        }
        guard terminatorIndex >= contentStart,
              sentenceTerminators.contains(characters[terminatorIndex]) else {
            return false
        }

        // "etc. and", "z. B. das": a lower-case continuation is not a new sentence.
        if characters[nextContentIndex].isLowercase {
            return false
        }

        guard characters[terminatorIndex] == "." else { return true }

        var tokenStart = terminatorIndex
        while tokenStart > contentStart, !characters[tokenStart - 1].isWhitespace {
            tokenStart -= 1
        }
        let token = String(characters[tokenStart..<terminatorIndex])
            .trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".")).inverted)
            .lowercased()
        guard !token.isEmpty else { return true }

        // Initials ("J. Smith") and ordinals ("am 3. Oktober") are not sentence ends.
        if token.count == 1, token.first?.isLetter == true {
            return false
        }
        if token.count <= 2, token.allSatisfy(\.isNumber) {
            return false
        }
        return !abbreviations.contains(token)
    }
}
