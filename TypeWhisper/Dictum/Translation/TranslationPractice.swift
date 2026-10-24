import Foundation

/// 上手引导里翻译练习用的示例句，按说话语言查找；没有时用默认语言对的示例句。
enum TranslationPractice {
    struct Sentence: Equatable {
        let text: String
        /// 说话语言没有示例句，显示的是默认说话语言的示例句。
        let isFallback: Bool
    }

    private static let missing = "\u{0}"

    static func sentence(for spoken: String?) -> Sentence {
        if let spoken {
            let normalized = TranslationLanguageCode.normalized(spoken)
            for code in [normalized, TranslationLanguageCode.primary(normalized)] {
                if let text = lookup(code) { return Sentence(text: text, isFallback: false) }
            }
        }
        let fallback = lookup(TranslationLanguageSettings.defaultSpokenLanguage) ?? ""
        return Sentence(text: fallback, isFallback: spoken != nil)
    }

    private static func lookup(_ code: String) -> String? {
        let text = Bundle.main.localizedString(forKey: "practice.sentence.\(code)", value: missing, table: "DictumTranslation")
        return text == missing ? nil : text
    }
}
