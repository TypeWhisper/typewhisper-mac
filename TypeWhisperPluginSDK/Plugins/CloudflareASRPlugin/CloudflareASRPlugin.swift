import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(CloudflareASRPlugin)
final class CloudflareASRPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.cloudflare-asr"
    static let pluginName = "Cloudflare ASR"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _baseURL: String?
    fileprivate var _cfClientId: String?
    fileprivate var _cfClientSecret: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _fetchedModels: [CFetchedModel] = []

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _cfClientId = host.loadSecret(key: "cf-client-id")
        _cfClientSecret = host.loadSecret(key: "cf-client-secret")
        _baseURL = host.userDefault(forKey: "baseURL") as? String
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String

        if let data = host.userDefault(forKey: "fetchedModels") as? Data {
            _fetchedModels = (try? JSONDecoder().decode([CFetchedModel].self, from: data)) ?? []
        }
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "cloudflare-asr" }
    var providerDisplayName: String { "Cloudflare ASR" }

    var isConfigured: Bool {
        guard let baseURL = _baseURL, !baseURL.isEmpty else { return false }
        let hasCFAuth = _cfClientId != nil && _cfClientSecret != nil
            && !(_cfClientId?.isEmpty ?? true) && !(_cfClientSecret?.isEmpty ?? true)
        return hasCFAuth
    }

    var transcriptionModels: [PluginModelInfo] {
        let models = _fetchedModels.map { PluginModelInfo(id: $0.id, displayName: $0.id) }
        if models.isEmpty, let selectedId = _selectedModelId, !selectedId.isEmpty {
            return [PluginModelInfo(id: selectedId, displayName: selectedId)]
        }
        return models
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }

    var supportedLanguages: [String] {
        [
            "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
            "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
            "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
            "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
            "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
            "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
            "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
            "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
            "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
            "tr", "tt", "uk", "ur", "uz", "vi", "vo", "yi", "yo", "yue",
            "zh",
        ]
    }

    // MARK: - Transcription (Custom HTTP with CF Headers)

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let baseURL = _baseURL, !baseURL.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId, !modelId.isEmpty else {
            throw PluginTranscriptionError.noModelSelected
        }

        let endpoint = translate
            ? "\(baseURL)/v1/audio/translations"
            : "\(baseURL)/v1/audio/transcriptions"

        guard let url = URL(string: endpoint) else {
            throw PluginTranscriptionError.apiError("Invalid URL: \(endpoint)")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // Cloudflare tunnel service token headers
        if let cfId = _cfClientId, !cfId.isEmpty,
           let cfSecret = _cfClientSecret, !cfSecret.isEmpty {
            request.setValue(cfId, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(cfSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }

        // Optional Bearer token for the upstream API
        if let apiKey = _apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Multipart form body
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio.wavData)
        body.append("\r\n".data(using: .utf8)!)

        body.cfAppendFormField(boundary: boundary, name: "model", value: modelId)
        body.cfAppendFormField(boundary: boundary, name: "response_format", value: "json")

        if !translate, let language, !language.isEmpty {
            body.cfAppendFormField(boundary: boundary, name: "language", value: language)
        }

        if let prompt, !prompt.isEmpty {
            body.cfAppendFormField(boundary: boundary, name: "prompt", value: prompt)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 403:
            throw PluginTranscriptionError.apiError("Cloudflare access denied (403). Check your CF service token credentials.")
        case 429:
            throw PluginTranscriptionError.rateLimited
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        default:
            let errorMessage = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        return try Self.parseTranscriptionResponse(responseData)
    }

    private static func parseTranscriptionResponse(_ data: Data) throws -> PluginTranscriptionResult {
        struct APISegment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }
        struct APIResponse: Decodable {
            let text: String
            let language: String?
            let segments: [APISegment]?
        }

        do {
            let response = try JSONDecoder().decode(APIResponse.self, from: data)
            let (lang, text) = parseASROutput(response.text)
            let detectedLang = lang.isEmpty ? response.language : lang
            let segments = (response.segments ?? []).map {
                let (_, segText) = parseASROutput($0.text)
                return PluginTranscriptionSegment(text: segText, start: $0.start, end: $0.end)
            }
            return PluginTranscriptionResult(text: text, detectedLanguage: detectedLang, segments: segments)
        } catch {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawText = json["text"] as? String {
                let (lang, text) = parseASROutput(rawText)
                let detectedLang = lang.isEmpty ? json["language"] as? String : lang
                return PluginTranscriptionResult(text: text, detectedLanguage: detectedLang)
            }
            throw PluginTranscriptionError.apiError("Failed to parse response: \(error.localizedDescription)")
        }
    }

    /// Parse Qwen3-ASR raw output `"language <LANG><asr_text><TEXT>"` into (language, text).
    /// Mirrors the reference `parse_asr_output` from the qwen_asr Python package.
    private static func parseASROutput(_ raw: String) -> (language: String, text: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return ("", "") }

        let asrTag = "<asr_text>"
        guard let tagRange = s.range(of: asrTag) else {
            return ("", s)
        }

        let metaPart = String(s[s.startIndex..<tagRange.lowerBound])
        let textPart = String(s[tagRange.upperBound...])
            .replacingOccurrences(of: #"language\s+\w+<asr_text>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "</asr_text>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if metaPart.lowercased().contains("language none") {
            return ("", textPart)
        }

        let langPrefix = "language "
        var lang = ""
        for line in metaPart.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix(langPrefix) {
                let val = String(trimmed.dropFirst(langPrefix.count)).trimmingCharacters(in: .whitespaces)
                if !val.isEmpty {
                    lang = val.prefix(1).uppercased() + val.dropFirst().lowercased()
                    break
                }
            }
        }

        return (lang, textPart)
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(CloudflareASRSettingsView(plugin: self))
    }

    // MARK: - Internal Methods

    fileprivate func setBaseURL(_ url: String) {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        if normalized.hasSuffix("/v1") {
            normalized = String(normalized.dropLast(3))
        }
        _baseURL = normalized
        host?.setUserDefault(normalized, forKey: "baseURL")
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key.isEmpty ? nil : key
        if let host {
            try? host.storeSecret(key: "api-key", value: key)
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func setCFClientId(_ value: String) {
        _cfClientId = value.isEmpty ? nil : value
        if let host {
            try? host.storeSecret(key: "cf-client-id", value: value)
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func setCFClientSecret(_ value: String) {
        _cfClientSecret = value.isEmpty ? nil : value
        if let host {
            try? host.storeSecret(key: "cf-client-secret", value: value)
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func setFetchedModels(_ models: [CFetchedModel]) {
        _fetchedModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: "fetchedModels")
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func fetchModels() async -> [CFetchedModel] {
        guard let baseURL = _baseURL, !baseURL.isEmpty,
              let url = URL(string: "\(baseURL)/v1/models") else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        addAuthHeaders(to: &request)

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }

            struct ModelsResponse: Decodable {
                let data: [CFetchedModel]
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data.sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }

    fileprivate func validateConnection() async -> Bool {
        guard let baseURL = _baseURL, !baseURL.isEmpty,
              let url = URL(string: "\(baseURL)/v1/models") else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        addAuthHeaders(to: &request)

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    private func addAuthHeaders(to request: inout URLRequest) {
        if let cfId = _cfClientId, !cfId.isEmpty,
           let cfSecret = _cfClientSecret, !cfSecret.isEmpty {
            request.setValue(cfId, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(cfSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        if let apiKey = _apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }
}

// MARK: - Fetched Model

struct CFetchedModel: Codable, Sendable {
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

// MARK: - Multipart Helper

private extension Data {
    mutating func cfAppendFormField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}

// MARK: - Settings View

private struct CloudflareASRSettingsView: View {
    let plugin: CloudflareASRPlugin
    @State private var baseURLInput = ""
    @State private var apiKeyInput = ""
    @State private var cfClientIdInput = ""
    @State private var cfClientSecretInput = ""
    @State private var showApiKey = false
    @State private var showCFSecret = false
    @State private var isTesting = false
    @State private var connectionResult: Bool?
    @State private var selectedModel = ""
    @State private var manualModel = ""
    @State private var fetchedModels: [CFetchedModel] = []

    private var hasModels: Bool { !fetchedModels.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Server URL
            VStack(alignment: .leading, spacing: 8) {
                Text("Server URL")
                    .font(.headline)

                TextField("e.g. https://asr.example.com", text: $baseURLInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            // Cloudflare Tunnel Auth
            VStack(alignment: .leading, spacing: 8) {
                Text("Cloudflare Tunnel Auth")
                    .font(.headline)

                TextField("CF-Access-Client-Id", text: $cfClientIdInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                HStack(spacing: 8) {
                    if showCFSecret {
                        TextField("CF-Access-Client-Secret", text: $cfClientSecretInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("CF-Access-Client-Secret", text: $cfClientSecretInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showCFSecret.toggle()
                    } label: {
                        Image(systemName: showCFSecret ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text("Service token credentials for Cloudflare Access. Stored in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // API Key (optional)
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
                }

                Text("Optional Bearer token for the upstream API behind the tunnel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                          || cfClientIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || cfClientSecretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || isTesting)

                if isTesting {
                    ProgressView().controlSize(.small)
                    Text("Testing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let result = connectionResult {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result ? .green : .red)
                    Text(result ? "Connected" : "Connection Failed")
                        .font(.caption)
                        .foregroundStyle(result ? .green : .red)
                }
            }

            if plugin.isConfigured {
                Divider()

                // Model Selection
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Model")
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

                    if hasModels {
                        Picker("Transcription Model", selection: $selectedModel) {
                            Text("None").tag("")
                            ForEach(fetchedModels, id: \.id) { model in
                                Text(model.id).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selectedModel) {
                            plugin.selectModel(selectedModel)
                        }
                    } else {
                        Text("No models found. Enter model name manually.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            TextField("Model name", text: $manualModel)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit { saveManualModel() }

                            Button("Save") { saveManualModel() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(manualModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }

            Text("All credentials are stored securely in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            baseURLInput = plugin._baseURL ?? ""
            apiKeyInput = plugin._apiKey ?? ""
            cfClientIdInput = plugin._cfClientId ?? ""
            cfClientSecretInput = plugin._cfClientSecret ?? ""
            fetchedModels = plugin._fetchedModels
            selectedModel = plugin.selectedModelId ?? ""
            manualModel = plugin.selectedModelId ?? ""
        }
    }

    private func saveManualModel() {
        let trimmed = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            plugin.selectModel(trimmed)
        }
    }

    private func testConnection() {
        plugin.setBaseURL(baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines))
        plugin.setCFClientId(cfClientIdInput.trimmingCharacters(in: .whitespacesAndNewlines))
        plugin.setCFClientSecret(cfClientSecretInput.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            plugin.setApiKey(trimmedKey)
        }

        isTesting = true
        connectionResult = nil
        Task {
            let models = await plugin.fetchModels()
            var isConnected = !models.isEmpty
            if !isConnected {
                isConnected = await plugin.validateConnection()
            }
            await MainActor.run {
                isTesting = false
                connectionResult = isConnected
                if isConnected {
                    fetchedModels = models
                    plugin.setFetchedModels(models)
                    if selectedModel.isEmpty, let first = models.first {
                        selectedModel = first.id
                        plugin.selectModel(first.id)
                    }
                }
            }
        }
    }

    private func refreshModels() {
        Task {
            let models = await plugin.fetchModels()
            await MainActor.run {
                fetchedModels = models
                plugin.setFetchedModels(models)
            }
        }
    }
}
