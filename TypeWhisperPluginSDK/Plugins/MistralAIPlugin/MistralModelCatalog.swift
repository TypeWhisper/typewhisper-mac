import Foundation
import TypeWhisperPluginSDK

// MARK: - Catalog Entries

/// One entry of Mistral's model list, `GET /v1/models`. The list repeats every model
/// once per alias, and each repetition names the others in `aliases`.
struct MistralCatalogEntry: Decodable, Equatable, Sendable {
    struct Capabilities: Decodable, Equatable, Sendable {
        var completionChat = false
        var audio = false
        var audioTranscription = false
        var audioTranscriptionRealtime = false
        var reasoning = false
        var ocr = false
        var moderation = false
        var completionFim = false
        var classification = false

        enum CodingKeys: String, CodingKey {
            case completionChat = "completion_chat"
            case audio
            case audioTranscription = "audio_transcription"
            case audioTranscriptionRealtime = "audio_transcription_realtime"
            case reasoning
            case ocr
            case moderation
            case completionFim = "completion_fim"
            case classification
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func flag(_ key: CodingKeys) -> Bool {
                (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? false
            }
            completionChat = flag(.completionChat)
            audio = flag(.audio)
            audioTranscription = flag(.audioTranscription)
            audioTranscriptionRealtime = flag(.audioTranscriptionRealtime)
            reasoning = flag(.reasoning)
            ocr = flag(.ocr)
            moderation = flag(.moderation)
            completionFim = flag(.completionFim)
            classification = flag(.classification)
        }
    }

    /// `audio_transcription_capabilities`, present on transcription models.
    struct TranscriptionCapabilities: Decodable, Equatable, Sendable {
        var modes: [String] = []
        var diarization = false
        var contextBias = false
        var languages: [String] = []

        enum CodingKeys: String, CodingKey {
            case modes
            case diarization
            case contextBias = "context_bias"
            case languages
        }

        init(modes: [String] = [], diarization: Bool = false, contextBias: Bool = false, languages: [String] = []) {
            self.modes = modes
            self.diarization = diarization
            self.contextBias = contextBias
            self.languages = languages
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            modes = (try? container.decodeIfPresent([String].self, forKey: .modes)) ?? []
            diarization = (try? container.decodeIfPresent(Bool.self, forKey: .diarization)) ?? false
            contextBias = (try? container.decodeIfPresent(Bool.self, forKey: .contextBias)) ?? false
            languages = (try? container.decodeIfPresent([String].self, forKey: .languages)) ?? []
        }
    }

    var id: String
    var name: String?
    var description: String?
    var aliases: [String] = []
    var deprecation: String?
    var capabilities = Capabilities()
    var transcription: TranscriptionCapabilities?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case aliases
        case deprecation
        case capabilities
        case transcription = "audio_transcription_capabilities"
    }

    init(
        id: String,
        name: String? = nil,
        description: String? = nil,
        aliases: [String] = [],
        deprecation: String? = nil,
        capabilities: Capabilities = Capabilities(),
        transcription: TranscriptionCapabilities? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.aliases = aliases
        self.deprecation = deprecation
        self.capabilities = capabilities
        self.transcription = transcription
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        aliases = (try? container.decodeIfPresent([String].self, forKey: .aliases)) ?? []
        deprecation = try? container.decodeIfPresent(String.self, forKey: .deprecation)
        capabilities = (try? container.decodeIfPresent(Capabilities.self, forKey: .capabilities)) ?? Capabilities()
        transcription = try? container.decodeIfPresent(TranscriptionCapabilities.self, forKey: .transcription)
    }
}

// MARK: - Catalog Models

/// A transcription model the plugin offers, with what Mistral reports it can do.
struct MistralTranscriptionModel: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    /// Other IDs Mistral accepts for the same model.
    let aliases: [String]
    /// ISO 639-1 codes the model accepts as `language`.
    let languages: [String]
    let supportsContextBias: Bool
    let supportsDiarization: Bool

    var modelInfo: PluginModelInfo { PluginModelInfo(id: id, displayName: displayName) }
}

/// A chat model the plugin offers.
struct MistralLLMModel: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let aliases: [String]
    let supportsReasoning: Bool

    var modelInfo: PluginModelInfo { PluginModelInfo(id: id, displayName: displayName) }
}

