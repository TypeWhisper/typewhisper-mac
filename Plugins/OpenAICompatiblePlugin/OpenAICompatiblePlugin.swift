import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(OpenAICompatiblePlugin)
final class OpenAICompatiblePlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, LLMProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.openai-compatible"
    static let pluginName = "OpenAI Compatible"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _baseURL: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _fetchedModels: [FetchedModel] = []

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _baseURL = host.userDefault(forKey: "baseURL") as? String
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
        _selectedLLMModelId = host.userDefault(forKey: "selectedLLMModel") as? String

        if let data = host.userDefault(forKey: "fetchedModels") as? Data {
            _fetchedModels = (try? JSONDecoder().decode([FetchedModel].self, from: data)) ?? []
        }
    }

    func deactivate() {
        host = nil
    }

    // MARK: - Helper Creation

    private func makeTranscriptionHelper() -> PluginOpenAITranscriptionHelper? {
        guard let baseURL = _baseURL, !baseURL.isEmpty else { return nil }
        return PluginOpenAITranscriptionHelper(baseURL: baseURL, responseFormat: "json")
    }

    private func makeChatHelper() -> PluginOpenAIChatHelper? {
        guard let baseURL = _baseURL, !baseURL.isEmpty else { return nil }
        return PluginOpenAIChatHelper(baseURL: baseURL)
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "openai-compatible" }
    var providerDisplayName: String { "Custom Server (Whisper)" }

    var isConfigured: Bool {
        guard let baseURL = _baseURL else { return false }
        return !baseURL.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        let models = _fetchedModels.map { PluginModelInfo(id: $0.id, displayName: $0.id) }
        if models.isEmpty, let selectedId = _selectedModelId, !selectedId.isEmpty {
            return [PluginModelInfo(id: selectedId, displayName: selectedId)]
        }
        return models
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
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
        guard let helper = makeTranscriptionHelper() else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId, !modelId.isEmpty else {
            throw PluginTranscriptionError.noModelSelected
        }

        return try await helper.transcribe(
            audio: audio,
            apiKey: _apiKey ?? "",
            modelName: modelId,
            language: language,
            translate: translate,
            prompt: prompt
        )
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "OpenAI Compatible" }

    var isAvailable: Bool { isConfigured }

    var supportedModels: [PluginModelInfo] {
        let models = _fetchedModels.map { PluginModelInfo(id: $0.id, displayName: $0.id) }
        if models.isEmpty, let selectedId = _selectedLLMModelId, !selectedId.isEmpty {
            return [PluginModelInfo(id: selectedId, displayName: selectedId)]
        }
        return models
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        guard let helper = makeChatHelper() else {
            throw PluginChatError.notConfigured
        }
        let modelId = model ?? _selectedLLMModelId ?? ""
        guard !modelId.isEmpty else {
            throw PluginChatError.noModelSelected
        }
        return try await helper.process(
            apiKey: _apiKey ?? "",
            model: modelId,
            systemPrompt: systemPrompt,
            userText: userText
        )
    }

    func selectLLMModel(_ modelId: String) {
        _selectedLLMModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedLLMModel")
    }

    var selectedLLMModelId: String? { _selectedLLMModelId }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(OpenAICompatibleSettingsView(plugin: self))
    }

    // MARK: - Internal Methods

    fileprivate func setBaseURL(_ url: String) {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        if normalized.hasSuffix("/v1") {
            normalized = String(normalized.dropLast(3))
        }
        _baseURL = normalized
        host?.setUserDefault(normalized, forKey: "baseURL")
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[OpenAICompatiblePlugin] Failed to store API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func removeApiKey() {
        _apiKey = nil
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: "")
            } catch {
                print("[OpenAICompatiblePlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func setFetchedModels(_ models: [FetchedModel]) {
        _fetchedModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: "fetchedModels")
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func fetchModels() async -> [FetchedModel] {
        guard let baseURL = _baseURL, !baseURL.isEmpty,
              let url = URL(string: "\(baseURL)/v1/models") else { return [] }

        var request = URLRequest(url: url)
        if let apiKey = _apiKey, !apiKey.isEmpty {
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

    fileprivate func validateConnection() async -> Bool {
        guard let baseURL = _baseURL, !baseURL.isEmpty,
              let url = URL(string: "\(baseURL)/v1/models") else { return false }

        var request = URLRequest(url: url)
        if let apiKey = _apiKey, !apiKey.isEmpty {
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
}

// MARK: - Fetched Model

struct FetchedModel: Codable, Sendable {
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

private struct OpenAICompatibleSettingsView: View {
    let plugin: OpenAICompatiblePlugin
    @State private var baseURLInput = ""
    @State private var apiKeyInput = ""
    @State private var showApiKey = false
    @State private var isTesting = false
    @State private var connectionResult: Bool?
    @State private var selectedTranscriptionModel = ""
    @State private var selectedLLMModel = ""
    @State private var manualTranscriptionModel = ""
    @State private var manualLLMModel = ""
    @State private var fetchedModels: [FetchedModel] = []
    private let bundle = Bundle(for: OpenAICompatiblePlugin.self)

    private var hasModels: Bool { !fetchedModels.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Server URL Section
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
                }

                Text("Optional for local servers like Ollama or LM Studio", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Connect Button
            HStack(spacing: 8) {
                Button {
                    testConnection()
                } label: {
                    Text("Test Connection", bundle: bundle)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                if plugin.isConfigured && plugin._apiKey != nil {
                    Button(String(localized: "Remove", bundle: bundle)) {
                        apiKeyInput = ""
                        plugin.removeApiKey()
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

            if plugin.isConfigured {
                Divider()

                // Model Selection
                VStack(alignment: .leading, spacing: 12) {
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
                    }

                    if hasModels {
                        // Transcription Model Picker
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Transcription Model", bundle: bundle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Picker("Transcription Model", selection: $selectedTranscriptionModel) {
                                Text(String(localized: "None", bundle: bundle)).tag("")
                                ForEach(fetchedModels, id: \.id) { model in
                                    Text(model.id).tag(model.id)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: selectedTranscriptionModel) {
                                plugin.selectModel(selectedTranscriptionModel)
                            }
                        }

                        // LLM Model Picker
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LLM Model", bundle: bundle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Picker("LLM Model", selection: $selectedLLMModel) {
                                Text(String(localized: "None", bundle: bundle)).tag("")
                                ForEach(fetchedModels, id: \.id) { model in
                                    Text(model.id).tag(model.id)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: selectedLLMModel) {
                                plugin.selectLLMModel(selectedLLMModel)
                            }
                        }
                    } else {
                        // Manual model entry fallback
                        Text("No models found. Enter model name manually.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Transcription Model", bundle: bundle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                TextField(String(localized: "Model name", bundle: bundle), text: $manualTranscriptionModel)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .onSubmit {
                                        let trimmed = manualTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if !trimmed.isEmpty {
                                            plugin.selectModel(trimmed)
                                        }
                                    }

                                Button(String(localized: "Save", bundle: bundle)) {
                                    let trimmed = manualTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        plugin.selectModel(trimmed)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(manualTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("LLM Model", bundle: bundle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                TextField(String(localized: "Model name", bundle: bundle), text: $manualLLMModel)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .onSubmit {
                                        let trimmed = manualLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if !trimmed.isEmpty {
                                            plugin.selectLLMModel(trimmed)
                                        }
                                    }

                                Button(String(localized: "Save", bundle: bundle)) {
                                    let trimmed = manualLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        plugin.selectLLMModel(trimmed)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(manualLLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
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
            baseURLInput = plugin._baseURL ?? ""
            if let key = plugin._apiKey, !key.isEmpty {
                apiKeyInput = key
            }
            fetchedModels = plugin._fetchedModels
            selectedTranscriptionModel = plugin.selectedModelId ?? ""
            selectedLLMModel = plugin.selectedLLMModelId ?? ""
            manualTranscriptionModel = plugin.selectedModelId ?? ""
            manualLLMModel = plugin.selectedLLMModelId ?? ""
        }
    }

    private func testConnection() {
        let trimmedURL = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        plugin.setBaseURL(trimmedURL)
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            plugin.setApiKey(trimmedKey)
        }

        isTesting = true
        connectionResult = nil
        Task {
            let models = await plugin.fetchModels()
            var isConnected = !models.isEmpty
            if !isConnected {
                isConnected = await plugin.validateConnection()
            }
            await MainActor.run {
                isTesting = false
                connectionResult = isConnected
                if isConnected {
                    fetchedModels = models
                    plugin.setFetchedModels(models)
                    // Auto-select first model if nothing selected
                    if selectedTranscriptionModel.isEmpty, let first = models.first {
                        selectedTranscriptionModel = first.id
                        plugin.selectModel(first.id)
                    }
                    if selectedLLMModel.isEmpty, let first = models.first {
                        selectedLLMModel = first.id
                        plugin.selectLLMModel(first.id)
                    }
                }
            }
        }
    }

    private func refreshModels() {
        Task {
            let models = await plugin.fetchModels()
            await MainActor.run {
                fetchedModels = models
                plugin.setFetchedModels(models)
            }
        }
    }
}
