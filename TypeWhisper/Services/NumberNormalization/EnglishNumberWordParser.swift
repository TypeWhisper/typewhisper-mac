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

    static func parse(_ words: [String]) -> NumberWordNormalizer.ParsedWords? {
        guard !words.isEmpty else { return nil }
        let normalizedWords = words.map(normalizeWord)
        var index = 0
        var isNegative = false

        if ["minus", "negative"].contains(normalizedWords[index]) {
            isNegative = true
            index += 1
            guard index < normalizedWords.count else { return nil }
        }

        guard let integer = parseInteger(normalizedWords, startingAt: index) else { return nil }
        index = integer.nextIndex
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
