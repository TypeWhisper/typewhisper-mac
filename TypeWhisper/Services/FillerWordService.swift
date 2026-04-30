import Foundation

final class FillerWordService {
    private let defaults: UserDefaults
    private var cachedCustomWordsSource: String = ""
    private var cachedCustomRegex: NSRegularExpression?

    private static let hardFillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "ah", "ahh", "er", "hm", "hmm", "ugh"
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func removeFillerWordsIfEnabled(from text: String) -> String {
        guard defaults.bool(forKey: UserDefaultsKeys.removeFillerWordsEnabled) else {
            return text
        }

        let hardMatches = hardMatchRanges(in: text)
        let hardCleaned = removeMatches(in: text, ranges: hardMatches)
        guard let customRegex = customRegex() else {
            return hardCleaned
        }

        let customMatches = regexRanges(in: hardCleaned, using: customRegex)
        return removeMatches(in: hardCleaned, ranges: customMatches)
    }

    private func customRegex() -> NSRegularExpression? {
        let source = defaults.string(forKey: UserDefaultsKeys.removeFillerWordsCustomList) ?? ""
        if source == cachedCustomWordsSource {
            return cachedCustomRegex
        }

        cachedCustomWordsSource = source
        let words = source
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !words.isEmpty else {
            cachedCustomRegex = nil
            return nil
        }

        let alternatives = words
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = #"(?i)\b(?:\#(alternatives))\b"#
        cachedCustomRegex = try? NSRegularExpression(pattern: pattern)
        return cachedCustomRegex
    }

    private func hardMatchRanges(in text: String) -> [Range<String.Index>] {
        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex

        while index < text.endIndex {
            let scalar = text[index].unicodeScalars.first!
            guard wordCharacters.contains(scalar) else {
                index = text.index(after: index)
                continue
            }

            let wordStart = index
            var wordEnd = index
            while wordEnd < text.endIndex {
                let currentScalar = text[wordEnd].unicodeScalars.first!
                guard wordCharacters.contains(currentScalar) else { break }
                wordEnd = text.index(after: wordEnd)
            }

            if Self.hardFillerWords.contains(text[wordStart..<wordEnd].lowercased()) {
                ranges.append(wordStart..<wordEnd)
            }
            index = wordEnd
        }

        return ranges
    }

    private func regexRanges(in text: String, using regex: NSRegularExpression) -> [Range<String.Index>] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: fullRange).compactMap { Range($0.range, in: text) }
    }

    private func removeMatches(in text: String, ranges: [Range<String.Index>]) -> String {
        var output = text
        guard !ranges.isEmpty else { return output }

        for range in ranges.reversed() {
            let distanceToLowerBound = output.distance(from: output.startIndex, to: range.lowerBound)
            let distanceToUpperBound = output.distance(from: output.startIndex, to: range.upperBound)
            let wordStart = output.index(output.startIndex, offsetBy: distanceToLowerBound)
            let wordEnd = output.index(output.startIndex, offsetBy: distanceToUpperBound)
            var replaceStart = wordStart
            var replaceEnd = wordEnd

            var consumedLeadingSpaces = 0
            var consumedTrailingSpaces = 0

            while replaceStart > output.startIndex {
                let previous = output.index(before: replaceStart)
                guard output[previous] == " " else { break }
                replaceStart = previous
                consumedLeadingSpaces += 1
            }

            while replaceEnd < output.endIndex {
                guard output[replaceEnd] == " " else { break }
                replaceEnd = output.index(after: replaceEnd)
                consumedTrailingSpaces += 1
            }

            let replacement = (consumedLeadingSpaces > 0 && consumedTrailingSpaces > 0) ? " " : ""
            output.replaceSubrange(replaceStart..<replaceEnd, with: replacement)
        }

        return output
    }
}
