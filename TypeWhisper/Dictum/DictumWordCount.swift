import Foundation

/// 按界面设计统计字数：中日韩文字按字计数，其余连续字母数字按词计数，标点和表情不计数。
/// 字母之间的撇号和数字之间的句点、逗号留在同一个词里。
enum DictumWordCount {
    static func count(_ text: String) -> Int {
        let characters = Array(text)
        var count = 0
        var insideWord = false

        for (index, character) in characters.enumerated() {
            if isCJK(character) {
                count += 1
                insideWord = false
            } else if character.isLetter || character.isNumber {
                if !insideWord {
                    count += 1
                }
                insideWord = true
            } else if insideWord,
                      joinsWord(
                          character,
                          between: characters[index - 1],
                          and: index + 1 < characters.count ? characters[index + 1] : nil
                      ) {
                continue
            } else {
                insideWord = false
            }
        }
        return count
    }

    /// 取簇的首个标量判断，簇后面跟着的变体选择符不影响结果。
    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:
            return scalar.properties.isAlphabetic
        case 0xAC00...0xD7A3:
            return true
        default:
            return false
        }
    }

    private static func joinsWord(_ character: Character, between previous: Character, and next: Character?) -> Bool {
        guard let next, !isCJK(previous), !isCJK(next) else { return false }
        switch character {
        case "'", "\u{2019}":
            return previous.isLetter && next.isLetter
        case ".", ",":
            return previous.isNumber && next.isNumber
        default:
            return false
        }
    }
}
