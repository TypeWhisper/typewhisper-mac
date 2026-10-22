import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(GroqPlugin)
final class GroqPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, LLMProviderPlugin, LLMTemperatureControllableProvider, LLMModelSelectable, @unchecked Sendable {
    static let pluginId = "com.typewhisper.groq"
    static let pluginName = "Groq"
    private static let transcriptionRequestTimeout: TimeInterval = 600
    static let sendDictionaryTermsKey = "sendDictionaryTerms"
    static let selectedLLMModelKey = "selectedLLMModel"
    static let fetchedLLMModelsKey = "fetchedLLMModels"
    static let fetchedLLMModelsDateKey = "fetchedLLMModelsDate"
    /// Groq's featured production model and its named replacement for the
    /// retired Llama 3.3 70B and Kimi K2 models.
    static let curatedDefaultLLMModelId = "openai/gpt-oss-120b"
    private static let fetchedLLMModelsLifetime: TimeInterval = 24 * 60 * 60

    typealias LLMModelFetcher = @Sendable (_ apiKey: String) async -> [GroqFetchedModel]

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _sendDictionaryTerms = false
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
    fileprivate var _llmTemperatureValue: Double = 0.3
    fileprivate var _fetchedLLMModels: [GroqFetchedModel] = []
    private let llmModelFetcher: LLMModelFetcher
    /// Background refresh of a stale cached model list, started on activation.
    private(set) var llmModelRefreshTask: Task<Void, Never>?
    private var llmModelRefreshGeneration = 0

    private let transcriptionHelper = PluginOpenAITranscriptionHelper(
        baseURL: "https://api.groq.com/openai",
        responseFormat: "verbose_json"
    )

    private let chatHelper = PluginOpenAIChatHelper(
        baseURL: "https://api.groq.com/openai"
    )

    required override init() {
        llmModelFetcher = { apiKey in await GroqPlugin.fetchLLMModels(apiKey: apiKey) }
        super.init()
    }

    init(llmModelFetcher: @escaping LLMModelFetcher) {
        self.llmModelFetcher = llmModelFetcher
        super.init()
    }

    func activate(host: HostServices) {
        cancelLLMModelRefresh()
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        if let data = host.userDefault(forKey: Self.fetchedLLMModelsKey) as? Data,
           let models = try? JSONDecoder().decode([GroqFetchedModel].self, from: data) {
            _fetchedLLMModels = models
        }
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? transcriptionModels.first?.id
        _sendDictionaryTerms = host.userDefault(forKey: Self.sendDictionaryTermsKey) as? Bool ?? false
        normalizeSelectedLLMModel()
        _llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
            ?? PluginLLMTemperatureMode.providerDefault.rawValue
        _llmTemperatureValue = host.userDefault(forKey: "llmTemperatureValue") as? Double
            ?? 0.3
        refreshStaleLLMModelsIfNeeded()
    }

