import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(GeminiPlugin)
final class GeminiPlugin: NSObject,
    LLMProviderPlugin,
    LLMTemperatureControllableProvider,
    LLMModelSelectable,
    TranscriptionEnginePlugin,
    LiveLanguageHintDictionaryTermHintTranscriptionCapablePlugin,
    DictionaryTermsCapabilityProviding,
    DictionaryTermsBudgetProviding,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.gemini"
    static let pluginName = "Gemini"
    private static let cachedLLMModelsKey = "fetchedLLMModels.v2"
    private static let cachedTranscriptionModelsKey = "fetchedTranscriptionModels.v1"
    private static let modelCatalogRefreshDateKey = "modelCatalogRefreshDate.v1"
    private static let legacyCachedLLMModelsKey = "fetchedLLMModels"
    private static let selectedLLMModelKey = "selectedLLMModel"
    private static let selectedTranscriptionModelKey = "selectedModel"
    private static let modelsEndpoint = "https://generativelanguage.googleapis.com/v1beta/models"
    private static let transcriptionRequestTimeout: TimeInterval = 60
    private static let dedicatedTranscriptionRequestTimeout: TimeInterval = 900
    private static let modelCatalogRefreshInterval: TimeInterval = 24 * 60 * 60
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
        "transcribe",
        "translate",
    ]

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _selectedTranscriptionModelId: String?
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
    fileprivate var _llmTemperatureValue: Double = 0.3
    fileprivate var _fetchedLLMModels: [GeminiFetchedModel] = []
    fileprivate var _fetchedTranscriptionModels: [GeminiFetchedTranscriptionModel] = []
    private var modelCatalogRefreshTask: Task<Void, Never>?

    private let chatHelper = PluginOpenAIChatHelper(
        baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        chatEndpoint: "/chat/completions"
    )

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        modelCatalogRefreshTask?.cancel()
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        if let data = host.userDefault(forKey: Self.cachedLLMModelsKey) as? Data,
           let models = try? JSONDecoder().decode([GeminiFetchedModel].self, from: data) {
            _fetchedLLMModels = models
        }
        if let data = host.userDefault(forKey: Self.cachedTranscriptionModelsKey) as? Data,
           let models = try? JSONDecoder().decode([GeminiFetchedTranscriptionModel].self, from: data) {
            let compatibleModels = Self.compatibleTranscriptionModels(from: models)
            _fetchedTranscriptionModels = compatibleModels
            if compatibleModels.count != models.count,
               let compatibleData = try? JSONEncoder().encode(compatibleModels) {
                host.setUserDefault(compatibleData, forKey: Self.cachedTranscriptionModelsKey)
            }
        }
        host.setUserDefault(nil, forKey: Self.legacyCachedLLMModelsKey)
        _llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
            ?? PluginLLMTemperatureMode.providerDefault.rawValue
        _llmTemperatureValue = host.userDefault(forKey: "llmTemperatureValue") as? Double
            ?? 0.3
        _selectedTranscriptionModelId = Self.resolvedTranscriptionModelId(
            host.userDefault(forKey: Self.selectedTranscriptionModelKey) as? String,
            availableModels: resolvedTranscriptionModels,
            host: host
        )
        normalizeSelectedModel()
        refreshModelCatalogIfNeeded()
    }

    func deactivate() {
        modelCatalogRefreshTask?.cancel()
        modelCatalogRefreshTask = nil
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

    /// Transient default when the user has not selected a model. Prefers the
    /// curated auto-updating alias over `supportedModels.first`, which for
    /// fetched models is the alphabetically-oldest (and possibly retired)
    /// model, e.g. `gemini-2.0-flash`.
    private static let curatedDefaultModelId = "gemini-flash-latest"

    fileprivate var defaultLLMModelId: String? {
        let models = supportedModels
        return models.first(where: { $0.id == Self.curatedDefaultModelId })?.id ?? models.first?.id
    }

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
        guard let modelId = model ?? _selectedLLMModelId ?? defaultLLMModelId else {
            throw PluginChatError.notConfigured
        }
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
    @objc var preferredModelId: String? { _selectedLLMModelId }
    @objc var defaultModelId: String? { defaultLLMModelId }
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

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "gemini" }
    var providerDisplayName: String { "Gemini" }

    var isConfigured: Bool { isAvailable }

    fileprivate static let fallbackTranscriptionModels: [GeminiFetchedTranscriptionModel] = [
        GeminiFetchedTranscriptionModel(
            id: "gemini-3.5-transcribe",
            displayName: "Gemini 3.5 Transcribe",
            liveModelId: "gemini-3.5-transcribe-live"
        ),
    ]

    private static var defaultTranscriptionModelId: String {
        fallbackTranscriptionModels[0].id
    }

    fileprivate var resolvedTranscriptionModels: [GeminiFetchedTranscriptionModel] {
        let fallbackById = Dictionary(
            uniqueKeysWithValues: Self.fallbackTranscriptionModels.map { ($0.id, $0) }
        )
        let fetchedModels = Self.compatibleTranscriptionModels(from: _fetchedTranscriptionModels).map { model in
            guard model.liveModelId == nil,
                  let fallbackLiveModelId = fallbackById[model.id]?.liveModelId else {
                return model
            }
            return GeminiFetchedTranscriptionModel(
                id: model.id,
                displayName: model.displayName,
                liveModelId: fallbackLiveModelId
            )
        }
        var seenIds = Set<String>()
        return (fetchedModels + Self.fallbackTranscriptionModels)
            .filter { seenIds.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.id == Self.defaultTranscriptionModelId { return true }
                if rhs.id == Self.defaultTranscriptionModelId { return false }
                return lhs.id < rhs.id
            }
    }

    var transcriptionModels: [PluginModelInfo] {
        resolvedTranscriptionModels.map {
            PluginModelInfo(id: $0.id, displayName: $0.displayName ?? $0.id)
        }
    }

    var selectedModelId: String? {
        _selectedTranscriptionModelId ?? Self.defaultTranscriptionModelId
    }

    func selectModel(_ modelId: String) {
        let trimmedModelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportedIds = Set(resolvedTranscriptionModels.map(\.id))
        let resolvedModelId = supportedIds.contains(trimmedModelId)
            ? trimmedModelId
            : Self.defaultTranscriptionModelId
        _selectedTranscriptionModelId = resolvedModelId
        host?.setUserDefault(resolvedModelId, forKey: Self.selectedTranscriptionModelKey)
        host?.notifyCapabilitiesChanged()
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool {
        liveTranscriptionModelId(for: selectedModelId) != nil
    }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }
    var dictionaryTermsBudget: DictionaryTermsBudget { DictionaryTermsBudget(maxTerms: 1_000) }

    var supportedLanguages: [String] {
        [
            "ar", "cs", "da", "de", "el", "en", "es", "fi", "fr", "he",
            "hi", "hu", "id", "it", "ja", "ko", "nl", "no", "pl", "pt",
            "ro", "ru", "sv", "th", "tr", "uk", "vi", "zh",
        ]
    }

    private static let transcriptionLanguageCodeOverrides: [String: String] = [
        "ar": "ar-EG",
        "cs": "cs-CZ",
        "da": "da-DK",
        "de": "de-DE",
        "el": "el-GR",
        "en": "en-US",
        "es": "es-419",
        "fi": "fi-FI",
        "fr": "fr-FR",
        "he": "he-IL",
        "hi": "hi-IN",
        "hu": "hu-HU",
        "id": "id-ID",
        "it": "it-IT",
        "ja": "ja-JP",
        "ko": "ko-KR",
        "nl": "nl-NL",
        "no": "nb-NO",
        "pl": "pl-PL",
        "pt": "pt-BR",
        "ro": "ro-RO",
        "ru": "ru-RU",
        "sv": "sv-SE",
        "th": "th-TH",
        "tr": "tr-TR",
        "uk": "uk-UA",
        "vi": "vi-VN",
        "zh": "cmn-Hans-CN",
    ]

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard !translate else {
            throw PluginTranscriptionError.apiError("Gemini speech transcription does not support translation yet.")
        }
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = selectedModelId?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isDedicatedTranscriptionModelId(modelId),
              resolvedTranscriptionModels.contains(where: { $0.id == modelId }) else {
            throw PluginTranscriptionError.noModelSelected
        }

        return try await transcribeDedicated(
            audio: audio,
            apiKey: apiKey,
            modelId: modelId,
            language: language,
            prompt: prompt
        )
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        let result = try await transcribe(
            audio: audio,
            language: language,
            translate: translate,
            prompt: prompt
        )
        _ = onProgress(result.text)
        return result
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: PluginLanguageSelection(requestedLanguage: language),
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: PluginDictionaryTerms.termHints(fromPrompt: prompt),
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: languageSelection,
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: PluginDictionaryTerms.termHints(fromPrompt: prompt),
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: PluginLanguageSelection(requestedLanguage: language),
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        guard !translate else {
            throw PluginTranscriptionError.apiError("Gemini speech transcription does not support translation yet.")
        }
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let liveModelId = liveTranscriptionModelId(for: selectedModelId) else {
            throw PluginTranscriptionError.apiError("The selected Gemini model does not support live transcription.")
        }

        let promptHints = PluginDictionaryTerms.termHints(fromPrompt: prompt)
        let vocabulary = PluginDictionaryTerms.clippedTermHints(
            from: dictionaryTermHints + promptHints,
            budget: dictionaryTermsBudget
        ).map(\.text)

        return try await GeminiLiveTranscriptionSession.connect(
            apiKey: apiKey,
            modelId: liveModelId,
            languageCodes: Self.resolvedLanguageCodes(from: languageSelection),
            customVocabulary: vocabulary,
            onProgress: onProgress
        )
    }

    nonisolated static func resolvedLanguageCodes(
        from selection: PluginLanguageSelection
    ) -> [String] {
        var seen = Set<String>()
        return ([selection.requestedLanguage] + selection.languageHints.map(Optional.some))
            .compactMap(resolvedTranscriptionLanguageCode)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    nonisolated static func resolvedTranscriptionLanguageCode(_ language: String?) -> String? {
        guard let language else { return nil }
        let normalized = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty,
              normalized.caseInsensitiveCompare("auto") != .orderedSame else {
            return nil
        }
        guard !normalized.contains("-") else { return normalized }
        return transcriptionLanguageCodeOverrides[normalized.lowercased()] ?? normalized
    }

    private func transcribeDedicated(
        audio: AudioData,
        apiKey: String,
        modelId: String,
        language: String?,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        try await PluginAudioUploadEncoder.withCompressedM4AUploadWavFallback(from: audio) { uploadFile in
            let uploadedFile = try await Self.uploadFile(uploadFile, apiKey: apiKey)

            do {
                let request = try Self.makeDedicatedTranscriptionRequest(
                    uploadedFile: uploadedFile,
                    apiKey: apiKey,
                    modelId: modelId,
                    language: language,
                    prompt: prompt,
                    timeout: Self.dedicatedTranscriptionRequestTimeout
                )
                let (data, response) = try await PluginHTTPClient.data(
                    for: request,
                    resourceTimeout: Self.dedicatedTranscriptionRequestTimeout
                )
                try Self.validateTranscriptionResponse(data: data, response: response)
                let text = try Self.parseDedicatedTranscriptionResponse(data)
                await Self.deleteUploadedFile(uploadedFile, apiKey: apiKey)
                return PluginTranscriptionResult(text: text, detectedLanguage: language)
            } catch {
                await Self.deleteUploadedFile(uploadedFile, apiKey: apiKey)
                throw error
            }
        }
    }

    private static func uploadFile(
        _ uploadFile: PluginAudioUploadFile,
        apiKey: String
    ) async throws -> GeminiUploadedFile {
        let startRequest = try makeFileUploadStartRequest(uploadFile: uploadFile, apiKey: apiKey)
        let (startData, startResponse) = try await PluginHTTPClient.data(for: startRequest)
        try validateTranscriptionResponse(data: startData, response: startResponse)

        guard let httpResponse = startResponse as? HTTPURLResponse,
              let uploadURLValue = httpResponse.value(forHTTPHeaderField: "x-goog-upload-url"),
              let uploadURL = URL(string: uploadURLValue) else {
            throw PluginTranscriptionError.apiError("Gemini Files API did not return an upload URL.")
        }

        let uploadRequest = makeFileUploadRequest(
            uploadFile: uploadFile,
            uploadURL: uploadURL
        )
        let (data, response) = try await PluginHTTPClient.data(
            for: uploadRequest,
            resourceTimeout: Self.dedicatedTranscriptionRequestTimeout
        )
        try validateTranscriptionResponse(data: data, response: response)

        do {
            let decoded = try JSONDecoder().decode(GeminiFileUploadResponse.self, from: data)
            return GeminiUploadedFile(
                name: decoded.file.name,
                uri: decoded.file.uri,
                mimeType: decoded.file.mimeType ?? uploadFile.contentType
            )
        } catch {
            throw PluginTranscriptionError.apiError(
                "Failed to parse Gemini file upload response: \(error.localizedDescription)"
            )
        }
    }

    static func makeFileUploadStartRequest(
        uploadFile: PluginAudioUploadFile,
        apiKey: String
    ) throws -> URLRequest {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files") else {
            throw PluginTranscriptionError.apiError("Invalid Gemini Files API URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue(String(uploadFile.data.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        request.setValue(uploadFile.contentType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.transcriptionRequestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "file": ["display_name": uploadFile.filename],
        ])
        return request
    }

    static func makeFileUploadRequest(
        uploadFile: PluginAudioUploadFile,
        uploadURL: URL
    ) -> URLRequest {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue(String(uploadFile.data.count), forHTTPHeaderField: "Content-Length")
        request.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        request.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue(uploadFile.contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.transcriptionRequestTimeout
        request.httpBody = uploadFile.data
        return request
    }

    static func makeDedicatedTranscriptionRequest(
        uploadedFile: GeminiUploadedFile,
        apiKey: String,
        modelId: String,
        language: String?,
        prompt: String?,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            throw PluginTranscriptionError.apiError("Invalid Gemini Interactions API URL.")
        }

        var transcriptionConfig: [String: Any] = ["mode": "smart"]
        if let languageCode = resolvedTranscriptionLanguageCode(language) {
            transcriptionConfig["language_codes"] = [languageCode]
        }

        let dictionaryTerms = PluginDictionaryTerms.clippedTerms(
            from: PluginDictionaryTerms.terms(fromPrompt: prompt),
            budget: DictionaryTermsBudget(maxTerms: 1_000)
        )
        if !dictionaryTerms.isEmpty {
            transcriptionConfig["custom_vocabulary"] = dictionaryTerms
        }

        let body: [String: Any] = [
            "model": modelId,
            "input": [[
                "type": "audio",
                "uri": uploadedFile.uri,
                "mime_type": uploadedFile.mimeType,
            ]],
            "generation_config": [
                "transcription_config": transcriptionConfig,
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseDedicatedTranscriptionResponse(_ data: Data) throws -> String {
        do {
            let response = try JSONDecoder().decode(GeminiInteractionResponse.self, from: data)
            let responseSteps = response.steps ?? response.outputs ?? []
            let modelOutputSteps = responseSteps.filter { step in
                step.type == nil || step.type == "model_output"
            }
            let outputContent = modelOutputSteps.flatMap { $0.content ?? [] }
            let textBlocks = outputContent.compactMap { content -> String? in
                guard content.type == nil || content.type == "text" else { return nil }
                return content.text
            }
            let text = (response.outputText ?? textBlocks.joined(separator: ""))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                let detail = response.error?.message ?? response.status ?? "empty response"
                throw PluginTranscriptionError.apiError("Gemini transcription failed: \(detail)")
            }
            return text
        } catch let error as PluginTranscriptionError {
            throw error
        } catch {
            throw PluginTranscriptionError.apiError(
                "Failed to parse Gemini transcription response: \(error.localizedDescription)"
            )
        }
    }

    private static func deleteUploadedFile(
        _ uploadedFile: GeminiUploadedFile,
        apiKey: String
    ) async {
        let escapedName = uploadedFile.name
            .split(separator: "/")
            .map(String.init)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(escapedName)") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 15
        _ = try? await PluginHTTPClient.data(for: request)
    }

    static func validateTranscriptionResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid Gemini response.")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw PluginTranscriptionError.invalidApiKey
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(transcriptionErrorMessage(from: data))")
        }
    }

    private static func transcriptionErrorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String,
              !message.isEmpty else {
            return "Gemini transcription request failed."
        }
        return message
    }

    private static func resolvedTranscriptionModelId(
        _ storedModelId: String?,
        availableModels: [GeminiFetchedTranscriptionModel],
        host: HostServices
    ) -> String {
        let trimmedModelId = storedModelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportedIds = Set(availableModels.map(\.id))
        let modelId = trimmedModelId.flatMap { supportedIds.contains($0) ? $0 : nil }
            ?? defaultTranscriptionModelId

        if modelId != storedModelId {
            host.setUserDefault(modelId, forKey: selectedTranscriptionModelKey)
        }

        return modelId
    }

    private func liveTranscriptionModelId(for modelId: String?) -> String? {
        guard let modelId else { return nil }
        return resolvedTranscriptionModels.first(where: { $0.id == modelId })?.liveModelId
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
              let request = Self.makeModelsRequest(apiKey: key, pageSize: 1) else { return false }

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

    fileprivate func setFetchedTranscriptionModels(_ models: [GeminiFetchedTranscriptionModel]) {
        let compatibleModels = Self.compatibleTranscriptionModels(from: models)
        _fetchedTranscriptionModels = compatibleModels
        if let data = try? JSONEncoder().encode(compatibleModels) {
            host?.setUserDefault(data, forKey: Self.cachedTranscriptionModelsKey)
        }

        if let selectedModelId,
           !resolvedTranscriptionModels.contains(where: { $0.id == selectedModelId }) {
            selectModel(Self.defaultTranscriptionModelId)
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setFetchedModelCatalog(_ catalog: GeminiModelCatalog) {
        setFetchedLLMModels(catalog.llmModels)
        setFetchedTranscriptionModels(catalog.transcriptionModels)
        host?.setUserDefault(Date(), forKey: Self.modelCatalogRefreshDateKey)
    }

    func fetchModelCatalog() async -> GeminiModelCatalog {
        guard let apiKey = _apiKey, !apiKey.isEmpty else { return .empty }
        return await Self.fetchModelCatalog(apiKey: apiKey)
    }

    nonisolated private static func fetchModelCatalog(apiKey: String) async -> GeminiModelCatalog {
        var apiModels: [GeminiAPIModel] = []
        var nextPageToken: String?

        do {
            repeat {
                guard let request = Self.makeModelsRequest(
                    apiKey: apiKey,
                    pageSize: 1_000,
                    pageToken: nextPageToken
                ) else { return .empty }

                let (data, response) = try await PluginHTTPClient.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { return .empty }

                let page = try JSONDecoder().decode(GeminiModelsPage.self, from: data)
                apiModels.append(contentsOf: page.models)
                nextPageToken = page.nextPageToken?.trimmingCharacters(in: .whitespacesAndNewlines)
                if nextPageToken?.isEmpty == true {
                    nextPageToken = nil
                }
            } while nextPageToken != nil

            return Self.makeModelCatalog(from: apiModels)
        } catch {
            return .empty
        }
    }

    fileprivate func fetchLLMModels() async -> [GeminiFetchedModel] {
        (await fetchModelCatalog()).llmModels
    }

    fileprivate func fetchTranscriptionModels() async -> [GeminiFetchedTranscriptionModel] {
        (await fetchModelCatalog()).transcriptionModels
    }

    nonisolated static func decodeModelCatalog(from data: Data) throws -> GeminiModelCatalog {
        let page = try JSONDecoder().decode(GeminiModelsPage.self, from: data)
        return makeModelCatalog(from: page.models)
    }

    nonisolated private static func makeModelCatalog(from models: [GeminiAPIModel]) -> GeminiModelCatalog {
        var seenLLMIds = Set<String>()
        let llmModels = models
            .compactMap { model -> GeminiFetchedModel? in
                let id = normalizedModelId(model.name)
                guard isCompatibleChatModel(model, normalizedId: id),
                      seenLLMIds.insert(id).inserted else { return nil }
                return GeminiFetchedModel(id: id, displayName: model.displayName)
            }
            .sorted { $0.id < $1.id }

        let availableIds = Set(models.map { normalizedModelId($0.name) })
        var seenTranscriptionIds = Set<String>()
        let transcriptionModels = models
            .compactMap { model -> GeminiFetchedTranscriptionModel? in
                let id = normalizedModelId(model.name)
                guard isDedicatedTranscriptionModelId(id),
                      seenTranscriptionIds.insert(id).inserted else { return nil }

                let liveModelId = "\(id)-live"
                return GeminiFetchedTranscriptionModel(
                    id: id,
                    displayName: model.displayName,
                    liveModelId: availableIds.contains(liveModelId) ? liveModelId : nil
                )
            }
            .sorted { $0.id < $1.id }

        return GeminiModelCatalog(
            llmModels: llmModels,
            transcriptionModels: transcriptionModels
        )
    }

    nonisolated private static func normalizedModelId(_ id: String) -> String {
        guard id.hasPrefix(modelIdPrefix) else { return id }
        return String(id.dropFirst(modelIdPrefix.count))
    }

    nonisolated private static func isCompatibleChatModel(
        _ model: GeminiAPIModel,
        normalizedId id: String
    ) -> Bool {
        guard id.hasPrefix("gemini-") else { return false }
        guard model.supportedGenerationMethods.contains(where: {
            $0.caseInsensitiveCompare("generateContent") == .orderedSame
        }) else { return false }
        return !excludedCompatibleModelTokens.contains { id.localizedCaseInsensitiveContains($0) }
    }

    nonisolated private static func isDedicatedTranscriptionModelId(_ id: String) -> Bool {
        id.hasPrefix("gemini-")
            && id.localizedCaseInsensitiveContains("-transcribe")
            && !id.localizedCaseInsensitiveContains("-transcribe-live")
    }

    nonisolated private static func compatibleTranscriptionModels(
        from models: [GeminiFetchedTranscriptionModel]
    ) -> [GeminiFetchedTranscriptionModel] {
        var seenIds = Set<String>()
        return models.filter {
            isDedicatedTranscriptionModelId($0.id) && seenIds.insert($0.id).inserted
        }
    }

    nonisolated private static func makeModelsRequest(
        apiKey: String,
        pageSize: Int,
        pageToken: String? = nil
    ) -> URLRequest? {
        guard var components = URLComponents(string: modelsEndpoint) else { return nil }
        var queryItems = [URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let pageToken, !pageToken.isEmpty {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 15
        return request
    }

    /// Validates the persisted selection against the current model list.
    /// `_selectedLLMModelId` (and thus `preferredModelId`) only ever holds an
    /// explicit, still-valid user selection — a fallback is never seeded into
    /// it or persisted, so the host cannot mistake the alphabetically-oldest
    /// fetched model for a deliberate choice. The stored value is kept even
    /// while invalid so it re-validates if the model reappears after a fetch.
    private func normalizeSelectedModel() {
        let storedModelId = host?.userDefault(forKey: Self.selectedLLMModelKey) as? String
        let supportedIds = Set(supportedModels.map(\.id))
        if let storedModelId, supportedIds.contains(storedModelId) {
            _selectedLLMModelId = storedModelId
        } else {
            _selectedLLMModelId = nil
        }
    }

    private func refreshModelCatalogIfNeeded() {
        guard _apiKey?.isEmpty == false else { return }

        let lastRefreshDate = host?.userDefault(forKey: Self.modelCatalogRefreshDateKey) as? Date
        let cacheIsFresh = lastRefreshDate.map {
            Date().timeIntervalSince($0) < Self.modelCatalogRefreshInterval
        } ?? false
        guard !cacheIsFresh || (_fetchedLLMModels.isEmpty && _fetchedTranscriptionModels.isEmpty) else {
            return
        }

        guard let apiKey = _apiKey else { return }
        modelCatalogRefreshTask?.cancel()
        modelCatalogRefreshTask = Task { [weak self, apiKey] in
            let catalog = await Self.fetchModelCatalog(apiKey: apiKey)
            guard !Task.isCancelled, !catalog.isEmpty, let self else { return }

            await MainActor.run {
                self.setFetchedModelCatalog(catalog)
            }
        }
    }
}

// MARK: - Gemini Live Transcription

actor GeminiLiveTranscriptionSession: LiveTranscriptionSession {
    private static let webSocketEndpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    private static let pcmChunkSampleCount = 1_600
    private static let setupTimeout: Duration = .seconds(10)
    private static let finishTimeout: Duration = .seconds(2)

    private let urlSession: URLSession
    private let webSocketTask: URLSessionWebSocketTask
    private let onProgress: @Sendable (String) -> Bool
    private var receiveTask: Task<Void, Never>?
    private var collector = GeminiLiveTranscriptCollector()
    private var setupComplete = false
    private var finalRevision = 0
    private var latestError: String?
    private var finished = false
    private var cancelled = false

    private init(
        urlSession: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        onProgress: @Sendable @escaping (String) -> Bool
    ) {
        self.urlSession = urlSession
        self.webSocketTask = webSocketTask
        self.onProgress = onProgress
    }

    static func connect(
        apiKey: String,
        modelId: String,
        languageCodes: [String],
        customVocabulary: [String],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> GeminiLiveTranscriptionSession {
        try ensureNetworkAccessIsAllowed()
        guard var components = URLComponents(string: webSocketEndpoint) else {
            throw PluginTranscriptionError.apiError("Invalid Gemini Live API URL.")
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw PluginTranscriptionError.apiError("Invalid Gemini Live API URL.")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let urlSession = URLSession(configuration: configuration)
        let webSocketTask = urlSession.webSocketTask(with: url)
        let session = GeminiLiveTranscriptionSession(
            urlSession: urlSession,
            webSocketTask: webSocketTask,
            onProgress: onProgress
        )

        do {
            try await session.start(
                modelId: modelId,
                languageCodes: languageCodes,
                customVocabulary: customVocabulary
            )
            return session
        } catch {
            await session.cancel()
            throw error
        }
    }

    private func start(
        modelId: String,
        languageCodes: [String],
        customVocabulary: [String]
    ) async throws {
        webSocketTask.resume()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }

        let setupMessage = try Self.makeSetupMessage(
            modelId: modelId,
            languageCodes: languageCodes,
            customVocabulary: customVocabulary
        )
        try await webSocketTask.send(.string(setupMessage))
        try await waitForSetup()
    }

    func appendAudio(samples: [Float]) async throws {
        guard !finished, !cancelled else { return }
        if let latestError {
            throw PluginTranscriptionError.apiError(latestError)
        }

        var offset = 0
        while offset < samples.count {
            let end = min(offset + Self.pcmChunkSampleCount, samples.count)
            let pcmData = Self.pcm16Data(from: samples[offset..<end])
            let message = try Self.makeRealtimeAudioMessage(pcmData)
            do {
                try await webSocketTask.send(.string(message))
            } catch {
                latestError = error.localizedDescription
                throw PluginTranscriptionError.networkError(error.localizedDescription)
            }
            offset = end
        }
    }

    func finish() async throws -> PluginTranscriptionResult {
        if finished {
            return try finalResult()
        }
        finished = true

        let revisionBeforeFinish = finalRevision
        do {
            try await webSocketTask.send(.string(Self.audioStreamEndMessage))
        } catch {
            if collector.resultText.isEmpty {
                throw PluginTranscriptionError.networkError(error.localizedDescription)
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.finishTimeout)
        while finalRevision == revisionBeforeFinish,
              latestError == nil,
              clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }

        closeSocket(code: .normalClosure)
        return try finalResult()
    }

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        closeSocket(code: .goingAway)
    }

    private func waitForSetup() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        while !setupComplete, latestError == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        if let latestError {
            throw PluginTranscriptionError.apiError(latestError)
        }
        guard setupComplete else {
            throw PluginTranscriptionError.networkError("Timed out while connecting to Gemini Live transcription.")
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                let message = try await webSocketTask.receive()
                try handle(message)
            } catch is CancellationError {
                return
            } catch {
                guard !cancelled, !finished else { return }
                latestError = error.localizedDescription
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .data(let messageData):
            data = messageData
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            return
        }

        let response = try JSONDecoder().decode(GeminiLiveResponse.self, from: data)
        if response.setupComplete != nil {
            setupComplete = true
        }
        if let message = response.error?.message, !message.isEmpty {
            latestError = message
        }

        guard let serverContent = response.serverContent else { return }
        let finalText = serverContent.inputTranscription?.text
        let preview = collector.apply(
            interimText: serverContent.interimInputTranscription?.text,
            finalText: finalText
        )
        if finalText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            finalRevision += 1
        }
        if let preview, !preview.isEmpty {
            _ = onProgress(preview)
        }
    }

    private func finalResult() throws -> PluginTranscriptionResult {
        let text = collector.resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let latestError {
            throw PluginTranscriptionError.apiError(latestError)
        }
        guard !text.isEmpty else {
            throw PluginTranscriptionError.apiError("Gemini Live transcription returned no text.")
        }
        return PluginTranscriptionResult(text: text)
    }

    private func closeSocket(code: URLSessionWebSocketTask.CloseCode) {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask.cancel(with: code, reason: nil)
        urlSession.finishTasksAndInvalidate()
    }

    static func makeSetupMessage(
        modelId: String,
        languageCodes: [String],
        customVocabulary: [String]
    ) throws -> String {
        var transcriptionConfig: [String: Any] = ["mode": "SMART"]
        if !languageCodes.isEmpty {
            transcriptionConfig["languageCodes"] = languageCodes
        }
        if !customVocabulary.isEmpty {
            transcriptionConfig["customVocabulary"] = Array(customVocabulary.prefix(1_000))
        }

        let body: [String: Any] = [
            "setup": [
                "model": "models/\(modelId)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcriptionConfig,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw PluginTranscriptionError.apiError("Failed to encode Gemini Live setup message.")
        }
        return text
    }

    static func makeRealtimeAudioMessage(_ pcmData: Data) throws -> String {
        let body: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": pcmData.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000",
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw PluginTranscriptionError.apiError("Failed to encode Gemini Live audio message.")
        }
        return text
    }

    static let audioStreamEndMessage = #"{"realtimeInput":{"audioStreamEnd":true}}"#

    static func pcm16Data(from samples: ArraySlice<Float>) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func ensureNetworkAccessIsAllowed() throws {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--store-screenshots") {
            throw URLError(.notConnectedToInternet)
        }
        #endif
    }
}

struct GeminiLiveTranscriptCollector: Sendable {
    private var committedText = ""
    private var interimText = ""

    var resultText: String {
        Self.combined(committed: committedText, interim: interimText)
    }

    mutating func apply(interimText newInterim: String?, finalText newFinal: String?) -> String? {
        if let final = Self.normalized(newFinal), !final.isEmpty {
            if committedText.isEmpty || final.hasPrefix(committedText) {
                committedText = final
            } else if !committedText.hasSuffix(final) {
                committedText = Self.joined(committedText, final)
            }
            interimText = ""
            return resultText
        }

        if let interim = Self.normalized(newInterim), !interim.isEmpty {
            interimText = interim
            return resultText
        }
        return nil
    }

    private static func combined(committed: String, interim: String) -> String {
        guard !committed.isEmpty else { return interim }
        guard !interim.isEmpty else { return committed }
        if interim.hasPrefix(committed) { return interim }
        if committed.hasSuffix(interim) { return committed }
        return joined(committed, interim)
    }

    private static func joined(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        if lhs.last?.isWhitespace == true || rhs.first?.isWhitespace == true {
            return lhs + rhs
        }
        return lhs + " " + rhs
    }

    private static func normalized(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GeminiLiveResponse: Decodable, Sendable {
    let setupComplete: EmptyObject?
    let serverContent: ServerContent?
    let error: APIError?

    struct EmptyObject: Decodable, Sendable {}

    struct ServerContent: Decodable, Sendable {
        let interimInputTranscription: Transcription?
        let inputTranscription: Transcription?
    }

    struct Transcription: Decodable, Sendable {
        let text: String?
    }

    struct APIError: Decodable, Sendable {
        let message: String?
    }
}

// MARK: - Native Models API

private struct GeminiModelsPage: Decodable, Sendable {
    let models: [GeminiAPIModel]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decodeIfPresent([GeminiAPIModel].self, forKey: .models) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case models
        case nextPageToken
    }
}

private struct GeminiAPIModel: Decodable, Sendable {
    let name: String
    let displayName: String?
    let supportedGenerationMethods: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        supportedGenerationMethods = try container.decodeIfPresent(
            [String].self,
            forKey: .supportedGenerationMethods
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case displayName
        case supportedGenerationMethods
    }
}

// MARK: - Fetched Model

struct GeminiFetchedModel: Codable, Sendable {
    let id: String
    let displayName: String?
}

struct GeminiFetchedTranscriptionModel: Codable, Sendable {
    let id: String
    let displayName: String?
    let liveModelId: String?

    init(id: String, displayName: String?, liveModelId: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.liveModelId = liveModelId
    }
}

struct GeminiModelCatalog: Sendable {
    let llmModels: [GeminiFetchedModel]
    let transcriptionModels: [GeminiFetchedTranscriptionModel]

    static let empty = GeminiModelCatalog(llmModels: [], transcriptionModels: [])

    var isEmpty: Bool {
        llmModels.isEmpty && transcriptionModels.isEmpty
    }
}

struct GeminiUploadedFile: Sendable, Equatable {
    let name: String
    let uri: String
    let mimeType: String
}

private struct GeminiFileUploadResponse: Decodable, Sendable {
    let file: File

    struct File: Decodable, Sendable {
        let name: String
        let uri: String
        let mimeType: String?
    }
}

private struct GeminiInteractionResponse: Decodable, Sendable {
    let status: String?
    let outputText: String?
    let steps: [Step]?
    let outputs: [Step]?
    let error: APIError?

    enum CodingKeys: String, CodingKey {
        case status
        case outputText = "output_text"
        case steps
        case outputs
        case error
    }

    struct Step: Decodable, Sendable {
        let type: String?
        let content: [Content]?
    }

    struct Content: Decodable, Sendable {
        let type: String?
        let text: String?
    }

    struct APIError: Decodable, Sendable {
        let message: String?
    }
}

// MARK: - Settings View

private struct GeminiSettingsView: View {
    let plugin: GeminiPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedLLMModel: String = ""
    @State private var selectedTranscriptionModel: String = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var fetchedLLMModels: [GeminiFetchedModel] = []
    @State private var fetchedTranscriptionModels: [GeminiFetchedTranscriptionModel] = []
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
                            refreshModels()
                        } label: {
                            Label(String(localized: "Refresh", bundle: bundle), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Picker("Model", selection: $selectedLLMModel) {
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

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcription Model", bundle: bundle)
                        .font(.headline)

                    Picker("Transcription Model", selection: $selectedTranscriptionModel) {
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedTranscriptionModel) {
                        plugin.selectModel(selectedTranscriptionModel)
                    }

                    if fetchedTranscriptionModels.isEmpty {
                        Text("Using built-in transcription models until the Gemini catalog is available.", bundle: bundle)
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
            selectedLLMModel = plugin.selectedLLMModelId ?? plugin.defaultLLMModelId ?? ""
            selectedTranscriptionModel = plugin.selectedModelId ?? ""
            llmTemperatureMode = plugin.llmTemperatureMode
            llmTemperatureValue = plugin.llmTemperatureValue
            fetchedLLMModels = plugin._fetchedLLMModels
            fetchedTranscriptionModels = plugin._fetchedTranscriptionModels
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
                let catalog = await plugin.fetchModelCatalog()
                await MainActor.run {
                    isValidating = false
                    validationResult = true
                    applyModelCatalog(catalog)
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
            let catalog = await plugin.fetchModelCatalog()
            await MainActor.run {
                applyModelCatalog(catalog)
            }
        }
    }

    private func applyModelCatalog(_ catalog: GeminiModelCatalog) {
        guard !catalog.isEmpty else { return }
        plugin.setFetchedModelCatalog(catalog)

        fetchedLLMModels = catalog.llmModels
        if !plugin.supportedModels.contains(where: { $0.id == selectedLLMModel }),
           let fallback = plugin.defaultLLMModelId {
            selectedLLMModel = fallback
            plugin.selectLLMModel(fallback)
        }

        fetchedTranscriptionModels = catalog.transcriptionModels
        if !plugin.transcriptionModels.contains(where: { $0.id == selectedTranscriptionModel }),
           let fallback = plugin.selectedModelId ?? plugin.transcriptionModels.first?.id {
            selectedTranscriptionModel = fallback
            plugin.selectModel(fallback)
        }
    }
}
