import Foundation

/// Word-level differences between the text in use and another version, for the History
/// comparison. Words, single punctuation marks and single characters of scripts written
/// without spaces are compared exactly, so changed capitalization and punctuation count as
/// differences. Whitespace only separates tokens: a different line break is not marked.
struct HistoryTextComparison: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Both texts are the same string.
        case identical
        /// Only spaces or line breaks differ.
        case whitespaceOnly
        /// `count` separate places differ; a place is a run of removed and added tokens
        /// between two unchanged ones.
        case changed(count: Int)
        /// More edits than the comparison follows token by token; nothing is marked.
        case tooManyChanges
    }

    let current: String
    let other: String
    let outcome: Outcome
    /// Ranges of `current` that the other version removes or replaces.
    let currentRanges: [Range<String.Index>]
    /// Ranges of `other` that are new compared with `current`.
    let otherRanges: [Range<String.Index>]

    /// The edit limit keeps time and memory bounded for long recordings: the search stores
    /// about limit² / 2 positions (18 MB at 3,000 edits) and stops past the limit.
    static let defaultEditLimit = 3_000

    init(current: String, other: String, editLimit: Int = defaultEditLimit) {
        self.current = current
        self.other = other
        guard current != other else {
            (outcome, currentRanges, otherRanges) = (.identical, [], [])
            return
        }
        let currentTokens = Self.tokens(in: current)
        let otherTokens = Self.tokens(in: other)
        var identifiers: [Substring: Int32] = [:]
        func identifier(_ token: Range<String.Index>, in text: String) -> Int32 {
            let key = text[token]
            if let existing = identifiers[key] { return existing }
            let next = Int32(identifiers.count)
            identifiers[key] = next
            return next
        }
        let a = currentTokens.map { identifier($0, in: current) }
        let b = otherTokens.map { identifier($0, in: other) }

        // Unchanged beginnings and endings are common and need no search.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let middleA = Array(a[prefix..<(a.count - suffix)])
        let middleB = Array(b[prefix..<(b.count - suffix)])
        guard let script = Self.editScript(middleA, middleB, editLimit: editLimit) else {
            (outcome, currentRanges, otherRanges) = (.tooManyChanges, [], [])
            return
        }
        let removed = script.removed.map { $0 + prefix }
        let added = script.added.map { $0 + prefix }
        let count = Self.changeCount(removed: removed, added: added, currentCount: a.count, otherCount: b.count)
        outcome = count == 0 ? .whitespaceOnly : .changed(count: count)
        currentRanges = Self.ranges(of: removed, in: currentTokens)
        otherRanges = Self.ranges(of: added, in: otherTokens)
    }

    var changeCount: Int {
        if case .changed(let count) = outcome { return count }
        return 0
    }

    // MARK: Tokens

    /// Letters and digits form words; every other visible character stands alone.
    static func tokens(in text: String) -> [Range<String.Index>] {
        var tokens: [Range<String.Index>] = []
        var wordStart: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character.isWhitespace {
                if let start = wordStart { tokens.append(start..<index); wordStart = nil }
            } else if (character.isLetter || character.isNumber) && !isWrittenWithoutSpaces(character) {
                if wordStart == nil { wordStart = index }
            } else {
                if let start = wordStart { tokens.append(start..<index); wordStart = nil }
                tokens.append(index..<next)
            }
            index = next
        }
        if let start = wordStart { tokens.append(start..<text.endIndex) }
        return tokens
    }

    /// Chinese, Japanese and Thai-script text has no spaces between words, so each
    /// character is compared on its own instead of a whole sentence as one word.
    private static func isWrittenWithoutSpaces(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x0E00...0x0EFF, // Thai, Lao
             0x1000...0x109F, // Myanmar
             0x1780...0x17FF, // Khmer
             0x3040...0x30FF, // Hiragana, Katakana
             0x31F0...0x31FF, // Katakana phonetic extensions
             0xFF66...0xFF9F: // Halfwidth Katakana
            return true
        default:
            return false
        }
    }

    // MARK: Edit script

    /// The shortest edit script (Myers), as indices of removed `a` and added `b` tokens in
    /// ascending order, or nil when it needs more than `editLimit` edits.
    static func editScript(_ a: [Int32], _ b: [Int32], editLimit: Int) -> (removed: [Int], added: [Int])? {
        let n = a.count, m = b.count
        if n == 0 || m == 0 {
            guard n + m <= editLimit else { return nil }
            return (Array(0..<n), Array(0..<m))
        }
        func snake(_ start: Int, diagonal k: Int) -> Int {
            var x = start
            while x < n, x - k < m, a[x] == b[x - k] { x += 1 }
            return x
        }
        // levels[d][(k + d) / 2] is the furthest x on diagonal k = x - y after d edits,
        // or -1 when that diagonal is out of reach.
        var levels: [[Int32]] = [[Int32(snake(0, diagonal: 0))]]
        if levels[0][0] == n, n == m { return ([], []) }
        let maximum = min(n + m, editLimit)
        guard maximum >= 1 else { return nil }
        for d in 1...maximum {
            let previous = levels[d - 1]
            var level = [Int32](repeating: -1, count: d + 1)
            for k in stride(from: -d, through: d, by: 2) {
                guard let move = Self.move(d: d, k: k, previous: previous, n: n, m: m) else { continue }
                let x = snake(move.x, diagonal: k)
                level[(k + d) / 2] = Int32(x)
                if x == n, x - k == m {
                    levels.append(level)
                    return backtrack(levels: levels, n: n, m: m)
                }
            }
            levels.append(level)
        }
        return nil
    }

    /// The step onto diagonal `k` after `d` edits: from `k + 1` adds a `b` token, from
    /// `k - 1` removes an `a` token. The one reaching further wins; a tie adds.
    private static func move(d: Int, k: Int, previous: [Int32], n: Int, m: Int) -> (fromDiagonal: Int, x: Int)? {
        func furthest(_ diagonal: Int) -> Int {
            guard diagonal >= -(d - 1), diagonal <= d - 1 else { return -1 }
            return Int(previous[(diagonal + d - 1) / 2])
        }
        var best: (fromDiagonal: Int, x: Int)?
        let down = furthest(k + 1)
        if down >= 0, down - k <= m { best = (k + 1, down) }
        let right = furthest(k - 1)
        if right >= 0, right + 1 <= n, right + 1 > (best?.x ?? -1) { best = (k - 1, right + 1) }
        return best
    }

    private static func backtrack(levels: [[Int32]], n: Int, m: Int) -> (removed: [Int], added: [Int]) {
        var removed: [Int] = []
        var added: [Int] = []
        var k = n - m
        for d in stride(from: levels.count - 1, to: 0, by: -1) {
            let previous = levels[d - 1]
            guard let move = move(d: d, k: k, previous: previous, n: n, m: m) else { break }
            if move.fromDiagonal == k + 1 {
                added.append(move.x - k - 1)
            } else {
                removed.append(move.x - 1)
            }
            k = move.fromDiagonal
        }
        return (removed.reversed(), added.reversed())
    }

    private static func changeCount(removed: [Int], added: [Int], currentCount: Int, otherCount: Int) -> Int {
        var isRemoved = [Bool](repeating: false, count: currentCount)
        for index in removed { isRemoved[index] = true }
        var isAdded = [Bool](repeating: false, count: otherCount)
        for index in added { isAdded[index] = true }
        var i = 0, j = 0, count = 0, inChange = false
        while i < currentCount || j < otherCount {
            if i < currentCount, isRemoved[i] {
                i += 1
            } else if j < otherCount, isAdded[j] {
                j += 1
            } else {
                i += 1; j += 1; inChange = false
                continue
            }
            if !inChange { count += 1; inChange = true }
        }
        return count
    }

    /// Adjacent changed tokens become one range that includes the space between them.
    private static func ranges(of indices: [Int], in tokens: [Range<String.Index>]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var previousIndex: Int?
        for index in indices {
            if let previousIndex, previousIndex == index - 1, let last = ranges.popLast() {
                ranges.append(last.lowerBound..<tokens[index].upperBound)
            } else {
                ranges.append(tokens[index])
            }
            previousIndex = index
        }
        return ranges
    }
}
