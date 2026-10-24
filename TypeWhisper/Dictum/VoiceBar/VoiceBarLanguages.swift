import Foundation

enum VoiceBarLanguages {
    struct Option: Identifiable {
        let code: String
        var id: String { code }
        var name: String { Locale(identifier: code).localizedString(forLanguageCode: code) ?? code }
    }

    static var options: [Option] {
        let codes = UserDefaults.standard.stringArray(forKey: "dictumTranslationTargetLanguages") ?? ["en", "ja", "ko", "zh-Hans", "fr", "de", "es"]
        return codes.map { Option(code: $0) }
    }
}
