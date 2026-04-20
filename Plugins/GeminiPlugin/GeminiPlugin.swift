import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(GeminiPlugin)
final class GeminiPlugin: NSObject, LLMProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.gemini"
    static let pluginName = "Gemini"
    private static let cachedLLMModelsKey = "fetchedLLMModels.v2"
    private static let legacyCachedLLMModelsKey = "fetchedLLMModels"
    private static let selectedLLMModelKey = "selectedLLMModel"
    private static let compatibleModelsEndpoint = "https://generativelanguage.googleapis.com/v1beta/openai/models"
    private static let modelIdPrefix = "models/"
    private static let excludedCompatibleModelTokens = [
        "embedding",
        "-image",
        "tts",
        "live",
        "audio",
        "robotics",
        "computer-use",
        "deep-research",
    ]

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
    fileprivate var _llmTemperatureValue: Double = 0.3
    fileprivate var _fetchedLLMModels: [GeminiFetchedModel] = []

    private let chatHelper = PluginOpenAIChatHelper(
        baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        chatEndpoint: "/chat/completions"
    )

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        if let data = host.userDefault(forKey: Self.cachedLLMModelsKey) as? Data,
           let models = try? JSONDecoder().decode([GeminiFetchedModel].self, from: data) {
            _fetchedLLMModels = models
        }
        host.setUserDefault(nil, forKey: Self.legacyCachedLLMModelsKey)
        _selectedLLMModelId = host.userDefault(forKey: Self.selectedLLMModelKey) as? String
        _llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
            ?? PluginLLMTemperatureMode.providerDefault.rawValue
        _llmTemperatureValue = host.userDefault(forKey: "llmTemperatureValue") as? Double
            ?? 0.3
        normalizeSelectedModel()
        refreshCompatibleModelsIfNeeded()
    }

    func deactivate() {
        host = nil
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "Gemini" }

    var isAvailable: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    private static let fallbackLLMModels: [PluginModelInfo] = [
        PluginModelInfo(id: "gemini-flash-latest", displayName: "Gemini Flash Latest"),
        PluginModelInfo(id: "gemini-pro-latest", displayName: "Gemini Pro Latest"),
        PluginModelInfo(id: "gemini-flash-lite-latest", displayName: "Gemini Flash-Lite Latest"),
    ]

    var supportedModels: [PluginModelInfo] {
        if !_fetchedLLMModels.isEmpty {
            return _fetchedLLMModels.map { PluginModelInfo(id: $0.id, displayName: $0.displayName ?? $0.id) }
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
        host?.setUserDefault(modelId, forKey: Self.selectedLLMModelKey)
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
        AnyView(GeminiSettingsView(plugin: self))
    }

    // Internal methods for settings
    func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[GeminiPlugin] Failed to store API key: \(error)")
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
                print("[GeminiPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func validateApiKey(_ key: String) async -> Bool {
        guard !key.isEmpty,
              let url = URL(string: Self.compatibleModelsEndpoint) else { return false }

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

    fileprivate func setFetchedLLMModels(_ models: [GeminiFetchedModel]) {
        _fetchedLLMModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: Self.cachedLLMModelsKey)
        }
        host?.setUserDefault(nil, forKey: Self.legacyCachedLLMModelsKey)
        normalizeSelectedModel()
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func fetchLLMModels() async -> [GeminiFetchedModel] {
        guard let apiKey = _apiKey, !apiKey.isEmpty,
              let url = URL(string: Self.compatibleModelsEndpoint) else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }
            return try Self.decodeCompatibleLLMModels(from: data)
        } catch {
            return []
        }
    }

    nonisolated static func decodeCompatibleLLMModels(from data: Data) throws -> [GeminiFetchedModel] {
        let decoded = try JSONDecoder().decode(GeminiCompatibleModelsResponse.self, from: data)
        var seenIds = Set<String>()

        return decoded.data
            .compactMap { model -> GeminiFetchedModel? in
                let normalizedId = normalizedCompatibleModelId(model.id)
                guard isCompatibleChatModelId(normalizedId),
                      seenIds.insert(normalizedId).inserted else { return nil }
                return GeminiFetchedModel(id: normalizedId, displayName: model.displayName)
            }
            .sorted { $0.id < $1.id }
    }

    nonisolated private static func normalizedCompatibleModelId(_ id: String) -> String {
        guard id.hasPrefix(modelIdPrefix) else { return id }
        return String(id.dropFirst(modelIdPrefix.count))
    }

    nonisolated private static func isCompatibleChatModelId(_ id: String) -> Bool {
        guard id.hasPrefix("gemini-") else { return false }
        return !excludedCompatibleModelTokens.contains { id.contains($0) }
    }

    private func normalizeSelectedModel() {
        let supportedIds = Set(supportedModels.map(\.id))
        guard !supportedIds.isEmpty else {
            _selectedLLMModelId = nil
            return
        }

        if let selectedModelId = _selectedLLMModelId,
           supportedIds.contains(selectedModelId) {
            return
        }

        let fallbackModelId = supportedModels.first?.id
        _selectedLLMModelId = fallbackModelId
        if let fallbackModelId {
            host?.setUserDefault(fallbackModelId, forKey: Self.selectedLLMModelKey)
        }
    }

    private func refreshCompatibleModelsIfNeeded() {
        guard _fetchedLLMModels.isEmpty,
              _apiKey?.isEmpty == false else { return }

        Task { [weak self] in
            guard let self else { return }

            let models = await self.fetchLLMModels()
            guard !models.isEmpty else { return }

            await MainActor.run {
                self.setFetchedLLMModels(models)
            }
        }
    }
}

// MARK: - OpenAI-Compatible Models API

private struct GeminiCompatibleModelsResponse: Decodable {
    let data: [GeminiCompatibleModel]
}

private struct GeminiCompatibleModel: Decodable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

// MARK: - Fetched Model

struct GeminiFetchedModel: Codable, Sendable {
    let id: String
    let displayName: String?
}

// MARK: - Settings View

private struct GeminiSettingsView: View {
    let plugin: GeminiPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var fetchedLLMModels: [GeminiFetchedModel] = []
    private let bundle = Bundle(for: GeminiPlugin.self)

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
                            refreshLLMModels()
                        } label: {
                            Label(String(localized: "Refresh", bundle: bundle), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Picker("Model", selection: $selectedModel) {
                        ForEach(plugin.supportedModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectLLMModel(selectedModel)
                    }

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
            selectedModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
            llmTemperatureMode = plugin.llmTemperatureMode
            llmTemperatureValue = plugin.llmTemperatureValue
            fetchedLLMModels = plugin._fetchedLLMModels
            if plugin.isAvailable, fetchedLLMModels.isEmpty {
                refreshLLMModels()
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
