import Foundation

enum NumberWordNormalizer {
    private static let supportedLanguageCodes: Set<String> = ["en", "de", "fr", "es", "nl", "pl", "zh", "ja"]

    /// Ordinary words in a language that another language's parser reads as a number,
    /// such as Polish `ten` ("this") and `one` ("they") for English.
    private static let ordinaryWordsByLanguage: [String: Set<String>] = [
        "pl": ["ten", "one"],
    ]
    private static let hanLexicalNumberWords: Set<String> = [
        "萬能", "万能", "萬一", "万一", "萬分", "万分",
        "百般", "百姓",
    ]
    private static let hanApproximationPrefixes: Set<Character> = [
        "幾", "几", "數", "数", "上", "成",
    ]
    private static let hanUnitCharacters: Set<Character> = [
        "十", "百", "千", "万", "萬", "亿", "億",
    ]
    private static let hanFractionalDigitCharacters: Set<Character> = [
        "零", "〇", "一", "二", "两", "兩", "三", "四", "五", "六", "七", "八", "九",
    ]
    private static let cjkNumberCharacters = Set("零〇一二两兩三四五六七八九十百千万萬亿億点點負负".map { $0 })

    static func supports(language: String?) -> Bool {
        guard let languageCode = PunctuationLanguageNormalizer.normalize(language) else { return false }
        return supportedLanguageCodes.contains(languageCode)
    }

    static func ordinaryWords(forLanguage language: String?) -> Set<String> {
        guard let languageCode = PunctuationLanguageNormalizer.normalize(language) else { return [] }
        return ordinaryWordsByLanguage[languageCode] ?? []
    }

    /// - Parameter preservedStandaloneWords: Lowercased words that stay unchanged when they
    ///   form a number on their own. Longer expressions that contain them still convert.
    static func normalize(
        text: String,
        language: String?,
        minimumValue: Int = 0,
        preservedStandaloneWords: Set<String> = []
    ) -> String {
        guard let languageCode = PunctuationLanguageNormalizer.normalize(language),
              supportedLanguageCodes.contains(languageCode),
              !text.isEmpty else {
            return text
        }

        let tokens = tokenize(text)
        guard tokens.contains(where: \.isWord) else { return text }

        let wordParser = latinWordParser(for: languageCode)
        // A number candidate runs from a word to the next punctuation, so every word
        // takes part in many candidates. Each word is normalized only once per call.
        var normalizedWords = [String?](repeating: nil, count: tokens.count)
        var result = ""
        var index = 0
        while index < tokens.count {
            if let decimal = parseDigitDecimal(startingAt: index, in: tokens, languageCode: languageCode) {
                result.append(decimal.replacement)
                index = decimal.endIndex
            } else if tokens[index].isWord,
               let parsed = parseNumber(
                   startingAt: index,
                   in: tokens,
                   languageCode: languageCode,
                   wordParser: wordParser,
                   normalizedWords: &normalizedWords
               ) {
                let isPreservedWord = parsed.endIndex == index + 1
                    && preservedStandaloneWords.contains(tokens[index].text.lowercased())
                if !isPreservedWord, parsed.words.shouldNormalize(minimumValue: minimumValue) {
                    result.append(parsed.words.value)
                } else {
                    // Consume the entire expression even when keeping its original spelling.
                    result.append(contentsOf: tokens[index..<parsed.endIndex].map(\.text).joined())
                }
                index = parsed.endIndex
            } else {
                result.append(tokens[index].text)
                index += 1
            }
        }

        return result
    }

    struct ParsedWords {
        enum Kind {
            case number
            case decimal
            case digitSequence
        }

        let value: String
        let consumedWords: Int
        let kind: Kind

        init(value: String, consumedWords: Int, kind: Kind = .number) {
            self.value = value
            self.consumedWords = consumedWords
            self.kind = kind
        }

        func shouldNormalize(minimumValue: Int) -> Bool {
            guard minimumValue > 0, kind == .number else { return true }
            // Parsers emit ASCII digits, optionally signed and with an ordinal suffix.
            let magnitude = value.drop(while: { $0 == "-" }).prefix(while: { $0.isASCII && $0.isNumber })
            guard let number = UInt64(magnitude) else { return false }
            return number >= UInt64(minimumValue)
        }
    }

    private enum TokenKind {
        case word
        case digit
        case cjkNumber
        case other

        var isWord: Bool {
            switch self {
            case .word, .cjkNumber:
                return true
            case .digit, .other:
                return false
            }
        }

        var isDigit: Bool {
            switch self {
            case .digit:
                return true
            case .word, .cjkNumber, .other:
                return false
            }
        }
    }

