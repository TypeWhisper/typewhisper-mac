import Foundation

enum VoiceBarLanguages {
    struct Option: Identifiable {
        let code: String
        var id: String { code }
        var name: String { TranslationLanguageNames.name(for: code) }
    }

    /// 目标语言按通用页的顺序排列，不含说话语言。
    @MainActor static var options: [Option] {
        TranslationLanguageStore.shared.settings.offeredTargets.map { Option(code: $0) }
    }
}