    func deactivate() {
        cancelLLMModelRefresh()
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "groq" }
    var providerDisplayName: String { "Groq" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "whisper-large-v3", displayName: "Whisper Large V3"),
            PluginModelInfo(id: "whisper-large-v3-turbo", displayName: "Whisper Large V3 Turbo"),
        ]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { _sendDictionaryTerms ? .supported : .requiresPluginSetting }
    var sendDictionaryTerms: Bool { _sendDictionaryTerms }

    func setSendDictionaryTerms(_ enabled: Bool) {
        guard enabled != _sendDictionaryTerms else { return }
        _sendDictionaryTerms = enabled
        host?.setUserDefault(enabled, forKey: Self.sendDictionaryTermsKey)
        host?.notifyCapabilitiesChanged()
    }

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
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        return try await transcriptionHelper.transcribeCompressedAudioWithWavFallback(
            audio: audio,
            apiKey: apiKey,
            modelName: modelId,
            language: language,
            translate: translate,
            prompt: prompt,
            requestTimeout: Self.transcriptionRequestTimeout
        )
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "Groq" }

    var isAvailable: Bool { isConfigured }

    /// Groq's production chat models. Llama 3.3 70B, Llama 3.1 8B and Kimi K2
    /// were retired for on-demand accounts and now return HTTP 404. Refresh
    /// fetches the full list, including preview models.
    static let fallbackLLMModels: [PluginModelInfo] = [
        PluginModelInfo(id: "openai/gpt-oss-120b", displayName: "GPT-OSS 120B"),
        PluginModelInfo(id: "openai/gpt-oss-20b", displayName: "GPT-OSS 20B"),
    ]

    var supportedModels: [PluginModelInfo] {
        if !_fetchedLLMModels.isEmpty {
            return _fetchedLLMModels.map { PluginModelInfo(id: $0.id, displayName: $0.id) }
        }
        return Self.fallbackLLMModels
    }

    /// The model used when no valid selection exists. The fetched list is
    /// sorted by id, so its first entry is not a sensible default.
    fileprivate var defaultLLMModelId: String? {
        let models = supportedModels
        return models.first(where: { $0.id == Self.curatedDefaultLLMModelId })?.id ?? models.first?.id
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
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginChatError.notConfigured
        }
        guard let modelId = model ?? _selectedLLMModelId ?? defaultLLMModelId else {
            throw PluginChatError.notConfigured
        }
        return try await chatHelper.process(
            apiKey: apiKey,
            model: modelId,
            systemPrompt: systemPrompt,
            userText: userText,
            temperature: providerTemperatureDirective.resolvedTemperature(applying: temperatureDirective)
        )
    }

    func selectLLMModel(_ modelId: String) {
        _selectedLLMModelId = modelId
        host?.setUserDefault(modelId, forKey: Self.selectedLLMModelKey)
    }

    var selectedLLMModelId: String? { _selectedLLMModelId }
    @objc var preferredModelId: String? { _selectedLLMModelId }
    @objc var defaultModelId: String? { defaultLLMModelId }
    var llmTemperatureMode: PluginLLMTemperatureMode {
        PluginLLMTemperatureMode(rawValue: _llmTemperatureModeRaw) ?? .providerDefault
    }
    var llmTemperatureValue: Double { _llmTemperatureValue }
    fileprivate var providerTemperatureDirective: PluginLLMTemperatureDirective {
        PluginLLMTemperatureDirective(mode: llmTemperatureMode, value: _llmTemperatureValue)
    }

    func setLLMTemperatureMode(_ mode: PluginLLMTemperatureMode) {
        _llmTemperatureModeRaw = mode.rawValue
        host?.setUserDefault(mode.rawValue, forKey: "llmTemperatureMode")
    }

    func setLLMTemperatureValue(_ value: Double) {
        let clamped = min(max(value, 0.0), 2.0)
        _llmTemperatureValue = clamped
        host?.setUserDefault(clamped, forKey: "llmTemperatureValue")
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(GroqSettingsView(plugin: self))
    }

    // Internal methods for settings
    func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[GroqPlugin] Failed to store API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func removeApiKey() {
        _apiKey = nil
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: "")
            } catch {
                print("[GroqPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func validateApiKey(_ key: String) async -> Bool {
        await transcriptionHelper.validateApiKey(key)
    }

    fileprivate func setFetchedLLMModels(_ models: [GroqFetchedModel]) {
        _fetchedLLMModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: Self.fetchedLLMModelsKey)
        }
        host?.setUserDefault(Date(), forKey: Self.fetchedLLMModelsDateKey)
        normalizeSelectedLLMModel()
        host?.notifyCapabilitiesChanged()
    }

    /// Uses the saved model only while the current list still offers it, so a
    /// model Groq retired falls back to the default instead of failing every
    /// request with HTTP 404. The saved value stays, so it applies again if a
    /// later refresh lists the model.
    private func normalizeSelectedLLMModel() {
        guard let host else { return }
        let storedModelId = host.userDefault(forKey: Self.selectedLLMModelKey) as? String
        _selectedLLMModelId = storedModelId.flatMap { modelId in
            supportedModels.contains(where: { $0.id == modelId }) ? modelId : nil
        }
    }

    /// A cached list can still offer models Groq retired after it was fetched.
    /// Refresh it in the background once it is a day old, or when an earlier
    /// plugin version saved it without a date.
    private func refreshStaleLLMModelsIfNeeded() {
        guard let host, let apiKey = _apiKey, !apiKey.isEmpty, !_fetchedLLMModels.isEmpty else { return }
        if let fetchedAt = host.userDefault(forKey: Self.fetchedLLMModelsDateKey) as? Date {
            let age = Date().timeIntervalSince(fetchedAt)
            guard age < 0 || age >= Self.fetchedLLMModelsLifetime else { return }
        }

        let generation = llmModelRefreshGeneration
        let fetcher = llmModelFetcher
        llmModelRefreshTask = Task { [weak self] in
            let models = await fetcher(apiKey)
            guard !Task.isCancelled, !models.isEmpty, let self else { return }
            await MainActor.run {
                // Drop a result that arrives after deactivation or reactivation.
                // applyFetchedLLMModels drops it after a key change.
                guard self.llmModelRefreshGeneration == generation else { return }
                self.applyFetchedLLMModels(models, fetchedWith: apiKey)
            }
        }
    }

    private func cancelLLMModelRefresh() {
        llmModelRefreshGeneration += 1
        llmModelRefreshTask?.cancel()
        llmModelRefreshTask = nil
    }

    /// Fetches the model list with the given key rather than the key saved
    /// when the request starts. Pass the same key to `applyFetchedLLMModels`.
    func fetchLLMModels(for apiKey: String) async -> [GroqFetchedModel] {
        guard !apiKey.isEmpty else { return [] }
        return await llmModelFetcher(apiKey)
    }

    /// Caches a fetched list only while the plugin is active and the key it
    /// was fetched with is still the saved one, so a slow response for a
    /// replaced or removed key cannot overwrite the list and its fetch date.
    @discardableResult
    func applyFetchedLLMModels(_ models: [GroqFetchedModel], fetchedWith apiKey: String) -> Bool {
        guard !models.isEmpty, host != nil, _apiKey == apiKey else { return false }
        setFetchedLLMModels(models)
        return true
    }

    static func fetchLLMModels(apiKey: String) async -> [GroqFetchedModel] {
        guard let url = URL(string: "https://api.groq.com/openai/v1/models") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }

            struct ModelsResponse: Decodable {
                let data: [GroqFetchedModel]
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data
                .filter { Self.isLLMModel($0.id) }
                .sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }

    nonisolated static func isLLMModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        let excluded = [
            "whisper", "distil-whisper", "tool-use",
            "orpheus",       // TTS models
            "prompt-guard",  // safety/guard models
            "safeguard",     // safety/guard models
        ]
        return !excluded.contains(where: { lowered.contains($0) })
    }
}

