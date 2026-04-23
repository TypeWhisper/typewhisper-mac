import Foundation
import OSLog
import SwiftUI
import FluidAudio
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(ParakeetPlugin)
final class ParakeetPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, PluginSettingsActivityReporting, @unchecked Sendable {
    static let pluginId = "com.typewhisper.parakeet"
    static let pluginName = "Parakeet"
    private static let logger = Logger(subsystem: "com.typewhisper.plugin.parakeet", category: "Transcription")
    private static let shortClipConfidenceThreshold: Float = 0.55
    private static let shortClipConfidenceGateDuration: TimeInterval = 1.0

    fileprivate var host: HostServices?
    fileprivate var asrManager: AsrManager?
    fileprivate var loadedModelId: String?
    fileprivate var modelState: ParakeetModelState = .notLoaded
    fileprivate var downloadProgress: Double = 0
    fileprivate var selectedVersion: ParakeetVersion = .v3

    // Vocabulary Boosting
    fileprivate var ctcModels: CtcModels?
    fileprivate var ctcTokenizer: CtcTokenizer?
    fileprivate var ctcSpotter: CtcKeywordSpotter?
    fileprivate var customVocabulary: CustomVocabularyContext?
    fileprivate var vocabularyRescorer: VocabularyRescorer?
    fileprivate var vocabSizeConfig: ContextBiasingConstants.VocabSizeConfig?
    fileprivate var vocabularyBoostingEnabled: Bool = false
    fileprivate var ctcModelState: CtcModelState = .notDownloaded
    fileprivate var lastConfiguredPrompt: String?
    fileprivate var lastBoostingTermCount: Int = 0

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        vocabularyBoostingEnabled = host.userDefault(forKey: "vocabularyBoostingEnabled") as? Bool ?? false
        if let versionString = host.userDefault(forKey: "selectedVersion") as? String,
           let version = ParakeetVersion(rawValue: versionString) {
            selectedVersion = version
        }
        Task { await restoreLoadedModel(allowDownloads: false) }
    }

    func deactivate() {
        clearVocabularyBoostingState(resetModelState: true)
        asrManager = nil
        loadedModelId = nil
        modelState = .notLoaded
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "parakeet" }
    var providerDisplayName: String { "Parakeet" }

    var isConfigured: Bool {
        asrManager != nil && loadedModelId != nil
    }

    var transcriptionModels: [PluginModelInfo] {
        ParakeetVersion.allCases.map { version in
            let def = version.modelDef
            return PluginModelInfo(
                id: def.id,
                displayName: def.displayName,
                sizeDescription: def.sizeDescription,
                languageCount: version.languageCount
            )
        }
    }

    var selectedModelId: String? { loadedModelId }

    func selectModel(_ modelId: String) {
        guard let version = ParakeetVersion.from(modelId: modelId) else { return }
        if version == selectedVersion && loadedModelId == modelId { return }
        Task {
            unloadModel(clearPersistence: false)
            selectedVersion = version
            host?.setUserDefault(version.rawValue, forKey: "selectedVersion")
            await loadModel()
        }
    }

    var supportsTranslation: Bool { false }
    var dictionaryTermsSupport: DictionaryTermsSupport { .requiresPluginSetting }

    var supportedLanguages: [String] {
        selectedVersion.supportedLanguages
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let asrManager else {
            throw PluginTranscriptionError.notConfigured
        }

        if translate {
            throw PluginTranscriptionError.apiError("Parakeet does not support translation")
        }

        if vocabularyBoostingEnabled {
            await configureBoostingIfNeeded(prompt: prompt)
        }

        let normalizedSamples = PluginAudioUtils.paddedSamples(
            audio.samples,
            minimumDuration: 1.0,
            sampleRate: 16_000
        )
        let fluidLanguage = Self.fluidAudioLanguage(for: language)
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(
            normalizedSamples,
            decoderState: &decoderState,
            language: fluidLanguage
        )
        let finalResult = await applyVocabularyRescoringIfNeeded(
            to: result,
            audioSamples: normalizedSamples
        )
        let trimmedText = finalResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if audio.duration < Self.shortClipConfidenceGateDuration {
            Self.logger.info(
                "Short clip transcription: rawDuration=\(String(format: "%.3f", audio.duration), privacy: .public)s, confidence=\(String(format: "%.3f", finalResult.confidence), privacy: .public), textLength=\(trimmedText.count, privacy: .public)"
            )
        }

        guard PluginAudioUtils.shouldAcceptShortClipTranscription(
            audioDuration: audio.duration,
            confidence: finalResult.confidence,
            minimumDuration: Self.shortClipConfidenceGateDuration,
            minimumConfidence: Self.shortClipConfidenceThreshold
        ) else {
            Self.logger.info(
                "Discarding low-confidence short clip: rawDuration=\(String(format: "%.3f", audio.duration), privacy: .public)s, confidence=\(String(format: "%.3f", finalResult.confidence), privacy: .public)"
            )
            return PluginTranscriptionResult(text: "", detectedLanguage: nil, segments: [])
        }

        let segments: [PluginTranscriptionSegment]
        if let tokenTimings = finalResult.tokenTimings, !tokenTimings.isEmpty {
            segments = Self.groupTokensIntoSegments(tokenTimings)
        } else {
            segments = []
        }

        return PluginTranscriptionResult(text: finalResult.text, detectedLanguage: nil, segments: segments)
    }

    private static func fluidAudioLanguage(for language: String?) -> Language? {
        guard let language else { return nil }
        let primaryCode = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)

        guard let primaryCode, !primaryCode.isEmpty else { return nil }
        return Language(rawValue: primaryCode)
    }
    // MARK: - Token-to-Segment Grouping

    private static func groupTokensIntoSegments(_ tokenTimings: [TokenTiming]) -> [PluginTranscriptionSegment] {
        // Phase 1: Group sub-word tokens into words
        struct WordTiming {
            let word: String
            let start: Double
            let end: Double
        }

        var words: [WordTiming] = []
        var currentWord = ""
        var wordStart: Double = 0
        var wordEnd: Double = 0

        for timing in tokenTimings {
            let token = timing.token
            if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }

            let startsNewWord = isWordBoundary(token) || currentWord.isEmpty

            if startsNewWord && !currentWord.isEmpty {
                let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    words.append(WordTiming(word: trimmed, start: wordStart, end: wordEnd))
                }
                currentWord = ""
            }

            if startsNewWord {
                currentWord = stripWordBoundaryPrefix(token)
                wordStart = timing.startTime
            } else {
                currentWord += token
            }
            wordEnd = timing.endTime
        }

        let lastTrimmed = currentWord.trimmingCharacters(in: .whitespaces)
        if !lastTrimmed.isEmpty {
            words.append(WordTiming(word: lastTrimmed, start: wordStart, end: wordEnd))
        }

        guard !words.isEmpty else { return [] }

        // Phase 2: Group words into sentence segments (split at sentence-ending punctuation or pause > 0.8s)
        let sentenceEndings: Set<Character> = [".", "?", "!"]
        let pauseThreshold: Double = 0.8

        var segments: [PluginTranscriptionSegment] = []
        var segmentWords: [String] = []
        var segmentStart: Double = words[0].start
        var segmentEnd: Double = words[0].end

        for i in 0..<words.count {
            let word = words[i]
            segmentWords.append(word.word)
            segmentEnd = word.end

            let isSentenceEnd = word.word.last.map { sentenceEndings.contains($0) } ?? false
            let hasLongPause = i + 1 < words.count && (words[i + 1].start - word.end) > pauseThreshold
            let isLast = i == words.count - 1

            if isSentenceEnd || hasLongPause || isLast {
                let text = segmentWords.joined(separator: " ")
                segments.append(PluginTranscriptionSegment(text: text, start: segmentStart, end: segmentEnd))
                segmentWords = []
                if i + 1 < words.count {
                    segmentStart = words[i + 1].start
                }
            }
        }

        return segments
    }

    // MARK: - Vocabulary Boosting

    fileprivate func downloadCtcModel() async {
        ctcModelState = .downloading
        do {
            let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let cacheDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(from: cacheDir)
            ctcModels = models
            ctcTokenizer = tokenizer
            ctcModelState = .ready
        } catch {
            ctcModelState = .error(error.localizedDescription)
        }
    }

    private func configureBoostingIfNeeded(prompt: String?) async {
        guard vocabularyBoostingEnabled else { return }

        if prompt == lastConfiguredPrompt { return }
        lastConfiguredPrompt = prompt

        guard let prompt, !prompt.isEmpty else {
            clearConfiguredVocabulary()
            return
        }

        if ctcModels == nil {
            await downloadCtcModel()
        }
        guard let ctcModels, let ctcTokenizer else {
            lastConfiguredPrompt = nil
            return
        }

        let termStrings = prompt.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let terms = termStrings.compactMap { text -> CustomVocabularyTerm? in
            let ids = ctcTokenizer.encode(text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(text: text, weight: 10.0, ctcTokenIds: ids)
        }

        guard !terms.isEmpty else {
            clearConfiguredVocabulary()
            return
        }

        let cappedTerms = Array(terms.prefix(256))
        let vocab = CustomVocabularyContext(terms: cappedTerms)
        let blankId = ctcModels.vocabulary.count
        let spotter = CtcKeywordSpotter(models: ctcModels, blankId: blankId)
        let ctcModelDir = CtcModels.defaultCacheDirectory(for: ctcModels.variant)
        do {
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: vocab,
                ctcModelDirectory: ctcModelDir
            )
            customVocabulary = vocab
            ctcSpotter = spotter
            vocabularyRescorer = rescorer
            vocabSizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: cappedTerms.count)
            lastBoostingTermCount = cappedTerms.count
        } catch {
            clearConfiguredVocabulary()
            lastBoostingTermCount = 0
            lastConfiguredPrompt = nil
        }
    }

    private func applyVocabularyRescoringIfNeeded(
        to result: ASRResult,
        audioSamples: [Float]
    ) async -> ASRResult {
        guard vocabularyBoostingEnabled,
              let spotter = ctcSpotter,
              let rescorer = vocabularyRescorer,
              let vocab = customVocabulary,
              let tokenTimings = result.tokenTimings,
              !tokenTimings.isEmpty
        else {
            return result
        }

        do {
            let spotResult = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: audioSamples,
                customVocabulary: vocab,
                minScore: nil
            )
            guard !spotResult.logProbs.isEmpty else { return result }

            let vocabConfig = vocabSizeConfig
                ?? ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count)
            let rescoreOutput = rescorer.ctcTokenRescore(
                transcript: result.text,
                tokenTimings: tokenTimings,
                logProbs: spotResult.logProbs,
                frameDuration: spotResult.frameDuration,
                cbw: vocabConfig.cbw,
                marginSeconds: 0.5,
                minSimilarity: max(vocabConfig.minSimilarity, vocab.minSimilarity)
            )

            guard rescoreOutput.wasModified else { return result }

            let detectedTerms = spotResult.detections.map(\.term.text)
            let appliedTerms = rescoreOutput.replacements.compactMap { replacement in
                replacement.shouldReplace ? replacement.replacementWord : nil
            }
            Self.logger.info(
                "Vocabulary rescoring applied \(rescoreOutput.replacements.count) replacement(s)"
            )
            return result.withRescoring(
                text: rescoreOutput.text,
                detected: detectedTerms,
                applied: appliedTerms
            )
        } catch {
            Self.logger.warning("Vocabulary rescoring failed: \(error.localizedDescription)")
            return result
        }
    }

    fileprivate func setBoostingEnabled(_ enabled: Bool) {
        vocabularyBoostingEnabled = enabled
        host?.setUserDefault(enabled, forKey: "vocabularyBoostingEnabled")
        if !enabled {
            clearConfiguredVocabulary()
        }
    }

    private func clearConfiguredVocabulary() {
        ctcSpotter = nil
        customVocabulary = nil
        vocabularyRescorer = nil
        vocabSizeConfig = nil
        lastConfiguredPrompt = nil
        lastBoostingTermCount = 0
    }

    private func clearVocabularyBoostingState(resetModelState: Bool = false) {
        clearConfiguredVocabulary()
        ctcModels = nil
        ctcTokenizer = nil
        if resetModelState {
            ctcModelState = .notDownloaded
        }
    }

    // MARK: - Model Management

    fileprivate func loadModel() async {
        modelState = .downloading
        downloadProgress = 0.1

        do {
            let models = try await AsrModels.downloadAndLoad(version: selectedVersion.asrModelVersion)
            downloadProgress = 0.7

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            downloadProgress = 1.0

            asrManager = manager
            loadedModelId = selectedVersion.modelDef.id
            modelState = .ready

            host?.setUserDefault(selectedVersion.modelDef.id, forKey: "loadedModel")
            host?.setUserDefault(selectedVersion.rawValue, forKey: "selectedVersion")
            host?.notifyCapabilitiesChanged()

            if vocabularyBoostingEnabled {
                let cacheDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
                if CtcModels.modelsExist(at: cacheDir) {
                    await downloadCtcModel()
                }
            }
        } catch {
            modelState = .error(error.localizedDescription)
            downloadProgress = 0
        }
    }

    @objc func triggerAutoUnload() { unloadModel(clearPersistence: false) }
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel(allowDownloads: true) } }

    func unloadModel(clearPersistence: Bool = true) {
        clearVocabularyBoostingState(resetModelState: true)
        asrManager = nil
        loadedModelId = nil
        modelState = .notLoaded
        downloadProgress = 0
        if clearPersistence {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    func restoreLoadedModel(allowDownloads: Bool = true) async {
        guard let savedModelId = host?.userDefault(forKey: "loadedModel") as? String else {
            return
        }
        // Infer version from persisted model ID for backwards compatibility
        if let version = ParakeetVersion.from(modelId: savedModelId) {
            selectedVersion = version
        }
        guard allowDownloads || isModelDownloaded(version: selectedVersion) else { return }
        await loadModel()
    }

    private func isModelDownloaded(version: ParakeetVersion) -> Bool {
        let cacheDir = AsrModels.defaultCacheDirectory(for: version.asrModelVersion)
        return AsrModels.modelsExist(at: cacheDir, version: version.asrModelVersion)
    }

    // MARK: - Settings View

    var currentSettingsActivity: PluginSettingsActivity? {
        switch modelState {
        case .notLoaded, .ready:
            break
        case .downloading:
            return PluginSettingsActivity(
                message: "Downloading model",
                progress: downloadProgress
            )
        case .error(let message):
            return PluginSettingsActivity(message: message, isError: true)
        }

        switch ctcModelState {
        case .notDownloaded, .ready:
            return nil
        case .downloading:
            return PluginSettingsActivity(message: "Downloading vocabulary model")
        case .error(let message):
            return PluginSettingsActivity(message: message, isError: true)
        }
    }

    var settingsView: AnyView? {
        AnyView(ParakeetSettingsView(plugin: self))
    }
}

// MARK: - Model Version

enum ParakeetVersion: String, CaseIterable {
    case v2
    case v3

    var asrModelVersion: AsrModelVersion {
        switch self {
        case .v2: return .v2
        case .v3: return .v3
        }
    }

    var modelDef: ParakeetModelDef {
        switch self {
        case .v2:
            return ParakeetModelDef(
                id: "parakeet-tdt-0.6b-v2",
                displayName: "Parakeet TDT v2",
                sizeDescription: "~600 MB",
                ramRequirement: "8 GB+"
            )
        case .v3:
            return ParakeetModelDef(
                id: "parakeet-tdt-0.6b-v3",
                displayName: "Parakeet TDT v3",
                sizeDescription: "~600 MB",
                ramRequirement: "8 GB+"
            )
        }
    }

    var supportedLanguages: [String] {
        switch self {
        case .v2:
            return ["en"]
        case .v3:
            return ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
        }
    }

    var languageCount: Int {
        supportedLanguages.count
    }

    func settingsDescription(bundle: Bundle) -> String {
        switch self {
        case .v2:
            return String(localized: "NVIDIA Parakeet TDT V2 - extremely fast on Apple Silicon. English only, highest recall. No API key required.", bundle: bundle)
        case .v3:
            return String(localized: "NVIDIA Parakeet TDT - extremely fast on Apple Silicon. 25 European languages, no API key required.", bundle: bundle)
        }
    }

    static func from(modelId: String) -> ParakeetVersion? {
        allCases.first { $0.modelDef.id == modelId }
    }
}

// MARK: - Model Types

struct ParakeetModelDef {
    let id: String
    let displayName: String
    let sizeDescription: String
    let ramRequirement: String
}

enum ParakeetModelState: Equatable {
    case notLoaded
    case downloading
    case ready
    case error(String)
}

enum CtcModelState: Equatable {
    case notDownloaded
    case downloading
    case ready
    case error(String)
}

// MARK: - Settings View

private struct ParakeetSettingsView: View {
    let plugin: ParakeetPlugin
    private let bundle = Bundle(for: ParakeetPlugin.self)
    @State private var selectedVersion: ParakeetVersion = .v3
    @State private var modelState: ParakeetModelState = .notLoaded
    @State private var downloadProgress: Double = 0
    @State private var isPolling = false
    @State private var boostingEnabled: Bool = false
    @State private var ctcModelState: CtcModelState = .notDownloaded
    @State private var boostingTermCount: Int = 0

    private let pollTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Parakeet")
                .font(.headline)

            Text(selectedVersion.settingsDescription(bundle: bundle))
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            // Model version picker
            HStack {
                Text("Model Version", bundle: bundle)
                Spacer()
                Picker("", selection: $selectedVersion) {
                    ForEach(ParakeetVersion.allCases, id: \.self) { version in
                        Text(version.modelDef.displayName).tag(version)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(modelState == .downloading)
            }

            // Model info and action
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedVersion.modelDef.displayName)
                        .font(.body)
                    Text("\(selectedVersion.modelDef.sizeDescription) - RAM: \(selectedVersion.modelDef.ramRequirement)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                switch modelState {
                case .notLoaded:
                    Button(String(localized: "Download & Load", bundle: bundle)) {
                        modelState = .downloading
                        downloadProgress = 0.05
                        isPolling = true
                        Task {
                            await plugin.loadModel()
                            isPolling = false
                            modelState = plugin.modelState
                            downloadProgress = plugin.downloadProgress
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                case .downloading:
                    HStack(spacing: 8) {
                        ProgressView(value: downloadProgress)
                            .frame(width: 80)
                        Text("\(Int(downloadProgress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                    }

                case .ready:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button(String(localized: "Unload", bundle: bundle)) {
                            plugin.unloadModel()
                            modelState = plugin.modelState
                            ctcModelState = plugin.ctcModelState
                            boostingTermCount = 0
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                case .error(let message):
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Button(String(localized: "Retry", bundle: bundle)) {
                            modelState = .downloading
                            isPolling = true
                            Task {
                                await plugin.loadModel()
                                isPolling = false
                                modelState = plugin.modelState
                                downloadProgress = plugin.downloadProgress
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
            .padding(.vertical, 4)

            if case .ready = modelState {
                Divider()
                vocabularyBoostingSection
            }
        }
        .padding()
        .onAppear {
            selectedVersion = plugin.selectedVersion
            modelState = plugin.modelState
            downloadProgress = plugin.downloadProgress
            boostingEnabled = plugin.vocabularyBoostingEnabled
            ctcModelState = plugin.ctcModelState
            boostingTermCount = plugin.lastBoostingTermCount
            if case .downloading = plugin.modelState { isPolling = true }
        }
        .onChange(of: selectedVersion) { _, newVersion in
            guard newVersion != plugin.selectedVersion else { return }
            plugin.selectedVersion = newVersion
            plugin.host?.setUserDefault(newVersion.rawValue, forKey: "selectedVersion")
            if plugin.loadedModelId != nil {
                // Reload with new version
                modelState = .downloading
                downloadProgress = 0.05
                isPolling = true
                Task {
                    plugin.unloadModel(clearPersistence: false)
                    await plugin.loadModel()
                    isPolling = false
                    modelState = plugin.modelState
                    downloadProgress = plugin.downloadProgress
                }
            }
        }
        .onReceive(pollTimer) { _ in
            guard isPolling else { return }
            downloadProgress = plugin.downloadProgress
            let pluginState = plugin.modelState
            if pluginState != .notLoaded {
                modelState = pluginState
            }
            ctcModelState = plugin.ctcModelState
            boostingTermCount = plugin.lastBoostingTermCount
            if case .ready = pluginState { isPolling = false }
            else if case .error = pluginState { isPolling = false }
        }
    }

    @ViewBuilder
    private var vocabularyBoostingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vocabulary Boosting", bundle: bundle)
                .font(.subheadline)
                .fontWeight(.medium)

            Text("Improves recognition of custom terms from your Dictionary using a secondary CTC model.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(isOn: $boostingEnabled) {
                Text("Enable Vocabulary Boosting", bundle: bundle)
            }
            .onChange(of: boostingEnabled) { _, newValue in
                plugin.setBoostingEnabled(newValue)
                ctcModelState = plugin.ctcModelState
            }

            if boostingEnabled {
                HStack(spacing: 6) {
                    switch ctcModelState {
                    case .notDownloaded:
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text("CTC model (~100 MB) - downloads automatically on first use, or:", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Download Now", bundle: bundle)) {
                            isPolling = true
                            Task {
                                await plugin.downloadCtcModel()
                                ctcModelState = plugin.ctcModelState
                                isPolling = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                    case .downloading:
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading CTC model...", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    case .ready:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        if boostingTermCount > 0 {
                            Text("Ready - \(boostingTermCount) terms loaded", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Ready - add terms in Dictionary settings", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                    case .error(let message):
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button(String(localized: "Retry", bundle: bundle)) {
                            isPolling = true
                            Task {
                                await plugin.downloadCtcModel()
                                ctcModelState = plugin.ctcModelState
                                isPolling = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
    }
}
