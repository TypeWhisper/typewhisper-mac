import Combine
import Foundation
import CoreML
import OSLog
import SwiftUI
import FluidAudio
@_spi(FirstPartyPlugins) import TypeWhisperPluginSDK

actor AsyncTranscriptionGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Callers queued behind the current holder.
    var waitingCount: Int { waiters.count }

    func withLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}

/// Publishes preparation synchronously, joins repeated requests, and prevents an
/// old model's completion from clearing a newer model's preparation activity.
final class ParakeetModelPrewarm: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (id: UUID, task: Task<Void, Never>)?

    var isRunning: Bool { lock.withLock { pending != nil } }
    var task: Task<Void, Never>? { lock.withLock { pending?.task } }

    func start(_ operation: @Sendable @escaping () async throws -> Void) {
        lock.withLock {
            guard pending == nil else { return }
            let id = UUID()
            let task = Task { [weak self] in
                defer { self?.finish(id) }
                do {
                    try Task.checkCancellation()
                    try await operation()
                } catch {
                    // Preparation is best-effort. A real transcription retries
                    // inference and reports its own error if it still fails.
                }
            }
            pending = (id, task)
        }
    }

    func wait() async {
        await task?.value
    }

    func cancel() {
        let task = lock.withLock {
            let task = pending?.task
            pending = nil
            return task
        }
        task?.cancel()
    }

    private func finish(_ id: UUID) {
        lock.withLock {
            if pending?.id == id { pending = nil }
        }
    }
}

// MARK: - Plugin Entry Point

