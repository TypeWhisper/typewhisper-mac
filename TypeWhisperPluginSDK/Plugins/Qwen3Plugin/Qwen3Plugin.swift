import Foundation
import SwiftUI
import HuggingFace
import MLX
import MLXAudioSTT
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(Qwen3Plugin)
final class Qwen3Plugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, DictionaryTermsCapabilityProviding, PluginSettingsActivityReporting, PluginDownloadedModelManaging, PluginRuntimeMemoryDiagnosticsReporting, @unchecked Sendable {
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
        language: nil,
        chunkDuration: 30.0,
        minChunkDuration: 1.0
    )

    private static let fallbackParams = STTGenerateParameters(
        maxTokens: 1536,
        temperature: 0.0,
        language: nil,
        chunkDuration: 15.0,
        minChunkDuration: 1.0
    )

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
        _hfToken = PluginHuggingFaceTokenHelper.loadToken(from: host)

        if shouldRestoreLoadedModelsPassively {
            Task { await restoreLoadedModel(allowDownloads: false) }
        }
    }

    func deactivate() {
        model = nil
        loadedModelId = nil
        modelState = .notLoaded
        Self.scheduleRuntimeCacheClearWhenInferenceIsIdle()
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "qwen3" }
    var providerDisplayName: String { "Qwen3 ASR (MLX)" }

    var isConfigured: Bool {
        model != nil && loadedModelId != nil
    }

    var shouldRestoreLoadedModelsPassively: Bool {
        host?.shouldRestoreLoadedModelsPassively ?? true
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
                downloaded: hasDownloadedModel(def),
                loaded: def.id == loadedModelId
            )
        }
    }

    var downloadedModels: [PluginModelInfo] {
        Self.availableModels
            .filter { hasDownloadedModel($0) }
            .map { def in
                PluginModelInfo(
                    id: def.id,
                    displayName: def.displayName,
                    sizeDescription: def.sizeDescription,
                    downloaded: true,
                    loaded: def.id == loadedModelId
                )
            }
    }

    func deleteDownloadedModel(_ modelId: String) async throws {
        guard let modelDef = Self.availableModels.first(where: { $0.id == modelId }) else { return }

        if loadedModelId == modelId {
            model = nil
            loadedModelId = nil
            modelState = .notLoaded
            host?.setUserDefault(nil, forKey: "loadedModel")
            await Self.clearRuntimeCacheWhenInferenceIsIdle()
        }
        if _selectedModelId == modelId {
            _selectedModelId = nil
            host?.setUserDefault(nil, forKey: "selectedModel")
        }
        if host?.userDefault(forKey: "loadedModel") as? String == modelId {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }

        try deleteModelFiles(modelDef)
        host?.notifyCapabilitiesChanged()
    }

    var supportedLanguages: [String] {
        Self.qwenSupportedLanguageCodes
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        let previousLoadedModelId = loadedModelId
        let shouldClearLoadedModel = previousLoadedModelId != nil && previousLoadedModelId != modelId
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")

        if shouldClearLoadedModel {
            model = nil
            loadedModelId = nil
            modelState = .notLoaded
            host?.setUserDefault(nil, forKey: "loadedModel")
            Self.scheduleRuntimeCacheClearWhenInferenceIsIdle()
            host?.notifyCapabilitiesChanged()
        }

        guard shouldRestoreDownloadedSelection(modelId, previousLoadedModelId: previousLoadedModelId) else {
            return
        }

        Task { await restoreLoadedModel(allowDownloads: false, preferredModelId: modelId) }
    }

    var supportsTranslation: Bool { false }
    var dictionaryTermsSupport: DictionaryTermsSupport { .unsupported }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        try await PluginLocalInferenceGate.shared.withLock { [self] in
            guard let model else {
                throw PluginTranscriptionError.notConfigured
            }
            defer { Self.clearRuntimeCache() }

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
            let outputLanguageName: String?

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
                    outputLanguageName = primaryOutput.language
                } else if QwenTranscriptGuard.isLikelyLooped(fallbackText) {
                    text = QwenTranscriptGuard.preferredTranscript(primary: primaryText, fallback: fallbackText)
                    outputLanguageName = primaryOutput.language ?? fallbackOutput.language
                } else {
                    text = fallbackText
                    outputLanguageName = fallbackOutput.language
                }
            } else {
                text = primaryText
                outputLanguageName = primaryOutput.language
            }

            let resultLanguageName = outputLanguageName ?? languageName
            let cleanedText = QwenTranscriptGuard.removingLikelyTrailingArtifact(
                from: text,
                languageName: resultLanguageName
            )
            let detectedLanguage = Self.languageCode(forQwenLanguageName: resultLanguageName) ?? language

            return PluginTranscriptionResult(text: cleanedText, detectedLanguage: detectedLanguage)
        }
    }

    // MARK: - Model Management

    fileprivate func loadModel(_ modelDef: Qwen3ModelDef) async throws {
        modelState = .loading
        do {
            let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models")
                ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

            let cache = HubCache(cacheDirectory: modelsDir)
            PluginHuggingFaceTokenHelper.applyTokenToEnvironment(_hfToken)
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
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel(allowDownloads: false) } }
    @objc(triggerRestoreModelForModel:) func triggerRestoreModel(forModel modelId: NSString?) {
        let preferredModelId = modelId.map(String.init)
        Task { await restoreLoadedModel(allowDownloads: false, preferredModelId: preferredModelId) }
    }

    func unloadModel(clearPersistence: Bool = true) {
        model = nil
        loadedModelId = nil
        modelState = .notLoaded
        Self.scheduleRuntimeCacheClearWhenInferenceIsIdle()
        if clearPersistence {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func deleteModelFiles(_ modelDef: Qwen3ModelDef) throws {
        guard let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models") else { return }
        let subdirectory = modelDef.repoId.replacingOccurrences(of: "/", with: "_")
        let modelDir = modelsDir
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(subdirectory)
        if FileManager.default.fileExists(atPath: modelDir.path) {
            try FileManager.default.removeItem(at: modelDir)
        }
    }

    func restoreLoadedModel(allowDownloads: Bool = false) async {
        await restoreLoadedModel(allowDownloads: allowDownloads, preferredModelId: nil)
    }

    func restoreLoadedModel(allowDownloads: Bool = false, preferredModelId: String?) async {
        for modelId in restoreCandidateModelIds(
            preferredModelId: preferredModelId,
            allowDownloads: allowDownloads
        ) {
            guard let modelDef = Self.availableModels.first(where: { $0.id == modelId }) else {
                continue
            }
            do {
                try await loadModel(modelDef)
                return
            } catch {
                continue
            }
        }
    }

    func restoreCandidateModelIds(
        preferredModelId: String? = nil,
        allowDownloads: Bool = false
    ) -> [String] {
        var candidateIds: [String] = []

        func appendCandidate(_ modelId: String?) {
            guard let modelId, !modelId.isEmpty else { return }
            guard Self.availableModels.contains(where: { $0.id == modelId }) else { return }
            guard !candidateIds.contains(modelId) else { return }
            candidateIds.append(modelId)
        }

        appendCandidate(preferredModelId)
        appendCandidate(host?.userDefault(forKey: "loadedModel") as? String)
        appendCandidate(_selectedModelId)

        let downloadedIds = downloadedModels.map(\.id)
        if downloadedIds.count == 1 {
            appendCandidate(downloadedIds[0])
        }

        guard !allowDownloads else { return candidateIds }

        return candidateIds.filter { modelId in
            guard let modelDef = Self.availableModels.first(where: { $0.id == modelId }) else {
                return false
            }
            return hasDownloadedModel(modelDef)
        }
    }

    func shouldRestoreDownloadedSelection(
        _ modelId: String,
        previousLoadedModelId: String?
    ) -> Bool {
        guard previousLoadedModelId != modelId else { return false }
        guard let modelDef = Self.availableModels.first(where: { $0.id == modelId }) else {
            return false
        }
        return hasDownloadedModel(modelDef)
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

    var runtimeMemorySnapshot: PluginRuntimeMemorySnapshot? {
        let snapshot = Memory.snapshot()
        return PluginRuntimeMemorySnapshot(
            activeMemoryBytes: snapshot.activeMemory,
            cacheMemoryBytes: snapshot.cacheMemory,
            peakMemoryBytes: snapshot.peakMemory
        )
    }

    private static func clearRuntimeCache() {
        Memory.clearCache()
    }

    private static func clearRuntimeCacheWhenInferenceIsIdle() async {
        try? await PluginLocalInferenceGate.shared.withLock {
            Memory.clearCache()
        }
    }

    private static func scheduleRuntimeCacheClearWhenInferenceIsIdle() {
        Task {
            await clearRuntimeCacheWhenInferenceIsIdle()
        }
    }

    var settingsView: AnyView? {
        AnyView(Qwen3SettingsView(plugin: self))
    }

    func setHuggingFaceToken(_ token: String) {
        _hfToken = PluginHuggingFaceTokenHelper.saveToken(token, to: host)
    }

    func clearHuggingFaceToken() {
        _hfToken = nil
        PluginHuggingFaceTokenHelper.clearToken(from: host)
    }

    func validateHuggingFaceToken(
        _ token: String,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async -> Bool {
        await PluginHuggingFaceTokenHelper.validateToken(token, dataFetcher: dataFetcher)
    }

    // MARK: - Model Definitions

    static let availableModels: [Qwen3ModelDef] = [
        Qwen3ModelDef(
            id: "qwen3-asr-0.6b-4bit",
            displayName: "Qwen3 0.6B (4-bit)",
            repoId: "mlx-community/Qwen3-ASR-0.6B-4bit",
            sizeDescription: "~0.7 GB",
            ramRequirement: "8 GB+",
            usageHint: "Smallest download; use when memory matters more than quality."
        ),
        Qwen3ModelDef(
            id: "qwen3-asr-0.6b-5bit",
            displayName: "Qwen3 0.6B (5-bit)",
            repoId: "mlx-community/Qwen3-ASR-0.6B-5bit",
            sizeDescription: "~0.8 GB",
            ramRequirement: "8 GB+",
            usageHint: "Slightly more precision than 4-bit with a similar footprint."
        ),
        Qwen3ModelDef(
            id: "qwen3-asr-0.6b-6bit",
            displayName: "Qwen3 0.6B (6-bit)",
            repoId: "mlx-community/Qwen3-ASR-0.6B-6bit",
            sizeDescription: "~0.9 GB",
            ramRequirement: "8 GB+",
            usageHint: "Fast pick for 8 GB Macs and casual dictation.",
            recommendation: .lowMemory
        ),
        Qwen3ModelDef(
            id: "qwen3-asr-0.6b-8bit",
            displayName: "Qwen3 0.6B (8-bit)",
            repoId: "mlx-community/Qwen3-ASR-0.6B-8bit",
            sizeDescription: "~1.0 GB",
            ramRequirement: "16 GB+",
            usageHint: "Higher-precision small model when 0.6B quality matters."
        ),
        Qwen3ModelDef(
            id: "qwen3-asr-0.6b-bf16",
            displayName: "Qwen3 0.6B (BF16)",
            repoId: "mlx-community/Qwen3-ASR-0.6B-bf16",
            sizeDescription: "~1.6 GB",
            ramRequirement: "16 GB+",
            usageHint: "Unquantized small model; useful for comparison or validation."
        ),
        Qwen3ModelDef(
            id: "qwen3-asr-1.7b-4bit",
            displayName: "Qwen3 1.7B (4-bit)",
            repoId: "mlx-community/Qwen3-ASR-1.7B-4bit",
            sizeDescription: "~1.6 GB",
            ramRequirement: "16 GB+",
            usageHint: "Smallest 1.7B option; use when 6-bit is too heavy."
        ),
        Qwen3ModelDef(
            id: "qwen3-asr-1.7b-5bit",
            displayName: "Qwen3 1.7B (5-bit)",
            repoId: "mlx-community/Qwen3-ASR-1.7B-5bit",
            sizeDescription: "~1.8 GB",
            ramRequirement: "16 GB+",
            usageHint: "Middle ground if the default 6-bit model is tight on memory."
        ),
        Qwen3ModelDef(
            id: "qwen3-asr-1.7b-6bit",
            displayName: "Qwen3 1.7B (6-bit)",
            repoId: "mlx-community/Qwen3-ASR-1.7B-6bit",
            sizeDescription: "~2.0 GB",
            ramRequirement: "16 GB+",
            usageHint: "Best default for most 16 GB+ Macs.",
            recommendation: .balanced
        ),
        Qwen3ModelDef(
            id: "qwen3-asr-1.7b-8bit",
            displayName: "Qwen3 1.7B (8-bit)",
            repoId: "mlx-community/Qwen3-ASR-1.7B-8bit",
            sizeDescription: "~2.5 GB",
            ramRequirement: "32 GB+",
            usageHint: "Higher-quality pick for 32 GB+ Macs.",
            recommendation: .highQuality
        ),
        Qwen3ModelDef(
            id: "qwen3-asr-1.7b-bf16",
            displayName: "Qwen3 1.7B (BF16)",
            repoId: "mlx-community/Qwen3-ASR-1.7B-bf16",
            sizeDescription: "~4.1 GB",
            ramRequirement: "32 GB+",
            usageHint: "Largest unquantized model; use for max-fidelity validation."
        ),
    ]

    // MARK: - Helpers

    static let qwenSupportedLanguageCodes: [String] = [
        "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it",
        "ko", "ru", "th", "vi", "ja", "tr", "hi", "ms", "nl", "sv",
        "da", "fi", "pl", "cs", "fil", "tl", "fa", "el", "ro", "hu",
        "mk",
    ]

    // Language code to English language name used by the Qwen3 ASR API.
    private static let languageNamesByCode: [String: String] = [
        "zh": "Chinese", "en": "English", "yue": "Cantonese",
        "ar": "Arabic", "de": "German", "fr": "French",
        "es": "Spanish", "pt": "Portuguese", "id": "Indonesian",
        "it": "Italian", "ko": "Korean", "ru": "Russian",
        "th": "Thai", "vi": "Vietnamese", "ja": "Japanese",
        "tr": "Turkish", "hi": "Hindi", "ms": "Malay",
        "nl": "Dutch", "sv": "Swedish", "da": "Danish",
        "fi": "Finnish", "pl": "Polish", "cs": "Czech",
        "fil": "Filipino", "tl": "Filipino", "fa": "Persian", "el": "Greek",
        "hu": "Hungarian", "mk": "Macedonian", "ro": "Romanian",
    ]

    private static let languageCodesByName: [String: String] = {
        var result: [String: String] = [:]
        for (code, name) in languageNamesByCode {
            if result[name.lowercased()] == nil || code != "tl" {
                result[name.lowercased()] = code
            }
        }
        return result
    }()

    static func resolveLanguageName(_ isoCode: String?) -> String? {
        guard let code = isoCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !code.isEmpty else {
            return nil
        }
        return languageNamesByCode[code]
    }

    static func languageCode(forQwenLanguageName languageName: String?) -> String? {
        guard let languageName = languageName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !languageName.isEmpty else {
            return nil
        }

        let names = languageName
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard names.count == 1 else { return nil }
        return languageCodesByName[names[0]]
    }

    static func contextBiasString(from prompt: String?) -> String {
        Qwen3ContextBiasFormatter.format(prompt: prompt)
    }

    private static func generate(
        model: Qwen3ASRModel,
        audio: MLXArray,
        params: STTGenerateParameters,
        context: String,
        language: String?
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
    let usageHint: String
    let recommendation: Qwen3ModelRecommendation?

    init(
        id: String,
        displayName: String,
        repoId: String,
        sizeDescription: String,
        ramRequirement: String,
        usageHint: String,
        recommendation: Qwen3ModelRecommendation? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.repoId = repoId
        self.sizeDescription = sizeDescription
        self.ramRequirement = ramRequirement
        self.usageHint = usageHint
        self.recommendation = recommendation
    }
}

enum Qwen3ModelRecommendation: Equatable {
    case lowMemory
    case balanced
    case highQuality
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
    static func removingLikelyTrailingArtifact(from text: String, languageName: String?) -> String {
        guard isFrench(languageName) else { return text }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let artifactPattern = #"(?i)[.!?;:]\s+oui[.!?]*$"#
        guard let artifactRange = trimmed.range(of: artifactPattern, options: .regularExpression) else {
            return removingBareTrailingOuiArtifact(from: trimmed) ?? text
        }

        let artifact = String(trimmed[artifactRange])
        guard let punctuation = artifact.first else { return text }

        let prefix = trimmed[..<artifactRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return text }

        return "\(prefix)\(punctuation)"
    }

    private static func removingBareTrailingOuiArtifact(from text: String) -> String? {
        let artifactPattern = #"(?i)(?:,\s+|\s+)oui[.!?]*$"#
        guard let artifactRange = text.range(of: artifactPattern, options: .regularExpression) else {
            return nil
        }

        let prefix = text[..<artifactRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixWords = words(in: String(prefix))
        guard prefixWords.count >= 4, prefixWords.last != "que" else {
            return nil
        }

        return String(prefix)
    }

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

    private static func isFrench(_ languageName: String?) -> Bool {
        guard let languageName = languageName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !languageName.isEmpty else {
            return false
        }

        return languageName
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains("french")
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

    nonisolated init(plugin: Qwen3Plugin) {
        self.plugin = plugin
    }

    private var trimmedHfTokenInput: String {
        hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var storedHfToken: String {
        plugin._hfToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var hasStoredHfToken: Bool {
        !storedHfToken.isEmpty
    }

    private var quickPickModels: [Qwen3ModelDef] {
        Qwen3Plugin.availableModels.filter { $0.recommendation != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Qwen3 ASR (MLX)")
                .font(.headline)

            Text("Local Qwen3-ASR speech-to-text powered by MLX on Apple Silicon. 30 languages plus Chinese dialect coverage, no API key required.", bundle: bundle)
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

                quickPickGuide

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
            if case .notLoaded = plugin.modelState, plugin.shouldRestoreLoadedModelsPassively {
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
    private var quickPickGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick picks", bundle: bundle)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(quickPickModels) { modelDef in
                if let recommendation = modelDef.recommendation {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: recommendationSystemImage(for: recommendation))
                            .font(.caption)
                            .foregroundStyle(recommendationColor(for: recommendation))
                            .frame(width: 14)

                        Text(recommendationTitle(for: recommendation))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Text(modelDef.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func modelRow(_ modelDef: Qwen3ModelDef) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(modelDef.displayName)
                        .font(.body)

                    if let recommendation = modelDef.recommendation {
                        recommendationBadge(recommendation)
                    }
                }

                Text("\(modelDef.sizeDescription) - RAM: \(modelDef.ramRequirement)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(localizedUsageHint(for: modelDef))
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
                        try? plugin.deleteModelFiles(modelDef)
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

    @ViewBuilder
    private func recommendationBadge(_ recommendation: Qwen3ModelRecommendation) -> some View {
        HStack(spacing: 3) {
            Image(systemName: recommendationSystemImage(for: recommendation))
                .imageScale(.small)
            Text(recommendationShortLabel(for: recommendation))
        }
        .font(.caption2)
        .fontWeight(.semibold)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(recommendationColor(for: recommendation))
        .background(recommendationColor(for: recommendation).opacity(0.12), in: Capsule())
    }

    private func recommendationSystemImage(for recommendation: Qwen3ModelRecommendation) -> String {
        switch recommendation {
        case .lowMemory:
            "bolt.fill"
        case .balanced:
            "checkmark.seal.fill"
        case .highQuality:
            "star.fill"
        }
    }

    private func recommendationColor(for recommendation: Qwen3ModelRecommendation) -> Color {
        switch recommendation {
        case .lowMemory:
            .blue
        case .balanced:
            .green
        case .highQuality:
            .purple
        }
    }

    private func recommendationShortLabel(for recommendation: Qwen3ModelRecommendation) -> String {
        switch recommendation {
        case .lowMemory:
            String(localized: "8 GB pick", bundle: bundle)
        case .balanced:
            String(localized: "Recommended", bundle: bundle)
        case .highQuality:
            String(localized: "32 GB quality", bundle: bundle)
        }
    }

    private func recommendationTitle(for recommendation: Qwen3ModelRecommendation) -> String {
        switch recommendation {
        case .lowMemory:
            String(localized: "Fast / 8 GB", bundle: bundle)
        case .balanced:
            String(localized: "Best default", bundle: bundle)
        case .highQuality:
            String(localized: "Quality / 32 GB", bundle: bundle)
        }
    }

    private func localizedUsageHint(for modelDef: Qwen3ModelDef) -> String {
        switch modelDef.id {
        case "qwen3-asr-0.6b-4bit":
            String(localized: "Smallest download; use when memory matters more than quality.", bundle: bundle)
        case "qwen3-asr-0.6b-5bit":
            String(localized: "Slightly more precision than 4-bit with a similar footprint.", bundle: bundle)
        case "qwen3-asr-0.6b-6bit":
            String(localized: "Fast pick for 8 GB Macs and casual dictation.", bundle: bundle)
        case "qwen3-asr-0.6b-8bit":
            String(localized: "Higher-precision small model when 0.6B quality matters.", bundle: bundle)
        case "qwen3-asr-0.6b-bf16":
            String(localized: "Unquantized small model; useful for comparison or validation.", bundle: bundle)
        case "qwen3-asr-1.7b-4bit":
            String(localized: "Smallest 1.7B option; use when 6-bit is too heavy.", bundle: bundle)
        case "qwen3-asr-1.7b-5bit":
            String(localized: "Middle ground if the default 6-bit model is tight on memory.", bundle: bundle)
        case "qwen3-asr-1.7b-6bit":
            String(localized: "Best default for most 16 GB+ Macs.", bundle: bundle)
        case "qwen3-asr-1.7b-8bit":
            String(localized: "Higher-quality pick for 32 GB+ Macs.", bundle: bundle)
        case "qwen3-asr-1.7b-bf16":
            String(localized: "Largest unquantized model; use for max-fidelity validation.", bundle: bundle)
        default:
            modelDef.usageHint
        }
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