    private struct Token {
        let text: String
        let kind: TokenKind

        var isWord: Bool { kind.isWord }
        var isDigit: Bool { kind.isDigit }
    }

    private struct ParsedNumber {
        let words: ParsedWords
        let endIndex: Int

        var replacement: String { words.value }
    }

    private struct WordCandidate {
        let tokenIndex: Int
        let text: String
    }

    private static func parseDigitDecimal(startingAt index: Int, in tokens: [Token], languageCode: String) -> ParsedNumber? {
        guard let decimalSeparator = digitDecimalSeparator(for: languageCode),
              index + 4 < tokens.count,
              tokens[index].isDigit,
              isWordConnector(tokens[index + 1].text),
              tokens[index + 2].isWord,
              normalizedDecimalWord(tokens[index + 2].text, languageCode: languageCode) == "point",
              isWordConnector(tokens[index + 3].text),
              tokens[index + 4].isDigit else {
            return nil
        }

        return ParsedNumber(
            words: ParsedWords(
                value: tokens[index].text + decimalSeparator + tokens[index + 4].text,
                consumedWords: 1,
                kind: .decimal
            ),
            endIndex: index + 5
        )
    }

    private static func digitDecimalSeparator(for languageCode: String) -> String? {
        switch languageCode {
        case "fr":
            return "."
        default:
            return nil
        }
    }

