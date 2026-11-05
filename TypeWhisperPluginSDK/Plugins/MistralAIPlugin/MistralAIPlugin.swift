import Foundation
import TypeWhisperPluginSDK
import SwiftUI

@objc(MistralAIPlugin)
public final class MistralAIPlugin: NSObject, LLMProviderPlugin, LLMProviderIdentityProviding, LLMModelSelectable, LLMTemperatureControllableProvider, TranscriptionEnginePlugin, @unchecked Sendable {
    
    public static var pluginId: String { "com.minerale.mistralai" }
    public static var pluginName: String { "Mistral AI" }
    
    private let lock = NSRecursiveLock()
    private var _host: HostServices?
    
    private var host: HostServices? {
        get { lock.withLock { _host } }
        set { lock.withLock { _host = newValue } }
    }
    
    public var apiKey: String {
        host?.loadSecret(key: "api-key") ?? ""
    }
    
    public override init() {
        super.init()
    }
    
    public func activate(host: HostServices) {
        var persistedTranscriptionModel: String?
        var shouldRewriteTranscriptionModel = false
        lock.withLock {
            self._host = host
            self._selectedLLMModelId = host.userDefault(forKey: "selectedLLMModel") as? String
            let storedTranscriptionModel = host.userDefault(forKey: "selectedModel") as? String
            let resolvedTranscriptionModel = storedTranscriptionModel.flatMap(Self.resolvedTranscriptionModelId)
            self._selectedModelId = resolvedTranscriptionModel
            self._llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
                ?? PluginLLMTemperatureMode.providerDefault.rawValue
            self._llmTemperatureValue = host.userDefault(forKey: "llmTemperatureValue") as? Double ?? 0.3
            persistedTranscriptionModel = resolvedTranscriptionModel
            if let storedTranscriptionModel {
                if let resolvedTranscriptionModel {
                    shouldRewriteTranscriptionModel = storedTranscriptionModel != resolvedTranscriptionModel
                } else {
                    shouldRewriteTranscriptionModel = true
                }
            }
        }
        if shouldRewriteTranscriptionModel {
            if let persistedTranscriptionModel {
                host.setUserDefault(persistedTranscriptionModel, forKey: "selectedModel")
            } else {
                host.setUserDefault(nil, forKey: "selectedModel")
            }
        }
        print("Mistral AI Plugin activated")
    }
    
    public func deactivate() {
        lock.withLock {
            self._host = nil
        }
        print("Mistral AI Plugin deactivated")
    }
    
    public var settingsView: AnyView? {
        AnyView(MistralSettingsView(plugin: self))
    }
    
    public func setApiKey(_ key: String) {
        guard let host = host else {
            print("[MistralAIPlugin] Failed to save API key: Host services not active.")
            return
        }
        do {
            try host.storeSecret(key: "api-key", value: key)
            host.notifyCapabilitiesChanged()
        } catch {
            print("[MistralAIPlugin] Failed to store API key: \(error)")
        }
    }
    
    public func clearApiKey() {
        guard let host = host else { return }
        do {
            try host.storeSecret(key: "api-key", value: "")
            host.notifyCapabilitiesChanged()
        } catch {
            print("[MistralAIPlugin] Failed to delete API key: \(error)")
        }
    }
    
    // MARK: - LLMProviderPlugin
    
    public var providerName: String { "Mistral AI" }
    
    public var isAvailable: Bool { !apiKey.isEmpty }
    
    public var supportedModels: [PluginModelInfo] {
        guard !apiKey.isEmpty else { return [] }
        return [
            PluginModelInfo(id: "mistral-large-latest", displayName: "Mistral Large"),
            PluginModelInfo(id: "pixtral-12b-2409", displayName: "Pixtral 12B"),
            PluginModelInfo(id: "ministral-8b-latest", displayName: "Ministral 8B"),
            PluginModelInfo(id: "ministral-3b-latest", displayName: "Ministral 3B"),
            PluginModelInfo(id: "mistral-small-latest", displayName: "Mistral Small")
        ]
    }
    
