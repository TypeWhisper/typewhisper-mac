import Foundation

enum DutchNumberWordParser {
    private static let unitValues: [String: Int] = [
        "nul": 0, "een": 1, "twee": 2, "drie": 3, "vier": 4, "vijf": 5,
        "zes": 6, "zeven": 7, "acht": 8, "negen": 9,
    ]

    private static let teenValues: [String: Int] = [
        "tien": 10, "elf": 11, "twaalf": 12, "dertien": 13, "veertien": 14,
        "vijftien": 15, "zestien": 16, "zeventien": 17, "achttien": 18,
        "negentien": 19,
    ]

    private static let tensValues: [String: Int] = [
        "twintig": 20, "dertig": 30, "veertig": 40, "vijftig": 50,
        "zestig": 60, "zeventig": 70, "tachtig": 80, "negentig": 90,
    ]

    static func parse(_ words: [String]) -> NumberWordNormalizer.ParsedWords? {
        guard !words.isEmpty else { return nil }
        let normalizedWords = words.map(normalizeWord)
        var index = 0
        var isNegative = false

        if ["min", "minus"].contains(normalizedWords[index]) {
            isNegative = true
            index += 1
            guard index < normalizedWords.count else { return nil }
        }

        let allowLeadingArticleOne = isNegative || startsWithOneDecimal(at: index, in: normalizedWords)
        guard let integer = parseInteger(
            normalizedWords,
            startingAt: index,
            allowLeadingArticleOne: allowLeadingArticleOne
        ) else {
            return nil
        }
        index = integer.nextIndex
        var replacement = "\(integer.value)"

        if index < normalizedWords.count, normalizedWords[index] == "komma" {
            let decimal = parseDecimalDigits(normalizedWords, startingAt: index + 1)
            if !decimal.digits.isEmpty {
                replacement += ",\(decimal.digits)"
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

            if word == "en",
               let remainder = parseOptionalAndRemainder(words, startingAt: index, current: current, total: total) {
                current += remainder.value
                index = remainder.nextIndex
                consumed = true
                lastWasPlainSmallNumber = false
                continue
            }

            if ["miljoen", "miljoenen"].contains(word) {
                total += max(current, 1) * 1_000_000
                current = 0
                index += 1
                consumed = true
                lastWasPlainSmallNumber = false
                continue
            }

            if word == "duizend" {
                total += max(current, 1) * 1_000
                current = 0
                index += 1
                consumed = true
                lastWasPlainSmallNumber = false
                continue
            }

            if word == "honderd" {
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
            guard let segment = parseSegment(words, startingAt: index, allowArticleOne: allowArticleOne) else {
                break
            }

            if lastWasPlainSmallNumber {
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

    private static func parseSegment(
        _ words: [String],
        startingAt startIndex: Int,
        allowArticleOne: Bool
    ) -> (value: Int, nextIndex: Int)? {
        if let underHundred = parseUnderHundred(words, startingAt: startIndex, allowArticleOne: allowArticleOne) {
            return underHundred
        }

        guard let compound = parseCompound(words[startIndex], allowArticleOne: allowArticleOne) else {
            return nil
        }
        return (compound, startIndex + 1)
    }

    private static func parseUnderHundred(
        _ words: [String],
        startingAt startIndex: Int,
        allowArticleOne: Bool
    ) -> (value: Int, nextIndex: Int)? {
        guard startIndex < words.count else { return nil }
        let word = words[startIndex]

        if let unit = unitValue(word, allowArticleOne: true),
           unit > 0,
           startIndex + 2 < words.count,
           words[startIndex + 1] == "en",
           let ten = tensValues[words[startIndex + 2]] {
            return (unit + ten, startIndex + 3)
        }

        if let direct = directValue(word, allowArticleOne: allowArticleOne) {
            return (direct, startIndex + 1)
        }

        return nil
    }

    private static func parseCompound(_ word: String, allowArticleOne: Bool) -> Int? {
        if let direct = directValue(word, allowArticleOne: allowArticleOne) {
            return direct
        }

        if let range = word.range(of: "duizend") {
            let prefix = String(word[..<range.lowerBound])
            let suffix = String(word[range.upperBound...])
            let prefixValue = prefix.isEmpty ? 1 : parseCompound(prefix, allowArticleOne: true)
            guard let prefixValue,
                  let suffixValue = compoundSuffixValue(suffix) else {
                return nil
            }
            return prefixValue * 1_000 + suffixValue
        }

        if let range = word.range(of: "honderd") {
            let prefix = String(word[..<range.lowerBound])
            let suffix = String(word[range.upperBound...])
            let prefixValue = prefix.isEmpty ? 1 : parseUnderHundred(prefix, allowArticleOne: true)
            guard let prefixValue,
                  let suffixValue = compoundSuffixValue(suffix) else {
                return nil
            }
            return prefixValue * 100 + suffixValue
        }

        return parseUnderHundred(word, allowArticleOne: allowArticleOne)
    }

    private static func parseUnderHundred(_ word: String, allowArticleOne: Bool) -> Int? {
        if let direct = directValue(word, allowArticleOne: allowArticleOne) {
            return direct
        }

        var searchRange = word.startIndex..<word.endIndex
        while let range = word.range(of: "en", range: searchRange) {
            let prefix = String(word[..<range.lowerBound])
            let suffix = String(word[range.upperBound...])
            if let unit = unitValue(prefix, allowArticleOne: true),
               unit > 0,
               let ten = tensValues[suffix] {
                return unit + ten
            }
            searchRange = range.upperBound..<word.endIndex
        }

        return nil
    }

    private static func compoundSuffixValue(_ suffix: String) -> Int? {
        guard !suffix.isEmpty else { return 0 }

        if suffix.hasPrefix("en") {
            let remainder = String(suffix.dropFirst(2))
            guard let value = parseCompound(remainder, allowArticleOne: true),
                  value <= 12 else {
                return nil
            }
            return value
        }

        return parseCompound(suffix, allowArticleOne: true)
    }

    private static func parseOptionalAndRemainder(
        _ words: [String],
        startingAt startIndex: Int,
        current: Int,
        total: Int
    ) -> (value: Int, nextIndex: Int)? {
        guard current > 0 || total > 0,
              startIndex + 1 < words.count,
              let remainder = parseSegment(words, startingAt: startIndex + 1, allowArticleOne: true),
              remainder.value <= 12 else {
            return nil
        }
        return remainder
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

    private static func directValue(_ word: String, allowArticleOne: Bool) -> Int? {
        if let unit = unitValue(word, allowArticleOne: allowArticleOne) {
            return unit
        }
        return teenValues[word] ?? tensValues[word]
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
        return ["honderd", "duizend", "miljoen", "miljoenen", "komma"].contains(words[index + 1])
    }

    private static func startsWithOneDecimal(at index: Int, in words: [String]) -> Bool {
        index + 1 < words.count && words[index] == "een" && words[index + 1] == "komma"
    }

    private static func normalizeWord(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "nl_NL"))
            .lowercased()
    }
}
