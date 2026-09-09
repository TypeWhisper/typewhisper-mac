import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

/// Vercel AI Gateway (https://vercel.com/docs/ai-gateway) fronts hundreds of
/// models behind one API key. Chat completions use the OpenAI-compatible
/// `/v1/chat/completions` surface. Speech-to-text does *not* go through the
/// OpenAI multipart endpoint (the gateway returns 404 for
/// `/v1/audio/transcriptions`); it uses the gateway's dedicated
/// `/v4/ai/transcription-model` endpoint which takes base64 audio in JSON.
@objc(VercelAIGatewayPlugin)
final class VercelAIGatewayPlugin: NSObject,
    TranscriptionEnginePlugin,
    DictionaryTermsCapabilityProviding,
    LLMProviderPlugin,
    LLMTemperatureControllableProvider,
    LLMModelSelectable,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.vercel-ai-gateway"
    static let pluginName = "Vercel AI Gateway"

    static let baseURL = "https://ai-gateway.vercel.sh"
    static let modelsURL = "\(baseURL)/v1/models"
    static let creditsURL = "\(baseURL)/v1/credits"
    static let transcriptionURL = "\(baseURL)/v4/ai/transcription-model"
    static let apiKeysURL = "https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai-gateway%2Fapi-keys"

    /// `transcribe`/`process` are nonisolated async and run off the caller's
    /// actor, while the settings view mutates configuration on the main actor.
    /// Every read and write of this state goes through `lock` so a request
    /// always sees a coherent key/model/temperature snapshot.
    private struct State {
        var host: HostServices?
        var apiKey: String?
        var selectedModelId: String?
        var selectedLLMModelId: String?
        var llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
        var llmTemperatureValue: Double = 0.3
        var fetchedLLMModels: [VercelAIGatewayFetchedModel] = []
        var fetchedTranscriptionModels: [VercelAIGatewayFetchedModel] = []
        /// Bumped on every key save or removal. An in-flight validation
        /// compares its captured value against this before publishing, so
        /// key A's late completion cannot overwrite key B's status.
        var apiKeyGeneration = 0
    }

    private let lock = NSLock()
    private var state = State()

    private func readState<T>(_ body: (State) -> T) -> T {
        lock.withLock { body(state) }
    }

    /// Host callbacks (Keychain, defaults, capability notifications) run
    /// outside the lock; the closure only updates in-memory state.
    private func updateState(_ body: (inout State) -> Void) {
        lock.withLock { body(&state) }
    }

    fileprivate var host: HostServices? { readState { $0.host } }
    fileprivate var _apiKey: String? { readState { $0.apiKey } }
    fileprivate var _selectedModelId: String? { readState { $0.selectedModelId } }
    fileprivate var _selectedLLMModelId: String? { readState { $0.selectedLLMModelId } }
    fileprivate var _llmTemperatureModeRaw: String { readState { $0.llmTemperatureModeRaw } }
    fileprivate var _llmTemperatureValue: Double { readState { $0.llmTemperatureValue } }
    fileprivate var _fetchedLLMModels: [VercelAIGatewayFetchedModel] { readState { $0.fetchedLLMModels } }
    fileprivate var _fetchedTranscriptionModels: [VercelAIGatewayFetchedModel] { readState { $0.fetchedTranscriptionModels } }

    private static let chatRequestTimeout: TimeInterval = 30
    private static let transcriptionRequestTimeout: TimeInterval = 120

    private let chatHelper = PluginOpenAIChatHelper(baseURL: VercelAIGatewayPlugin.baseURL)

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
        var loaded = State()
        loaded.host = host
        loaded.apiKey = host.loadSecret(key: Self.StorageKeys.apiKey)
        if let data = host.userDefault(forKey: Self.StorageKeys.fetchedModels) as? Data,
           let models = try? JSONDecoder().decode([VercelAIGatewayFetchedModel].self, from: data) {
            loaded.fetchedLLMModels = models
        }
        if let data = host.userDefault(forKey: Self.StorageKeys.fetchedTranscriptionModels) as? Data,
           let models = try? JSONDecoder().decode([VercelAIGatewayFetchedModel].self, from: data) {
            loaded.fetchedTranscriptionModels = models
        }
        loaded.llmTemperatureModeRaw = host.userDefault(forKey: Self.StorageKeys.llmTemperatureMode) as? String
            ?? PluginLLMTemperatureMode.providerDefault.rawValue
        loaded.llmTemperatureValue = host.userDefault(forKey: Self.StorageKeys.llmTemperatureValue) as? Double
            ?? 0.3
        updateState { $0 = loaded }

        // Selections validate against the model lists, so resolve them once
        // the lists above are published.
        let selectedModelId = Self.resolvedStoredModelId(
            host.userDefault(forKey: Self.StorageKeys.selectedModel) as? String,
            availableModels: transcriptionModels,
            storageKey: Self.StorageKeys.selectedModel,
            host: host
        )
        let selectedLLMModelId = Self.resolvedStoredModelId(
            host.userDefault(forKey: Self.StorageKeys.selectedLLMModel) as? String,
            availableModels: supportedModels,
            storageKey: Self.StorageKeys.selectedLLMModel,
            host: host
        )
        updateState {
            $0.selectedModelId = selectedModelId
            $0.selectedLLMModelId = selectedLLMModelId
        }
    }

    /// A persisted selection can point at a model the gateway has since retired.
    /// Fall back to the first available model and persist that so the picker
    /// and the transcription path agree on what is selected.
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
        updateState { $0.host = nil }
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "vercel-ai-gateway" }
    var providerDisplayName: String { "Vercel AI Gateway" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    static let fallbackTranscriptionModels: [VercelAIGatewayFetchedModel] = [
        VercelAIGatewayFetchedModel(id: "openai/whisper-1", name: "Whisper"),
        VercelAIGatewayFetchedModel(id: "openai/gpt-4o-mini-transcribe", name: "GPT-4o mini Transcribe"),
        VercelAIGatewayFetchedModel(id: "openai/gpt-4o-transcribe", name: "GPT-4o Transcribe"),
        VercelAIGatewayFetchedModel(id: "google/gemini-3.5-transcribe", name: "Gemini 3.5 Transcribe"),
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
        updateState { $0.selectedModelId = modelId }
        host?.setUserDefault(modelId, forKey: Self.StorageKeys.selectedModel)
    }

    var supportsTranslation: Bool { false }
    var dictionaryTermsSupport: DictionaryTermsSupport { .unsupported }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        let (storedApiKey, storedModelId) = readState { ($0.apiKey, $0.selectedModelId) }
        guard let apiKey = storedApiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = storedModelId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelId.isEmpty else {
            throw PluginTranscriptionError.noModelSelected
        }
        guard !translate else {
            throw PluginTranscriptionError.apiError("Vercel AI Gateway speech-to-text does not support translation.")
        }

        let uploadAudio = PluginAudioUploadEncoder.normalizedAudioForUpload(audio)
        let preferredUpload = (try? PluginAudioUploadEncoder.compressedM4AUpload(from: uploadAudio))
            ?? PluginAudioUploadEncoder.wavUpload(from: uploadAudio)
        var request = try Self.makeTranscriptionRequest(
            uploadFile: preferredUpload,
            apiKey: apiKey,
            modelId: modelId,
            language: language,
            timeout: Self.transcriptionRequestTimeout
        )
        var (data, response) = try await PluginHTTPClient.data(for: request, resourceTimeout: Self.transcriptionRequestTimeout)
        if let httpResponse = response as? HTTPURLResponse,
           preferredUpload.format != "wav",
           PluginAudioUploadEncoder.shouldRetryWithWavUpload(
            statusCode: httpResponse.statusCode,
            responseData: data
           ) {
            request = try Self.makeTranscriptionRequest(
                uploadFile: PluginAudioUploadEncoder.wavUpload(from: uploadAudio),
                apiKey: apiKey,
                modelId: modelId,
                language: language,
                timeout: Self.transcriptionRequestTimeout
            )
            (data, response) = try await PluginHTTPClient.data(for: request, resourceTimeout: Self.transcriptionRequestTimeout)
        }
        try Self.validateTranscriptionResponse(data: data, response: response)
        return try Self.parseTranscriptionResponse(data)
    }

    /// Builds the request for the gateway's AI SDK transcription protocol
    /// (https://vercel.com/docs/ai-gateway/modalities/speech-to-text#transcribe-with-the-rest-api).
    /// The model travels in the `ai-model-id` header, not the body.
    static func makeTranscriptionRequest(
        uploadFile: PluginAudioUploadFile,
        apiKey: String,
        modelId: String,
        language: String?,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: transcriptionURL) else {
            throw PluginTranscriptionError.apiError("Invalid Vercel AI Gateway transcription URL.")
        }

        var body: [String: Any] = [
            "audio": uploadFile.data.base64EncodedString(),
            "mediaType": uploadFile.contentType,
        ]
        if let providerOptions = transcriptionProviderOptions(modelId: modelId, language: language) {
            body["providerOptions"] = providerOptions
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("0.0.1", forHTTPHeaderField: "ai-gateway-protocol-version")
        request.setValue("4", forHTTPHeaderField: "ai-transcription-model-specification-version")
        request.setValue(modelId, forHTTPHeaderField: "ai-model-id")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The gateway forwards `providerOptions` keyed by the upstream provider.
    /// Only OpenAI's transcription options document a `language` hint, so the
    /// hint is limited to `openai/*` models to avoid 400s from other creators.
    private static func transcriptionProviderOptions(modelId: String, language: String?) -> [String: Any]? {
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedLanguage.isEmpty else { return nil }
        let creator = modelId.split(separator: "/", maxSplits: 1).first.map(String.init)?.lowercased()
        guard creator == "openai" else { return nil }
        return ["openai": ["language": trimmedLanguage]]
    }

    static func validateTranscriptionResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            if let htmlPageSummary = PluginHTTPErrorBodyFormatter.htmlPageSummary(
                from: data,
                response: httpResponse
            ) {
                throw PluginTranscriptionError.apiError(
                    "Failed to parse transcription response: \(htmlPageSummary)"
                )
            }
            return
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 429:
            throw PluginTranscriptionError.rateLimited
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        default:
            let errorMessage = Self.apiErrorMessage(from: data, response: httpResponse)
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
    }

    static func parseTranscriptionResponse(_ data: Data) throws -> PluginTranscriptionResult {
        // Segment field names follow the AI SDK transcription result shape.
        struct Segment: Decodable {
            let text: String
            let startSecond: Double
            let endSecond: Double
        }

        struct Response: Decodable {
            let text: String
            let language: String?
            let segments: [Segment]?
        }

        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            let segments = (response.segments ?? []).map {
                PluginTranscriptionSegment(text: $0.text, start: $0.startSecond, end: $0.endSecond)
            }
            return PluginTranscriptionResult(
                text: response.text,
                detectedLanguage: response.language,
                segments: segments
            )
        } catch {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return PluginTranscriptionResult(text: text)
            }
            throw PluginTranscriptionError.apiError("Failed to parse transcription response")
        }
    }

    /// The gateway returns OpenAI-shaped `{"error":{"message":...}}` on most
    /// surfaces, but the AI SDK protocol endpoint can also return a bare
    /// `{"error":"..."}` string or a top-level `message`.
    private static func apiErrorMessage(from data: Data, response: HTTPURLResponse) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return PluginHTTPErrorBodyFormatter.summary(from: message)
            }
            if let message = json["error"] as? String {
                return PluginHTTPErrorBodyFormatter.summary(from: message)
            }
            if let message = json["message"] as? String {
                return PluginHTTPErrorBodyFormatter.summary(from: message)
            }
        }
        return PluginHTTPErrorBodyFormatter.summary(from: data, response: response)
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "Vercel AI Gateway" }

    var isAvailable: Bool { isConfigured }

    static let fallbackLLMModels: [VercelAIGatewayFetchedModel] = [
        VercelAIGatewayFetchedModel(id: "openai/gpt-4o-mini", name: "GPT-4o mini"),
        VercelAIGatewayFetchedModel(id: "openai/gpt-5.4-mini", name: "GPT 5.4 Mini"),
        VercelAIGatewayFetchedModel(id: "anthropic/claude-haiku-4.5", name: "Claude Haiku 4.5"),
        VercelAIGatewayFetchedModel(id: "anthropic/claude-sonnet-5", name: "Claude Sonnet 5"),
        VercelAIGatewayFetchedModel(id: "google/gemini-3.5-flash", name: "Gemini 3.5 Flash"),
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
        let snapshot = readState { state in
            (
                apiKey: state.apiKey,
                selectedModelId: state.selectedLLMModelId,
                fallbackModels: state.fetchedLLMModels.isEmpty ? Self.fallbackLLMModels : state.fetchedLLMModels,
                temperature: PluginLLMTemperatureDirective(
                    mode: PluginLLMTemperatureMode(rawValue: state.llmTemperatureModeRaw) ?? .providerDefault,
                    value: state.llmTemperatureValue
                )
            )
        }
        guard let apiKey = snapshot.apiKey, !apiKey.isEmpty else {
            throw PluginChatError.notConfigured
        }
        let modelId = model ?? snapshot.selectedModelId ?? snapshot.fallbackModels.first!.id
        return try await chatHelper.process(
            apiKey: apiKey,
            model: modelId,
            systemPrompt: systemPrompt,
            userText: userText,
            temperature: snapshot.temperature.resolvedTemperature(applying: temperatureDirective),
            requestTimeout: Self.chatRequestTimeout
        )
    }

    func selectLLMModel(_ modelId: String) {
        updateState { $0.selectedLLMModelId = modelId }
        host?.setUserDefault(modelId, forKey: Self.StorageKeys.selectedLLMModel)
    }

    var selectedLLMModelId: String? { _selectedLLMModelId }
    @objc var preferredModelId: String? { _selectedLLMModelId }
    var llmTemperatureMode: PluginLLMTemperatureMode {
        PluginLLMTemperatureMode(rawValue: _llmTemperatureModeRaw) ?? .providerDefault
    }
    var llmTemperatureValue: Double { _llmTemperatureValue }

    func setLLMTemperatureMode(_ mode: PluginLLMTemperatureMode) {
        updateState { $0.llmTemperatureModeRaw = mode.rawValue }
        host?.setUserDefault(mode.rawValue, forKey: Self.StorageKeys.llmTemperatureMode)
    }

    func setLLMTemperatureValue(_ value: Double) {
        let clamped = min(max(value, 0.0), 2.0)
        updateState { $0.llmTemperatureValue = clamped }
        host?.setUserDefault(clamped, forKey: Self.StorageKeys.llmTemperatureValue)
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(VercelAIGatewaySettingsView(plugin: self))
    }

    // MARK: - API Key Management

    func setApiKey(_ key: String) {
        _ = beginApiKeyUpdate(key)
        if let host {
            do {
                try host.storeSecret(key: Self.StorageKeys.apiKey, value: key)
            } catch {
                print("[VercelAIGatewayPlugin] Failed to store API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func removeApiKey() {
        _ = beginApiKeyUpdate(nil)
        if let host {
            do {
                try host.storeSecret(key: Self.StorageKeys.apiKey, value: "")
            } catch {
                print("[VercelAIGatewayPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    /// Stores the key in memory and returns the generation token that any
    /// asynchronous follow-up work must present via `isCurrentApiKeyUpdate`.
    private func beginApiKeyUpdate(_ key: String?) -> Int {
        lock.withLock {
            state.apiKey = key
            state.apiKeyGeneration += 1
            return state.apiKeyGeneration
        }
    }

    func isCurrentApiKeyUpdate(_ generation: Int) -> Bool {
        readState { $0.apiKeyGeneration == generation }
    }

    /// Result of `saveApiKey`. `catalog` and `balance` are only populated
    /// when the key validated.
    struct ApiKeySaveResult: Sendable {
        let isValid: Bool
        let catalog: VercelAIGatewayModelCatalog
        let balance: Double?
    }

    /// Persists the key, validates it, and loads the catalogue and balance.
    /// Returns `nil` when a newer save or a removal superseded this call
    /// while it was in flight; callers must then discard the outcome.
    func saveApiKey(_ key: String) async -> ApiKeySaveResult? {
        await saveApiKey(key, validate: { [self] in await validateApiKey($0) })
    }

    /// `validate` is injectable so tests can control completion order.
    func saveApiKey(
        _ key: String,
        validate: @Sendable (String) async -> Bool
    ) async -> ApiKeySaveResult? {
        let generation = beginApiKeyUpdate(key)
        if let host {
            do {
                try host.storeSecret(key: Self.StorageKeys.apiKey, value: key)
            } catch {
                print("[VercelAIGatewayPlugin] Failed to store API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }

        let isValid = await validate(key)
        guard isCurrentApiKeyUpdate(generation) else { return nil }
        guard isValid else {
            return ApiKeySaveResult(isValid: false, catalog: .empty, balance: nil)
        }

        async let catalogTask = fetchModelCatalog()
        async let creditsTask = fetchCredits()
        let (catalog, balance) = await (catalogTask, creditsTask)
        guard isCurrentApiKeyUpdate(generation) else { return nil }

        // Publish the catalogue from here so a superseded save can never
        // reach `setFetched*` through the view.
        if !catalog.llmModels.isEmpty {
            setFetchedLLMModels(catalog.llmModels)
        }
        if !catalog.transcriptionModels.isEmpty {
            setFetchedTranscriptionModels(catalog.transcriptionModels)
        }
        return ApiKeySaveResult(isValid: true, catalog: catalog, balance: balance)
    }

    /// `/v1/models` is public, so it cannot prove a key works. `/v1/credits`
    /// requires authentication and is the cheapest authenticated call.
    func validateApiKey(_ key: String) async -> Bool {
        guard !key.isEmpty, let url = URL(string: Self.creditsURL) else { return false }

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

    func setFetchedLLMModels(_ models: [VercelAIGatewayFetchedModel]) {
        updateState { $0.fetchedLLMModels = models }
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: Self.StorageKeys.fetchedModels)
        }
        host?.notifyCapabilitiesChanged()
    }

    func setFetchedTranscriptionModels(_ models: [VercelAIGatewayFetchedModel]) {
        updateState { $0.fetchedTranscriptionModels = models }
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: Self.StorageKeys.fetchedTranscriptionModels)
        }
        host?.notifyCapabilitiesChanged()
    }

    /// One catalogue call covers every modality; the `type` field splits
    /// language models from transcription models.
    func fetchModelCatalog() async -> VercelAIGatewayModelCatalog {
        guard let url = URL(string: Self.modelsURL) else { return .empty }

        var request = URLRequest(url: url)
        if let apiKey = _apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return .empty }
            return try Self.parseModelCatalog(data)
        } catch {
            return .empty
        }
    }

    static func parseModelCatalog(_ data: Data) throws -> VercelAIGatewayModelCatalog {
        let decoded = try JSONDecoder().decode(VercelAIGatewayModelsResponse.self, from: data)
        let llm = decoded.data
            .filter { $0.type == "language" }
            .map { model in
                VercelAIGatewayFetchedModel(
                    id: model.id,
                    name: model.name ?? model.id,
                    inputPrice: model.pricing?.input,
                    outputPrice: model.pricing?.output
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let transcription = decoded.data
            .filter { $0.type == "transcription" && Self.supportsRecordedAudio($0) }
            .map { model in
                VercelAIGatewayFetchedModel(id: model.id, name: model.name ?? model.id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return VercelAIGatewayModelCatalog(llmModels: llm, transcriptionModels: transcription)
    }

    /// Realtime/live models only accept audio over WebSocket streams, which the
    /// REST transcription endpoint cannot serve.
    private static func supportsRecordedAudio(_ model: VercelAIGatewayAPIModel) -> Bool {
        if (model.tags ?? []).contains("websocket-realtime") { return false }
        return !model.id.lowercased().hasSuffix("-live")
    }

    // MARK: - Credits

    fileprivate func fetchCredits() async -> Double? {
        guard let apiKey = _apiKey, !apiKey.isEmpty,
              let url = URL(string: Self.creditsURL) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            return Self.parseCreditBalance(data)
        } catch {
            return nil
        }
    }

    /// `/v1/credits` returns `{"balance":"95.50","total_used":"4.50"}` with
    /// USD amounts as strings.
    static func parseCreditBalance(_ data: Data) -> Double? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let balance = json["balance"] as? String {
            return Double(balance)
        }
        if let balance = json["balance"] as? Double {
            return balance
        }
        return nil
    }
}

// MARK: - API Response Models

private struct VercelAIGatewayModelsResponse: Decodable {
    let data: [VercelAIGatewayAPIModel]
}

private struct VercelAIGatewayAPIModel: Decodable {
    let id: String
    let name: String?
    let type: String?
    let tags: [String]?
    let pricing: VercelAIGatewayPricing?
}

private struct VercelAIGatewayPricing: Decodable {
    let input: String?
    let output: String?
}

struct VercelAIGatewayModelCatalog: Sendable {
    let llmModels: [VercelAIGatewayFetchedModel]
    let transcriptionModels: [VercelAIGatewayFetchedModel]

    static let empty = VercelAIGatewayModelCatalog(llmModels: [], transcriptionModels: [])
}

// MARK: - Fetched Model (persisted)

struct VercelAIGatewayFetchedModel: Codable, Sendable, Equatable {
    let id: String
    let name: String
    /// USD per token as returned by the gateway catalogue. `nil` means the
    /// price is unknown (static fallback entry, or the catalogue omitted it),
    /// which must never be rendered as free.
    let inputPrice: String?
    let outputPrice: String?

    init(id: String, name: String, inputPrice: String? = nil, outputPrice: String? = nil) {
        self.id = id
        self.name = name
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
    }

    var formattedPricing: String {
        let bundle = Bundle(for: VercelAIGatewayPlugin.self)
        guard let inputPrice, let outputPrice,
              let inputPerToken = Double(inputPrice),
              let outputPerToken = Double(outputPrice) else {
            return String(localized: "Pricing unavailable", bundle: bundle)
        }
        let inputPer1M = inputPerToken * 1_000_000
        let outputPer1M = outputPerToken * 1_000_000
        if inputPer1M == 0 && outputPer1M == 0 {
            return String(localized: "Free", bundle: bundle)
        }
        return String(format: "$%.2f/$%.2f per 1M", inputPer1M, outputPer1M)
    }
}

// MARK: - Settings View

private struct VercelAIGatewaySettingsView: View {
    let plugin: VercelAIGatewayPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedLLMModel = ""
    @State private var selectedTranscriptionModel = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var fetchedLLMModels: [VercelAIGatewayFetchedModel] = []
    @State private var fetchedTranscriptionModels: [VercelAIGatewayFetchedModel] = []
    @State private var llmSearchText = ""
    @State private var transcriptionSearchText = ""
    @State private var creditBalance: Double?
    private let bundle = Bundle(for: VercelAIGatewayPlugin.self)

    private var llmModels: [VercelAIGatewayFetchedModel] {
        fetchedLLMModels.isEmpty ? VercelAIGatewayPlugin.fallbackLLMModels : fetchedLLMModels
    }

    private var transcriptionModels: [VercelAIGatewayFetchedModel] {
        fetchedTranscriptionModels.isEmpty
            ? VercelAIGatewayPlugin.fallbackTranscriptionModels
            : fetchedTranscriptionModels
    }

    private var filteredLLMModels: [VercelAIGatewayFetchedModel] {
        filtered(models: llmModels, searchText: llmSearchText)
    }

    private var filteredTranscriptionModels: [VercelAIGatewayFetchedModel] {
        filtered(models: transcriptionModels, searchText: transcriptionSearchText)
    }

    /// A rejected key stays stored (matching the other cloud plugins, so an
    /// offline save is not lost), so Save must remain reachable whenever the
    /// field no longer matches the stored key.
    private var hasUnsavedApiKeyInput: Bool {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return !plugin.isAvailable }
        return trimmed != (plugin._apiKey ?? "")
    }

    private func filtered(models: [VercelAIGatewayFetchedModel], searchText: String) -> [VercelAIGatewayFetchedModel] {
        if searchText.isEmpty { return models }
        let query = searchText.lowercased()
        return models.filter {
            $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 8) {
                    if showApiKey {
                        TextField(String(localized: "API Key", bundle: bundle), text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField(String(localized: "API Key", bundle: bundle), text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    if hasUnsavedApiKeyInput {
                        Button(String(localized: "Save", bundle: bundle)) {
                            saveApiKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if plugin.isAvailable {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            isValidating = false
                            validationResult = nil
                            creditBalance = nil
                            plugin.removeApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
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

                if let balance = creditBalance {
                    HStack(spacing: 4) {
                        Image(systemName: "creditcard")
                            .foregroundStyle(.secondary)
                        Text("Balance: $\(String(format: "%.2f", balance))", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Link(String(localized: "Get API Key", bundle: bundle),
                     destination: URL(string: VercelAIGatewayPlugin.apiKeysURL)!)
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
                            refreshModels()
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

                    Text("Speech to text on Vercel AI Gateway is in beta. Transcription models may not be enabled for your team yet.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

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
                    if let balance = await plugin.fetchCredits() {
                        await MainActor.run {
                            creditBalance = balance
                        }
                    }
                }
            }
        }
    }

    private func saveApiKey() {
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        isValidating = true
        validationResult = nil
        Task {
            // `nil` means a later save or removal superseded this one; that
            // call owns the UI state now.
            guard let result = await plugin.saveApiKey(trimmedKey) else { return }
            await MainActor.run {
                isValidating = false
                validationResult = result.isValid
                creditBalance = result.balance
                syncSelections(with: result.catalog)
            }
        }
    }

    private func refreshModels() {
        Task {
            let catalog = await plugin.fetchModelCatalog()
            await MainActor.run {
                applyCatalog(catalog)
            }
        }
    }

    private func applyCatalog(_ catalog: VercelAIGatewayModelCatalog) {
        if !catalog.llmModels.isEmpty {
            plugin.setFetchedLLMModels(catalog.llmModels)
        }
        if !catalog.transcriptionModels.isEmpty {
            plugin.setFetchedTranscriptionModels(catalog.transcriptionModels)
        }
        syncSelections(with: catalog)
    }

    /// Mirrors a freshly published catalogue into the pickers and moves a
    /// selection that the catalogue no longer contains to the first entry.
    private func syncSelections(with catalog: VercelAIGatewayModelCatalog) {
        if !catalog.llmModels.isEmpty {
            fetchedLLMModels = catalog.llmModels
            if !catalog.llmModels.contains(where: { $0.id == selectedLLMModel }),
               let first = catalog.llmModels.first {
                selectedLLMModel = first.id
                plugin.selectLLMModel(first.id)
            }
        }
        if !catalog.transcriptionModels.isEmpty {
            fetchedTranscriptionModels = catalog.transcriptionModels
            if !catalog.transcriptionModels.contains(where: { $0.id == selectedTranscriptionModel }),
               let first = catalog.transcriptionModels.first {
                selectedTranscriptionModel = first.id
                plugin.selectModel(first.id)
            }
        }
    }
}