// MARK: - Fetched Model

struct GroqFetchedModel: Codable, Sendable {
    let id: String
    let owned_by: String?

    enum CodingKeys: String, CodingKey {
        case id
        case owned_by
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        owned_by = try container.decodeIfPresent(String.self, forKey: .owned_by)
    }
}

// MARK: - Settings View

private struct GroqSettingsView: View {
    let plugin: GroqPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var sendDictionaryTerms = false
    @State private var selectedLLMModel: String = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var fetchedLLMModels: [GroqFetchedModel] = []
    private let bundle = Bundle(for: GroqPlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // API Key Section
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 8) {
                    if showApiKey {
                        TextField(String(localized: "API Key", bundle: bundle), text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel(Text("API Key", bundle: bundle))
                    } else {
                        SecureField(String(localized: "API Key", bundle: bundle), text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(Text("API Key", bundle: bundle))
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showApiKey ? Text("Hide API key", bundle: bundle) : Text("Show API key", bundle: bundle))

                    if plugin.isConfigured {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            validationResult = nil
                            plugin.removeApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                        .accessibilityLabel(Text("Remove API key", bundle: bundle))
                    } else {
                        Button(String(localized: "Save", bundle: bundle)) {
                            saveApiKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(Text("Save API key", bundle: bundle))
                    }
                }

                if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating...", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let result = validationResult {
                    HStack(spacing: 4) {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result ? .green : .red)
                            .accessibilityHidden(true)
                        Text(result ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle))
                            .font(.caption)
                            .foregroundStyle(result ? .green : .red)
                    }
                }
            }

            if plugin.isConfigured {
                Divider()

                // Transcription Model Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcription Model", bundle: bundle)
                        .font(.headline)

                    Picker(String(localized: "Transcription Model", bundle: bundle), selection: $selectedModel) {
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectModel(selectedModel)
                    }
                }

                Toggle(isOn: $sendDictionaryTerms) {
                    Text("Send dictionary terms", bundle: bundle)
                }
                .onChange(of: sendDictionaryTerms) {
                    plugin.setSendDictionaryTerms(sendDictionaryTerms)
                }
                Text("Off by default because dictionary terms can make Groq skip parts of a dictation. Dictionary corrections after transcription apply either way.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                // LLM Model Selection
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LLM Model", bundle: bundle)
                            .font(.headline)

                        Spacer()

                        Button {
                            refreshLLMModels()
                        } label: {
                            Label(String(localized: "Refresh", bundle: bundle), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(Text("Refresh LLM models", bundle: bundle))
                    }

                    // Saves only a model the user picks. Syncing the picker on
                    // appear or after a refresh must not replace a saved model
                    // the current list lacks; the plugin uses it again once
                    // a later list offers it.
                    Picker(String(localized: "LLM Model", bundle: bundle), selection: Binding(
                        get: { selectedLLMModel },
                        set: { modelId in
                            selectedLLMModel = modelId
                            plugin.selectLLMModel(modelId)
                        }
                    )) {
                        ForEach(plugin.supportedModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()

                    if fetchedLLMModels.isEmpty {
                        Text("Using default models. Press Refresh to fetch all available models.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperature", bundle: bundle)
                        .font(.headline)

                    Picker(String(localized: "Temperature Mode", bundle: bundle), selection: $llmTemperatureMode) {
                        Text("Provider Default", bundle: bundle).tag(PluginLLMTemperatureMode.providerDefault)
                        Text("Custom", bundle: bundle).tag(PluginLLMTemperatureMode.custom)
                    }
                    .onChange(of: llmTemperatureMode) {
                        plugin.setLLMTemperatureMode(llmTemperatureMode)
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
                                plugin.setLLMTemperatureValue(llmTemperatureValue)
                            }
                            .accessibilityLabel(Text("Temperature", bundle: bundle))
                    }
                }
            }

            Text("API keys are stored securely in the Keychain", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            if let key = plugin._apiKey, !key.isEmpty {
                apiKeyInput = key
            }
            selectedModel = plugin.selectedModelId ?? plugin.transcriptionModels.first?.id ?? ""
            sendDictionaryTerms = plugin.sendDictionaryTerms
            showSelectedLLMModel()
            llmTemperatureMode = plugin.llmTemperatureMode
            llmTemperatureValue = plugin.llmTemperatureValue
            fetchedLLMModels = plugin._fetchedLLMModels
        }
    }

    private func saveApiKey() {
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        plugin.setApiKey(trimmedKey)

        isValidating = true
        validationResult = nil
        Task {
            let isValid = await plugin.validateApiKey(trimmedKey)
            if isValid {
                let models = await plugin.fetchLLMModels(for: trimmedKey)
                await MainActor.run {
                    isValidating = false
                    validationResult = true
                    showFetchedLLMModels(models, fetchedWith: trimmedKey)
                }
            } else {
                await MainActor.run {
                    isValidating = false
                    validationResult = false
                }
            }
        }
    }

    private func refreshLLMModels() {
        guard let apiKey = plugin._apiKey, !apiKey.isEmpty else { return }
        Task {
            let models = await plugin.fetchLLMModels(for: apiKey)
            await MainActor.run {
                showFetchedLLMModels(models, fetchedWith: apiKey)
            }
        }
    }

    /// Shows a fetched list once the plugin cached it. The plugin drops a list
    /// fetched with a key that was replaced or removed in the meantime.
    private func showFetchedLLMModels(_ models: [GroqFetchedModel], fetchedWith apiKey: String) {
        guard plugin.applyFetchedLLMModels(models, fetchedWith: apiKey) else { return }
        fetchedLLMModels = models
        showSelectedLLMModel()
    }

    /// Shows the model requests use: the saved one while the list offers it,
    /// otherwise the recommended default rather than the alphabetically first
    /// model. Showing it does not save it.
    private func showSelectedLLMModel() {
        selectedLLMModel = plugin.selectedLLMModelId ?? plugin.defaultLLMModelId ?? ""
    }
}
