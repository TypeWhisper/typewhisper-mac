import Foundation
import os.log

private let itnLogger = Logger(subsystem: "com.typewhisper", category: "ITN")

// MARK: - Number Word Dictionaries

private let units: [String: Int] = [
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
    "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
]

private let teens: [String: Int] = [
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
    "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19,
]

private let tens: [String: Int] = [
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
]

private let scales: [String: Int] = [
    "hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000,
    // Indian scale words (singular + plural)
    "lakh": 100_000, "lakhs": 100_000, "crore": 10_000_000, "crores": 10_000_000,
]

private let numberWords: Set<String> = {
    var s = Set<String>()
    for k in units.keys {
        s.insert(k)
    }
    for k in teens.keys {
        s.insert(k)
    }
    for k in tens.keys {
        s.insert(k)
    }
    for k in scales.keys {
        s.insert(k)
    }
    s.insert("and")
    s.insert("minus")
    s.insert("negative")
    s.insert("point")
    // "o" and "oh" recognized only within digit spans, not globally
    return s
}()

private let currencyWords: Set<String> = [
    "dollar", "dollars", "cent", "cents",
    "euro", "euros", "rupee", "rupees",
    "pound", "pounds", "yen", "percent", "percentage",
]

private let timeWords: Set<String> = ["am", "pm", "o'clock"]

private let yearExclusionTokens: Set<String> = [
    "million", "thousand", "billion", "hundred",
    "dollar", "dollars", "euro", "euros", "rupee", "rupees",
    "pound", "pounds", "yen", "cent", "cents", "percent", "percentage",
]

// MARK: - Date Words

private let monthNames: [String: Int] = [
    "january": 1, "february": 2, "march": 3, "april": 4,
    "may": 5, "june": 6, "july": 7, "august": 8,
    "september": 9, "october": 10, "november": 11, "december": 12,
    "jan": 1, "feb": 2, "mar": 3, "apr": 4,
    "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9,
    "oct": 10, "nov": 11, "dec": 12,
]

private let ordinalWords: [String: Int] = [
    "first": 1, "second": 2, "third": 3, "fourth": 4,
    "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
    "ninth": 9, "tenth": 10,
    "eleventh": 11, "twelfth": 12, "thirteenth": 13,
    "fourteenth": 14, "fifteenth": 15, "sixteenth": 16,
    "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    "twentieth": 20, "thirtieth": 30,
]

// MARK: - Token Slot

private struct ITNSlot {
    var text: String
    var consumed: Bool
}

// MARK: - NumberNormalizationService

@MainActor
final class NumberNormalizationService {
    private let defaults: UserDefaults

    var isEnabled: Bool {
        get { defaults.bool(forKey: UserDefaultsKeys.itnEnabled) }
        set { defaults.set(newValue, forKey: UserDefaultsKeys.itnEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: UserDefaultsKeys.itnEnabled) == nil {
            defaults.set(true, forKey: UserDefaultsKeys.itnEnabled)
        }
    }

    func normalize(_ text: String) -> String {
        guard isEnabled else { return text }
        guard needsITN(text) else { return text }

        do {
            return try performNormalization(text)
        } catch {
            itnLogger.error("ITN normalization failed: \(error.localizedDescription)")
            return text
        }
    }

    // MARK: - Passes

    private enum ITNPass: Int, CaseIterable {
        // Time and decimals must precede cardinalNumbers: both need to see raw word tokens.
        // Cardinal merges spans greedily (e.g. "three thirty" → 33, "one four" → 5), destroying
        // the structure that time and decimal passes rely on.
        case time = 5
        case yearDetection = 10
        case decimals = 12
        case mixedDigitWordMerge = 15
        case cardinalNumbers = 20
        case currency = 40
        case dateNormalization = 45
        case finalCleanup = 50
    }

    // MARK: - Gate

    private func needsITN(_ text: String) -> Bool {
        let lower = text.lowercased()

        // Tokenize and strip punctuation once — reuse for exact token matching.
        // Prevents false positives from substring matching (e.g. "one" in "someone").
        let tokens = lower.split(separator: " ").map { token in
            let (core, _, _) = stripPunctuation(String(token))
            return core
        }
        let tokenSet = Set(tokens)

        // Singular "cent" (as a standalone word) without "dollar"/"dollars"/
        // "cents"/"per" and without scale words is ambiguous — could be a
        // proper noun (e.g. "fifty cent" the rapper). Don't activate ITN in
        // that narrow case.
        if tokenSet.contains("cent"),
           !tokenSet.contains("cents"),
           !tokenSet.contains("dollar"),
           !tokenSet.contains("dollars"),
           !tokenSet.contains("hundred"),
           !tokenSet.contains("thousand"),
           !tokenSet.contains("million"),
           !tokenSet.contains("billion"),
           !tokenSet.contains("per")
        {
            return false
        }

        for token in tokens {
            if numberWords.contains(token) {
                return true
            }
            // Handle hyphenated compounds like "twenty-five"
            if token.contains("-") {
                let parts = token.split(separator: "-").map(String.init)
                if parts.count == 2,
                   numberWords.contains(parts[0]),
                   numberWords.contains(parts[1])
                {
                    return true
                }
            }
        }
        for word in currencyWords {
            // Skip "cent"/"cents" in the gate check — singular "cent" alone is
            // too ambiguous (e.g. "fifty cent" the rapper), and dollar+cents
            // spans are already triggered by the "dollar" part.
            if word == "cent" || word == "cents" { continue }
            if tokenSet.contains(word) {
                return true
            }
        }
        for word in timeWords {
            if tokenSet.contains(word) {
                return true
            }
        }
        for word in monthNames.keys {
            if tokenSet.contains(word) {
                return true
            }
        }
        return false
    }

    // MARK: - Normalization Engine

    private func performNormalization(_ text: String) throws -> String {
        // Pre-process: "per cent" (two words) → "percent" so the % rule fires correctly
        let preprocessed = normalizePerCent(text)
        let rawTokens = preprocessed.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !rawTokens.isEmpty else { return preprocessed }

        var slots: [ITNSlot] = rawTokens.map { ITNSlot(text: $0, consumed: false) }

        for pass in ITNPass.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch pass {
            case .time:
                try applyTime(&slots)
            case .yearDetection:
                try applyYearDetection(&slots)
            case .decimals:
                try applyDecimals(&slots)
            case .mixedDigitWordMerge:
                try applyMixedDigitWordMerge(&slots)
            case .cardinalNumbers:
                try applyCardinalNumbers(&slots)
            case .currency:
                try applyCurrency(&slots)
            case .dateNormalization:
                try applyDateNormalization(&slots)
            case .finalCleanup:
                try applyFinalCleanup(&slots)
            }
        }

        return slots.filter { !$0.consumed }.map(\.text).joined(separator: " ")
    }

