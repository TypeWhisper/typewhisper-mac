import Foundation
import SwiftUI
import TypeWhisperPluginSDK

protocol OpenAICompatibleRealtimeSessionConnecting: Sendable {
    func connect(
        request: URLRequest,
        configuration: PluginOpenAIRealtimeTranscriptionConfiguration,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession
}

private struct DefaultOpenAICompatibleRealtimeSessionConnector: OpenAICompatibleRealtimeSessionConnecting {
    func connect(
        request: URLRequest,
        configuration: PluginOpenAIRealtimeTranscriptionConfiguration,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await PluginOpenAIRealtimeTranscriptionSession.connect(
            request: request,
            configuration: configuration,
            onProgress: onProgress
        )
    }
}

// MARK: - Transcription Transport

/// Per-profile transport selection for transcription requests.
///
/// `auto` keeps existing batch behavior for every model except a small set of
/// known realtime-only model IDs (see `OpenAICompatibleRealtimeModel`), which
/// is the safe default for profiles migrated from before realtime support
/// existed. `batch` and `realtime` let a user force one transport regardless
/// of the selected model name, which is required for custom Azure/BYO
/// deployment aliases that don't match the well-known IDs.
enum OpenAICompatibleTranscriptTransport: String, Codable, CaseIterable, Sendable {
    case auto
    case batch
    case realtime

    var displayName: String {
        switch self {
        case .auto:
            "Auto"
        case .batch:
            "Batch"
        case .realtime:
            "Realtime"
        }
    }
}

/// Resolved (non-`auto`) transport for a single transcription request.
enum OpenAICompatibleResolvedTranscriptionTransport: Sendable, Equatable {
    case batch
    case realtime
}

/// Per-profile URL shape for batch transcription. Standard OpenAI-compatible
/// servers use `/v1/audio/...`; some providers require a deployment-scoped route.
enum OpenAICompatibleBatchEndpoint: String, Codable, CaseIterable, Sendable {
    case standard
    case deploymentScoped = "deployment-scoped"
}

/// Per-profile LLM endpoint selection. Chat Completions remains the default so
/// profiles created before Responses API support keep their existing behavior.
enum OpenAICompatibleLLMAPI: String, Codable, CaseIterable, Sendable {
    case chatCompletions = "chat-completions"
    case responses

    var displayName: String {
        switch self {
        case .chatCompletions:
            "Chat Completions"
        case .responses:
            "Responses"
        }
    }

    var path: String {
        switch self {
        case .chatCompletions:
            "/v1/chat/completions"
        case .responses:
            "/v1/responses"
        }
    }
}

enum OpenAICompatibleReasoningEffort: String, Codable, CaseIterable, Sendable {
    case providerDefault = ""
    case low
    case medium
    case high
    case xhigh
    case max

    var displayName: String {
        switch self {
        case .providerDefault:
            "Provider Default"
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        case .xhigh:
            "X High"
        case .max:
            "Max"
        }
    }

    var requestValue: String? {
        self == .providerDefault ? nil : rawValue
    }
}

/// Knowledge about the well-known OpenAI/Azure realtime transcription model
/// IDs, mirroring the classification `OpenAIPlugin` uses for `gpt-live-transcribe`
/// (context-aware) and `gpt-realtime-whisper` (legacy). Custom Azure/Foundry
/// deployment aliases won't match these names, so callers must opt in
/// explicitly via `OpenAICompatibleTranscriptTransport.realtime`.
enum OpenAICompatibleRealtimeModel {
    static let contextAwareModelID = "gpt-live-transcribe"
    static let legacyModelID = "gpt-realtime-whisper"
    static let knownRealtimeModelIDs: Set<String> = [contextAwareModelID, legacyModelID]

    static func isKnownRealtimeModelID(_ modelId: String) -> Bool {
        knownRealtimeModelIDs.contains(normalized(modelId))
    }

    /// Custom Azure/BYO deployment aliases are assumed to use the modern,
    /// context-aware realtime transcription protocol (languages/keywords/delay)
    /// unless the alias itself signals the legacy Whisper-based protocol by
    /// containing "whisper", matching Azure's own `gpt-realtime-whisper` name.
    static func usesContextAwareRealtimeHints(modelId: String) -> Bool {
        !normalized(modelId).contains("whisper")
    }

    private static func normalized(_ modelId: String) -> String {
        modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Profile Model

struct OpenAICompatibleProfile: Codable, Equatable, Identifiable, Sendable {
    static let defaultId = "openai-compatible"
    static let defaultName = "OpenAI Compatible"

    var id: String
    var name: String
    var baseURL: String
    var apiVersion: String
    var selectedModelId: String
    var selectedLLMModelId: String
    var llmTemperatureModeRaw: String
    var llmTemperatureValue: Double
    var fetchedModels: [FetchedModel]
    var chatRequestTimeoutSeconds: TimeInterval?
    var thinkingEnabled: Bool
    var transcriptionTransportRaw: String
    var batchEndpointRaw: String
    var llmAPIModeRaw: String
    var reasoningEffortRaw: String

    static let defaultChatRequestTimeout: TimeInterval = 30
    static let minChatRequestTimeout: TimeInterval = 5
    static let maxChatRequestTimeout: TimeInterval = 3600

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case apiVersion
        case selectedModelId
        case selectedLLMModelId
        case llmTemperatureModeRaw
        case llmTemperatureValue
        case fetchedModels
        case chatRequestTimeoutSeconds
        case thinkingEnabled
        case transcriptionTransportRaw
        case batchEndpointRaw
        case llmAPIModeRaw
        case reasoningEffortRaw
    }

    init(
        id: String,
        name: String,
        baseURL: String = "",
        apiVersion: String = "",
        selectedModelId: String = "",
        selectedLLMModelId: String = "",
        llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue,
        llmTemperatureValue: Double = 0.3,
        fetchedModels: [FetchedModel] = [],
        chatRequestTimeoutSeconds: TimeInterval? = nil,
        thinkingEnabled: Bool = false,
        transcriptionTransportRaw: String = OpenAICompatibleTranscriptTransport.auto.rawValue,
        batchEndpointRaw: String = OpenAICompatibleBatchEndpoint.standard.rawValue,
        llmAPIModeRaw: String = OpenAICompatibleLLMAPI.chatCompletions.rawValue,
        reasoningEffortRaw: String = OpenAICompatibleReasoningEffort.providerDefault.rawValue
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.selectedModelId = selectedModelId
        self.selectedLLMModelId = selectedLLMModelId
        self.llmTemperatureModeRaw = llmTemperatureModeRaw
        self.llmTemperatureValue = llmTemperatureValue
        self.fetchedModels = fetchedModels
        self.chatRequestTimeoutSeconds = chatRequestTimeoutSeconds
        self.thinkingEnabled = thinkingEnabled
        self.transcriptionTransportRaw = transcriptionTransportRaw
        self.batchEndpointRaw = batchEndpointRaw
        self.llmAPIModeRaw = llmAPIModeRaw
        self.reasoningEffortRaw = reasoningEffortRaw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion) ?? ""
        selectedModelId = try container.decode(String.self, forKey: .selectedModelId)
        selectedLLMModelId = try container.decode(String.self, forKey: .selectedLLMModelId)
        llmTemperatureModeRaw = try container.decode(String.self, forKey: .llmTemperatureModeRaw)
        llmTemperatureValue = try container.decode(Double.self, forKey: .llmTemperatureValue)
        fetchedModels = try container.decode([FetchedModel].self, forKey: .fetchedModels)
        chatRequestTimeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .chatRequestTimeoutSeconds)
        thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
        // Profiles saved before realtime support existed have no stored value;
        // default to `auto` so previously-working batch models keep working
        // and only the known realtime model IDs switch transport.
        transcriptionTransportRaw = try container.decodeIfPresent(String.self, forKey: .transcriptionTransportRaw)
            ?? OpenAICompatibleTranscriptTransport.auto.rawValue
        batchEndpointRaw = try container.decodeIfPresent(String.self, forKey: .batchEndpointRaw)
            ?? OpenAICompatibleBatchEndpoint.standard.rawValue
        // Profiles saved before Responses API support always used Chat Completions.
        llmAPIModeRaw = try container.decodeIfPresent(String.self, forKey: .llmAPIModeRaw)
            ?? OpenAICompatibleLLMAPI.chatCompletions.rawValue
        reasoningEffortRaw = try container.decodeIfPresent(String.self, forKey: .reasoningEffortRaw)
            ?? OpenAICompatibleReasoningEffort.providerDefault.rawValue
    }