/// The models the plugin offers: from the account's model list once fetched,
/// otherwise the built-in list below.
struct MistralModelCatalog: Codable, Equatable, Sendable {
    /// File transcription models (`/v1/audio/transcriptions`), default first.
    let transcriptionModels: [MistralTranscriptionModel]
    /// Models for live sessions over the realtime WebSocket, newest first.
    let realtimeModels: [MistralTranscriptionModel]
    /// Chat models for prompts and workflows, most capable first.
    let llmModels: [MistralLLMModel]

    // MARK: Built-in IDs

    static let defaultTranscriptionModelId = "voxtral-mini-transcribe-3-0"
    static let smallTranscriptionModelId = "voxtral-small-transcribe-3-0"
    static let defaultRealtimeModelId = "voxtral-mini-transcribe-realtime-3-0"
    static let defaultLLMModelId = "mistral-small-2603"
    static let largeLLMModelId = "mistral-large-4"
    static let mediumLLMModelId = "mistral-medium-2604"
    static let ministral14bModelId = "ministral-14b-2512"
    static let ministral8bModelId = "ministral-8b-2512"
    static let ministral3bModelId = "ministral-3b-2512"

    /// The 58 languages Mistral lists for Transcribe 3 and Realtime 3 (November 2026).
    static let transcribe3Languages = [
        "ar", "en", "de", "es", "fr", "hi", "it", "nl", "pt", "zh", "ru", "ko", "ja",
        "id", "tr", "vi", "sv", "pl", "th", "tl", "no", "da", "hu", "cs", "uk", "ro",
        "ms", "ca", "el", "sk", "fi", "lv", "km", "pa", "ta", "my", "bg", "mr", "ur",
        "et", "te", "gu", "kn", "fa", "sl", "ml", "is", "bn", "hr", "mk", "eu", "sr",
        "ps", "lb", "ga", "or", "lt", "mt",
    ]

    /// Names for the models this plugin knows; the list order is the picker order.
    /// Other models use the name Mistral reports.
    static let knownDisplayNames: [(id: String, name: String)] = [
        (defaultTranscriptionModelId, "Voxtral Mini Transcribe 3"),
        (smallTranscriptionModelId, "Voxtral Small Transcribe 3"),
        (defaultRealtimeModelId, "Voxtral Mini Transcribe Realtime 3"),
        (largeLLMModelId, "Mistral Large 4"),
        (mediumLLMModelId, "Mistral Medium 3.5"),
        (defaultLLMModelId, "Mistral Small 4"),
        (ministral14bModelId, "Ministral 3 14B"),
        (ministral8bModelId, "Ministral 3 8B"),
        (ministral3bModelId, "Ministral 3 3B"),
    ]

    /// Used until the account's list is fetched, and when fetching fails.
    static let builtIn = MistralModelCatalog(
        transcriptionModels: [
            MistralTranscriptionModel(
                id: defaultTranscriptionModelId,
                displayName: "Voxtral Mini Transcribe 3",
                aliases: ["voxtral-mini-transcribe-3"],
                languages: transcribe3Languages,
                supportsContextBias: true,
                supportsDiarization: true
            ),
            MistralTranscriptionModel(
                id: smallTranscriptionModelId,
                displayName: "Voxtral Small Transcribe 3",
                aliases: ["voxtral-small-transcribe-3"],
                languages: transcribe3Languages,
                supportsContextBias: true,
                supportsDiarization: true
            ),
        ],
        realtimeModels: [
            MistralTranscriptionModel(
                id: defaultRealtimeModelId,
                displayName: "Voxtral Mini Transcribe Realtime 3",
                aliases: ["voxtral-mini-transcribe-realtime-3"],
                languages: transcribe3Languages,
                supportsContextBias: true,
                supportsDiarization: true
            ),
        ],
        llmModels: [
            MistralLLMModel(id: largeLLMModelId, displayName: "Mistral Large 4", aliases: ["mistral-large-4-0"], supportsReasoning: true),
            MistralLLMModel(id: defaultLLMModelId, displayName: "Mistral Small 4", aliases: ["mistral-small-latest"], supportsReasoning: true),
            MistralLLMModel(id: ministral14bModelId, displayName: "Ministral 3 14B", aliases: ["ministral-14b-latest"], supportsReasoning: false),
            MistralLLMModel(id: ministral8bModelId, displayName: "Ministral 3 8B", aliases: ["ministral-8b-latest"], supportsReasoning: false),
            MistralLLMModel(id: ministral3bModelId, displayName: "Ministral 3 3B", aliases: ["ministral-3b-latest"], supportsReasoning: false),
        ]
    )

