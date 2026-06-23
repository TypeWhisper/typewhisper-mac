import Foundation

enum GermanNumberWordParser {
    private static let units: [String: Int] = [
        "null": 0, "eins": 1, "ein": 1, "eine": 1, "einen": 1, "einem": 1, "einer": 1,
        "zwei": 2, "drei": 3, "vier": 4, "funf": 5, "fuenf": 5,
        "sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
    ]

    private static let teens: [String: Int] = [
        "zehn": 10, "elf": 11, "zwolf": 12, "zwoelf": 12, "dreizehn": 13, "vierzehn": 14,
        "funfzehn": 15, "fuenfzehn": 15, "sechzehn": 16, "siebzehn": 17,
        "achtzehn": 18, "neunzehn": 19,
    ]

    // Include common ASR spelling variants for spoken-number cleanup.
    private static let tens: [String: Int] = [
        "zwanzig": 20, "dreissig": 30, "dreizig": 30, "vierzig": 40,
        "funfzig": 50, "fuenfzig": 50, "sechzig": 60, "siebzig": 70,
        "achtzig": 80, "neunzig": 90,
    ]

    static func parse(_ words: [String]) -> NumberWordNormalizer.ParsedWords? {
        guard !words.isEmpty else { return nil }
        let normalizedWords = words.map(normalizeWord)
        var index = 0
        var isNegative = false

        if normalizedWords[index] == "minus" {
            isNegative = true
            index += 1
            guard index < normalizedWords.count else { return nil }
        }

        guard let integer = parseInteger(normalizedWords, startingAt: index) else { return nil }
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

    private static func parseInteger(_ words: [String], startingAt startIndex: Int) -> (value: Int, nextIndex: Int)? {
        guard startIndex < words.count else { return nil }
        var total = 0
        var current = 0
        var index = startIndex
        var consumed = false
        var lastWasPlainSmallNumber = false

        while index < words.count {
            let word = words[index]

            if word == "und",
               current > 0,
               current < 10,
               index + 1 < words.count,
               let tenValue = tens[words[index + 1]] {
                current += tenValue
                index += 2
                consumed = true
                lastWasPlainSmallNumber = false
                continue
            }

            if word == "hundert" {
                current = max(current, 1) * 100
                index += 1
                consumed = true
                lastWasPlainSmallNumber = false
                continue
            }

            if ["tausend", "million", "millionen"].contains(word) {
                let scale = word == "tausend" ? 1_000 : 1_000_000
                total += max(current, 1) * scale
                current = 0
                index += 1
                consumed = true
                lastWasPlainSmallNumber = false
                continue
            }

            let allowsArticleOne = allowsArticleOne(at: index, in: words)
            guard let value = parseCompound(word, allowArticleOne: allowsArticleOne) else { break }

            if lastWasPlainSmallNumber, value < 10 {
                break
            }

            current += value
            index += 1
            consumed = true
            lastWasPlainSmallNumber = value < 10 && !allowsArticleOne
        }

        guard consumed else { return nil }
        return (total + current, index)
    }

    private static func parseDecimalDigits(_ words: [String], startingAt startIndex: Int) -> (digits: String, nextIndex: Int) {
        var digits = ""
        var index = startIndex

        while index < words.count, let digit = digitValue(words[index]) {
            digits += "\(digit)"
            index += 1
        }

        return (digits, index)
    }

    private static func parseCompound(_ word: String, allowArticleOne: Bool) -> Int? {
        if let direct = directValue(word, allowArticleOne: allowArticleOne) {
            return direct
        }

        if let range = word.range(of: "tausend") {
            let prefix = String(word[..<range.lowerBound])
            let suffix = String(word[range.upperBound...])
            let prefixValue = prefix.isEmpty ? 1 : parseCompound(prefix, allowArticleOne: true)
            guard let prefixValue else { return nil }
            let suffixValue = suffix.isEmpty ? 0 : parseCompound(suffix, allowArticleOne: true)
            guard let suffixValue else { return nil }
            return prefixValue * 1_000 + suffixValue
        }

        if let range = word.range(of: "hundert") {
            let prefix = String(word[..<range.lowerBound])
            let suffix = String(word[range.upperBound...])
            let prefixValue = prefix.isEmpty ? 1 : parseUnderHundred(prefix, allowArticleOne: true)
            guard let prefixValue else { return nil }
            let suffixValue = suffix.isEmpty ? 0 : parseUnderHundred(suffix, allowArticleOne: true)
            guard let suffixValue else { return nil }
            return prefixValue * 100 + suffixValue
        }

        return parseUnderHundred(word, allowArticleOne: allowArticleOne)
    }

    private static func parseUnderHundred(_ word: String, allowArticleOne: Bool) -> Int? {
        if let direct = directValue(word, allowArticleOne: allowArticleOne) {
            return direct
        }

        if let range = word.range(of: "und") {
            let prefix = String(word[..<range.lowerBound])
            let suffix = String(word[range.upperBound...])
            guard let unit = directUnitValue(prefix, allowArticleOne: true),
                  unit > 0,
                  unit < 10,
                  let tenValue = tens[suffix] else {
                return nil
            }
            return unit + tenValue
        }

        return nil
    }

    private static func directValue(_ word: String, allowArticleOne: Bool) -> Int? {
        if let unit = directUnitValue(word, allowArticleOne: allowArticleOne) {
            return unit
        }
        return teens[word] ?? tens[word]
    }

    private static func directUnitValue(_ word: String, allowArticleOne: Bool) -> Int? {
        guard let value = units[word] else { return nil }
        if value == 1, word != "eins", !allowArticleOne {
            return nil
        }
        return value
    }

    private static func digitValue(_ word: String) -> Int? {
        directUnitValue(word, allowArticleOne: false)
    }

    private static func allowsArticleOne(at index: Int, in words: [String]) -> Bool {
        guard index + 1 < words.count else { return false }
        return ["hundert", "tausend", "million", "millionen"].contains(words[index + 1])
    }

    private static func normalizeWord(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .replacingOccurrences(of: "ß", with: "ss")
    }
}
