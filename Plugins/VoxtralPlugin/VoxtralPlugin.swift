import Foundation
import SwiftUI
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(VoxtralPlugin)
final class VoxtralPlugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, DictionaryTermsCapabilityProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.voxtral"
    static let pluginName = "Voxtral"

    fileprivate var host: HostServices?
    fileprivate var _selectedModelId: String?
    fileprivate var model: VoxtralRealtimeModel?
    fileprivate var loadedModelId: String?
    fileprivate var _hfToken: String?

    fileprivate var modelState: VoxtralModelState = .notLoaded

    private static let defaultParams = STTGenerateParameters(
        maxTokens: 4096,
        temperature: 0.0,
        language: "en",
        chunkDuration: 1200.0,
        minChunkDuration: 1.0
    )

    private static let fallbackParams = STTGenerateParameters(
        maxTokens: 2048,
        temperature: 0.0,
        language: "en",
        chunkDuration: 600.0,
        minChunkDuration: 1.0
    )

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

    var providerId: String { "voxtral" }
    var providerDisplayName: String { "Voxtral (MLX)" }

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
        [
            "en", "fr", "es", "pt", "de", "nl", "it", "hi",
            "pl", "tr", "ru", "ar", "zh", "ja", "ko",
        ]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { .unsupported }

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
        let params = Self.makeParams(Self.defaultParams, language: language ?? "en")

        let output = model.generate(audio: audioArray, generationParameters: params)
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
        let params = Self.makeParams(Self.defaultParams, language: language ?? "en")

        var accumulated = ""
        let stream = model.generateStream(audio: audioArray, generationParameters: params)

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

    fileprivate func loadModel(_ modelDef: VoxtralModelDef) async throws {
        modelState = .loading
        do {
            let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models")
                ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

            let cache = HubCache(cacheDirectory: modelsDir)
            if let token = _hfToken, !token.isEmpty {
                setenv("HF_TOKEN", token, 1)
            }
            guard let repoID = Repo.ID(rawValue: modelDef.repoId) else {
                throw NSError(
                    domain: "VoxtralPlugin", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid repository ID: \(modelDef.repoId)"]
                )
            }

            let modelDir = try await ModelUtils.resolveOrDownloadModel(
                repoID: repoID,
                requiredExtension: "safetensors",
                cache: cache
            )

            let loaded = try VoxtralRealtimeModel.fromDirectory(modelDir)

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

    fileprivate func deleteModelFiles(_ modelDef: VoxtralModelDef) {
        guard let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models") else { return }
        let repoDir = modelsDir.appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
        // HubCache stores repos under models--org--name pattern
        let subdirectory = "models--" + modelDef.repoId.replacingOccurrences(of: "/", with: "--")
        let modelDir = repoDir.appendingPathComponent(subdirectory)
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

    var settingsView: AnyView? {
        AnyView(VoxtralSettingsView(plugin: self))
    }

    // MARK: - Model Definitions

    static let availableModels: [VoxtralModelDef] = [
        VoxtralModelDef(
            id: "voxtral-mini-4b-2602-4bit",
            displayName: "Mini 4B (4-bit)",
            repoId: "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit",
            sizeDescription: "~2.5 GB",
            ramRequirement: "8 GB+"
        ),
        VoxtralModelDef(
            id: "voxtral-mini-4b-2602-fp16",
            displayName: "Mini 4B (fp16)",
            repoId: "mlx-community/Voxtral-Mini-4B-Realtime-2602-fp16",
            sizeDescription: "~8 GB",
            ramRequirement: "16 GB+"
        ),
    ]

    // MARK: - Helpers

    private static func makeParams(_ base: STTGenerateParameters, language: String) -> STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: base.maxTokens,
            temperature: base.temperature,
            language: language,
            chunkDuration: base.chunkDuration,
            minChunkDuration: base.minChunkDuration
        )
    }

    fileprivate static func normalizeTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Model Types

struct VoxtralModelDef: Identifiable {
    let id: String
    let displayName: String
    let repoId: String
    let sizeDescription: String
    let ramRequirement: String
}

enum VoxtralModelState: Equatable {
    case notLoaded
    case loading
    case ready(String)
    case error(String)

    static func == (lhs: VoxtralModelState, rhs: VoxtralModelState) -> Bool {
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

private struct VoxtralSettingsView: View {
    let plugin: VoxtralPlugin
    private let bundle = Bundle(for: VoxtralPlugin.self)
    @State private var modelState: VoxtralModelState = .notLoaded
    @State private var selectedModelId: String = ""
    @State private var isPolling = false
    @State private var hfTokenInput = ""
    @State private var showHfToken = false

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Voxtral (MLX)")
                .font(.headline)

            Text("Local speech-to-text by Mistral, powered by MLX on Apple Silicon. 15 languages, no API key required.", bundle: bundle)
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

                ForEach(VoxtralPlugin.availableModels) { modelDef in
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
            selectedModelId = plugin.selectedModelId ?? VoxtralPlugin.availableModels.first?.id ?? ""
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
    private func modelRow(_ modelDef: VoxtralModelDef) -> some View {
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
