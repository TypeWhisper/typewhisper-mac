import Foundation
import SwiftUI
import FluidAudio
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(ParakeetPlugin)
final class ParakeetPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.parakeet"
    static let pluginName = "Parakeet"

    fileprivate var host: HostServices?
    fileprivate var asrManager: AsrManager?
    fileprivate var loadedModelId: String?
    fileprivate var modelState: ParakeetModelState = .notLoaded
    fileprivate var downloadProgress: Double = 0

    // Vocabulary Boosting
    fileprivate var ctcModels: CtcModels?
    fileprivate var ctcTokenizer: CtcTokenizer?
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
        Task { await restoreLoadedModel() }
    }

    func deactivate() {
        asrManager?.disableVocabularyBoosting()
        ctcModels = nil
        ctcTokenizer = nil
        ctcModelState = .notDownloaded
        lastConfiguredPrompt = nil
        lastBoostingTermCount = 0
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
        guard loadedModelId != nil else { return [] }
        return [PluginModelInfo(
            id: Self.modelDef.id,
            displayName: Self.modelDef.displayName,
            sizeDescription: Self.modelDef.sizeDescription,
            languageCount: 25
        )]
    }

    var selectedModelId: String? { loadedModelId }

    func selectModel(_ modelId: String) {
        // Only one model, no-op
    }

    var supportsTranslation: Bool { false }

    var supportedLanguages: [String] {
        ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
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

        let result = try await asrManager.transcribe(audio.samples, source: .system)

        let segments: [PluginTranscriptionSegment]
        if let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty {
            segments = Self.groupTokensIntoSegments(tokenTimings)
        } else {
            segments = []
        }

        return PluginTranscriptionResult(text: result.text, detectedLanguage: nil, segments: segments)
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
        guard vocabularyBoostingEnabled, let asrManager else { return }

        if prompt == lastConfiguredPrompt { return }
        lastConfiguredPrompt = prompt

        guard let prompt, !prompt.isEmpty else {
            asrManager.disableVocabularyBoosting()
            lastBoostingTermCount = 0
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
            asrManager.disableVocabularyBoosting()
            lastBoostingTermCount = 0
            return
        }

        let cappedTerms = Array(terms.prefix(256))
        let vocab = CustomVocabularyContext(terms: cappedTerms)
        do {
            try await asrManager.configureVocabularyBoosting(vocabulary: vocab, ctcModels: ctcModels)
            lastBoostingTermCount = cappedTerms.count
        } catch {
            lastBoostingTermCount = 0
            lastConfiguredPrompt = nil
        }
    }

    fileprivate func setBoostingEnabled(_ enabled: Bool) {
        vocabularyBoostingEnabled = enabled
        host?.setUserDefault(enabled, forKey: "vocabularyBoostingEnabled")
        if !enabled {
            asrManager?.disableVocabularyBoosting()
            lastConfiguredPrompt = nil
            lastBoostingTermCount = 0
        }
    }

    // MARK: - Model Management

    fileprivate func loadModel() async {
        modelState = .downloading
        downloadProgress = 0.1

        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            downloadProgress = 0.7

            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            downloadProgress = 1.0

            asrManager = manager
            loadedModelId = Self.modelDef.id
            modelState = .ready

            host?.setUserDefault(Self.modelDef.id, forKey: "loadedModel")
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
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel() } }

    func unloadModel(clearPersistence: Bool = true) {
        asrManager?.disableVocabularyBoosting()
        ctcModels = nil
        ctcTokenizer = nil
        ctcModelState = .notDownloaded
        lastConfiguredPrompt = nil
        lastBoostingTermCount = 0
        asrManager = nil
        loadedModelId = nil
        modelState = .notLoaded
        downloadProgress = 0
        if clearPersistence {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    func restoreLoadedModel() async {
        guard host?.userDefault(forKey: "loadedModel") as? String != nil else {
            return
        }
        await loadModel()
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(ParakeetSettingsView(plugin: self))
    }

    // MARK: - Model Definition

    static let modelDef = ParakeetModelDef(
        id: "parakeet-tdt-0.6b-v3",
        displayName: "Parakeet TDT v3",
        sizeDescription: "~600 MB",
        ramRequirement: "8 GB+"
    )
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

            Text("NVIDIA Parakeet TDT - extremely fast on Apple Silicon. 25 European languages, no API key required.", bundle: bundle)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ParakeetPlugin.modelDef.displayName)
                        .font(.body)
                    Text("\(ParakeetPlugin.modelDef.sizeDescription) - RAM: \(ParakeetPlugin.modelDef.ramRequirement)")
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
            modelState = plugin.modelState
            downloadProgress = plugin.downloadProgress
            boostingEnabled = plugin.vocabularyBoostingEnabled
            ctcModelState = plugin.ctcModelState
            boostingTermCount = plugin.lastBoostingTermCount
            if case .downloading = plugin.modelState { isPolling = true }
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