    public func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: .inheritProviderSetting
        )
    }

    public func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String {
        let llmModelId = lock.withLock { _selectedLLMModelId }
        let selectedModel = model ?? ((llmModelId?.isEmpty == false) ? llmModelId! : "mistral-small-latest")
        let temperature = providerTemperatureDirective.resolvedTemperature(applying: temperatureDirective)
        let client = MistralAPIClient(apiKey: apiKey)
        return try await client.processChat(
            systemPrompt: systemPrompt,
            userText: userText,
            model: selectedModel,
            temperature: temperature
        )
    }

    // MARK: - LLMTemperatureControllableProvider

    private var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
    private var _llmTemperatureValue: Double = 0.3

    public var llmTemperatureMode: PluginLLMTemperatureMode {
        lock.withLock { PluginLLMTemperatureMode(rawValue: _llmTemperatureModeRaw) ?? .providerDefault }
    }

    public var llmTemperatureValue: Double { lock.withLock { _llmTemperatureValue } }

    private var providerTemperatureDirective: PluginLLMTemperatureDirective {
        lock.withLock { PluginLLMTemperatureDirective(mode: PluginLLMTemperatureMode(rawValue: _llmTemperatureModeRaw) ?? .providerDefault, value: _llmTemperatureValue) }
    }

    public func setLLMTemperatureMode(_ mode: PluginLLMTemperatureMode) {
        lock.withLock { _llmTemperatureModeRaw = mode.rawValue }
        host?.setUserDefault(mode.rawValue, forKey: "llmTemperatureMode")
    }

    public func setLLMTemperatureValue(_ value: Double) {
        let clamped = min(max(value, 0.0), 2.0)
        lock.withLock { _llmTemperatureValue = clamped }
        host?.setUserDefault(clamped, forKey: "llmTemperatureValue")
    }
    
    // MARK: - LLMModelSelectable
    
    private var _selectedLLMModelId: String?
    
    public var selectedLLMModelId: String? { lock.withLock { _selectedLLMModelId } }
    
    @objc public var preferredModelId: String? { lock.withLock { _selectedLLMModelId } }
    
    @objc public var defaultModelId: String? { "mistral-small-latest" }
    
    public func selectLLMModel(_ modelId: String) {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueToSave = normalized.isEmpty ? nil : normalized
        lock.withLock {
            _selectedLLMModelId = valueToSave
        }
        host?.setUserDefault(valueToSave, forKey: "selectedLLMModel")
        host?.notifyCapabilitiesChanged()
    }
    
    // MARK: - Identity & TranscriptionEnginePlugin
    
    public var providerId: String { "mistral" }
    public var providerDisplayName: String { "Mistral AI" }
    public var isConfigured: Bool { isAvailable }
    
    public var transcriptionModels: [PluginModelInfo] {
        guard !apiKey.isEmpty else { return [] }
        return Self.availableTranscriptionModels
    }

    /// Voxtral Mini Transcribe 3. Used when the user has not picked a model.
    static let defaultTranscriptionModelId = "voxtral-mini-transcribe-3"

    /// Voxtral Small Transcribe 3, the higher-quality file transcription model.
    static let smallTranscriptionModelId = "voxtral-small-transcribe-3"

    /// Both IDs are the Transcribe 3 aliases documented for
    /// `POST /v1/audio/transcriptions`. Mini is first because it is the default.
    static let availableTranscriptionModels: [PluginModelInfo] = [
        PluginModelInfo(id: defaultTranscriptionModelId, displayName: "Voxtral Mini Transcribe 3"),
        PluginModelInfo(id: smallTranscriptionModelId, displayName: "Voxtral Small Transcribe 3"),
    ]

    /// Persisted Voxtral 2 transcription IDs. `voxtral-mini-latest` pointed at
    /// Voxtral Mini Transcribe 2 (`voxtral-mini-2602`). `voxtral-small-latest`
    /// was sent through chat completions because that endpoint did not serve
    /// Small; its Voxtral 2 model is `voxtral-small-2507`.
    static let transcriptionModelMigrations: [String: String] = [
        "voxtral-mini-latest": defaultTranscriptionModelId,
        "voxtral-mini-2602": defaultTranscriptionModelId,
        "voxtral-small-latest": smallTranscriptionModelId,
        "voxtral-small-2507": smallTranscriptionModelId,
    ]

    /// Empty input becomes "no selection" (`nil`). A known Voxtral 2 ID becomes
    /// its Transcribe 3 replacement. Anything else is kept, trimmed.
    static func resolvedTranscriptionModelId(_ modelId: String) -> String? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return transcriptionModelMigrations[trimmed] ?? trimmed
    }
    
    private var _selectedModelId: String?
    public var selectedModelId: String? { lock.withLock { _selectedModelId } }
    
    public func selectModel(_ modelId: String) {
        let valueToSave = Self.resolvedTranscriptionModelId(modelId)
        lock.withLock {
            _selectedModelId = valueToSave
        }
        if let valueToSave {
            host?.setUserDefault(valueToSave, forKey: "selectedModel")
        } else {
            host?.setUserDefault(nil, forKey: "selectedModel")
        }
        host?.notifyCapabilitiesChanged()
    }
    
    public var supportsTranslation: Bool { false }
    public var supportsStreaming: Bool { false } // Note: We declare false here because Mistral's basic API doesn't support WebSocket streaming chunk-by-chunk in a public STT endpoint yet. The TypeWhisper app will just use transcribe(audio:...) normally.
    // Codes the language picker can force. Transcribe 3 documents 50 languages
    // for file transcription, but the languages page does not list their codes,
    // so this stays the eight languages the plugin already offered. Leaving the
    // language unset lets the model detect one from the wider set.
    public var supportedLanguages: [String] {
        ["en", "fr", "de", "es", "it", "pt", "nl", "hi"]
    }
    
    public func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        let client = MistralAPIClient(apiKey: apiKey)
        let sttModelId = lock.withLock { _selectedModelId }
        let sttModel = sttModelId.flatMap(Self.resolvedTranscriptionModelId) ?? Self.defaultTranscriptionModelId
        // Mini and Small Transcribe 3 both use /v1/audio/transcriptions.
        // Ten-minute chunks stay within the WAV fallback size the shared
        // uploader already accounts for.
        return try await PluginAudioChunking.transcribe(audio) { chunk in
            try await client.transcribe(audio: chunk, language: language, model: sttModel)
        }
    }
}

