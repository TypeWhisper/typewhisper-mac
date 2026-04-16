import Foundation
import SwiftUI
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(GranitePlugin)
final class GranitePlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, PluginSettingsActivityReporting, @unchecked Sendable {
    static let pluginId = "com.typewhisper.granite"
    static let pluginName = "Granite Speech"

    fileprivate var host: HostServices?
    fileprivate var _selectedModelId: String?
    fileprivate var model: GraniteSpeechModel?
    fileprivate var loadedModelId: String?
    fileprivate var _hfToken: String?

    fileprivate var modelState: GraniteModelState = .notLoaded

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? Self.availableModels.first?.id
        _hfToken = host.loadSecret(key: "hf-token")

        Task { await restoreLoadedModel() }
    }

    func deactivate() {
        model = nil
        loadedModelId = nil
        modelState = .notLoaded
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "granite" }
    var providerDisplayName: String { "Granite Speech (MLX)" }

    var isConfigured: Bool {
        model != nil && loadedModelId != nil
    }

    var transcriptionModels: [PluginModelInfo] {
        guard let loadedModelId else { return [] }
        return Self.availableModels
            .filter { $0.id == loadedModelId }
            .map { PluginModelInfo(id: $0.id, displayName: $0.displayName) }
    }

    var availableModels: [PluginModelInfo] {
        Self.availableModels.map { def in
            PluginModelInfo(
                id: def.id,
                displayName: def.displayName,
                sizeDescription: def.sizeDescription,
                loaded: def.id == loadedModelId
            )
        }
    }

    var supportedLanguages: [String] {
        ["en", "fr", "de", "es", "pt", "ja"]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { true }
    var supportsStreaming: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let model else {
            throw PluginTranscriptionError.notConfigured
        }

        let audioArray = MLXArray(audio.samples)
        let resolvedPrompt = Self.resolvePrompt(translate: translate, language: language, prompt: prompt)
        let output = model.generate(
            audio: audioArray,
            maxTokens: 4096,
            temperature: 0.0,
            prompt: resolvedPrompt,
            language: translate ? (language ?? "en") : nil
        )
        let text = Self.normalizeTranscript(output.text)

        return PluginTranscriptionResult(text: text, detectedLanguage: language)
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let model else {
            throw PluginTranscriptionError.notConfigured
        }

        let audioArray = MLXArray(audio.samples)
        let resolvedPrompt = Self.resolvePrompt(translate: translate, language: language, prompt: prompt)
        let stream = model.generateStream(
            audio: audioArray,
            maxTokens: 4096,
            temperature: 0.0,
            prompt: resolvedPrompt,
            language: translate ? (language ?? "en") : nil
        )

        var accumulated = ""
        for try await generation in stream {
            switch generation {
            case .token(let token):
                accumulated += token
                let shouldContinue = onProgress(Self.normalizeTranscript(accumulated))
                if !shouldContinue { break }
            case .info:
                break
            case .result(let output):
                accumulated = output.text
            }
        }

        let text = Self.normalizeTranscript(accumulated)
        return PluginTranscriptionResult(text: text, detectedLanguage: language)
    }

    // MARK: - Model Management

    fileprivate func loadModel(_ modelDef: GraniteModelDef) async throws {
        modelState = .loading
        do {
            let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models")
                ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

            let cache = HubCache(cacheDirectory: modelsDir)
            if let token = _hfToken, !token.isEmpty {
                setenv("HF_TOKEN", token, 1)
            }
            let loaded = try await GraniteSpeechModel.fromPretrained(modelDef.repoId, cache: cache)

            model = loaded
            loadedModelId = modelDef.id
            _selectedModelId = modelDef.id
            host?.setUserDefault(modelDef.id, forKey: "selectedModel")
            host?.setUserDefault(modelDef.id, forKey: "loadedModel")
            modelState = .ready(modelDef.id)
            host?.notifyCapabilitiesChanged()
        } catch {
            modelState = .error("\(error)")
            throw error
        }
    }

    @objc func triggerAutoUnload() { unloadModel(clearPersistence: false) }
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel() } }

    func unloadModel(clearPersistence: Bool = true) {
        model = nil
        loadedModelId = nil
        modelState = .notLoaded
        if clearPersistence {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func deleteModelFiles(_ modelDef: GraniteModelDef) {
        guard let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models") else { return }
        let subdirectory = modelDef.repoId.replacingOccurrences(of: "/", with: "_")
        let modelDir = modelsDir
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(subdirectory)
        try? FileManager.default.removeItem(at: modelDir)
    }

    func restoreLoadedModel() async {
        guard let savedId = host?.userDefault(forKey: "loadedModel") as? String,
              let modelDef = Self.availableModels.first(where: { $0.id == savedId }) else {
            return
        }
        try? await loadModel(modelDef)
    }

    // MARK: - Settings View

    var currentSettingsActivity: PluginSettingsActivity? {
        switch modelState {
        case .notLoaded, .ready:
            return nil
        case .loading:
            return PluginSettingsActivity(message: "Preparing model")
        case .error(let message):
            return PluginSettingsActivity(message: message, isError: true)
        }
    }

    var settingsView: AnyView? {
        AnyView(GraniteSettingsView(plugin: self))
    }

    // MARK: - Model Definitions

    static let availableModels: [GraniteModelDef] = [
        GraniteModelDef(
            id: "granite-1b-speech-4bit",
            displayName: "Granite 1B (4-bit)",
            repoId: "mlx-community/granite-4.0-1b-speech-4bit",
            sizeDescription: "~2 GB",
            ramRequirement: "8 GB+"
        ),
        GraniteModelDef(
            id: "granite-1b-speech-5bit",
            displayName: "Granite 1B (5-bit)",
            repoId: "mlx-community/granite-4.0-1b-speech-5bit",
            sizeDescription: "~2.2 GB",
            ramRequirement: "8 GB+"
        ),
        GraniteModelDef(
            id: "granite-1b-speech-8bit",
            displayName: "Granite 1B (8-bit)",
            repoId: "mlx-community/granite-4.0-1b-speech-8bit",
            sizeDescription: "~2.9 GB",
            ramRequirement: "16 GB+"
        ),
    ]

    // MARK: - Helpers

    /// Resolve the prompt for Granite. When translate=true, language is passed separately
    /// so prompt is only used for keyword biasing. For transcription, a custom prompt
    /// overrides the default; otherwise nil lets the model use its built-in prompt.
    private static func resolvePrompt(translate: Bool, language: String?, prompt: String?) -> String? {
        if let prompt, !prompt.isEmpty { return prompt }
        if translate { return nil }
        return nil
    }

    fileprivate static func normalizeTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Model Types

struct GraniteModelDef: Identifiable {
    let id: String
    let displayName: String
    let repoId: String
    let sizeDescription: String
    let ramRequirement: String
}

enum GraniteModelState: Equatable {
    case notLoaded
    case loading
    case ready(String)
    case error(String)

    static func == (lhs: GraniteModelState, rhs: GraniteModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded): true
        case (.loading, .loading): true
        case let (.ready(a), .ready(b)): a == b
        case let (.error(a), .error(b)): a == b
        default: false
        }
    }
}

