import Foundation

enum PunctuationApplicationMode {
    case selectiveFallback
    case fullFallback
}

@MainActor
final class SpeechPunctuationService {
    private let rulesLoader: PunctuationRulesLoader

    init(rulesLoader: PunctuationRulesLoader = PunctuationRulesLoader()) {
        self.rulesLoader = rulesLoader
    }

    func normalize(
        text: String,
        language: String?,
        mode: PunctuationApplicationMode = .fullFallback
    ) -> String {
        guard !text.isEmpty,
              let ruleSet = rulesLoader.ruleSet(for: language) else {
            return text
        }

        var result = text
        var replacementApplied = false

        for rule in ruleSet.rules.sorted(by: { $0.phrase.count > $1.phrase.count }) {
            let updated = replaceWholePhrase(rule.phrase, with: rule.replacement, in: result)
            if updated != result {
                replacementApplied = true
                result = updated
            }
        }

        switch mode {
        case .selectiveFallback where !replacementApplied:
            return text
        default:
            return normalizeSpacing(in: result)
        }
    }

    private func replaceWholePhrase(_ phrase: String, with replacement: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: wholePhrasePattern(for: phrase),
            options: [.caseInsensitive]
        ) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private func wholePhrasePattern(for phrase: String) -> String {
        let escapedWords = phrase
            .split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
        return #"(?<![\p{L}\p{N}])\#(escapedWords)(?![\p{L}\p{N}])"#
    }

    private func normalizeSpacing(in text: String) -> String {
        let openingTokens = CharacterSet(charactersIn: "([{")
        let closingTokens = CharacterSet(charactersIn: ")]}")
        let inlineTokens = CharacterSet(charactersIn: ",.:;?!")

        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character.isWhitespace {
                let nextIndex = text.index(after: index)
                let nextCharacter = nextIndex < text.endIndex ? text[nextIndex] : nil

                if let previous = result.last,
                   behavior(for: previous, opening: openingTokens, closing: closingTokens, inline: inlineTokens) == .opening {
                    index = nextIndex
                    continue
                }

                if let nextCharacter,
                   let nextBehavior = behavior(for: nextCharacter, opening: openingTokens, closing: closingTokens, inline: inlineTokens) {
                    if nextBehavior == .opening, !result.isEmpty, !result.last!.isWhitespace {
                        result.append(" ")
                    }
                    index = nextIndex
                    continue
                }

                if !result.isEmpty, !result.last!.isWhitespace {
                    result.append(" ")
                }
                index = nextIndex
                continue
            }

            if let behavior = behavior(for: character, opening: openingTokens, closing: closingTokens, inline: inlineTokens) {
                if behavior == .closing || behavior == .inline {
                    while result.last == " " {
                        result.removeLast()
                    }
                }

                result.append(character)
                index = text.index(after: index)
                continue
            }

            result.append(character)
            index = text.index(after: index)
        }

        return result
    }

    private enum TokenBehavior {
        case opening
        case closing
        case inline
    }

    private func behavior(
        for character: Character,
        opening: CharacterSet,
        closing: CharacterSet,
        inline: CharacterSet
    ) -> TokenBehavior? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return nil
        }
        if opening.contains(scalar) { return .opening }
        if closing.contains(scalar) { return .closing }
        if inline.contains(scalar) { return .inline }
        return nil
    }
}