    // MARK: Retired IDs

    /// Retired chat IDs the plugin used to save, plus the dated models the catalog
    /// lists as their predecessors. `mistral-small-latest` and `ministral-*-latest`
    /// are also current aliases; saving the dated ID keeps the picker selection stable.
    static let llmModelMigrations: [String: String] = [
        "mistral-large-latest": largeLLMModelId,
        "mistral-large-2512": largeLLMModelId,
        "mistral-large-2411": largeLLMModelId,
        "mistral-large-2407": largeLLMModelId,
        "mistral-large-2402": largeLLMModelId,
        "mistral-large-4-0": largeLLMModelId,
        "mistral-small-latest": defaultLLMModelId,
        "mistral-small-2506": defaultLLMModelId,
        "mistral-small-2503": defaultLLMModelId,
        "mistral-small-2501": defaultLLMModelId,
        "mistral-small-2409": defaultLLMModelId,
        "mistral-small-2402": defaultLLMModelId,
        "pixtral-12b-2409": ministral14bModelId,
        "pixtral-large-2411": ministral14bModelId,
        "pixtral-large-latest": ministral14bModelId,
        "ministral-14b-latest": ministral14bModelId,
        "ministral-8b-latest": ministral8bModelId,
        "ministral-8b-2410": ministral8bModelId,
        "ministral-3b-latest": ministral3bModelId,
        "ministral-3b-2410": ministral3bModelId,
    ]

    /// Persisted Voxtral 2 transcription IDs, plus the short Transcribe 3 aliases.
    /// `voxtral-mini-latest` pointed at Voxtral Mini Transcribe 2
    /// (`voxtral-mini-2602`). `voxtral-small-latest` was sent through chat
    /// completions because that endpoint did not serve Small; its Voxtral 2
    /// model is `voxtral-small-2507`.
    static let transcriptionModelMigrations: [String: String] = [
        "voxtral-mini-latest": defaultTranscriptionModelId,
        "voxtral-mini-2602": defaultTranscriptionModelId,
        "voxtral-mini-transcribe-3": defaultTranscriptionModelId,
        "voxtral-mini-transcribe-latest": defaultTranscriptionModelId,
        "voxtral-small-latest": smallTranscriptionModelId,
        "voxtral-small-2507": smallTranscriptionModelId,
        "voxtral-small-transcribe-3": smallTranscriptionModelId,
        "voxtral-small-transcribe-latest": smallTranscriptionModelId,
    ]

    /// Realtime 2 takes neither `language` nor `context_bias`, so the list hides it
    /// next to Realtime 3.
    static let realtimeModelMigrations: [String: String] = [
        "voxtral-mini-transcribe-realtime-2602": defaultRealtimeModelId,
        "voxtral-mini-realtime-2602": defaultRealtimeModelId,
        "voxtral-mini-realtime-latest": defaultRealtimeModelId,
        "voxtral-mini-transcribe-realtime-3": defaultRealtimeModelId,
    ]

    // MARK: Building From The Model List

