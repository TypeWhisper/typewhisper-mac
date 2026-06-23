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
            let updated = replaceWholePhrase(
                rule.phrase,
                with: rule.replacement,
                category: rule.category,
                in: result
            )
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

    private func replaceWholePhrase(
        _ phrase: String,
        with replacement: String,
        category: PunctuationRuleCategory,
        in text: String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: wholePhrasePattern(for: phrase, category: category),
            options: [.caseInsensitive]
        ) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else {
            return text
        }

        var result = text
        for match in matches.reversed() {
            guard let originalMatchRange = Range(match.range, in: text) else { continue }
            guard let matchRange = Range(match.range, in: result) else { continue }
            let effectiveReplacement: String

            if shouldSuppressDuplicateReplacement(
                in: text,
                range: originalMatchRange,
                replacement: replacement,
                category: category
            ) {
                effectiveReplacement = ""
            } else {
                effectiveReplacement = replacement
            }

            result.replaceSubrange(matchRange, with: effectiveReplacement)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wholePhrasePattern(for phrase: String, category: PunctuationRuleCategory) -> String {
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
        let unspacedTokens = CharacterSet(charactersIn: "、。？！：；（）［］｛｝「」『』【】〈〉《》")
        let unspacedOpeningTokens = CharacterSet(charactersIn: "（［｛「『【〈《")

        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character.isWhitespace {
                let nextIndex = text.index(after: index)
                let nextCharacter = nextIndex < text.endIndex ? text[nextIndex] : nil
                let followingNonWhitespace = nextNonWhitespaceCharacter(in: text, after: index)

                if let previous = result.last,
                   behavior(for: previous, opening: openingTokens, closing: closingTokens, inline: inlineTokens) == .opening {
                    index = nextIndex
                    continue
                }

                if let previous = result.last,
                   isMember(previous, of: unspacedTokens),
                   shouldRemoveSpaceAfterUnspacedToken(
                    previous,
                    next: followingNonWhitespace,
                    openingTokens: unspacedOpeningTokens
                   ) {
                    index = nextIndex
                    continue
                }

                if let followingNonWhitespace,
                   isMember(followingNonWhitespace, of: unspacedTokens) {
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

    private func isMember(_ character: Character, of characterSet: CharacterSet) -> Bool {
        character.unicodeScalars.allSatisfy { characterSet.contains($0) }
    }

    private func shouldRemoveSpaceAfterUnspacedToken(
        _ previous: Character,
        next: Character?,
        openingTokens: CharacterSet
    ) -> Bool {
        if isMember(previous, of: openingTokens) {
            return true
        }

        guard let next else {
            return true
        }

        return isUnspacedScript(next)
    }

    private func isUnspacedScript(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana and Katakana
                 0x3400...0x9FFF, // CJK ideographs
                 0x20000...0x2A6DF, // CJK extension B
                 0x2A700...0x2B73F, // CJK extension C
                 0x2B740...0x2B81F, // CJK extension D
                 0x2B820...0x2CEAF, // CJK extension E-F
                 0x2CEB0...0x2EBEF, // CJK extension F-I
                 0x30000...0x323AF, // CJK extension G-H
                 0xF900...0xFAFF, // CJK compatibility ideographs
                 0xFF00...0xFFEF: // Halfwidth and fullwidth forms
                return true
            default:
                return false
            }
        }
    }

    private func shouldSuppressDuplicateReplacement(
        in text: String,
        range: Range<String.Index>,
        replacement: String,
        category: PunctuationRuleCategory
    ) -> Bool {
        guard category == .punctuation,
              replacement.count == 1,
              let replacementCharacter = replacement.first else {
            return false
        }

        return isDuplicatePunctuation(
            previousNonWhitespaceCharacter(in: text, before: range.lowerBound),
            replacement: replacementCharacter
        ) || isDuplicatePunctuation(
            nextNonWhitespaceCharacter(in: text, after: range.upperBound),
            replacement: replacementCharacter
        )
    }

    private func isDuplicatePunctuation(_ candidate: Character?, replacement: Character) -> Bool {
        guard let candidate else { return false }
        return canonicalPunctuationCharacter(candidate) == canonicalPunctuationCharacter(replacement)
    }

    private func canonicalPunctuationCharacter(_ character: Character) -> Character {
        switch character {
        case "。": "."
        case "、": ","
        case "？": "?"
        case "！": "!"
        case "：": ":"
        case "；": ";"
        default: character
        }
    }

    private func previousNonWhitespaceCharacter(
        in text: String,
        before index: String.Index
    ) -> Character? {
        var current = index
        while current > text.startIndex {
            let previous = text.index(before: current)
            let character = text[previous]
            if !character.isWhitespace {
                return character
            }
            current = previous
        }
        return nil
    }

    private func nextNonWhitespaceCharacter(
        in text: String,
        after index: String.Index
    ) -> Character? {
        var current = index
        while current < text.endIndex {
            let character = text[current]
            if !character.isWhitespace {
                return character
            }
            current = text.index(after: current)
        }
        return nil
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
