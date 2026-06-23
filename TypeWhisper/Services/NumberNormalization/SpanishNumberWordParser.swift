import Foundation

enum SpanishNumberWordParser {
    private static let unitValues: [String: Int] = [
        "cero": 0, "uno": 1, "un": 1, "una": 1, "dos": 2, "tres": 3,
        "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9,
    ]

    private static let teenValues: [String: Int] = [
        "diez": 10, "once": 11, "doce": 12, "trece": 13, "catorce": 14,
        "quince": 15, "dieciseis": 16, "diecisiete": 17, "dieciocho": 18, "diecinueve": 19,
    ]

    private static let twentyValues: [String: Int] = [
        "veinte": 20, "veintiuno": 21, "veintiun": 21, "veintiuna": 21,
        "veintidos": 22, "veintitres": 23, "veinticuatro": 24, "veinticinco": 25,
        "veintiseis": 26, "veintisiete": 27, "veintiocho": 28, "veintinueve": 29,
    ]

    private static let tensValues: [String: Int] = [
        "treinta": 30, "cuarenta": 40, "cincuenta": 50,
        "sesenta": 60, "setenta": 70, "ochenta": 80, "noventa": 90,
    ]

    private static let hundredValues: [String: Int] = [
        "cien": 100, "ciento": 100, "doscientos": 200, "doscientas": 200,
        "trescientos": 300, "trescientas": 300, "cuatrocientos": 400, "cuatrocientas": 400,
        "quinientos": 500, "quinientas": 500, "seiscientos": 600, "seiscientas": 600,
        "setecientos": 700, "setecientas": 700, "ochocientos": 800, "ochocientas": 800,
        "novecientos": 900, "novecientas": 900,
    ]

    static func parse(_ words: [String]) -> NumberWordNormalizer.ParsedWords? {
        guard !words.isEmpty else { return nil }
        let normalizedWords = words.map(normalizeWord)
        var index = 0
        var isNegative = false

        if normalizedWords[index] == "menos" {
            isNegative = true
            index += 1
            guard index < normalizedWords.count else { return nil }
        }

        guard let integer = parseInteger(normalizedWords, startingAt: index, allowLeadingArticleOne: isNegative) else {
            return nil
        }
        index = integer.nextIndex
        var replacement = "\(integer.value)"

        if index < normalizedWords.count, normalizedWords[index] == "coma" {
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

            if ["millon", "millones"].contains(word) {
                total += max(current, 1) * 1_000_000
                current = 0
                index += 1
                consumed = true
                lastWasPlainSmallNumber = false
                continue
            }

            if word == "mil" {
                total += max(current, 1) * 1_000
                current = 0
                index += 1
                consumed = true
                lastWasPlainSmallNumber = false
                continue
            }

            if let hundred = hundredValues[word] {
                current += hundred
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

        if word == "veinte" {
            // Keep ASR tolerance for split "veintiuno" forms like "veinte uno".
            return appendSpanishUnit(base: 20, words: words, startingAt: startIndex + 1, allowWithoutY: true)
        }

        if let twenty = twentyValues[word] {
            return (twenty, startIndex + 1)
        }

        if let ten = tensValues[word] {
            return appendSpanishUnit(base: ten, words: words, startingAt: startIndex + 1, allowWithoutY: false)
        }

        if let teen = teenValues[word] {
            return (teen, startIndex + 1)
        }

        if let unit = unitValue(word, allowArticleOne: allowArticleOne) {
            return (unit, startIndex + 1)
        }

        return nil
    }

    private static func appendSpanishUnit(
        base: Int,
        words: [String],
        startingAt startIndex: Int,
        allowWithoutY: Bool
    ) -> (value: Int, nextIndex: Int) {
        let index = startIndex

        if index < words.count, words[index] == "y" {
            let afterY = index + 1
            if afterY < words.count,
               let unit = unitValue(words[afterY], allowArticleOne: true),
               unit > 0 {
                return (base + unit, afterY + 1)
            }
            return (base, startIndex)
        }

        if allowWithoutY,
           index < words.count,
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
        return ["mil", "millon", "millones"].contains(words[index + 1])
    }

    private static func normalizeWord(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
            .lowercased()
    }
}