    private static func normalizedDecimalWord(_ word: String, languageCode: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: languageCode))
            .lowercased()
    }

    /// A Latin-script parser and the word normalization it expects.
    private struct LatinWordParser {
        let normalizeWord: (String) -> String
        let parse: ([String]) -> ParsedWords?
    }

    private static func latinWordParser(for languageCode: String) -> LatinWordParser? {
        switch languageCode {
        case "en":
            LatinWordParser(
                normalizeWord: EnglishNumberWordParser.normalizeWord,
                parse: EnglishNumberWordParser.parse(normalizedWords:)
            )
        case "de":
            LatinWordParser(
                normalizeWord: GermanNumberWordParser.normalizeWord,
                parse: GermanNumberWordParser.parse(normalizedWords:)
            )
        case "fr":
            LatinWordParser(
                normalizeWord: FrenchNumberWordParser.normalizeWord,
                parse: FrenchNumberWordParser.parse(normalizedWords:)
            )
        case "es":
            LatinWordParser(
                normalizeWord: SpanishNumberWordParser.normalizeWord,
                parse: SpanishNumberWordParser.parse(normalizedWords:)
            )
        case "nl":
            LatinWordParser(
                normalizeWord: DutchNumberWordParser.normalizeWord,
                parse: DutchNumberWordParser.parse(normalizedWords:)
            )
        case "pl":
            LatinWordParser(
                normalizeWord: PolishNumberWordParser.normalizeWord,
                parse: PolishNumberWordParser.parse(normalizedWords:)
            )
        default:
            nil
        }
    }

    private static func parseNumber(
        startingAt index: Int,
        in tokens: [Token],
        languageCode: String,
        wordParser: LatinWordParser?,
        normalizedWords: inout [String?]
    ) -> ParsedNumber? {
        let words = wordCandidates(startingAt: index, in: tokens)
        guard !words.isEmpty else { return nil }

        let parsed: ParsedWords?
        if let wordParser {
            let normalized = words.map { word in
                if let cached = normalizedWords[word.tokenIndex] { return cached }
                let normalizedWord = wordParser.normalizeWord(word.text)
                normalizedWords[word.tokenIndex] = normalizedWord
                return normalizedWord
            }
            parsed = wordParser.parse(normalized)
        } else {
            let wordTexts = words.map(\.text)
            if languageCode == "zh" || languageCode == "ja" {
                if isHanLexicalNumberWord(startingAt: index, text: wordTexts[0], in: tokens) {
                    return nil
                }
                if index > 1,
                   tokens[index - 1].kind == .other,
                   tokens[index - 1].text == ".",
                   tokens[index - 2].kind == .digit,
                   isHanDecimalFractionStart(wordTexts[0]) {
                    // A merged numeric run directly preceded by "<digits>."
                    // belongs to a decimal fraction when it starts with a
                    // fractional digit (1.5万, 1.五万, 2.3亿), not to the
                    // large unit. Unit-first text such as 1.十个人 can be an
                    // ordinary numbered-list item instead. The Han parsers
                    // cannot represent fractional unit scaling yet, so leave
                    // decimal text unchanged rather than producing a
                    // plausible-looking wrong value such as 1.50000元.
                    return nil
                }
            }
            switch languageCode {
            case "zh":
                parsed = ChineseNumberWordParser.parse(wordTexts)
            case "ja":
                parsed = JapaneseNumberWordParser.parse(wordTexts)
            default:
                parsed = nil
            }
        }

        guard let parsed, parsed.consumedWords > 0, parsed.consumedWords <= words.count else {
            return nil
        }

        let finalTokenIndex = words[parsed.consumedWords - 1].tokenIndex
        return ParsedNumber(words: parsed, endIndex: finalTokenIndex + 1)
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
        var currentKind: TokenKind?

        for character in text {
            let kind = tokenKind(for: character)
            if currentKind == kind {
                current.append(character)
            } else {
                if !current.isEmpty, let currentKind {
                    tokens.append(Token(text: current, kind: currentKind))
                }
                current = String(character)
                currentKind = kind
            }
        }

        if !current.isEmpty, let currentKind {
            tokens.append(Token(text: current, kind: currentKind))
        }

        return mergingAdjacentNumericRuns(tokens)
    }

    private static func mergingAdjacentNumericRuns(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var index = 0

        while index < tokens.count {
            guard tokens[index].kind == .digit || tokens[index].kind == .cjkNumber else {
                result.append(tokens[index])
                index += 1
                continue
            }

            var endIndex = index
            var text = ""
            var containsCJKNumber = false
            var stoppedAtLexicalWord = false
            while endIndex < tokens.count,
                  (tokens[endIndex].kind == .digit || tokens[endIndex].kind == .cjkNumber) {
                if tokens[endIndex].kind == .digit,
                   !text.isEmpty,
                   let lexical = hanLexicalNumberWords.first(where: { text.hasSuffix($0) }) {
                    // A digit run must not merge into a lexical word: in
                    // 万一5个人都来了 the 万一 is "in case", not a number.
                    // Mixed numbers such as 1万5 keep merging because 万
                    // alone is never lexical. Merging resumes after the
                    // protected word so later numerals still combine.
                    if text.count > lexical.count {
                        let numberPart = String(text.dropLast(lexical.count))
                        result.append(Token(text: numberPart, kind: .cjkNumber))
                    }
                    result.append(Token(text: lexical, kind: .cjkNumber))
                    index = endIndex
                    stoppedAtLexicalWord = true
                    break
                }
                text += tokens[endIndex].text
                containsCJKNumber = containsCJKNumber || tokens[endIndex].kind == .cjkNumber
                endIndex += 1
            }

            if stoppedAtLexicalWord {
                // The loop above stopped at a protected lexical word and
                // already emitted it; continue merging at the digit run.
                continue
            }

            if containsCJKNumber {
                result.append(Token(text: text, kind: .cjkNumber))
            } else {
                result.append(contentsOf: tokens[index..<endIndex])
            }
            index = endIndex
        }

        return result
    }

    private static func isHanLexicalNumberWord(
        startingAt index: Int,
        text: String,
        in tokens: [Token]
    ) -> Bool {
        if hanLexicalNumberWords.contains(text) {
            return true
        }

        if index > 0,
           tokens[index - 1].kind == .word,
           let left = tokens[index - 1].text.last {
            // Approximations attach the prefix directly to bare units
            // (幾千, 數百, 成千上萬). Count-label suffixes such as 总数, 人数
            // and 訂單數 end in the same character, so only treat the prefix
            // as approximating when the number itself contains no digit, e.g.
            // keep 數百 intact but still normalize 总数一百 to 总数100.
            // 上 and 成 only approximate with 百, 千 and 万 (上百, 上千,
            // 上万, 成千上万); before 十 they end ordinary words such as
            // 完成十项 and 楼上十个, which still normalize.
            if hanApproximationPrefixes.contains(left),
               isBareHanUnitRun(text),
               !(text.first == "十" && (left == "上" || left == "成")) {
                return true
            }
            if hanLexicalNumberWords.contains(String(left) + text) {
                return true
            }
        }

        if index + 1 < tokens.count,
           tokens[index + 1].kind == .word,
           let right = tokens[index + 1].text.first,
           hanLexicalNumberWords.contains(text + String(right)) {
            return true
        }

        return false
    }

    private static func isHanDecimalFractionStart(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return (first.isASCII && first.isNumber) || hanFractionalDigitCharacters.contains(first)
    }

    private static func isBareHanUnitRun(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { hanUnitCharacters.contains($0) }
    }

    private static func tokenKind(for character: Character) -> TokenKind {
        if cjkNumberCharacters.contains(character) {
            return .cjkNumber
        }

        if isDigitCharacter(character) {
            return .digit
        }

        if isWordCharacter(character) {
            return .word
        }

        return .other
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    private static func isDigitCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private static func isWordConnector(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "-" || scalar == "\u{2011}"
        }
    }
}
