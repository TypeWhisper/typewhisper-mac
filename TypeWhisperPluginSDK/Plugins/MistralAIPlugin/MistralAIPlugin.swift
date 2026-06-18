import Foundation
import TypeWhisperPluginSDK
import SwiftUI

@objc(MistralAIPlugin)
public final class MistralAIPlugin: NSObject, LLMProviderPlugin, LLMProviderIdentityProviding, LLMModelSelectable, TranscriptionEnginePlugin, @unchecked Sendable {
    
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
        let llmModelId = lock.withLock { _selectedLLMModelId }
        let selectedModel = model ?? ((llmModelId?.isEmpty == false) ? llmModelId! : "mistral-small-latest")
        let client = MistralAPIClient(apiKey: apiKey)
        return try await client.processChat(systemPrompt: systemPrompt, userText: userText, model: selectedModel)
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
            PluginModelInfo(id: "voxtral-mini-latest", displayName: "Voxtral Mini Latest")
        ]
    }
    
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
    
    func processChat(systemPrompt: String, userText: String, model: String) async throws -> String {
        guard let url = URL(string: "https://api.mistral.ai/v1/chat/completions") else {
            throw MistralAPIError.invalidURL
        }
        
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
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
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        let filename = "audio.wav"
        let mimeType = "audio/wav"
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(audio.wavData)
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
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MistralAPIError.invalidResponse
        }
        
        if httpResponse.statusCode == 200 {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                throw MistralAPIError.apiError("Failed to parse transcription response")
            }
            return PluginTranscriptionResult(text: text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), detectedLanguage: language ?? "en")
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
            let (_, response) = try await URLSession.shared.data(for: request)
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mistral AI")
                .font(.headline)
            Text("Cloud API integration for Mistral LLMs and Voxtral STT.")
                .font(.callout)
                .foregroundColor(.secondary)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                HStack {
                    if showApiKey {
                        TextField("e.g. LFztgP5WA...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("e.g. LFztgP5WA...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    Button(action: { showApiKey.toggle() }) {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    
                    if !plugin.apiKey.isEmpty {
                        Button("Remove") {
                            apiKeyInput = ""
                            validationResult = nil
                            isValidating = false
                            plugin.clearApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    Button("Save") {
                        validateAndSave()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
                }
                
                if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let result = validationResult {
                    HStack(spacing: 4) {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result ? .green : .red)
                        Text(result ? "Valid API Key" : "Invalid API Key")
                            .font(.caption)
                            .foregroundColor(result ? .green : .red)
                    }
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription Model")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Picker("", selection: $selectedSTTModel) {
                        Text("Select a Model").tag("")
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
                    Text("LLM Model")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Picker("", selection: $selectedLLMModel) {
                        Text("Select a Model").tag("")
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
            }
        }
        .padding()
        .onAppear {
            apiKeyInput = plugin.apiKey
            selectedSTTModel = plugin.selectedModelId ?? ""
            selectedLLMModel = plugin.selectedLLMModelId ?? ""
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
