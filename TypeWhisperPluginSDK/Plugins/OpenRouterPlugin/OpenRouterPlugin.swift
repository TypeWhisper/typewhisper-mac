import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(OpenRouterPlugin)
final class OpenRouterPlugin: NSObject,
    TranscriptionEnginePlugin,
    DictionaryTermsCapabilityProviding,
    LLMProviderPlugin,
    LLMModelSelectable,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.openrouter"
    static let pluginName = "OpenRouter"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
    fileprivate var _llmTemperatureValue: Double = 0.3
    fileprivate var _fetchedLLMModels: [OpenRouterFetchedModel] = []
    fileprivate var _fetchedTranscriptionModels: [OpenRouterFetchedModel] = []

    private static let chatRequestTimeout: TimeInterval = 30
    private static let transcriptionRequestTimeout: TimeInterval = 120

    private enum StorageKeys {
        static let apiKey = "api-key"
        static let selectedModel = "selectedModel"
        static let selectedLLMModel = "selectedLLMModel"
        static let llmTemperatureMode = "llmTemperatureMode"
        static let llmTemperatureValue = "llmTemperatureValue"
        static let fetchedModels = "fetchedModels"
        static let fetchedTranscriptionModels = "fetchedTranscriptionModels"
    }

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: Self.StorageKeys.apiKey)
        if let data = host.userDefault(forKey: Self.StorageKeys.fetchedModels) as? Data,
           let models = try? JSONDecoder().decode([OpenRouterFetchedModel].self, from: data) {
            _fetchedLLMModels = models
        }
        if let data = host.userDefault(forKey: Self.StorageKeys.fetchedTranscriptionModels) as? Data,
           let models = try? JSONDecoder().decode([OpenRouterFetchedModel].self, from: data) {
            _fetchedTranscriptionModels = models
        }
        _selectedModelId = Self.resolvedStoredModelId(
            host.userDefault(forKey: Self.StorageKeys.selectedModel) as? String,
            availableModels: transcriptionModels,
            storageKey: Self.StorageKeys.selectedModel,
            host: host
        )
        _selectedLLMModelId = Self.resolvedStoredModelId(
            host.userDefault(forKey: Self.StorageKeys.selectedLLMModel) as? String,
            availableModels: supportedModels,
            storageKey: Self.StorageKeys.selectedLLMModel,
            host: host
        )
        _llmTemperatureModeRaw = host.userDefault(forKey: Self.StorageKeys.llmTemperatureMode) as? String
            ?? PluginLLMTemperatureMode.providerDefault.rawValue
        _llmTemperatureValue = host.userDefault(forKey: Self.StorageKeys.llmTemperatureValue) as? Double
            ?? 0.3
    }

    private static func resolvedStoredModelId(
        _ storedModelId: String?,
        availableModels: [PluginModelInfo],
        storageKey: String,
        host: HostServices
    ) -> String? {
        let trimmedModelId = storedModelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModelId = trimmedModelId.flatMap { modelId in
            availableModels.contains(where: { $0.id == modelId }) ? modelId : nil
        } ?? availableModels.first?.id

        if selectedModelId != storedModelId {
            host.setUserDefault(selectedModelId, forKey: storageKey)
        }

        return selectedModelId
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "openrouter" }
    var providerDisplayName: String { "OpenRouter" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    fileprivate static let fallbackTranscriptionModels: [OpenRouterFetchedModel] = [
        OpenRouterFetchedModel(id: "openai/whisper-1", name: "OpenAI: Whisper 1", promptPrice: "0", completionPrice: "0"),
        OpenRouterFetchedModel(id: "openai/gpt-4o-mini-transcribe", name: "OpenAI: GPT-4o Mini Transcribe", promptPrice: "0", completionPrice: "0"),
        OpenRouterFetchedModel(id: "openai/gpt-4o-transcribe", name: "OpenAI: GPT-4o Transcribe", promptPrice: "0", completionPrice: "0"),
        OpenRouterFetchedModel(id: "openai/whisper-large-v3", name: "OpenAI: Whisper Large V3", promptPrice: "0", completionPrice: "0"),
    ]

    var transcriptionModels: [PluginModelInfo] {
        let models = _fetchedTranscriptionModels.isEmpty
            ? Self.fallbackTranscriptionModels
            : _fetchedTranscriptionModels
        return models.map {
            PluginModelInfo(id: $0.id, displayName: $0.name)
        }
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: Self.StorageKeys.selectedModel)
    }

    var supportsTranslation: Bool { false }
    var dictionaryTermsSupport: DictionaryTermsSupport { .unsupported }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelId.isEmpty else {
            throw PluginTranscriptionError.noModelSelected
        }
        guard !translate else {
            throw PluginTranscriptionError.apiError("OpenRouter speech-to-text does not support translation.")
        }

        let request = try Self.makeTranscriptionRequest(
            audio: audio,
            apiKey: apiKey,
            modelId: modelId,
            language: language,
            timeout: Self.transcriptionRequestTimeout
        )
        let (data, response) = try await PluginHTTPClient.data(for: request)
        try Self.validateTranscriptionResponse(data: data, response: response)
        return try Self.parseTranscriptionResponse(data)
    }

    static func makeTranscriptionRequest(
        audio: AudioData,
        apiKey: String,
        modelId: String,
        language: String?,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions") else {
            throw PluginTranscriptionError.apiError("Invalid OpenRouter transcription URL.")
        }

        var body: [String: Any] = [
            "model": modelId,
            "input_audio": [
                "data": audio.wavData.base64EncodedString(),
                "format": "wav",
            ],
        ]
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedLanguage, !trimmedLanguage.isEmpty {
            body["language"] = trimmedLanguage
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func validateTranscriptionResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            return
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 429:
            throw PluginTranscriptionError.rateLimited
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        default:
            let errorMessage = Self.apiErrorMessage(from: data)
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
    }

    static func parseTranscriptionResponse(_ data: Data) throws -> PluginTranscriptionResult {
        struct Response: Decodable {
            let text: String
        }

        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            return PluginTranscriptionResult(text: response.text)
        } catch {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return PluginTranscriptionResult(text: text)
            }
            throw PluginTranscriptionError.apiError("Failed to parse transcription response")
        }
    }

    private static func apiErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = json["message"] as? String {
                return message
            }
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "OpenRouter" }

    var isAvailable: Bool { isConfigured }

    fileprivate static let fallbackLLMModels: [OpenRouterFetchedModel] = [
        OpenRouterFetchedModel(id: "openai/gpt-4o", name: "OpenAI: GPT-4o", promptPrice: "0", completionPrice: "0"),
        OpenRouterFetchedModel(id: "anthropic/claude-sonnet-4", name: "Anthropic: Claude Sonnet 4", promptPrice: "0", completionPrice: "0"),
        OpenRouterFetchedModel(id: "google/gemini-2.5-flash-preview", name: "Google: Gemini 2.5 Flash", promptPrice: "0", completionPrice: "0"),
        OpenRouterFetchedModel(id: "meta-llama/llama-3.3-70b-instruct", name: "Meta: Llama 3.3 70B", promptPrice: "0", completionPrice: "0"),
    ]

    var supportedModels: [PluginModelInfo] {
        let models = _fetchedLLMModels.isEmpty ? Self.fallbackLLMModels : _fetchedLLMModels
        return models.map {
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
        let request = try Self.makeChatRequest(
            apiKey: apiKey,
            model: modelId,
            systemPrompt: systemPrompt,
            userText: userText,
            temperature: providerTemperatureDirective.resolvedTemperature(applying: temperatureDirective),
            timeout: Self.chatRequestTimeout
        )
        let (data, response) = try await PluginHTTPClient.data(for: request)
        try Self.validateChatResponse(data: data, response: response)
        return try Self.parseChatResponse(data)
    }

    func selectLLMModel(_ modelId: String) {
        _selectedLLMModelId = modelId
        host?.setUserDefault(modelId, forKey: Self.StorageKeys.selectedLLMModel)
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
        host?.setUserDefault(mode.rawValue, forKey: Self.StorageKeys.llmTemperatureMode)
    }

    func setLLMTemperatureValue(_ value: Double) {
        let clamped = min(max(value, 0.0), 2.0)
        _llmTemperatureValue = clamped
        host?.setUserDefault(clamped, forKey: Self.StorageKeys.llmTemperatureValue)
    }

    static func makeChatRequest(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        temperature: Double?,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw PluginChatError.apiError("Invalid OpenRouter chat URL.")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
            "max_tokens": 4096,
        ]
        if let temperature {
            body["temperature"] = temperature
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func validateChatResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginChatError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            return
        case 401:
            throw PluginChatError.invalidApiKey
        case 429:
            throw PluginChatError.rateLimited
        default:
            throw PluginChatError.apiError(Self.apiErrorMessage(from: data))
        }
    }

    static func parseChatResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PluginChatError.apiError("Failed to parse response")
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
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
                try host.storeSecret(key: Self.StorageKeys.apiKey, value: key)
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
                try host.storeSecret(key: Self.StorageKeys.apiKey, value: "")
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

    func setFetchedLLMModels(_ models: [OpenRouterFetchedModel]) {
        _fetchedLLMModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: Self.StorageKeys.fetchedModels)
        }
        host?.notifyCapabilitiesChanged()
    }

    func setFetchedTranscriptionModels(_ models: [OpenRouterFetchedModel]) {
        _fetchedTranscriptionModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: Self.StorageKeys.fetchedTranscriptionModels)
        }
        host?.notifyCapabilitiesChanged()
    }

    func fetchLLMModels() async -> [OpenRouterFetchedModel] {
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

    func fetchTranscriptionModels() async -> [OpenRouterFetchedModel] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=transcription") else { return [] }

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
    @State private var selectedLLMModel = ""
    @State private var selectedTranscriptionModel = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var fetchedLLMModels: [OpenRouterFetchedModel] = []
    @State private var fetchedTranscriptionModels: [OpenRouterFetchedModel] = []
    @State private var llmSearchText = ""
    @State private var transcriptionSearchText = ""
    @State private var remainingCredits: Double?
    private let bundle = Bundle(for: OpenRouterPlugin.self)

    private var llmModels: [OpenRouterFetchedModel] {
        fetchedLLMModels.isEmpty ? OpenRouterPlugin.fallbackLLMModels : fetchedLLMModels
    }

    private var transcriptionModels: [OpenRouterFetchedModel] {
        fetchedTranscriptionModels.isEmpty
            ? OpenRouterPlugin.fallbackTranscriptionModels
            : fetchedTranscriptionModels
    }

    private var filteredLLMModels: [OpenRouterFetchedModel] {
        filtered(models: llmModels, searchText: llmSearchText)
    }

    private var filteredTranscriptionModels: [OpenRouterFetchedModel] {
        filtered(models: transcriptionModels, searchText: transcriptionSearchText)
    }

    private func filtered(models: [OpenRouterFetchedModel], searchText: String) -> [OpenRouterFetchedModel] {
        if searchText.isEmpty { return models }
        let query = searchText.lowercased()
        return models.filter {
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

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Transcription Model", bundle: bundle)
                            .font(.headline)

                        Spacer()

                        Button {
                            refreshTranscriptionModels()
                        } label: {
                            Label(String(localized: "Refresh", bundle: bundle), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    TextField(String(localized: "Search models...", bundle: bundle), text: $transcriptionSearchText)
                        .textFieldStyle(.roundedBorder)

                    let models = filteredTranscriptionModels
                    Picker("Transcription Model", selection: $selectedTranscriptionModel) {
                        ForEach(models, id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedTranscriptionModel) {
                        guard !selectedTranscriptionModel.isEmpty else { return }
                        plugin.selectModel(selectedTranscriptionModel)
                    }

                    if fetchedTranscriptionModels.isEmpty {
                        Text("Using default models. Press Refresh to fetch all available models.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

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

                    TextField(String(localized: "Search models...", bundle: bundle), text: $llmSearchText)
                        .textFieldStyle(.roundedBorder)

                    let models = filteredLLMModels
                    Picker("LLM Model", selection: $selectedLLMModel) {
                        ForEach(models, id: \.id) { model in
                            Text("\(model.name) - \(model.formattedPricing)").tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedLLMModel) {
                        guard !selectedLLMModel.isEmpty else { return }
                        plugin.selectLLMModel(selectedLLMModel)
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
            fetchedLLMModels = plugin._fetchedLLMModels
            fetchedTranscriptionModels = plugin._fetchedTranscriptionModels
            selectedLLMModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
            selectedTranscriptionModel = plugin.selectedModelId ?? plugin.transcriptionModels.first?.id ?? ""
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
                async let llmModelsTask = plugin.fetchLLMModels()
                async let transcriptionModelsTask = plugin.fetchTranscriptionModels()
                async let creditsTask = plugin.fetchCredits()
                let (llmModels, transcriptionModels, credits) = await (
                    llmModelsTask,
                    transcriptionModelsTask,
                    creditsTask
                )
                await MainActor.run {
                    isValidating = false
                    validationResult = true
                    remainingCredits = credits
                    applyLLMModels(llmModels)
                    applyTranscriptionModels(transcriptionModels)
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
                applyLLMModels(models)
            }
        }
    }

    private func refreshTranscriptionModels() {
        Task {
            let models = await plugin.fetchTranscriptionModels()
            await MainActor.run {
                applyTranscriptionModels(models)
            }
        }
    }

    private func applyLLMModels(_ models: [OpenRouterFetchedModel]) {
        guard !models.isEmpty else { return }
        fetchedLLMModels = models
        plugin.setFetchedLLMModels(models)
        if !models.contains(where: { $0.id == selectedLLMModel }),
           let first = models.first {
            selectedLLMModel = first.id
            plugin.selectLLMModel(first.id)
        }
    }

    private func applyTranscriptionModels(_ models: [OpenRouterFetchedModel]) {
        guard !models.isEmpty else { return }
        fetchedTranscriptionModels = models
        plugin.setFetchedTranscriptionModels(models)
        if !models.contains(where: { $0.id == selectedTranscriptionModel }),
           let first = models.first {
            selectedTranscriptionModel = first.id
            plugin.selectModel(first.id)
        }
    }
}
