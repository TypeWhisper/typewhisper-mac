import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

@objc(SmallestAIPlugin)
final class SmallestAIPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.smallest-pulse"
    static let pluginName = "Smallest Pulse"

    private static let endpoint = "https://api.smallest.ai/waves/v1/pulse/get_text"
    private static let defaultLanguageMode = "multi-eu"
    private static let validationWAV = makeSilentWAV(duration: 0.25)

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?

    private let logger = Logger(subsystem: "com.typewhisper.smallest-pulse", category: "Plugin")

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? Self.defaultLanguageMode
    }

    func deactivate() {
        host = nil
    }

    var providerId: String { "smallest-pulse" }
    var providerDisplayName: String { "Smallest Pulse" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "multi-eu", displayName: "Auto (European)"),
            PluginModelInfo(id: "multi", displayName: "Auto (Multilingual)"),
            PluginModelInfo(id: "multi-indic", displayName: "Auto (Indic)"),
            PluginModelInfo(id: "multi-asian", displayName: "Auto (Asian)"),
        ]
    }

    var selectedModelId: String? { _selectedModelId ?? Self.defaultLanguageMode }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { false }

    var supportedLanguages: [String] {
        [
            "en", "it", "es", "pt", "hi", "de", "fr", "uk", "ru", "kn",
            "ml", "pl", "mr", "gu", "cs", "sk", "te", "or", "nl", "bn",
            "lv", "et", "ro", "pa", "fi", "sv", "bg", "ta", "hu", "da",
            "lt", "mt", "ja", "yue", "zh", "ko", "tl", "id", "ms",
        ]
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard !translate else {
            throw PluginTranscriptionError.apiError("Smallest Pulse does not support translation.")
        }
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }

        let request = try Self.makePreRecordedRequest(
            wavData: audio.wavData,
            apiKey: apiKey,
            requestedLanguage: language,
            selectedLanguageMode: selectedModelId
        )

        let (data, response) = try await PluginHTTPClient.data(for: request)
        try Self.validateHTTPResponse(data: data, response: response)
        return try Self.parsePreRecordedResponse(data)
    }

    var settingsView: AnyView? {
        AnyView(SmallestAISettingsView(plugin: self))
    }

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                logger.error("Failed to store API key: \(error.localizedDescription)")
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
                logger.error("Failed to delete API key: \(error.localizedDescription)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func validateApiKey(_ key: String) async -> Bool {
        do {
            let request = try Self.makePreRecordedRequest(
                wavData: Self.validationWAV,
                apiKey: key,
                requestedLanguage: "en",
                selectedLanguageMode: Self.defaultLanguageMode
            )
            let (data, response) = try await PluginHTTPClient.data(for: request)
            try Self.validateHTTPResponse(data: data, response: response)
            return true
        } catch {
            return false
        }
    }
}

extension SmallestAIPlugin {
    static func makePreRecordedRequest(
        wavData: Data,
        apiKey: String,
        requestedLanguage: String?,
        selectedLanguageMode: String?
    ) throws -> URLRequest {
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(
                name: "language",
                value: resolvedLanguageParameter(
                    requestedLanguage: requestedLanguage,
                    selectedLanguageMode: selectedLanguageMode
                )
            ),
            URLQueryItem(name: "word_timestamps", value: "true"),
        ]

        guard let url = components?.url else {
            throw PluginTranscriptionError.apiError("Invalid Smallest Pulse URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wavData
        request.timeoutInterval = 120
        return request
    }

    static func parsePreRecordedResponse(_ data: Data) throws -> PluginTranscriptionResult {
        let response: PreRecordedResponse
        do {
            response = try JSONDecoder().decode(PreRecordedResponse.self, from: data)
        } catch {
            throw PluginTranscriptionError.apiError("Failed to parse Smallest Pulse response: \(error.localizedDescription)")
        }

        if let status = response.status, status.lowercased() != "success" {
            throw PluginTranscriptionError.apiError(
                response.errorMessage ?? "Smallest Pulse transcription failed with status \(status)"
            )
        }

        let text = response.transcription ?? response.text
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginTranscriptionError.apiError("Smallest Pulse response did not include a transcription")
        }

        return PluginTranscriptionResult(
            text: text,
            detectedLanguage: response.language,
            segments: response.utterances?.map {
                PluginTranscriptionSegment(text: $0.text, start: $0.start, end: $0.end)
            } ?? []
        )
    }

    static func resolvedLanguageParameter(
        requestedLanguage: String?,
        selectedLanguageMode: String?
    ) -> String {
        let requested = requestedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested, !requested.isEmpty {
            return requested
        }

        let selected = selectedLanguageMode?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selected, !selected.isEmpty {
            return selected
        }

        return defaultLanguageMode
    }

    static func validateHTTPResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            return
        case 401, 403:
            throw PluginTranscriptionError.invalidApiKey
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    struct PreRecordedResponse: Decodable {
        let status: String?
        let transcription: String?
        let text: String?
        let language: String?
        let utterances: [Utterance]?
        let error: String?
        let message: String?
        let detail: String?

        var errorMessage: String? {
            error ?? message ?? detail
        }
    }

    struct Utterance: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    private static func makeSilentWAV(duration: TimeInterval, sampleRate: Int = 16_000) -> Data {
        let sampleCount = max(1, Int(duration * Double(sampleRate)))
        let byteRate = sampleRate * 2
        let dataSize = sampleCount * 2
        let fileSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendUInt32LE(UInt32(fileSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(1)
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(UInt32(byteRate))
        data.appendUInt16LE(2)
        data.appendUInt16LE(16)
        data.append(contentsOf: "data".utf8)
        data.appendUInt32LE(UInt32(dataSize))
        data.append(Data(repeating: 0, count: dataSize))
        return data
    }
}

private struct SmallestAISettingsView: View {
    let plugin: SmallestAIPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel = ""
    private let bundle = Bundle(for: SmallestAIPlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                        Text(
                            result
                                ? String(localized: "Valid API Key", bundle: bundle)
                                : String(localized: "Invalid API Key", bundle: bundle)
                        )
                        .font(.caption)
                        .foregroundStyle(result ? .green : .red)
                    }
                }
            }

            if plugin.isConfigured {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Language Mode", bundle: bundle)
                        .font(.headline)

                    Picker("Language Mode", selection: $selectedModel) {
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectModel(selectedModel)
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
            selectedModel = plugin.selectedModelId ?? plugin.transcriptionModels.first?.id ?? ""
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

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
