import Foundation

enum ChineseNumberWordParser {
    static func parse(_ words: [String]) -> NumberWordNormalizer.ParsedWords? {
        HanNumberWordParser.parse(words)
    }
}
