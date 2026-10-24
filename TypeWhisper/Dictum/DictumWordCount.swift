import Foundation

/// 按界面设计统计字数：中日韩文字按字计数，其余连续字母数字按词计数，标点和表情不计数。
enum DictumWordCount {
    static func count(_ text: String) -> Int {
        var count = 0
        var insideWord = false

        for character in text {
            if isCJK(character) {
                count += 1
                insideWord = false
            } else if character.isLetter || character.isNumber {
                if !insideWord {
                    count += 1
                }
                insideWord = true
            } else {
                insideWord = false
            }
        }
        return count
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            (0x3005...0x3007).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0x31F0...0x31FF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0xAC00...0xD7A3).contains(scalar.value)
                || (0x20000...0x2A6DF).contains(scalar.value)
                || (0x2A700...0x2EBEF).contains(scalar.value)
                || (0x2EBF0...0x323AF).contains(scalar.value)
                || (0xFF66...0xFF9F).contains(scalar.value)
        }
    }
}
