import Foundation
import SwiftUI
import HuggingFace
import MLX
import MLXAudioSTT
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(Qwen3Plugin)
final class Qwen3Plugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, DictionaryTermsCapabilityProviding, DictionaryTermsBudgetProviding, PluginSettingsActivityReporting, @unchecked Sendable {
    static let pluginId = "com.typewhisper.qwen3"
    static let pluginName = "Qwen3 ASR"

    fileprivate var host: HostServices?
    fileprivate var _selectedModelId: String?
    fileprivate var model: Qwen3ASRModel?
    fileprivate var loadedModelId: String?
    fileprivate var _hfToken: String?

    // Observable state for settings UI
    fileprivate var modelState: Qwen3ModelState = .notLoaded

    private static let primaryParams = STTGenerateParameters(
        maxTokens: 2048,
        temperature: 0.0,
        language: "English",
        chunkDuration: 30.0,
        minChunkDuration: 1.0
    )

    private static let fallbackParams = STTGenerateParameters(
        maxTokens: 1536,
        temperature: 0.0,
        language: "English",
        chunkDuration: 15.0,
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

        Task { await restoreLoadedModel(allowDownloads: false) }
    }

    func deactivate() {
        model = nil
        loadedModelId = nil
        modelState = .notLoaded
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "qwen3" }
    var providerDisplayName: String { "Qwen3 ASR (MLX)" }

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
            "af", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs",
            "cy", "da", "de", "el", "en", "es", "et", "fa", "fi", "fr",
            "gl", "gu", "ha", "he", "hi", "hr", "hu", "hy", "id", "is",
            "it", "ja", "jw", "ka", "kk", "km", "kn", "ko", "lo", "lt",
            "lv", "mk", "ml", "mn", "mr", "ms", "my", "ne", "nl", "no",
            "pa", "pl", "ps", "pt", "ro", "ru", "sd", "si", "sk", "sl",
            "sn", "so", "sq", "sr", "su", "sv", "sw", "ta", "te", "tg",
            "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi", "yo",
            "yue", "zh",
        ]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { false }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }
    var dictionaryTermsBudget: DictionaryTermsBudget { DictionaryTermsBudget(maxTotalChars: 10_000) }

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
        let languageName = Self.resolveLanguageName(language)
        let context = Self.contextBiasString(from: prompt)

        let primaryOutput = Self.generate(
            model: model,
            audio: audioArray,
            params: Self.primaryParams,
            context: context,
            language: languageName
        )
        let primaryText = Self.normalizeTranscript(primaryOutput.text)
        let text: String

        if QwenTranscriptGuard.isLikelyLooped(primaryText) {
            let fallbackOutput = Self.generate(
                model: model,
                audio: audioArray,
                params: Self.fallbackParams,
                context: "",
                language: languageName
            )
            let fallbackText = Self.normalizeTranscript(fallbackOutput.text)

            if fallbackText.isEmpty {
                text = primaryText
            } else if QwenTranscriptGuard.isLikelyLooped(fallbackText) {
                text = QwenTranscriptGuard.preferredTranscript(primary: primaryText, fallback: fallbackText)
            } else {
                text = fallbackText
            }
        } else {
            text = primaryText
        }

        return PluginTranscriptionResult(text: text, detectedLanguage: language)
    }

    // MARK: - Model Management

    fileprivate func loadModel(_ modelDef: Qwen3ModelDef) async throws {
        modelState = .loading
        do {
            let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models")
                ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

            let cache = HubCache(cacheDirectory: modelsDir)
            if let token = _hfToken, !token.isEmpty {
                setenv("HF_TOKEN", token, 1)
            }
            let loaded = try await Qwen3ASRModel.fromPretrained(modelDef.repoId, cache: cache)

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
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel(allowDownloads: true) } }

    func unloadModel(clearPersistence: Bool = true) {
        model = nil
        loadedModelId = nil
        modelState = .notLoaded
        if clearPersistence {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func deleteModelFiles(_ modelDef: Qwen3ModelDef) {
        guard let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models") else { return }
        let subdirectory = modelDef.repoId.replacingOccurrences(of: "/", with: "_")
        let modelDir = modelsDir
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(subdirectory)
        try? FileManager.default.removeItem(at: modelDir)
    }

    func restoreLoadedModel(allowDownloads: Bool = true) async {
        guard let savedId = host?.userDefault(forKey: "loadedModel") as? String,
              let modelDef = Self.availableModels.first(where: { $0.id == savedId }) else {
            return
        }
        guard allowDownloads || hasDownloadedModel(modelDef) else { return }
        try? await loadModel(modelDef)
    }

    private func hasDownloadedModel(_ modelDef: Qwen3ModelDef) -> Bool {
        guard let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models") else { return false }
        let subdirectory = modelDef.repoId.replacingOccurrences(of: "/", with: "_")
        let modelDir = modelsDir
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(subdirectory)

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
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
        AnyView(Qwen3SettingsView(plugin: self))
    }

    func setHuggingFaceToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        _hfToken = trimmed.isEmpty ? nil : trimmed
        try? host?.storeSecret(key: "hf-token", value: trimmed)
    }

    func clearHuggingFaceToken() {
        _hfToken = nil
        try? host?.storeSecret(key: "hf-token", value: "")
    }

    func validateHuggingFaceToken(
        _ token: String,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "https://huggingface.co/api/whoami-v2") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await dataFetcher(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }

            return json["name"] != nil || json["type"] != nil || json["auth"] != nil
        } catch {
            return false
        }
    }

    // MARK: - Model Definitions

    static let availableModels: [Qwen3ModelDef] = [
        Qwen3ModelDef(
            id: "qwen3-asr-0.6b-4bit",
            displayName: "Qwen3 0.6B (4-bit)",
            repoId: "mlx-community/Qwen3-ASR-0.6B-4bit",
            sizeDescription: "~400 MB",
            ramRequirement: "8 GB+"
        ),
        Qwen3ModelDef(
            id: "qwen3-asr-0.6b-8bit",
            displayName: "Qwen3 0.6B (8-bit)",
            repoId: "mlx-community/Qwen3-ASR-0.6B-8bit",
            sizeDescription: "~800 MB",
            ramRequirement: "16 GB+"
        ),
        Qwen3ModelDef(
            id: "qwen3-asr-1.7b-4bit",
            displayName: "Qwen3 1.7B (4-bit)",
            repoId: "mlx-community/Qwen3-ASR-1.7B-4bit",
            sizeDescription: "~1 GB",
            ramRequirement: "16 GB+"
        ),
        Qwen3ModelDef(
            id: "qwen3-asr-1.7b-8bit",
            displayName: "Qwen3 1.7B (8-bit)",
            repoId: "mlx-community/Qwen3-ASR-1.7B-8bit",
            sizeDescription: "~2 GB",
            ramRequirement: "32 GB+"
        ),
    ]

    // MARK: - Helpers

    // ISO 639-1 code to English language name (used by Qwen3 ASR API)
    private static let languageNames: [String: String] = [
        "zh": "Chinese", "en": "English", "yue": "Cantonese",
        "ar": "Arabic", "de": "German", "fr": "French",
        "es": "Spanish", "pt": "Portuguese", "id": "Indonesian",
        "it": "Italian", "ko": "Korean", "ru": "Russian",
        "th": "Thai", "vi": "Vietnamese", "ja": "Japanese",
        "tr": "Turkish", "hi": "Hindi", "ms": "Malay",
        "nl": "Dutch", "sv": "Swedish", "da": "Danish",
        "fi": "Finnish", "pl": "Polish", "cs": "Czech",
        "fil": "Filipino", "fa": "Persian", "el": "Greek",
        "hu": "Hungarian", "mk": "Macedonian", "ro": "Romanian",
    ]

    fileprivate static func resolveLanguageName(_ isoCode: String?) -> String {
        guard let code = isoCode else { return "English" }
        return languageNames[code] ?? "English"
    }

    private static func contextBiasString(from prompt: String?) -> String {
        Qwen3ContextBiasFormatter.format(prompt: prompt)
    }

    private static func generate(
        model: Qwen3ASRModel,
        audio: MLXArray,
        params: STTGenerateParameters,
        context: String,
        language: String
    ) -> STTOutput {
        model.generate(
            audio: audio,
            maxTokens: params.maxTokens,
            temperature: params.temperature,
            context: context,
            language: language,
            chunkDuration: params.chunkDuration,
            minChunkDuration: params.minChunkDuration
        )
    }

    fileprivate static func normalizeTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Model Types

