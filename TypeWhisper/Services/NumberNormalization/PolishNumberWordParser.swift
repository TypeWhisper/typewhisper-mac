import Foundation

/// Converts Polish cardinal numbers in their nominative form, such as
/// `dwa tysiące pięćset` -> `2500`.
///
/// Declined forms (`dziesięciu`, `dwóch`, `stu`) stay as spoken: they double as
/// masculine-personal and case forms whose conversion depends on the sentence.
/// Words are matched with their diacritics, because dropping them would turn
/// ordinary words such as `piec` (oven) into numbers.
enum PolishNumberWordParser {
    private static let unitValues: [String: Int] = [
        "jeden": 1, "jedna": 1, "jedno": 1, "dwa": 2, "dwie": 2, "trzy": 3,
        "cztery": 4, "pięć": 5, "sześć": 6, "siedem": 7, "osiem": 8, "dziewięć": 9,
    ]

    private static let teenValues: [String: Int] = [
        "dziesięć": 10, "jedenaście": 11, "dwanaście": 12, "trzynaście": 13,
        "czternaście": 14, "piętnaście": 15, "szesnaście": 16, "siedemnaście": 17,
        "osiemnaście": 18, "dziewiętnaście": 19,
    ]

    private static let tensValues: [String: Int] = [
        "dwadzieścia": 20, "trzydzieści": 30, "czterdzieści": 40, "pięćdziesiąt": 50,
        "sześćdziesiąt": 60, "siedemdziesiąt": 70, "osiemdziesiąt": 80, "dziewięćdziesiąt": 90,
    ]

    private static let hundredValues: [String: Int] = [
        "sto": 100, "dwieście": 200, "trzysta": 300, "czterysta": 400, "pięćset": 500,
        "sześćset": 600, "siedemset": 700, "osiemset": 800, "dziewięćset": 900,
    ]

    /// Scale words. Only the singular form may stand without a count:
    /// `tysiąc` is 1000, while a bare `tysiące` means "thousands".
    private static let scaleValues: [String: (value: Int, isSingular: Bool)] = [
        "tysiąc": (1_000, true), "tysiące": (1_000, false), "tysięcy": (1_000, false),
        "milion": (1_000_000, true), "miliony": (1_000_000, false), "milionów": (1_000_000, false),
        "miliard": (1_000_000_000, true), "miliardy": (1_000_000_000, false), "miliardów": (1_000_000_000, false),
    ]

    private static let decimalSeparatorWord = "przecinek"

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

        guard let integer = parseInteger(normalizedWords, startingAt: index) else {
            return nil
        }
        index = integer.nextIndex
        var replacement = "\(integer.value)"
        var kind = NumberWordNormalizer.ParsedWords.Kind.number

        if index < normalizedWords.count, normalizedWords[index] == decimalSeparatorWord {
            let decimal = parseDecimalDigits(normalizedWords, startingAt: index + 1)
            if !decimal.digits.isEmpty {
                kind = .decimal
                replacement += ",\(decimal.digits)"
                index = decimal.nextIndex
            }
        }

        // A lone `jeden` usually means "one of" or "a", as in `jeden z nich`.
        // Keep it unless a sign or decimal part marks it as a number.
        if integer.isBareOne, !isNegative, kind == .number {
            return nil
        }

        // `zero` is also an English word. Converting it on its own would block
        // a later English candidate, as in `zero point five`, so only Polish
        // decimals such as `zero przecinek pięć` convert it.
        if integer.isBareZero, kind == .number {
            return nil
        }

        if isNegative {
            replacement = "-" + replacement
        }

        return NumberWordNormalizer.ParsedWords(value: replacement, consumedWords: index, kind: kind)
    }

    private static func parseInteger(
        _ words: [String],
        startingAt startIndex: Int
    ) -> (value: Int, nextIndex: Int, isBareOne: Bool, isBareZero: Bool)? {
        guard startIndex < words.count else { return nil }

        if words[startIndex] == "zero" {
            return (0, startIndex + 1, false, true)
        }

        var total = 0
        var index = startIndex
        var previousScale = Int.max

        while index < words.count {
            let group = parseGroup(words, startingAt: index)
            let scaleIndex = group?.nextIndex ?? index

            if scaleIndex < words.count,
               let scale = scaleValues[words[scaleIndex]],
               scale.value < previousScale,
               group != nil || scale.isSingular {
                total += (group?.value ?? 1) * scale.value
                previousScale = scale.value
                index = scaleIndex + 1
                continue
            }

            if let group {
                total += group.value
                index = group.nextIndex
            }
            break
        }

        guard index > startIndex else { return nil }
        let isBareOne = index == startIndex + 1 && unitValues[words[startIndex]] == 1
        return (total, index, isBareOne, false)
    }

    /// Parses one group below 1000 in spoken order: hundreds, then tens, then a unit or teen.
    private static func parseGroup(_ words: [String], startingAt startIndex: Int) -> (value: Int, nextIndex: Int)? {
        var value = 0
        var index = startIndex

        if index < words.count, let hundred = hundredValues[words[index]] {
            value += hundred
            index += 1
        }

        if index < words.count, let ten = tensValues[words[index]] {
            value += ten
            index += 1
            if index < words.count, let unit = unitValues[words[index]] {
                value += unit
                index += 1
            }
        } else if index < words.count, let small = teenValues[words[index]] ?? unitValues[words[index]] {
            value += small
            index += 1
        }

        guard index > startIndex else { return nil }
        return (value, index)
    }

    /// Reads the decimal part either digit by digit (`pięć zero` -> `50`) or, as Polish
    /// speakers often do, as one cardinal group after optional leading zeros
    /// (`dwadzieścia pięć` -> `25`, `zero dwadzieścia pięć` -> `025`).
    private static func parseDecimalDigits(_ words: [String], startingAt startIndex: Int) -> (digits: String, nextIndex: Int) {
        var digits = ""
        var index = startIndex

        while index < words.count, words[index] == "zero" {
            digits += "0"
            index += 1
        }

        if index < words.count,
           unitValues[words[index]] == nil,
           let group = parseGroup(words, startingAt: index) {
            return (digits + "\(group.value)", group.nextIndex)
        }

        while index < words.count, let digit = words[index] == "zero" ? 0 : unitValues[words[index]] {
            digits += "\(digit)"
            index += 1
        }

        return (digits, index)
    }

    private static func normalizeWord(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "pl_PL"))
    }
}