    var isDefault: Bool { id == Self.defaultId }

    var resolvedChatRequestTimeout: TimeInterval {
        guard let seconds = chatRequestTimeoutSeconds, seconds.isFinite else {
            return Self.defaultChatRequestTimeout
        }
        return min(max(seconds, Self.minChatRequestTimeout), Self.maxChatRequestTimeout)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultName : trimmed
    }

    var transcriptionTransport: OpenAICompatibleTranscriptTransport {
        OpenAICompatibleTranscriptTransport(rawValue: transcriptionTransportRaw) ?? .auto
    }

    var batchEndpoint: OpenAICompatibleBatchEndpoint {
        OpenAICompatibleBatchEndpoint(rawValue: batchEndpointRaw) ?? .standard
    }

    var llmAPI: OpenAICompatibleLLMAPI {
        OpenAICompatibleLLMAPI(rawValue: llmAPIModeRaw) ?? .chatCompletions
    }

    var reasoningEffort: OpenAICompatibleReasoningEffort {
        OpenAICompatibleReasoningEffort(rawValue: reasoningEffortRaw) ?? .providerDefault
    }

    /// Resolves the effective (non-`auto`) transport for the currently
    /// selected transcription model.
    func resolvedTranscriptionTransport() -> OpenAICompatibleResolvedTranscriptionTransport {
        switch transcriptionTransport {
        case .batch:
            .batch
        case .realtime:
            .realtime
        case .auto:
            OpenAICompatibleRealtimeModel.isKnownRealtimeModelID(selectedModelId) ? .realtime : .batch
        }
    }

    static func defaultProfile(
        baseURL: String = "",
        apiVersion: String = "",
        selectedModelId: String = "",
        selectedLLMModelId: String = "",
        llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue,
        llmTemperatureValue: Double = 0.3,
        fetchedModels: [FetchedModel] = [],
        chatRequestTimeoutSeconds: TimeInterval? = nil,
        thinkingEnabled: Bool = false,
        transcriptionTransportRaw: String = OpenAICompatibleTranscriptTransport.auto.rawValue,
        batchEndpointRaw: String = OpenAICompatibleBatchEndpoint.standard.rawValue,
        llmAPIModeRaw: String = OpenAICompatibleLLMAPI.chatCompletions.rawValue,
        reasoningEffortRaw: String = OpenAICompatibleReasoningEffort.providerDefault.rawValue
    ) -> OpenAICompatibleProfile {
        OpenAICompatibleProfile(
            id: defaultId,
            name: defaultName,
            baseURL: baseURL,
            apiVersion: apiVersion,
            selectedModelId: selectedModelId,
            selectedLLMModelId: selectedLLMModelId,
            llmTemperatureModeRaw: llmTemperatureModeRaw,
            llmTemperatureValue: llmTemperatureValue,
            fetchedModels: fetchedModels,
            chatRequestTimeoutSeconds: chatRequestTimeoutSeconds,
            thinkingEnabled: thinkingEnabled,
            transcriptionTransportRaw: transcriptionTransportRaw,
            batchEndpointRaw: batchEndpointRaw,
            llmAPIModeRaw: llmAPIModeRaw,
            reasoningEffortRaw: reasoningEffortRaw
        )
    }
}

// MARK: - Plugin Entry Point

