import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(ArkPlugin)
final class ArkPlugin: NSObject, LLMProviderPlugin, LLMTemperatureControllableProvider, @unchecked Sendable {
    static let pluginId = "com.typewhisper.volcengine.ark"
    static let pluginName = "Volcengine Ark"

    static let defaultBaseURL = "https://ark.cn-beijing.volces.com"
    static let apiPathPrefix = "/api/v3"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _baseURL: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _disableThinking: Bool = true
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
    fileprivate var _llmTemperatureValue: Double = 0.3
    fileprivate var _fetchedModels: [FetchedModel] = []

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _baseURL = host.userDefault(forKey: "baseURL") as? String
            ?? Self.defaultBaseURL
        _selectedLLMModelId = host.userDefault(forKey: "selectedLLMModel") as? String
        _disableThinking = host.userDefault(forKey: "disableThinking") as? Bool ?? true
        _llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
            ?? PluginLLMTemperatureMode.providerDefault.rawValue
        _llmTemperatureValue = host.userDefault(forKey: "llmTemperatureValue") as? Double ?? 0.3

        if let data = host.userDefault(forKey: "fetchedModels") as? Data {
            _fetchedModels = (try? JSONDecoder().decode([FetchedModel].self, from: data)) ?? []
        }
    }

    func deactivate() {
        host = nil
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "Volcengine Ark" }

    var isAvailable: Bool {
        guard let baseURL = _baseURL, !baseURL.isEmpty else { return false }
        guard let parsedBase = URL(string: baseURL), parsedBase.scheme?.lowercased() == "https" else { return false }
        guard let key = _apiKey, !key.isEmpty else { return false }
        return true
    }

    var supportedModels: [PluginModelInfo] {
        let chatModels = Self.filterChatModels(_fetchedModels)
        let models = chatModels.map { PluginModelInfo(id: $0.id, displayName: $0.id) }
        if models.isEmpty, let selectedId = _selectedLLMModelId, !selectedId.isEmpty {
            return [PluginModelInfo(id: selectedId, displayName: selectedId)]
        }
        return models
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
        guard let baseURL = _baseURL, !baseURL.isEmpty else {
            throw PluginChatError.notConfigured
        }
        guard let parsedBase = URL(string: baseURL), parsedBase.scheme?.lowercased() == "https" else {
            throw PluginChatError.apiError("Insecure base URL; HTTPS required")
        }
        let modelId = model ?? _selectedLLMModelId ?? ""
        guard !modelId.isEmpty else {
            throw PluginChatError.noModelSelected
        }

        guard let url = URL(string: "\(baseURL)\(Self.apiPathPrefix)/chat/completions") else {
            throw PluginChatError.apiError("Invalid base URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body: [String: Any] = [
            "model": modelId,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]
        if let temp = providerTemperatureDirective.resolvedTemperature(applying: temperatureDirective) {
            body["temperature"] = temp
        }
        if _disableThinking {
            body["thinking"] = ["type": "disabled"]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await PluginHTTPClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginChatError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw PluginChatError.invalidApiKey
        }
        if httpResponse.statusCode == 429 {
            throw PluginChatError.rateLimited
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let errMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw PluginChatError.apiError(errMsg)
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw PluginChatError.apiError("Empty response")
        }
        return content
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
        AnyView(ArkSettingsView(plugin: self))
    }

    // MARK: - Internal Methods (called from settings view)

    fileprivate func setBaseURL(_ url: String) {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        if normalized.hasSuffix(Self.apiPathPrefix) {
            normalized = String(normalized.dropLast(Self.apiPathPrefix.count))
        }
        _baseURL = normalized
        host?.setUserDefault(normalized, forKey: "baseURL")
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            try? host.storeSecret(key: "api-key", value: key)
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func removeApiKey() {
        _apiKey = nil
        if let host {
            try? host.storeSecret(key: "api-key", value: "")
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func setDisableThinking(_ value: Bool) {
        _disableThinking = value
        host?.setUserDefault(value, forKey: "disableThinking")
    }

    fileprivate var disableThinking: Bool { _disableThinking }
    fileprivate var apiKey: String? { _apiKey }
    fileprivate var baseURL: String? { _baseURL }
    fileprivate var fetchedModels: [FetchedModel] { _fetchedModels }

    fileprivate func setFetchedModels(_ models: [FetchedModel]) {
        _fetchedModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: "fetchedModels")
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func fetchModelList() async -> [FetchedModel] {
        guard let baseURL = _baseURL, !baseURL.isEmpty,
              let parsedBase = URL(string: baseURL), parsedBase.scheme?.lowercased() == "https",
              let url = URL(string: "\(baseURL)\(Self.apiPathPrefix)/models") else {
            return []
        }
        var request = URLRequest(url: url)
        if let apiKey = _apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }
            struct ModelsResponse: Decodable {
                let data: [FetchedModel]
            }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data.sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }

    static func filterChatModels(_ models: [FetchedModel]) -> [FetchedModel] {
        let exclude = [
            "seedance", "seedream", "embedding", "tts", "asr",
            "vision", "ui-tars", "seaweed", "seed3d", "seededit",
            "translation", "image", "audio"
        ]
        return models.filter { m in
            let lower = m.id.lowercased()
            return !exclude.contains { lower.contains($0) }
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

private struct ArkSettingsView: View {
    let plugin: ArkPlugin
    @State private var baseURLInput = ""
    @State private var apiKeyInput = ""
    @State private var showApiKey = false
    @State private var disableThinking = true
    @State private var isTesting = false
    @State private var connectionResult: Bool?
    @State private var connectionError: String?
    @State private var selectedLLMModel = ""
    @State private var fetchedModels: [FetchedModel] = []
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3

    private var chatModels: [FetchedModel] {
        ArkPlugin.filterChatModels(fetchedModels)
    }
    private var hasModels: Bool { !chatModels.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Server URL
            VStack(alignment: .leading, spacing: 8) {
                Text("Server URL").font(.headline)
                TextField(
                    "https://ark.cn-beijing.volces.com/api/v3",
                    text: $baseURLInput
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                Text("Default works for cn-beijing. Override for other regions.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // API Key
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key").font(.headline)
                HStack(spacing: 8) {
                    if showApiKey {
                        TextField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button { showApiKey.toggle() } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                Text("Get from console.volcengine.com → API Key Management")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Test Connection
            HStack(spacing: 8) {
                Button {
                    testConnection()
                } label: {
                    Text("Test Connection")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || isTesting)

                if let key = plugin.apiKey, !key.isEmpty {
                    Button("Remove Key") {
                        apiKeyInput = ""
                        plugin.removeApiKey()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                }

                if isTesting {
                    ProgressView().controlSize(.small)
                    Text("Testing…").font(.caption).foregroundStyle(.secondary)
                } else if let result = connectionResult {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result ? .green : .red)
                    Text(result ? "Connected" : "Connection Failed")
                        .font(.caption).foregroundStyle(result ? .green : .red)
                }
            }

            if let err = connectionError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if plugin.isAvailable {
                Divider()

                // Model selection
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Model").font(.headline)
                        Spacer()
                        Button {
                            refreshModels()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if hasModels {
                        Picker("LLM Model", selection: $selectedLLMModel) {
                            Text("None").tag("")
                            ForEach(chatModels, id: \.id) { model in
                                Text(model.id).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selectedLLMModel) {
                            plugin.selectLLMModel(selectedLLMModel)
                        }
                        Text("\(chatModels.count) chat models available (filtered from \(fetchedModels.count) total)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Click Test Connection to load models")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Thinking toggle
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Disable thinking", isOn: $disableThinking)
                        .onChange(of: disableThinking) {
                            plugin.setDisableThinking(disableThinking)
                        }
                    Text("Recommended for dictation. Reasoning models add 10–20s latency when enabled.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                // Temperature
                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperature").font(.headline)
                    Picker("Temperature Mode", selection: $llmTemperatureMode) {
                        Text("Provider Default").tag(PluginLLMTemperatureMode.providerDefault)
                        Text("Custom").tag(PluginLLMTemperatureMode.custom)
                    }
                    .onChange(of: llmTemperatureMode) {
                        plugin.setLLMTemperatureMode(llmTemperatureMode)
                    }

                    if llmTemperatureMode == .custom {
                        HStack {
                            Text("Temperature").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(llmTemperatureValue, format: .number.precision(.fractionLength(2)))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $llmTemperatureValue, in: 0...2, step: 0.1)
                            .onChange(of: llmTemperatureValue) {
                                plugin.setLLMTemperatureValue(llmTemperatureValue)
                            }
                    }
                }
            }

            Text("API key is stored securely in the macOS Keychain")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            baseURLInput = plugin.baseURL ?? ArkPlugin.defaultBaseURL
            // Show /api/v3 suffix for clarity (it's stripped on save)
            if !baseURLInput.hasSuffix(ArkPlugin.apiPathPrefix) {
                baseURLInput += ArkPlugin.apiPathPrefix
            }
            if let key = plugin.apiKey, !key.isEmpty {
                apiKeyInput = key
            }
            disableThinking = plugin.disableThinking
            fetchedModels = plugin.fetchedModels
            selectedLLMModel = plugin.selectedLLMModelId ?? ""
            llmTemperatureMode = plugin.llmTemperatureMode
            llmTemperatureValue = plugin.llmTemperatureValue
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
        connectionError = nil

        Task {
            let models = await plugin.fetchModelList()
            await MainActor.run {
                isTesting = false
                let connected = !models.isEmpty
                connectionResult = connected
                if connected {
                    fetchedModels = models
                    plugin.setFetchedModels(models)
                    reconcileSelectedModel(models)
                } else {
                    connectionError = "Failed to fetch model list. Check URL and API key."
                }
            }
        }
    }

    private func refreshModels() {
        Task {
            let models = await plugin.fetchModelList()
            await MainActor.run {
                if !models.isEmpty {
                    fetchedModels = models
                    plugin.setFetchedModels(models)
                    reconcileSelectedModel(models)
                }
            }
        }
    }

    private func reconcileSelectedModel(_ models: [FetchedModel]) {
        let chat = ArkPlugin.filterChatModels(models)
        if chat.contains(where: { $0.id == selectedLLMModel }) {
            return
        }
        let nextSelection = chat.first?.id ?? ""
        selectedLLMModel = nextSelection
        plugin.selectLLMModel(nextSelection)
    }
}