// MARK: - Settings View

private struct GraniteSettingsView: View {
    let plugin: GranitePlugin
    private let bundle = Bundle(for: GranitePlugin.self)
    @State private var modelState: GraniteModelState = .notLoaded
    @State private var selectedModelId: String = ""
    @State private var isPolling = false
    @State private var hfTokenInput = ""
    @State private var showHfToken = false

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Granite Speech (MLX)")
                .font(.headline)

            Text("Local speech-to-text and translation by IBM, powered by MLX on Apple Silicon. 6 languages with bidirectional translation.", bundle: bundle)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            // HuggingFace Token
            VStack(alignment: .leading, spacing: 8) {
                Text("HuggingFace Token", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Optional. Increases download rate limits. Free at huggingface.co/settings/tokens", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if showHfToken {
                        TextField("hf_...", text: $hfTokenInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("hf_...", text: $hfTokenInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showHfToken.toggle()
                    } label: {
                        Image(systemName: showHfToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    if plugin._hfToken != nil, !plugin._hfToken!.isEmpty {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            hfTokenInput = ""
                            plugin._hfToken = nil
                            try? plugin.host?.storeSecret(key: "hf-token", value: "")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button(String(localized: "Save", bundle: bundle)) {
                        let trimmed = hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        plugin._hfToken = trimmed
                        try? plugin.host?.storeSecret(key: "hf-token", value: trimmed)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Model", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                ForEach(GranitePlugin.availableModels) { modelDef in
                    modelRow(modelDef)
                }
            }

            if case .error(let message) = modelState {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .onAppear {
            modelState = plugin.modelState
            selectedModelId = plugin.selectedModelId ?? GranitePlugin.availableModels.first?.id ?? ""
            if let token = plugin._hfToken, !token.isEmpty {
                hfTokenInput = token
            }
        }
        .task {
            if case .notLoaded = plugin.modelState {
                isPolling = true
                await plugin.restoreLoadedModel()
                isPolling = false
                modelState = plugin.modelState
            }
        }
        .onReceive(pollTimer) { _ in
            guard isPolling else { return }
            let pluginState = plugin.modelState
            if pluginState != .notLoaded {
                modelState = pluginState
            }
            if case .ready = pluginState { isPolling = false }
            else if case .error = pluginState { isPolling = false }
        }
    }

    @ViewBuilder
    private func modelRow(_ modelDef: GraniteModelDef) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(modelDef.displayName)
                    .font(.body)
                Text("\(modelDef.sizeDescription) - RAM: \(modelDef.ramRequirement)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .loading = modelState, selectedModelId == modelDef.id {
                ProgressView()
                    .controlSize(.small)
            } else if case .ready(let loadedId) = modelState, loadedId == modelDef.id {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button(String(localized: "Unload", bundle: bundle)) {
                        plugin.unloadModel()
                        plugin.deleteModelFiles(modelDef)
                        modelState = plugin.modelState
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Button(String(localized: "Download & Load", bundle: bundle)) {
                    selectedModelId = modelDef.id
                    modelState = .loading
                    isPolling = true
                    Task {
                        try? await plugin.loadModel(modelDef)
                        isPolling = false
                        modelState = plugin.modelState
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(modelState == .loading)
            }
        }
        .padding(.vertical, 4)
    }
}
