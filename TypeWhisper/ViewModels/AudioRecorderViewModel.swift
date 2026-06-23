import Foundation
import Combine
import AppKit
import AVFoundation
import os
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioRecorderViewModel")

@MainActor
final class AudioRecorderViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: AudioRecorderViewModel?
    static var shared: AudioRecorderViewModel {
        guard let instance = _shared else {
            fatalError("AudioRecorderViewModel not initialized")
        }
        return instance
    }

    enum RecorderState: Equatable {
        case idle, recording, finalizing
    }

    enum RecorderAPISessionStatus: String {
        case recording, finalizing, completed, failed
    }

    struct RecorderAPISessionSnapshot {
        let id: UUID
        let status: RecorderAPISessionStatus
        let text: String?
        let outputFile: String?
        let error: String?
    }

    enum RecorderAPIError: LocalizedError {
        case noSourceEnabled
        case alreadyRecording
        case finalizing
        case notRecording

        var errorDescription: String? {
            switch self {
            case .noSourceEnabled:
                "At least one audio source must be enabled."
            case .alreadyRecording:
                "Already recording"
            case .finalizing:
                "Recorder is finalizing"
            case .notRecording:
                "Not recording"
            }
        }
    }

    private struct FinalTranscriptionRequest {
        let outputURL: URL
        let buffer: [Float]
        let languageSelection: LanguageSelection
        let task: TranscriptionTask
        let providerId: String?
        let resolvedModelId: String?
        let prompt: String?
        let dictionaryTermHints: [PluginDictionaryTermHint]
        let liveSessionResult: TranscriptionResult?
    }

    struct RecordingItem: Identifiable {
        let id = UUID()
        let url: URL
        let date: Date
        let duration: TimeInterval
        let fileSize: Int64
        let transcript: String?
        var fileName: String { url.lastPathComponent }
    }

    @Published var state: RecorderState = .idle
    @Published var duration: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var micEnabled: Bool {
        didSet { defaults.set(micEnabled, forKey: UserDefaultsKeys.recorderMicEnabled) }
    }
    @Published var systemAudioEnabled: Bool {
        didSet { defaults.set(systemAudioEnabled, forKey: UserDefaultsKeys.recorderSystemAudioEnabled) }
    }
    @Published var outputFormat: AudioRecorderService.OutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: UserDefaultsKeys.recorderOutputFormat) }
    }
    @Published var micDuckingMode: AudioRecorderService.MicDuckingMode {
        didSet {
            defaults.set(micDuckingMode.rawValue, forKey: UserDefaultsKeys.recorderMicDuckingMode)
            recorderService.micDuckingMode = micDuckingMode
        }
    }
    @Published var trackMode: AudioRecorderService.TrackMode {
        didSet {
            defaults.set(trackMode.rawValue, forKey: UserDefaultsKeys.recorderTrackMode)
            recorderService.trackMode = trackMode
        }
    }
    @Published var transcriptionEnabled: Bool {
        didSet { defaults.set(transcriptionEnabled, forKey: UserDefaultsKeys.recorderTranscriptionEnabled) }
    }
    @Published var livePreviewEnabled: Bool {
        didSet { defaults.set(livePreviewEnabled, forKey: UserDefaultsKeys.recorderLivePreviewEnabled) }
    }
    @Published var selectedEngine: String? {
        didSet {
            defaults.set(selectedEngine, forKey: UserDefaultsKeys.recorderTranscriptionEngine)
            guard isInitialized, oldValue != selectedEngine else { return }
            selectedModel = nil
            normalizeLanguageSelectionForResolvedEngine()
        }
    }
    @Published var selectedModel: String? {
        didSet { defaults.set(selectedModel, forKey: UserDefaultsKeys.recorderTranscriptionModel) }
    }
    @Published var languageSelection: LanguageSelection = .auto
    @Published var selectedTask: TranscriptionTask = .transcribe
    @Published var recordings: [RecordingItem] = []
    @Published var errorMessage: String?
    @Published var systemAudioWarningMessage: String?
    @Published var partialText: String = ""
    @Published var isTranscribing: Bool = false

    var activeEngineName: String? { resolvedEngine?.providerDisplayName }
    var activeModelName: String? {
        modelManager.resolvedModelDisplayName(
            engineOverrideId: selectedEngine,
            cloudModelOverride: effectiveModelId
        )
    }
    var isModelReady: Bool {
        guard let engine = resolvedEngine else { return false }
        guard modelManager.canUseForTranscription(engine) else { return false }
        return engine.isConfigured
    }
    var supportsTranslation: Bool { resolvedEngine?.supportsTranslation ?? false }
    var effectiveProviderId: String? {
        selectedEngine ?? modelManager.selectedProviderId
    }
    var effectiveModelId: String? {
        modelManager.resolvedModelId(
            engineOverrideId: selectedEngine,
            cloudModelOverride: selectedModel
        )
    }
    var resolvedEngine: TranscriptionEnginePlugin? {
        guard let providerId = effectiveProviderId else { return nil }
        guard let pluginManager = PluginManager.shared else { return nil }
        return pluginManager.transcriptionEngine(for: providerId)
    }
    var selectedEngineSupportedLanguages: [String] {
        resolvedEngine?.supportedLanguages.sorted() ?? []
    }
    var selectedLanguage: String? { languageSelection.requestedLanguage }
    var canToggleRecording: Bool {
        Self.canToggleRecording(
            state: state,
            micEnabled: micEnabled,
            systemAudioEnabled: systemAudioEnabled
        )
    }

    private let recorderService: AudioRecorderService
    private let modelManager: ModelManagerService
    private let dictionaryService: DictionaryService
    private let defaults: UserDefaults
    private let streamingHandler: StreamingHandler
    private let livePreviewStartObserver: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var currentOutputURL: URL?
    private var activeRecorderAPISessionID: UUID?
    private var recorderAPISessions: [UUID: RecorderAPISessionSnapshot] = [:]
    private var isInitialized = false

    init(
        recorderService: AudioRecorderService,
        modelManager: ModelManagerService,
        dictionaryService: DictionaryService,
        defaults: UserDefaults = .standard,
        livePreviewStartObserver: (() -> Void)? = nil
    ) {
        self.recorderService = recorderService
        self.modelManager = modelManager
        self.dictionaryService = dictionaryService
        self.defaults = defaults
        self.livePreviewStartObserver = livePreviewStartObserver
        self.streamingHandler = StreamingHandler(
            modelManager: modelManager,
            bufferProvider: { [weak recorderService] in
                recorderService?.getCurrentBuffer() ?? []
            },
            recentBufferProvider: { [weak recorderService] maxDuration in
                recorderService?.getRecentBuffer(maxDuration: maxDuration) ?? []
            },
            bufferDeltaProvider: { [weak recorderService] offset in
                recorderService?.getBufferDelta(since: offset) ?? ([], offset)
            },
            bufferedDurationProvider: { [weak recorderService] in
                recorderService?.totalBufferDuration ?? 0
            }
        )

        // Load saved preferences with defaults
        if defaults.object(forKey: UserDefaultsKeys.recorderMicEnabled) == nil {
            self.micEnabled = true
        } else {
            self.micEnabled = defaults.bool(forKey: UserDefaultsKeys.recorderMicEnabled)
        }
        self.systemAudioEnabled = defaults.bool(forKey: UserDefaultsKeys.recorderSystemAudioEnabled)

        if let formatString = defaults.string(forKey: UserDefaultsKeys.recorderOutputFormat),
           let format = AudioRecorderService.OutputFormat(rawValue: formatString) {
            self.outputFormat = format
        } else {
            self.outputFormat = .wav
        }

        if let modeString = defaults.string(forKey: UserDefaultsKeys.recorderMicDuckingMode),
           let mode = AudioRecorderService.MicDuckingMode(rawValue: modeString) {
            self.micDuckingMode = mode
        } else {
            self.micDuckingMode = .aggressive
        }

        if let modeString = defaults.string(forKey: UserDefaultsKeys.recorderTrackMode),
           let mode = AudioRecorderService.TrackMode(rawValue: modeString) {
            self.trackMode = mode
        } else {
            self.trackMode = .mixed
        }

        if defaults.object(forKey: UserDefaultsKeys.recorderTranscriptionEnabled) == nil {
            self.transcriptionEnabled = true
        } else {
            self.transcriptionEnabled = defaults.bool(forKey: UserDefaultsKeys.recorderTranscriptionEnabled)
        }
        if defaults.object(forKey: UserDefaultsKeys.recorderLivePreviewEnabled) == nil {
            self.livePreviewEnabled = false
        } else {
            self.livePreviewEnabled = defaults.bool(forKey: UserDefaultsKeys.recorderLivePreviewEnabled)
        }
        self.selectedEngine = defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine)
        self.selectedModel = defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel)

        recorderService.micDuckingMode = micDuckingMode
        recorderService.trackMode = trackMode

        setupBindings()
        loadRecordings()

        streamingHandler.onPartialTextUpdate = { [weak self] text in
            guard let self else { return }
            self.partialText = text
            EventBus.shared.emit(.partialTranscriptionUpdate(PartialTranscriptionPayload(
                text: text,
                elapsedSeconds: self.duration
            )))
        }
        streamingHandler.onStreamingStateChange = { [weak self] streaming in
            self?.isTranscribing = streaming
        }

        isInitialized = true
        reconcileSelectionWithAvailablePlugins()
    }

    private func setupBindings() {
        recorderService.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.duration = value }
            .store(in: &cancellables)

        recorderService.$micLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.micLevel = value }
            .store(in: &cancellables)

        recorderService.$systemLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.systemLevel = value }
            .store(in: &cancellables)

        recorderService.$systemAudioWarningMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.systemAudioWarningMessage = value }
            .store(in: &cancellables)

        modelManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.reconcileSelectionWithAvailablePlugins()
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }

    func observePluginManager() {
        guard let pluginManager = PluginManager.shared else { return }
        pluginManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcileSelectionWithAvailablePlugins()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func canUseForTranscription(_ engine: TranscriptionEnginePlugin) -> Bool {
        modelManager.canUseForTranscription(engine)
    }

    func reconcileSelectionWithAvailablePlugins() {
        guard let pluginManager = PluginManager.shared else { return }
        if let selectedEngine,
           pluginManager.transcriptionEngine(for: selectedEngine) == nil {
            self.selectedEngine = nil
            selectedModel = nil
        }
        clearUnavailableSelectedModelForResolvedEngine()
        normalizeLanguageSelectionForResolvedEngine()
    }

    private func clearUnavailableSelectedModelForResolvedEngine() {
        guard let selectedModel else { return }
        guard let engine = resolvedEngine else {
            self.selectedModel = nil
            return
        }

        let modelIds = Set((engine.modelCatalog + engine.transcriptionModels).map(\.id))
        if !modelIds.contains(selectedModel) {
            self.selectedModel = nil
        }
    }

    private func normalizeLanguageSelectionForResolvedEngine() {
        guard let engine = resolvedEngine else { return }
        let normalized = languageSelection.normalizedForSupportedLanguages(engine.supportedLanguages)
        if normalized != languageSelection {
            languageSelection = normalized
        }
    }

    nonisolated static func canToggleRecording(
        state: RecorderState,
        micEnabled: Bool,
        systemAudioEnabled: Bool
    ) -> Bool {
        switch state {
        case .idle:
            micEnabled || systemAudioEnabled
        case .recording:
            true
        case .finalizing:
            false
        }
    }

    func toggleRecording() {
        guard canToggleRecording else { return }

        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .finalizing:
            break
        }
    }

    func startRecording() {
        Task {
            do {
                _ = try await beginRecording(
                    micEnabled: micEnabled,
                    systemAudioEnabled: systemAudioEnabled,
                    apiSessionID: nil
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        stopRecording(apiSessionID: activeRecorderAPISessionID)
    }

    @discardableResult
    private func beginRecording(
        micEnabled requestedMicEnabled: Bool,
        systemAudioEnabled requestedSystemAudioEnabled: Bool,
        apiSessionID: UUID?
    ) async throws -> URL {
        switch state {
        case .idle:
            break
        case .recording:
            throw RecorderAPIError.alreadyRecording
        case .finalizing:
            throw RecorderAPIError.finalizing
        }

        guard requestedMicEnabled || requestedSystemAudioEnabled else {
            throw RecorderAPIError.noSourceEnabled
        }

        errorMessage = nil
        systemAudioWarningMessage = nil
        partialText = ""
        reconcileSelectionWithAvailablePlugins()
        state = .recording

        let url: URL
        do {
            url = try await recorderService.startRecording(
                micEnabled: requestedMicEnabled,
                systemAudioEnabled: requestedSystemAudioEnabled,
                format: outputFormat
            )
        } catch {
            state = .idle
            currentOutputURL = nil
            if let apiSessionID {
                activeRecorderAPISessionID = nil
                recorderAPISessions.removeValue(forKey: apiSessionID)
            }
            throw error
        }
        currentOutputURL = url

        if let apiSessionID {
            activeRecorderAPISessionID = apiSessionID
            storeRecorderAPISession(RecorderAPISessionSnapshot(
                id: apiSessionID,
                status: .recording,
                text: nil,
                outputFile: url.path,
                error: nil
            ))
        }

        EventBus.shared.emit(.recordingStarted(RecordingStartedPayload()))

        if transcriptionEnabled && livePreviewEnabled {
            startStreamingTranscription()
        } else {
            isTranscribing = false
        }

        return url
    }

    private func stopRecording(apiSessionID: UUID?) {
        let recordingDuration = duration

        Task {
            let liveSessionResult = await streamingHandler.finish()
            let url = await recorderService.stopRecording()

            let finalTranscriptionRequest: FinalTranscriptionRequest?
            if transcriptionEnabled, let url {
                reconcileSelectionWithAvailablePlugins()
                let providerId = effectiveProviderId
                let dictionaryPrompt = dictionaryService.getTermsForPrompt(providerId: providerId)
                let dictionaryTermHints = dictionaryService.getTermHints(providerId: providerId)
                finalTranscriptionRequest = FinalTranscriptionRequest(
                    outputURL: url,
                    buffer: recorderService.getCurrentBuffer(),
                    languageSelection: languageSelection,
                    task: selectedTask,
                    providerId: providerId,
                    resolvedModelId: effectiveModelId,
                    prompt: dictionaryPrompt,
                    dictionaryTermHints: dictionaryTermHints,
                    liveSessionResult: liveSessionResult
                )
                state = .finalizing
                if let apiSessionID {
                    markRecorderAPISessionFinalizing(id: apiSessionID, outputURL: url)
                }
            } else {
                finalTranscriptionRequest = nil
                state = .idle
                isTranscribing = false
            }

            EventBus.shared.emit(.recordingStopped(RecordingStoppedPayload(durationSeconds: recordingDuration)))

            if let request = finalTranscriptionRequest {
                await runFinalTranscription(request)
                state = .idle
            }

            // Emit final transcript to LiveTranscriptPlugin
            if livePreviewEnabled && !partialText.isEmpty {
                EventBus.shared.emit(.partialTranscriptionUpdate(PartialTranscriptionPayload(
                    text: partialText, isFinal: true, elapsedSeconds: recordingDuration
                )))
            }

            if url != nil {
                loadRecordings()
            }

            if let apiSessionID {
                if let url {
                    completeRecorderAPISession(id: apiSessionID, outputURL: url)
                } else {
                    failRecorderAPISession(id: apiSessionID, error: "Failed to finalize recording")
                }
            }
        }
    }

    // MARK: - HTTP API

    var apiRecorderIsRecording: Bool {
        state == .recording
    }

    func apiStartRecording(micEnabled micOverride: Bool?, systemAudioEnabled systemAudioOverride: Bool?) async throws -> UUID {
        let resolvedMicEnabled = micOverride ?? micEnabled
        let resolvedSystemAudioEnabled = systemAudioOverride ?? systemAudioEnabled
        let sessionID = UUID()
        _ = try await beginRecording(
            micEnabled: resolvedMicEnabled,
            systemAudioEnabled: resolvedSystemAudioEnabled,
            apiSessionID: sessionID
        )
        return sessionID
    }

    func apiStopRecording() throws -> UUID {
        guard state == .recording else {
            throw RecorderAPIError.notRecording
        }
        guard let sessionID = activeRecorderAPISessionID else {
            throw RecorderAPIError.notRecording
        }
        if let currentOutputURL {
            markRecorderAPISessionFinalizing(id: sessionID, outputURL: currentOutputURL)
        }
        state = .finalizing
        stopRecording(apiSessionID: sessionID)
        return sessionID
    }

    func apiRecorderSession(id: UUID) -> RecorderAPISessionSnapshot? {
        recorderAPISessions[id]
    }

    private func storeRecorderAPISession(_ session: RecorderAPISessionSnapshot) {
        recorderAPISessions[session.id] = session
    }

    private func markRecorderAPISessionFinalizing(id: UUID, outputURL: URL) {
        storeRecorderAPISession(RecorderAPISessionSnapshot(
            id: id,
            status: .finalizing,
            text: nil,
            outputFile: outputURL.path,
            error: nil
        ))
    }

    private func completeRecorderAPISession(id: UUID, outputURL: URL) {
        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        storeRecorderAPISession(RecorderAPISessionSnapshot(
            id: id,
            status: .completed,
            text: text.isEmpty ? nil : text,
            outputFile: outputURL.path,
            error: nil
        ))
        if activeRecorderAPISessionID == id {
            activeRecorderAPISessionID = nil
        }
    }

    private func failRecorderAPISession(id: UUID, error: String) {
        let outputFile = recorderAPISessions[id]?.outputFile
        storeRecorderAPISession(RecorderAPISessionSnapshot(
            id: id,
            status: .failed,
            text: nil,
            outputFile: outputFile,
            error: error
        ))
        if activeRecorderAPISessionID == id {
            activeRecorderAPISessionID = nil
        }
    }

    func deleteRecording(_ item: RecordingItem) {
        do {
            try FileManager.default.removeItem(at: item.url)
            // Also delete sidecar transcript
            let txtURL = item.url.deletingPathExtension().appendingPathExtension("txt")
            try? FileManager.default.removeItem(at: txtURL)
            recordings.removeAll { $0.id == item.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealInFinder(_ item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func transcribeRecording(_ item: RecordingItem) {
        FileTranscriptionViewModel.shared.addFiles([item.url])
    }

    func openRecordingsFolder() {
        let dir = recorderService.recordingsDirectory
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.open(dir)
        }
    }

    func copyTranscript(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func loadRecordings() {
        let dir = recorderService.recordingsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else {
            recordings = []
            return
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aac", "caf"]
            let items: [RecordingItem] = files
                .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .compactMap { url in
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
                    let date = (attrs[.creationDate] as? Date) ?? Date.distantPast
                    let size = (attrs[.size] as? Int64) ?? 0
                    let duration = audioDuration(for: url)
                    let transcript = loadTranscript(for: url)
                    return RecordingItem(url: url, date: date, duration: duration, fileSize: size, transcript: transcript)
                }
                .sorted { $0.date > $1.date }

            recordings = items
        } catch {
            recordings = []
        }
    }

    private func audioDuration(for url: URL) -> TimeInterval {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return 0 }
        return player.duration.isFinite ? player.duration : 0
    }

    func formattedDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    func formattedFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Streaming Transcription

    private func startStreamingTranscription() {
        guard let pluginManager = PluginManager.shared else {
            logger.info("Plugin manager unavailable, skipping live transcription")
            return
        }
        reconcileSelectionWithAvailablePlugins()
        guard let providerId = effectiveProviderId,
              let plugin = pluginManager.transcriptionEngine(for: providerId) else {
            logger.info("No transcription engine available, skipping live transcription")
            return
        }

        livePreviewStartObserver?()
        let task = (selectedTask == .translate && !plugin.supportsTranslation) ? .transcribe : selectedTask
        streamingHandler.start(
            streamPrompt: dictionaryService.getTermsForPrompt(providerId: providerId) ?? "",
            dictionaryTermHints: dictionaryService.getTermHints(providerId: providerId),
            engineOverrideId: providerId,
            selectedProviderId: modelManager.selectedProviderId,
            languageSelection: languageSelection,
            task: task,
            cloudModelOverride: effectiveModelId,
            allowLiveTranscription: true,
            stateCheck: { [weak self] in self?.state == .recording }
        )
    }

    private func runFinalTranscription(_ request: FinalTranscriptionRequest) async {
        isTranscribing = true
        defer { isTranscribing = false }

        let buffer = request.buffer
        guard buffer.count > 8000 else { // At least 0.5s of audio
            // Use streaming result as final if buffer too short
            if !partialText.isEmpty {
                saveTranscript(partialText, for: request.outputURL)
            } else if let liveSessionResult = request.liveSessionResult {
                let text = liveSessionResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    partialText = text
                    saveTranscript(text, for: request.outputURL)
                }
            }
            return
        }

        // Fall back to transcribe if engine doesn't support translation
        let effectiveTask: TranscriptionTask
        if request.task == .translate,
           let providerId = request.providerId,
           let pluginManager = PluginManager.shared,
           let plugin = pluginManager.transcriptionEngine(for: providerId),
           !plugin.supportsTranslation {
            effectiveTask = .transcribe
        } else {
            effectiveTask = request.task
        }

        do {
            let result = if let liveSessionResult = request.liveSessionResult {
                liveSessionResult
            } else {
                try await modelManager.transcribe(
                    audioSamples: buffer,
                    languageSelection: request.languageSelection,
                    task: effectiveTask,
                    engineOverrideId: request.providerId,
                    cloudModelOverride: request.resolvedModelId,
                    prompt: request.prompt,
                    dictionaryTermHints: request.dictionaryTermHints
                )
            }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                partialText = text
                saveTranscript(text, for: request.outputURL)
            } else if !partialText.isEmpty {
                saveTranscript(partialText, for: request.outputURL)
            }
        } catch {
            logger.error("Final transcription failed: \(error.localizedDescription)")
            // Fall back to streaming result
            if !partialText.isEmpty {
                saveTranscript(partialText, for: request.outputURL)
            }
        }
    }

    // MARK: - Transcript Sidecar

    private func transcriptURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("txt")
    }

    private func saveTranscript(_ text: String, for audioURL: URL) {
        let txtURL = transcriptURL(for: audioURL)
        do {
            try text.write(to: txtURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to save transcript: \(error.localizedDescription)")
        }
    }

    private func loadTranscript(for audioURL: URL) -> String? {
        let txtURL = transcriptURL(for: audioURL)
        return try? String(contentsOf: txtURL, encoding: .utf8)
    }
}
