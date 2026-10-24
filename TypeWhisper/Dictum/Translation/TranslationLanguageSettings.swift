import Foundation
import Combine

/// BCP 47 语言代码的比较与拆分。
enum TranslationLanguageCode {
    static func normalized(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
    }

    static func primary(_ code: String) -> String {
        Locale.Language(identifier: normalized(code)).languageCode?.identifier
            ?? normalized(code).lowercased()
    }

    static func script(_ code: String) -> String? {
        Locale.Language(identifier: normalized(code)).script?.identifier
    }

    /// 主语言相同，且文字（如简体与繁体）不冲突时视为同一种语言。
    static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        guard primary(lhs) == primary(rhs) else { return false }
        guard let left = script(lhs), let right = script(rhs) else { return true }
        return left == right
    }
}

/// 说话语言、有序目标语言和最近一次选用的目标语言。
struct TranslationLanguageSettings: Equatable, Sendable {
    static let automatic = "auto"
    static let defaultSpokenLanguage = "zh-Hans"
    static let defaultTargets = ["en"]

    var spokenLanguage: String = Self.defaultSpokenLanguage
    var targets: [String] = Self.defaultTargets
    var current: String?

    var isAutomatic: Bool { spokenLanguage == Self.automatic }

    /// 与说话语言相同的目标不提供；自动识别时不排除。
    var offeredTargets: [String] {
        var seen: [String] = []
        for code in targets.map(TranslationLanguageCode.normalized) where !code.isEmpty {
            guard !seen.contains(code) else { continue }
            if !isAutomatic, TranslationLanguageCode.isSame(spokenLanguage, code) { continue }
            seen.append(code)
        }
        return seen
    }

    /// 当前目标被移除后回到列表中的第一个。
    var currentTarget: String? {
        let offered = offeredTargets
        if let current, offered.contains(current) { return current }
        return offered.first
    }

    var pair: TranslationPair? {
        currentTarget.map { TranslationPair(spoken: isAutomatic ? nil : spokenLanguage, target: $0) }
    }
}

/// 翻译语言设置的唯一存储。所有读取方（语音条、菜单栏、通用页、上手引导、听写流程）都通过它。
@MainActor
final class TranslationLanguageStore: ObservableObject {
    static let shared = TranslationLanguageStore()

    enum Keys {
        static let spoken = "dictum.translation.spoken"
        static let targets = "dictum.translation.targets"
        static let current = "dictum.translation.current"
        static let migrated = "dictum.translation.migrated"
        static let legacyTarget = "translationTargetLanguage"
        static let legacyTargets = "dictumTranslationTargetLanguages"
    }

    @Published private(set) var settings: TranslationLanguageSettings
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyKeys(in: defaults)
        settings = Self.load(from: defaults)
    }

    /// 旧版本的单个目标与语音条目标列表一次性并入新键，之后不再读取旧键。
    nonisolated static func migrateLegacyKeys(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: Keys.migrated) else { return }
        defer { defaults.set(true, forKey: Keys.migrated) }
        guard defaults.object(forKey: Keys.targets) == nil else { return }
        var ordered: [String] = []
        for code in [defaults.string(forKey: Keys.legacyTarget)].compactMap({ $0 }) + (defaults.stringArray(forKey: Keys.legacyTargets) ?? []) {
            let normalized = TranslationLanguageCode.normalized(code)
            if !normalized.isEmpty, !ordered.contains(normalized) { ordered.append(normalized) }
        }
        guard !ordered.isEmpty else { return }
        defaults.set(ordered, forKey: Keys.targets)
        if let legacy = defaults.string(forKey: Keys.legacyTarget) {
            defaults.set(TranslationLanguageCode.normalized(legacy), forKey: Keys.current)
        }
        defaults.removeObject(forKey: Keys.legacyTargets)
    }

    nonisolated static func load(from defaults: UserDefaults) -> TranslationLanguageSettings {
        var settings = TranslationLanguageSettings()
        if let spoken = defaults.string(forKey: Keys.spoken), !spoken.isEmpty { settings.spokenLanguage = spoken }
        if let targets = defaults.stringArray(forKey: Keys.targets) { settings.targets = targets }
        settings.current = defaults.string(forKey: Keys.current)
        return settings
    }

    private func persist() {
        defaults.set(settings.spokenLanguage, forKey: Keys.spoken)
        defaults.set(settings.targets, forKey: Keys.targets)
        if let current = settings.current { defaults.set(current, forKey: Keys.current) }
        else { defaults.removeObject(forKey: Keys.current) }
    }

    /// 新的说话语言与全部目标冲突时，原来的说话语言成为目标。
    func setSpokenLanguage(_ code: String) {
        let previous = settings.spokenLanguage
        settings.spokenLanguage = code
        if settings.offeredTargets.isEmpty, previous != code, previous != TranslationLanguageSettings.automatic {
            settings.targets = [previous]
            settings.current = previous
        }
        persist()
    }

    func addTarget(_ code: String) {
        let normalized = TranslationLanguageCode.normalized(code)
        guard !normalized.isEmpty, !settings.targets.contains(normalized) else { return }
        settings.targets.append(normalized)
        persist()
    }

    /// 目标列表至少保留一项。
    func removeTarget(_ code: String) {
        guard settings.offeredTargets.count > 1 else { return }
        settings.targets.removeAll { $0 == code }
        persist()
    }

    func moveTargets(from offsets: IndexSet, to destination: Int) {
        var offered = settings.offeredTargets
        let moving = offsets.map { offered[$0] }
        let insertion = destination - offsets.filter { $0 < destination }.count
        for index in offsets.sorted(by: >) { offered.remove(at: index) }
        offered.insert(contentsOf: moving, at: insertion)
        let hidden = settings.targets.filter { !offered.contains($0) }
        settings.targets = offered + hidden
        persist()
    }

    func selectCurrentTarget(_ code: String) {
        guard settings.offeredTargets.contains(code) else { return }
        settings.current = code
        persist()
    }
}