    /// Builds the catalog from `GET /v1/models`: one entry per model instead of one
    /// per alias, without retired models, models with a replacement in this
    /// catalog, and chat models meant for code, OCR, moderation or audio input.
    /// Lists that come out empty keep the built-in models.
    static func from(entries: [MistralCatalogEntry], now: Date = Date()) -> MistralModelCatalog {
        let groups = groupedByModel(entries.filter { !isRetired($0, now: now) })

        var transcription: [MistralTranscriptionModel] = []
        var realtime: [MistralTranscriptionModel] = []
        var llm: [MistralLLMModel] = []

        for group in groups {
            let ids = group.ids
            let entry = group.entry
            if entry.capabilities.audioTranscription || entry.capabilities.audioTranscriptionRealtime {
                let modes = Set(entry.transcription?.modes ?? [])
                let isRealtime = modes.contains("realtime") || (modes.isEmpty && entry.capabilities.audioTranscriptionRealtime)
                let isOffline = modes.contains("offline") || (modes.isEmpty && entry.capabilities.audioTranscription)
                let migrations = isRealtime ? realtimeModelMigrations : transcriptionModelMigrations
                guard !isSuperseded(ids, migrations: migrations) else { continue }
                let id = canonicalId(of: group)
                let model = MistralTranscriptionModel(
                    id: id,
                    displayName: displayName(forId: id, entry: entry, isChatModel: false),
                    aliases: ids.filter { $0 != id }.sorted(),
                    languages: entry.transcription?.languages.isEmpty == false
                        ? entry.transcription?.languages ?? []
                        : transcribe3Languages,
                    supportsContextBias: entry.transcription?.contextBias ?? true,
                    supportsDiarization: entry.transcription?.diarization ?? false
                )
                if isRealtime { realtime.append(model) }
                if isOffline { transcription.append(model) }
                continue
            }

            guard isOfferedChatModel(group) else { continue }
            guard !isSuperseded(ids, migrations: llmModelMigrations) else { continue }
            let id = canonicalId(of: group)
            llm.append(MistralLLMModel(
                id: id,
                displayName: displayName(forId: id, entry: entry, isChatModel: true),
                aliases: ids.filter { $0 != id }.sorted(),
                supportsReasoning: entry.capabilities.reasoning
            ))
        }

        return MistralModelCatalog(
            transcriptionModels: transcription.isEmpty ? builtIn.transcriptionModels : sorted(transcription),
            realtimeModels: realtime.isEmpty ? builtIn.realtimeModels : sorted(realtime),
            llmModels: llm.isEmpty ? builtIn.llmModels : sorted(llm)
        )
    }

    private struct Group {
        let entry: MistralCatalogEntry
        let ids: Set<String>
    }

    /// Entries that name each other as aliases describe one model.
    private static func groupedByModel(_ entries: [MistralCatalogEntry]) -> [Group] {
        var groups: [Group] = []
        var groupIndexById: [String: Int] = [:]
        for entry in entries {
            let ids = Set([entry.id] + entry.aliases)
            if let index = ids.lazy.compactMap({ groupIndexById[$0] }).first {
                let merged = groups[index].ids.union(ids)
                groups[index] = Group(entry: groups[index].entry, ids: merged)
                for id in merged { groupIndexById[id] = index }
            } else {
                groups.append(Group(entry: entry, ids: ids))
                for id in ids { groupIndexById[id] = groups.count - 1 }
            }
        }
        return groups
    }

