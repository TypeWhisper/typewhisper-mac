import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(OpenRouterPlugin)
final class OpenRouterPlugin: NSObject, LLMProviderPlugin, LLMModelSelectable, @unchecked Sendable {
    static let pluginId = "com.typewhisper.openrouter"
    static let pluginName = "OpenRouter"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
    fileprivate var _llmTemperatureValue: Double = 0.3
    fileprivate var _fetchedModels: [OpenRouterFetchedModel] = []

    private let chatHelper = PluginOpenAIChatHelper(
        baseURL: "https://openrouter.ai/api"
    )

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        if let data = host.userDefault(forKey: "fetchedModels") as? Data,
           let models = try? JSONDecoder().decode([OpenRouterFetchedModel].self, from: data) {
            _fetchedModels = models
        }
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

    // MARK: - LLMProviderPlugin

    var providerName: String { "OpenRouter" }

    var isAvailable: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    private static let fallbackModels: [PluginModelInfo] = [
        PluginModelInfo(id: "openai/gpt-4o", displayName: "OpenAI: GPT-4o"),
        PluginModelInfo(id: "anthropic/claude-sonnet-4", displayName: "Anthropic: Claude Sonnet 4"),
        PluginModelInfo(id: "google/gemini-2.5-flash-preview", displayName: "Google: Gemini 2.5 Flash"),
        PluginModelInfo(id: "meta-llama/llama-3.3-70b-instruct", displayName: "Meta: Llama 3.3 70B"),
    ]

    var supportedModels: [PluginModelInfo] {
        if _fetchedModels.isEmpty {
            return Self.fallbackModels
        }
        return _fetchedModels.map {
            PluginModelInfo(id: $0.id, displayName: $0.name)
        }
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
    @objc var preferredModelId: String? { _selectedLLMModelId }
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
        AnyView(OpenRouterSettingsView(plugin: self))
    }

    // MARK: - API Key Management

    func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[OpenRouterPlugin] Failed to store API key: \(error)")
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
                print("[OpenRouterPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func validateApiKey(_ key: String) async -> Bool {
        guard !key.isEmpty,
              let url = URL(string: "https://openrouter.ai/api/v1/auth/key") else { return false }

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

    // MARK: - Model Fetching

    fileprivate func setFetchedModels(_ models: [OpenRouterFetchedModel]) {
        _fetchedModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: "fetchedModels")
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func fetchModels() async -> [OpenRouterFetchedModel] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else { return [] }

        var request = URLRequest(url: url)
        if let apiKey = _apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }

            let decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
            return decoded.data
                .filter { Self.isTextLLM($0) }
                .map { model in
                    OpenRouterFetchedModel(
                        id: model.id,
                        name: model.name,
                        promptPrice: model.pricing?.prompt ?? "0",
                        completionPrice: model.pricing?.completion ?? "0"
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            return []
        }
    }

    private static func isTextLLM(_ model: OpenRouterAPIModel) -> Bool {
        let modality = model.architecture?.modality ?? ""
        if !modality.isEmpty {
            return modality.hasSuffix("->text")
        }
        let lowered = model.id.lowercased()
        let excluded = ["embed", "tts", "audio", "image-gen", "dall-e", "stable-diffusion",
                        "midjourney", "whisper", "moderation"]
        return !excluded.contains(where: { lowered.contains($0) })
    }

    // MARK: - Credits

    fileprivate func fetchCredits() async -> Double? {
        guard let apiKey = _apiKey, !apiKey.isEmpty,
              let url = URL(string: "https://openrouter.ai/api/v1/auth/key") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any] else { return nil }

            if let limit = dataObj["limit"] as? Double,
               let usage = dataObj["usage"] as? Double {
                return limit - usage
            }
            if let limitCredits = dataObj["limit_remaining"] as? Double {
                return limitCredits
            }
            return nil
        } catch {
            return nil
        }
    }
}

// MARK: - API Response Models

private struct OpenRouterModelsResponse: Decodable {
    let data: [OpenRouterAPIModel]
}

private struct OpenRouterAPIModel: Decodable {
    let id: String
    let name: String
    let pricing: OpenRouterPricing?
    let architecture: OpenRouterArchitecture?
}

private struct OpenRouterPricing: Decodable {
    let prompt: String?
    let completion: String?
}

private struct OpenRouterArchitecture: Decodable {
    let modality: String?
}

// MARK: - Fetched Model (persisted)

struct OpenRouterFetchedModel: Codable, Sendable {
    let id: String
    let name: String
    let promptPrice: String
    let completionPrice: String

    var formattedPricing: String {
        let promptPer1M = (Double(promptPrice) ?? 0) * 1_000_000
        let completionPer1M = (Double(completionPrice) ?? 0) * 1_000_000
        if promptPer1M == 0 && completionPer1M == 0 {
            return String(localized: "Free", bundle: Bundle(for: OpenRouterPlugin.self))
        }
        return String(format: "$%.2f/$%.2f per 1M", promptPer1M, completionPer1M)
    }
}

// MARK: - Settings View

private struct OpenRouterSettingsView: View {
    let plugin: OpenRouterPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var fetchedModels: [OpenRouterFetchedModel] = []
    @State private var searchText = ""
    @State private var remainingCredits: Double?
    private let bundle = Bundle(for: OpenRouterPlugin.self)

    private var filteredModels: [OpenRouterFetchedModel] {
        if searchText.isEmpty { return fetchedModels }
        let query = searchText.lowercased()
        return fetchedModels.filter {
            $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
    }

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
                            remainingCredits = nil
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

                if let credits = remainingCredits {
                    HStack(spacing: 4) {
                        Image(systemName: "creditcard")
                            .foregroundStyle(.secondary)
                        Text("Remaining: $\(String(format: "%.2f", credits))", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Link(String(localized: "Get API Key", bundle: bundle),
                     destination: URL(string: "https://openrouter.ai/keys")!)
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

                    TextField(String(localized: "Search models...", bundle: bundle), text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    let models = filteredModels
                    Picker("LLM Model", selection: $selectedModel) {
                        ForEach(models, id: \.id) { model in
                            Text("\(model.name) - \(model.formattedPricing)").tag(model.id)
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
            fetchedModels = plugin._fetchedModels
            selectedModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
            llmTemperatureMode = plugin.llmTemperatureMode
            llmTemperatureValue = plugin.llmTemperatureValue

            if plugin.isAvailable {
                Task {
                    if let credits = await plugin.fetchCredits() {
                        await MainActor.run {
                            remainingCredits = credits
                        }
                    }
                }
            }
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
                async let modelsTask = plugin.fetchModels()
                async let creditsTask = plugin.fetchCredits()
                let (models, credits) = await (modelsTask, creditsTask)
                await MainActor.run {
                    isValidating = false
                    validationResult = true
                    remainingCredits = credits
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
