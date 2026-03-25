import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(CerebrasPlugin)
final class CerebrasPlugin: NSObject, LLMProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.cerebras"
    static let pluginName = "Cerebras"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _fetchedModels: [CerebrasFetchedModel] = []

    private let chatHelper = PluginOpenAIChatHelper(
        baseURL: "https://api.cerebras.ai"
    )

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        if let data = host.userDefault(forKey: "fetchedModels") as? Data,
           let models = try? JSONDecoder().decode([CerebrasFetchedModel].self, from: data) {
            _fetchedModels = models
        }
        _selectedLLMModelId = host.userDefault(forKey: "selectedLLMModel") as? String
            ?? supportedModels.first?.id
    }

    func deactivate() {
        host = nil
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "Cerebras" }

    var isAvailable: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    // Nice display names for known model IDs
    private static let displayNames: [String: String] = [
        "llama3.1-8b": "Llama 3.1 8B",
        "gpt-oss-120b": "GPT-OSS 120B",
        "qwen-3-235b-a22b-instruct-2507": "Qwen 3 235B",
        "zai-glm-4.7": "ZAI GLM 4.7",
    ]

    private static let fallbackModels: [PluginModelInfo] = [
        PluginModelInfo(id: "llama3.1-8b", displayName: "Llama 3.1 8B"),
        PluginModelInfo(id: "gpt-oss-120b", displayName: "GPT-OSS 120B"),
    ]

    var supportedModels: [PluginModelInfo] {
        if _fetchedModels.isEmpty {
            return Self.fallbackModels
        }
        return _fetchedModels.map {
            PluginModelInfo(id: $0.id, displayName: Self.displayNames[$0.id] ?? $0.id)
        }
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
        AnyView(CerebrasSettingsView(plugin: self))
    }

    // Internal methods for settings
    func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[CerebrasPlugin] Failed to store API key: \(error)")
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
                print("[CerebrasPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func validateApiKey(_ key: String) async -> Bool {
        guard !key.isEmpty,
              let url = URL(string: "https://api.cerebras.ai/v1/models") else { return false }

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

    fileprivate func setFetchedModels(_ models: [CerebrasFetchedModel]) {
        _fetchedModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: "fetchedModels")
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func fetchModels() async -> [CerebrasFetchedModel] {
        guard let apiKey = _apiKey, !apiKey.isEmpty,
              let url = URL(string: "https://api.cerebras.ai/v1/models") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }

            struct ModelsResponse: Decodable {
                let data: [CerebrasFetchedModel]
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data.sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }
}

// MARK: - Fetched Model

struct CerebrasFetchedModel: Codable, Sendable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case owned_by
    }

    init(id: String, displayName: String?) {
        self.id = id
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        _ = try container.decodeIfPresent(String.self, forKey: .owned_by)
        displayName = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
    }
}

// MARK: - Settings View

private struct CerebrasSettingsView: View {
    let plugin: CerebrasPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var fetchedModels: [CerebrasFetchedModel] = []
    private let bundle = Bundle(for: CerebrasPlugin.self)

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

                    if plugin.isAvailable {
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

                Link(String(localized: "Get API Key", bundle: bundle),
                     destination: URL(string: "https://cloud.cerebras.ai/")!)
                    .font(.caption)
            }

            if plugin.isAvailable {
                Divider()

                // LLM Model Selection
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LLM Model", bundle: bundle)
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

                    Picker("LLM Model", selection: $selectedModel) {
                        ForEach(plugin.supportedModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectLLMModel(selectedModel)
                    }

                    if fetchedModels.isEmpty {
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
            selectedModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
            fetchedModels = plugin._fetchedModels
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
                let models = await plugin.fetchModels()
                await MainActor.run {
                    isValidating = false
                    validationResult = true
                    if !models.isEmpty {
                        fetchedModels = models
                        plugin.setFetchedModels(models)
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

    private func refreshModels() {
        Task {
            let models = await plugin.fetchModels()
            await MainActor.run {
                if !models.isEmpty {
                    fetchedModels = models
                    plugin.setFetchedModels(models)
                    if !models.contains(where: { $0.id == selectedModel }),
                       let first = models.first {
                        selectedModel = first.id
                        plugin.selectLLMModel(first.id)
                    }
                }
            }
        }
    }
}
