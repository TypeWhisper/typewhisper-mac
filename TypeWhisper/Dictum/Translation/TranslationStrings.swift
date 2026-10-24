import Foundation

/// 听写流程里使用的翻译文案。
enum TranslationStrings {
    static var failedInserted: String { String(localized: "translation.failed.inserted", table: "DictumTranslation") }
    static var retryReplaced: String { String(localized: "translation.retry.replaced", table: "DictumTranslation") }
    static var retryCopied: String { String(localized: "translation.retry.copied", table: "DictumTranslation") }
}
