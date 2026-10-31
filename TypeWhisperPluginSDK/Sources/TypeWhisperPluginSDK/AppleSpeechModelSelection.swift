import Foundation

public enum AppleSpeechModelSelection {
    public static let providerId = "speechAnalyzer"
    public static let manifestId = "com.typewhisper.speechanalyzer"
    public static let modelIdPrefix = "speechanalyzer-"

    public static func preferredModelId(
        from models: [PluginModelInfo],
        localeIdentifier: String = Locale.current.identifier,
        languageCode: String? = Locale.current.language.languageCode?.identifier,
        preferredModelId: String? = nil,
        fallbackLocaleIdentifier: String? = nil,
        fallbackToFirst: Bool = true
    ) -> String? {
        Self.preferredModelId(
            fromModelIds: models.map(\.id),
            localeIdentifier: localeIdentifier,
            languageCode: languageCode,
            preferredModelId: preferredModelId,
            fallbackLocaleIdentifier: fallbackLocaleIdentifier,
            fallbackToFirst: fallbackToFirst
        )
    }

    public static func preferredModelId(
        fromModelIds modelIds: [String],
        localeIdentifier: String = Locale.current.identifier,
        languageCode: String? = Locale.current.language.languageCode?.identifier,
        preferredModelId: String? = nil,
        fallbackLocaleIdentifier: String? = nil,
        fallbackToFirst: Bool = true
    ) -> String? {
        guard !modelIds.isEmpty else { return nil }

        for modelId in localeModelIds(for: localeIdentifier) {
            if modelIds.contains(modelId) {
                return modelId
            }
        }

        if let languageCode {
            for modelId in localeModelIds(for: languageCode) {
                if modelIds.contains(modelId) {
                    return modelId
                }
            }

            let normalizedLanguageCode = normalizedLanguageCode(for: languageCode)
            let languageModelId = "\(modelIdPrefix)\(normalizedLanguageCode)"
            if modelIds.contains(languageModelId) {
                return languageModelId
            }

            if let preferredModelId,
               modelIds.contains(preferredModelId),
               modelLanguageCode(for: preferredModelId) == normalizedLanguageCode {
                return preferredModelId
            }

            if let fallbackLocaleIdentifier,
               Self.normalizedLanguageCode(for: fallbackLocaleIdentifier) == normalizedLanguageCode {
                for modelId in localeModelIds(for: fallbackLocaleIdentifier) {
                    if modelIds.contains(modelId) {
                        return modelId
                    }
                }
            }

            if let match = modelIds.first(where: { modelLanguageCode(for: $0) == normalizedLanguageCode }) {
                return match
            }
        }

        return fallbackToFirst ? modelIds.first : nil
    }

    /// Language codes for the language picker: the language of every model, plus the full locale
    /// of each model whose language has regional models in different scripts. Chinese has zh-CN
    /// (Simplified) next to zh-TW and zh-HK (Traditional, zh-HK is Cantonese), and "zh" alone
    /// would leave the choice to the fallback order. Other regional models, such as en-GB next to
    /// en-US, stay behind their language code.
    public static func supportedLanguages(fromModelIds modelIds: [String]) -> [String] {
        let localeIdentifiers = modelIds
            .filter { $0.hasPrefix(modelIdPrefix) }
            .map { String($0.dropFirst(modelIdPrefix.count)) }

        var localesByLanguage: [String: [String]] = [:]
        for localeIdentifier in localeIdentifiers {
            guard let languageCode = Locale(identifier: localeIdentifier).language.languageCode?.identifier else {
                continue
            }
            localesByLanguage[languageCode, default: []].append(localeIdentifier)
        }

        var languages = Set(localesByLanguage.keys)
        for localeIdentifiers in localesByLanguage.values {
            let scripts = Set(localeIdentifiers.map { scriptCode(for: $0) })
            guard scripts.count > 1 else { continue }
            for localeIdentifier in localeIdentifiers {
                languages.insert(Locale(identifier: localeIdentifier).identifier(.bcp47))
            }
        }
        return languages.sorted()
    }

    public static func modelLanguageCode(for modelId: String) -> String? {
        guard modelId.hasPrefix(modelIdPrefix) else { return nil }
        let localeIdentifier = String(modelId.dropFirst(modelIdPrefix.count))
        return Locale(identifier: localeIdentifier).language.languageCode?.identifier
    }

    private static func localeModelIds(for localeIdentifier: String) -> [String] {
        uniqueModelIds([
            localeIdentifier,
            localeIdentifier.replacingOccurrences(of: "-", with: "_"),
            localeIdentifier.replacingOccurrences(of: "_", with: "-")
        ])
        .map { "\(modelIdPrefix)\($0)" }
    }

    private static func scriptCode(for localeIdentifier: String) -> String? {
        let maximalIdentifier = Locale.Language(identifier: localeIdentifier).maximalIdentifier
        return Locale.Language(identifier: maximalIdentifier).script?.identifier
    }

    private static func normalizedLanguageCode(for localeIdentifier: String) -> String {
        Locale(identifier: localeIdentifier).language.languageCode?.identifier
            ?? localeIdentifier.split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first
                .map(String.init)?
                .lowercased()
            ?? localeIdentifier.lowercased()
    }

    private static func uniqueModelIds(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, value in
            guard !value.isEmpty, !result.contains(value) else { return }
            result.append(value)
        }
    }
}
