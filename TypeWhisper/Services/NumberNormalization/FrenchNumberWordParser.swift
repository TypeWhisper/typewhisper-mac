import Foundation

enum FrenchNumberWordParser {
    private static let unitValues: [String: Int] = [
        "zero": 0, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4,
        "cinq": 5, "six": 6, "sept": 7, "huit": 8, "neuf": 9,
    ]

    private static let teenValues: [String: Int] = [
        "dix": 10, "onze": 11, "douze": 12, "treize": 13, "quatorze": 14,
        "quinze": 15, "seize": 16,
    ]

    private static let tensValues: [String: Int] = [
        "vingt": 20, "trente": 30, "quarante": 40,
        "cinquante": 50, "soixante": 60,
    ]

    static func parse(_ words: [String]) -> NumberWordNormalizer.ParsedWords? {
        guard !words.isEmpty else { return nil }
        let normalizedWords = words.map(normalizeWord)
        var index = 0
        var isNegative = false

        if normalizedWords[index] == "moins" {
            isNegative = true
            index += 1
            guard index < normalizedWords.count else { return nil }
        }

        guard let integer = parseInteger(normalizedWords, startingAt: index, allowLeadingArticleOne: isNegative) else {
            return nil
        }
        index = integer.nextIndex
        var replacement = "\(integer.value)"

        if index < normalizedWords.count, let decimalSeparator = decimalSeparator(for: normalizedWords[index]) {
            let decimal = parseDecimalDigits(normalizedWords, startingAt: index + 1)
            if !decimal.digits.isEmpty {
                replacement += "\(decimalSeparator)\(decimal.digits)"
                index = decimal.nextIndex
            }
        }

        if isNegative {
            replacement = "-" + replacement
        }

        return NumberWordNormalizer.ParsedWords(value: replacement, consumedWords: index)
    }

    private static func parseInteger(
        _ words: [String],
        startingAt startIndex: Int,
        allowLeadingArticleOne: Bool
    ) -> (value: Int, nextIndex: Int)? {
        guard startIndex < words.count else { return nil }
        var total = 0
        var current = 0
        var index = startIndex
        var consumed = false
        var lastWasPlainSmallNumber = false

        while index < words.count {
            let word = words[index]

            if ["million", "millions"].contains(word) {
                total += max(current, 1) * 1_000_000
                current = 0
                index += 1
                consumed = true
                lastWasPlainSmallNumber = false
                continue
            }

            if word == "mille" {
                total += max(current, 1) * 1_000
                current = 0
                index += 1
                consumed = true
                lastWasPlainSmallNumber = false
                continue
            }

            if ["cent", "cents"].contains(word) {
                current = max(current, 1) * 100
                index += 1
                consumed = true
                lastWasPlainSmallNumber = false
                continue
            }

            let allowArticleOne = allowsArticleOne(
                at: index,
                in: words,
                startIndex: startIndex,
                allowLeadingArticleOne: allowLeadingArticleOne,
                current: current,
                total: total
            )
            guard let segment = parseUnderHundred(words, startingAt: index, allowArticleOne: allowArticleOne) else {
                break
            }

            if lastWasPlainSmallNumber, segment.value < 10 {
                break
            }

            current += segment.value
            index = segment.nextIndex
            consumed = true
            lastWasPlainSmallNumber = segment.value < 10 && !allowArticleOne
        }

        guard consumed else { return nil }
        return (total + current, index)
    }

    private static func parseUnderHundred(
        _ words: [String],
        startingAt startIndex: Int,
        allowArticleOne: Bool
    ) -> (value: Int, nextIndex: Int)? {
        guard startIndex < words.count else { return nil }

        let word = words[startIndex]
        if word == "quatre",
           startIndex + 1 < words.count,
           ["vingt", "vingts"].contains(words[startIndex + 1]) {
            return appendFrenchRemainder(base: 80, words: words, startingAt: startIndex + 2)
        }

        if word == "dix",
           startIndex + 1 < words.count,
           let unit = unitValue(words[startIndex + 1], allowArticleOne: true),
           unit >= 7 {
            return (10 + unit, startIndex + 2)
        }

        if let ten = tensValues[word] {
            return appendFrenchRemainder(base: ten, words: words, startingAt: startIndex + 1)
        }

        if let teen = teenValues[word] {
            return (teen, startIndex + 1)
        }

        if let unit = unitValue(word, allowArticleOne: allowArticleOne) {
            return (unit, startIndex + 1)
        }

        return nil
    }

    private static func appendFrenchRemainder(
        base: Int,
        words: [String],
        startingAt startIndex: Int
    ) -> (value: Int, nextIndex: Int) {
        let index = startIndex

        if index < words.count, words[index] == "et" {
            let afterEt = index + 1
            if afterEt < words.count {
                if let unit = unitValue(words[afterEt], allowArticleOne: true), unit == 1 {
                    return (base + unit, afterEt + 1)
                }
                if base == 60, let teen = teenValues[words[afterEt]], teen == 11 {
                    return (base + teen, afterEt + 1)
                }
            }
            return (base, startIndex)
        }

        if base == 60, index < words.count, let teen = teenValues[words[index]] {
            return (base + teen, index + 1)
        }

        if base == 80, index < words.count {
            if words[index] == "dix",
               index + 1 < words.count,
               let unit = unitValue(words[index + 1], allowArticleOne: true),
               unit >= 7 {
                return (90 + unit, index + 2)
            }

            if let teen = teenValues[words[index]] {
                return (base + teen, index + 1)
            }
        }

        if index < words.count,
           let unit = unitValue(words[index], allowArticleOne: true),
           unit > 0 {
            return (base + unit, index + 1)
        }

        return (base, startIndex)
    }

    private static func parseDecimalDigits(_ words: [String], startingAt startIndex: Int) -> (digits: String, nextIndex: Int) {
        var digits = ""
        var index = startIndex

        while index < words.count, let digit = unitValue(words[index], allowArticleOne: true) {
            digits += "\(digit)"
            index += 1
        }

        return (digits, index)
    }

    private static func decimalSeparator(for word: String) -> String? {
        switch word {
        case "virgule":
            return ","
        case "point":
            return "."
        default:
            return nil
        }
    }

    private static func unitValue(_ word: String, allowArticleOne: Bool) -> Int? {
        guard let value = unitValues[word] else { return nil }
        if value == 1, !allowArticleOne {
            return nil
        }
        return value
    }

    private static func allowsArticleOne(
        at index: Int,
        in words: [String],
        startIndex: Int,
        allowLeadingArticleOne: Bool,
        current: Int,
        total: Int
    ) -> Bool {
        if index == startIndex, allowLeadingArticleOne {
            return true
        }

        if current >= 100 || total > 0 {
            return true
        }

        guard index + 1 < words.count else { return false }
        return ["cent", "cents", "mille", "million", "millions"].contains(words[index + 1])
    }

    private static func normalizeWord(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .lowercased()
    }
}
