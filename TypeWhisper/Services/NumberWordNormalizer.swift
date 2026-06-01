import Foundation

enum NumberWordNormalizer {
    private static let supportedLanguageCodes: Set<String> = ["en", "de", "fr", "es", "zh", "ja"]
    private static let cjkNumberCharacters = Set("零〇一二两兩三四五六七八九十百千万萬亿億点點負负".map { $0 })

    static func normalize(text: String, language: String?) -> String {
        guard let languageCode = PunctuationLanguageNormalizer.normalize(language),
              supportedLanguageCodes.contains(languageCode),
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

    struct ParsedWords {
        let value: String
        let consumedWords: Int
    }

    private enum TokenKind {
        case word
        case cjkNumber
        case other

        var isWord: Bool {
            switch self {
            case .word, .cjkNumber:
                return true
            case .other:
                return false
            }
        }
    }

    private struct Token {
        let text: String
        let kind: TokenKind

        var isWord: Bool { kind.isWord }
    }

    private struct ParsedNumber {
        let replacement: String
        let endIndex: Int
    }

    private struct WordCandidate {
        let tokenIndex: Int
        let text: String
    }

    private static func parseNumber(startingAt index: Int, in tokens: [Token], languageCode: String) -> ParsedNumber? {
        let words = wordCandidates(startingAt: index, in: tokens)
        guard !words.isEmpty else { return nil }

        let wordTexts = words.map(\.text)
        let parsed: ParsedWords?
        switch languageCode {
        case "en":
            parsed = EnglishNumberWordParser.parse(wordTexts)
        case "de":
            parsed = GermanNumberWordParser.parse(wordTexts)
        case "fr":
            parsed = FrenchNumberWordParser.parse(wordTexts)
        case "es":
            parsed = SpanishNumberWordParser.parse(wordTexts)
        case "zh":
            parsed = ChineseNumberWordParser.parse(wordTexts)
        case "ja":
            parsed = JapaneseNumberWordParser.parse(wordTexts)
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

        return tokens
    }

    private static func tokenKind(for character: Character) -> TokenKind {
        if cjkNumberCharacters.contains(character) {
            return .cjkNumber
        }

        if isWordCharacter(character) {
            return .word
        }

        return .other
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