struct Qwen3ModelDef: Identifiable {
    let id: String
    let displayName: String
    let repoId: String
    let sizeDescription: String
    let ramRequirement: String
}

enum Qwen3ModelState: Equatable {
    case notLoaded
    case loading
    case ready(String) // loaded model ID
    case error(String)

    static func == (lhs: Qwen3ModelState, rhs: Qwen3ModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded): true
        case (.loading, .loading): true
        case let (.ready(a), .ready(b)): a == b
        case let (.error(a), .error(b)): a == b
        default: false
        }
    }
}

// MARK: - QwenTranscriptGuard (Loop Detection)

enum QwenTranscriptGuard {
    static func isLikelyLooped(_ text: String) -> Bool {
        let words = words(in: text)
        guard words.count >= 16 else { return false }

        let metrics = LoopMetrics(words: words)
        let dominantShare = Double(metrics.maxFrequency) / Double(words.count)

        if metrics.longestRun >= 7 { return true }
        if dominantShare >= 0.5, metrics.uniqueRatio <= 0.3 { return true }
        if metrics.hasRepeatedNGram(n: 3, minRepeats: 5), metrics.uniqueRatio <= 0.45 { return true }
        return false
    }

    static func preferredTranscript(primary: String, fallback: String) -> String {
        let primaryMetrics = LoopMetrics(words: words(in: primary))
        let fallbackMetrics = LoopMetrics(words: words(in: fallback))
        let primaryScore = primaryMetrics.qualityScore
        let fallbackScore = fallbackMetrics.qualityScore

        if primaryScore == fallbackScore {
            return primary.count <= fallback.count ? primary : fallback
        }
        return primaryScore >= fallbackScore ? primary : fallback
    }