@objc(OpenAICompatiblePlugin)
final class OpenAICompatiblePlugin: NSObject,
    TranscriptionEnginePlugin,
    DictionaryTermsCapabilityProviding,
    LLMProviderPlugin,
    LLMProviderIdentityProviding,
    LLMTemperatureControllableProvider,
    LLMModelSelectable,
    AdditionalTranscriptionEnginesProviding,
    AdditionalLLMProvidersProviding,
    LiveLanguageHintDictionaryTermHintTranscriptionCapablePlugin,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.openai-compatible"
    static let pluginName = "OpenAI Compatible"

    fileprivate var host: HostServices?
    fileprivate private(set) var profiles: [OpenAICompatibleProfile] = [
        .defaultProfile()
    ]
    private static let profilesKey = "profiles"
    private static let legacyProviderName = "OpenAI Compatible"
    private static let transcriptionRequestTimeout: TimeInterval = 600
    private static let realtimeAudioChunkSampleCount = 16_000
    var realtimeSessionConnector: any OpenAICompatibleRealtimeSessionConnecting =
        DefaultOpenAICompatibleRealtimeSessionConnector()

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        profiles = loadProfiles(from: host)
        persistProfiles(notify: false)
    }

    func deactivate() {
        host = nil
    }

    // MARK: - Role Expansion

    var additionalTranscriptionEngines: [any TranscriptionEnginePlugin] {
        profiles
            .filter { !$0.isDefault }
            .map { OpenAICompatibleProfileRole(plugin: self, profileId: $0.id) }
    }

    var additionalLLMProviders: [any LLMProviderPlugin] {
        profiles
            .filter { !$0.isDefault }
            .map { OpenAICompatibleProfileRole(plugin: self, profileId: $0.id) }
    }

    // MARK: - Default TranscriptionEnginePlugin

    var providerId: String { OpenAICompatibleProfile.defaultId }
    var providerDisplayName: String { displayName(for: providerId) }

    var isConfigured: Bool {
        isConfigured(for: providerId)
    }

    var transcriptionModels: [PluginModelInfo] {
        transcriptionModels(for: providerId)
    }

    var selectedModelId: String? {
        selectedModelId(for: providerId)
    }

    func selectModel(_ modelId: String) {
        selectModel(modelId, for: providerId)
    }

    var supportsTranslation: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }

    var supportedLanguages: [String] {
        [
            "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
            "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
            "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
            "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
            "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
            "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
            "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
            "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
            "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
            "tr", "tt", "uk", "ur", "uz", "vi", "vo", "yi", "yo", "yue",
            "zh",
        ]
    }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        try await transcribe(
            audio: audio,
            language: language,
            translate: translate,
            prompt: prompt,
            profileId: providerId
        )
    }

    var supportsStreaming: Bool {
        supportsStreaming(for: providerId)
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: PluginLanguageSelection(requestedLanguage: language),
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: [],
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: languageSelection,
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: [],
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: PluginLanguageSelection(requestedLanguage: language),
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: languageSelection,
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            onProgress: onProgress,
            profileId: providerId
        )
    }

    // MARK: - Default LLMProviderPlugin

    var providerName: String { providerDisplayName }
    var providerLegacyAliases: [String] { [Self.legacyProviderName] }
    var isAvailable: Bool { isConfigured }

    var supportedModels: [PluginModelInfo] {
        supportedModels(for: providerId)
    }

    var preferredModelId: String? {
        selectedLLMModelId(for: providerId)
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: .inheritProviderSetting
        )
    }

    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: temperatureDirective,
            profileId: providerId
        )
    }

    func selectLLMModel(_ modelId: String) {
        selectLLMModel(modelId, for: providerId)
    }

    var selectedLLMModelId: String? { selectedLLMModelId(for: providerId) }
    var llmTemperatureMode: PluginLLMTemperatureMode {
        llmTemperatureMode(for: providerId)
    }
    var llmTemperatureValue: Double {
        profile(for: providerId)?.llmTemperatureValue ?? 0.3
    }

    func setLLMTemperatureMode(_ mode: PluginLLMTemperatureMode) {
        setLLMTemperatureMode(mode, for: providerId)
    }

    func setLLMTemperatureValue(_ value: Double) {
        setLLMTemperatureValue(value, for: providerId)
    }

    func setThinkingEnabled(_ enabled: Bool) {
        setThinkingEnabled(enabled, for: providerId)
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(OpenAICompatibleSettingsView(plugin: self))
    }

    // MARK: - Profile Management

    var profileSnapshots: [OpenAICompatibleProfile] {
        profiles
    }

    func profileSnapshot(for profileId: String) -> OpenAICompatibleProfile? {
        profile(for: profileId)
    }

    @discardableResult
    func addProfile(named requestedName: String? = nil) -> OpenAICompatibleProfile {
        let profile = OpenAICompatibleProfile(
            id: "openai-compatible:\(UUID().uuidString.lowercased())",
            name: uniqueProfileName(requestedName ?? "Custom Server")
        )
        profiles.append(profile)
        persistProfiles()
        return profile
    }

    func renameProfile(_ profileId: String, to name: String) {
        updateProfile(profileId) { profile in
            profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func deleteProfile(_ profileId: String) {
        guard profileId != OpenAICompatibleProfile.defaultId,
              let index = profiles.firstIndex(where: { $0.id == profileId }) else { return }

        profiles.remove(at: index)
        removeApiKey(for: profileId)
        persistProfiles()
    }

    func setBaseURL(_ url: String) {
        setBaseURL(url, for: OpenAICompatibleProfile.defaultId)
    }

    func setBaseURL(_ url: String, for profileId: String) {
        updateProfile(profileId) { profile in
            profile.baseURL = Self.normalizedBaseURL(url)
        }
    }

    func setApiVersion(_ apiVersion: String, for profileId: String) {
        updateProfile(profileId) { profile in
            profile.apiVersion = Self.normalizedAPIVersion(apiVersion)
        }
    }

    func setApiKey(_ key: String) {
        setApiKey(key, for: OpenAICompatibleProfile.defaultId)
    }

    func setApiKey(_ key: String, for profileId: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host else { return }

        do {
            try host.storeSecret(key: secretKey(for: profileId), value: trimmed)
        } catch {
            print("[OpenAICompatiblePlugin] Failed to store API key: \(error)")
        }
        host.notifyCapabilitiesChanged()
    }

    func removeApiKey() {
        removeApiKey(for: OpenAICompatibleProfile.defaultId)
    }

    func removeApiKey(for profileId: String) {
        guard let host else { return }

        do {
            try host.storeSecret(key: secretKey(for: profileId), value: "")
        } catch {
            print("[OpenAICompatiblePlugin] Failed to delete API key: \(error)")
        }
        host.notifyCapabilitiesChanged()
    }

    func hasApiKey(for profileId: String) -> Bool {
        let key = apiKey(for: profileId)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false
    }

    func setFetchedModels(_ models: [FetchedModel]) {
        setFetchedModels(models, for: OpenAICompatibleProfile.defaultId)
    }

    func setFetchedModels(_ models: [FetchedModel], for profileId: String) {
        updateProfile(profileId) { profile in
            profile.fetchedModels = models
        }
    }

    func selectModel(_ modelId: String, for profileId: String) {
        updateProfile(profileId) { profile in
            profile.selectedModelId = modelId
        }
    }

    func selectLLMModel(_ modelId: String, for profileId: String) {
        updateProfile(profileId) { profile in
            profile.selectedLLMModelId = modelId
        }
    }

    func setLLMTemperatureMode(_ mode: PluginLLMTemperatureMode, for profileId: String) {
        updateProfile(profileId) { profile in
            profile.llmTemperatureModeRaw = mode.rawValue
        }
    }

    func setLLMTemperatureValue(_ value: Double, for profileId: String) {
        let clamped = min(max(value, 0.0), 2.0)
        updateProfile(profileId) { profile in
            profile.llmTemperatureValue = clamped
        }
    }

    func setChatRequestTimeout(_ seconds: Double, for profileId: String) {
        guard seconds.isFinite else { return }
        let clamped = min(
            max(seconds.rounded(), OpenAICompatibleProfile.minChatRequestTimeout),
            OpenAICompatibleProfile.maxChatRequestTimeout
        )
        updateProfile(profileId) { profile in
            profile.chatRequestTimeoutSeconds = clamped
        }
    }

    func setThinkingEnabled(_ enabled: Bool, for profileId: String) {
        updateProfile(profileId) { profile in
            profile.thinkingEnabled = enabled
        }
    }

    func setLLMAPI(_ api: OpenAICompatibleLLMAPI, for profileId: String) {
        updateProfile(profileId) { profile in
            profile.llmAPIModeRaw = api.rawValue
        }
    }

    func setReasoningEffort(_ effort: OpenAICompatibleReasoningEffort, for profileId: String) {
        updateProfile(profileId) { profile in
            profile.reasoningEffortRaw = effort.rawValue
        }
    }

    // MARK: - Profile Runtime

    func displayName(for profileId: String) -> String {
        profile(for: profileId)?.displayName ?? profileId
    }

    func isConfigured(for profileId: String) -> Bool {
        guard let profile = profile(for: profileId) else { return false }
        return !profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func transcriptionModels(for profileId: String) -> [PluginModelInfo] {
        guard let profile = profile(for: profileId) else { return [] }
        let models = profile.fetchedModels.map { PluginModelInfo(id: $0.id, displayName: $0.id) }
        if models.isEmpty, !profile.selectedModelId.isEmpty {
            return [PluginModelInfo(id: profile.selectedModelId, displayName: profile.selectedModelId)]
        }
        return models
    }

    func selectedModelId(for profileId: String) -> String? {
        let selected = profile(for: profileId)?.selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected?.isEmpty == false ? selected : nil
    }

    func supportedModels(for profileId: String) -> [PluginModelInfo] {
        guard let profile = profile(for: profileId) else { return [] }
        let models = profile.fetchedModels.map { PluginModelInfo(id: $0.id, displayName: $0.id) }
        if models.isEmpty, !profile.selectedLLMModelId.isEmpty {
            return [PluginModelInfo(id: profile.selectedLLMModelId, displayName: profile.selectedLLMModelId)]
        }
        return models
    }

    func selectedLLMModelId(for profileId: String) -> String? {
        let selected = profile(for: profileId)?.selectedLLMModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected?.isEmpty == false ? selected : nil
    }

    func llmTemperatureMode(for profileId: String) -> PluginLLMTemperatureMode {
        guard let raw = profile(for: profileId)?.llmTemperatureModeRaw else {
            return .providerDefault
        }
        return PluginLLMTemperatureMode(rawValue: raw) ?? .providerDefault
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        profileId: String
    ) async throws -> PluginTranscriptionResult {
        guard let profile = profile(for: profileId), !profile.baseURL.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        let modelId = profile.selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelId.isEmpty else {
            throw PluginTranscriptionError.noModelSelected
        }

        if profile.resolvedTranscriptionTransport() == .realtime {
            let session = try await createLiveTranscriptionSession(
                languageSelection: PluginLanguageSelection(requestedLanguage: language),
                translate: translate,
                prompt: prompt,
                dictionaryTermHints: [],
                onProgress: { _ in true },
                profileId: profileId
            )
            do {
                for startIndex in stride(
                    from: audio.samples.startIndex,
                    to: audio.samples.endIndex,
                    by: Self.realtimeAudioChunkSampleCount
                ) {
                    let endIndex = min(startIndex + Self.realtimeAudioChunkSampleCount, audio.samples.endIndex)
                    try await session.appendAudio(samples: Array(audio.samples[startIndex..<endIndex]))
                }
                return try await session.finish()
            } catch {
                await session.cancel()
                throw error
            }
        }

        if profile.batchEndpoint == .deploymentScoped,
           !Self.isDatedAPIVersion(profile.apiVersion) {
            throw PluginTranscriptionError.apiError(
                "Deployment-scoped batch transcription requires a dated API version."
            )
        }

        guard let helper = makeTranscriptionHelper(for: profile) else {
            throw PluginTranscriptionError.notConfigured
        }
        let apiKey = apiKey(for: profileId) ?? ""
        if profile.apiVersion.isEmpty, profile.batchEndpoint == .standard {
            return try await helper.transcribeCompressedAudioWithWavFallback(
                audio: audio,
                apiKey: apiKey,
                modelName: modelId,
                language: language,
                translate: translate,
                prompt: prompt,
                requestTimeout: Self.transcriptionRequestTimeout
            )
        }

        // TypeWhisper 1.6 RC1 does not export the SDK's apiVersion overload.
        // Keep this JSON request path in the plugin until that host is no longer supported.
        return try await PluginAudioUploadEncoder.withCompressedM4AUploadWavFallback(from: audio) { uploadFile in
            try await self.performBatchTranscriptionRequest(
                profile: profile,
                uploadFile: uploadFile,
                apiKey: apiKey,
                modelName: modelId,
                language: language,
                translate: translate,
                prompt: prompt
            )
        }
    }

    // MARK: - Realtime Transport

    func transcriptionTransport(for profileId: String) -> OpenAICompatibleTranscriptTransport {
        profile(for: profileId)?.transcriptionTransport ?? .auto
    }

    func setTranscriptionTransport(_ transport: OpenAICompatibleTranscriptTransport, for profileId: String) {
        updateProfile(profileId) { profile in
            profile.transcriptionTransportRaw = transport.rawValue
        }
    }

    func batchEndpoint(for profileId: String) -> OpenAICompatibleBatchEndpoint {
        profile(for: profileId)?.batchEndpoint ?? .standard
    }

    func setBatchEndpoint(_ endpoint: OpenAICompatibleBatchEndpoint, for profileId: String) {
        updateProfile(profileId) { profile in
            profile.batchEndpointRaw = endpoint.rawValue
        }
    }

    /// Resolves the effective transport for the profile's *currently selected*
    /// transcription model, applying the `auto` heuristic (known realtime IDs
    /// use realtime, everything else stays batch) when the profile hasn't
    /// forced an explicit transport.
    func resolvedTranscriptionTransport(for profileId: String) -> OpenAICompatibleResolvedTranscriptionTransport {
        profile(for: profileId)?.resolvedTranscriptionTransport() ?? .batch
    }

    func supportsStreaming(for profileId: String) -> Bool {
        resolvedTranscriptionTransport(for: profileId) == .realtime
    }

    func createLiveTranscriptionSession(
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool,
        profileId: String
    ) async throws -> any LiveTranscriptionSession {
        guard let profile = profile(for: profileId), !profile.baseURL.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        let modelId = profile.selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelId.isEmpty else {
            throw PluginTranscriptionError.noModelSelected
        }
        guard profile.resolvedTranscriptionTransport() == .realtime else {
            // Batch-routed models: don't fake streaming with a repeated-REST-upload
            // loop here. Throwing lets the host fall back to its own generic
            // polling-based transcript preview loop over the regular `transcribe()`
            // call, which is exactly the behavior a batch-only model already had.
            throw PluginTranscriptionError.apiError(
                "\"\(modelId)\" is routed through batch transcription; live streaming is unavailable for it."
            )
        }
        guard !translate else {
            throw PluginTranscriptionError.apiError(
                "Realtime transcription does not support translation. Disable translation or switch to batch transport."
            )
        }
        guard let request = realtimeRequest(for: profile, profileId: profileId) else {
            throw PluginTranscriptionError.notConfigured
        }

        let usesContextAwareHints = OpenAICompatibleRealtimeModel.usesContextAwareRealtimeHints(modelId: modelId)
        let configuration = PluginOpenAIRealtimeTranscriptionConfiguration(
            modelID: modelId,
            languageSelection: usesContextAwareHints
                ? languageSelection
                : PluginLanguageSelection(
                    requestedLanguage: PluginOpenAIRealtimeTranscriptionConfiguration.normalizedLanguages(
                        from: languageSelection
                    ).first
                ),
            prompt: prompt,
            keywords: usesContextAwareHints
                ? PluginOpenAIRealtimeTranscriptionConfiguration.normalizedRealtimeKeywords(from: dictionaryTermHints)
                : [],
            delay: nil,
            usesContextAwareHints: usesContextAwareHints
        )

        return try await realtimeSessionConnector.connect(
            request: request,
            configuration: configuration,
            onProgress: onProgress
        )
    }

    /// Builds the WebSocket request for the realtime transcription endpoint:
    /// scheme swapped to ws/wss, the profile's configured base path preserved,
    /// `/v1/realtime` appended, `intent=transcription` and the configured
    /// api-version applied without duplicating any existing query items, and
    /// the same Bearer/api-key authentication used by REST requests.
    func realtimeRequest(for profile: OpenAICompatibleProfile, profileId: String) -> URLRequest? {
        guard let url = Self.realtimeRequestURL(baseURL: profile.baseURL, apiVersion: profile.apiVersion) else {
            return nil
        }
        var request = URLRequest(url: url)
        applyAuthentication(to: &request, profileId: profileId)
        return request
    }

    static func realtimeRequestURL(baseURL: String, apiVersion: String) -> URL? {
        guard let restURL = requestURL(baseURL: baseURL, path: "/v1/realtime", apiVersion: apiVersion),
              var components = URLComponents(url: restURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("intent") == .orderedSame }
        queryItems.append(URLQueryItem(name: "intent", value: "transcription"))
        components.queryItems = queryItems

        return components.url
    }

    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective,
        profileId: String
    ) async throws -> String {
        guard let profile = profile(for: profileId), !profile.baseURL.isEmpty else {
            throw PluginChatError.notConfigured
        }
        let modelId = model ?? selectedLLMModelId(for: profileId) ?? ""
        guard !modelId.isEmpty else {
            throw PluginChatError.noModelSelected
        }
        let temperature = providerTemperatureDirective(for: profileId)
            .resolvedTemperature(applying: temperatureDirective)
        let apiKey = apiKey(for: profileId) ?? ""

        switch profile.llmAPI {
        case .chatCompletions:
            return try await processChatCompletion(
                apiKey: apiKey,
                baseURL: profile.baseURL,
                model: modelId,
                systemPrompt: systemPrompt,
                userText: userText,
                temperature: temperature,
                requestTimeout: profile.resolvedChatRequestTimeout,
                thinkingEnabled: profile.thinkingEnabled,
                apiVersion: profile.apiVersion
            )
        case .responses:
            return try await processResponse(
                apiKey: apiKey,
                baseURL: profile.baseURL,
                model: modelId,
                systemPrompt: systemPrompt,
                userText: userText,
                temperature: profile.reasoningEffort.requestValue == nil ? temperature : nil,
                reasoningEffort: profile.reasoningEffort.requestValue,
                requestTimeout: profile.resolvedChatRequestTimeout,
                apiVersion: profile.apiVersion
            )
        }
    }

    func fetchModels() async -> [FetchedModel] {
        await fetchModels(for: OpenAICompatibleProfile.defaultId)
    }

    func fetchModels(for profileId: String) async -> [FetchedModel] {
        guard let profile = profile(for: profileId),
              !profile.baseURL.isEmpty,
              let url = Self.requestURL(
                baseURL: profile.baseURL,
                path: "/v1/models",
                apiVersion: profile.apiVersion
              ) else { return [] }

        var request = URLRequest(url: url)
        applyAuthentication(to: &request, profileId: profileId)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }

            struct ModelsResponse: Decodable {
                let data: [FetchedModel]
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data.sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }

    func validateConnection() async -> Bool {
        await validateConnection(for: OpenAICompatibleProfile.defaultId)
    }

    func validateConnection(for profileId: String) async -> Bool {
        guard let profile = profile(for: profileId),
              !profile.baseURL.isEmpty,
              let url = Self.requestURL(
                baseURL: profile.baseURL,
                path: "/v1/models",
                apiVersion: profile.apiVersion
              ) else { return false }

        var request = URLRequest(url: url)
        applyAuthentication(to: &request, profileId: profileId)
        request.timeoutInterval = 10

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Internal Helpers

    fileprivate func profile(for profileId: String) -> OpenAICompatibleProfile? {
        let canonicalId = canonicalProfileId(for: profileId)
        return profiles.first { $0.id == canonicalId }
    }

    func apiKey(for profileId: String) -> String? {
        host?.loadSecret(key: secretKey(for: profileId))
    }

    private func canonicalProfileId(for identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(Self.legacyProviderName) == .orderedSame {
            return OpenAICompatibleProfile.defaultId
        }
        if let match = profiles.first(where: {
            $0.id.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return match.id
        }
        return trimmed
    }

    private nonisolated static func isAzureOpenAIEndpoint(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host.hasSuffix(".openai.azure.com")
            || host.hasSuffix(".openai.azure.us")
            || host.hasSuffix(".services.ai.azure.com")
    }

    private func applyAuthentication(to request: inout URLRequest, profileId: String) {
        guard let apiKey = apiKey(for: profileId) else { return }
        Self.applyAuthentication(to: &request, apiKey: apiKey)
    }

    private nonisolated static func applyAuthentication(to request: inout URLRequest, apiKey: String) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        let authorizationHeader = "Authorization"
        request.setValue("Bearer " + trimmedKey, forHTTPHeaderField: authorizationHeader)
        if isAzureOpenAIEndpoint(request.url) {
            request.setValue(trimmedKey, forHTTPHeaderField: "api-key")
        }
    }

    private func providerTemperatureDirective(for profileId: String) -> PluginLLMTemperatureDirective {
        PluginLLMTemperatureDirective(
            mode: llmTemperatureMode(for: profileId),
            value: profile(for: profileId)?.llmTemperatureValue ?? 0.3
        )
    }

    private func makeTranscriptionHelper(for profile: OpenAICompatibleProfile) -> PluginOpenAITranscriptionHelper? {
        guard !profile.baseURL.isEmpty else { return nil }
        return PluginOpenAITranscriptionHelper(baseURL: profile.baseURL, responseFormat: "json")
    }

    private func updateProfile(
        _ profileId: String,
        _ mutate: (inout OpenAICompatibleProfile) -> Void
    ) {
        let canonicalId = canonicalProfileId(for: profileId)
        guard let index = profiles.firstIndex(where: { $0.id == canonicalId }) else { return }

        mutate(&profiles[index])
        persistProfiles()
    }

    private func loadProfiles(from host: HostServices) -> [OpenAICompatibleProfile] {
        if let data = host.userDefault(forKey: Self.profilesKey) as? Data,
           let decoded = try? JSONDecoder().decode([OpenAICompatibleProfile].self, from: data),
           !decoded.isEmpty {
            return normalizedProfiles(decoded, host: host)
        }

        let fetchedModels: [FetchedModel]
        if let data = host.userDefault(forKey: "fetchedModels") as? Data {
            fetchedModels = (try? JSONDecoder().decode([FetchedModel].self, from: data)) ?? []
        } else {
            fetchedModels = []
        }

        return [
            .defaultProfile(
                baseURL: Self.normalizedBaseURL(host.userDefault(forKey: "baseURL") as? String ?? ""),
                apiVersion: Self.normalizedAPIVersion(
                    host.userDefault(forKey: "apiVersion") as? String ?? ""
                ),
                selectedModelId: host.userDefault(forKey: "selectedModel") as? String ?? "",
                selectedLLMModelId: host.userDefault(forKey: "selectedLLMModel") as? String ?? "",
                llmTemperatureModeRaw: host.userDefault(forKey: "llmTemperatureMode") as? String
                    ?? PluginLLMTemperatureMode.providerDefault.rawValue,
                llmTemperatureValue: host.userDefault(forKey: "llmTemperatureValue") as? Double ?? 0.3,
                fetchedModels: fetchedModels,
                llmAPIModeRaw: host.userDefault(forKey: "llmAPIMode") as? String
                    ?? OpenAICompatibleLLMAPI.chatCompletions.rawValue,
                reasoningEffortRaw: host.userDefault(forKey: "reasoningEffort") as? String
                    ?? OpenAICompatibleReasoningEffort.providerDefault.rawValue
            )
        ]
    }

    private func normalizedProfiles(
        _ loadedProfiles: [OpenAICompatibleProfile],
        host: HostServices
    ) -> [OpenAICompatibleProfile] {
        var seenIds = Set<String>()
        var result: [OpenAICompatibleProfile] = []

        for var profile in loadedProfiles {
            let trimmedId = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedId.isEmpty, !seenIds.contains(trimmedId) else { continue }

            profile.id = trimmedId
            if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.name = profile.isDefault ? OpenAICompatibleProfile.defaultName : "Custom Server"
            }
            profile.baseURL = Self.normalizedBaseURL(profile.baseURL)
            profile.apiVersion = Self.normalizedAPIVersion(profile.apiVersion)
            seenIds.insert(profile.id)
            result.append(profile)
        }

        if !seenIds.contains(OpenAICompatibleProfile.defaultId) {
            result.insert(
                .defaultProfile(
                    baseURL: Self.normalizedBaseURL(host.userDefault(forKey: "baseURL") as? String ?? ""),
                    apiVersion: Self.normalizedAPIVersion(
                        host.userDefault(forKey: "apiVersion") as? String ?? ""
                    ),
                    selectedModelId: host.userDefault(forKey: "selectedModel") as? String ?? "",
                    selectedLLMModelId: host.userDefault(forKey: "selectedLLMModel") as? String ?? "",
                    llmAPIModeRaw: host.userDefault(forKey: "llmAPIMode") as? String
                        ?? OpenAICompatibleLLMAPI.chatCompletions.rawValue,
                    reasoningEffortRaw: host.userDefault(forKey: "reasoningEffort") as? String
                        ?? OpenAICompatibleReasoningEffort.providerDefault.rawValue
                ),
                at: 0
            )
        }

        result.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return result
    }

    private func persistProfiles(notify: Bool = true) {
        guard let host else { return }

        if let data = try? JSONEncoder().encode(profiles) {
            host.setUserDefault(data, forKey: Self.profilesKey)
        }
        syncLegacyDefaultProfile(to: host)

        if notify {
            host.notifyCapabilitiesChanged()
        }
    }

    private func syncLegacyDefaultProfile(to host: HostServices) {
        guard let defaultProfile = profiles.first(where: \.isDefault) else { return }

        host.setUserDefault(defaultProfile.baseURL, forKey: "baseURL")
        host.setUserDefault(defaultProfile.apiVersion, forKey: "apiVersion")
        host.setUserDefault(defaultProfile.selectedModelId, forKey: "selectedModel")
        host.setUserDefault(defaultProfile.selectedLLMModelId, forKey: "selectedLLMModel")
        host.setUserDefault(defaultProfile.llmTemperatureModeRaw, forKey: "llmTemperatureMode")
        host.setUserDefault(defaultProfile.llmTemperatureValue, forKey: "llmTemperatureValue")
        host.setUserDefault(defaultProfile.llmAPIModeRaw, forKey: "llmAPIMode")
        host.setUserDefault(defaultProfile.reasoningEffortRaw, forKey: "reasoningEffort")
        if let data = try? JSONEncoder().encode(defaultProfile.fetchedModels) {
            host.setUserDefault(data, forKey: "fetchedModels")
        }
    }

    private func uniqueProfileName(_ baseName: String) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Custom Server" : trimmed
        let existingNames = Set(profiles.map { $0.displayName.lowercased() })
        if !existingNames.contains(fallback.lowercased()) {
            return fallback
        }

        var index = 2
        while true {
            let candidate = "\(fallback) \(index)"
            if !existingNames.contains(candidate.lowercased()) {
                return candidate
            }
            index += 1
        }
    }

    private func secretKey(for profileId: String) -> String {
        canonicalProfileId(for: profileId) == OpenAICompatibleProfile.defaultId
            ? "api-key"
            : "api-key.\(canonicalProfileId(for: profileId))"
    }

    enum OutputTokenParameter: String {
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"

        var fallback: OutputTokenParameter {
            switch self {
            case .maxTokens:
                .maxCompletionTokens
            case .maxCompletionTokens:
                .maxTokens
            }
        }
    }

    nonisolated static func fallbackOutputTokenParameter(
        after parameter: OutputTokenParameter,
        errorMessage: String
    ) -> OutputTokenParameter? {
        let lowered = errorMessage.lowercased()
        let current = parameter.rawValue.lowercased()
        let fallback = parameter.fallback.rawValue.lowercased()
        guard lowered.contains(current), lowered.contains(fallback) else {
            return nil
        }
        return parameter.fallback
    }

    private func processChatCompletion(
        apiKey: String,
        baseURL: String,
        model: String,
        systemPrompt: String,
        userText: String,
        temperature: Double?,
        requestTimeout: TimeInterval,
        thinkingEnabled: Bool,
        apiVersion: String
    ) async throws -> String {
        let path = OpenAICompatibleLLMAPI.chatCompletions.path
        guard let url = Self.requestURL(baseURL: baseURL, path: path, apiVersion: apiVersion) else {
            throw PluginChatError.apiError("Invalid URL: \(baseURL)\(path)")
        }

        let outputTokenParameter = OutputTokenParameter.maxTokens
        do {
            return try await performChatCompletionRequest(
                url: url,
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt,
                userText: userText,
                temperature: temperature,
                requestTimeout: requestTimeout,
                thinkingEnabled: thinkingEnabled,
                outputTokenParameter: outputTokenParameter
            )
        } catch let error as PluginChatError {
            guard case .apiError(let message) = error,
                  let fallback = Self.fallbackOutputTokenParameter(
                    after: outputTokenParameter,
                    errorMessage: message
                  ) else {
                throw error
            }
            return try await performChatCompletionRequest(
                url: url,
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt,
                userText: userText,
                temperature: temperature,
                requestTimeout: requestTimeout,
                thinkingEnabled: thinkingEnabled,
                outputTokenParameter: fallback
            )
        }
    }

    private func performChatCompletionRequest(
        url: URL,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        temperature: Double?,
        requestTimeout: TimeInterval,
        thinkingEnabled: Bool,
        outputTokenParameter: OutputTokenParameter
    ) async throws -> String {
        var requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
        ]
        requestBody[outputTokenParameter.rawValue] = 4096
        if let temperature {
            requestBody["temperature"] = temperature
        }
        if thinkingEnabled {
            requestBody["thinking"] = ["type": "enabled"]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        Self.applyAuthentication(to: &request, apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await PluginHTTPClient.data(for: request, resourceTimeout: requestTimeout)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginChatError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw PluginChatError.invalidApiKey
        case 429:
            throw PluginChatError.rateLimited
        default:
            throw PluginChatError.apiError(Self.chatErrorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PluginChatError.apiError("Failed to parse response")
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func processResponse(
        apiKey: String,
        baseURL: String,
        model: String,
        systemPrompt: String,
        userText: String,
        temperature: Double?,
        reasoningEffort: String?,
        requestTimeout: TimeInterval,
        apiVersion: String
    ) async throws -> String {
        let path = OpenAICompatibleLLMAPI.responses.path
        guard let url = Self.requestURL(baseURL: baseURL, path: path, apiVersion: apiVersion) else {
            throw PluginChatError.apiError("Invalid URL: \(baseURL)\(path)")
        }

        let instructions = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "You are a helpful assistant."
            : systemPrompt
        var requestBody: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": userText,
                        ],
                    ],
                ],
            ],
            "store": false,
        ]
        if let reasoningEffort {
            requestBody["reasoning"] = ["effort": reasoningEffort]
        }
        if let temperature {
            requestBody["temperature"] = temperature
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        Self.applyAuthentication(to: &request, apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await PluginHTTPClient.data(for: request, resourceTimeout: requestTimeout)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginChatError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseResponsesText(from: data)
        case 401:
            throw PluginChatError.invalidApiKey
        case 429:
            throw PluginChatError.rateLimited
        default:
            throw PluginChatError.apiError(Self.chatErrorMessage(from: data, statusCode: httpResponse.statusCode))
        }
    }

    static func parseResponsesText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginChatError.apiError("Failed to parse response")
        }

        if let outputText = json["output_text"] as? String {
            let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let output = json["output"] as? [[String: Any]] {
            let textParts = output.flatMap { item -> [String] in
                guard let content = item["content"] as? [[String: Any]] else { return [] }
                return content.compactMap { contentItem in
                    let type = contentItem["type"] as? String
                    guard type == nil || type == "output_text" || type == "text" else { return nil }
                    if let text = contentItem["text"] as? String {
                        return text
                    }
                    if let text = contentItem["text"] as? [String: Any] {
                        return text["value"] as? String
                    }
                    return nil
                }
            }

            let text = textParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }

        throw PluginChatError.apiError("Failed to parse response text")
    }

    private func performBatchTranscriptionRequest(
        profile: OpenAICompatibleProfile,
        uploadFile: PluginAudioUploadFile,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        let operation = translate ? "translations" : "transcriptions"
        let path: String
        switch profile.batchEndpoint {
        case .standard:
            path = "/v1/audio/\(operation)"
        case .deploymentScoped:
            path = "/deployments/\(Self.percentEncodedPathSegment(modelName))/audio/\(operation)"
        }
        guard let url = Self.requestURL(
            baseURL: profile.baseURL,
            path: path,
            apiVersion: profile.apiVersion
        ) else {
            throw PluginTranscriptionError.apiError("Invalid URL: \(profile.baseURL)\(path)")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        Self.applyAuthentication(to: &request, apiKey: apiKey)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.transcriptionRequestTimeout

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(uploadFile.filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(uploadFile.contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(uploadFile.data)
        body.append("\r\n".data(using: .utf8)!)
        Self.appendMultipartField(to: &body, boundary: boundary, name: "model", value: modelName)
        Self.appendMultipartField(to: &body, boundary: boundary, name: "response_format", value: "json")
        if !translate, let language, !language.isEmpty {
            Self.appendMultipartField(to: &body, boundary: boundary, name: "language", value: language)
        }
        if let prompt, !prompt.isEmpty {
            Self.appendMultipartField(to: &body, boundary: boundary, name: "prompt", value: prompt)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await PluginHTTPClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 429:
            throw PluginTranscriptionError.rateLimited
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        default:
            let errorMessage = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }
        struct Response: Decodable {
            let text: String
            let language: String?
            let segments: [Segment]?
        }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: responseData)
            let segments = (decoded.segments ?? []).map {
                PluginTranscriptionSegment(text: $0.text, start: $0.start, end: $0.end)
            }
            return PluginTranscriptionResult(
                text: decoded.text,
                detectedLanguage: decoded.language,
                segments: segments
            )
        } catch {
            throw PluginTranscriptionError.apiError("Failed to parse response: \(error.localizedDescription)")
        }
    }

    private static func appendMultipartField(
        to data: inout Data,
        boundary: String,
        name: String,
        value: String
    ) {
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(value)\r\n".data(using: .utf8)!)
    }

    private static func chatErrorMessage(from data: Data, statusCode: Int) -> String {
        let json = try? JSONSerialization.jsonObject(with: data)

        let object: [String: Any]?
        if let dictionary = json as? [String: Any] {
            object = dictionary
        } else if let array = json as? [Any],
                  let first = array.first as? [String: Any] {
            object = first
        } else {
            object = nil
        }

        if let object, let message = message(fromChatErrorObject: object) {
            return message
        }
        return "HTTP \(statusCode)"
    }

    private static func message(fromChatErrorObject object: [String: Any]) -> String? {
        if let detail = object["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    private static func normalizedBaseURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasSuffix("/v1") {
            path.removeLast(3)
        }
        components.percentEncodedPath = path
        return components.string ?? trimmed
    }

    private static func normalizedAPIVersion(_ apiVersion: String) -> String {
        apiVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isDatedAPIVersion(_ apiVersion: String) -> Bool {
        normalizedAPIVersion(apiVersion).range(
            of: #"^\d{4}-\d{2}-\d{2}"#,
            options: .regularExpression
        ) != nil
    }

    private static func percentEncodedPathSegment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func requestURL(baseURL: String, path: String, apiVersion: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, requestPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")

        let trimmedVersion = normalizedAPIVersion(apiVersion)
        if !trimmedVersion.isEmpty {
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name.caseInsensitiveCompare("api-version") == .orderedSame }
            queryItems.append(URLQueryItem(name: "api-version", value: trimmedVersion))
            components.queryItems = queryItems
        }
        return components.url
    }
}

