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

    static func parse(
        _ words: [String],
        spokenTailEnabled: Bool = false
    ) -> NumberWordNormalizer.ParsedWords? {
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
        guard let parsed = parseNumberText(numberText, spokenTailEnabled: spokenTailEnabled) else { return nil }
        return NumberWordNormalizer.ParsedWords(value: parsed, consumedWords: consumedWords, kind: parsed.contains(".") ? .decimal : .number)
    }

    private static func parseNumberText(_ text: String, spokenTailEnabled: Bool) -> String? {
        var characters = Array(text)
        var isNegative = false

        if let first = characters.first, negativeMarkers.contains(first) {
            isNegative = true
            characters.removeFirst()
            guard !characters.isEmpty else { return nil }
        }

        let parts = splitDecimal(characters)
        guard let integer = parseInteger(parts.integer, spokenTailEnabled: spokenTailEnabled),
              parts.integerHadNumber else {
            return nil
        }

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

    private static func parseInteger(_ characters: [Character], spokenTailEnabled: Bool) -> Int? {
        guard !characters.isEmpty else { return nil }

        var total = 0
        var section = 0
        var number = 0
        var lastUnit: Int?
        var lastUnitHadExplicitZero = false
        var lastCharacterWasDigit = false
        var previousCharacterWasASCIIDigit = false

        for character in characters {
            if let digit = asciiDigitValue(character) {
                if previousCharacterWasASCIIDigit {
                    let (multiplied, multiplyOverflow) = number.multipliedReportingOverflow(by: 10)
                    guard !multiplyOverflow else { return nil }
                    let (sum, addOverflow) = multiplied.addingReportingOverflow(digit)
                    guard !addOverflow else { return nil }
                    number = sum
                } else {
                    number = digit
                }
                lastCharacterWasDigit = true
                previousCharacterWasASCIIDigit = true
                continue
            }

            if let digit = digitValues[character] {
                number = digit
                if digit == 0 {
                    lastUnitHadExplicitZero = true
                }
                lastCharacterWasDigit = true
                previousCharacterWasASCIIDigit = false
                continue
            }

            if let unit = unitValues[character] {
                section += (number == 0 ? 1 : number) * unit
                number = 0
                lastUnit = unit
                lastUnitHadExplicitZero = false
                lastCharacterWasDigit = false
                previousCharacterWasASCIIDigit = false
                continue
            }

            if let largeUnit = largeUnitValues[character] {
                section += number
                total += max(section, 1) * largeUnit
                section = 0
                number = 0
                lastUnit = largeUnit
                lastUnitHadExplicitZero = false
                lastCharacterWasDigit = false
                previousCharacterWasASCIIDigit = false
                continue
            }

            return nil
        }

        if spokenTailEnabled, let lastUnit, lastCharacterWasDigit, !lastUnitHadExplicitZero {
            // In spoken Chinese, a trailing digit after a unit fills the next
            // lower place: 一萬五 = 15000, 千二 = 1200. An explicit zero
            // keeps the literal reading: 一萬零五 = 10005.
            return total + section + number * max(lastUnit / 10, 1)
        }
        return total + section + number
    }

    private static func isHanNumberWord(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { isNumericCharacter($0) || negativeMarkers.contains($0) }
    }

    private static func isNumericCharacter(_ character: Character) -> Bool {
        asciiDigitValue(character) != nil ||
            digitValues[character] != nil ||
            unitValues[character] != nil ||
            largeUnitValues[character] != nil ||
            decimalMarkers.contains(character)
    }

    private static func asciiDigitValue(_ character: Character) -> Int? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1,
              scalar.value >= 48,
              scalar.value <= 57 else {
            return nil
        }
        return Int(scalar.value - 48)
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
