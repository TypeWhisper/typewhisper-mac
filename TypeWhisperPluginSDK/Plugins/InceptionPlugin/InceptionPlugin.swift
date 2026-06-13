import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(InceptionPlugin)
final class InceptionPlugin: NSObject,
    LLMProviderPlugin,
    LLMProviderIdentityProviding,
    LLMTemperatureControllableProvider,
    LLMModelSelectable,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.inception"
    static let pluginName = "Inception"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
    fileprivate var _llmTemperatureValue: Double = 0.75
    fileprivate var _reasoningEffort: String = "medium"
    fileprivate var _outputModeRaw: String = InceptionOutputMode.streaming.rawValue
    fileprivate var _fetchedModels: [InceptionFetchedModel] = []

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        if let data = host.userDefault(forKey: "fetchedModels") as? Data,
           let models = try? JSONDecoder().decode([InceptionFetchedModel].self, from: data) {
            _fetchedModels = models
        }
        _selectedLLMModelId = host.userDefault(forKey: "selectedLLMModel") as? String
        _llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
            ?? PluginLLMTemperatureMode.providerDefault.rawValue
        _llmTemperatureValue = host.userDefault(forKey: "llmTemperatureValue") as? Double
            ?? 0.75
        _reasoningEffort = host.userDefault(forKey: "reasoningEffort") as? String
            ?? "medium"
        _outputModeRaw = host.userDefault(forKey: "outputMode") as? String
            ?? InceptionOutputMode.streaming.rawValue
    }

    func deactivate() {
        host = nil
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "Inception" }
    var providerId: String { Self.pluginId }
    var providerDisplayName: String { providerName }

    var isAvailable: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    private static let displayNames: [String: String] = [
        "mercury-2": "Mercury 2",
    ]

    private static let fallbackModels: [PluginModelInfo] = [
        PluginModelInfo(id: "mercury-2", displayName: "Mercury 2"),
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
        return try await Self.processStreamingChatCompletion(
            apiKey: apiKey,
            model: modelId,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: 8192,
            reasoningEffort: _reasoningEffort,
            temperature: providerTemperatureDirective.resolvedTemperature(applying: temperatureDirective),
            outputMode: outputMode,
            requestTimeout: 120
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
        AnyView(InceptionSettingsView(plugin: self))
    }

    func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[InceptionPlugin] Failed to store API key: \(error)")
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
                print("[InceptionPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func setReasoningEffort(_ value: String) {
        guard Self.reasoningEfforts.contains(value) else { return }
        _reasoningEffort = value
        host?.setUserDefault(value, forKey: "reasoningEffort")
    }

    func setOutputMode(_ mode: InceptionOutputMode) {
        _outputModeRaw = mode.rawValue
        host?.setUserDefault(mode.rawValue, forKey: "outputMode")
    }

    var outputMode: InceptionOutputMode {
        InceptionOutputMode(rawValue: _outputModeRaw) ?? .streaming
    }

    func validateApiKey(_ key: String) async -> Bool {
        guard !key.isEmpty,
              let url = URL(string: "https://api.inceptionlabs.ai/v1/models") else { return false }

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

    fileprivate func setFetchedModels(_ models: [InceptionFetchedModel]) {
        _fetchedModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: "fetchedModels")
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func fetchModels() async -> [InceptionFetchedModel] {
        guard let apiKey = _apiKey, !apiKey.isEmpty,
              let url = URL(string: "https://api.inceptionlabs.ai/v1/models") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }

            struct ModelsResponse: Decodable {
                let data: [InceptionFetchedModel]
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let chatModels = decoded.data.filter { $0.isChatCompletionsModel }
            return chatModels.sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }

    fileprivate static let reasoningEfforts = ["instant", "low", "medium", "high"]

    private static func processStreamingChatCompletion(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int,
        reasoningEffort: String,
        temperature: Double?,
        outputMode: InceptionOutputMode,
        requestTimeout: TimeInterval
    ) async throws -> String {
        guard let url = URL(string: "https://api.inceptionlabs.ai/v1/chat/completions") else {
            throw PluginChatError.apiError("Invalid Inception chat URL")
        }

        var requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
            "max_tokens": maxOutputTokens,
            "reasoning_effort": reasoningEffort,
            "stream": true,
        ]

        if let temperature {
            requestBody["temperature"] = temperature
        }

        if outputMode == .diffusion {
            requestBody["diffusing"] = true
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
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
            throw PluginChatError.apiError(errorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let content = try parseStreamingContent(from: data, outputMode: outputMode)
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseStreamingContent(from data: Data, outputMode: InceptionOutputMode) throws -> String {
        guard let stream = String(data: data, encoding: .utf8) else {
            throw PluginChatError.apiError("Failed to parse streaming response")
        }

        var accumulated = ""
        var latest = ""

        for rawLine in stream.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data: ") else { continue }

            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { continue }

            guard let payloadData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]] else {
                continue
            }

            for choice in choices {
                guard let delta = choice["delta"] as? [String: Any],
                      let content = delta["content"] as? String,
                      !content.isEmpty else {
                    continue
                }

                switch outputMode {
                case .streaming:
                    accumulated += content
                case .diffusion:
                    latest = content
                }
            }
        }

        let content = outputMode == .diffusion ? latest : accumulated
        guard !content.isEmpty else {
            throw PluginChatError.apiError("Failed to parse streaming response")
        }
        return content
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "HTTP \(statusCode)"
        }
        if let detail = object["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return "HTTP \(statusCode)"
    }
}

