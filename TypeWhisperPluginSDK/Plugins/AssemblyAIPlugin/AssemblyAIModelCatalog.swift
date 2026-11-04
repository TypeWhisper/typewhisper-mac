import Foundation
import TypeWhisperPluginSDK

enum AssemblyAIDictionaryPayload: Sendable, Equatable {
    case keytermsPrompt
    case wordBoost(boostParam: String)
}

enum AssemblyAIStreamingModelConfiguration: Sendable, Equatable {
    case universal35Pro(
        speechModelId: String,
        supportedLanguageCodes: Set<String>
    )
    case universal2(
        englishSpeechModelId: String,
        multilingualSpeechModelId: String
    )
}

/// AssemblyAI's Sync API (`POST https://sync.assemblyai.com/v1/transcribe`)
/// returns a finished transcript in the same request, without the async
/// API's upload, job and polling round trips.
struct AssemblyAISyncConfiguration: Sendable, Equatable {
    /// Value of the `X-AAI-Model` header.
    let modelId: String
    /// Codes `language_codes` accepts; any other code is rejected with a 400.
    let supportedLanguageCodes: Set<String>
    /// Audio longer than this is rejected with a 413.
    let maximumAudioDuration: TimeInterval
    let maximumKeyterms: Int
    let maximumKeytermCharacters: Int
}

struct AssemblyAIModelDefinition: Sendable, Equatable {
    let id: String
    let displayName: String
    let legacyIds: Set<String>
    let restModelId: String
    let supportedLanguages: [String]
    let dictionaryTermsBudget: DictionaryTermsBudget
    let dictionaryPayload: AssemblyAIDictionaryPayload
    let streamingConfiguration: AssemblyAIStreamingModelConfiguration
    let syncConfiguration: AssemblyAISyncConfiguration?

    var modelInfo: PluginModelInfo {
        PluginModelInfo(id: id, displayName: displayName)
    }
}

enum AssemblyAIModelCatalog {
    private static let universal35ProModelId = "universal-3-5-pro"
    private static let universal2ModelId = "universal-2"
    private static let universal35ProLanguages = [
        "en", "es", "fr", "de", "it", "pt", "tr", "nl", "sv",
        "no", "da", "fi", "hi", "vi", "ar", "he", "ja", "zh",
    ]
    private static let universal2Languages = [
        "bg", "ca", "cs", "da", "de", "el", "en", "es", "et", "fi",
        "fr", "hi", "hr", "hu", "id", "it", "ja", "ko", "lt", "lv",
        "ms", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sl", "sq",
        "sr", "sv", "th", "tr", "uk", "vi", "zh",
    ]
    private static let syncLanguages: Set<String> = [
        "en", "es", "de", "fr", "it", "pt", "tr", "nl", "sv", "no", "da",
        "fi", "hi", "vi", "ar", "he", "ja", "ur", "zh", "ko", "ca", "gl",
        "ru", "ro", "et", "fa", "yue", "af", "mr", "zu", "xh", "nn",
    ]

    static let legacyUniversal3ProModelId = "universal-3-pro"

    static let universal35Pro = AssemblyAIModelDefinition(
        id: universal35ProModelId,
        displayName: "Universal-3.5 Pro",
        legacyIds: [legacyUniversal3ProModelId],
        restModelId: universal35ProModelId,
        supportedLanguages: universal35ProLanguages,
        dictionaryTermsBudget: DictionaryTermsBudget(maxTerms: 1_000, maxWordsPerTerm: 6),
        dictionaryPayload: .keytermsPrompt,
        streamingConfiguration: .universal35Pro(
            speechModelId: universal35ProModelId,
            supportedLanguageCodes: Set(universal35ProLanguages)
        ),
        syncConfiguration: AssemblyAISyncConfiguration(
            modelId: universal35ProModelId,
            supportedLanguageCodes: syncLanguages,
            maximumAudioDuration: 20 * 60,
            maximumKeyterms: 100,
            maximumKeytermCharacters: 8_000
        )
    )

    static let universal2 = AssemblyAIModelDefinition(
        id: universal2ModelId,
        displayName: "Universal-2",
        legacyIds: [],
        restModelId: universal2ModelId,
        supportedLanguages: universal2Languages,
        dictionaryTermsBudget: DictionaryTermsBudget(maxTerms: 100, maxCharsPerTerm: 50),
        dictionaryPayload: .wordBoost(boostParam: "high"),
        streamingConfiguration: .universal2(
            englishSpeechModelId: "universal-streaming-english",
            multilingualSpeechModelId: "universal-streaming-multilingual"
        ),
        syncConfiguration: nil
    )

    static let all = [universal35Pro, universal2]
    static let defaultModel = universal35Pro

    static func resolve(_ modelId: String?) -> AssemblyAIModelDefinition {
        guard let modelId else { return defaultModel }
        return all.first { definition in
            definition.id == modelId || definition.legacyIds.contains(modelId)
        } ?? defaultModel
    }
}
