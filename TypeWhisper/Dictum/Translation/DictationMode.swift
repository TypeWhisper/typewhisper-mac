import Foundation

/// 一次会话的模式在开始时确定：Fn 为听写，Fn + 左 Shift 为翻译。
enum DictationMode: String, Codable, Sendable {
    case dictation
    case translation
}

/// 翻译会话使用的语言对。`spoken` 为空表示自动识别。
struct TranslationPair: Equatable, Hashable, Sendable {
    var spoken: String?
    var target: String
}
