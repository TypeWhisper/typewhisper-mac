import Foundation

enum JapaneseNumberWordParser {
    static func parse(_ words: [String]) -> NumberWordNormalizer.ParsedWords? {
        HanNumberWordParser.parse(words)
    }
}
