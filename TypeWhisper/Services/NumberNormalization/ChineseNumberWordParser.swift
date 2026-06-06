import Foundation

/// 解析中文数字词的解析器
///
/// 提供将中文数字词转换为标准数字格式的功能，作为数字规范化服务的一部分。
enum ChineseNumberWordParser {
    /// 解析中文数字词数组为标准化的数字格式
    ///
    /// - Parameter words: 包含中文数字词的字符串数组，例如 `["一", "十", "百"]`
    /// - Returns: 解析成功返回标准化的数字表示，解析失败返回 `nil`
    static func parse(_ words: [String]) -> NumberWordNormalizer.ParsedWords? {
        HanNumberWordParser.parse(words)
    }
}