@objc(ParakeetPlugin)
final class ParakeetPlugin: NSObject, DictionaryTermHintSourceProgressTranscriptionEnginePlugin, DictionaryTermsSettingEnabling, TranscriptPreviewFallbackPolicyProviding, PluginSettingsActivityReporting, PassiveModelRestoreProviding, TransientModelSelectionProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.parakeet"
    static let pluginName = "Parakeet"
    static let vocabularyAssetFileName = "parakeet_vocab.json"
    private static let logger = Logger(subsystem: "com.typewhisper.plugin.parakeet", category: "Transcription")
    private static let shortClipConfidenceThreshold: Float = 0.55
    private static let shortClipConfidenceGateDuration: TimeInterval = 1.0
    private static let fluidAudioProgressMinimumSampleCount = 240_000
    // Share the configuration so warmup scales with the actual worker pool.
    private static let asrConfiguration = ASRConfig(melChunkContext: true)
    typealias VocabularyAssetFetcher = @Sendable (_ url: URL, _ description: String) async throws -> Data

    fileprivate var host: HostServices?
    fileprivate var asrManager: AsrManager?
    fileprivate var loadedAsrModels: AsrModels?
    fileprivate(set) var loadedModelId: String?
    fileprivate var _selectedModelId: String?
    var modelState: ParakeetModelState = .notLoaded
    fileprivate var downloadProgress: Double = 0
    fileprivate var selectedVersion: ParakeetVersion = .ultra
    fileprivate var _hfToken: String?
    var restoresModelOnActivate = true

    // Vocabulary Boosting
    var ctcModels: CtcModels? {
        didSet { ctcPrewarmInference = ctcModels.map(Self.makeCtcPrewarmInference) }
    }
    /// Captures only the loaded CTC models, independently of dictionary terms.
    var ctcPrewarmInference: (@Sendable ([Float]) async throws -> Void)?
    var ctcTokenizer: CtcTokenizer?
    fileprivate var ctcSpotter: CtcKeywordSpotter?
    fileprivate var customVocabulary: CustomVocabularyContext?
    fileprivate var vocabularyRescorer: VocabularyRescorer?
    fileprivate var vocabSizeConfig: ContextBiasingConstants.VocabSizeConfig?
    fileprivate var vocabularyBoostingEnabled: Bool = false
    private let transcriptionGate = AsyncTranscriptionGate()
    private let modelPrewarm = ParakeetModelPrewarm()
    /// Replaces only inference, preserving preparation, serialization and result handling.
    var asrTranscriptionOverrideForTests: (@Sendable ([Float]) async throws -> ASRResult)?
    /// Serializes every CTC model download, so file-only and in-memory downloads
    /// never overlap or overwrite each other's state.
    let ctcDownloadGate = AsyncTranscriptionGate()
    var ctcModelState: CtcModelState = .notDownloaded
    /// Test hook replacing the CTC download I/O while keeping `ctcDownloadGate`.
    /// Receives whether the model would also be loaded into memory.
    var ctcModelDownloadOverrideForTests: (@Sendable (_ loadIntoMemory: Bool) async -> Void)?
    /// Test hook replacing the Parakeet model download and Core ML load while
    /// keeping `modelLoadGate` and the state updates around them.
    var asrModelLoadOverrideForTests: (@Sendable (_ version: ParakeetVersion) async throws -> Void)?
    var lastConfiguredPrompt: String?
    var lastBoostingTermCount: Int = 0

    private let passiveRestoreController = PluginPassiveModelRestoreController()
    private let modelLoadGate = PluginLocalInferenceGate()
    /// A model the host uses in place of the user's selection, which is never saved.
    /// `_selectedModelId` and `selectedVersion` follow it while it lasts.
    let transientSelection = PluginTransientModelSelection()
    private var versionBeforeTransientSelection: ParakeetVersion?

    func requestPassiveModelRestore() {
        passiveRestoreController.request { [weak self] in
            guard let self, self.restoresModelOnActivate else { return }
            await self.restoreLoadedModel(allowDownloads: false, passively: true)
        }
    }

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
        _hfToken = PluginHuggingFaceTokenHelper.loadToken(from: host)
        vocabularyBoostingEnabled = host.userDefault(forKey: "vocabularyBoostingEnabled") as? Bool ?? false
        if let versionString = host.userDefault(forKey: "selectedVersion") as? String,
           let version = ParakeetVersion(rawValue: versionString) {
            selectedVersion = version
        }
        if let selectedModelId = _selectedModelId,
           let version = ParakeetVersion.from(modelId: selectedModelId) {
            selectedVersion = version
        } else if let persistedLoadedModel = host.userDefault(forKey: "loadedModel") as? String,
                  !persistedLoadedModel.isEmpty {
            _selectedModelId = persistedLoadedModel
            host.setUserDefault(persistedLoadedModel, forKey: "selectedModel")
            if let version = ParakeetVersion.from(modelId: persistedLoadedModel) {
                selectedVersion = version
            }
        }
        if restoresModelOnActivate, host.shouldRestoreLoadedModelsPassively {
            requestPassiveModelRestore()
        }
    }

    func deactivate() {
        transientSelection.end()
        versionBeforeTransientSelection = nil
        passiveRestoreController.cancel()
        modelPrewarm.cancel()
        clearVocabularyBoostingState(resetModelState: true)
        asrManager = nil
        loadedAsrModels = nil
        loadedModelId = nil
        _selectedModelId = nil
        modelState = .notLoaded
        _hfToken = nil
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "parakeet" }
    var providerDisplayName: String { "Parakeet" }

    var isConfigured: Bool {
        asrManager != nil && loadedModelId != nil
    }

    var canDismissSettingsAfterSetup: Bool {
        if case .ready = modelState {
            return true
        }
        return false
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

    var selectedModelId: String? { transientSelection.modelId ?? _selectedModelId }
    var allowsTranscriptPreviewFallback: Bool { true }
    var supportsStreaming: Bool { true }

    func selectModel(_ modelId: String) {
        guard let version = ParakeetVersion.from(modelId: modelId) else { return }
        if transientSelection.modelId != nil {
            saveUserSelection(version)
            return
        }
        let revision = transientSelection.revision
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
        if version == selectedVersion && loadedModelId == modelId { return }
        Task {
            // A transient selection that began meanwhile keeps its model in use.
            guard transientSelection.revision == revision else {
                saveUserSelection(version)
                return
            }
            unloadModel(clearPersistence: false)
            selectedVersion = version
            _selectedModelId = modelId
            host?.setUserDefault(modelId, forKey: "selectedModel")
            host?.setUserDefault(version.rawValue, forKey: "selectedVersion")
            await loadModel(requestedAt: revision)
        }
    }

    // MARK: - Transient Model Selection

    var transientModelId: String? { transientSelection.modelId }

    func beginTransientModelSelection(_ modelId: String) {
        guard host != nil, let version = ParakeetVersion.from(modelId: modelId) else { return }
        let wasTransient = transientSelection.modelId != nil
        guard transientSelection.begin(version.modelDef.id) else { return }
        if !wasTransient {
            versionBeforeTransientSelection = selectedVersion
        }
        _selectedModelId = version.modelDef.id
        selectedVersion = version
        if loadedModelId != nil, loadedModelId != version.modelDef.id {
            unloadModel(clearPersistence: false)
        } else {
            host?.notifyCapabilitiesChanged()
        }
        requestPassiveRestoreOfSelection()
    }

    func endTransientModelSelection() {
        guard let host, transientSelection.end() != nil else { return }
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
        selectedVersion = _selectedModelId.flatMap(ParakeetVersion.from(modelId:))
            ?? (host.userDefault(forKey: "selectedVersion") as? String).flatMap(ParakeetVersion.init(rawValue:))
            ?? versionBeforeTransientSelection
            ?? selectedVersion
        versionBeforeTransientSelection = nil
        // Only the model the user loaded last stays loaded, as after a relaunch.
        if loadedModelId != nil, loadedModelId != host.userDefault(forKey: "loadedModel") as? String {
            unloadModel(clearPersistence: false)
        } else {
            host.notifyCapabilitiesChanged()
        }
        requestPassiveRestoreOfSelection()
    }

    /// Saves a model the user chose while a transient model is in use; it applies once that ends.
    private func saveUserSelection(_ version: ParakeetVersion) {
        host?.setUserDefault(version.modelDef.id, forKey: "selectedModel")
        host?.setUserDefault(version.rawValue, forKey: "selectedVersion")
    }

    /// Loads the model now in use from installed files, if the host keeps models loaded.
    private func requestPassiveRestoreOfSelection() {
        guard host?.shouldRestoreLoadedModelsPassively == true else { return }
        requestPassiveModelRestore()
    }

    var supportsTranslation: Bool { false }
    var dictionaryTermsSupport: DictionaryTermsSupport {
        vocabularyBoostingEnabled ? .supported : .requiresPluginSetting
    }

    var dictionaryTermsSettingSummary: String {
        String(
            localized: "Parakeet recognizes your terms better with Vocabulary Boosting (about 100 MB download).",
            bundle: Bundle(for: ParakeetPlugin.self)
        )
    }

    /// Turns on Vocabulary Boosting and fetches its CTC model, so the first dictation
    /// after enabling does not wait for the download.
    func enableDictionaryTermsSetting() async throws {
        setBoostingEnabled(true)
        try await prepareVocabularyBoostingModel()
        host?.notifyCapabilitiesChanged()
    }

    var supportedLanguages: [String] {
        selectedVersion.supportedLanguages
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        try await transcribe(
            audio: audio,
            language: language,
            translate: translate,
            prompt: prompt,
            onProgress: { _ in true },
            onSourceProgress: { _ in true }
        )
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> PluginTranscriptionResult {
        // Join the synchronously published task before acquiring the gate: the
        // warmup task may not have been scheduled yet when recording stops.
        await modelPrewarm.wait()
        return try await transcriptionGate.withLock {
            try await transcribeSerially(
                audio: audio,
                language: language,
                translate: translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints,
                onProgress: onProgress,
                onSourceProgress: onSourceProgress
            )
        }
    }

    private func transcribeSerially(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let asrManager else {
            throw PluginTranscriptionError.notConfigured
        }

        if translate {
            throw PluginTranscriptionError.apiError("Parakeet does not support translation")
        }

        if vocabularyBoostingEnabled {
            await configureBoostingIfNeeded(prompt: prompt, dictionaryTermHints: dictionaryTermHints)
        }

        let normalizedSamples = PluginAudioUtils.paddedSamples(
            audio.samples,
            minimumDuration: 1.0,
            sampleRate: 16_000
        )
        let loadedVersion = loadedModelId.flatMap(ParakeetVersion.from(modelId:)) ?? selectedVersion
        let fluidLanguage = loadedVersion.acceptsLanguageHint ? Self.fluidAudioLanguage(for: language) : nil
        let progressTask: Task<Void, Never>? = if Self.shouldObserveSourceProgress(sampleCount: normalizedSamples.count) {
            Task { [asrManager, duration = audio.duration, onSourceProgress] in
                let stream = await asrManager.transcriptionProgressStream
                do {
                    for try await fraction in stream {
                        guard !Task.isCancelled else { break }
                        guard let progress = Self.sourceProgress(fromFraction: fraction, totalDuration: duration) else {
                            continue
                        }
                        if !onSourceProgress(progress) {
                            break
                        }
                    }
                } catch {
                    // The transcription task reports the underlying error; progress is best-effort.
                }
            }
        } else {
            nil
        }
        defer { progressTask?.cancel() }

        let result = try await runInference(
            normalizedSamples,
            manager: asrManager,
            language: fluidLanguage
        )
        let finalResult = await applyVocabularyRescoringIfNeeded(
            to: result,
            audioSamples: normalizedSamples
        )
        let text = Self.removingUnknownTokens(from: finalResult.text)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

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
            let words = Self.groupTokensIntoWords(tokenTimings)
            segments = Self.groupWordsIntoSegments(words)
            PluginWordTimings.report(words)
        } else {
            segments = []
        }

        _ = onProgress(trimmedText)
        return PluginTranscriptionResult(text: trimmedText, detectedLanguage: nil, segments: segments)
    }

    /// Parakeet's vocabulary has no token for a few characters, mostly "&", brackets and some
    /// quotes. v3 never writes them, but Ultra learned to and emits "<unk>" in their place
    /// ("M<unk>A", "spectroscopy <unk> FTIR"). Between capitals it stands for "&" (M&A, P&L,
    /// R&D); elsewhere it is dropped, so the marker never reaches the user's text.
    static func removingUnknownTokens(from text: String) -> String {
        let marker = "<unk>"
        guard text.contains(marker) else { return text }
        var cleaned = text
            .replacingOccurrences(of: "(?<=\\p{Lu})<unk>(?=\\p{Lu})", with: "&", options: .regularExpression)
            .replacingOccurrences(of: "(?<=\\w)<unk>(?=\\w)", with: "", options: .regularExpression)
            .replacingOccurrences(of: marker, with: " ")
        cleaned = cleaned
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +([,.;:!?)\\]}…])", with: "$1", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    private func runInference(_ samples: [Float], manager: AsrManager, language: Language?) async throws -> ASRResult {
        if let asrTranscriptionOverrideForTests {
            return try await asrTranscriptionOverrideForTests(samples)
        }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &decoderState, language: language)
    }

    /// Optional host selector, so older hosts/plugins remain compatible. A loaded
    /// MLModel can lose its device-specialized cache under disk pressure (#1605).
    /// Exercise the real inference path while the user speaks, without depending
    /// on Apple's private cache layout or publishing a synthetic transcript.
    @objc func triggerPrewarmModel() {
        guard let manager = asrManager, isConfigured else { return }
        let prepareCtc = vocabularyBoostingEnabled ? ctcPrewarmInference : nil
        modelPrewarm.start { [self] in
            try await transcriptionGate.withLock { [self] in
                let started = ContinuousClock.now
                do {
                    // A single short prediction may reuse a surviving execution
                    // stream. Exercise ChunkProcessor and its full worker pool,
                    // which share the loaded MLModels but predict concurrently.
                    // All-silent input is kept in full by FluidAudio's chunker.
                    let sampleCount = ASRConstants.maxModelSamples * max(2, Self.asrConfiguration.parallelChunkConcurrency)
                    _ = try await runInference([Float](repeating: 0, count: sampleCount), manager: manager, language: nil)
                    try Task.checkCancellation()
                    if vocabularyBoostingEnabled, let prepareCtc {
                        try await prepareCtc([Float](repeating: 0, count: ASRConstants.sampleRate))
                    }
                    Self.logger.info("Model preparation finished in \(String(describing: ContinuousClock.now - started), privacy: .public)")
                } catch {
                    Self.logger.notice("Model preparation did not finish; the next transcription will retry")
                    throw error
                }
            }
        }
    }

    func waitForModelPrewarm() async {
        await modelPrewarm.wait()
    }

    private static func makeCtcPrewarmInference(models: CtcModels) -> @Sendable ([Float]) async throws -> Void {
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        return { samples in
            // Empty terms still run mel + encoder inference, without configuring
            // vocabulary, rescoring synthetic text, or downloading any assets.
            _ = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples,
                customVocabulary: CustomVocabularyContext(terms: [])
            )
        }
    }

    static func sourceProgress(
        fromFraction fraction: Double,
        totalDuration: TimeInterval
    ) -> PluginTranscriptionSourceProgress? {
        guard fraction.isFinite,
              totalDuration.isFinite,
              totalDuration > 0 else {
            return nil
        }
        let clampedFraction = min(max(fraction, 0), 1)
        return PluginTranscriptionSourceProgress(
            processedDuration: totalDuration * clampedFraction,
            totalDuration: totalDuration
        )
    }

    static func shouldObserveSourceProgress(sampleCount: Int) -> Bool {
        sampleCount > fluidAudioProgressMinimumSampleCount
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

    static func groupTokensIntoWords(_ tokenTimings: [TokenTiming]) -> [PluginWordTiming] {
        var words: [PluginWordTiming] = []
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
                    words.append(PluginWordTiming(text: trimmed, start: wordStart, end: wordEnd))
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
            words.append(PluginWordTiming(text: lastTrimmed, start: wordStart, end: wordEnd))
        }
        // A dropped marker can leave punctuation on its own ("hello <unk>, world", "<unk>(note").
        // Closing punctuation joins the previous word and opening punctuation the next one, so
        // the words do not read "hello , world" or "hello( note".
        var cleaned: [PluginWordTiming] = []
        var opening: PluginWordTiming?
        for word in words {
            var text = removingUnknownTokens(from: word.text)
            guard !text.isEmpty else { continue }
            let leftByMarker = text != word.text
            if leftByMarker, text.allSatisfy(closingPunctuation.contains), let previous = cleaned.popLast() {
                cleaned.append(PluginWordTiming(text: previous.text + text, start: previous.start, end: word.end))
                continue
            }
            if leftByMarker, text.allSatisfy(openingPunctuation.contains) {
                opening = PluginWordTiming(text: (opening?.text ?? "") + text, start: opening?.start ?? word.start, end: word.end)
                continue
            }
            var start = word.start
            if let pending = opening {
                text = pending.text + text
                start = pending.start
                opening = nil
            }
            cleaned.append(text == word.text ? word : PluginWordTiming(text: text, start: start, end: word.end))
        }
        if let opening { cleaned.append(opening) }
        return cleaned
    }

    /// Same characters as the spacing rule in `removingUnknownTokens(from:)`.
    private static let closingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "…"]
    private static let openingPunctuation: Set<Character> = ["(", "[", "{"]

    /// Groups words into sentence segments (split at sentence-ending punctuation or pause > 0.8s).
    static func groupWordsIntoSegments(_ words: [PluginWordTiming]) -> [PluginTranscriptionSegment] {
        guard !words.isEmpty else { return [] }

        let sentenceEndings: Set<Character> = [".", "?", "!"]
        let pauseThreshold: Double = 0.8

        var segments: [PluginTranscriptionSegment] = []
        var segmentWords: [String] = []
        var segmentStart: Double = words[0].start
        var segmentEnd: Double = words[0].end

        for i in 0..<words.count {
            let word = words[i]
            segmentWords.append(word.text)
            segmentEnd = word.end

            let isSentenceEnd = word.text.last.map { sentenceEndings.contains($0) } ?? false
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

    /// Downloads and loads the CTC model, waiting for any CTC download in progress.
    func downloadCtcModel() async {
        _ = try? await ctcDownloadGate.withLock { [self] in
            await performCtcModelDownload(loadIntoMemory: true)
        }
    }

    /// Loads already downloaded CTC files after a model load. Skipped when the
    /// model was unloaded while waiting for a CTC download in progress.
    private func loadDownloadedCtcModel() async {
        _ = try? await ctcDownloadGate.withLock { [self] in
            guard isConfigured else { return ctcModelState }
            return await performCtcModelDownload(loadIntoMemory: true, onlyIfDownloaded: true)
        }
    }

    /// Loads the CTC model when Parakeet is loaded. Otherwise only its files are
    /// downloaded; the next model load picks them up without holding memory now.
    /// A download already running from the settings view or a first transcription
    /// finishes first, and the decision is made again afterwards.
    func prepareVocabularyBoostingModel() async throws {
        let state = try await ctcDownloadGate.withLock { [self] in
            await performCtcModelDownload(loadIntoMemory: isConfigured)
        }
        if case .error(let message) = state {
            throw ParakeetVocabularyBoostingError(message: message)
        }
    }

    /// Call only while holding `ctcDownloadGate`. Returns the resulting state.
    private func performCtcModelDownload(loadIntoMemory: Bool, onlyIfDownloaded: Bool = false) async -> CtcModelState {
        guard ctcModels == nil else { return ctcModelState }

        let cacheDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
        let downloadRefusal = host?.modelDownloadRefusal
        if let downloadRefusal, !onlyIfDownloaded, !CtcModels.modelsExist(at: cacheDir) {
            ctcModelState = .error(downloadRefusal)
            return ctcModelState
        }

        if let ctcModelDownloadOverrideForTests {
            await ctcModelDownloadOverrideForTests(loadIntoMemory)
            return ctcModelState
        }

        if onlyIfDownloaded, !CtcModels.modelsExist(at: cacheDir) {
            return ctcModelState
        }

        ctcModelState = .downloading
        do {
            applyHuggingFaceTokenToEnvironment()
            let spaceReservation = try await reserveCtcDownloadSpace()
            defer { spaceReservation?.release() }
            if loadIntoMemory {
                // FluidAudio's loader may repair the cache by downloading; while downloads
                // are refused, load the installed files directly.
                let models = downloadRefusal == nil
                    ? try await CtcModels.downloadAndLoad(variant: .ctc110m)
                    : try await CtcModels.loadDirect(from: cacheDir, variant: .ctc110m)
                let tokenizer = try await CtcTokenizer.load(from: cacheDir)
                ctcModels = models
                ctcTokenizer = tokenizer
                ctcModelState = .ready
            } else {
                try await CtcModels.download(variant: .ctc110m)
                // Only the files are cached. Never replace a state another path
                // set meanwhile, such as an unload resetting it.
                if ctcModelState == .downloading {
                    ctcModelState = .notDownloaded
                }
            }
        } catch {
            ctcModelState = .error(error.localizedDescription)
        }
        return ctcModelState
    }

    static func vocabularyHints(
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint]
    ) -> [PluginDictionaryTermHint] {
        if !dictionaryTermHints.isEmpty {
            return PluginDictionaryTerms.normalizedTermHints(from: dictionaryTermHints)
        }
        return PluginDictionaryTerms.termHints(fromPrompt: prompt)
    }

    static func vocabularySignature(from hints: [PluginDictionaryTermHint]) -> String? {
        guard !hints.isEmpty else { return nil }
        return hints.map {
            let threshold = $0.ctcMinSimilarity.map { String(format: "%.4f", Double($0)) } ?? "auto"
            return "\($0.text)|\(threshold)"
        }.joined(separator: "\u{1F}")
    }

    private func configureBoostingIfNeeded(
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint] = []
    ) async {
        guard vocabularyBoostingEnabled else { return }

        let termHints = Self.vocabularyHints(prompt: prompt, dictionaryTermHints: dictionaryTermHints)
        let signature = Self.vocabularySignature(from: termHints)
        if signature == lastConfiguredPrompt && (signature != nil || customVocabulary == nil) { return }
        lastConfiguredPrompt = signature

        guard !termHints.isEmpty else {
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

        let terms = termHints.compactMap { hint -> CustomVocabularyTerm? in
            let text = hint.text
            let ids = ctcTokenizer.encode(text)
            guard !ids.isEmpty else { return nil }
            return Self.customVocabularyTerm(
                from: hint,
                ctcTokenIds: ids
            )
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
                // Acoustic-only rescue can inject unrelated short dictionary words.
                // Keep the text-similarity gate, including per-term overrides.
                config: VocabularyRescorer.Config(spotterRescueEnabled: false),
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

    static func customVocabularyTerm(
        from hint: PluginDictionaryTermHint,
        ctcTokenIds: [Int]
    ) -> CustomVocabularyTerm {
        CustomVocabularyTerm(
            text: hint.text,
            weight: 10.0,
            ctcTokenIds: ctcTokenIds,
            minSimilarity: hint.ctcMinSimilarity
        )
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
            // The upstream span search can shorten an already-correct phrase,
            // e.g. "uses GitHub Actions" to "GitHub Actions". Its public output
            // has no replacement ranges, so preserve the original transcript if
            // any applied replacement would delete text around an existing term.
            guard !rescoreOutput.replacements.contains(where: { replacement in
                replacement.shouldReplace && replacement.replacementWord.map {
                    Self.removesTextAroundExistingTerm(original: replacement.originalWord, replacement: $0)
                } == true
            }) else { return result }

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

    static func removesTextAroundExistingTerm(original: String, replacement: String) -> Bool {
        // Ignore spelling separators so compounds and split names are protected
        // too, while capitalization/spacing-only corrections remain possible.
        func lettersAndNumbers(_ text: String) -> String {
            String(text.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).filter { $0.isLetter || $0.isNumber })
        }
        let source = lettersAndNumbers(original)
        let term = lettersAndNumbers(replacement)
        return !term.isEmpty && source != term && source.contains(term)
    }

    func setBoostingEnabled(_ enabled: Bool) {
        guard vocabularyBoostingEnabled != enabled else { return }
        vocabularyBoostingEnabled = enabled
        host?.setUserDefault(enabled, forKey: "vocabularyBoostingEnabled")
        if !enabled {
            clearConfiguredVocabulary()
        }
        host?.notifyCapabilitiesChanged()
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

    func loadModel(
        version: ParakeetVersion? = nil,
        passively: Bool = false,
        requestedAt revision: Int? = nil
    ) async {
        let revision = revision ?? transientSelection.revision
        let version = version ?? selectedVersion
        if !passively, let transientModelId = transientSelection.modelId, version.modelDef.id != transientModelId {
            // Chosen in the settings while a transient model is in use: saved for later, not loaded.
            saveUserSelection(version)
            selectedVersion = ParakeetVersion.from(modelId: transientModelId) ?? selectedVersion
            requestPassiveRestoreOfSelection()
            return
        }
        let didLoad = (try? await modelLoadGate.withLock { [self] () -> Bool in
            guard host != nil else { return false }
            guard transientSelection.permitsLoad(of: version.modelDef.id, requestedAt: revision) else { return false }
            if passively {
                guard host?.shouldRestoreLoadedModelsPassively == true, !isConfigured,
                      isModelInstalled(version: version) else { return false }
            }
            guard !(isConfigured && loadedModelId == version.modelDef.id) else { return false }
            return await performModelLoad(version: version, allowDownloads: !passively, requestedAt: revision)
        }) ?? false

        // Optional vocabulary preparation remains on the explicit/first-use path;
        // FluidAudio's CTC loader may repair its cache by downloading assets.
        // It runs outside `modelLoadGate`, so switching models meanwhile does not
        // wait for it with no model loaded.
        if didLoad, !passively, vocabularyBoostingEnabled {
            await loadDownloadedCtcModel()
        }
    }

    /// Returns whether the model was loaded.
    private func performModelLoad(version: ParakeetVersion, allowDownloads: Bool, requestedAt revision: Int) async -> Bool {
        modelState = .downloading
        downloadProgress = 0.1

        do {
            applyHuggingFaceTokenToEnvironment()
            // While downloads are refused, installed files still load locally, as in a passive restore.
            let downloadRefusal = allowDownloads ? host?.modelDownloadRefusal : nil
            if let downloadRefusal, !isModelInstalled(version: version) {
                throw PluginModelDownloadRefusedError(reason: downloadRefusal)
            }
            let models: AsrModels?
            if let asrModelLoadOverrideForTests {
                try await asrModelLoadOverrideForTests(version)
                models = nil
            } else if allowDownloads, downloadRefusal == nil {
                let spaceReservation = isModelDownloaded(version: version)
                    ? nil
                    : try await reserveDownloadSpace(for: version)
                defer { spaceReservation?.release() }
                if version == .fluidSpeechMini {
                    try await installFluidSpeechMini()
                    models = try Self.loadInstalledModels(version: version)
                } else {
                    try await ensureVocabularyAsset(for: version)
                    models = try await AsrModels.downloadAndLoad(
                        version: version.asrModelVersion,
                        progressHandler: { [weak self] progress in
                            guard let self, self.modelState == .downloading,
                                  case .downloading = progress.phase else { return }
                            self.downloadProgress = Self.downloadProgress(
                                after: self.downloadProgress,
                                downloadFraction: progress.fractionCompleted
                            )
                        }
                    )
                }
            } else {
                models = try Self.loadInstalledModels(version: version)
            }
            downloadProgress = 0.7

            // Keep the pre-0.15.7 chunk context: the new v3 default changes
            // punctuation at chunk boundaries in paired long-form recordings.
            let manager = AsrManager(config: Self.asrConfiguration)
            if let models {
                try await manager.loadModels(models)
            }
            downloadProgress = 1.0

            try Task.checkCancellation()
            guard host != nil else { return false }
            var isTransient = false
            let installed = transientSelection.installIfPermitted(version.modelDef.id, requestedAt: revision) { transient in
                isTransient = transient
                selectedVersion = version
                asrManager = manager
                loadedAsrModels = models
                loadedModelId = version.modelDef.id
                _selectedModelId = version.modelDef.id
                modelState = .ready
            }
            guard installed else {
                // The transient selection changed while loading, so another model is in use now.
                modelState = isConfigured ? .ready : .notLoaded
                downloadProgress = 0
                return false
            }

            // A transient model is never saved as the user's selection or as the model to restore.
            if !isTransient {
                host?.setUserDefault(version.modelDef.id, forKey: "selectedModel")
                host?.setUserDefault(version.modelDef.id, forKey: "loadedModel")
                host?.setUserDefault(version.rawValue, forKey: "selectedVersion")
            }
            host?.notifyCapabilitiesChanged()
            return true
        } catch is CancellationError {
            if host != nil { modelState = isConfigured ? .ready : .notLoaded }
            return false
        } catch {
            modelState = .error(error.localizedDescription)
            downloadProgress = 0
            return false
        }
    }

    /// Maps a FluidAudio download-phase fraction onto the 10-70% band that precedes model
    /// loading. FluidAudio spends the first half of each operation on the download and
    /// restarts its fraction for every model file it loads, so the value never moves backwards.
    static func downloadProgress(after current: Double, downloadFraction: Double) -> Double {
        guard downloadFraction.isFinite else { return current }
        let fraction = min(max(downloadFraction * 2, 0), 1)
        return max(current, 0.1 + fraction * 0.6)
    }

    private func installFluidSpeechMini() async throws {
        let token = Self.currentHuggingFaceToken()
        let listFiles: FluidSpeechMini.FileLister = {
            try await FluidSpeechMini.listRemoteFiles(token: token)
        }
        let downloadFile: FluidSpeechMini.FileDownloader = { remotePath, destination in
            try await FluidSpeechMini.downloadRemoteFile(remotePath, to: destination, token: token)
        }
        try await FluidSpeechMini.install(listFiles: listFiles, downloadFile: downloadFile) { [weak self] fraction in
            guard let self, self.modelState == .downloading else { return }
            // The download fills the 10-70% band that precedes model loading.
            self.downloadProgress = max(self.downloadProgress, 0.1 + min(max(fraction, 0), 1) * 0.6)
        }
    }

    /// FluidAudio's high-level loaders can delete and re-download a corrupt cache,
    /// even when every file exists. Passive restore must use local Core ML loading.
    static func loadInstalledModels(version: ParakeetVersion, directory: URL? = nil) throws -> AsrModels {
        let directory = directory ?? version.installDirectory
        let vocabularyURL = directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        let tokens = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: vocabularyURL))
        var vocabulary: [Int: String] = [:]
        for (key, token) in tokens {
            if let id = Int(key) { vocabulary[id] = token }
        }
        guard !vocabulary.isEmpty else {
            throw AsrModelsError.loadingFailed("Installed vocabulary is empty")
        }
        let configuration = AsrModels.defaultConfiguration()
        let preprocessorConfiguration = MLModelConfiguration()
        preprocessorConfiguration.computeUnits = .cpuOnly
        preprocessorConfiguration.allowLowPrecisionAccumulationOnGPU = true
        let jointFile = version.jointFileName
        return try AsrModels(
            encoder: MLModel(contentsOf: directory.appendingPathComponent(ModelNames.ASR.encoderFile), configuration: configuration),
            preprocessor: MLModel(contentsOf: directory.appendingPathComponent(ModelNames.ASR.preprocessorFile), configuration: preprocessorConfiguration),
            decoder: MLModel(contentsOf: directory.appendingPathComponent(ModelNames.ASR.decoderFile), configuration: configuration),
            joint: MLModel(contentsOf: directory.appendingPathComponent(jointFile), configuration: configuration),
            configuration: configuration,
            vocabulary: vocabulary,
            version: version.asrModelVersion
        )
    }

    static func vocabularyAssetURL(for version: ParakeetVersion) -> URL {
        let revision = version == .fluidSpeechMini ? FluidSpeechMini.revision : "main"
        return URL(string: "https://huggingface.co/\(version.huggingFaceRepository)/resolve/\(revision)/\(vocabularyAssetFileName)")!
    }

    static func vocabularyAssetDirectory(for version: ParakeetVersion) -> URL {
        version.installDirectory
    }

    func ensureVocabularyAsset(
        for version: ParakeetVersion,
        targetDirectory: URL? = nil,
        fetcher: VocabularyAssetFetcher = { url, description in
            try await ParakeetPlugin.downloadVocabularyAsset(from: url, description: description)
        }
    ) async throws {
        let directory = targetDirectory ?? Self.vocabularyAssetDirectory(for: version)
        let targetURL = directory.appendingPathComponent(Self.vocabularyAssetFileName, isDirectory: false)
        guard !Self.vocabularyAssetExists(at: targetURL) else { return }

        let vocabularyURL = Self.vocabularyAssetURL(for: version)
        let description = "\(version.modelDef.displayName) vocabulary"
        let data: Data
        do {
            data = try await fetcher(vocabularyURL, description)
        } catch {
            throw ParakeetVocabularyAssetError.downloadFailed(version: version, underlying: error)
        }
        guard !data.isEmpty else {
            throw ParakeetVocabularyAssetError.emptyDownload(version: version)
        }

        let fileManager = FileManager.default
        var installFailureURL = directory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporaryURL = directory.appendingPathComponent(
                ".\(Self.vocabularyAssetFileName).\(UUID().uuidString).tmp",
                isDirectory: false
            )
            installFailureURL = temporaryURL
            do {
                try data.write(to: temporaryURL, options: .atomic)
                if Self.vocabularyAssetExists(at: targetURL) {
                    try? fileManager.removeItem(at: temporaryURL)
                    return
                }
                installFailureURL = targetURL
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileManager.removeItem(at: targetURL)
                }
                try fileManager.moveItem(at: temporaryURL, to: targetURL)
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
        } catch {
            throw ParakeetVocabularyAssetError.installFailed(
                version: version,
                path: installFailureURL,
                underlying: error
            )
        }
    }

    private static func vocabularyAssetExists(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private static func downloadVocabularyAsset(from url: URL, description: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 600
        if let token = currentHuggingFaceToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await PluginHTTPClient.data(for: request, resourceTimeout: 600)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ParakeetVocabularyAssetHTTPError(description: description, statusCode: nil)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ParakeetVocabularyAssetHTTPError(
                description: description,
                statusCode: httpResponse.statusCode
            )
        }
        return data
    }

    private static func currentHuggingFaceToken() -> String? {
        for key in PluginHuggingFaceTokenHelper.environmentKeys {
            if let token = PluginHuggingFaceTokenHelper.normalizedToken(ProcessInfo.processInfo.environment[key]) {
                return token
            }
        }
        return nil
    }

    @objc func triggerAutoUnload() { unloadModel(clearPersistence: false) }

    /// Test hook: when true, restore triggers publish the synchronous in-flight
    /// mark without spawning the async restore task, so tests can assert on the
    /// mark deterministically instead of racing the task's completion.
    var suppressAsyncRestoreForTests = false

    @objc func triggerRestoreModel() {
        markRestoreInFlight()
        guard !suppressAsyncRestoreForTests else { return }
        Task {
            await restoreLoadedModel(allowDownloads: true)
            finishRestoreTrigger()
        }
    }

    @objc(triggerRestoreModelForModel:)
    func triggerRestoreModel(forModel modelId: NSString?) {
        guard let modelId = modelId.map(String.init),
              let version = ParakeetVersion.from(modelId: modelId) else {
            return
        }
        let revision = transientSelection.revision
        let transientModelId = transientSelection.modelId
        if let transientModelId, transientModelId != modelId {
            saveUserSelection(version)
            return
        }
        if loadedModelId != nil, loadedModelId != modelId {
            unloadModel(clearPersistence: false)
        }
        _selectedModelId = modelId
        selectedVersion = version
        if transientModelId == nil {
            host?.setUserDefault(modelId, forKey: "selectedModel")
            host?.setUserDefault(version.rawValue, forKey: "selectedVersion")
        }
        markRestoreInFlight()
        guard !suppressAsyncRestoreForTests else { return }
        Task {
            await loadModel(version: version, requestedAt: revision)
            finishRestoreTrigger()
        }
    }

    /// Marks a restore as in-flight synchronously. The host extends its restore
    /// wait past the base window only while the plugin reports an activity, and
    /// task scheduling can delay the unstructured task above before it publishes
    /// its first state update. Without this mark, the host can time out and
    /// report "no model loaded" for a restore that is still starting.
    private func markRestoreInFlight() {
        guard !isConfigured else { return }
        modelState = .downloading
        downloadProgress = 0
    }

    /// Resolves the in-flight restore mark once the restore task finishes. A
    /// successful load already recorded `.ready` and a failed load already
    /// recorded the underlying `.error`. Only a restore that produced nothing
    /// (e.g. nothing was persisted to restore) needs an explicit error, so the
    /// host surfaces it instead of polling a stale activity until its wait
    /// expires.
    private func finishRestoreTrigger() {
        guard host != nil else { return }
        switch modelState {
        case .ready, .error:
            return
        case .notLoaded, .downloading:
            break
        }
        modelState = isConfigured ? .ready : .error("No previously loaded model to restore.")
    }

    func unloadModel(clearPersistence: Bool = true) {
        modelPrewarm.cancel()
        clearVocabularyBoostingState(resetModelState: true)
        asrManager = nil
        loadedAsrModels = nil
        loadedModelId = nil
        modelState = .notLoaded
        downloadProgress = 0
        // The saved model to restore is the user's, not the transient one in use.
        if clearPersistence, transientSelection.modelId == nil {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    func restoreLoadedModel(allowDownloads: Bool = true, passively: Bool = false) async {
        guard !Task.isCancelled else { return }
        let revision = transientSelection.revision
        if passively {
            guard host?.shouldRestoreLoadedModelsPassively == true, !isConfigured else { return }
        }
        // A transient model replaces the model the user loaded last.
        guard let savedModelId = transientSelection.modelId
            ?? host?.userDefault(forKey: "loadedModel") as? String else { return }
        let version = ParakeetVersion.from(modelId: savedModelId) ?? selectedVersion
        guard allowDownloads || isModelDownloaded(version: version) else { return }
        await loadModel(version: version, passively: passively, requestedAt: revision)
    }

    /// FluidAudio skips complete files and resumes `.partial` files in the cache
    /// directory, so those bytes count toward the download instead of being deleted.
    private func reserveDownloadSpace(for version: ParakeetVersion) async throws -> PluginDownloadSpaceReservation? {
        let cacheDir = version.installDirectory
        if version == .fluidSpeechMini {
            // Files download into the staging folder and move into place when complete.
            let staging = FluidSpeechMini.stagingDirectory(for: cacheDir)
            return try await PluginDownloadDiskSpace.reserveHuggingFaceDownload(
                repositoryID: FluidSpeechMini.repository,
                revision: FluidSpeechMini.revision,
                matching: FluidSpeechMini.filePatterns,
                token: _hfToken,
                destination: cacheDir,
                trackedDirectory: staging,
                localRepositoryRoot: staging,
                modelName: version.modelDef.displayName
            )
        }
        return try await PluginDownloadDiskSpace.reserveHuggingFaceDownload(
            repositoryID: version.huggingFaceRepository,
            matching: version.requiredModelFiles.sorted().map { "\($0)/*" } + ["*vocab*.json"],
            token: _hfToken,
            destination: cacheDir,
            trackedDirectory: cacheDir,
            localRepositoryRoot: cacheDir,
            modelName: version.modelDef.displayName
        )
    }

    private func reserveCtcDownloadSpace() async throws -> PluginDownloadSpaceReservation? {
        let cacheDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
        guard !CtcModels.modelsExist(at: cacheDir) else { return nil }
        return try await PluginDownloadDiskSpace.reserveHuggingFaceDownload(
            repositoryID: CtcModelVariant.ctc110m.repo.remotePath,
            matching: ModelNames.CTC.requiredModels.sorted().map { "\($0)/*" } + [ModelNames.CTC.vocabularyPath],
            token: _hfToken,
            destination: cacheDir,
            trackedDirectory: cacheDir,
            localRepositoryRoot: cacheDir,
            modelName: "Parakeet CTC 110M"
        )
    }

    fileprivate func isModelDownloaded(version: ParakeetVersion) -> Bool {
        if version == .fluidSpeechMini {
            return FluidSpeechMini.isInstalled(at: version.installDirectory)
        }
        return AsrModels.modelsExist(at: version.installDirectory, version: version.asrModelVersion)
    }

    /// Whether `loadInstalledModels` finds everything it needs without downloading.
    private func isModelInstalled(version: ParakeetVersion) -> Bool {
        let vocabularyURL = Self.vocabularyAssetDirectory(for: version)
            .appendingPathComponent(Self.vocabularyAssetFileName)
        return isModelDownloaded(version: version) && Self.vocabularyAssetExists(at: vocabularyURL)
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

        if modelPrewarm.isRunning {
            return PluginSettingsActivity(message: String(localized: "Preparing model", bundle: Bundle(for: Self.self)))
        }

        guard vocabularyBoostingEnabled else { return nil }

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

    var huggingFaceToken: String? { _hfToken }

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

    func applyHuggingFaceTokenToEnvironment() {
        PluginHuggingFaceTokenHelper.applyTokenToEnvironment(_hfToken)
    }
}

// MARK: - Model Version

/// Ordered as offered: Ultra is the default because it is more accurate than v3 and keeps
/// transcribing the person dictating when someone else talks in the background.
enum ParakeetVersion: String, CaseIterable {
    case ultra
    case v3
    case fluidSpeechMini
    case v2

    var asrModelVersion: AsrModelVersion {
        switch self {
        case .v2: return .v2
        case .v3: return .v3
        // Fluid Speech Mini keeps Ultra's decoder, joint network and decode contract.
        case .ultra, .fluidSpeechMini: return .ultra
        }
    }

    /// Hugging Face repository the model files come from.
    var huggingFaceRepository: String {
        switch self {
        case .v2: return Repo.parakeetV2.remotePath
        case .v3: return Repo.parakeetV3.remotePath
        case .ultra: return Repo.parakeetUltra.remotePath
        case .fluidSpeechMini: return FluidSpeechMini.repository
        }
    }

    /// Folder the model is installed in.
    var installDirectory: URL {
        switch self {
        case .v2, .v3, .ultra: return AsrModels.defaultCacheDirectory(for: asrModelVersion)
        case .fluidSpeechMini: return FluidSpeechMini.directory
        }
    }

    /// Model folders `AsrModels.download` fetches with its default int8 encoder, or that
    /// the plugin downloads itself for Fluid Speech Mini.
    var requiredModelFiles: Set<String> {
        switch self {
        case .v2: return ModelNames.ASR.requiredModels
        case .v3, .ultra: return ModelNames.ASR.requiredModelsV3()
        case .fluidSpeechMini: return FluidSpeechMini.modelFolders
        }
    }

    /// Fluid Speech Mini's joint network has no top-K outputs, so it keeps the plain name.
    var jointFileName: String {
        switch self {
        case .v2, .fluidSpeechMini: return ModelNames.ASR.jointFile
        case .v3, .ultra: return ModelNames.ASR.jointV3File
        }
    }

    /// FluidAudio filters tokens by a language's script through the joint network's top-K
    /// outputs, which Fluid Speech Mini does not have; v2 ignores the hint.
    var acceptsLanguageHint: Bool {
        self != .fluidSpeechMini
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
        case .ultra:
            return ParakeetModelDef(
                id: "parakeet-ultra",
                displayName: "Parakeet Ultra",
                sizeDescription: "~630 MB",
                ramRequirement: "8 GB+"
            )
        case .fluidSpeechMini:
            return ParakeetModelDef(
                id: "fluid-speech-mini",
                displayName: "Fluid Speech Mini",
                sizeDescription: "~250 MB",
                ramRequirement: "8 GB+"
            )
        }
    }

    var supportedLanguages: [String] {
        switch self {
        case .v2, .fluidSpeechMini:
            return ["en"]
        case .v3, .ultra:
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
        case .ultra:
            return String(localized: "Moondream Parakeet Ultra - Parakeet TDT v3 trained further for higher accuracy. 25 European languages, no API key required.", bundle: bundle)
        case .fluidSpeechMini:
            // CC BY 4.0 asks for this attribution wherever the model is offered.
            return String(localized: "Fluid Speech Mini by FluidVoice, built on NVIDIA Parakeet TDT 0.6B v3 and Moondream Parakeet Ultra. Smallest download, English only, no API key required.", bundle: bundle)
        }
    }

    static func from(modelId: String) -> ParakeetVersion? {
        allCases.first { $0.modelDef.id == modelId }
    }
}

// MARK: - Fluid Speech Mini

/// Fluid Speech Mini (FluidVoice-Labs, CC BY 4.0) is a Parakeet fine-tune that FluidAudio's
/// model registry does not list, so the plugin downloads its Core ML folders itself, pinned to
/// a reviewed revision, next to FluidAudio's own Parakeet folders.
enum FluidSpeechMini {
    static let repository = "FluidVoice-Labs/fluid-speech-mini-coreml"
    static let revision = "d81c3160dfe5a5e1f8f7267164a07d30617a3a1a"
    static let modelFolders: Set<String> = [
        ModelNames.ASR.preprocessorFile,
        ModelNames.ASR.encoderFile,
        ModelNames.ASR.decoderFile,
        ModelNames.ASR.jointFile,
    ]
    static let filePatterns = modelFolders.sorted().map { "\($0)/*" } + [ModelNames.ASR.vocabularyFile]

    static var directory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
            .deletingLastPathComponent()
            .appendingPathComponent("fluid-speech-mini-coreml", isDirectory: true)
    }

    /// Files land here first and move into place once all of them are complete, so an
    /// interrupted download resumes instead of leaving a broken model folder.
    static func stagingDirectory(for directory: URL) -> URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent).download", isDirectory: true)
    }

    static func isInstalled(at directory: URL) -> Bool {
        let fileManager = FileManager.default
        let foldersExist = modelFolders.allSatisfy {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).appendingPathComponent("coremldata.bin").path)
        }
        let vocabulary = directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        return foldersExist && (fileSize(of: vocabulary) ?? 0) > 0
    }

    typealias FileLister = @Sendable () async throws -> [PluginHuggingFaceDownloadSize.RemoteFile]
    typealias FileDownloader = @Sendable (_ remotePath: String, _ destination: URL) async throws -> Void

    struct DownloadError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// Downloads the pinned revision into `directory`, skipping files a previous attempt finished.
    static func install(
        into directory: URL = FluidSpeechMini.directory,
        listFiles: FileLister,
        downloadFile: FileDownloader,
        progress: @Sendable (Double) -> Void
    ) async throws {
        guard !isInstalled(at: directory) else { return }
        let files = try await listFiles()
        guard !files.isEmpty else {
            throw DownloadError(message: "Fluid Speech Mini has no files at revision \(revision)")
        }
        let staging = stagingDirectory(for: directory)
        let fileManager = FileManager.default
        let total = max(1, files.reduce(Int64(0)) { $0 + $1.size })
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            guard isSafeRelativePath(file.path) else {
                throw DownloadError(message: "Unexpected file path in Fluid Speech Mini: \(file.path)")
            }
            let target = staging.appendingPathComponent(file.path, isDirectory: false)
            if fileSize(of: target) != file.size {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await downloadFile(file.path, target)
                guard fileSize(of: target) == file.size else {
                    try? fileManager.removeItem(at: target)
                    throw DownloadError(message: "Incomplete download of \(file.path)")
                }
            }
            completed += file.size
            progress(Double(completed) / Double(total))
        }
        guard isInstalled(at: staging) else {
            throw DownloadError(message: "Fluid Speech Mini is missing model files after the download")
        }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.moveItem(at: staging, to: directory)
    }

    static func listRemoteFiles(token: String?) async throws -> [PluginHuggingFaceDownloadSize.RemoteFile] {
        try await PluginHuggingFaceDownloadSize.files(
            repositoryID: repository,
            revision: revision,
            matching: filePatterns,
            token: token
        )
    }

    static func downloadRemoteFile(_ remotePath: String, to destination: URL, token: String?) async throws {
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()
        guard let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(remotePath)") else {
            throw DownloadError(message: "Invalid Fluid Speech Mini file path: \(remotePath)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (temporaryFile, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporaryFile) }
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            throw DownloadError(message: "HTTP \(status.map(String.init) ?? "error") while downloading \(remotePath)")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryFile, to: destination)
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("/") && !components.isEmpty
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func fileSize(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
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

struct ParakeetVocabularyBoostingError: LocalizedError, Equatable, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private struct ParakeetVocabularyAssetHTTPError: LocalizedError, Sendable {
    let description: String
    let statusCode: Int?

    var errorDescription: String? {
        guard let statusCode else {
            return "Invalid HTTP response while downloading \(description)"
        }
        return "HTTP \(statusCode) while downloading \(description)"
    }
}

private enum ParakeetVocabularyAssetError: LocalizedError {
    case downloadFailed(version: ParakeetVersion, underlying: Error)
    case emptyDownload(version: ParakeetVersion)
    case installFailed(version: ParakeetVersion, path: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let version, let underlying):
            return "Failed to download Parakeet vocabulary file for \(version.modelDef.displayName): \(underlying.localizedDescription)"
        case .emptyDownload(let version):
            return "Failed to download Parakeet vocabulary file for \(version.modelDef.displayName): downloaded file was empty"
        case .installFailed(let version, let path, let underlying):
            return "Failed to install Parakeet vocabulary file for \(version.modelDef.displayName) at \(path.path): \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Settings View

private struct ParakeetSettingsView: View {
    let plugin: ParakeetPlugin
    private let bundle = Bundle(for: ParakeetPlugin.self)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pluginSettingsClose) private var closeSettings
    @State private var selectedVersion: ParakeetVersion = .ultra
    @State private var modelState: ParakeetModelState = .notLoaded
    @State private var downloadProgress: Double = 0
    @State private var downloadedVersions: Set<ParakeetVersion> = []
    @State private var onDemandModelId: String?
    @State private var hfTokenInput = ""
    @State private var showHfToken = false
    @State private var isValidatingToken = false
    @State private var tokenValidationResult: Bool?
    @State private var boostingEnabled: Bool = false
    @State private var ctcModelState: CtcModelState = .notDownloaded
    @State private var boostingTermCount: Int = 0

    private let pollTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hugging Face Token", bundle: bundle)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("Optional. Increases download rate limits. Free at huggingface.co/settings/tokens", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        if showHfToken {
                            TextField("hf_...", text: $hfTokenInput)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(Text("Hugging Face token", bundle: bundle))
                        } else {
                            SecureField("hf_...", text: $hfTokenInput)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(Text("Hugging Face token", bundle: bundle))
                        }

                        Button {
                            showHfToken.toggle()
                        } label: {
                            Image(systemName: showHfToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showHfToken ? Text("Hide Hugging Face token", bundle: bundle) : Text("Show Hugging Face token", bundle: bundle))

                        if hasStoredHfToken {
                            Button(String(localized: "Remove", bundle: bundle)) {
                                hfTokenInput = ""
                                tokenValidationResult = nil
                                isValidatingToken = false
                                plugin.clearHuggingFaceToken()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel(Text("Remove Hugging Face token", bundle: bundle))
                        }

                        Button(String(localized: "Save", bundle: bundle)) {
                            validateAndSaveHuggingFaceToken()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(trimmedHfTokenInput.isEmpty || isValidatingToken)
                        .accessibilityLabel(Text("Save Hugging Face token", bundle: bundle))
                    }

                    if isValidatingToken {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Validating token...", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let tokenValidationResult {
                        HStack(spacing: 4) {
                            Image(systemName: tokenValidationResult ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(tokenValidationResult ? .green : .red)
                                .accessibilityHidden(true)
                            Text(
                                tokenValidationResult
                                    ? String(localized: "Valid Hugging Face Token", bundle: bundle)
                                    : String(localized: "Invalid Hugging Face Token", bundle: bundle)
                            )
                            .font(.caption)
                            .foregroundStyle(tokenValidationResult ? .green : .red)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Model Version", bundle: bundle)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    ForEach(ParakeetVersion.allCases, id: \.self) { version in
                        modelRow(for: version)
                    }
                }

                if case .ready = modelState {
                    Divider()
                    vocabularyBoostingSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            // Embedded in the host's settings page there is nothing to close.
            if plugin.canDismissSettingsAfterSetup, closeSettings != nil {
                Divider()

                HStack {
                    Spacer()

                    Button(String(localized: "Done", bundle: bundle)) {
                        finishSetupAndClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .padding()
                .background(.bar)
            }
        }
        .onAppear {
            syncViewStateFromPlugin()
            if let token = plugin._hfToken, !token.isEmpty {
                hfTokenInput = token
            }
        }
        .onReceive(pollTimer) { _ in
            syncViewStateFromPlugin()
        }
        .onChange(of: hfTokenInput) { _, newValue in
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedValue != storedHfToken {
                tokenValidationResult = nil
            }
        }
    }

    private func modelRow(for version: ParakeetVersion) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(version.modelDef.displayName)
                    .font(.body)
                Text(verbatim: "\(version.modelDef.sizeDescription) - RAM: \(version.modelDef.ramRequirement)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(version.settingsDescription(bundle: bundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            modelAction(for: version)
        }
    }

    @ViewBuilder
    private func modelAction(for version: ParakeetVersion) -> some View {
        // The plugin holds one model at a time; its state belongs to the selected version.
        switch version == selectedVersion ? modelState : .notLoaded {
        case .notLoaded:
            if version.modelDef.id == onDemandModelId, downloadedVersions.contains(version) {
                PluginModelLoadsOnDemandStatus(bundle: bundle)
            } else {
                Button(
                    downloadedVersions.contains(version)
                        ? String(localized: "Load", bundle: bundle)
                        : String(localized: "Download & Load", bundle: bundle)
                ) {
                    load(version)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(modelState == .downloading)
                .accessibilityLabel(
                    downloadedVersions.contains(version)
                        ? Text("Load \(version.modelDef.displayName)", bundle: bundle)
                        : Text("Download and load \(version.modelDef.displayName)", bundle: bundle)
                )
            }

        case .downloading:
            HStack(spacing: 8) {
                ProgressView(value: downloadProgress)
                    .frame(width: 80)
                    .accessibilityLabel(Text("Downloading \(version.modelDef.displayName)", bundle: bundle))
                Text(verbatim: "\(Int(downloadProgress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }

        case .ready:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("Loaded", bundle: bundle))
                Button(String(localized: "Unload", bundle: bundle)) {
                    plugin.unloadModel()
                    modelState = plugin.modelState
                    ctcModelState = plugin.ctcModelState
                    boostingTermCount = 0
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(Text("Unload \(version.modelDef.displayName)", bundle: bundle))
            }

        case .error(let message):
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("Error", bundle: bundle))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button(String(localized: "Retry", bundle: bundle)) {
                    load(version)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel(Text("Retry \(version.modelDef.displayName)", bundle: bundle))
            }
        }
    }

    private func load(_ version: ParakeetVersion) {
        selectedVersion = version
        modelState = .downloading
        downloadProgress = 0.05
        if plugin.loadedModelId != nil, plugin.selectedVersion != version {
            plugin.unloadModel(clearPersistence: false)
        }
        plugin.selectedVersion = version
        plugin.host?.setUserDefault(version.rawValue, forKey: "selectedVersion")
        Task {
            await plugin.loadModel(version: version)
            syncViewStateFromPlugin()
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
                            .accessibilityHidden(true)
                        Text("CTC model (~100 MB) - downloads automatically on first use, or:", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Download Now", bundle: bundle)) {
                            Task {
                                await plugin.downloadCtcModel()
                                syncViewStateFromPlugin()
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
                            .accessibilityHidden(true)
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
                            .accessibilityLabel(Text("Error", bundle: bundle))
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button(String(localized: "Retry", bundle: bundle)) {
                            Task {
                                await plugin.downloadCtcModel()
                                syncViewStateFromPlugin()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityLabel(Text("Retry CTC model download", bundle: bundle))
                    }
                }
            }
        }
    }

    private func syncViewStateFromPlugin() {
        selectedVersion = plugin.selectedVersion
        modelState = plugin.modelState
        downloadProgress = plugin.downloadProgress
        downloadedVersions = Set(ParakeetVersion.allCases.filter(plugin.isModelDownloaded(version:)))
        onDemandModelId = plugin.host?.modelIdLoadedOnDemand
        boostingEnabled = plugin.vocabularyBoostingEnabled
        ctcModelState = plugin.ctcModelState
        boostingTermCount = plugin.lastBoostingTermCount
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

    private func finishSetupAndClose() {
        plugin.host?.notifyCapabilitiesChanged()
        if let closeSettings {
            closeSettings()
        } else {
            dismiss()
        }
    }
}
