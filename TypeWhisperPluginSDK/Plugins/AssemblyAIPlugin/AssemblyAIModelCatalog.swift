import Foundation
import TypeWhisperPluginSDK

enum AssemblyAIDictionaryPayload: Sendable, Equatable {
    case keytermsPrompt
    case wordBoost(boostParam: String)
}

/// The models a live session can stream. Both take the same 32 languages and up to 100
/// dictionary terms; the final text is as good with either.
enum AssemblyAILiveModel: String, CaseIterable, Sendable {
    /// Built for voice agents: the preview grows word by word and rarely changes. $0.45/h.
    case realtimeAgent = "assemblyai-stt-3-7-realtime-agent"
    /// Built for captions and notetakers: cheaper, but the preview is revised more often
    /// while you speak. $0.30/h.
    case realtime = "assemblyai-stt-3-7-realtime"

    static let defaultModel = realtimeAgent

    var speechModelId: String { rawValue }
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
    /// `speech_models` for the async API: the model, then the one it falls back to for
    /// languages it does not support.
    let restModelIds: [String]
    let supportedLanguages: [String]
    let dictionaryTermsBudget: DictionaryTermsBudget
    let dictionaryPayload: AssemblyAIDictionaryPayload
    /// The languages a live session can be steered to, or nil when the model has none.
    let liveLanguageCodes: Set<String>?
    let syncConfiguration: AssemblyAISyncConfiguration?

    var modelInfo: PluginModelInfo {
        PluginModelInfo(id: id, displayName: displayName)
    }
}

enum AssemblyAIModelCatalog {
    private static let stt37ModelId = "assemblyai-stt-3-7"
    private static let universal2ModelId = "universal-2"
    /// AssemblyAI-STT-3.7, its realtime models and Universal-3.6 Pro on the Sync and
    /// Dictation APIs all take these 32 languages.
    private static let stt37Languages = [
        "en", "es", "de", "fr", "it", "pt", "tr", "nl", "sv", "no", "da",
        "fi", "hi", "vi", "ar", "he", "ja", "ur", "zh", "ko", "ca", "gl",
        "ru", "ro", "et", "fa", "yue", "af", "mr", "zu", "xh", "nn",
    ]
    private static let universal2Languages = [
        "bg", "ca", "cs", "da", "de", "el", "en", "es", "et", "fi",
        "fr", "hi", "hr", "hu", "id", "it", "ja", "ko", "lt", "lv",
        "ms", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sl", "sq",
        "sr", "sv", "th", "tr", "uk", "vi", "zh",
    ]

    /// Earlier defaults. AssemblyAI deprecated both on November 17, 2026 in favour of
    /// AssemblyAI-STT-3.7; saved selections and profile overrides move to it.
    static let legacyUniversal3ProModelId = "universal-3-pro"
    static let legacyUniversal35ProModelId = "universal-3-5-pro"

    static let stt37 = AssemblyAIModelDefinition(
        id: stt37ModelId,
        displayName: "AssemblyAI-STT-3.7",
        legacyIds: [legacyUniversal35ProModelId, legacyUniversal3ProModelId],
        restModelIds: [stt37ModelId, universal2ModelId],
        supportedLanguages: stt37Languages,
        dictionaryTermsBudget: DictionaryTermsBudget(maxTerms: 1_000, maxWordsPerTerm: 6),
        dictionaryPayload: .keytermsPrompt,
        liveLanguageCodes: Set(stt37Languages),
        syncConfiguration: AssemblyAISyncConfiguration(
            // The Sync API runs Universal-3.6 Pro; it routes the retired
            // universal-3-5-pro to it.
            modelId: "universal-3-6-pro",
            supportedLanguageCodes: Set(stt37Languages),
            maximumAudioDuration: 20 * 60,
            maximumKeyterms: 100,
            maximumKeytermCharacters: 8_000
        )
    )

    static let universal2 = AssemblyAIModelDefinition(
        id: universal2ModelId,
        displayName: "Universal-2",
        legacyIds: [],
        restModelIds: [universal2ModelId],
        supportedLanguages: universal2Languages,
        dictionaryTermsBudget: DictionaryTermsBudget(maxTerms: 100, maxCharsPerTerm: 50),
        dictionaryPayload: .wordBoost(boostParam: "high"),
        liveLanguageCodes: nil,
        syncConfiguration: nil
    )

    static let all = [stt37, universal2]
    static let defaultModel = stt37

    static func resolve(_ modelId: String?) -> AssemblyAIModelDefinition {
        guard let modelId else { return defaultModel }
        return all.first { definition in
            definition.id == modelId || definition.legacyIds.contains(modelId)
        } ?? defaultModel
    }
}
