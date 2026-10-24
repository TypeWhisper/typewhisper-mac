import Foundation

/// 翻译记录的语言对。说话语言为自动识别时，保存识别出的语言。
struct HistoryTranslationInfo: Equatable, Sendable {
    var spokenLanguage: String?
    var targetLanguage: String
}
