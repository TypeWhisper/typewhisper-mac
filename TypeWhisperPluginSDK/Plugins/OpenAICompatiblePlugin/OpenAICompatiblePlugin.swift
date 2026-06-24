import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Profile Model

struct OpenAICompatibleProfile: Codable, Equatable, Identifiable, Sendable {
    static let defaultId = "openai-compatible"
    static let defaultName = "OpenAI Compatible"

    var id: String
    var name: String
    var baseURL: String
    var selectedModelId: String
    var selectedLLMModelId: String
    var llmTemperatureModeRaw: String
    var llmTemperatureValue: Double
    var fetchedModels: [FetchedModel]
    var chatRequestTimeoutSeconds: TimeInterval?
    var thinkingEnabled: Bool

    static let defaultChatRequestTimeout: TimeInterval = 30
    static let minChatRequestTimeout: TimeInterval = 5
    static let maxChatRequestTimeout: TimeInterval = 3600

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case selectedModelId
        case selectedLLMModelId
        case llmTemperatureModeRaw
        case llmTemperatureValue
        case fetchedModels
        case chatRequestTimeoutSeconds
        case thinkingEnabled
    }

    init(
        id: String,
        name: String,
        baseURL: String = "",
        selectedModelId: String = "",
        selectedLLMModelId: String = "",
        llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue,
        llmTemperatureValue: Double = 0.3,
        fetchedModels: [FetchedModel] = [],
        chatRequestTimeoutSeconds: TimeInterval? = nil,
        thinkingEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.selectedModelId = selectedModelId
        self.selectedLLMModelId = selectedLLMModelId
        self.llmTemperatureModeRaw = llmTemperatureModeRaw
        self.llmTemperatureValue = llmTemperatureValue
        self.fetchedModels = fetchedModels
        self.chatRequestTimeoutSeconds = chatRequestTimeoutSeconds
        self.thinkingEnabled = thinkingEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        selectedModelId = try container.decode(String.self, forKey: .selectedModelId)
        selectedLLMModelId = try container.decode(String.self, forKey: .selectedLLMModelId)
        llmTemperatureModeRaw = try container.decode(String.self, forKey: .llmTemperatureModeRaw)
        llmTemperatureValue = try container.decode(Double.self, forKey: .llmTemperatureValue)
        fetchedModels = try container.decode([FetchedModel].self, forKey: .fetchedModels)
        chatRequestTimeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .chatRequestTimeoutSeconds)
        thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
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

    static func defaultProfile(
        baseURL: String = "",
        selectedModelId: String = "",
        selectedLLMModelId: String = "",
        llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue,
        llmTemperatureValue: Double = 0.3,
        fetchedModels: [FetchedModel] = [],
        chatRequestTimeoutSeconds: TimeInterval? = nil,
        thinkingEnabled: Bool = false
    ) -> OpenAICompatibleProfile {
        OpenAICompatibleProfile(
            id: defaultId,
            name: defaultName,
            baseURL: baseURL,
            selectedModelId: selectedModelId,
            selectedLLMModelId: selectedLLMModelId,
            llmTemperatureModeRaw: llmTemperatureModeRaw,
            llmTemperatureValue: llmTemperatureValue,
            fetchedModels: fetchedModels,
            chatRequestTimeoutSeconds: chatRequestTimeoutSeconds,
            thinkingEnabled: thinkingEnabled
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
        guard let profile = profile(for: profileId),
              let helper = makeTranscriptionHelper(for: profile) else {
            throw PluginTranscriptionError.notConfigured
        }
        let modelId = profile.selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelId.isEmpty else {
            throw PluginTranscriptionError.noModelSelected
        }

        return try await helper.transcribe(
            audio: audio,
            apiKey: apiKey(for: profileId) ?? "",
            modelName: modelId,
            language: language,
            translate: translate,
            prompt: prompt,
            requestTimeout: Self.transcriptionRequestTimeout
        )
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
        return try await processChatCompletion(
            apiKey: apiKey(for: profileId) ?? "",
            baseURL: profile.baseURL,
            model: modelId,
            systemPrompt: systemPrompt,
            userText: userText,
            temperature: providerTemperatureDirective(for: profileId).resolvedTemperature(applying: temperatureDirective),
            requestTimeout: profile.resolvedChatRequestTimeout,
            thinkingEnabled: profile.thinkingEnabled
        )
    }

    func fetchModels() async -> [FetchedModel] {
        await fetchModels(for: OpenAICompatibleProfile.defaultId)
    }

    func fetchModels(for profileId: String) async -> [FetchedModel] {
        guard let profile = profile(for: profileId),
              !profile.baseURL.isEmpty,
              let url = URL(string: "\(profile.baseURL)/v1/models") else { return [] }

        var request = URLRequest(url: url)
        if let apiKey = apiKey(for: profileId), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
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
              let url = URL(string: "\(profile.baseURL)/v1/models") else { return false }

        var request = URLRequest(url: url)
        if let apiKey = apiKey(for: profileId), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
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
                selectedModelId: host.userDefault(forKey: "selectedModel") as? String ?? "",
                selectedLLMModelId: host.userDefault(forKey: "selectedLLMModel") as? String ?? "",
                llmTemperatureModeRaw: host.userDefault(forKey: "llmTemperatureMode") as? String
                    ?? PluginLLMTemperatureMode.providerDefault.rawValue,
                llmTemperatureValue: host.userDefault(forKey: "llmTemperatureValue") as? Double ?? 0.3,
                fetchedModels: fetchedModels
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
            seenIds.insert(profile.id)
            result.append(profile)
        }

        if !seenIds.contains(OpenAICompatibleProfile.defaultId) {
            result.insert(
                .defaultProfile(
                    baseURL: Self.normalizedBaseURL(host.userDefault(forKey: "baseURL") as? String ?? ""),
                    selectedModelId: host.userDefault(forKey: "selectedModel") as? String ?? "",
                    selectedLLMModelId: host.userDefault(forKey: "selectedLLMModel") as? String ?? ""
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
        host.setUserDefault(defaultProfile.selectedModelId, forKey: "selectedModel")
        host.setUserDefault(defaultProfile.selectedLLMModelId, forKey: "selectedLLMModel")
        host.setUserDefault(defaultProfile.llmTemperatureModeRaw, forKey: "llmTemperatureMode")
        host.setUserDefault(defaultProfile.llmTemperatureValue, forKey: "llmTemperatureValue")
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

    nonisolated static func outputTokenParameter(for modelID: String) -> String {
        let lowered = modelID.lowercased()
        if lowered.hasPrefix("gpt-5")
            || lowered.hasPrefix("o1")
            || lowered.hasPrefix("o3")
            || lowered.hasPrefix("o4") {
            return "max_completion_tokens"
        }
        return "max_tokens"
    }

    private func processChatCompletion(
        apiKey: String,
        baseURL: String,
        model: String,
        systemPrompt: String,
        userText: String,
        temperature: Double?,
        requestTimeout: TimeInterval,
        thinkingEnabled: Bool
    ) async throws -> String {
        let endpoint = "\(baseURL)/v1/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw PluginChatError.apiError("Invalid URL: \(endpoint)")
        }

        var requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
            "thinking": [
                "type": thinkingEnabled ? "enabled" : "disabled"
            ],
        ]
        requestBody[Self.outputTokenParameter(for: model)] = 4096
        if let temperature {
            requestBody["temperature"] = temperature
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        if normalized.hasSuffix("/v1") {
            normalized = String(normalized.dropLast(3))
        }
        return normalized
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
                    thinkingModeSection
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
        }
    }

    private var thinkingModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Toggle(isOn: $thinkingEnabled) {
                Text("Thinking Mode", bundle: bundle)
                    .font(.headline)
            }
            .onChange(of: thinkingEnabled) {
                guard let selectedProfile else { return }
                plugin.setThinkingEnabled(thinkingEnabled, for: selectedProfile.id)
                reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
            }
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
        apiKeyInput = plugin.apiKey(for: profile.id) ?? ""
        selectedTranscriptionModel = profile.selectedModelId
        selectedLLMModel = profile.selectedLLMModelId
        manualTranscriptionModel = profile.selectedModelId
        manualLLMModel = profile.selectedLLMModelId
        llmTemperatureMode = PluginLLMTemperatureMode(rawValue: profile.llmTemperatureModeRaw) ?? .providerDefault
        llmTemperatureValue = profile.llmTemperatureValue
        thinkingEnabled = profile.thinkingEnabled
        chatTimeoutInput = String(Int(profile.resolvedChatRequestTimeout))
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

    private func saveProfileName() {
        guard let selectedProfile else { return }
        let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != selectedProfile.displayName else { return }

        plugin.renameProfile(selectedProfile.id, to: trimmed)
        reloadProfiles(selecting: selectedProfile.id, preserveInputs: true)
    }

    private func saveServerFields(for profileId: String) {
        plugin.setBaseURL(baseURLInput, for: profileId)
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
