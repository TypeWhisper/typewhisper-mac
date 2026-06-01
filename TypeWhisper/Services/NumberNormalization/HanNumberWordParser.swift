import Foundation

enum HanNumberWordParser {
    private static let digitValues: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3,
        "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]

    private static let unitValues: [Character: Int] = [
        "十": 10, "百": 100, "千": 1_000,
    ]

    private static let largeUnitValues: [Character: Int] = [
        "万": 10_000, "萬": 10_000, "亿": 100_000_000, "億": 100_000_000,
    ]

    private static let decimalMarkers: Set<Character> = ["点", "點"]
    private static let negativeMarkers: Set<Character> = ["负", "負"]

    static func parse(_ words: [String]) -> NumberWordNormalizer.ParsedWords? {
        guard !words.isEmpty else { return nil }

        var consumedWords = 0
        var pieces: [String] = []

        if words[0] == "マイナス" {
            pieces.append("負")
            consumedWords = 1
        }

        while consumedWords < words.count, isHanNumberWord(words[consumedWords]) {
            pieces.append(words[consumedWords])
            consumedWords += 1
        }

        guard !pieces.isEmpty else { return nil }

        let numberText = pieces.joined()
        guard containsNumberMarker(numberText) else { return nil }
        guard let parsed = parseNumberText(numberText) else { return nil }
        return NumberWordNormalizer.ParsedWords(value: parsed, consumedWords: consumedWords)
    }

    private static func parseNumberText(_ text: String) -> String? {
        var characters = Array(text)
        var isNegative = false

        if let first = characters.first, negativeMarkers.contains(first) {
            isNegative = true
            characters.removeFirst()
            guard !characters.isEmpty else { return nil }
        }

        let parts = splitDecimal(characters)
        guard let integer = parseInteger(parts.integer), parts.integerHadNumber else { return nil }

        var replacement = "\(integer)"
        if let decimal = parts.decimal {
            let decimalDigits = decimal.compactMap { digitValues[$0] }
            guard decimalDigits.count == decimal.count, !decimalDigits.isEmpty else { return nil }
            replacement += "." + decimalDigits.map { String($0) }.joined()
        }

        if isNegative {
            replacement = "-" + replacement
        }
        return replacement
    }

    private static func splitDecimal(_ characters: [Character]) -> (integer: [Character], integerHadNumber: Bool, decimal: [Character]?) {
        guard let decimalIndex = characters.firstIndex(where: { decimalMarkers.contains($0) }) else {
            return (characters, characters.contains(where: isNumericCharacter), nil)
        }

        let integer = Array(characters[..<decimalIndex])
        let decimal = Array(characters[characters.index(after: decimalIndex)...])
        return (integer, integer.contains(where: isNumericCharacter), decimal)
    }

    private static func parseInteger(_ characters: [Character]) -> Int? {
        guard !characters.isEmpty else { return nil }

        var total = 0
        var section = 0
        var number = 0

        for character in characters {
            if let digit = digitValues[character] {
                number = digit
                continue
            }

            if let unit = unitValues[character] {
                section += (number == 0 ? 1 : number) * unit
                number = 0
                continue
            }

            if let largeUnit = largeUnitValues[character] {
                section += number
                total += max(section, 1) * largeUnit
                section = 0
                number = 0
                continue
            }

            return nil
        }

        return total + section + number
    }

    private static func isHanNumberWord(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { isNumericCharacter($0) || negativeMarkers.contains($0) }
    }

    private static func isNumericCharacter(_ character: Character) -> Bool {
        digitValues[character] != nil ||
            unitValues[character] != nil ||
            largeUnitValues[character] != nil ||
            decimalMarkers.contains(character)
    }

    private static func containsNumberMarker(_ text: String) -> Bool {
        text.contains { character in
            negativeMarkers.contains(character) ||
                decimalMarkers.contains(character) ||
                unitValues[character] != nil ||
                largeUnitValues[character] != nil
        }
    }
}
