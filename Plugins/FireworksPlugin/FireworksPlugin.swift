import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(FireworksPlugin)
final class FireworksPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, LLMProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.fireworks"
    static let pluginName = "Fireworks AI"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
    fileprivate var _llmTemperatureValue: Double = 0.3
    fileprivate var _fetchedLLMModels: [FireworksFetchedModel] = []

    private let chatHelper = PluginOpenAIChatHelper(
        baseURL: "https://api.fireworks.ai/inference"
    )

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        if let data = host.userDefault(forKey: "fetchedLLMModels") as? Data,
           let models = try? JSONDecoder().decode([FireworksFetchedModel].self, from: data) {
            _fetchedLLMModels = models
        }
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? transcriptionModels.first?.id
        _selectedLLMModelId = host.userDefault(forKey: "selectedLLMModel") as? String
            ?? supportedModels.first?.id
        _llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
            ?? PluginLLMTemperatureMode.providerDefault.rawValue
        _llmTemperatureValue = host.userDefault(forKey: "llmTemperatureValue") as? Double
            ?? 0.3
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "fireworks" }
    var providerDisplayName: String { "Fireworks AI" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "whisper-v3", displayName: "Whisper V3"),
            PluginModelInfo(id: "whisper-v3-turbo", displayName: "Whisper V3 Turbo"),
        ]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { true }
    var supportsStreaming: Bool { true }
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

    // MARK: - Transcription (Non-Streaming)

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        let baseURL = Self.transcriptionBaseURL(for: modelId)
        let helper = PluginOpenAITranscriptionHelper(baseURL: baseURL, responseFormat: "json")

        return try await helper.transcribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelId,
            language: language,
            translate: translate,
            prompt: prompt
        )
    }

    // MARK: - Transcription (Streaming Preview)

    // Uses REST for intermediate polls (lower overhead than WebSocket per call,
    // since StreamingHandler re-sends the full buffer each time anyway).
    // WebSocket streaming would open a new connection every 1.5s just to re-send
    // the same audio - REST is simpler and faster for this pattern.

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        let baseURL = Self.transcriptionBaseURL(for: modelId)
        let helper = PluginOpenAITranscriptionHelper(baseURL: baseURL, responseFormat: "json")
        let result = try await helper.transcribe(
            audio: audio, apiKey: apiKey, modelName: modelId,
            language: language, translate: translate, prompt: prompt
        )
        _ = onProgress(result.text)
        return result
    }

    // MARK: - Helpers

    private static func transcriptionBaseURL(for modelId: String) -> String {
        switch modelId {
        case "whisper-v3-turbo": return "https://audio-turbo.api.fireworks.ai"
        case "whisper-v3": return "https://audio-prod.api.fireworks.ai"
        default: return "https://audio-prod.api.fireworks.ai"
        }
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "Fireworks AI" }

    var isAvailable: Bool { isConfigured }

    private static let fallbackLLMModels: [PluginModelInfo] = [
        PluginModelInfo(id: "accounts/fireworks/models/deepseek-v3p1", displayName: "DeepSeek V3p1"),
        PluginModelInfo(id: "accounts/fireworks/models/llama-v3p3-70b-instruct", displayName: "Llama 3.3 70B"),
        PluginModelInfo(id: "accounts/fireworks/models/llama-v3p1-8b-instruct", displayName: "Llama 3.1 8B"),
        PluginModelInfo(id: "accounts/fireworks/models/qwen2p5-72b-instruct", displayName: "Qwen 2.5 72B"),
        PluginModelInfo(id: "accounts/fireworks/models/gpt-oss-120b", displayName: "GPT-OSS 120B"),
        PluginModelInfo(id: "accounts/fireworks/models/kimi-k2p5", displayName: "Kimi K2.5"),
    ]

    var supportedModels: [PluginModelInfo] {
        if !_fetchedLLMModels.isEmpty {
            return _fetchedLLMModels.map {
                PluginModelInfo(id: $0.id, displayName: $0.displayName ?? $0.id)
            }
        }
        return Self.fallbackLLMModels
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
        let modelId = model ?? _selectedLLMModelId ?? supportedModels.first!.id
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
        host?.setUserDefault(modelId, forKey: "selectedLLMModel")
    }

    var selectedLLMModelId: String? { _selectedLLMModelId }
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
        AnyView(FireworksSettingsView(plugin: self))
    }

    // Internal methods for settings
    func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[FireworksPlugin] Failed to store API key: \(error)")
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
                print("[FireworksPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func validateApiKey(_ key: String) async -> Bool {
        guard let url = URL(string: "https://api.fireworks.ai/inference/v1/models?page_size=1") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    func addCustomModel(_ modelId: String) {
        if !_fetchedLLMModels.contains(where: { $0.id == modelId }) {
            _fetchedLLMModels.insert(FireworksFetchedModel(id: modelId, displayName: modelId), at: 0)
            if let data = try? JSONEncoder().encode(_fetchedLLMModels) {
                host?.setUserDefault(data, forKey: "fetchedLLMModels")
            }
        }
        selectLLMModel(modelId)
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setFetchedLLMModels(_ models: [FireworksFetchedModel]) {
        _fetchedLLMModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: "fetchedLLMModels")
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func fetchLLMModels() async -> [FireworksFetchedModel] {
        guard let apiKey = _apiKey, !apiKey.isEmpty,
              let url = URL(string: "https://api.fireworks.ai/inference/v1/models?page_size=200") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }

            // Fireworks returns {"models": [{"name": "accounts/.../model-name", ...}]}
            // not the OpenAI format {"data": [{"id": "..."}]}
            struct FireworksModelsResponse: Decodable {
                let models: [FireworksModelEntry]?
                let data: [FireworksFetchedModel]? // OpenAI fallback
            }
            struct FireworksModelEntry: Decodable {
                let name: String
                let displayName: String?
                let kind: String?
            }

            let decoded = try JSONDecoder().decode(FireworksModelsResponse.self, from: data)

            // Prefer Fireworks-native format
            if let models = decoded.models, !models.isEmpty {
                return models
                    .filter { Self.isLLMModel($0.name) }
                    .map { FireworksFetchedModel(id: $0.name, displayName: $0.displayName) }
                    .sorted { $0.id < $1.id }
            }

            // Fallback to OpenAI format
            if let models = decoded.data {
                return models
                    .filter { Self.isLLMModel($0.id) }
                    .sorted { $0.id < $1.id }
            }

            return []
        } catch {
            return []
        }
    }

    nonisolated static func isLLMModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        let excluded = [
            "whisper", "asr", "embedding", "audio", "tts",
            "vision", "image", "stable-diffusion", "flux",
        ]
        return !excluded.contains(where: { lowered.contains($0) })
    }
}

