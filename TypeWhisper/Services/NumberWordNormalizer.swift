import Foundation

enum NumberWordNormalizer {
    static func normalize(text: String, language: String?) -> String {
        guard let languageCode = PunctuationLanguageNormalizer.normalize(language),
              ["en", "de"].contains(languageCode),
              !text.isEmpty else {
            return text
        }

        let tokens = tokenize(text)
        guard tokens.contains(where: \.isWord) else { return text }

        var result = ""
        var index = 0
        while index < tokens.count {
            if tokens[index].isWord,
               let parsed = parseNumber(startingAt: index, in: tokens, languageCode: languageCode) {
                result.append(parsed.replacement)
                index = parsed.endIndex
            } else {
                result.append(tokens[index].text)
                index += 1
            }
        }

        return result
    }

    private struct Token {
        let text: String
        let isWord: Bool
    }

    private struct ParsedNumber {
        let replacement: String
        let endIndex: Int
    }

    private struct WordCandidate {
        let tokenIndex: Int
        let text: String
    }

    fileprivate struct ParsedWords {
        let value: String
        let consumedWords: Int
    }

    private static func parseNumber(startingAt index: Int, in tokens: [Token], languageCode: String) -> ParsedNumber? {
        let words = wordCandidates(startingAt: index, in: tokens)
        guard !words.isEmpty else { return nil }

        let parsed: ParsedWords?
        switch languageCode {
        case "en":
            parsed = EnglishNumberParser.parse(words.map(\.text))
        case "de":
            parsed = GermanNumberParser.parse(words.map(\.text))
        default:
            parsed = nil
        }

        guard let parsed, parsed.consumedWords > 0, parsed.consumedWords <= words.count else {
            return nil
        }

        let finalTokenIndex = words[parsed.consumedWords - 1].tokenIndex
        return ParsedNumber(replacement: parsed.value, endIndex: finalTokenIndex + 1)
    }

    private static func wordCandidates(startingAt index: Int, in tokens: [Token]) -> [WordCandidate] {
        var words: [WordCandidate] = []
        var current = index

        while current < tokens.count, tokens[current].isWord {
            words.append(WordCandidate(tokenIndex: current, text: tokens[current].text))

            let separatorIndex = current + 1
            let nextWordIndex = current + 2
            guard separatorIndex < tokens.count,
                  nextWordIndex < tokens.count,
                  tokens[nextWordIndex].isWord,
                  isWordConnector(tokens[separatorIndex].text) else {
                break
            }

            current = nextWordIndex
        }

        return words
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord: Bool?

        for character in text {
            let isWord = isWordCharacter(character)
            if currentIsWord == isWord {
                current.append(character)
            } else {
                if !current.isEmpty, let currentIsWord {
                    tokens.append(Token(text: current, isWord: currentIsWord))
                }
                current = String(character)
                currentIsWord = isWord
            }
        }

        if !current.isEmpty, let currentIsWord {
            tokens.append(Token(text: current, isWord: currentIsWord))
        }

        return tokens
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    private static func isWordConnector(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "-" || scalar == "\u{2011}"
        }
    }
}

private enum EnglishNumberParser {
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

private enum GermanNumberParser {
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
