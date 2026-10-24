import Foundation

/// 语言代码到显示名的转换。名字来自系统的语言数据，字符串表只覆盖带文字变体的写法。
enum TranslationLanguageNames {
    enum Style {
        /// 该语言自己的写法，例如 English、日本語。
        case native
        /// 界面语言里的名字。
        case interface
    }

    private static let missing = "\u{0}"
    /// 写入提示词的语言名统一用英文，模型对英文语言名最稳定。
    private static let defaultPromptLanguage = "en"

    static func name(for code: String, style: Style = .native) -> String {
        let normalized = TranslationLanguageCode.normalized(code)
        let override = Bundle.main.localizedString(forKey: "language.name.\(normalized)", value: missing, table: "DictumTranslation")
        if override != missing { return override }
        let locale = style == .native ? Locale(identifier: normalized) : Locale(identifier: preferredAppLanguageCode())
        let name = locale.localizedString(forIdentifier: normalized) ?? normalized
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// 语音条上的短名，只含语言本身，例如「中文」。
    static func shortName(for code: String) -> String {
        let normalized = TranslationLanguageCode.normalized(code)
        let language = TranslationLanguageCode.primary(normalized)
        let name = Locale(identifier: language).localizedString(forLanguageCode: language) ?? normalized
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// 写入提示词的英文名，例如 Japanese；带文字变体时形如 Chinese, Simplified。
    static func promptName(for code: String) -> String {
        let normalized = TranslationLanguageCode.normalized(code)
        return Locale(identifier: defaultPromptLanguage).localizedString(forIdentifier: normalized) ?? normalized
    }
}

/// 说话语言与目标语言的候选列表。
enum TranslationLanguageCatalog {
    /// 系统同时有简体和繁体数据的语言拆成两个变体。
    private static let splitScripts: Set<String> = ["Hans", "Hant"]

    /// 遍历全部系统语言标识符要 1 秒以上，只算一次。
    private static let scriptsByLanguage: [String: Set<String>] = {
        var result: [String: Set<String>] = [:]
        for identifier in Locale.availableIdentifiers {
            let language = Locale.Language(identifier: identifier)
            guard let code = language.languageCode?.identifier, let script = language.script?.identifier else { continue }
            result[code, default: []].insert(script)
        }
        return result
    }()

    struct Candidate: Equatable, Sendable {
        let code: String
        /// 界面语言里的名字，列表显示并按它排序。
        let name: String
        /// 该语言自己的写法，搜索时同样匹配。
        let nativeName: String
    }

    /// 全部可作为目标的语言，按界面语言的名字排好序，只算一次。
    private static let allCandidates: [Candidate] = {
        var codes: [String] = []
        for identifier in Locale.availableIdentifiers {
            guard let code = Locale.Language(identifier: identifier).languageCode?.identifier, code.count == 2 else { continue }
            for variant in expandedVariants(of: code) where !codes.contains(variant) { codes.append(variant) }
        }
        return codes
            .map { Candidate(code: $0, name: TranslationLanguageNames.name(for: $0, style: .interface),
                             nativeName: TranslationLanguageNames.name(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// 在后台提前算好候选列表，添加语言的浮层第一次打开时不卡顿。
    static func warmUp() {
        Task.detached(priority: .utility) { _ = allCandidates }
    }

    /// 把引擎报告的语言代码展开为带文字变体的选项。
    static func expandedVariants(of code: String) -> [String] {
        let normalized = TranslationLanguageCode.normalized(code)
        guard normalized.count == 2,
              let scripts = scriptsByLanguage[normalized], splitScripts.isSubset(of: scripts) else { return [normalized] }
        return splitScripts.sorted().map { "\(normalized)-\($0)" }
    }

    /// 说话语言选项：当前引擎支持的语言，加上已选的值。
    static func spokenOptions(engineCodes: [String], selected: String) -> [String] {
        var options: [String] = []
        for code in engineCodes.flatMap(expandedVariants(of:)) where !options.contains(code) { options.append(code) }
        if selected != TranslationLanguageSettings.automatic, !options.contains(selected) { options.append(selected) }
        return options.sorted {
            TranslationLanguageNames.name(for: $0, style: .interface)
                .localizedCaseInsensitiveCompare(TranslationLanguageNames.name(for: $1, style: .interface)) == .orderedAscending
        }
    }

    /// 翻译走大模型，任何有系统语言数据的语言都可以作为目标。
    static func targetCandidates(excluding existing: [String], matching query: String = "") -> [Candidate] {
        allCandidates.filter { candidate in
            !existing.contains { TranslationLanguageCode.isSame($0, candidate.code) }
                && (query.isEmpty || candidate.name.localizedCaseInsensitiveContains(query)
                    || candidate.nativeName.localizedCaseInsensitiveContains(query))
        }
    }

    /// 引擎能接受的语言提示：引擎列表里有该代码就直接用，否则用主语言。
    static func engineHint(for code: String, engineCodes: [String]) -> String {
        let normalized = TranslationLanguageCode.normalized(code)
        return engineCodes.contains(normalized) ? normalized : TranslationLanguageCode.primary(normalized)
    }
}
