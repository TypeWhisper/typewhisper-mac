import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Supported Languages

private let cohereSupportedLanguages = [
    "ar", "bn", "de", "en", "es", "fr", "hi", "ja", "ko", "pt",
    "ru", "sw", "tr", "zh",
]

// MARK: - Plugin Entry Point

@objc(CoherePlugin)
final class CoherePlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.cohere"
    static let pluginName = "Cohere"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "cohere" }
    var providerDisplayName: String { "Cohere" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "cohere-transcribe-03-2026", displayName: "Cohere Transcribe"),
        ]
    }

    var selectedModelId: String? { transcriptionModels.first?.id }

    func selectModel(_ modelId: String) {
        // Single model, nothing to change
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { false }

    var supportedLanguages: [String] { cohereSupportedLanguages }

    // MARK: - Transcription

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }

        let model = "cohere-transcribe-03-2026"
        let lang = language ?? "en"

        guard let url = URL(string: "https://api.cohere.com/v2/audio/transcriptions") else {
            throw PluginTranscriptionError.apiError("Invalid Cohere API URL")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        // Build multipart form body
        var body = Data()

        // model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // language field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(lang)\r\n".data(using: .utf8)!)

        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio.wavData)
        body.append("\r\n".data(using: .utf8)!)

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
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let text = json["text"] as? String else {
            throw PluginTranscriptionError.apiError("Failed to parse Cohere response")
        }

        return PluginTranscriptionResult(text: text, detectedLanguage: lang)
    }

    // MARK: - API Key Validation

    fileprivate func validateApiKey(_ key: String) async -> Bool {
        guard let url = URL(string: "https://api.cohere.com/v2/models") else { return false }
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

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(CohereSettingsView(plugin: self))
    }

    // MARK: - Internal Methods for Settings

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[CoherePlugin] Failed to store API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func removeApiKey() {
        _apiKey = nil
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: "")
            } catch {
                print("[CoherePlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }
}

// MARK: - Settings View

private struct CohereSettingsView: View {
    let plugin: CoherePlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    private let bundle = Bundle(for: CoherePlugin.self)

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

                    if plugin.isConfigured {
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

            if plugin.isConfigured {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Model", bundle: bundle)
                        .font(.headline)
                    Text("Cohere Transcribe (cohere-transcribe-03-2026)")
                        .font(.body)
                        .foregroundStyle(.secondary)
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
            await MainActor.run {
                isValidating = false
                validationResult = isValid
            }
        }
    }
}