enum MistralAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL."
        case .invalidResponse: return "Invalid API response."
        case .apiError(let message): return "API Error: \(message)"
        }
    }
}

struct MistralAPIClient {
    private let apiKey: String
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    // MARK: - Chat Completions (LLM)
    
    func processChat(systemPrompt: String, userText: String, model: String, temperature: Double? = nil) async throws -> String {
        guard let url = URL(string: "https://api.mistral.ai/v1/chat/completions") else {
            throw MistralAPIError.invalidURL
        }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]
        if let temperature {
            body["temperature"] = temperature
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MistralAPIError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            // Reported before parsing: an unreadable reply still used the tokens.
            PluginLLMUsageReporting.report(.openAICompatible(from: data))
            return try parseChatResponse(data)
        } else {
            throw MistralAPIError.apiError(errorMessage(from: data, response: httpResponse))
        }
    }
    
    private func parseChatResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MistralAPIError.apiError("Failed to parse response text")
        }
        return content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
    
    // MARK: - Transcriptions (STT)
    
    func transcribe(audio: AudioData, language: String?, model: String) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: "https://api.mistral.ai/v1/audio/transcriptions") else {
            throw MistralAPIError.invalidURL
        }

        func makeRequest(uploadFile: PluginAudioUploadFile) -> URLRequest {
            let boundary = UUID().uuidString
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120

            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(uploadFile.filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(uploadFile.contentType)\r\n\r\n".data(using: .utf8)!)
            body.append(uploadFile.data)
            body.append("\r\n".data(using: .utf8)!)

            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(model)\r\n".data(using: .utf8)!)

            if let language = language {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(language)\r\n".data(using: .utf8)!)
            }

            // Transcribe 3 leaves `language` null unless asked. Request it so an
            // unpinned recording still reports the detected language. A pinned
            // language remains the fallback when the response omits one.
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"return_language\"\r\n\r\n".data(using: .utf8)!)
            body.append("true\r\n".data(using: .utf8)!)

            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body
            return request
        }

        let preferredUpload = (try? PluginAudioUploadEncoder.compressedM4AUpload(from: audio))
            ?? PluginAudioUploadEncoder.wavUpload(from: audio)
        var (data, response) = try await PluginHTTPClient.data(for: makeRequest(uploadFile: preferredUpload))

        guard var httpResponse = response as? HTTPURLResponse else {
            throw MistralAPIError.invalidResponse
        }

        if preferredUpload.format != "wav",
           PluginAudioUploadEncoder.shouldRetryWithWavUpload(
            statusCode: httpResponse.statusCode,
            responseData: data
           ) {
            (data, response) = try await PluginHTTPClient.data(
                for: makeRequest(uploadFile: PluginAudioUploadEncoder.wavUpload(from: audio))
            )
            guard let retryResponse = response as? HTTPURLResponse else {
                throw MistralAPIError.invalidResponse
            }
            httpResponse = retryResponse
        }

        if httpResponse.statusCode == 200 {
            if let htmlPageSummary = PluginHTTPErrorBodyFormatter.htmlPageSummary(
                from: data,
                response: httpResponse
            ) {
                throw MistralAPIError.apiError(
                    "Failed to parse transcription response: \(htmlPageSummary)"
                )
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                throw MistralAPIError.apiError("Failed to parse transcription response")
            }
            // Prefer the language reported in the response. Transcribe 3 fills it
            // only when `return_language` is set and the request did not pin one,
            // so a pinned language stays the fallback.
            let detectedLanguage = (json["language"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? language
                ?? "en"
            return PluginTranscriptionResult(text: text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), detectedLanguage: detectedLanguage)
        } else {
            throw MistralAPIError.apiError(errorMessage(from: data, response: httpResponse))
        }
    }

    // MARK: - Validation
    
    func validate() async throws -> Bool {
        guard let url = URL(string: "https://api.mistral.ai/v1/models") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
            return false
        } catch {
            return false
        }
    }
    
    private func errorMessage(from data: Data, response: HTTPURLResponse) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            return PluginHTTPErrorBodyFormatter.summary(from: message)
        }
        let body = PluginHTTPErrorBodyFormatter.summary(from: data, response: response)
        return "HTTP \(response.statusCode): \(body)"
    }
}