    private static func words(in text: String) -> [String] {
        text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    private struct LoopMetrics {
        let words: [String]
        let uniqueRatio: Double
        let maxFrequency: Int
        let longestRun: Int

        init(words: [String]) {
            self.words = words
            if words.isEmpty {
                uniqueRatio = 0
                maxFrequency = 0
                longestRun = 0
                return
            }

            var counts: [String: Int] = [:]
            counts.reserveCapacity(words.count)
            var currentRun = 0
            var lastWord: String?
            var bestRun = 0

            for word in words {
                counts[word, default: 0] += 1
                if word == lastWord {
                    currentRun += 1
                } else {
                    currentRun = 1
                    lastWord = word
                }
                if currentRun > bestRun {
                    bestRun = currentRun
                }
            }

            uniqueRatio = Double(counts.count) / Double(words.count)
            maxFrequency = counts.values.max() ?? 0
            longestRun = bestRun
        }

        var qualityScore: Double {
            guard !words.isEmpty else { return -Double.greatestFiniteMagnitude }
            let runPenalty = Double(longestRun) / Double(words.count)
            let dominancePenalty = Double(maxFrequency) / Double(words.count)
            return uniqueRatio - runPenalty - dominancePenalty
        }

        func hasRepeatedNGram(n: Int, minRepeats: Int) -> Bool {
            guard n > 0, words.count >= n * minRepeats else { return false }
            var counts: [String: Int] = [:]
            counts.reserveCapacity(words.count / n)
            let limit = words.count - n
            for index in 0...limit {
                let key = words[index..<(index + n)].joined(separator: " ")
                counts[key, default: 0] += 1
                if counts[key, default: 0] >= minRepeats {
                    return true
                }
            }
            return false
        }
    }
}

// MARK: - Settings View

private struct Qwen3SettingsView: View {
    let plugin: Qwen3Plugin
    private let bundle = Bundle(for: Qwen3Plugin.self)
    @State private var modelState: Qwen3ModelState = .notLoaded
    @State private var selectedModelId: String = ""
    @State private var isPolling = false
    @State private var hfTokenInput = ""
    @State private var showHfToken = false
    @State private var isValidatingToken = false
    @State private var tokenValidationResult: Bool?

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var trimmedHfTokenInput: String {
        hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var storedHfToken: String {
        plugin._hfToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var hasStoredHfToken: Bool {
        !storedHfToken.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Qwen3 ASR (MLX)")
                .font(.headline)

            Text("Local speech-to-text powered by MLX on Apple Silicon. 30 languages, no API key required.", bundle: bundle)
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

                    if hasStoredHfToken {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            hfTokenInput = ""
                            tokenValidationResult = nil
                            isValidatingToken = false
                            plugin.clearHuggingFaceToken()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button(String(localized: "Save", bundle: bundle)) {
                        validateAndSaveHuggingFaceToken()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedHfTokenInput.isEmpty || isValidatingToken)
                }

                if isValidatingToken {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating token...", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let tokenValidationResult {
                    HStack(spacing: 4) {
                        Image(systemName: tokenValidationResult ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(tokenValidationResult ? .green : .red)
                        Text(
                            tokenValidationResult
                                ? String(localized: "Valid HuggingFace Token", bundle: bundle)
                                : String(localized: "Invalid HuggingFace Token", bundle: bundle)
                        )
                        .font(.caption)
                        .foregroundStyle(tokenValidationResult ? .green : .red)
                    }
                }
            }

            Divider()

            // Model Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Model", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                ForEach(Qwen3Plugin.availableModels) { modelDef in
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
            selectedModelId = plugin.selectedModelId ?? Qwen3Plugin.availableModels.first?.id ?? ""
            if let token = plugin._hfToken, !token.isEmpty {
                hfTokenInput = token
            }
        }
        .task {
            // Auto-restore previously loaded model
            if case .notLoaded = plugin.modelState {
                isPolling = true
                await plugin.restoreLoadedModel(allowDownloads: false)
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
        .onChange(of: hfTokenInput) { _, newValue in
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedValue != storedHfToken {
                tokenValidationResult = nil
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ modelDef: Qwen3ModelDef) -> some View {
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

    private func validateAndSaveHuggingFaceToken() {
        let trimmedToken = trimmedHfTokenInput
        guard !trimmedToken.isEmpty else { return }

        isValidatingToken = true
        tokenValidationResult = nil

        Task {
            let isValid = await plugin.validateHuggingFaceToken(trimmedToken)
            await MainActor.run {
                isValidatingToken = false
                tokenValidationResult = isValid
                if isValid {
                    plugin.setHuggingFaceToken(trimmedToken)
                    hfTokenInput = trimmedToken
                }
            }
        }
    }
}