// MARK: - Additional Profile Role

private final class OpenAICompatibleProfileRole: NSObject,
    TranscriptionEnginePlugin,
    DictionaryTermsCapabilityProviding,
    LLMProviderPlugin,
    LLMProviderIdentityProviding,
    LLMTemperatureControllableProvider,
    LLMModelSelectable,
    LiveLanguageHintDictionaryTermHintTranscriptionCapablePlugin,
    @unchecked Sendable
{
    static let pluginId = OpenAICompatiblePlugin.pluginId
    static let pluginName = OpenAICompatiblePlugin.pluginName

    private let plugin: OpenAICompatiblePlugin
    private let profileId: String

    required override init() {
        fatalError("Use init(plugin:profileId:)")
    }

    init(plugin: OpenAICompatiblePlugin, profileId: String) {
        self.plugin = plugin
        self.profileId = profileId
        super.init()
    }

    func activate(host: HostServices) {}
    func deactivate() {}
    var settingsView: AnyView? { nil }

    var providerId: String { profileId }
    var providerDisplayName: String { plugin.displayName(for: profileId) }
    var providerName: String { providerDisplayName }
    var isConfigured: Bool { plugin.isConfigured(for: profileId) }
    var isAvailable: Bool { isConfigured }
    var transcriptionModels: [PluginModelInfo] { plugin.transcriptionModels(for: profileId) }
    var selectedModelId: String? { plugin.selectedModelId(for: profileId) }
    var supportsTranslation: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }
    var supportedLanguages: [String] { plugin.supportedLanguages }
    var supportedModels: [PluginModelInfo] { plugin.supportedModels(for: profileId) }
    var preferredModelId: String? { plugin.selectedLLMModelId(for: profileId) }

    func selectModel(_ modelId: String) {
        plugin.selectModel(modelId, for: profileId)
    }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        try await plugin.transcribe(
            audio: audio,
            language: language,
            translate: translate,
            prompt: prompt,
            profileId: profileId
        )
    }

    var supportsStreaming: Bool {
        plugin.supportsStreaming(for: profileId)
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: PluginLanguageSelection(requestedLanguage: language),
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: [],
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: languageSelection,
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: [],
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: PluginLanguageSelection(requestedLanguage: language),
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await plugin.createLiveTranscriptionSession(
            languageSelection: languageSelection,
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            onProgress: onProgress,
            profileId: profileId
        )
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: .inheritProviderSetting
        )
    }

    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String {
        try await plugin.process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: temperatureDirective,
            profileId: profileId
        )
    }
}

