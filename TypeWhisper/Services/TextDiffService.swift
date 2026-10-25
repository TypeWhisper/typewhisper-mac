import Foundation
import NaturalLanguage

struct CorrectionSuggestion: Identifiable {
    let id = UUID()
    let original: String
    let replacement: String
}

enum DiffSegment: Equatable, Sendable {
    case unchanged(String)
    case removed(String)
    case added(String)
}

final class TextDiffService {
    /// Number of LCS cells compared between two `checkCancellation` calls in `wordDiff`.
    static let cancellationCheckInterval = 1 << 16

    func computeWordDiff(original: String, processed: String) -> [DiffSegment] {
        Self.wordDiff(original: original, processed: processed, maxComparisonCells: .max) ?? []
    }

    /// Computes the same word diff as `computeWordDiff`, but returns `nil` instead of
    /// building an LCS table with more than `maxComparisonCells` cells. The table costs
    /// O(m·n) time and one byte per cell, so callers can present a fallback for very long texts.
    static func wordDiff(original: String, processed: String, maxComparisonCells: Int) -> [DiffSegment]? {
        wordDiff(original: original, processed: processed, maxComparisonCells: maxComparisonCells) {}
    }

    /// Like `wordDiff(original:processed:maxComparisonCells:)`, but runs `checkCancellation`
    /// before the table is built and after every `cancellationCheckInterval` compared cells,
    /// also within a single wide row, so a background caller can abandon the comparison by
    /// throwing. The remaining work outside the table is linear in the word count.
    static func wordDiff(
        original: String,
        processed: String,
        maxComparisonCells: Int,
        checkCancellation: () throws -> Void
    ) rethrows -> [DiffSegment]? {
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

        let (cellCount, overflow) = m.multipliedReportingOverflow(by: n)
        guard !overflow, cellCount <= maxComparisonCells else { return nil }

        try checkCancellation()
        // Keep only the current LCS row and one byte per backtracking direction,
        // rather than an Int for every cell in a nested copy-on-write array.
        var row = Array(repeating: 0, count: n + 1)
        var directions = Array(repeating: UInt8(0), count: m * n)
        if m > 0 && n > 0 {
            var cellsUntilCancellationCheck = cancellationCheckInterval
            for i in 1...m {
                var diagonal = 0
                let rowOffset = (i - 1) * n
                for j in 1...n {
                    cellsUntilCancellationCheck -= 1
                    if cellsUntilCancellationCheck == 0 {
                        cellsUntilCancellationCheck = cancellationCheckInterval
                        try checkCancellation()
                    }
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

                if Self.isNumericValue(origStripped), Self.isNumericValue(replStripped) { continue }

                if Self.isHanEditWithDifferentSound(origStripped, replStripped) { continue }

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

        guard maxSuggestions > 0, !originalTokens.isEmpty, !editedTokens.isEmpty else {
            return []
        }

        let sharedCount = min(originalTokens.count, editedTokens.count)
        var prefix = 0
        while prefix < sharedCount, originalTokens[prefix].text == editedTokens[prefix].text {
            prefix += 1
        }
        var suffix = 0
        while suffix < sharedCount - prefix,
              originalTokens[originalTokens.count - 1 - suffix].text == editedTokens[editedTokens.count - 1 - suffix].text {
            suffix += 1
        }

        let originalChanged = originalTokens[prefix..<(originalTokens.count - suffix)]
        let editedChanged = editedTokens[prefix..<(editedTokens.count - suffix)]

        // 两边都由多个词组成是改写一段话，两边共有的词（项目、的）说明改动区间切得过宽；
        // 多 token 原文只在每个 token 都是单字（分词器不认识的词，例如酷|伯|尼|特|斯）时学习。
        guard originalChanged.count == 1 || editedChanged.count == 1,
              originalChanged.count == 1 || originalChanged.allSatisfy({ $0.text.count == 1 }),
              Set(originalChanged.map(\.text)).isDisjoint(with: editedChanged.map(\.text)),
              let originalSpan = Self.changedSpan(originalChanged, in: original, maximumTokens: Self.maximumOriginalSpanTokens),
              let editedSpan = Self.changedSpan(editedChanged, in: edited, maximumTokens: Self.maximumEditedSpanTokens) else {
            return []
        }

        let originalStripped = Self.strippedWordToken(originalSpan)
        let editedStripped = Self.strippedWordToken(editedSpan)

        guard !originalStripped.isEmpty, !editedStripped.isEmpty,
              originalStripped.lowercased() != editedStripped.lowercased(),
              !(Self.isNumericValue(originalStripped) && Self.isNumericValue(editedStripped)),
              !Self.isHanEditWithDifferentSound(originalStripped, editedStripped) else {
            return []
        }

        return [CorrectionSuggestion(original: originalStripped, replacement: editedStripped)]
    }

    private struct WordToken {
        let text: String
        let range: Range<String.Index>
    }

    /// 识别结果可能把一个词切成几个单字（酷伯尼特斯在句末被切成 5 个），修正后只会是一个词或相邻的两个词。
    private static let maximumOriginalSpanTokens = 5
    private static let maximumEditedSpanTokens = 2

    /// 无空格的文字（中文）由系统分词器切成词，英文仍按单词比较。
    private static func wordTokens(in text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            tokens.append(WordToken(text: String(text[range]), range: range))
            return true
        }
        return tokens
    }

    /// 改动区间只在相邻词紧挨（或只隔连字符、撇号）时才合并成一个词条，
    /// 避免把带空格的多个词或跨标点的整句话学成一个词。
    private static func changedSpan(_ tokens: ArraySlice<WordToken>, in text: String, maximumTokens: Int) -> String? {
        guard let first = tokens.first, let last = tokens.last, tokens.count <= maximumTokens else {
            return nil
        }
        let connectors = CharacterSet(charactersIn: "-‐'’")
        for (previous, next) in zip(tokens, tokens.dropFirst()) {
            let gap = text[previous.range.upperBound..<next.range.lowerBound]
            guard gap.unicodeScalars.allSatisfy(connectors.contains) else { return nil }
        }
        return String(text[first.range.lowerBound..<last.range.upperBound])
    }

    private static func strippedWordToken(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters)
    }

    /// A number changed into another number ("90%" -> "95%") is a content edit,
    /// not a misrecognized word worth replacing in every future dictation.
    /// 汉字数字（三、四）同时是数字和字母，所以只排除字母以外的字符，不能用 isLetter 判断。
    private static func isNumericValue(_ token: String) -> Bool {
        token.contains(where: \.isNumber)
            && token.allSatisfy { $0.isNumber || $0.isPunctuation || $0.isSymbol || $0.isWhitespace }
    }

    /// 汉字改成汉字时，只有读音相近才是听错的词；读音不同（明天 → 后天、记录 → 纪要）是改了内容，
    /// 学进词典会改写之后每次听写里的这个词。两边转成不带声调的拼音，每个字一个音节，按音节逐个比较求编辑距离：
    /// 两个音节相差 0 或 1 个字母时，代价是它们拼音字母的编辑距离；相差更多时（今天 → 明天 的 jin / ming），
    /// 代价是两个音节的字母数之和；多出或缺少一个音节的代价是它的字母数。
    /// 距离超过较长一方拼音字母数的三分之一时不学习。
    private static func isHanEditWithDifferentSound(_ original: String, _ replacement: String) -> Bool {
        guard original.allSatisfy(\.isHan), replacement.allSatisfy(\.isHan) else { return false }
        let originalSyllables = pinyinSyllables(of: original)
        let replacementSyllables = pinyinSyllables(of: replacement)
        let longerLetterCount = max(originalSyllables.joined().count, replacementSyllables.joined().count)
        let distance = editDistance(originalSyllables, replacementSyllables, indelCost: \.count) { first, second in
            let letterDistance = editDistance(first, second, indelCost: { _ in 1 }) { $0 == $1 ? 0 : 1 }
            return letterDistance <= 1 ? letterDistance : first.count + second.count
        }
        return distance * 3 > longerLetterCount
    }

    private static func pinyinSyllables(of text: String) -> [[Character]] {
        let pinyin = text.applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? text
        return pinyin.lowercased().split(whereSeparator: \.isWhitespace).map(Array.init)
    }

    private static func editDistance<Element>(
        _ first: [Element],
        _ second: [Element],
        indelCost: (Element) -> Int,
        substitutionCost: (Element, Element) -> Int
    ) -> Int {
        var row = [0]
        for element in second {
            row.append(row[row.count - 1] + indelCost(element))
        }
        for element in first {
            var diagonal = row[0]
            row[0] += indelCost(element)
            for (index, other) in second.enumerated() {
                let above = row[index + 1]
                row[index + 1] = min(
                    above + indelCost(element),
                    row[index] + indelCost(other),
                    diagonal + substitutionCost(element, other)
                )
                diagonal = above
            }
        }
        return row[second.count]
    }
}