    /// A dated, fixed ID rather than a `-latest` alias that moves to newer models:
    /// a built-in ID if the model has one, otherwise the ID with a date or version,
    /// otherwise the one Mistral calls the model by.
    private static func canonicalId(of group: Group) -> String {
        if let known = knownDisplayNames.first(where: { group.ids.contains($0.id) }) {
            return known.id
        }
        let fixed = group.ids.filter { !$0.hasSuffix("-latest") }
        let dated = fixed.filter { $0.range(of: #"-\d{4}$"#, options: .regularExpression) != nil }
        if let id = dated.sorted().last {
            return id
        }
        if let name = group.entry.name, fixed.contains(name) {
            return name
        }
        return fixed.sorted { ($0.count, $0) > ($1.count, $1) }.first ?? group.entry.id
    }

    /// A model whose IDs include one this plugin replaces with another model.
    private static func isSuperseded(_ ids: Set<String>, migrations: [String: String]) -> Bool {
        ids.contains { id in
            guard let replacement = migrations[id] else { return false }
            return !ids.contains(replacement)
        }
    }

    private static func isRetired(_ entry: MistralCatalogEntry, now: Date) -> Bool {
        guard let deprecation = entry.deprecation, !deprecation.isEmpty else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let date = formatter.date(from: String(deprecation.prefix(10)))
        return date.map { $0 <= now } ?? false
    }

    private static func isOfferedChatModel(_ group: Group) -> Bool {
        let capabilities = group.entry.capabilities
        guard capabilities.completionChat,
              !capabilities.audio,
              !capabilities.ocr,
              !capabilities.moderation,
              !capabilities.completionFim,
              !capabilities.classification else {
            return false
        }
        let excludedPrefixes = ["labs-", "codestral", "devstral"]
        return !group.ids.contains { id in excludedPrefixes.contains { id.hasPrefix($0) } }
    }

    private static func displayName(forId id: String, entry: MistralCatalogEntry, isChatModel: Bool) -> String {
        if let known = knownDisplayNames.first(where: { $0.id == id }) {
            return known.name
        }
        if !isChatModel, let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        // Chat models carry their ID as `name`; a short description is the readable name.
        if let description = entry.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty, description.count <= 40, !description.contains(",") {
            return description.hasSuffix(".") ? String(description.dropLast()) : description
        }
        return id
    }

    /// Built-in models in their order first, then the others by name.
    private static func sorted<Model>(_ models: [Model]) -> [Model] where Model: MistralCatalogModel {
        models.sorted { lhs, rhs in
            let lhsIndex = knownDisplayNames.firstIndex { $0.id == lhs.id }
            let rhsIndex = knownDisplayNames.firstIndex { $0.id == rhs.id }
            switch (lhsIndex, rhsIndex) {
            case let (lhs?, rhs?): return lhs < rhs
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    // MARK: Lookup

    /// The catalog's ID for `modelId`: a retired ID becomes its replacement and an
    /// alias the model's own ID. Empty input is "no selection".
    func resolvedTranscriptionModelId(_ modelId: String) -> String? {
        Self.resolvedId(modelId, migrations: Self.transcriptionModelMigrations, models: transcriptionModels)
    }

    func resolvedLLMModelId(_ modelId: String) -> String? {
        Self.resolvedId(modelId, migrations: Self.llmModelMigrations, models: llmModels)
    }

    private static func resolvedId<Model: MistralCatalogModel>(
        _ modelId: String,
        migrations: [String: String],
        models: [Model]
    ) -> String? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let model = models.first(where: { $0.id == trimmed || $0.aliases.contains(trimmed) }) {
            return model.id
        }
        return migrations[trimmed] ?? trimmed
    }

    func transcriptionModel(_ modelId: String?) -> MistralTranscriptionModel? {
        guard let modelId else { return nil }
        return transcriptionModels.first { $0.id == modelId || $0.aliases.contains(modelId) }
    }

    func llmModel(_ modelId: String?) -> MistralLLMModel? {
        guard let modelId else { return nil }
        return llmModels.first { $0.id == modelId || $0.aliases.contains(modelId) }
    }
}

/// What the catalog's sorting and lookup need from both model kinds.
protocol MistralCatalogModel {
    var id: String { get }
    var displayName: String { get }
    var aliases: [String] { get }
}

extension MistralTranscriptionModel: MistralCatalogModel {}
extension MistralLLMModel: MistralCatalogModel {}

// MARK: - Reasoning Effort

/// The `reasoning_effort` values a chat model accepts. Mistral documents them per
/// model, and the model list only says whether a model reasons at all.
enum MistralReasoningEffort {
    /// Mistral Large 4 accepts `low`, `medium` and `high`, not `none`, and always
    /// returns a thinking chunk before the text.
    static let largeEfforts = ["low", "medium", "high"]
    /// Mistral Small 4 and Medium 3.5: `none` skips the thinking chunk.
    static let switchableEfforts = ["none", "high"]

    static func supportedEfforts(forModelId modelId: String) -> [String] {
        if modelId.hasPrefix("mistral-large-4") {
            return largeEfforts
        }
        if modelId.hasPrefix("mistral-small-2603") || modelId.hasPrefix("mistral-medium-") {
            return switchableEfforts
        }
        // Ministral 3 rejects the field ("reasoning_effort is not enabled for this
        // model"); other models keep Mistral's own default.
        return []
    }

    /// The fastest level, which suits dictation cleanup. Requests without an
    /// explicit effort use it.
    static func defaultEffort(forModelId modelId: String) -> String? {
        supportedEfforts(forModelId: modelId).first
    }
}
