import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(OpenAIPlugin)
final class OpenAIPlugin: NSObject, TranscriptionEnginePlugin, LLMProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.openai"
    static let pluginName = "OpenAI"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _fetchedLLMModels: [OpenAIFetchedModel] = []

    private let transcriptionHelper = PluginOpenAITranscriptionHelper(
        baseURL: "https://api.openai.com",
        responseFormat: "verbose_json"
    )

    private let chatHelper = PluginOpenAIChatHelper(
        baseURL: "https://api.openai.com"
    )

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        if let data = host.userDefault(forKey: "fetchedLLMModels") as? Data,
           let models = try? JSONDecoder().decode([OpenAIFetchedModel].self, from: data) {
            _fetchedLLMModels = models
        }
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? transcriptionModels.first?.id
        _selectedLLMModelId = host.userDefault(forKey: "selectedLLMModel") as? String
            ?? supportedModels.first?.id
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "openai" }
    var providerDisplayName: String { "OpenAI" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "whisper-1", displayName: "Whisper 1"),
            PluginModelInfo(id: "gpt-4o-transcribe", displayName: "GPT-4o Transcribe"),
            PluginModelInfo(id: "gpt-4o-mini-transcribe", displayName: "GPT-4o Mini Transcribe"),
        ]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { true }

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

        // GPT-4o models use "json" format, Whisper uses "verbose_json"
        let responseFormat = modelId.hasPrefix("gpt-4o") ? "json" : "verbose_json"

        return try await transcriptionHelper.transcribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelId,
            language: language,
            translate: translate && !modelId.hasPrefix("gpt-4o"), // GPT-4o doesn't support translation
            prompt: prompt,
            responseFormat: responseFormat
        )
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "OpenAI" }

    var isAvailable: Bool { isConfigured }

    private static let fallbackLLMModels: [PluginModelInfo] = [
        PluginModelInfo(id: "gpt-4.1-nano", displayName: "GPT-4.1 Nano"),
        PluginModelInfo(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini"),
        PluginModelInfo(id: "gpt-4.1", displayName: "GPT-4.1"),
        PluginModelInfo(id: "gpt-4o", displayName: "GPT-4o"),
        PluginModelInfo(id: "gpt-4o-mini", displayName: "GPT-4o Mini"),
        PluginModelInfo(id: "o4-mini", displayName: "o4-mini"),
    ]

    var supportedModels: [PluginModelInfo] {
        if !_fetchedLLMModels.isEmpty {
            return _fetchedLLMModels.map { PluginModelInfo(id: $0.id, displayName: $0.id) }
        }
        return Self.fallbackLLMModels
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginChatError.notConfigured
        }
        let modelId = model ?? _selectedLLMModelId ?? supportedModels.first!.id
        return try await chatHelper.process(
            apiKey: apiKey,
            model: modelId,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokenParameter: Self.outputTokenParameter(for: modelId)
        )
    }

    func selectLLMModel(_ modelId: String) {
        _selectedLLMModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedLLMModel")
    }

    var selectedLLMModelId: String? { _selectedLLMModelId }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(OpenAISettingsView(plugin: self))
    }

    // Internal methods for settings
    func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[OpenAIPlugin] Failed to store API key: \(error)")
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
                print("[OpenAIPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func validateApiKey(_ key: String) async -> Bool {
        await transcriptionHelper.validateApiKey(key)
    }

    fileprivate func setFetchedLLMModels(_ models: [OpenAIFetchedModel]) {
        _fetchedLLMModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: "fetchedLLMModels")
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func fetchLLMModels() async -> [OpenAIFetchedModel] {
        guard let apiKey = _apiKey, !apiKey.isEmpty,
              let url = URL(string: "https://api.openai.com/v1/models") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }

            struct ModelsResponse: Decodable {
                let data: [OpenAIFetchedModel]
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data
                .filter { Self.isChatModel($0.id) }
                .sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }

    private static let chatPrefixes = ["gpt-", "o1-", "o3-", "o4-", "chatgpt-"]
    private static let excludeSuffixes = ["-transcribe", "-tts", "-embedding", "-realtime", "-search"]
    private static let excludeContains = ["dall-e", "whisper", "tts-", "text-embedding", "audio-preview", "gpt-image"]

    nonisolated static func isChatModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        guard chatPrefixes.contains(where: { lowered.hasPrefix($0) }) else { return false }
        if excludeSuffixes.contains(where: { lowered.hasSuffix($0) }) { return false }
        if excludeContains.contains(where: { lowered.contains($0) }) { return false }
        return true
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
}

// MARK: - Fetched Model

struct OpenAIFetchedModel: Codable, Sendable {
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

private struct OpenAISettingsView: View {
    let plugin: OpenAIPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var selectedLLMModel: String = ""
    @State private var fetchedLLMModels: [OpenAIFetchedModel] = []
    private let bundle = Bundle(for: OpenAIPlugin.self)

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

                    if selectedModel.hasPrefix("gpt-4o") {
                        Text("GPT-4o models do not support Whisper Translate (translation to English).", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

                    if fetchedLLMModels.isEmpty {
                        Text("Using default models. Press Refresh to fetch all available models.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    // Keep selection if still valid, otherwise pick first
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