// MARK: - Fetched Model

struct FireworksFetchedModel: Codable, Sendable {
    let id: String
    let displayName: String?

    init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }
}

// MARK: - Settings View

private struct FireworksSettingsView: View {
    let plugin: FireworksPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var selectedLLMModel: String = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var customModelId: String = ""
    @State private var fetchedLLMModels: [FireworksFetchedModel] = []
    private let bundle = Bundle(for: FireworksPlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // API Key Section
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

                    if plugin.isConfigured {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            validationResult = nil
                            plugin.removeApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    } else {
                        Button(String(localized: "Save", bundle: bundle)) {
                            saveApiKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

                    Picker("Transcription Model", selection: $selectedModel) {
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectModel(selectedModel)
                    }

}

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
                    }

                    Picker("LLM Model", selection: $selectedLLMModel) {
                        ForEach(plugin.supportedModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedLLMModel) {
                        plugin.selectLLMModel(selectedLLMModel)
                    }

                    HStack(spacing: 8) {
                        TextField("accounts/fireworks/models/...", text: $customModelId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button(String(localized: "Use", bundle: bundle)) {
                            let trimmed = customModelId.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            plugin.addCustomModel(trimmed)
                            selectedLLMModel = trimmed
                            customModelId = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(customModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text("Enter any model ID from fireworks.ai/models", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperature", bundle: bundle)
                        .font(.headline)

                    Picker("Temperature Mode", selection: $llmTemperatureMode) {
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
            selectedLLMModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
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
                let models = await plugin.fetchLLMModels()
                await MainActor.run {
                    isValidating = false
                    validationResult = true
                    if !models.isEmpty {
                        fetchedLLMModels = models
                        plugin.setFetchedLLMModels(models)
                    }
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
        Task {
            let models = await plugin.fetchLLMModels()
            await MainActor.run {
                if !models.isEmpty {
                    fetchedLLMModels = models
                    plugin.setFetchedLLMModels(models)
                    if !models.contains(where: { $0.id == selectedLLMModel }),
                       let first = models.first {
                        selectedLLMModel = first.id
                        plugin.selectLLMModel(first.id)
                    }
                }
            }
        }
    }
}
