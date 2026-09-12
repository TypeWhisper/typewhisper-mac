import Foundation

struct CorrectionSuggestion: Identifiable {
    let id = UUID()
    let original: String
    let replacement: String
}

enum DiffSegment: Equatable {
    case unchanged(String)
    case removed(String)
    case added(String)
}

final class TextDiffService {

    func computeWordDiff(original: String, processed: String) -> [DiffSegment] {
        let origWords = original.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace).map(String.init)
        let procWords = processed.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace).map(String.init)

        if origWords.isEmpty && procWords.isEmpty { return [] }
        if origWords.isEmpty { return procWords.map { .added($0) } }
        if procWords.isEmpty { return origWords.map { .removed($0) } }

        // Backtracking always consumes an equal suffix first. Excluding it from
        // the table preserves the original tie-breaking, including repeated words.
        // An equal prefix cannot be trimmed with that same guarantee.
        var m = origWords.count, n = procWords.count
        while m > 0 && n > 0 && origWords[m - 1] == procWords[n - 1] {
            m -= 1
            n -= 1
        }

        // Keep only the current LCS row and one byte per backtracking direction,
        // rather than an Int for every cell in a nested copy-on-write array.
        var row = Array(repeating: 0, count: n + 1)
        var directions = Array(repeating: UInt8(0), count: m * n)
        if m > 0 && n > 0 {
            for i in 1...m {
                var diagonal = 0
                let rowOffset = (i - 1) * n
                for j in 1...n {
                    let above = row[j]
                    if origWords[i - 1] == procWords[j - 1] {
                        row[j] = diagonal + 1
                    } else if row[j - 1] >= above {
                        row[j] = row[j - 1]
                        directions[rowOffset + j - 1] = 1 // added (left wins ties)
                    } else {
                        directions[rowOffset + j - 1] = 2 // removed
                    }
                    diagonal = above
                }
            }
        }

        // Backtrack to produce segments
        var segments: [DiffSegment] = []
        segments.reserveCapacity(origWords.count + procWords.count)
        for word in origWords[m...].reversed() {
            segments.append(.unchanged(word))
        }
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && directions[(i - 1) * n + j - 1] == 0 {
                segments.append(.unchanged(origWords[i - 1]))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || directions[(i - 1) * n + j - 1] == 1) {
                segments.append(.added(procWords[j - 1]))
                j -= 1
            } else {
                segments.append(.removed(origWords[i - 1]))
                i -= 1
            }
        }
        segments.reverse()
        return segments
    }

    func extractCorrections(original: String, edited: String) -> [CorrectionSuggestion] {
        let originalWords = original.split(separator: " ").map(String.init)
        let editedWords = edited.split(separator: " ").map(String.init)

        // Skip if too different (massive rewrite)
        let maxLen = max(originalWords.count, editedWords.count)
        guard maxLen > 0 else { return [] }

        let diff = editedWords.difference(from: originalWords)

        let removals = diff.compactMap { change -> (offset: Int, element: String)? in
            if case .remove(let offset, let element, _) = change {
                return (offset, element)
            }
            return nil
        }
        let insertions = diff.compactMap { change -> (offset: Int, element: String)? in
            if case .insert(let offset, let element, _) = change {
                return (offset, element)
            }
            return nil
        }

        // If more than 50% changed, treat as rewrite
        let changeCount = removals.count + insertions.count
        if changeCount > maxLen { return [] }

        var suggestions: [CorrectionSuggestion] = []
        var usedInsertions = Set<Int>()

        for removal in removals {
            // Find nearest insertion within 3 positions
            var bestMatch: (index: Int, distance: Int)?
            for (i, insertion) in insertions.enumerated() {
                guard !usedInsertions.contains(i) else { continue }
                let distance = abs(removal.offset - insertion.offset)
                if distance <= 3 {
                    if bestMatch == nil || distance < bestMatch!.distance {
                        bestMatch = (i, distance)
                    }
                }
            }

            if let match = bestMatch {
                let insertion = insertions[match.index]
                usedInsertions.insert(match.index)

                // Strip surrounding punctuation from words
                let origStripped = removal.element.trimmingCharacters(in: .punctuationCharacters)
                let replStripped = insertion.element.trimmingCharacters(in: .punctuationCharacters)

                // Skip empty or punctuation-only tokens
                guard !origStripped.isEmpty, !replStripped.isEmpty else { continue }

                // Skip if only punctuation or case changed
                if origStripped.lowercased() == replStripped.lowercased() { continue }

                suggestions.append(CorrectionSuggestion(
                    original: origStripped,
                    replacement: replStripped
                ))
            }
        }

        return suggestions
    }

    func extractHighConfidenceCorrections(
        original: String,
        edited: String,
        maxSuggestions: Int = 3
    ) -> [CorrectionSuggestion] {
        let originalTokens = Self.wordTokens(in: original)
        let editedTokens = Self.wordTokens(in: edited)

        guard maxSuggestions > 0,
              !originalTokens.isEmpty,
              originalTokens.count == editedTokens.count else {
            return []
        }

        var suggestion: CorrectionSuggestion?

        for (originalToken, editedToken) in zip(originalTokens, editedTokens) where originalToken != editedToken {
            guard suggestion == nil else {
                return []
            }

            let originalStripped = Self.strippedWordToken(originalToken)
            let editedStripped = Self.strippedWordToken(editedToken)

            guard !originalStripped.isEmpty, !editedStripped.isEmpty else {
                return []
            }

            guard originalStripped.lowercased() != editedStripped.lowercased() else {
                return []
            }

            guard !Self.isPunctuationOnly(originalToken),
                  !Self.isPunctuationOnly(editedToken) else {
                return []
            }

            suggestion = CorrectionSuggestion(
                original: originalStripped,
                replacement: editedStripped
            )
        }

        guard let suggestion else { return [] }
        return [suggestion]
    }

    private static func wordTokens(in text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func strippedWordToken(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters)
    }

    private static func isPunctuationOnly(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }
}