// MARK: - Fetched Model

struct FetchedModel: Codable, Equatable, Sendable {
    let id: String
    let owned_by: String?

    enum CodingKeys: String, CodingKey {
        case id
        case owned_by
    }

    init(id: String, owned_by: String? = nil) {
        self.id = id
        self.owned_by = owned_by
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        owned_by = try container.decodeIfPresent(String.self, forKey: .owned_by)
    }
}

// MARK: - Settings View

private struct OpenAICompatibleSettingsView: View {
    let plugin: OpenAICompatiblePlugin

    @State private var profiles: [OpenAICompatibleProfile] = []
    @State private var selectedProfileId = OpenAICompatibleProfile.defaultId
    @State private var nameInput = ""
    @State private var baseURLInput = ""
    @State private var apiVersionInput = ""
    @State private var apiKeyInput = ""
    @State private var showApiKey = false
    @State private var isTesting = false
    @State private var connectionResult: Bool?
    @State private var selectedTranscriptionModel = ""
    @State private var selectedLLMModel = ""
    @State private var manualTranscriptionModel = ""
    @State private var manualLLMModel = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var thinkingEnabled = false
    @State private var chatTimeoutInput = ""
    @State private var transcriptionTransport: OpenAICompatibleTranscriptTransport = .auto
    @State private var batchEndpoint: OpenAICompatibleBatchEndpoint = .standard
    @State private var llmAPI: OpenAICompatibleLLMAPI = .chatCompletions
    @State private var reasoningEffort: OpenAICompatibleReasoningEffort = .providerDefault

