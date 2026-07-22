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
        lock.withLock {
            self._host = host
            self._selectedLLMModelId = host.userDefault(forKey: "selectedLLMModel") as? String
            self._selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            self._llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
                ?? PluginLLMTemperatureMode.providerDefault.rawValue
            self._llmTemperatureValue = host.userDefault(forKey: "llmTemperatureValue") as? Double ?? 0.3
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
        return [
            PluginModelInfo(id: "voxtral-mini-latest", displayName: "Voxtral Mini Latest"),
            PluginModelInfo(id: "voxtral-small-latest", displayName: "Voxtral Small (24B)")
        ]
    }

    /// Models that transcribe through the chat/completions endpoint (audio input)
    /// rather than the dedicated /audio/transcriptions endpoint, which only serves
    /// `voxtral-mini-latest`.
    static let chatTranscriptionModelIds: Set<String> = ["voxtral-small-latest"]
    
    private var _selectedModelId: String?
    public var selectedModelId: String? { lock.withLock { _selectedModelId } }
    
    public func selectModel(_ modelId: String) {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueToSave = normalized.isEmpty ? nil : normalized
        lock.withLock {
            _selectedModelId = valueToSave
        }
        host?.setUserDefault(valueToSave, forKey: "selectedModel")
        host?.notifyCapabilitiesChanged()
    }
    
    public var supportsTranslation: Bool { false }
    public var supportsStreaming: Bool { false } // Note: We declare false here because Mistral's basic API doesn't support WebSocket streaming chunk-by-chunk in a public STT endpoint yet. The TypeWhisper app will just use transcribe(audio:...) normally.
    public var supportedLanguages: [String] { [] }
    
    public func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        let client = MistralAPIClient(apiKey: apiKey)
        let sttModelId = lock.withLock { _selectedModelId }
        let sttModel = (sttModelId?.isEmpty == false) ? sttModelId! : "voxtral-mini-latest"
        if Self.chatTranscriptionModelIds.contains(sttModel) {
            return try await client.transcribeViaChat(audio: audio, language: language, model: sttModel)
        }
        return try await client.transcribe(audio: audio, language: language, model: sttModel)
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
            return try parseChatResponse(data)
        } else {
            throw MistralAPIError.apiError(errorMessage(from: data, statusCode: httpResponse.statusCode))
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
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                throw MistralAPIError.apiError("Failed to parse transcription response")
            }
            // The endpoint doubles as a language-detection service, so prefer the
            // language reported in the response over the (optional) requested one.
            let detectedLanguage = (json["language"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? language
                ?? "en"
            return PluginTranscriptionResult(text: text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), detectedLanguage: detectedLanguage)
        } else {
            throw MistralAPIError.apiError(errorMessage(from: data, statusCode: httpResponse.statusCode))
        }
    }

    // MARK: - Transcription via Chat (audio-input LLM, e.g. Voxtral Small)

    /// Transcribes by sending base64 audio to /v1/chat/completions. Used for
    /// audio-capable chat models like Voxtral Small that the dedicated
    /// transcription endpoint does not serve. The endpoint only accepts mp3/wav
    /// audio, so we always upload WAV.
    func transcribeViaChat(audio: AudioData, language: String?, model: String) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: "https://api.mistral.ai/v1/chat/completions") else {
            throw MistralAPIError.invalidURL
        }

        let wav = PluginAudioUploadEncoder.wavUpload(from: PluginAudioUploadEncoder.normalizedAudioForUpload(audio))
        let audioBase64 = wav.data.base64EncodedString()

        var instruction = "Transcribe this audio verbatim. Output only the transcription text, with no additional commentary, labels, or quotation marks."
        if let language, !language.isEmpty {
            instruction += " The spoken language is \(language)."
        }

        let body: [String: Any] = [
            "model": model,
            // Transcription must be deterministic, independent of the LLM
            // workflow temperature setting.
            "temperature": 0.0,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_audio", "input_audio": audioBase64],
                        ["type": "text", "text": instruction]
                    ]
                ]
            ]
        ]

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
            let text = try parseChatResponse(data)
            // Chat completions returns no structured detected-language field, so
            // fall back to the requested language (or English).
            return PluginTranscriptionResult(text: text, detectedLanguage: language ?? "en")
        } else {
            throw MistralAPIError.apiError(errorMessage(from: data, statusCode: httpResponse.statusCode))
        }
    }

    // MARK: - Validation
    
    func validate() async throws -> Bool {
        guard let url = URL(string: "https://api.mistral.ai/v1/models") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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
    
    private func errorMessage(from data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            return message
        }
        if let body = String(data: data, encoding: .utf8), !body.isEmpty {
            return "HTTP \(statusCode): \(body)"
        }
        return "HTTP \(statusCode)"
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
                    } else {
                        SecureField(String(localized: "e.g. LFztgP5WA...", bundle: bundle), text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    Button(action: { showApiKey.toggle() }) {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    
                    if !plugin.apiKey.isEmpty {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            validationResult = nil
                            isValidating = false
                            plugin.clearApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    Button(String(localized: "Save", bundle: bundle)) {
                        validateAndSave()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
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
                    
                    Picker("Transcription Model", selection: $selectedSTTModel) {
                        Text("None", bundle: bundle).tag("")
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
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

                    Picker("LLM Model", selection: $selectedLLMModel) {
                        Text("None", bundle: bundle).tag("")
                        ForEach(plugin.supportedModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
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

                    Picker("Temperature Mode", selection: $llmTemperatureMode) {
                        Text("Provider Default", bundle: bundle).tag(PluginLLMTemperatureMode.providerDefault)
                        Text("Custom", bundle: bundle).tag(PluginLLMTemperatureMode.custom)
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