struct MistralSettingsView: View {
    let plugin: MistralAIPlugin
    @State private var apiKeyInput: String = ""
    @State private var showApiKey: Bool = false
    @State private var isValidating: Bool = false
    @State private var validationResult: Bool?
    @State private var selectedSTTModel: String = ""
    @State private var selectedLLMModel: String = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    private let bundle = Bundle(for: MistralAIPlugin.self)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mistral AI", bundle: bundle)
                .font(.headline)
            Text("Cloud API integration for Mistral LLMs and Voxtral STT.", bundle: bundle)
                .font(.callout)
                .foregroundColor(.secondary)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                HStack {
                    if showApiKey {
                        TextField(String(localized: "e.g. LFztgP5WA...", bundle: bundle), text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(Text("API Key", bundle: bundle))
                    } else {
                        SecureField(String(localized: "e.g. LFztgP5WA...", bundle: bundle), text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(Text("API Key", bundle: bundle))
                    }
                    
                    Button(action: { showApiKey.toggle() }) {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showApiKey ? Text("Hide API key", bundle: bundle) : Text("Show API key", bundle: bundle))
                    
                    if !plugin.apiKey.isEmpty {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            validationResult = nil
                            isValidating = false
                            plugin.clearApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(Text("Remove API key", bundle: bundle))
                    }
                    
                    Button(String(localized: "Save", bundle: bundle)) {
                        validateAndSave()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
                    .accessibilityLabel(Text("Save API key", bundle: bundle))
                }
                
                if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating...", bundle: bundle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let result = validationResult {
                    HStack(spacing: 4) {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result ? .green : .red)
                            .accessibilityHidden(true)
                        Text(result ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle))
                            .font(.caption)
                            .foregroundColor(result ? .green : .red)
                    }
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription Model", bundle: bundle)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Picker(selection: $selectedSTTModel) {
                        Text("Default", bundle: bundle).tag("")
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    } label: {
                        Text("Transcription Model", bundle: bundle)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: selectedSTTModel) { _, newValue in
                        plugin.selectModel(newValue)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("LLM Model", bundle: bundle)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Picker(selection: $selectedLLMModel) {
                        Text("Default", bundle: bundle).tag("")
                        ForEach(plugin.supportedModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    } label: {
                        Text("LLM Model", bundle: bundle)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: selectedLLMModel) { _, newValue in
                        plugin.selectLLMModel(newValue)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature", bundle: bundle)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Picker(selection: $llmTemperatureMode) {
                        Text("Provider Default", bundle: bundle).tag(PluginLLMTemperatureMode.providerDefault)
                        Text("Custom", bundle: bundle).tag(PluginLLMTemperatureMode.custom)
                    } label: {
                        Text("Temperature Mode", bundle: bundle)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: llmTemperatureMode) { _, newValue in
                        plugin.setLLMTemperatureMode(newValue)
                    }

                    if llmTemperatureMode == .custom {
                        HStack {
                            Text("Applies to workflow (LLM) processing only.", bundle: bundle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(llmTemperatureValue, format: .number.precision(.fractionLength(2)))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }

                        Slider(value: $llmTemperatureValue, in: 0...2, step: 0.1)
                            .onChange(of: llmTemperatureValue) { _, newValue in
                                plugin.setLLMTemperatureValue(newValue)
                            }
                            .accessibilityLabel(Text("Temperature", bundle: bundle))
                    }
                }
            }
        }
        .padding()
        .onAppear {
            apiKeyInput = plugin.apiKey
            selectedSTTModel = plugin.selectedModelId ?? ""
            selectedLLMModel = plugin.selectedLLMModelId ?? ""
            llmTemperatureMode = plugin.llmTemperatureMode
            llmTemperatureValue = plugin.llmTemperatureValue
        }
    }
    
    private func validateAndSave() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        isValidating = true
        validationResult = nil
        
        Task {
            let client = MistralAPIClient(apiKey: trimmed)
            let isValid = (try? await client.validate()) ?? false
            await MainActor.run {
                isValidating = false
                validationResult = isValid
                if isValid {
                    plugin.setApiKey(trimmed)
                }
            }
        }
    }
}