    private let bundle = pluginModuleBundle

    private var selectedProfile: OpenAICompatibleProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    private var hasModels: Bool {
        selectedProfile?.fetchedModels.isEmpty == false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            profileSidebar
                .frame(width: 210)

            Divider()

            profileDetail
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 680, minHeight: 520, alignment: .topLeading)
        .onAppear {
            reloadProfiles(selecting: selectedProfileId)
        }
        .onChange(of: selectedProfileId) {
            syncFieldsFromSelectedProfile()
        }
    }

    private var profileSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Profiles", bundle: bundle)
                    .font(.headline)
                Spacer()
                Button {
                    let profile = plugin.addProfile()
                    reloadProfiles(selecting: profile.id)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(Text("Add Profile", bundle: bundle))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(profiles) { profile in
                        Button {
                            selectedProfileId = profile.id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: profile.isDefault ? "server.rack" : "server.rack.fill")
                                    .frame(width: 18)
                                Text(profile.displayName)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                selectedProfileId == profile.id
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button(role: .destructive) {
                let nextSelection = profiles.first(where: { $0.id != selectedProfileId })?.id
                    ?? OpenAICompatibleProfile.defaultId
                plugin.deleteProfile(selectedProfileId)
                reloadProfiles(selecting: nextSelection)
            } label: {
                Label(String(localized: "Delete", bundle: bundle), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedProfile?.isDefault != false)
        }
        .padding()
    }

    private var profileDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if selectedProfile == nil {
                    Text("Select a profile", bundle: bundle)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } else {
                    profileIdentitySection
                    serverSection
                    modelSection
                    temperatureSection
                    if llmAPI == .chatCompletions {
                        thinkingModeSection
                    } else {
                        reasoningEffortSection
                    }
                    timeoutSection

                    Text("API keys are stored securely in the Keychain", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var profileIdentitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile Name", bundle: bundle)
                .font(.headline)

            TextField(String(localized: "Profile name", bundle: bundle), text: $nameInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveProfileName)
                .onChange(of: nameInput) {
                    saveProfileName()
                }
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Server URL", bundle: bundle)
                    .font(.headline)

                TextField(
                    String(localized: "e.g. http://localhost:11434", bundle: bundle),
                    text: $baseURLInput
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Version", bundle: bundle)
                    .font(.headline)

                TextField(
                    String(localized: "Optional, e.g. preview", bundle: bundle),
                    text: $apiVersionInput
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(saveApiVersion)
                .onChange(of: apiVersionInput) {
                    saveApiVersion()
                }

                Text("Some servers require an API version. Deployment-scoped batch endpoints require a dated version; realtime endpoints may require a preview version. Leave blank when the server does not require one.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 8) {
                    if showApiKey {
                        TextField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text("Optional for local servers like Ollama or LM Studio", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    testConnection()
                } label: {
                    Text("Test Connection", bundle: bundle)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                if let selectedProfile, plugin.hasApiKey(for: selectedProfile.id) {
                    Button(String(localized: "Remove", bundle: bundle)) {
                        apiKeyInput = ""
                        plugin.removeApiKey(for: selectedProfile.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                }

                if isTesting {
                    ProgressView().controlSize(.small)
                    Text("Testing...", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let result = connectionResult {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result ? .green : .red)
                    Text(result ? String(localized: "Connected", bundle: bundle) : String(localized: "Connection Failed", bundle: bundle))
                        .font(.caption)
                        .foregroundStyle(result ? .green : .red)
                }
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            HStack {
                Text("Models", bundle: bundle)
                    .font(.headline)

                Spacer()

                Button {
                    refreshModels()
                } label: {
                    Label(String(localized: "Refresh", bundle: bundle), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if hasModels, let selectedProfile {
                modelPickerSection(profile: selectedProfile)
            } else {
                manualModelSection
            }

            llmAPISection
            transportSection
            batchEndpointSection
        }
    }

    private var llmAPISection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LLM API", bundle: bundle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("LLM API", selection: $llmAPI) {
                Text("Chat Completions", bundle: bundle).tag(OpenAICompatibleLLMAPI.chatCompletions)
                Text("Responses", bundle: bundle).tag(OpenAICompatibleLLMAPI.responses)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: llmAPI) {
                guard let selectedProfile else { return }
                plugin.setLLMAPI(llmAPI, for: selectedProfile.id)
                reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
            }

            Text(
                llmAPI == .chatCompletions
                    ? "Uses /v1/chat/completions for broad compatibility with existing providers."
                    : "Uses /v1/responses with OpenAI-compatible input, output, and reasoning fields.",
                bundle: bundle
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcription Transport", bundle: bundle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Transcription Transport", selection: $transcriptionTransport) {
                Text("Auto", bundle: bundle).tag(OpenAICompatibleTranscriptTransport.auto)
                Text("Batch", bundle: bundle).tag(OpenAICompatibleTranscriptTransport.batch)
                Text("Realtime", bundle: bundle).tag(OpenAICompatibleTranscriptTransport.realtime)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: transcriptionTransport) {
                saveTranscriptionTransport()
            }

            Text("Auto uses realtime streaming only for known realtime model IDs (gpt-live-transcribe, gpt-realtime-whisper) and batch upload otherwise. Choose Realtime to force streaming for any OpenAI-compatible server that supports the /v1/realtime WebSocket API, including custom deployment aliases (e.g. an Azure OpenAI or Microsoft Foundry gpt-live-transcribe deployment) — some providers, including Azure, require a preview API version for realtime transcription. Choose Batch to use the selected Batch Transcription Endpoint.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var batchEndpointSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Batch Transcription Endpoint", bundle: bundle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Batch Transcription Endpoint", selection: $batchEndpoint) {
                Text("Standard v1", bundle: bundle).tag(OpenAICompatibleBatchEndpoint.standard)
                Text("Deployment-scoped", bundle: bundle).tag(OpenAICompatibleBatchEndpoint.deploymentScoped)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: batchEndpoint) {
                saveBatchEndpoint()
            }

            Text("Standard v1 uses /v1/audio/transcriptions. Deployment-scoped uses /deployments/{model}/audio/transcriptions and requires a dated API version. Realtime transcription continues to use /v1/realtime.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func modelPickerSection(profile: OpenAICompatibleProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription Model", bundle: bundle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Transcription Model", selection: $selectedTranscriptionModel) {
                    Text(String(localized: "None", bundle: bundle)).tag("")
                    ForEach(profile.fetchedModels, id: \.id) { model in
                        Text(model.id).tag(model.id)
                    }
                }
                .labelsHidden()
                .onChange(of: selectedTranscriptionModel) {
                    plugin.selectModel(selectedTranscriptionModel, for: profile.id)
                    reloadProfiles(selecting: profile.id, preserveInputs: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("LLM Model", bundle: bundle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("LLM Model", selection: $selectedLLMModel) {
                    Text(String(localized: "None", bundle: bundle)).tag("")
                    ForEach(profile.fetchedModels, id: \.id) { model in
                        Text(model.id).tag(model.id)
                    }
                }
                .labelsHidden()
                .onChange(of: selectedLLMModel) {
                    plugin.selectLLMModel(selectedLLMModel, for: profile.id)
                    reloadProfiles(selecting: profile.id, preserveInputs: true)
                }
            }
        }
    }

    private var manualModelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No models found. Enter model name manually.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

            manualModelField(
                title: String(localized: "Transcription Model", bundle: bundle),
                text: $manualTranscriptionModel
            ) {
                guard let selectedProfile else { return }
                let trimmed = manualTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                plugin.selectModel(trimmed, for: selectedProfile.id)
                selectedTranscriptionModel = trimmed
                reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
            }

            manualModelField(
                title: String(localized: "LLM Model", bundle: bundle),
                text: $manualLLMModel
            ) {
                guard let selectedProfile else { return }
                let trimmed = manualLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                plugin.selectLLMModel(trimmed, for: selectedProfile.id)
                selectedLLMModel = trimmed
                reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
            }
        }
    }

    private func manualModelField(
        title: String,
        text: Binding<String>,
        save: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(String(localized: "Model name", bundle: bundle), text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(save)

                Button(String(localized: "Save", bundle: bundle), action: save)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("Temperature", bundle: bundle)
                .font(.headline)

            Picker("Temperature Mode", selection: $llmTemperatureMode) {
                Text("Provider Default", bundle: bundle).tag(PluginLLMTemperatureMode.providerDefault)
                Text("Custom", bundle: bundle).tag(PluginLLMTemperatureMode.custom)
            }
            .onChange(of: llmTemperatureMode) {
                guard let selectedProfile else { return }
                plugin.setLLMTemperatureMode(llmTemperatureMode, for: selectedProfile.id)
                reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
            }

            if llmTemperatureMode == .custom {
                HStack {
                    Text("Temperature", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(llmTemperatureValue, format: .number.precision(.fractionLength(2)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(value: $llmTemperatureValue, in: 0...2, step: 0.1)
                    .onChange(of: llmTemperatureValue) {
                        guard let selectedProfile else { return }
                        plugin.setLLMTemperatureValue(llmTemperatureValue, for: selectedProfile.id)
                        reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
                    }
            }

            if llmAPI == .responses, reasoningEffort != .providerDefault {
                Text("Temperature overrides are omitted when Responses reasoning effort is configured.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var thinkingModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Toggle(isOn: $thinkingEnabled) {
                Text("Provider Thinking Extension", bundle: bundle)
                    .font(.headline)
            }
            .onChange(of: thinkingEnabled) {
                guard let selectedProfile else { return }
                plugin.setThinkingEnabled(thinkingEnabled, for: selectedProfile.id)
                reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
            }

            Text("Adds the nonstandard Chat Completions thinking field only when enabled. Leave off unless your provider documents support.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var reasoningEffortSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("Reasoning Effort", bundle: bundle)
                .font(.headline)

            Picker("Reasoning Effort", selection: $reasoningEffort) {
                ForEach(OpenAICompatibleReasoningEffort.allCases, id: \.self) { effort in
                    Text(String(localized: String.LocalizationValue(effort.displayName), bundle: bundle))
                        .tag(effort)
                }
            }
            .onChange(of: reasoningEffort) {
                guard let selectedProfile else { return }
                plugin.setReasoningEffort(reasoningEffort, for: selectedProfile.id)
                reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
            }

            Text("Provider Default omits reasoning. Other values send reasoning: { effort: ... } to /v1/responses.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var timeoutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("LLM Request Timeout", bundle: bundle)
                .font(.headline)

            HStack(spacing: 8) {
                TextField(String(localized: "Seconds", bundle: bundle), text: $chatTimeoutInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit(saveChatTimeout)
                    .accessibilityLabel(Text("LLM Request Timeout", bundle: bundle))

                Button(String(localized: "Save", bundle: bundle), action: saveChatTimeout)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Text("Seconds to wait for the LLM response. Increase for local servers (LM Studio, Ollama) that take a long time on large prompts. Higher values wait longer before failing. Default 30.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reloadProfiles(selecting profileId: String? = nil, preserveInputs: Bool = false) {
        profiles = plugin.profileSnapshots
        if let profileId,
           profiles.contains(where: { $0.id == profileId }) {
            selectedProfileId = profileId
        } else if !profiles.contains(where: { $0.id == selectedProfileId }) {
            selectedProfileId = profiles.first?.id ?? OpenAICompatibleProfile.defaultId
        }

        if !preserveInputs {
            syncFieldsFromSelectedProfile()
        }
    }

    private func syncFieldsFromSelectedProfile() {
        guard let profile = plugin.profileSnapshot(for: selectedProfileId) else { return }

        nameInput = profile.displayName
        baseURLInput = profile.baseURL
        apiVersionInput = profile.apiVersion
        apiKeyInput = plugin.apiKey(for: profile.id) ?? ""
        selectedTranscriptionModel = profile.selectedModelId
        selectedLLMModel = profile.selectedLLMModelId
        manualTranscriptionModel = profile.selectedModelId
        manualLLMModel = profile.selectedLLMModelId
        llmTemperatureMode = PluginLLMTemperatureMode(rawValue: profile.llmTemperatureModeRaw) ?? .providerDefault
        llmTemperatureValue = profile.llmTemperatureValue
        thinkingEnabled = profile.thinkingEnabled
        chatTimeoutInput = String(Int(profile.resolvedChatRequestTimeout))
        transcriptionTransport = profile.transcriptionTransport
        batchEndpoint = profile.batchEndpoint
        llmAPI = profile.llmAPI
        reasoningEffort = profile.reasoningEffort
        connectionResult = nil
    }

    private func saveChatTimeout() {
        guard let selectedProfile else { return }
        let trimmed = chatTimeoutInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Double(trimmed) else {
            chatTimeoutInput = String(Int(selectedProfile.resolvedChatRequestTimeout))
            return
        }
        plugin.setChatRequestTimeout(seconds, for: selectedProfile.id)
        reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
        if let updated = plugin.profileSnapshot(for: selectedProfile.id) {
            chatTimeoutInput = String(Int(updated.resolvedChatRequestTimeout))
        }
    }

    private func saveApiVersion() {
        guard let selectedProfile else { return }
        let trimmed = apiVersionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != selectedProfile.apiVersion else { return }
        plugin.setApiVersion(trimmed, for: selectedProfile.id)
        reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
    }

    private func saveTranscriptionTransport() {
        guard let selectedProfile else { return }
        guard transcriptionTransport != selectedProfile.transcriptionTransport else { return }
        plugin.setTranscriptionTransport(transcriptionTransport, for: selectedProfile.id)
        reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
    }

    private func saveBatchEndpoint() {
        guard let selectedProfile else { return }
        guard batchEndpoint != selectedProfile.batchEndpoint else { return }
        plugin.setBatchEndpoint(batchEndpoint, for: selectedProfile.id)
        reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
    }

    private func saveProfileName() {
        guard let selectedProfile else { return }
        let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != selectedProfile.displayName else { return }

        plugin.renameProfile(selectedProfile.id, to: trimmed)
        reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
    }

    private func saveServerFields(for profileId: String) {
        plugin.setBaseURL(baseURLInput, for: profileId)
        plugin.setApiVersion(apiVersionInput, for: profileId)
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            plugin.setApiKey(trimmedKey, for: profileId)
        }
    }

    private func testConnection() {
        guard let selectedProfile else { return }
        let profileId = selectedProfile.id
        saveServerFields(for: profileId)

        isTesting = true
        connectionResult = nil
        Task {
            let models = await plugin.fetchModels(for: profileId)
            var isConnected = !models.isEmpty
            if !isConnected {
                isConnected = await plugin.validateConnection(for: profileId)
            }
            await MainActor.run {
                isTesting = false
                connectionResult = isConnected
                if isConnected {
                    plugin.setFetchedModels(models, for: profileId)
                    if selectedTranscriptionModel.isEmpty, let first = models.first {
                        selectedTranscriptionModel = first.id
                        plugin.selectModel(first.id, for: profileId)
                    }
                    if selectedLLMModel.isEmpty, let first = models.first {
                        selectedLLMModel = first.id
                        plugin.selectLLMModel(first.id, for: profileId)
                    }
                    reloadProfiles(selecting: profileId, preserveInputs: true)
                }
            }
        }
    }

    private func refreshModels() {
        guard let selectedProfile else { return }
        let profileId = selectedProfile.id
        saveServerFields(for: profileId)

        Task {
            let models = await plugin.fetchModels(for: profileId)
            await MainActor.run {
                plugin.setFetchedModels(models, for: profileId)
                reloadProfiles(selecting: profileId)
            }
        }
    }
}

private let pluginModuleBundle: Bundle = {
#if SWIFT_PACKAGE
    Bundle.module
#else
    Bundle(for: OpenAICompatiblePlugin.self)
#endif
}()