    // MARK: - Helpers

    /// Indian grouping: last 3 digits, then groups of 2 from right (e.g. 1300000 → "13,00,000")
    private func formatIndianNumber(_ value: Int) -> String {
        if value < 0 { return "-" + formatIndianNumber(-value) }
        if value < 1000 { return "\(value)" }
        let str = "\(value)"
        var head = Array(str)
        let n = head.count
        // Peel off last 3
        let tail = String(head[(n - 3)...])
        head = Array(head[..<(n - 3)])
        var groups: [String] = [tail]
        while !head.isEmpty {
            let take = min(2, head.count)
            groups.insert(String(head[(head.count - take)...]), at: 0)
            head = Array(head[..<(head.count - take)])
        }
        return groups.joined(separator: ",")
    }

    /// Replace "per cent" (two words, case-insensitive) with "percent" so the % pass fires.
    private static let perCentRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\bper\\s+cent\\b", options: .caseInsensitive
    )

    private func normalizePerCent(_ text: String) -> String {
        guard let regex = Self.perCentRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "percent")
    }

    private static let punctuationSet = CharacterSet(charactersIn: ".,!?:;")

    private func stripPunctuation(_ token: String) -> (core: String, leading: String, trailing: String) {
        var leading = ""
        var trailing = ""
        var core = token

        while let first = core.first, Self.punctuationSet.contains(first.unicodeScalars.first!) {
            leading.append(core.removeFirst())
        }
        while let last = core.last, Self.punctuationSet.contains(last.unicodeScalars.first!) {
            trailing.insert(core.removeLast(), at: trailing.startIndex)
        }

        return (core, leading, trailing)
    }

    private func resolvedWord(_ token: String) -> String {
        let (core, _, _) = stripPunctuation(token)
        return core.lowercased()
    }

    private func wordToValue(_ word: String) -> Int? {
        if let v = units[word] { return v }
        if let v = teens[word] { return v }
        if let v = tens[word] { return v }
        if let v = scales[word] { return v }
        // Handle hyphenated compounds: "twenty-three" = 23, "forty-five" = 45, etc.
        if word.contains("-") {
            let parts = word.split(separator: "-").map(String.init)
            if parts.count == 2, let t = tens[parts[0]], let u = units[parts[1]] {
                return t + u
            }
        }
        return nil
    }

    private func isNumberWord(_ word: String) -> Bool {
        return wordToValue(word) != nil
    }

    private func isTensOrTeens(_ word: String) -> Bool {
        return tens[word] != nil || teens[word] != nil
    }

    private func isUnit(_ word: String) -> Bool {
        return units[word] != nil
    }

    private func formatNumber(_ value: Int, useCommas: Bool) -> String {
        if value < 0 {
            return "-" + formatNumber(-value, useCommas: useCommas)
        }
        if useCommas && value >= 1000 {
            // Manual Western comma formatting (avoids locale-dependent
            // NumberFormatter behavior).
            let str = "\(value)"
            var result = ""
            let n = str.count
            for (i, ch) in str.enumerated() {
                if i > 0, (n - i) % 3 == 0 {
                    result.append(",")
                }
                result.append(ch)
            }
            return result
        }
        return "\(value)"
    }

    /// Parse a numeric token string to an integer value.
    /// Handles plain digits, Indian-formatted numbers (e.g. "1,00,000"), and decimal strings.
    private func parseNumericToken(_ token: String) -> Int? {
        // Strip commas for Indian-formatted numbers like "5,00,00,000"
        let stripped = token.replacingOccurrences(of: ",", with: "")
        if let v = Int(stripped) { return v }
        if let d = Double(stripped), d == floor(d) { return Int(d) }
        return nil
    }

    /// Parse a token as either an integer or a double (for decimal numbers like "0.5").
    private func parseNumericTokenAsDouble(_ token: String) -> Double? {
        let stripped = token.replacingOccurrences(of: ",", with: "")
        return Double(stripped)
    }

    // MARK: - Number Span Parsing

    /// Parses a contiguous span of number words and numeric tokens into an integer value.
    /// Enforces punctuation boundaries: stops if a token has trailing punctuation.
    /// Handles "o"/"oh" as zero within digit sequences (e.g. "five o five" → 505).
    /// Detects pure sequences of unit words as digit sequences (e.g. "one two three" → 123).
    private func parseNumberSpan(_: [String], startAt index: Int, in slots: [ITNSlot]) -> (value: Int, endIndex: Int, consumedCount: Int)? {
        var i = index
        let n = slots.count
        var current = 0
        var total = 0
        var consumedCount = 0

        // When non-nil, we are in "digit sequence" mode (triggered by "o"/"oh").
        // Each subsequent unit/teen word is treated as a single digit appended to this string.
        var digitSequence: String? = nil

        // Track unit digits for plain digit-sequence detection.
        // When non-nil, all word values seen so far are single-digit units (< 10).
        // Set to nil when a value >= 10 (teen, tens, scale) or a numeric token is encountered.
        var unitDigits: [Int]? = []

        while i < n {
            guard !slots[i].consumed else { break }
            let word = resolvedWord(slots[i].text)

            // --- Punctuation boundary check (Fix 8) ---
            // If the current token has trailing punctuation (comma, period, semicolon),
            // terminate the span immediately. The punctuation stays with this token.
            let (_, _, trailing) = stripPunctuation(slots[i].text)
            let hasTrailingPunct = !trailing.isEmpty

            // Skip "and" connector
            if word == "and" {
                i += 1
                consumedCount += 1
                continue
            }

            // --- Handle "o"/"oh" as zero within digit sequences (Fix 7) ---
            if word == "o" || word == "oh" {
                if digitSequence != nil || current != 0 || total != 0 {
                    // We are inside a number span — treat as digit 0
                    if digitSequence == nil {
                        // Convert accumulated value to digit string and enter digit mode
                        let accumulated = total + current
                        digitSequence = String(accumulated)
                        current = 0
                        total = 0
                    }
                    digitSequence! += "0"
                    i += 1
                    consumedCount += 1
                    // Don't break on trailing punct here; digit sequences can continue
                    continue
                }
                // "o"/"oh" not inside a span — break
                break
            }

            // --- Check for numeric (digit) tokens (Fix 2) ---
            if let digitVal = parseNumericToken(word) {
                // Numeric digit token — part of the span, but not a word unit
                unitDigits = nil
                if digitSequence != nil {
                    // In digit sequence mode: append each digit
                    let digitStr = String(digitVal)
                    digitSequence! += digitStr
                } else if digitVal >= 1_000_000_000 {
                    if current == 0 { current = 1 }
                    total += current * digitVal
                    current = 0
                } else if digitVal >= 1_000_000 {
                    if current == 0 { current = 1 }
                    total += current * digitVal
                    current = 0
                } else if digitVal >= 1000 {
                    if current == 0 { current = 1 }
                    total += current * digitVal
                    current = 0
                } else if digitVal >= 100 {
                    if current == 0 { current = 1 }
                    current *= digitVal
                } else {
                    current += digitVal
                }
                i += 1
                consumedCount += 1
                if hasTrailingPunct { break }
                continue
            }

            // --- Word-based number parsing ---
            guard isNumberWord(word) else { break }
            guard let val = wordToValue(word) else { break }

            // Track unit digits for plain digit-sequence detection
            if unitDigits != nil, val < 10, scales[word] == nil {
                unitDigits!.append(val)
            } else {
                unitDigits = nil
            }

            // If in digit sequence mode, only accept single-digit values
            if digitSequence != nil {
                if val < 10 {
                    digitSequence! += "\(val)"
                    i += 1
                    consumedCount += 1
                    continue
                }
                // Multi-digit values (teens/tens) don't make sense in digit mode
                break
            }

            // Normal arithmetic mode
            if val >= 1_000_000_000 {
                if current == 0 { current = 1 }
                total += current * val
                current = 0
            } else if val >= 1_000_000 {
                if current == 0 { current = 1 }
                total += current * val
                current = 0
            } else if val >= 1000 {
                if current == 0 { current = 1 }
                total += current * val
                current = 0
            } else if val >= 100 {
                if current == 0 { current = 1 }
                current *= val
            } else {
                current += val
            }

            i += 1
            consumedCount += 1

            // Punctuation boundary: if this token has trailing punctuation, terminate span
            if hasTrailingPunct { break }
        }

        // If we were in digit sequence mode, use that value
        if let ds = digitSequence, let sequenceVal = Int(ds) {
            total = sequenceVal
        } else if let digits = unitDigits, digits.count >= 2 {
            // Pure sequence of unit words (no teens/tens/scales) → treat as digit sequence
            let digitStr = digits.map(String.init).joined()
            if let sequenceVal = Int(digitStr) {
                total = sequenceVal
            } else {
                total += current
            }
        } else {
            total += current
        }

        if consumedCount == 0 { return nil }
        return (total, i, consumedCount)
    }

    // MARK: - Pass 0.5: Mixed Digit+Word Merge

    /// Handles ASR outputs like "100 twenty-three" where a round digit is followed by a sub-100
    /// word span. Merges them: 100 + 23 → 123. Only fires when following words are all <100
    /// (no scale words like thousand/lakh), preventing false merges like "100 million".
    private func applyMixedDigitWordMerge(_ slots: inout [ITNSlot]) throws {
        let n = slots.count
        var i = 0

        while i < n {
            guard !slots[i].consumed else { i += 1; continue }
            let (core, _, _) = stripPunctuation(slots[i].text)
            // Only merge when digit is a round multiple of 100 (e.g. 100, 200, 1000).
            // This avoids false merges like "3 thirty pm" → "33".
            guard let digitVal = Int(core), digitVal >= 100, digitVal % 100 == 0 else { i += 1; continue }

            // Scan following tokens for sub-100 number words (and skip "and")
            var wordValue = 0
            var j = i + 1
            var lastWordEnd = i + 1

            while j < n, !slots[j].consumed {
                let word = resolvedWord(slots[j].text)
                if word == "and" { j += 1; continue }
                guard let val = wordToValue(word), val < 100 else { break }
                wordValue += val
                j += 1
                lastWordEnd = j
            }

            if wordValue > 0 {
                let merged = digitVal + wordValue
                let (_, leading, trailing) = stripPunctuation(slots[i].text)
                slots[i].text = leading + "\(merged)" + trailing
                for k in (i + 1) ..< lastWordEnd {
                    slots[k].consumed = true
                }
                i = lastWordEnd
                continue
            }

            i += 1
        }
    }

    // MARK: - Pass 1: Year Detection

    private func applyYearDetection(_ slots: inout [ITNSlot]) throws {
        let n = slots.count
        var i = 0

        while i < n {
            guard !slots[i].consumed else { i += 1; continue }

            // Pattern A: "two thousand [and] <number>" producing year 1900-2099
            if let numberSpanStart = tryMatchThousandAndYear(&slots, from: i) {
                let tokenCount = numberSpanStart.tokenCount
                let year = numberSpanStart.value
                if year >= 1900, year <= 2099 {
                    let yearStr = "\(year)"
                    slots[i].text = reattachPunctuation(yearStr, from: slots[i].text)
                    slots[i].consumed = false
                    for j in (i + 1) ..< (i + tokenCount) {
                        slots[j].consumed = true
                    }
                    i += tokenCount
                    continue
                }
            }

            // Pattern B: two consecutive digit-group tokens forming 19xx/20xx
            if i + 1 < n,
               !slots[i].consumed,
               !slots[i + 1].consumed
            {
                let w0 = resolvedWord(slots[i].text)
                let w1 = resolvedWord(slots[i + 1].text)
                if let v0 = twoDigitValue(w0), let v1 = twoDigitValue(w1) {
                    var year = v0 * 100 + v1
                    var tokenCount = 2

                    // Optional third unit token
                    if i + 2 < n, !slots[i + 2].consumed {
                        let w2 = resolvedWord(slots[i + 2].text)
                        if let v2 = units[w2] {
                            year += v2
                            tokenCount = 3
                        }
                    }

                    // Check exclusion: token after span is not a currency/scale word
                    let afterIdx = i + tokenCount
                    if afterIdx < n {
                        let afterWord = resolvedWord(slots[afterIdx].text)
                        if yearExclusionTokens.contains(afterWord) {
                            i += 1
                            continue
                        }
                    }

                    // Also handle "oh <unit>" in the third position
                    if i + 3 < n,
                       tokenCount == 2,
                       !slots[i + 2].consumed,
                       !slots[i + 3].consumed
                    {
                        let w2 = resolvedWord(slots[i + 2].text)
                        let w3 = resolvedWord(slots[i + 3].text)
                        if w2 == "oh" || w2 == "o", let v3 = units[w3] {
                            year += v3
                            tokenCount = 4
                        }
                    }

                    if year >= 1900, year <= 2099 {
                        let yearStr = "\(year)"
                        slots[i].text = reattachPunctuation(yearStr, from: slots[i].text)
                        slots[i].consumed = false
                        for j in (i + 1) ..< (i + tokenCount) {
                            slots[j].consumed = true
                        }
                        i += tokenCount
                        continue
                    }
                }
            }

            i += 1
        }
    }

    private struct NumberSpanResult {
        let value: Int
        let tokenCount: Int
    }

    private func tryMatchThousandAndYear(_ slots: inout [ITNSlot], from index: Int) -> NumberSpanResult? {
        // Pattern: <number_word> thousand ["and"] <number_word>
        let n = slots.count
        guard index < n, !slots[index].consumed else { return nil }
        let w0 = resolvedWord(slots[index].text)
        guard isNumberWord(w0), scales[w0] == nil else { return nil }
        guard let val0 = wordToValue(w0) else { return nil }
        guard val0 < 100 else { return nil }

        var i = index + 1
        guard i < n, !slots[i].consumed else { return nil }
        let w1 = resolvedWord(slots[i].text)
        guard w1 == "thousand" else { return nil }
        i += 1

        var total = val0 * 1000

        // Skip "and"
        if i < n, !slots[i].consumed, resolvedWord(slots[i].text) == "and" {
            i += 1
        }

        // Parse remaining number after thousand
        if i < n, !slots[i].consumed {
            let spanResult = parseInlineNumberSpan(slots, from: i)
            if let span = spanResult {
                total += span.value
                i = i + span.tokenCount
            }
        }

        let tokenCount = i - index
        return NumberSpanResult(value: total, tokenCount: tokenCount)
    }

    private func parseInlineNumberSpan(_ slots: [ITNSlot], from index: Int) -> NumberSpanResult? {
        let n = slots.count
        var i = index
        var current = 0
        var total = 0
        var consumed = 0
        var foundAny = false

        while i < n {
            guard !slots[i].consumed else { break }
            let word = resolvedWord(slots[i].text)

            if word == "and" {
                i += 1
                consumed += 1
                continue
            }

            guard isNumberWord(word), let val = wordToValue(word) else { break }
            foundAny = true

            if val >= 1000 {
                if current == 0 { current = 1 }
                total += current * val
                current = 0
            } else if val >= 100 {
                if current == 0 { current = 1 }
                current *= val
            } else {
                current += val
            }
            i += 1
            consumed += 1
        }

        total += current
        guard foundAny else { return nil }
        return NumberSpanResult(value: total, tokenCount: consumed)
    }

    private func twoDigitValue(_ word: String) -> Int? {
        if let v = tens[word] { return v }
        if let v = teens[word] { return v }
        // Hyphenated compound like "twenty-six" = 26, "eighty-four" = 84
        if word.contains("-") {
            let parts = word.split(separator: "-").map(String.init)
            if parts.count == 2, let t = tens[parts[0]], let u = units[parts[1]] {
                return t + u
            }
        }
        return nil
    }

    // MARK: - Pass 2: Cardinal Numbers

    private func applyCardinalNumbers(_ slots: inout [ITNSlot]) throws {
        let n = slots.count
        var i = 0

        while i < n {
            guard !slots[i].consumed else { i += 1; continue }
            let word = resolvedWord(slots[i].text)

            // Check if token starts a number span: either a number word or a numeric digit token
            let isNumberStart = isNumberWord(word) || parseNumericToken(word) != nil

            guard isNumberStart else {
                i += 1
                continue
            }

            // Don't start a cardinal span on a bare scale word unless preceded by a digit/unit.
            // Hyphenated compounds (e.g. "twenty-three") are resolved by wordToValue and are
            // not scale words — they should always be allowed to start a span.
            if isNumberWord(word), units[word] == nil, teens[word] == nil, tens[word] == nil, !word.contains("-") {
                // It's a scale word (hundred, thousand, lakh, crore, etc.)
                // Only allow if it's preceded by a numeric token (already handled by parseNumberSpan)
                // or if another number word follows. For bare scale words at start, skip.
                if i + 1 < n {
                    let nextWord = resolvedWord(slots[i + 1].text)
                    if !isNumberWord(nextWord), parseNumericToken(nextWord) == nil {
                        i += 1
                        continue
                    }
                } else {
                    i += 1
                    continue
                }
            }

            // Find consecutive number word span
            if let span = parseNumberSpan([], startAt: i, in: slots) {
                // Skip pure digit tokens that are already normalized (e.g. years
                // converted by yearDetection pass). No word→digit work to do.
                if span.consumedCount == 1, !isNumberWord(resolvedWord(slots[i].text)) {
                    i += 1
                    continue
                }
                let value = span.value
                if value != 0 || units[resolvedWord(slots[i].text)] != nil || parseNumericToken(resolvedWord(slots[i].text)) != nil {
                    // Use Indian grouping when lakh/crore scale words appear in the span
                    let usedIndianScale = (i ..< span.endIndex).contains { idx in
                        let w = resolvedWord(slots[idx].text)
                        return w == "lakh" || w == "lakhs" || w == "crore" || w == "crores"
                    }
                    let formatted = usedIndianScale
                        ? formatIndianNumber(value)
                        : formatNumber(value, useCommas: value >= 1000)
                    let (_, leading, _) = stripPunctuation(slots[i].text)
                    // Use trailing punct from the last token of the span (e.g. "twenty three," → "123,")
                    let (_, _, spanTrailing) = stripPunctuation(slots[span.endIndex - 1].text)
                    slots[i].text = leading + formatted + spanTrailing
                    slots[i].consumed = false
                    for j in (i + 1) ..< span.endIndex {
                        slots[j].consumed = true
                    }
                    i = span.endIndex
                    continue
                }
            }

            i += 1
        }
    }

    // MARK: - Pass 3: Decimals

    private func applyDecimals(_ slots: inout [ITNSlot]) throws {
        let n = slots.count
        var i = 0

        while i < n {
            guard !slots[i].consumed else { i += 1; continue }

            // Check for minus/negative prefix
            var sign = 1
            var startIdx = i
            let w = resolvedWord(slots[i].text)
            if w == "minus" || w == "negative" {
                sign = -1
                startIdx = i + 1
            }

            guard startIdx < n, !slots[startIdx].consumed else { i += 1; continue }

            // Try to parse a number span followed by "point" followed by digits
            // First parse the integer part
            let intWord = resolvedWord(slots[startIdx].text)
            var intValue: Int?
            var intTokens = 0

            if let val = parseIntToken(intWord) {
                // Already a digit (or Indian-formatted number)
                intValue = val
                intTokens = 1
            } else if isNumberWord(intWord) {
                if let span = parseNumberSpan([], startAt: startIdx, in: slots) {
                    intValue = span.value
                    intTokens = span.endIndex - startIdx
                }
            }

            if let intVal = intValue {
                let pointIdx = startIdx + intTokens
                if pointIdx < n, !slots[pointIdx].consumed,
                   resolvedWord(slots[pointIdx].text) == "point"
                {
                    // Parse fractional part
                    let fracStart = pointIdx + 1
                    var fracDigits = ""
                    var fracTokens = 0
                    var fi = fracStart

                    while fi < n, !slots[fi].consumed {
                        let fw = resolvedWord(slots[fi].text)
                        if Int(fw) != nil {
                            fracDigits.append(fw)
                            fracTokens += 1
                            fi += 1
                        } else if let digitVal = units[fw] {
                            fracDigits.append("\(digitVal)")
                            fracTokens += 1
                            fi += 1
                        } else {
                            break
                        }
                    }

                    if !fracDigits.isEmpty {
                        let value = sign * intVal
                        let intStr = String(abs(value))
                        let decimalStr: String
                        if sign < 0 {
                            decimalStr = "-\(intStr).\(fracDigits)"
                        } else {
                            decimalStr = "\(intStr).\(fracDigits)"
                        }

                        // Use first token's punctuation
                        let (_, leading, trailing) = stripPunctuation(slots[i].text)
                        slots[i].text = leading + decimalStr + trailing
                        slots[i].consumed = false

                        // Consume all tokens from startIdx to fracEnd
                        let fracEnd = fracStart + fracTokens
                        for j in (i + 1) ..< fracEnd {
                            if j < slots.count {
                                slots[j].consumed = true
                            }
                        }
                        i = fracEnd
                        continue
                    }
                }

                // No "point" — check minus/negative alone
                if sign < 0, intTokens > 0, startIdx != i {
                    // "minus forty" → "-40"
                    let formatted = "-\(intVal)"
                    let (_, leading, trailing) = stripPunctuation(slots[i].text)
                    slots[i].text = leading + formatted + trailing
                    slots[i].consumed = false
                    for j in (i + 1) ..< (startIdx + intTokens) {
                        slots[j].consumed = true
                    }
                    i = startIdx + intTokens
                    continue
                }
            }

            i += 1
        }
    }

    /// Parse a token as an integer, stripping commas first (for Indian-formatted numbers).
    private func parseIntToken(_ token: String) -> Int? {
        let stripped = token.replacingOccurrences(of: ",", with: "")
        return Int(stripped)
    }

    // MARK: - Pass 4: Currency

    private func applyCurrency(_ slots: inout [ITNSlot]) throws {
        let n = slots.count
        var i = 0

        while i < n {
            guard !slots[i].consumed else { i += 1; continue }

            // Find nearest non-consumed preceding token that is a plain digit or number.
            // We must scan back past consumed slots because earlier passes (e.g. mixed-digit-merge)
            // may have consumed the token immediately before a currency word.
            var prevIdx = i - 1
            while prevIdx >= 0, slots[prevIdx].consumed {
                prevIdx -= 1
            }
            var numberValue: Int?
            var decimalValue: Double?
            var numberTokenIdx: Int?
            var isDecimal = false

            if prevIdx >= 0 {
                let prevText = slots[prevIdx].text
                let (core, _, _) = stripPunctuation(prevText)
                // Try integer first (strip commas for Indian numbers like "5,00,00,000")
                if let val = parseNumericToken(core) {
                    numberValue = val
                    numberTokenIdx = prevIdx
                } else if isNumberWord(core) {
                    // Fallback: cardinal pass did not convert this span.
                    // Log a warning so this does not become silent technical debt.
                    itnLogger.warning("ITN currency fallback fired — cardinal pass may have missed span starting at index \(prevIdx)")
                    if let span = parseNumberSpan([], startAt: prevIdx, in: slots) {
                        numberValue = span.value
                        numberTokenIdx = prevIdx
                    }
                } else if let val = parseNumericTokenAsDouble(core) {
                    // Decimal number like "0.5"
                    decimalValue = val
                    numberTokenIdx = prevIdx
                    isDecimal = true
                }
            }

            let word = resolvedWord(slots[i].text)

            // Capture trailing punctuation from the currency word token so it's not lost
            // when the token is consumed (e.g. "percent." → the "." transfers to the number).
            let (_, _, currTrailing) = stripPunctuation(slots[i].text)

            // Handle decimal percent (e.g. "0.5 percent" → "0.5%")
            if isDecimal, let _ = decimalValue, let numIdx = numberTokenIdx {
                if word == "percent" || word == "percentage" {
                    // Format decimal: keep original precision
                    let (core, _, _) = stripPunctuation(slots[numIdx].text)
                    let coreStripped = core.replacingOccurrences(of: ",", with: "")
                    slots[numIdx].text = reattachPunctuation("\(coreStripped)%\(currTrailing)", from: slots[numIdx].text)
                    slots[i].consumed = true
                    i += 1
                    continue
                }
            }

            if let numVal = numberValue, let numIdx = numberTokenIdx {
                // Use Indian-formatted display text when available (Fix 9 — preserves lakh/crore comma formatting)
                let displayNumber: String = {
                    let (prevCore, _, _) = stripPunctuation(slots[numIdx].text)
                    return prevCore.contains(",") ? prevCore : "\(numVal)"
                }()

                switch word {
                case "dollar", "dollars":
                    slots[numIdx].text = reattachPunctuation("$\(displayNumber)\(currTrailing)", from: slots[numIdx].text)
                    slots[i].consumed = true
                    // Check for "and <number> cent(s)" after (Fix 3 & 4: comma and missing connector handled in tryMergeCents)
                    i = tryMergeCents(&slots, dollarIdx: numIdx, currentIdx: i + 1)
                    continue

                case "euro", "euros":
                    slots[numIdx].text = reattachPunctuation("€\(displayNumber)\(currTrailing)", from: slots[numIdx].text)
                    slots[i].consumed = true
                    i += 1
                    continue

                case "rupee", "rupees":
                    slots[numIdx].text = reattachPunctuation("₹\(displayNumber)\(currTrailing)", from: slots[numIdx].text)
                    slots[i].consumed = true
                    i += 1
                    continue

                case "pound", "pounds":
                    slots[numIdx].text = reattachPunctuation("£\(displayNumber)\(currTrailing)", from: slots[numIdx].text)
                    slots[i].consumed = true
                    i += 1
                    continue

                case "percent", "percentage":
                    slots[numIdx].text = reattachPunctuation("\(displayNumber)%\(currTrailing)", from: slots[numIdx].text)
                    slots[i].consumed = true
                    i += 1
                    continue

                case "cents":
                    // Standalone "N cents" (plural, no preceding dollars) → "$0.NN"
                    // Singular "cent" is skipped here because it may be a proper noun
                    // (e.g. "fifty cent"). Dollar+cent merges are handled by tryMergeCents.
                    slots[numIdx].text = reattachPunctuation(String(format: "$0.%02d\(currTrailing)", numVal), from: slots[numIdx].text)
                    slots[i].consumed = true
                    i += 1
                    continue

                default:
                    break
                }
            }

            i += 1
        }
    }

    private func tryMergeCents(_ slots: inout [ITNSlot], dollarIdx: Int, currentIdx: Int) -> Int {
        let n = slots.count
        var idx = currentIdx

        // Skip "and"  (Fix 4: connector is optional)
        if idx < n, resolvedWord(slots[idx].text) == "and" {
            slots[idx].consumed = true
            idx += 1
        }

        // Skip comma token if present between dollar and cents (Fix 3)
        // "One dollar, one cent." → the comma is trailing on "dollar," which we already consumed.
        // But if comma is its own token, skip it.
        if idx < n, !slots[idx].consumed {
            let (core, _, _) = stripPunctuation(slots[idx].text)
            if core.isEmpty {
                // Pure punctuation token like ","
                slots[idx].consumed = true
                idx += 1
            }
        }

        // Look for <number> cent(s)
        if idx < n, !slots[idx].consumed {
            let numberCore = resolvedWord(slots[idx].text)
            // Could be already-converted digit, number word, or Indian-formatted number
            if let centVal = parseNumericToken(numberCore) {
                // Scan forward past any consumed slots to find "cent"/"cents"
                var centsIdx = idx + 1
                while centsIdx < n, slots[centsIdx].consumed {
                    centsIdx += 1
                }
                if centsIdx < n, !slots[centsIdx].consumed {
                    let centWord = resolvedWord(slots[centsIdx].text)
                    if centWord == "cent" || centWord == "cents" {
                        // Extract dollar value robustly: strip currency symbol and any non-numeric chars (Fix 3)
                        let dollarText = slots[dollarIdx].text
                        let (dollarCore, _, _) = stripPunctuation(dollarText)
                        let dollarDigits = dollarCore.replacingOccurrences(of: "$", with: "")
                            .replacingOccurrences(of: ",", with: "")
                        if let dollarVal = Int(dollarDigits) {
                            let totalDollars = dollarVal + centVal / 100
                            let remainingCents = centVal % 100
                            let mergedAmount = remainingCents > 0
                                ? "$\(totalDollars).\(String(format: "%02d", remainingCents))"
                                : "$\(totalDollars).00"
                            let (_, _, centsTrailing) = stripPunctuation(slots[centsIdx].text)
                            let (_, dollarLeading, _) = stripPunctuation(slots[dollarIdx].text)
                            slots[dollarIdx].text = dollarLeading + mergedAmount + centsTrailing
                        }
                        slots[idx].consumed = true
                        slots[centsIdx].consumed = true
                        return centsIdx + 1
                    }
                }
            } else if isNumberWord(numberCore) {
                if let span = parseNumberSpan([], startAt: idx, in: slots) {
                    let centVal = span.value
                    let centEnd = span.endIndex
                    if centEnd < n, !slots[centEnd].consumed {
                        let centWord = resolvedWord(slots[centEnd].text)
                        if centWord == "cent" || centWord == "cents" {
                            let dollarText = slots[dollarIdx].text
                            let (dollarCore, _, _) = stripPunctuation(dollarText)
                            let dollarDigits = dollarCore.replacingOccurrences(of: "$", with: "")
                                .replacingOccurrences(of: ",", with: "")
                            if let dollarVal = Int(dollarDigits) {
                                let totalDollars = dollarVal + centVal / 100
                                let remainingCents = centVal % 100
                                let mergedAmount = remainingCents > 0
                                    ? "$\(totalDollars).\(String(format: "%02d", remainingCents))"
                                    : "$\(totalDollars).00"
                                let (_, _, centsTrailing) = stripPunctuation(slots[centEnd].text)
                                let (_, dollarLeading, _) = stripPunctuation(slots[dollarIdx].text)
                                slots[dollarIdx].text = dollarLeading + mergedAmount + centsTrailing
                            }
                            for j in idx ..< centEnd {
                                slots[j].consumed = true
                            }
                            slots[centEnd].consumed = true
                            return centEnd + 1
                        }
                    }
                }
            }
        }

        return idx
    }

    // MARK: - Pass 5: Time

    private func applyTime(_ slots: inout [ITNSlot]) throws {
        let n = slots.count
        var i = 0

        while i < n {
            guard !slots[i].consumed else { i += 1; continue }

            let word = resolvedWord(slots[i].text)
            let hasDisambiguator = (word == "am" || word == "pm" || word == "o'clock")
            guard hasDisambiguator else { i += 1; continue }

            if word == "o'clock" {
                // Scan backward past consumed slots — earlier passes may have consumed
                // tokens between the hour and o'clock. Mirrors applyCurrency pattern.
                var prevIdx = i - 1
                while prevIdx >= 0, slots[prevIdx].consumed {
                    prevIdx -= 1
                }

                if prevIdx >= 0 {
                    let prevWord = resolvedWord(slots[prevIdx].text)
                    if let hourVal = Int(slots[prevIdx].text) {
                        let (_, leading, trailing) = stripPunctuation(slots[prevIdx].text)
                        slots[prevIdx].text = leading + "\(hourVal):00" + trailing
                        slots[i].consumed = true
                        i += 1
                        continue
                    } else if isNumberWord(prevWord) {
                        if let span = parseNumberSpan([], startAt: prevIdx, in: slots) {
                            let hourVal = span.value
                            if hourVal > 0, hourVal <= 12 {
                                let (_, leading, trailing) = stripPunctuation(slots[prevIdx].text)
                                slots[prevIdx].text = leading + "\(hourVal):00" + trailing
                                for j in (prevIdx + 1) ..< span.endIndex {
                                    slots[j].consumed = true
                                }
                                slots[i].consumed = true
                                i = span.endIndex
                                continue
                            }
                        }
                    }
                }

            } else if word == "am" || word == "pm" {
                let suffix = word.lowercased()

                // Scan backward past consumed slots — earlier passes (cardinal, year detection)
                // may have consumed tokens between the hour and am/pm.
                // This mirrors the pattern in applyCurrency.

                // Collect up to 3 nearest non-consumed slots before i
                var prevIndices: [Int] = []
                var scan = i - 1
                while scan >= 0, prevIndices.count < 3 {
                    if !slots[scan].consumed {
                        prevIndices.append(scan)
                    }
                    scan -= 1
                }
                // prevIndices[0] = nearest, [1] = one further back, [2] = two further back

                // Pattern: <hour> oh <minute> am/pm
                if prevIndices.count >= 3 {
                    let minIdx = prevIndices[0]
                    let ohIdx = prevIndices[1]
                    let hourIdx = prevIndices[2]

                    let ohWord = resolvedWord(slots[ohIdx].text)
                    let hourWord = resolvedWord(slots[hourIdx].text)
                    let minWord = resolvedWord(slots[minIdx].text)

                    if ohWord == "oh" || ohWord == "o" {
                        var hourVal: Int?
                        if let v = Int(slots[hourIdx].text) { hourVal = v }
                        else if let v = wordToValue(hourWord), v < 100 { hourVal = v }

                        var minVal: Int?
                        if let v = Int(slots[minIdx].text) { minVal = v }
                        else if let v = units[minWord] { minVal = v }

                        if let h = hourVal, let m = minVal, h > 0, h <= 12, m >= 0, m <= 9 {
                            slots[hourIdx].text = reattachPunctuation("\(h):0\(m)\(suffix)", from: slots[hourIdx].text)
                            slots[ohIdx].consumed = true
                            slots[minIdx].consumed = true
                            slots[i].consumed = true
                            i += 1
                            continue
                        }
                    }
                }

                // Pattern: <hour> <minute> am/pm
                if prevIndices.count >= 2 {
                    let minIdx = prevIndices[0]
                    let hourIdx = prevIndices[1]

                    let hourWord = resolvedWord(slots[hourIdx].text)
                    let minWord = resolvedWord(slots[minIdx].text)

                    var hourVal: Int?
                    if let v = Int(slots[hourIdx].text) { hourVal = v }
                    else if let v = wordToValue(hourWord), v < 100 { hourVal = v }

                    let minuteMap: [String: Int] = [
                        "thirty": 30, "fifteen": 15, "forty": 40,
                        "five": 5, "ten": 10, "twenty": 20, "fifty": 50,
                    ]
                    var minVal: Int?
                    if let v = minuteMap[minWord] { minVal = v }
                    else if let v = Int(slots[minIdx].text) { minVal = v }
                    else if let span = parseNumberSpan([], startAt: minIdx, in: slots),
                            span.value > 0, span.value < 60 { minVal = span.value }

                    if let h = hourVal, let m = minVal, h > 0, h <= 12, m >= 0, m < 60 {
                        slots[hourIdx].text = reattachPunctuation("\(h):\(String(format: "%02d", m))\(suffix)", from: slots[hourIdx].text)
                        slots[minIdx].consumed = true
                        slots[i].consumed = true
                        i += 1
                        continue
                    }
                }

                // Pattern: <hour> am/pm (bare hour)
                if let hourIdx = prevIndices.first {
                    let hourWord = resolvedWord(slots[hourIdx].text)
                    var hourVal: Int?
                    if let v = Int(slots[hourIdx].text) { hourVal = v }
                    else if let v = wordToValue(hourWord), v < 100 { hourVal = v }

                    if let h = hourVal, h > 0, h <= 12 {
                        slots[hourIdx].text = reattachPunctuation("\(h)\(suffix)", from: slots[hourIdx].text)
                        slots[i].consumed = true
                        i += 1
                        continue
                    }
                }
            }

            i += 1
        }
    }

    // MARK: - Pass 5: Date Normalization

    private func applyDateNormalization(_ slots: inout [ITNSlot]) throws {
        let n = slots.count
        var i = 0

        while i < n {
            guard !slots[i].consumed else { i += 1; continue }

            let word = resolvedWord(slots[i].text)

            // Pattern 4 (British): [the] ordinal + "of" + month
            // Also handles compound ordinals split by cardinal pass:
            //   "twenty first of april" → ["20", "first", "of", "april"]
            //   → "21st of April"
            if let ordinalVal = ordinalWords[word] {
                if i + 2 < n,
                   !slots[i + 1].consumed,
                   resolvedWord(slots[i + 1].text) == "of",
                   !slots[i + 2].consumed,
                   matchMonth(slots[i + 2].text) != nil
                {
                    var adjustedVal = ordinalVal
                    var consumedPrev = false
                    // Look backward for a digit created by cardinal pass
                    // from a compound ordinal like "twenty" (→20) + "first" (→1)
                    if i > 0, !slots[i - 1].consumed {
                        let prevWord = resolvedWord(slots[i - 1].text)
                        if let prevDigit = Int(prevWord), prevDigit == 20 || prevDigit == 30 {
                            let combined = prevDigit + ordinalVal
                            if combined >= 1, combined <= 31 {
                                adjustedVal = combined
                                consumedPrev = true
                            }
                        }
                    }

                    let suffix = ordinalSuffix(for: adjustedVal)
                    if consumedPrev {
                        slots[i - 1].consumed = true
                    }
                    slots[i].text = reattachPunctuation("\(adjustedVal)\(suffix)", from: slots[i].text)
                    let monthName = capitalizeMonthName(slots[i + 2].text)
                    slots[i + 2].text = reattachPunctuation(monthName, from: slots[i + 2].text)
                    i += 3
                    continue
                }
                i += 1
                continue
            }

            // Patterns 1/2/3: Month + Day [+ Year]
            guard matchMonth(word) != nil else { i += 1; continue }
            guard i + 1 < n, !slots[i + 1].consumed else { i += 1; continue }

            let dayToken = resolvedWord(slots[i + 1].text)
            var dayValue: Int?
            var dayEndIndex = i + 1

            // Ordinal day (e.g. "fifteenth")
            if let ordVal = ordinalWords[dayToken] {
                dayValue = ordVal
                dayEndIndex = i + 1
                // Digit day (already converted by cardinal pass, e.g. "23")
            } else if let digitVal = Int(dayToken), digitVal >= 1, digitVal <= 31 {
                dayValue = digitVal
                dayEndIndex = i + 1
                // Digit + ordinal: "20" + "first" → 21 (only combine 20/30)
                if i + 2 < n, !slots[i + 2].consumed, digitVal == 20 || digitVal == 30 {
                    let nextWord = resolvedWord(slots[i + 2].text)
                    if let ordVal2 = ordinalWords[nextWord] {
                        let combined = digitVal + ordVal2
                        if combined >= 1, combined <= 31 {
                            dayValue = combined
                            dayEndIndex = i + 2
                        }
                    }
                }
                // Number-word cardinal day via parseNumberSpan (FIX 2)
            } else if isNumberWord(dayToken) {
                if let span = parseNumberSpan([], startAt: i + 1, in: slots) {
                    // Reject if span includes scale words
                    let hasScaleWord = (i + 1 ..< span.endIndex).contains { idx in
                        let w = resolvedWord(slots[idx].text)
                        return scales[w] != nil
                    }
                    if !hasScaleWord, span.value >= 1, span.value <= 31 {
                        dayValue = span.value
                        dayEndIndex = span.endIndex - 1
                    }
                }
            }

            guard let day = dayValue, day >= 1, day <= 31 else { i += 1; continue }

            // Capitalize month
            let monthName = capitalizeMonthName(slots[i].text)
            slots[i].text = reattachPunctuation(monthName, from: slots[i].text)

            // Replace first token of day span, consume the rest
            slots[i + 1].text = reattachPunctuation("\(day)", from: slots[i + 1].text)
            if dayEndIndex > i + 1 {
                for j in (i + 2) ... dayEndIndex {
                    slots[j].consumed = true
                }
            }

            // Pattern 3: Optional year
            let yearSearchStart = dayEndIndex + 1
            if yearSearchStart < n, !slots[yearSearchStart].consumed {
                let rawYearSearchToken = slots[yearSearchStart].text
                let (yearSearchCore, yearSearchLeading, _) = stripPunctuation(rawYearSearchToken)
                var commaConsumed = false
                var yearTokenStart = yearSearchStart

                // Detect comma separator in any of three forms (FIX 3):
                // 1. Trailing comma on day token — handled below when formatting output
                // 2. Leading comma on year token (e.g. ",2026")
                // 3. Standalone comma token (e.g. ",")
                if yearSearchCore.isEmpty {
                    // Case 3: standalone punctuation token
                    commaConsumed = true
                    yearTokenStart = yearSearchStart + 1
                } else if yearSearchLeading.contains(",") {
                    // Case 2: leading comma on year token
                    commaConsumed = true
                } else if resolvedWord(rawYearSearchToken) == "," {
                    commaConsumed = true
                    yearTokenStart = yearSearchStart + 1
                }

                if yearTokenStart < n, !slots[yearTokenStart].consumed {
                    let yearStr = slots[yearTokenStart].text
                    let (yearCore, _, _) = stripPunctuation(yearStr)

                    if let yearVal = Int(yearCore), yearVal >= 1000, yearVal <= 2999 {
                        // Exclusion: not followed by currency/percent/time
                        let afterIdx = yearTokenStart + 1
                        var isExcluded = false
                        if afterIdx < n {
                            let afterWord = resolvedWord(slots[afterIdx].text)
                            if currencyWords.contains(afterWord) || timeWords.contains(afterWord) {
                                isExcluded = true
                            }
                        }

                        if !isExcluded {
                            if commaConsumed {
                                slots[yearSearchStart].consumed = true
                            }
                            let (_, _, yearTrailing) = stripPunctuation(yearStr)

                            // Formatting is deterministic: always "Month D, YYYY" when year present.
                            // Input comma structure is intentionally ignored here.
                            let (dayCore, dayLeading, dayTrailing) = stripPunctuation(slots[i + 1].text)
                            let cleanedTrailing = dayTrailing.replacingOccurrences(of: ",", with: "")
                            slots[i + 1].text = dayLeading + dayCore + "," + cleanedTrailing
                            slots[yearTokenStart].text = yearCore + yearTrailing
                            i = yearTokenStart
                            continue
                        }
                    }
                }
            }

            i = dayEndIndex
            continue
        }
    }

    // MARK: - Date Helpers

    private func matchMonth(_ token: String) -> Int? {
        let (core, _, _) = stripPunctuation(token)
        return monthNames[core.lowercased()]
    }

    private func capitalizeMonthName(_ token: String) -> String {
        let (core, leading, trailing) = stripPunctuation(token)
        guard !core.isEmpty else { return token }
        let capitalized = core.prefix(1).uppercased() + core.dropFirst()
        return leading + capitalized + trailing
    }

    private func ordinalSuffix(for value: Int) -> String {
        let mod100 = value % 100
        let mod10 = value % 10
        if mod100 >= 11, mod100 <= 13 { return "th" }
        switch mod10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private func isCommaToken(_ word: String) -> Bool {
        let (core, _, _) = stripPunctuation(word)
        return core.isEmpty || core == ","
    }

    // MARK: - Pass 6: Final Cleanup (Fix 5 & 6)

    /// Handles post-normalization patterns that require already-converted numbers:
    /// - "minus/negative + <number>" → "-<number>"
    /// - "<number> percent" → "<number>%" (backup for cases currency pass missed)
    private func applyFinalCleanup(_ slots: inout [ITNSlot]) throws {
        let n = slots.count
        var i = 0

        while i < n {
            guard !slots[i].consumed else { i += 1; continue }

            let word = resolvedWord(slots[i].text)

            // --- Fix 6: minus/negative + <number> → -<number> ---
            if word == "minus" || word == "negative", i + 1 < n, !slots[i + 1].consumed {
                let nextText = slots[i + 1].text
                let (nextCore, nextLeading, nextTrailing) = stripPunctuation(nextText)

                // Extract the leading numeric portion from nextCore (may have % or other suffix)
                // Match optional leading minus, digits, optional decimal point + digits
                let pattern = #"^-?\d+(?:,\d{1,2})*(?:\.\d+)?"#
                if let match = nextCore.range(of: pattern, options: .regularExpression) {
                    let numericPart = String(nextCore[match.lowerBound ..< match.upperBound])
                    let suffix = String(nextCore[match.upperBound...])

                    // Prevent double-negative
                    let finalNumber: String
                    if numericPart.hasPrefix("-") {
                        finalNumber = String(numericPart.dropFirst())
                    } else {
                        finalNumber = "-" + numericPart
                    }

                    slots[i].text = nextLeading + finalNumber + suffix + nextTrailing
                    slots[i].consumed = false
                    slots[i + 1].consumed = true
                    i += 2
                    continue
                }
            }

            // --- Fix 5: <number> percent → <number>% (backup) ---
            // Only fires when the current token is (or contains) a number and the next is "percent"
            if i + 1 < n, !slots[i + 1].consumed {
                let nextWord = resolvedWord(slots[i + 1].text)
                if nextWord == "percent" || nextWord == "percentage" {
                    let (core, _, _) = stripPunctuation(slots[i].text)
                    let coreStripped = core.replacingOccurrences(of: ",", with: "")
                    if Int(coreStripped) != nil || Double(coreStripped) != nil {
                        let (_, _, nextTrailing) = stripPunctuation(slots[i + 1].text)
                        slots[i].text = reattachPunctuation(coreStripped + "%" + nextTrailing, from: slots[i].text)
                        slots[i + 1].consumed = true
                        i += 2
                        continue
                    }
                }
            }

            i += 1
        }
    }

    // MARK: - Punctuation Reattachment

    private func reattachPunctuation(_ newCore: String, from original: String) -> String {
        let (_, leading, trailing) = stripPunctuation(original)
        return leading + newCore + trailing
    }
}
