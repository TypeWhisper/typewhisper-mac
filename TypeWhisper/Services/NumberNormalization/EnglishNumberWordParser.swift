import Foundation

enum EnglishNumberWordParser {
    private static let unitValues: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    private static let teenValues: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tensValues: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let scaleValues: [String: Int] = [
        "thousand": 1_000,
        "million": 1_000_000,
    ]

    // Spoken zeros inside a digit sequence ("four oh two" -> the "oh" is 0).
    // Only read as 0 when flanked by real digits; never starts or ends a run,
    // so a bare interjection "oh" is left alone.
    private static let sequenceZeroWords: Set<String> = ["oh", "o"]

    // Minimum length, in digit positions, before a run of bare single digits is
    // read as one sequence ("one nine eight four" -> 1984) instead of spaced
    // individual digits. Kept high so dictated counting like "one two three"
    // stays split — the false-positive risk lives in the short runs.
    private static let minDigitSequenceLength = 4

    // Unit ordinals 1–9. Used only as the tail of a compound such as
    // "twenty" + "eighth" -> 28th, where the numeric context is unambiguous.
    private static let ordinalUnitValues: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    ]

    // Ordinals safe to convert on their own. Bare "first" / "second" / "third"
    // are deliberately excluded — in dictation they are too often non-numeric
    // ("first, let's...", "wait a second"). They still convert inside a
    // compound ("twenty first" -> 21st), just not standalone.
    private static let standaloneOrdinalValues: [String: Int] = [
        "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
        "hundredth": 100, "thousandth": 1_000,
    ]

    static func parse(_ words: [String]) -> NumberWordNormalizer.ParsedWords? {
        guard !words.isEmpty else { return nil }
        let normalizedWords = words.map(normalizeWord)

        // A long run of bare single digits is a sequence ("one nine eight four"
        // -> 1984), not a cardinal. Checked first because the cardinal path
        // would otherwise emit the same digits spaced apart.
        if let sequence = parseDigitSequence(normalizedWords) {
            return sequence
        }

        var index = 0
        var isNegative = false

        if ["minus", "negative"].contains(normalizedWords[index]) {
            isNegative = true
            index += 1
            guard index < normalizedWords.count else { return nil }
        }

        if let integer = parseInteger(normalizedWords, startingAt: index) {
            index = integer.nextIndex

            // "twenty" + "eighth" -> 28th, "thirty" + "first" -> 31st.
            if integer.value > 0, integer.value % 10 == 0,
               index < normalizedWords.count,
               let unit = ordinalUnitValues[normalizedWords[index]] {
                index += 1
                return makeResult(integer.value + unit, ordinal: true, isNegative: isNegative, consumedWords: index)
            }

            var replacement = "\(integer.value)"

            if index < normalizedWords.count, normalizedWords[index] == "point" {
                let decimal = parseDecimalDigits(normalizedWords, startingAt: index + 1)
                if !decimal.digits.isEmpty {
                    replacement += ".\(decimal.digits)"
                    index = decimal.nextIndex
                }
            }

            if isNegative {
                replacement = "-" + replacement
            }

            return NumberWordNormalizer.ParsedWords(value: replacement, consumedWords: index)
        }

        // Standalone ordinal word ("eighth", "twelfth", "twentieth", ...),
        // excluding the ambiguous bare "first" / "second" / "third".
        if let ordinal = standaloneOrdinalValues[normalizedWords[index]] {
            index += 1
            return makeResult(ordinal, ordinal: true, isNegative: isNegative, consumedWords: index)
        }

        return nil
    }

    // Reads a leading run of bare single-digit words as one joined sequence,
    // e.g. ["one","nine","eight","four"] -> "1984". An "oh"/"o" inside the run
    // counts as 0. The run must start and end on a real digit, and reach
    // `minDigitSequenceLength` positions, or this returns nil and the caller
    // falls back to the cardinal reading.
    private static func parseDigitSequence(_ words: [String]) -> NumberWordNormalizer.ParsedWords? {
        // Must start on a real digit so a leading "oh" is never swallowed as 0.
        guard let first = words.first, unitValues[first] != nil else { return nil }

        var index = 0
        var lastRealDigitIndex = -1
        while index < words.count {
            let word = words[index]
            if unitValues[word] != nil {
                lastRealDigitIndex = index
            } else if !sequenceZeroWords.contains(word) {
                break
            }
            index += 1
        }

        // End on a real digit: a trailing "oh"/"o" is not consumed.
        let positions = lastRealDigitIndex + 1
        guard positions >= minDigitSequenceLength else { return nil }

        var sequence = ""
        for position in 0..<positions {
            // Within the run, anything that is not a unit digit is a flanked
            // "oh"/"o", which reads as 0.
            sequence += "\(unitValues[words[position]] ?? 0)"
        }

        return NumberWordNormalizer.ParsedWords(value: sequence, consumedWords: positions)
    }

    private static func makeResult(_ value: Int, ordinal: Bool, isNegative: Bool, consumedWords: Int) -> NumberWordNormalizer.ParsedWords {
        var replacement = "\(value)"
        if ordinal {
            replacement += ordinalSuffix(value)
        }
        if isNegative {
            replacement = "-" + replacement
        }
        return NumberWordNormalizer.ParsedWords(value: replacement, consumedWords: consumedWords)
    }

    private static func ordinalSuffix(_ value: Int) -> String {
        let magnitude = abs(value)
        if (11...13).contains(magnitude % 100) { return "th" }
        switch magnitude % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static func parseInteger(_ words: [String], startingAt startIndex: Int) -> (value: Int, nextIndex: Int)? {
        guard var group = parseGroup(words, startingAt: startIndex) else { return nil }
        var total = 0
        var current = group.value
        var index = group.nextIndex
        var consumedScale = false

        while index < words.count {
            guard let scale = scaleValues[words[index]] else { break }
            total += current * scale
            current = 0
            consumedScale = true
            index += 1

            if index < words.count, words[index] == "and" {
                index += 1
            }

            if let nextGroup = parseGroup(words, startingAt: index) {
                group = nextGroup
                current = group.value
                index = group.nextIndex
            }
        }

        let value = consumedScale ? total + current : current
        return (value, index)
    }

    private static func parseGroup(_ words: [String], startingAt startIndex: Int) -> (value: Int, nextIndex: Int)? {
        guard startIndex < words.count else { return nil }
        var index = startIndex
        var value = 0
        var consumed = false

        if let base = smallNumberValue(words[index]),
           index + 1 < words.count,
           words[index + 1] == "hundred" {
            value = base * 100
            index += 2
            consumed = true

            if index < words.count, words[index] == "and" {
                index += 1
            }
        }

        if index < words.count, let tens = tensValues[words[index]] {
            value += tens
            index += 1
            consumed = true

            if index < words.count, let unit = unitValues[words[index]], unit > 0 {
                value += unit
                index += 1
            }
        } else if index < words.count, let small = smallNumberValue(words[index]) {
            value += small
            index += 1
            consumed = true
        }

        return consumed ? (value, index) : nil
    }

    private static func parseDecimalDigits(_ words: [String], startingAt startIndex: Int) -> (digits: String, nextIndex: Int) {
        var digits = ""
        var index = startIndex

        while index < words.count, let digit = unitValues[words[index]], digit >= 0, digit <= 9 {
            digits += "\(digit)"
            index += 1
        }

        return (digits, index)
    }

    private static func smallNumberValue(_ word: String) -> Int? {
        unitValues[word] ?? teenValues[word]
    }

    private static func normalizeWord(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
    }
}