enum InceptionOutputMode: String, CaseIterable, Sendable {
    case streaming
    case diffusion

    var displayName: String {
        switch self {
        case .streaming:
            return "Streaming"
        case .diffusion:
            return "Diffusion"
        }
    }
}

// MARK: - Fetched Model

struct InceptionFetchedModel: Codable, Sendable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case owned_by
    }

    var isChatCompletionsModel: Bool {
        !id.localizedCaseInsensitiveContains("edit")
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

private struct InceptionSettingsView: View {
    let plugin: InceptionPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var reasoningEffort: String = "medium"
    @State private var outputMode: InceptionOutputMode = .streaming
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.75
    @State private var fetchedModels: [InceptionFetchedModel] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
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
                        Button("Remove") {
                            apiKeyInput = ""
                            validationResult = nil
                            plugin.removeApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    } else {
                        Button("Save") {
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
                        Text("Validating...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let result = validationResult {
                    HStack(spacing: 4) {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result ? .green : .red)
                        Text(result ? "Valid API Key" : "Invalid API Key")
                            .font(.caption)
                            .foregroundStyle(result ? .green : .red)
                    }
                }

                Link("Get API Key", destination: URL(string: "https://platform.inceptionlabs.ai/")!)
                    .font(.caption)
            }

            if plugin.isAvailable {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LLM Model")
                            .font(.headline)

                        Spacer()

                        Button {
                            refreshModels()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
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
                        Text("Using default models. Press Refresh to fetch available chat models.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Thinking Level")
                        .font(.headline)

                    Picker("Thinking Level", selection: $reasoningEffort) {
                        ForEach(InceptionPlugin.reasoningEfforts, id: \.self) { value in
                            Text(value.capitalized).tag(value)
                        }
                    }
                    .onChange(of: reasoningEffort) {
                        plugin.setReasoningEffort(reasoningEffort)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Output Mode")
                        .font(.headline)

                    Picker("Output Mode", selection: $outputMode) {
                        ForEach(InceptionOutputMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .onChange(of: outputMode) {
                        plugin.setOutputMode(outputMode)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperature")
                        .font(.headline)

                    Picker("Temperature Mode", selection: $llmTemperatureMode) {
                        Text("Provider Default").tag(PluginLLMTemperatureMode.providerDefault)
                        Text("Custom").tag(PluginLLMTemperatureMode.custom)
                    }
                    .onChange(of: llmTemperatureMode) {
                        plugin.setLLMTemperatureMode(llmTemperatureMode)
                    }

                    if llmTemperatureMode == .custom {
                        HStack {
                            Text("Temperature")
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

            Text("API keys are stored securely in the Keychain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            if let key = plugin._apiKey, !key.isEmpty {
                apiKeyInput = key
            }
            selectedModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
            reasoningEffort = plugin._reasoningEffort
            outputMode = plugin.outputMode
            llmTemperatureMode = plugin.llmTemperatureMode
            llmTemperatureValue = plugin.llmTemperatureValue
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
