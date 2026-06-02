import Foundation

public enum AppleSpeechModelSelection {
    public static let providerId = "speechAnalyzer"
    public static let manifestId = "com.typewhisper.speechanalyzer"
    public static let modelIdPrefix = "speechanalyzer-"

    public static func preferredModelId(
        from models: [PluginModelInfo],
        localeIdentifier: String = Locale.current.identifier,
        languageCode: String? = Locale.current.language.languageCode?.identifier,
        fallbackToFirst: Bool = true
    ) -> String? {
        preferredModelId(
            fromModelIds: models.map(\.id),
            localeIdentifier: localeIdentifier,
            languageCode: languageCode,
            fallbackToFirst: fallbackToFirst
        )
    }

    public static func preferredModelId(
        fromModelIds modelIds: [String],
        localeIdentifier: String = Locale.current.identifier,
        languageCode: String? = Locale.current.language.languageCode?.identifier,
        fallbackToFirst: Bool = true
    ) -> String? {
        guard !modelIds.isEmpty else { return nil }

        for modelId in localeModelIds(for: localeIdentifier) {
            if modelIds.contains(modelId) {
                return modelId
            }
        }

        if let languageCode {
            let languageModelId = "\(modelIdPrefix)\(languageCode)"
            if modelIds.contains(languageModelId) {
                return languageModelId
            }

            if let match = modelIds.first(where: { modelLanguageCode(for: $0) == languageCode }) {
                return match
            }
        }

        return fallbackToFirst ? modelIds.first : nil
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

    private static func uniqueModelIds(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, value in
            guard !value.isEmpty, !result.contains(value) else { return }
            result.append(value)
        }
    }
}
