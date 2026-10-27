import Foundation
import Combine
import AppKit
import AVFoundation
import os
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioRecorderViewModel")

/// Speech detection found no speech in the recording, so the engine was not asked.
private struct RecordingHasNoSpeech: Error {}

private final class RecorderTranscriptionSourceProgressCapture: @unchecked Sendable {
    private let maximumProcessedDuration = OSAllocatedUnfairLock(initialState: TimeInterval.zero)

    func record(_ progress: PluginTranscriptionSourceProgress) -> Bool {
        guard progress.processedDuration.isFinite else { return true }
        maximumProcessedDuration.withLock { current in
            current = max(current, progress.processedDuration)
        }
        return true
    }

    var processedDuration: TimeInterval {
        maximumProcessedDuration.withLock { $0 }
    }
}

private func recorderAudioHasAudibleTail(
    samples: [Float],
    startingAt startTime: TimeInterval,
    sampleRate: Double = AudioRecorderService.transcriptionSampleRate
) -> Bool {
    let frameSampleCount = max(1, Int(sampleRate * 0.1))
    let analysisStride = 8
    let requiredActiveFrames = 10
    let speechRMSFloor = 0.004
    let analysisStartOffset = startTime > 0 ? 0.5 : 0
    let startIndex = min(
        samples.count,
        max(0, Int((startTime + analysisStartOffset) * sampleRate))
    )
    guard startIndex < samples.count else { return false }

    var activeFrames = 0
    var frameStart = startIndex
    while frameStart < samples.count {
        guard !Task.isCancelled else { return false }
        let frameEnd = min(samples.count, frameStart + frameSampleCount)
        var squaredSum = 0.0
        var analyzedSamples = 0
        var index = frameStart
        while index < frameEnd {
            let sample = Double(samples[index])
            if sample.isFinite {
                squaredSum += sample * sample
                analyzedSamples += 1
            }
            index += analysisStride
        }

        if analyzedSamples > 0 {
            let rms = sqrt(squaredSum / Double(analyzedSamples))
            if rms >= speechRMSFloor {
                activeFrames += 1
                if activeFrames >= requiredActiveFrames {
                    return true
                }
            }
        }
        frameStart = frameEnd
    }

    return false
}

// File-system scans run away from the main actor. The caller validates a generation
// afterwards, discarding reads that overlapped a transcript save or deletion.
private func readRecorderTranscriptCompletions(
    from directory: URL, since: Date?
) throws -> [RecorderTranscriptReadyPayload] {
    let files: [URL]
    do {
        files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
        return []
    }
    return try files.filter { $0.lastPathComponent.hasSuffix(".transcript-ready.json") }
        .compactMap { receiptURL -> RecorderTranscriptReadyPayload? in
            let saved = try JSONDecoder().decode(
                RecorderTranscriptReadyPayload.self, from: Data(contentsOf: receiptURL)
            )
            if let since, saved.completedAt < since { return nil }
            // Derive current paths from the receipt rather than retaining obsolete absolute paths
            // when a user moves the recordings folder together with its sidecars.
            let audioURL = receiptURL.deletingPathExtension().deletingPathExtension().resolvingSymlinksInPath()
            let txtURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
            guard try isRegularRecorderAutomationFile(audioURL), try isRegularRecorderAutomationFile(txtURL) else { return nil }
            let markdownURL = audioURL.deletingPathExtension().appendingPathExtension("transcript.md")
            let hasMarkdown = try saved.markdownFilePath != nil && isRegularRecorderAutomationFile(markdownURL)
            return RecorderTranscriptReadyPayload(
                recordingID: saved.recordingID,
                completionID: saved.completionID,
                completedAt: saved.completedAt,
                text: saved.text,
                audioFilePath: audioURL.path,
                transcriptFilePath: txtURL.path,
                markdownFilePath: hasMarkdown ? markdownURL.path : nil,
                recordedAt: saved.recordedAt,
                durationSeconds: saved.durationSeconds,
                calendarEvent: saved.calendarEvent
            )
        }
        .sorted(by: recorderCompletionPrecedes)
}

private func recorderCompletionPrecedes(_ lhs: RecorderTranscriptReadyPayload, _ rhs: RecorderTranscriptReadyPayload) -> Bool {
    if lhs.completedAt == rhs.completedAt { return lhs.completionID.uuidString < rhs.completionID.uuidString }
    return lhs.completedAt < rhs.completedAt
}

private func isRegularRecorderAutomationFile(_ url: URL) throws -> Bool {
    do {
        return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
        return false
    }
}

@MainActor
final class AudioRecorderViewModel: ObservableObject {
    typealias AudioSamplesLoader = @MainActor (URL) async throws -> [Float]
    /// Reads a finalized recording's length in seconds from its header, without decoding it.
    typealias RecordingDurationReader = @Sendable (URL) async throws -> TimeInterval
    typealias RecordingsLoader = @Sendable (
        URL,
        [String: RecordingTranscriptionFailure]
    ) -> [RecordingItem]
    typealias RecorderCompletionsLoader = @Sendable (URL, Date?) throws -> [RecorderTranscriptReadyPayload]
    /// Moves a recording file to the Trash and returns where it ended up there.
    typealias RecordingFileTrasher = @MainActor (URL) throws -> URL?

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
        case retranscribing
        case notRecording
        case calendarRecordingHandleMismatch

        var errorDescription: String? {
            switch self {
            case .noSourceEnabled:
                String(localized: "At least one audio source must be enabled.")
            case .alreadyRecording:
                String(localized: "Already recording")
            case .finalizing:
                String(localized: "Recorder is finalizing")
            case .retranscribing:
                String(localized: "Recorder is transcribing an existing recording")
            case .notRecording:
                String(localized: "Not recording")
            case .calendarRecordingHandleMismatch:
                String(localized: "The calendar-started recording is no longer active.")
            }
        }
    }

    private struct FinalTranscriptionRequest {
        let outputURL: URL
        var buffer: [Float]
        let languageSelection: LanguageSelection
        let task: TranscriptionTask
        let providerId: String?
        let modelOverrideId: String?
        let prompt: String?
        let dictionaryTermHints: [PluginDictionaryTermHint]
        let liveSessionResult: TranscriptionResult?
        /// The live session lost audio or could not finalize, so its preview is not
        /// a usable transcript.
        let liveSessionFailed: Bool
        let calendarEvent: CalendarMeetingTranscriptMetadata?
        /// When the microphone carried the user's own speech, for speaker detection.
        var ownSpeech: [ClosedRange<TimeInterval>] = []
        /// The live preview when the recording stopped.
        var livePreviewText = ""
        /// Whether a speaker record follows, decided when the request is made.
        var detectsSpeakers = false
        /// The captured audio's length in samples. A queued job holds no audio while it
        /// waits, so a live session's job is measured by this.
        var capturedSampleCount = 0
    }

    /// Where a queued job finds the recording's audio when it runs. A waiting job
    /// holds no audio unless its finalized file failed the check at stop.
    private enum FinalTranscriptionAudio {
        /// The live session's result is the transcript, and no speaker record needs audio.
        case notNeeded
        /// The finalized file was complete at stop; the job reads it when it runs.
        case finalizedFile
        /// The finalized file failed the check, so the job keeps the captured audio in
        /// case the file cannot be read.
        case capturedAudio([Float])
    }

    /// A stopped recording's final transcription. The queue runs one at a time, in
    /// the order the recordings stopped, while the Recorder records the next one.
    /// The job owns its request, so a newer recording cannot change it.
    private struct FinalTranscriptionJob {
        let id = UUID()
        let request: FinalTranscriptionRequest
        let audio: FinalTranscriptionAudio
        let apiSessionID: UUID?
        /// The preview belongs to this recording until the next one starts.
        let recordingGeneration: Int
        let recordingDuration: TimeInterval
        let livePreviewEnabled: Bool

        /// A live session's result is the transcript already; other jobs run the engine.
        func usesEngine(_ providerId: String) -> Bool {
            request.liveSessionResult == nil && request.providerId == providerId
        }
    }

    /// A stopped recording whose transcript is not saved yet.
    struct PendingTranscription: Identifiable, Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case transcribing, waiting
        }

        let id: UUID
        /// With symbolic links resolved, to find the recording in the list.
        let url: URL
        let status: Status
        var fileName: String { url.lastPathComponent }
    }

    struct RecordingTranscriptionFailure: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Equatable, Sendable {
            case preparingFinalAudio
            case finalTranscription
            case emptyResult
            case savingTranscript

            var displayName: String {
                switch self {
                case .preparingFinalAudio:
                    String(localized: "recorder.failurePhase.preparingFinalAudio")
                case .finalTranscription:
                    String(localized: "recorder.failurePhase.finalTranscription")
                case .emptyResult:
                    String(localized: "recorder.failurePhase.emptyResult")
                case .savingTranscript:
                    String(localized: "recorder.failurePhase.savingTranscript")
                }
            }
        }

        let phase: Phase
        let providerError: String
        let engineName: String?
        let modelName: String?
        let failedAt: Date
    }

    private enum FinalTranscriptionOutcome {
        case skipped
        case transcriptSaved(recordingID: UUID)
        case failed(RecordingTranscriptionFailure)

        var failure: RecordingTranscriptionFailure? {
            if case .failed(let failure) = self {
                return failure
            }
            return nil
        }
    }

    struct RecordingItem: Identifiable, Sendable {
        let id = UUID()
        let url: URL
        let date: Date
        let duration: TimeInterval
        let fileSize: Int64
        let transcript: String?
        let transcriptionFailure: RecordingTranscriptionFailure?
        let calendarEvent: CalendarMeetingTranscriptMetadata?
        var fileName: String { url.lastPathComponent }

        init(
            url: URL,
            date: Date,
            duration: TimeInterval,
            fileSize: Int64,
            transcript: String?,
            transcriptionFailure: RecordingTranscriptionFailure?,
            calendarEvent: CalendarMeetingTranscriptMetadata? = nil
        ) {
            self.url = url
            self.date = date
            self.duration = duration
            self.fileSize = fileSize
            self.transcript = transcript
            self.transcriptionFailure = transcriptionFailure
            self.calendarEvent = calendarEvent
        }
    }

    @Published var state: RecorderState = .idle {
        didSet {
            if state != .recording { isMeetingRecording = false }
        }
    }
    /// True while Meeting Automation records; set before the state changes so a
    /// hidden meeting recording never flashes the indicator.
    private var isMeetingRecording = false {
        didSet { updateIndicatorHidden() }
    }
    /// Whether the indicator shows meeting recordings; Meeting Automation sets it (#1079).
    var showsMeetingIndicator = true {
        didSet { updateIndicatorHidden() }
    }
    /// True while a meeting is recorded without anything on screen.
    @Published private(set) var isIndicatorHidden = false
    /// The Recorder state the indicator shows: idle while the recording is hidden.
    var indicatorState: RecorderState { isIndicatorHidden ? .idle : state }
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
    /// Saves each transcribed recording to History and detects its speakers (Premium).
    @Published var detectSpeakers: Bool {
        didSet { defaults.set(detectSpeakers, forKey: UserDefaultsKeys.recorderDetectSpeakers) }
    }
    var speakerRecordIntake: SpeakerRecordIntake?
    /// Adds the speakers History holds for a recording to its completion; with
    /// `true`, after a detection run for it has finished.
    var addingRecorderSpeakers: (@MainActor (RecorderTranscriptReadyPayload, Bool) async -> RecorderTranscriptReadyPayload)?

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
        didSet {
            defaults.set(selectedModel, forKey: UserDefaultsKeys.recorderTranscriptionModel)
            guard isInitialized, oldValue != selectedModel else { return }
            normalizeLanguageSelectionForResolvedEngine()
        }
    }
    @Published var languageSelection: LanguageSelection = .auto {
        didSet {
            defaults.set(
                languageSelection.storedValue(nilBehavior: .auto),
                forKey: UserDefaultsKeys.recorderTranscriptionLanguage
            )
        }
    }
    @Published var selectedTask: TranscriptionTask = .transcribe
    @Published var recordings: [RecordingItem] = []
    @Published var errorMessage: String?
    @Published var systemAudioWarningMessage: String?
    @Published var partialText: String = ""
    /// The live preview runs, or a stopped recording's transcript is not saved yet.
    @Published var isTranscribing: Bool = false
    @Published private(set) var retranscribingRecordingURL: URL?
    /// Stopped recordings waiting for their transcripts, in the order they run.
    @Published private(set) var pendingTranscriptions: [PendingTranscription] = []
    /// The recording's live preview waits for a queued transcript on its engine.
    @Published private(set) var isLivePreviewWaiting = false

    var activeEngineName: String? { resolvedEngine?.providerDisplayName }
    var activeModelName: String? {
        modelManager.resolvedModelDisplayName(
            engineOverrideId: availableSelectedEngine,
            cloudModelOverride: effectiveModelId
        )
    }
    var isModelReady: Bool {
        guard let engine = resolvedEngine else { return false }
        guard modelManager.canUseForTranscription(engine) else { return false }
        return engine.isConfigured
    }
    var supportsTranslation: Bool { resolvedEngine?.supportsTranslation(forModel: effectiveModelId) ?? false }
    /// The Recorder's own engine while its plugin is loaded. A plugin that is
    /// gone for now, as during an update, keeps the choice saved; recordings
    /// use the default engine until it is back.
    var availableSelectedEngine: String? {
        guard let selectedEngine,
              PluginManager.shared?.transcriptionEngine(for: selectedEngine) != nil else { return nil }
        return selectedEngine
    }
    /// The model choice, unless it belongs to an engine that is gone for now.
    var availableSelectedModel: String? {
        isSelectedEngineMissing ? nil : selectedModel
    }
    private var isSelectedEngineMissing: Bool {
        selectedEngine != nil && availableSelectedEngine == nil
    }
    /// The engine picker's selection; it shows the default engine while the
    /// chosen one is gone.
    var engineChoice: String? {
        get { availableSelectedEngine }
        set { selectedEngine = newValue }
    }
    var modelChoice: String? {
        get { availableSelectedModel }
        set {
            // The picker shows the default engine in place of a missing one,
            // so a model chosen there is for the default engine.
            if isSelectedEngineMissing { selectedEngine = nil }
            selectedModel = newValue
        }
    }

    /// The engine and model a recording started with. The Recorder's own engine
    /// can come back during a recording that started on the default engine,
    /// whose live preview already ran; the final pass stays on that engine.
    private struct RecordingEngine {
        let providerId: String?
        let modelId: String?
    }
    private var recordingEngine: RecordingEngine?
    private var currentRecordingEngine: RecordingEngine {
        RecordingEngine(providerId: effectiveProviderId, modelId: availableSelectedModel)
    }
    private func isLoaded(_ engine: RecordingEngine) -> Bool {
        engine.providerId.flatMap { PluginManager.shared?.transcriptionEngine(for: $0) } != nil
    }
    /// An update during the recording can drop the model it started with.
    private static func validated(_ engine: RecordingEngine) -> RecordingEngine {
        guard let modelId = engine.modelId, let providerId = engine.providerId,
              let plugin = PluginManager.shared?.transcriptionEngine(for: providerId) else { return engine }
        let modelIds = Set((plugin.modelCatalog + plugin.transcriptionModels).map(\.id))
        guard !modelIds.isEmpty, !modelIds.contains(modelId) else { return engine }
        return RecordingEngine(providerId: providerId, modelId: nil)
    }

    var effectiveProviderId: String? {
        // An enforced pair replaces the chosen engine, as it does when the recording is transcribed.
        modelManager.effectiveEngineId(availableSelectedEngine)
    }
    var effectiveModelId: String? {
        modelManager.resolvedModelId(
            engineOverrideId: availableSelectedEngine,
            cloudModelOverride: availableSelectedModel
        )
    }
    var resolvedEngine: TranscriptionEnginePlugin? {
        guard let providerId = effectiveProviderId else { return nil }
        guard let pluginManager = PluginManager.shared else { return nil }
        return pluginManager.transcriptionEngine(for: providerId)
    }
    var selectedEngineSupportedLanguages: [String] {
        resolvedEngine?.supportedLanguages(forModel: availableSelectedModel).sorted() ?? []
    }
    var selectedLanguage: String? { languageSelection.requestedLanguage }
    @Published private(set) var isHistoryRetranscribing = false
    var canToggleRecording: Bool {
        !isHistoryRetranscribing && retranscribingRecordingURL == nil && Self.canToggleRecording(
            state: state,
            micEnabled: micEnabled,
            systemAudioEnabled: systemAudioEnabled
        )
    }

    private let recorderService: AudioRecorderService
    private let audioDeviceService: AudioDeviceService
    private let modelManager: ModelManagerService
    private let dictionaryService: DictionaryService
    private let audioSamplesLoader: AudioSamplesLoader
    private let recordingDurationReader: RecordingDurationReader
    private let speechRegionDetector: any SpeechRegionDetecting
    private let recordingsLoader: RecordingsLoader
    private let recorderCompletionsLoader: RecorderCompletionsLoader
    private let recordingFileTrasher: RecordingFileTrasher
    private let defaults: UserDefaults
    private let streamingHandler: StreamingHandler
    private let livePreviewStartObserver: (() -> Void)?
    private let accessibilityAnnouncementService: AccessibilityAnnouncementService?
    private var cancellables = Set<AnyCancellable>()
    private var currentOutputURL: URL?
    private var activeCalendarMeetingHandle: CalendarMeetingRecordingHandle?
    private var activeCalendarMeetingTranscriptMetadata: CalendarMeetingTranscriptMetadata?
    private var activeRecorderAPISessionID: UUID?
    private var recorderAPISessions: [UUID: RecorderAPISessionSnapshot] = [:]
    private var finalTranscriptionJobs: [FinalTranscriptionJob] = []
    private var finalTranscriptionTask: Task<Void, Never>?
    /// Advances with every recording, so a transcript finished later leaves the
    /// preview of a newer recording alone.
    private var recordingGeneration = 0
    /// The recording whose live preview waits for a queued transcription on its engine.
    private var deferredLivePreviewGeneration: Int? {
        didSet {
            let waiting = deferredLivePreviewGeneration != nil
            if isLivePreviewWaiting != waiting {
                isLivePreviewWaiting = waiting
            }
        }
    }
    private var isLivePreviewStreaming = false {
        didSet { publishTranscriptionActivity() }
    }
    private var transientTranscriptionFailures: [String: RecordingTranscriptionFailure] = [:]
    private var recordingsLoadTask: Task<Void, Never>?
    private var recordingsLoadGeneration = 0
    private var hasRequestedInitialRecordingsLoad = false
    private var isInitialized = false

    init(
        recorderService: AudioRecorderService,
        modelManager: ModelManagerService,
        dictionaryService: DictionaryService,
        audioFileService: AudioFileService = AudioFileService(),
        audioDeviceService: AudioDeviceService = AudioDeviceService(initialInputDevices: [], monitorDeviceChanges: false),
        defaults: UserDefaults = .standard,
        audioSamplesLoader: AudioSamplesLoader? = nil,
        recordingDurationReader: RecordingDurationReader? = nil,
        speechRegionDetector: (any SpeechRegionDetecting)? = nil,
        recordingsLoader: RecordingsLoader? = nil,
        recorderCompletionsLoader: RecorderCompletionsLoader? = nil,
        recordingFileTrasher: RecordingFileTrasher? = nil,
        livePreviewStartObserver: (() -> Void)? = nil,
        accessibilityAnnouncementService: AccessibilityAnnouncementService? = nil
    ) {
        self.recorderService = recorderService
        self.audioDeviceService = audioDeviceService
        self.modelManager = modelManager
        self.dictionaryService = dictionaryService
        self.audioSamplesLoader = audioSamplesLoader ?? { [audioFileService] url in
            try await audioFileService.loadAudioSamples(from: url)
        }
        self.recordingDurationReader = recordingDurationReader ?? { url in
            try await AudioRecorderViewModel.readRecordingDuration(url)
        }
        self.speechRegionDetector = speechRegionDetector ?? SoundAnalysisSpeechRegionDetector()
        self.recordingsLoader = recordingsLoader ?? { directory, transientFailures in
            Self.readRecordings(from: directory, transientFailures: transientFailures)
        }
        self.recorderCompletionsLoader = recorderCompletionsLoader ?? readRecorderTranscriptCompletions
        self.recordingFileTrasher = recordingFileTrasher ?? { url in
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
            return trashedURL as URL?
        }
        self.defaults = defaults
        self.livePreviewStartObserver = livePreviewStartObserver
        self.accessibilityAnnouncementService = accessibilityAnnouncementService
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
        self.detectSpeakers = defaults.bool(forKey: UserDefaultsKeys.recorderDetectSpeakers)

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
        self.languageSelection = LanguageSelection(
            storedValue: defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionLanguage),
            nilBehavior: .auto
        )

        recorderService.micDuckingMode = micDuckingMode
        recorderService.trackMode = trackMode

        setupBindings()
        if !defaults.bool(forKey: UserDefaultsKeys.devPrivacyQuietMode) {
            loadRecordingsIfNeeded()
        }

        streamingHandler.onPartialTextUpdate = { [weak self] text in
            guard let self else { return }
            // An update delivered after its preview stopped belongs to a stopped
            // recording; the next one can already be running.
            guard self.isLivePreviewStreaming else { return }
            self.partialText = text
            EventBus.shared.emit(.partialTranscriptionUpdate(PartialTranscriptionPayload(
                text: text,
                elapsedSeconds: self.duration
            )))
        }
        streamingHandler.onStreamingStateChange = { [weak self] streaming in
            self?.isLivePreviewStreaming = streaming
        }

        isInitialized = true
        reconcileSelectionWithAvailablePlugins()
    }

    private func setupBindings() {
        HistoryRetranscriptionActivity.recordIDPublisher
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] in self?.isHistoryRetranscribing = $0 }
            .store(in: &cancellables)

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

        // Recorder errors and warnings appear on the Recorder page, which VoiceOver
        // users rarely have in front of them while a recording runs. Duplicates are
        // removed before nil is dropped, so a message that was cleared in between
        // (a new recording resets it) is announced again.
        $errorMessage
            .removeDuplicates()
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.accessibilityAnnouncementService?.announceError(message)
            }
            .store(in: &cancellables)

        $systemAudioWarningMessage
            .removeDuplicates()
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.accessibilityAnnouncementService?.announceWarning(message, isUrgent: true)
            }
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
        pluginManager.uninstalledTranscriptionEngines
            .sink { [weak self] providerIds in self?.forgetUninstalledEngines(providerIds) }
            .store(in: &cancellables)
    }

    /// An uninstalled engine's choice goes; one that is only gone for now stays.
    private func forgetUninstalledEngines(_ providerIds: Set<String>) {
        guard let selectedEngine, providerIds.contains(selectedEngine) else { return }
        self.selectedEngine = nil
        selectedModel = nil
    }

    func canUseForTranscription(_ engine: TranscriptionEnginePlugin) -> Bool {
        modelManager.canUseForTranscription(engine)
    }

    func reconcileSelectionWithAvailablePlugins() {
        guard PluginManager.shared != nil else { return }
        clearUnavailableSelectedModelForResolvedEngine()
        normalizeLanguageSelectionForResolvedEngine()
    }

    private func clearUnavailableSelectedModelForResolvedEngine() {
        guard let selectedModel, !isSelectedEngineMissing else { return }
        guard let engine = resolvedEngine else {
            self.selectedModel = nil
            return
        }

        let modelIds = Set((engine.modelCatalog + engine.transcriptionModels).map(\.id))
        // An engine that lists no models yet says nothing about this one.
        if !modelIds.isEmpty, !modelIds.contains(selectedModel) {
            self.selectedModel = nil
        }
    }

    private func normalizeLanguageSelectionForResolvedEngine() {
        // The language stays for the chosen engine while it is gone.
        guard !isSelectedEngineMissing, let engine = resolvedEngine else { return }
        let normalized = languageSelection.normalizedForSupportedLanguages(
            engine.supportedLanguages(forModel: selectedModel)
        )
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
        WhatsNewCoordinator.shared?.suppressForCurrentLaunch()
        Task {
            do {
                _ = try await beginRecording(
                    micEnabled: micEnabled,
                    systemAudioEnabled: systemAudioEnabled,
                    apiSessionID: nil,
                    preferredBaseName: nil,
                    transcriptMetadata: nil
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
        apiSessionID: UUID?,
        preferredBaseName: String?,
        transcriptMetadata: CalendarMeetingTranscriptMetadata?
    ) async throws -> URL {
        WhatsNewCoordinator.shared?.suppressForCurrentLaunch()
        guard retranscribingRecordingURL == nil, HistoryRetranscriptionActivity.recordID == nil else {
            throw RecorderAPIError.retranscribing
        }

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
        // The preview is this recording's now, also while an earlier transcript is pending.
        recordingGeneration += 1
        activeCalendarMeetingTranscriptMetadata = transcriptMetadata
        reconcileSelectionWithAvailablePlugins()
        recordingEngine = currentRecordingEngine
        state = .recording
        let microphoneSelection = requestedMicEnabled
            ? audioDeviceService.resolvedRecordingInputSelection()
            : .systemDefault

        let url: URL
        do {
            url = try await recorderService.startRecording(
                micEnabled: requestedMicEnabled,
                systemAudioEnabled: requestedSystemAudioEnabled,
                format: outputFormat,
                microphoneSelection: microphoneSelection,
                preferredBaseName: preferredBaseName
            )
        } catch {
            if let selectionError = error as? SelectedInputDeviceError,
               case .incompatible(let issue) = selectionError {
                audioDeviceService.markRecordingInputSelectionCompatibility(
                    .incompatible(issue),
                    selection: microphoneSelection
                )
            }
            state = .idle
            currentOutputURL = nil
            recordingEngine = nil
            activeCalendarMeetingTranscriptMetadata = nil
            if let apiSessionID {
                activeRecorderAPISessionID = nil
                recorderAPISessions.removeValue(forKey: apiSessionID)
            }
            throw error
        }
        currentOutputURL = url
        accessibilityAnnouncementService?.announce(localizedAppText(
            "Recorder started",
            de: "Recorder gestartet",
            ja: "レコーダーを開始しました",
            zh: "录音器已开始"
        ))

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
            isLivePreviewStreaming = false
        }

        return url
    }

    private func stopRecording(apiSessionID: UUID?) {
        activeCalendarMeetingHandle = nil
        // The stopped recording's transcript reports to its API session from here
        // on; a recording started next is not part of that session.
        activeRecorderAPISessionID = nil
        deferredLivePreviewGeneration = nil
        let calendarEvent = activeCalendarMeetingTranscriptMetadata
        activeCalendarMeetingTranscriptMetadata = nil
        let recordingDuration = duration
        let shouldTranscribe = transcriptionEnabled
        let livePreviewEnabled = livePreviewEnabled
        let startedEngine = recordingEngine
        recordingEngine = nil
        let recordingGeneration = recordingGeneration

        // Flip out of `.recording` immediately so the recording timer/widget disappears
        // the instant Stop is pressed, instead of staying up while audio finalization
        // runs (which can take a while for long recordings).
        state = .finalizing
        accessibilityAnnouncementService?.announce(shouldTranscribe
            ? localizedAppText(
                "Recorder stopped, transcribing",
                de: "Recorder gestoppt, wird transkribiert",
                ja: "レコーダーを停止しました。文字起こし中",
                zh: "录音器已停止，正在转录"
            )
            : localizedAppText(
                "Recorder stopped",
                de: "Recorder gestoppt",
                ja: "レコーダーを停止しました",
                zh: "录音器已停止"
            ))

        Task {
            let stoppedRecording = await recorderService.stopCapture(
                includeTranscriptionSamples: shouldTranscribe
            )
            // The live session and the audio file finish before the next recording can
            // start: it would reuse the live preview, and its file name must not collide.
            async let liveSessionFinishTask = streamingHandler.finish(
                finalSamples: stoppedRecording.transcriptionSamples
            )
            async let finalizedURLTask = recorderService.finalizeRecording(stoppedRecording)
            let (liveSessionFinish, url) = await (liveSessionFinishTask, finalizedURLTask)
            let liveResultFromStart = liveSessionFinish.result
            let liveSessionFailed = if case .failed = liveSessionFinish { true } else { false }
            // A complete file stands in for the captured audio, so a job waiting in
            // the queue holds none. Only the file's header is read here.
            let finalizedFileIsComplete = if shouldTranscribe, let url {
                await checkFinalizedRecording(
                    url,
                    capturedSampleCount: stoppedRecording.transcriptionSamples.count
                )
            } else {
                false
            }

            if let url, let calendarEvent {
                do {
                    try saveTranscriptDocument(
                        text: nil,
                        calendarEvent: calendarEvent,
                        for: url
                    )
                } catch {
                    logger.error(
                        "Failed to save calendar transcript metadata: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            var finalTranscriptionJob: FinalTranscriptionJob?
            if shouldTranscribe, let url {
                reconcileSelectionWithAvailablePlugins()
                let startedEngineIsLoaded = startedEngine.map(isLoaded) ?? false
                let engine = startedEngineIsLoaded ? Self.validated(startedEngine!) : currentRecordingEngine
                // A live result or preview from an engine or model that is gone by
                // now does not belong to this request; the full recording is transcribed.
                let keepsLiveSession = startedEngine == nil
                    || (startedEngineIsLoaded && engine.modelId == startedEngine?.modelId)
                let liveSessionResult = keepsLiveSession ? liveResultFromStart : nil
                if !keepsLiveSession { partialText = "" }
                let providerId = engine.providerId
                let dictionaryPrompt = dictionaryService.getTermsForPrompt(providerId: providerId)
                let dictionaryTermHints = dictionaryService.getTermHints(providerId: providerId)
                let detectsSpeakers = wantsSpeakerRecord(calendarEvent: calendarEvent)
                // The engine and a speaker record need the audio; a live session's
                // result alone does not.
                let audio: FinalTranscriptionAudio = if liveSessionResult != nil && !detectsSpeakers {
                    .notNeeded
                } else if finalizedFileIsComplete {
                    .finalizedFile
                } else {
                    .capturedAudio(stoppedRecording.transcriptionSamples)
                }
                finalTranscriptionJob = FinalTranscriptionJob(
                    request: FinalTranscriptionRequest(
                        outputURL: url,
                        // Filled in when the job runs, from `audio`.
                        buffer: [],
                        languageSelection: languageSelection,
                        task: selectedTask,
                        providerId: providerId,
                        modelOverrideId: engine.modelId,
                        prompt: dictionaryPrompt,
                        dictionaryTermHints: dictionaryTermHints,
                        liveSessionResult: liveSessionResult,
                        liveSessionFailed: liveSessionFailed || !keepsLiveSession,
                        calendarEvent: calendarEvent,
                        ownSpeech: stoppedRecording.ownSpeech,
                        livePreviewText: partialText,
                        detectsSpeakers: detectsSpeakers,
                        capturedSampleCount: stoppedRecording.transcriptionSamples.count
                    ),
                    audio: audio,
                    apiSessionID: apiSessionID,
                    recordingGeneration: recordingGeneration,
                    recordingDuration: recordingDuration,
                    livePreviewEnabled: livePreviewEnabled
                )
                if let apiSessionID {
                    markRecorderAPISessionFinalizing(id: apiSessionID, outputURL: url)
                }
            }

            // Announced before the Recorder is free, so a recording started next
            // follows this one's stop.
            EventBus.shared.emit(.recordingStopped(RecordingStoppedPayload(durationSeconds: recordingDuration)))
            if let finalTranscriptionJob {
                // The transcript is made in the background; the next recording can start now.
                enqueueFinalTranscription(finalTranscriptionJob)
            }
            state = .idle
            isLivePreviewStreaming = false
            if url != nil {
                // A queued recording is listed right away, with its place in the queue.
                loadRecordings()
            }
            guard finalTranscriptionJob == nil else { return }

            // Without a transcript to wait for, the preview is final now. A failed live
            // session's preview stopped early, so it is not.
            if livePreviewEnabled && !liveSessionFailed && !partialText.isEmpty {
                EventBus.shared.emit(.partialTranscriptionUpdate(PartialTranscriptionPayload(
                    text: partialText, isFinal: true, elapsedSeconds: recordingDuration
                )))
            }

            if let apiSessionID {
                if let url {
                    completeRecorderAPISession(id: apiSessionID, outputURL: url, text: partialText)
                } else {
                    failRecorderAPISession(id: apiSessionID, error: "Failed to finalize recording")
                }
            }
        }
    }

    /// Whether the finalized file holds the whole recording, from its header alone.
    private func checkFinalizedRecording(_ url: URL, capturedSampleCount: Int) async -> Bool {
        let capturedDuration = Double(capturedSampleCount) / AudioRecorderService.transcriptionSampleRate
        do {
            let fileDuration = try await recordingDurationReader(url)
            guard Self.finalizedFileIsComplete(fileDuration: fileDuration, capturedDuration: capturedDuration) else {
                logger.warning(
                    "Finalized recording is shorter than the captured audio (\(fileDuration, privacy: .public)s of \(capturedDuration, privacy: .public)s); keeping the capture buffer"
                )
                return false
            }
            return true
        } catch {
            logger.warning(
                "Could not check the finalized recording; keeping the capture buffer: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// A complete file has audio and is at most a second, or 2 % of a long
    /// recording, shorter than the captured audio.
    nonisolated static func finalizedFileIsComplete(
        fileDuration: TimeInterval,
        capturedDuration: TimeInterval
    ) -> Bool {
        guard fileDuration.isFinite, fileDuration > 0 else { return false }
        return capturedDuration - fileDuration <= max(1, capturedDuration * 0.02)
    }

    /// The file's length from its header; the audio is not decoded.
    nonisolated static func readRecordingDuration(_ url: URL) async throws -> TimeInterval {
        try await Task.detached(priority: .utility) {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.processingFormat.sampleRate
            guard sampleRate > 0 else { throw AudioFileService.AudioFileError.unsupportedFormat }
            return Double(file.length) / sampleRate
        }.value
    }

    /// Reads a finalized file that was complete at stop. Without captured audio to
    /// fall back on, a file that cannot be read or holds no audio is an error.
    private func loadCompleteFinalizedRecording(_ outputURL: URL) async throws -> [Float] {
        let samples = try await audioSamplesLoader(outputURL)
        guard !samples.isEmpty else {
            throw AudioFileService.AudioFileError.conversionFailed("The recording contains no audio")
        }
        return samples
    }

    private func finalizedRecordingSamples(
        from outputURL: URL,
        fallback captureSamples: [Float]
    ) async -> [Float] {
        do {
            let samples = try await audioSamplesLoader(outputURL)
            guard !samples.isEmpty else {
                logger.warning(
                    "Finalized recording contained no transcription samples; using capture buffer"
                )
                return captureSamples
            }
            return samples
        } catch {
            logger.warning(
                "Could not load finalized recording for transcription; using capture buffer: \(error.localizedDescription, privacy: .public)"
            )
            return captureSamples
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
            apiSessionID: sessionID,
            preferredBaseName: nil,
            transcriptMetadata: nil
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

    private var recorderTranscriptGeneration = 0

    /// Reads durable completion receipts, including manual and calendar recordings.
    func apiRecorderRecordings(since: Date? = nil) async throws -> [RecorderTranscriptReadyPayload] {
        let recorderService = recorderService
        let loader = recorderCompletionsLoader
        for _ in 0..<3 {
            let generation = recorderTranscriptGeneration
            let result = await Task.detached(priority: .utility) {
                // Earlier Recorder folders keep their recordings, so their completions are included.
                Result {
                    try recorderService.recordingsDirectories
                        .flatMap { try loader($0, since) }
                        .sorted(by: recorderCompletionPrecedes)
                }
            }.value
            try Task.checkCancellation()
            guard generation == recorderTranscriptGeneration else { continue }
            let completions = try result.get()
            guard let addingRecorderSpeakers else { return completions }
            var withSpeakers: [RecorderTranscriptReadyPayload] = []
            for completion in completions {
                withSpeakers.append(await addingRecorderSpeakers(completion, false))
            }
            return withSpeakers
        }
        throw CocoaError(.fileReadUnknown)
    }

    // MARK: - Calendar Meeting Automation

    private func updateIndicatorHidden() {
        let hidden = isMeetingRecording && !showsMeetingIndicator
        if hidden != isIndicatorHidden { isIndicatorHidden = hidden }
    }

    func startCalendarMeetingRecording(
        preferredBaseName: String,
        transcriptMetadata: CalendarMeetingTranscriptMetadata? = nil
    ) async throws -> CalendarMeetingRecordingHandle {
        // A recording already running is not the meeting's.
        if state == .idle { isMeetingRecording = true }
        let outputURL: URL
        do {
            outputURL = try await beginRecording(
                micEnabled: micEnabled,
                systemAudioEnabled: systemAudioEnabled,
                apiSessionID: nil,
                preferredBaseName: preferredBaseName,
                transcriptMetadata: transcriptMetadata
            )
        } catch {
            if state != .recording { isMeetingRecording = false }
            throw error
        }
        guard state == .recording else {
            activeCalendarMeetingHandle = nil
            throw RecorderAPIError.notRecording
        }
        let handle = CalendarMeetingRecordingHandle(id: UUID(), outputURL: outputURL)
        activeCalendarMeetingHandle = handle
        return handle
    }

    func stopCalendarMeetingRecording(
        handle: CalendarMeetingRecordingHandle
    ) throws {
        guard state == .recording else {
            activeCalendarMeetingHandle = nil
            throw RecorderAPIError.notRecording
        }
        guard activeCalendarMeetingHandle == handle else {
            throw RecorderAPIError.calendarRecordingHandleMismatch
        }
        stopRecording(apiSessionID: nil)
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

    private func completeRecorderAPISession(id: UUID, outputURL: URL, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func failRecorderAPISession(id: UUID, outputURL: URL? = nil, error: String) {
        let outputFile = outputURL?.path ?? recorderAPISessions[id]?.outputFile
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
        // A recording keeps its files until its transcript is done.
        guard transcriptionStatus(for: item) == nil else { return }
        defer { recorderTranscriptGeneration &+= 1 }

        let sidecarURLs = [
            transcriptURL(for: item.url),
            transcriptMarkdownURL(for: item.url),
            transcriptDocumentURL(for: item.url),
            transcriptReadyURL(for: item.url),
            recordingIdentityURL(for: item.url),
            transcriptionFailureURL(for: item.url)
        ]

        // The files go to the Trash, so a recording deleted by mistake can be restored.
        var trashedFiles: [(original: URL, trashed: URL)] = []
        do {
            for url in sidecarURLs + [item.url] {
                if let trashedURL = try trashRecordingFileIfPresent(at: url) {
                    trashedFiles.append((url, trashedURL))
                }
            }
            transientTranscriptionFailures.removeValue(
                forKey: transcriptionFailureKey(for: item.url)
            )
            recordings.removeAll { $0.id == item.id }
        } catch {
            // Keep the recording complete: move the files trashed so far back.
            for file in trashedFiles.reversed() {
                do {
                    try FileManager.default.moveItem(at: file.trashed, to: file.original)
                } catch {
                    logger.error(
                        "Failed to restore a recording file from the Trash after deletion failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            errorMessage = error.localizedDescription
        }
    }

    private func trashRecordingFileIfPresent(at url: URL) throws -> URL? {
        do {
            return try recordingFileTrasher(url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return nil
        }
    }

    func revealInFinder(_ item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func transcribeRecording(_ item: RecordingItem) {
        guard canTranscribeRecording(item) else { return }

        let url = item.url
        retranscribingRecordingURL = url
        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.retranscribingRecordingURL = nil
                self.loadRecordings()
            }

            let samples: [Float]
            do {
                samples = try await self.audioSamplesLoader(url)
            } catch {
                self.recordRetranscriptionFailure(
                    phase: .preparingFinalAudio,
                    error: error,
                    for: url
                )
                return
            }

            self.reconcileSelectionWithAvailablePlugins()
            let providerId = self.effectiveProviderId
            let request = FinalTranscriptionRequest(
                outputURL: url,
                buffer: samples,
                languageSelection: self.languageSelection,
                task: self.selectedTask,
                providerId: providerId,
                modelOverrideId: self.availableSelectedModel,
                prompt: self.dictionaryService.getTermsForPrompt(providerId: providerId),
                dictionaryTermHints: self.dictionaryService.getTermHints(providerId: providerId),
                liveSessionResult: nil,
                liveSessionFailed: false,
                calendarEvent: item.calendarEvent,
                detectsSpeakers: self.wantsSpeakerRecord(calendarEvent: item.calendarEvent)
            )

            _ = await self.runRetranscription(request)
        }
    }

    func isRetranscribing(_ item: RecordingItem) -> Bool {
        retranscribingRecordingURL?.standardizedFileURL == item.url.standardizedFileURL
    }

    /// Whether the recording's transcript is being made or waits for its turn.
    func transcriptionStatus(for item: RecordingItem) -> PendingTranscription.Status? {
        if isRetranscribing(item) { return .transcribing }
        guard !pendingTranscriptions.isEmpty else { return nil }
        let path = item.url.resolvingSymlinksInPath().path
        return pendingTranscriptions.first { $0.url.path == path }?.status
    }

    func canTranscribeRecording(_ item: RecordingItem) -> Bool {
        guard !isHistoryRetranscribing else { return false }
        // Queued transcripts run first, on the same engines.
        guard state == .idle, retranscribingRecordingURL == nil, finalTranscriptionJobs.isEmpty else { return false }
        guard FileManager.default.fileExists(atPath: item.url.path) else { return false }
        guard let engine = resolvedEngine else { return false }
        return modelManager.canPrepareForTranscription(engine)
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

    func loadRecordingsIfNeeded() {
        guard !hasRequestedInitialRecordingsLoad else { return }
        hasRequestedInitialRecordingsLoad = true
        loadRecordings()
    }

    func loadRecordings() {
        guard hasRequestedInitialRecordingsLoad else { return }
        let recorderService = recorderService
        let transientFailures = transientTranscriptionFailures
        let loader = recordingsLoader
        recordingsLoadGeneration += 1
        let generation = recordingsLoadGeneration

        recordingsLoadTask?.cancel()
        let worker = Task.detached(priority: .userInitiated) {
            // Recordings stay in the folder they were saved to, also after the folder changed.
            recorderService.recordingsDirectories
                .flatMap { loader($0, transientFailures) }
                .sorted { $0.date > $1.date }
        }
        recordingsLoadTask = Task { [weak self] in
            let items = await worker.value
            guard !Task.isCancelled, let self, generation == self.recordingsLoadGeneration else { return }
            self.recordings = items
        }
    }

    nonisolated private static func readRecordings(
        from directory: URL,
        transientFailures: [String: RecordingTranscriptionFailure]
    ) -> [RecordingItem] {
        guard FileManager.default.fileExists(atPath: directory.path),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aac", "caf"]
        return files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
                let date = (attrs[.creationDate] as? Date) ?? Date.distantPast
                let size = (attrs[.size] as? Int64) ?? 0
                let duration = audioDuration(for: url)
                let transcriptURL = url.deletingPathExtension().appendingPathExtension("txt")
                let transcriptDocumentURL = url
                    .deletingPathExtension()
                    .appendingPathExtension("transcript.json")
                let transcriptDocument = (try? Data(contentsOf: transcriptDocumentURL))
                    .flatMap { data -> RecordingTranscriptDocument? in
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        return try? decoder.decode(RecordingTranscriptDocument.self, from: data)
                    }
                let transcript = (try? String(contentsOf: transcriptURL, encoding: .utf8))
                    ?? transcriptDocument?.text
                let failureURL = url.appendingPathExtension("transcription-failure.json")
                let persistedFailure = (try? Data(contentsOf: failureURL))
                    .flatMap { try? JSONDecoder().decode(RecordingTranscriptionFailure.self, from: $0) }
                let failureKey = url.resolvingSymlinksInPath().path
                return RecordingItem(
                    url: url,
                    date: date,
                    duration: duration,
                    fileSize: size,
                    transcript: transcript,
                    transcriptionFailure: persistedFailure ?? transientFailures[failureKey],
                    calendarEvent: transcriptDocument?.calendarEvent
                )
            }
            .sorted { $0.date > $1.date }
    }

    nonisolated private static func audioDuration(for url: URL) -> TimeInterval {
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

    func transcriptionFailureSummary(for item: RecordingItem) -> String? {
        guard let failure = item.transcriptionFailure else { return nil }
        return String(
            format: String(localized: "recorder.transcriptionFailureSummary"),
            formattedDuration(item.duration),
            formattedFileSize(item.fileSize),
            failure.phase.displayName,
            failure.providerError
        )
    }

    // MARK: - Streaming Transcription

    private func startStreamingTranscription() {
        guard let pluginManager = PluginManager.shared else {
            logger.info("Plugin manager unavailable, skipping live transcription")
            return
        }
        reconcileSelectionWithAvailablePlugins()
        let engine = recordingEngine ?? currentRecordingEngine
        guard let providerId = engine.providerId,
              let plugin = pluginManager.transcriptionEngine(for: providerId) else {
            logger.info("No transcription engine available, skipping live transcription")
            return
        }
        // An engine runs one Recorder transcription at a time: a queued transcript
        // goes first, then the preview starts and catches up with the recording.
        guard !finalTranscriptionJobs.contains(where: { $0.usesEngine(providerId) }) else {
            logger.info("Live preview waits for a queued transcription on providerId=\(providerId, privacy: .public)")
            deferredLivePreviewGeneration = recordingGeneration
            return
        }

        livePreviewStartObserver?()
        let task = (selectedTask == .translate && !plugin.supportsTranslation(forModel: engine.modelId)) ? .transcribe : selectedTask
        streamingHandler.start(
            streamPrompt: dictionaryService.getTermsForPrompt(providerId: providerId) ?? "",
            dictionaryTermHints: dictionaryService.getTermHints(providerId: providerId),
            engineOverrideId: providerId,
            selectedProviderId: modelManager.selectedProviderId,
            languageSelection: languageSelection,
            task: task,
            cloudModelOverride: engine.modelId,
            allowLiveTranscription: true,
            stateCheck: { [weak self] in self?.state == .recording }
        )
    }

    private func startDeferredLivePreviewIfPossible() {
        guard let generation = deferredLivePreviewGeneration else { return }
        // Waits again if another queued transcript needs the engine.
        deferredLivePreviewGeneration = nil
        guard generation == recordingGeneration, state == .recording else { return }
        startStreamingTranscription()
    }

    // MARK: - Final Transcription Queue

    private func enqueueFinalTranscription(_ job: FinalTranscriptionJob) {
        finalTranscriptionJobs.append(job)
        runNextFinalTranscription()
    }

    /// Transcribes the stopped recordings one at a time, in the order they stopped.
    private func runNextFinalTranscription() {
        defer { publishTranscriptionActivity() }
        guard finalTranscriptionTask == nil, let job = finalTranscriptionJobs.first else { return }
        finalTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            var request = job.request
            switch job.audio {
            case .notNeeded:
                break
            case .finalizedFile:
                do {
                    request.buffer = try await self.loadCompleteFinalizedRecording(request.outputURL)
                } catch {
                    // A job given up when the app quit is marked as interrupted already.
                    guard !Task.isCancelled else {
                        self.finishFinalTranscription(job, outcome: .skipped, previewText: request.livePreviewText)
                        return
                    }
                    guard request.liveSessionResult != nil else {
                        self.failFinalTranscriptionAudio(job, request: request, error: error)
                        return
                    }
                    // The live session's result is still the transcript; only the
                    // speaker record needed the file.
                    logger.warning(
                        "Could not read the finalized recording for its speaker record: \(error.localizedDescription, privacy: .public)"
                    )
                    request.detectsSpeakers = false
                }
            case .capturedAudio(let capturedSamples):
                // The finished file comes first; the captured audio is the fallback.
                request.buffer = if request.liveSessionResult == nil {
                    await self.finalizedRecordingSamples(from: request.outputURL, fallback: capturedSamples)
                } else {
                    capturedSamples
                }
            }
            let result = await self.runFinalTranscription(request)
            self.finishFinalTranscription(job, outcome: result.outcome, previewText: result.previewText)
        }
    }

    /// The recording keeps its audio and is listed as not transcribed, so it can be
    /// transcribed again once its file can be read.
    private func failFinalTranscriptionAudio(
        _ job: FinalTranscriptionJob,
        request: FinalTranscriptionRequest,
        error: Error
    ) {
        logger.error("Could not read the finalized recording for transcription: \(error.localizedDescription, privacy: .public)")
        let failure = makeTranscriptionFailure(
            phase: .preparingFinalAudio,
            providerError: error.localizedDescription,
            request: request
        )
        let recordedFailure = saveTranscriptionFailure(failure, for: request.outputURL)
        errorMessage = recorderTranscriptionFailureAPISummary(recordedFailure)
        finishFinalTranscription(job, outcome: .failed(recordedFailure), previewText: request.livePreviewText)
    }

    private func finishFinalTranscription(
        _ job: FinalTranscriptionJob,
        outcome: FinalTranscriptionOutcome,
        previewText: String
    ) {
        // A job given up when the app quit has nothing left to report.
        guard finalTranscriptionJobs.first?.id == job.id else { return }
        finalTranscriptionJobs.removeFirst()
        finalTranscriptionTask = nil

        if case .transcriptSaved = outcome {
            accessibilityAnnouncementService?.announce(localizedAppText(
                "Recorder transcript saved",
                de: "Recorder-Transkript gespeichert",
                ja: "レコーダーの文字起こしを保存しました",
                zh: "录音器转录已保存"
            ))
        }

        // The preview and LiveTranscriptPlugin's panel belong to the newest recording.
        if job.recordingGeneration == recordingGeneration {
            partialText = previewText
            // A failed live session's preview stopped early, so it is only final once a
            // saved transcript replaced it.
            let previewIsFinal = if case .transcriptSaved = outcome { true } else { !job.request.liveSessionFailed }
            if job.livePreviewEnabled && previewIsFinal && !previewText.isEmpty {
                EventBus.shared.emit(.partialTranscriptionUpdate(PartialTranscriptionPayload(
                    text: previewText, isFinal: true, elapsedSeconds: job.recordingDuration
                )))
            }
        }

        loadRecordings()

        if let apiSessionID = job.apiSessionID {
            if let failure = outcome.failure {
                failRecorderAPISession(
                    id: apiSessionID,
                    outputURL: job.request.outputURL,
                    error: recorderTranscriptionFailureAPISummary(failure)
                )
            } else {
                completeRecorderAPISession(id: apiSessionID, outputURL: job.request.outputURL, text: previewText)
            }
        }

        runNextFinalTranscription()
        startDeferredLivePreviewIfPossible()
    }

    /// Called when the app quits. A recording whose transcript is not saved yet keeps
    /// its audio and is listed as not transcribed, with the reason, so it can be
    /// transcribed after the next launch. A crash leaves it without a transcript too.
    func markPendingTranscriptionsInterrupted() {
        let jobs = finalTranscriptionJobs
        guard !jobs.isEmpty else { return }
        finalTranscriptionJobs.removeAll()
        finalTranscriptionTask?.cancel()
        finalTranscriptionTask = nil
        // A job can be past its transcript, adding the speaker record.
        for job in jobs where !FileManager.default.fileExists(atPath: transcriptURL(for: job.request.outputURL).path) {
            let failure = makeTranscriptionFailure(
                phase: .finalTranscription,
                providerError: String(localized: "recorder.transcriptionInterruptedError"),
                request: job.request
            )
            saveTranscriptionFailure(failure, for: job.request.outputURL)
        }
        publishTranscriptionActivity()
    }

    private func publishTranscriptionActivity() {
        let pending = finalTranscriptionJobs.enumerated().map { index, job in
            PendingTranscription(
                id: job.id,
                url: job.request.outputURL.resolvingSymlinksInPath(),
                status: index == 0 && finalTranscriptionTask != nil ? .transcribing : .waiting
            )
        }
        if pendingTranscriptions != pending {
            pendingTranscriptions = pending
        }
        let transcribing = isLivePreviewStreaming || !finalTranscriptionJobs.isEmpty
        if isTranscribing != transcribing {
            isTranscribing = transcribing
        }
    }

    /// `previewText` is what the recording's preview shows afterwards: the saved
    /// transcript, or the preview from when the recording stopped.
    private func runFinalTranscription(
        _ request: FinalTranscriptionRequest
    ) async -> (outcome: FinalTranscriptionOutcome, previewText: String) {
        // A failed live session's preview stopped at the failure, so it never stands in
        // for the transcript.
        let preview = request.livePreviewText
        let previewCanBeTranscript = !request.liveSessionFailed
        // A live session's job holds audio only for a speaker record, so the captured
        // length decides for it.
        let sampleCount = request.liveSessionResult == nil ? request.buffer.count : request.capturedSampleCount
        guard sampleCount > 8000 else { // At least 0.5s of audio
            // Use streaming result as final if buffer too short
            if previewCanBeTranscript, !preview.isEmpty {
                return (saveTranscriptOutcome(preview, for: request.outputURL, request: request), preview)
            } else if let liveSessionResult = request.liveSessionResult {
                let text = liveSessionResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return (saveTranscriptOutcome(text, for: request.outputURL, request: request), text)
                }
            }
            return (.skipped, preview)
        }

        // Fall back to transcribe if engine doesn't support translation
        let effectiveTask = resolvedTask(for: request)

        do {
            let result = if let liveSessionResult = request.liveSessionResult {
                liveSessionResult
            } else {
                try await transcribeFinalRecording(request, task: effectiveTask)
            }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                // The transcript is saved first; adding the speaker record can take seconds.
                let (outcome, payload) = savingTranscript(text, for: request.outputURL, request: request)
                let speakerRecordID = await addSpeakerRecordIfWanted(
                    result, request: request, recordingID: payload?.recordingID
                )
                announce(payload, waitingForSpeakers: speakerRecordID != nil)
                return (outcome, text)
            } else if previewCanBeTranscript, !preview.isEmpty {
                return (saveTranscriptOutcome(preview, for: request.outputURL, request: request), preview)
            } else {
                let failure = makeTranscriptionFailure(
                    phase: .emptyResult,
                    providerError: String(localized: "recorder.emptyFinalTranscriptionError"),
                    request: request
                )
                let recordedFailure = saveTranscriptionFailure(failure, for: request.outputURL)
                errorMessage = recorderTranscriptionFailureAPISummary(recordedFailure)
                return (.failed(recordedFailure), preview)
            }
        } catch is CancellationError {
            return (.skipped, preview)
        } catch is RecordingHasNoSpeech {
            // A preview of a recording without speech is text the engine made up.
            return (recordNoSpeech(for: request), "")
        } catch {
            logger.error("Final transcription failed: \(error.localizedDescription)")
            // A WhisperKit error can mean that entire audio chunks are missing.
            // Its live preview must not turn that failure into a completed recording.
            if request.providerId != "whisper", previewCanBeTranscript, !preview.isEmpty {
                return (saveTranscriptOutcome(preview, for: request.outputURL, request: request), preview)
            }
            let failure = makeTranscriptionFailure(
                phase: .finalTranscription,
                providerError: error.localizedDescription,
                request: request
            )
            let recordedFailure = saveTranscriptionFailure(failure, for: request.outputURL)
            errorMessage = recorderTranscriptionFailureAPISummary(recordedFailure)
            return (.failed(recordedFailure), preview)
        }
    }

    private func runRetranscription(_ request: FinalTranscriptionRequest) async -> FinalTranscriptionOutcome {
        let effectiveTask = resolvedTask(for: request)

        do {
            let result = try await transcribeFinalRecording(request, task: effectiveTask)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                let failure = makeTranscriptionFailure(
                    phase: .emptyResult,
                    providerError: String(localized: "recorder.emptyFinalTranscriptionError"),
                    request: request
                )
                let recordedFailure = saveTranscriptionFailure(failure, for: request.outputURL)
                errorMessage = recorderTranscriptionFailureAPISummary(recordedFailure)
                return .failed(recordedFailure)
            }

            let (outcome, payload) = savingTranscript(text, for: request.outputURL, request: request)
            // A recording that already has its speaker record keeps it; the
            // intake tells them apart by the recording ID.
            if let payload {
                let speakerRecordID = await addSpeakerRecordIfWanted(
                    result, request: request, recordingID: payload.recordingID
                )
                announce(payload, waitingForSpeakers: speakerRecordID != nil)
            }
            return outcome
        } catch is CancellationError {
            return .skipped
        } catch is RecordingHasNoSpeech {
            return recordNoSpeech(for: request)
        } catch {
            recordRetranscriptionFailure(
                phase: .finalTranscription,
                error: error,
                for: request.outputURL,
                request: request
            )
            let failure = loadTranscriptionFailure(for: request.outputURL)
                ?? transientTranscriptionFailures[transcriptionFailureKey(for: request.outputURL)]
            if let failure {
                return .failed(failure)
            }
            return .skipped
        }
    }

    /// Calendar-meeting recordings detect speakers unless that was turned off;
    /// other recordings follow the Recorder's switch. The intake checks Premium.
    private func wantsSpeakerRecord(calendarEvent: CalendarMeetingTranscriptMetadata?) -> Bool {
        calendarEvent != nil
            ? defaults.object(forKey: UserDefaultsKeys.calendarMeetingDetectSpeakers) as? Bool ?? true
            : detectSpeakers
    }

    /// Returns the History record's ID, or nil when no speaker record was wanted or saved.
    private func addSpeakerRecordIfWanted(
        _ result: TranscriptionResult,
        request: FinalTranscriptionRequest,
        recordingID: UUID?
    ) async -> UUID? {
        guard request.detectsSpeakers, let speakerRecordIntake else { return nil }
        return await speakerRecordIntake(SpeakerRecordingInput(
            result: result,
            samples: request.buffer,
            title: request.outputURL.deletingPathExtension().lastPathComponent,
            source: .recorder,
            modelUsed: request.modelOverrideId,
            ownSpeech: request.ownSpeech,
            recorderRecordingID: recordingID
        ))
    }

    /// The engine gets only the parts of the recording that hold speech; the
    /// result's times are on the recording's timeline again.
    private func transcribeFinalRecording(
        _ request: FinalTranscriptionRequest,
        task: TranscriptionTask
    ) async throws -> TranscriptionResult {
        let speechOnlyAudio = try await speechOnlyAudio(for: request)
        let result = try await transcribeFinalRecording(
            request,
            samples: speechOnlyAudio?.samples ?? request.buffer,
            task: task
        )
        return speechOnlyAudio?.restoringOriginalTimes(of: result) ?? result
    }

    /// `nil` sends the whole recording: it is speech throughout, or detection failed.
    private func speechOnlyAudio(for request: FinalTranscriptionRequest) async throws -> SpeechOnlyAudio? {
        let regions: [ClosedRange<TimeInterval>]
        do {
            regions = try await speechRegionDetector.speechRegions(in: request.buffer)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning(
                "Speech detection failed; transcribing the whole recording: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        try Task.checkCancellation()
        guard !regions.isEmpty else {
            logger.info("Speech detection found no speech; the recording is not transcribed")
            throw RecordingHasNoSpeech()
        }

        // Copying a long recording would hold up the main actor.
        let samples = request.buffer
        let speechOnlyAudio = await Task.detached(priority: .userInitiated) {
            SpeechOnlyAudio(
                samples: samples,
                sampleRate: AudioRecorderService.transcriptionSampleRate,
                speechRegions: regions
            )
        }.value
        try Task.checkCancellation()
        if let speechOnlyAudio {
            logger.info(
                "Transcribing speech only [parts=\(speechOnlyAudio.parts.count, privacy: .public), speechDuration=\(Double(speechOnlyAudio.samples.count) / AudioRecorderService.transcriptionSampleRate, privacy: .public), audioDuration=\(speechOnlyAudio.originalDuration, privacy: .public)]"
            )
        }
        return speechOnlyAudio
    }

    private func recordNoSpeech(for request: FinalTranscriptionRequest) -> FinalTranscriptionOutcome {
        let failure = makeTranscriptionFailure(
            phase: .emptyResult,
            providerError: String(localized: "recorder.noSpeechDetectedError"),
            request: request
        )
        let recordedFailure = saveTranscriptionFailure(failure, for: request.outputURL)
        errorMessage = recorderTranscriptionFailureAPISummary(recordedFailure)
        return .failed(recordedFailure)
    }

    private func transcribeFinalRecording(
        _ request: FinalTranscriptionRequest,
        samples: [Float],
        task: TranscriptionTask
    ) async throws -> TranscriptionResult {
        let initialPass = try await transcribeFinalRecordingPass(
            request,
            samples: samples,
            task: task,
            prompt: request.prompt,
            dictionaryTermHints: request.dictionaryTermHints
        )
        try Task.checkCancellation()

        guard try await shouldRetryWhisperKitWithoutConditioning(
            request: request,
            samples: samples,
            pass: initialPass
        ) else {
            return initialPass.result
        }

        logger.warning(
            "WhisperKit final transcription stopped with audible audio remaining; retrying without dictionary conditioning [processedDuration=\(initialPass.processedDuration, privacy: .public), audioDuration=\(initialPass.result.duration, privacy: .public)]"
        )

        // This retry was needed because the first result left audible audio out.
        // If it fails, persist the failure instead of declaring that first result complete.
        try Task.checkCancellation()
        let retryPass = try await transcribeFinalRecordingPass(
            request,
            samples: samples,
            task: task,
            prompt: nil,
            dictionaryTermHints: []
        )
        return preferredFinalTranscriptionResult(initial: initialPass, retry: retryPass)
    }

    private struct FinalTranscriptionPass {
        let result: TranscriptionResult
        let processedDuration: TimeInterval
    }

    private func transcribeFinalRecordingPass(
        _ request: FinalTranscriptionRequest,
        samples: [Float],
        task: TranscriptionTask,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint]
    ) async throws -> FinalTranscriptionPass {
        let progressCapture = RecorderTranscriptionSourceProgressCapture()
        let result = try await modelManager.transcribe(
            audioSamples: samples,
            languageSelection: request.languageSelection,
            task: task,
            engineOverrideId: request.providerId,
            cloudModelOverride: request.modelOverrideId,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            onProgress: { _ in true },
            onSourceProgress: progressCapture.record
        )
        let summary = result.diagnosticSummary(
            audioDuration: Double(samples.count) / AudioRecorderService.transcriptionSampleRate
        )
        logger.info(
            "Recorder transcription result [engine=\(request.providerId ?? "default", privacy: .public), task=\(task.rawValue, privacy: .public), promptChars=\(prompt?.count ?? 0, privacy: .public), \(summary, privacy: .public)]"
        )
        let segmentDuration = result.segments
            .map(\.end)
            .filter(\.isFinite)
            .max() ?? 0
        return FinalTranscriptionPass(
            result: result,
            processedDuration: max(progressCapture.processedDuration, segmentDuration)
        )
    }

    private func shouldRetryWhisperKitWithoutConditioning(
        request: FinalTranscriptionRequest,
        samples: [Float],
        pass: FinalTranscriptionPass
    ) async throws -> Bool {
        guard request.providerId == "whisper",
              let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            return false
        }

        let text = pass.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let audioDuration = Double(samples.count) / AudioRecorderService.transcriptionSampleRate
        let analysisStartTime: TimeInterval
        if text.isEmpty {
            analysisStartTime = 0
        } else {
            guard audioDuration >= 60,
                  pass.processedDuration > 0,
                  audioDuration - pass.processedDuration >= 30 else {
                return false
            }
            analysisStartTime = pass.processedDuration
        }

        let analysisTask = Task.detached(priority: .utility) {
            recorderAudioHasAudibleTail(
                samples: samples,
                startingAt: analysisStartTime
            )
        }
        let hasAudibleAudio = await withTaskCancellationHandler {
            await analysisTask.value
        } onCancel: {
            analysisTask.cancel()
        }
        try Task.checkCancellation()
        return hasAudibleAudio
    }

    private func preferredFinalTranscriptionResult(
        initial: FinalTranscriptionPass,
        retry: FinalTranscriptionPass
    ) -> TranscriptionResult {
        let initialText = initial.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let retryText = retry.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !retryText.isEmpty else { return initial.result }
        guard !initialText.isEmpty else { return retry.result }

        if retry.processedDuration > initial.processedDuration + 5 {
            return retry.result
        }
        if retryText.count > Int(Double(initialText.count) * 1.2) {
            return retry.result
        }
        return initial.result
    }

    private func resolvedTask(for request: FinalTranscriptionRequest) -> TranscriptionTask {
        guard request.task == .translate,
              let providerId = request.providerId,
              let plugin = PluginManager.shared?.transcriptionEngine(for: providerId),
              !plugin.supportsTranslation(forModel: request.modelOverrideId) else {
            return request.task
        }
        return .transcribe
    }

    private func recordRetranscriptionFailure(
        phase: RecordingTranscriptionFailure.Phase,
        error: Error,
        for audioURL: URL,
        request: FinalTranscriptionRequest? = nil
    ) {
        let request = request ?? FinalTranscriptionRequest(
            outputURL: audioURL,
            buffer: [],
            languageSelection: languageSelection,
            task: selectedTask,
            providerId: effectiveProviderId,
            modelOverrideId: availableSelectedModel,
            prompt: nil,
            dictionaryTermHints: [],
            liveSessionResult: nil,
            liveSessionFailed: false,
            calendarEvent: nil
        )
        let failure = makeTranscriptionFailure(
            phase: phase,
            providerError: error.localizedDescription,
            request: request
        )
        let recordedFailure = saveTranscriptionFailure(failure, for: audioURL)
        errorMessage = recorderTranscriptionFailureAPISummary(recordedFailure)
    }

    // MARK: - Transcript Sidecar

    private func transcriptURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("txt")
    }

    private func saveTranscript(
        _ text: String,
        for audioURL: URL,
        calendarEvent: CalendarMeetingTranscriptMetadata?
    ) throws -> RecorderTranscriptReadyPayload {
        defer { recorderTranscriptGeneration &+= 1 }
        let audioURL = audioURL.resolvingSymlinksInPath()
        let txtURL = transcriptURL(for: audioURL)
        guard try isRegularRecorderAutomationFile(audioURL) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: audioURL.path])
        }
        let receiptURL = transcriptReadyURL(for: audioURL)
        let identity = try recordingIdentity(for: audioURL)
        // The header holds the length; the samples are not read.
        let duration = (try? AVAudioFile(forReading: audioURL)).map {
            Double($0.length) / $0.fileFormat.sampleRate
        } ?? 0
        let payload = RecorderTranscriptReadyPayload(
            recordingID: identity.recordingID,
            text: text,
            audioFilePath: audioURL.path,
            transcriptFilePath: txtURL.path,
            markdownFilePath: calendarEvent == nil ? nil : transcriptMarkdownURL(for: audioURL).path,
            recordedAt: (try? FileManager.default.attributesOfItem(atPath: audioURL.path))?[.creationDate] as? Date,
            durationSeconds: duration.isFinite && duration > 0 ? duration : nil,
            calendarEvent: calendarEvent?.recorderCalendarEvent
        )
        var writes = [RecordingFileWrite(url: txtURL, data: Data(text.utf8))]
        if let calendarEvent {
            writes += try transcriptDocumentWrites(
                text: text,
                calendarEvent: calendarEvent,
                for: audioURL
            )
        }
        writes.append(RecordingFileWrite(url: recordingIdentityURL(for: audioURL), data: try JSONEncoder().encode(identity)))
        writes.append(RecordingFileWrite(url: receiptURL, data: try JSONEncoder().encode(payload)))
        try writeRecordingFilesTransactionally(writes)
        clearTranscriptionFailure(for: audioURL)
        return payload
    }

    private func transcriptReadyURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("transcript-ready.json")
    }

    private struct RecordingIdentity: Codable {
        let recordingID: UUID

        private enum CodingKeys: String, CodingKey {
            case recordingID = "recording_id"
        }
    }

    private func recordingIdentityURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("recording-id.json")
    }

    private func recordingIdentity(for audioURL: URL) throws -> RecordingIdentity {
        var foundExistingIdentity = false
        // Either copy can recover the stable ID after the other is damaged. Reading only
        // the identity also permits repairing receipts with invalid completion fields.
        for url in [recordingIdentityURL(for: audioURL), transcriptReadyURL(for: audioURL)] {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            }
            foundExistingIdentity = true
            if let identity = try? JSONDecoder().decode(RecordingIdentity.self, from: data) {
                return identity
            }
        }
        // Losing both copies must not silently split one recording into a new identity.
        guard !foundExistingIdentity else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: audioURL.path])
        }
        return RecordingIdentity(recordingID: UUID())
    }

    private func transcriptDocumentURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    private func transcriptMarkdownURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("transcript.md")
    }

    private func saveTranscriptDocument(
        text: String?,
        calendarEvent: CalendarMeetingTranscriptMetadata,
        for audioURL: URL
    ) throws {
        try writeRecordingFilesTransactionally(
            try transcriptDocumentWrites(
                text: text,
                calendarEvent: calendarEvent,
                for: audioURL
            )
        )
    }

    private struct RecordingFileWrite {
        let url: URL
        let data: Data
    }

    private struct RecordingFileCommit {
        let write: RecordingFileWrite
        let stagedURL: URL
        let backupURL: URL?
        var installedNewFile: Bool
    }

    private func transcriptDocumentWrites(
        text: String?,
        calendarEvent: CalendarMeetingTranscriptMetadata,
        for audioURL: URL
    ) throws -> [RecordingFileWrite] {
        let document = RecordingTranscriptDocument(
            text: text,
            calendarEvent: calendarEvent
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let markdown = RecordingTranscriptMarkdownRenderer.render(document)
        return [
            RecordingFileWrite(url: transcriptDocumentURL(for: audioURL), data: data),
            RecordingFileWrite(url: transcriptMarkdownURL(for: audioURL), data: Data(markdown.utf8))
        ]
    }

    private func writeRecordingFilesTransactionally(_ writes: [RecordingFileWrite]) throws {
        let fileManager = FileManager.default
        var stagedWrites: [(write: RecordingFileWrite, stagedURL: URL)] = []
        var commits: [RecordingFileCommit] = []

        do {
            for write in writes {
                let stagedURL = temporarySiblingURL(for: write.url, suffix: "staged")
                try write.data.write(to: stagedURL, options: .atomic)
                stagedWrites.append((write, stagedURL))
            }

            for stagedWrite in stagedWrites {
                let backupURL: URL?
                if fileManager.fileExists(atPath: stagedWrite.write.url.path) {
                    let url = temporarySiblingURL(for: stagedWrite.write.url, suffix: "backup")
                    try fileManager.moveItem(at: stagedWrite.write.url, to: url)
                    backupURL = url
                } else {
                    backupURL = nil
                }

                commits.append(RecordingFileCommit(
                    write: stagedWrite.write,
                    stagedURL: stagedWrite.stagedURL,
                    backupURL: backupURL,
                    installedNewFile: false
                ))
                try fileManager.moveItem(at: stagedWrite.stagedURL, to: stagedWrite.write.url)
                commits[commits.count - 1].installedNewFile = true
            }
        } catch {
            for commit in commits.reversed() {
                if commit.installedNewFile,
                   fileManager.fileExists(atPath: commit.write.url.path) {
                    try? fileManager.removeItem(at: commit.write.url)
                }
                if let backupURL = commit.backupURL,
                   fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.moveItem(at: backupURL, to: commit.write.url)
                }
            }
            for stagedWrite in stagedWrites where fileManager.fileExists(atPath: stagedWrite.stagedURL.path) {
                try? fileManager.removeItem(at: stagedWrite.stagedURL)
            }
            throw error
        }

        for commit in commits {
            if let backupURL = commit.backupURL,
               fileManager.fileExists(atPath: backupURL.path) {
                do {
                    try fileManager.removeItem(at: backupURL)
                } catch {
                    logger.error(
                        "Failed to remove transcript backup: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    private func temporarySiblingURL(for url: URL, suffix: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).\(suffix)"
        )
    }

    private func loadTranscript(for audioURL: URL) -> String? {
        let txtURL = transcriptURL(for: audioURL)
        return try? String(contentsOf: txtURL, encoding: .utf8)
    }

    private func saveTranscriptOutcome(
        _ text: String,
        for audioURL: URL,
        request: FinalTranscriptionRequest
    ) -> FinalTranscriptionOutcome {
        let (outcome, payload) = savingTranscript(text, for: audioURL, request: request)
        announce(payload, waitingForSpeakers: false)
        return outcome
    }

    /// Emits a saved completion. With a speaker record it waits for the record's
    /// speakers, without holding up the next recording's transcription.
    private func announce(_ payload: RecorderTranscriptReadyPayload?, waitingForSpeakers: Bool) {
        guard let payload else { return }
        guard waitingForSpeakers, let addingRecorderSpeakers else {
            EventBus.shared.emit(.recorderTranscriptReady(payload))
            return
        }
        Task { @MainActor in
            EventBus.shared.emit(.recorderTranscriptReady(await addingRecorderSpeakers(payload, true)))
        }
    }

    /// Saves the transcript without emitting its completion, which is returned.
    private func savingTranscript(
        _ text: String,
        for audioURL: URL,
        request: FinalTranscriptionRequest
    ) -> (FinalTranscriptionOutcome, RecorderTranscriptReadyPayload?) {
        do {
            let payload = try saveTranscript(
                text,
                for: audioURL,
                calendarEvent: request.calendarEvent
            )
            return (.transcriptSaved(recordingID: payload.recordingID), payload)
        } catch {
            logger.error("Failed to save transcript: \(error.localizedDescription)")
            let failure = makeTranscriptionFailure(
                phase: .savingTranscript,
                providerError: error.localizedDescription,
                request: request
            )
            let recordedFailure = saveTranscriptionFailure(failure, for: audioURL)
            errorMessage = recorderTranscriptionFailureAPISummary(recordedFailure)
            return (.failed(recordedFailure), nil)
        }
    }

    private func transcriptionFailureURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("transcription-failure.json")
    }

    private func transcriptionFailureKey(for audioURL: URL) -> String {
        audioURL.resolvingSymlinksInPath().path
    }

    private func makeTranscriptionFailure(
        phase: RecordingTranscriptionFailure.Phase,
        providerError: String,
        request: FinalTranscriptionRequest
    ) -> RecordingTranscriptionFailure {
        RecordingTranscriptionFailure(
            phase: phase,
            providerError: providerError,
            engineName: request.providerId.flatMap { providerId in
                PluginManager.shared?.transcriptionEngine(for: providerId)?.providerDisplayName
            },
            modelName: modelManager.resolvedModelDisplayName(
                engineOverrideId: request.providerId,
                cloudModelOverride: request.modelOverrideId
            ),
            failedAt: Date()
        )
    }

    @discardableResult
    private func saveTranscriptionFailure(
        _ failure: RecordingTranscriptionFailure,
        for audioURL: URL
    ) -> RecordingTranscriptionFailure {
        let url = transcriptionFailureURL(for: audioURL)
        let key = transcriptionFailureKey(for: audioURL)
        do {
            let data = try JSONEncoder().encode(failure)
            try data.write(to: url, options: .atomic)
            transientTranscriptionFailures.removeValue(forKey: key)
            return failure
        } catch {
            logger.error("Failed to save recorder transcription failure: \(error.localizedDescription)")
            let surfacedFailure = RecordingTranscriptionFailure(
                phase: failure.phase,
                providerError: String(
                    format: String(localized: "recorder.failureMetadataSaveError"),
                    failure.providerError,
                    error.localizedDescription
                ),
                engineName: failure.engineName,
                modelName: failure.modelName,
                failedAt: failure.failedAt
            )
            transientTranscriptionFailures[key] = surfacedFailure
            return surfacedFailure
        }
    }

    private func loadTranscriptionFailure(for audioURL: URL) -> RecordingTranscriptionFailure? {
        let url = transcriptionFailureURL(for: audioURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingTranscriptionFailure.self, from: data)
    }

    private func clearTranscriptionFailure(for audioURL: URL) {
        transientTranscriptionFailures.removeValue(forKey: transcriptionFailureKey(for: audioURL))
        try? FileManager.default.removeItem(at: transcriptionFailureURL(for: audioURL))
    }

    private func recorderTranscriptionFailureAPISummary(_ failure: RecordingTranscriptionFailure) -> String {
        String(
            format: String(localized: "recorder.transcriptionFailureAPISummary"),
            failure.phase.displayName,
            failure.providerError
        )
    }
}

#if DEBUG
extension AudioRecorderViewModel {
    /// The audio samples each queued transcription holds while it waits, for tests.
    var queuedFinalTranscriptionSampleCounts: [Int] {
        finalTranscriptionJobs.map { job in
            let capturedSampleCount = if case .capturedAudio(let samples) = job.audio { samples.count } else { 0 }
            return job.request.buffer.count + capturedSampleCount
        }
    }

    /// Screenshot fixture: a meeting is recorded while the two meetings before it
    /// wait for their transcripts.
    func prepareScreenshotQueueFixture() {
        guard AppConstants.isScreenshotAutomation else { return }
        let directory = recorderService.recordingsDirectory
        let now = AppConstants.screenshotFixtureReferenceDate
        func recording(_ name: String, minutesAgo: Double, duration: TimeInterval, transcript: String? = nil) -> RecordingItem {
            RecordingItem(
                url: directory.appendingPathComponent(name),
                date: now.addingTimeInterval(-minutesAgo * 60),
                duration: duration,
                fileSize: Int64(duration * 32_000),
                transcript: transcript,
                transcriptionFailure: nil
            )
        }
        let designReview = recording("Design Review.wav", minutesAgo: 13, duration: 1_846)
        let customerCall = recording("Customer Call.wav", minutesAgo: 62, duration: 2_874)
        let standup = recording(
            "Team Standup.wav", minutesAgo: 150, duration: 912,
            transcript: "Quick round: the release branch is ready, QA starts tomorrow."
        )

        // The fixture list replaces the folder's contents.
        recordingsLoadTask?.cancel()
        recordingsLoadGeneration += 1
        hasRequestedInitialRecordingsLoad = true
        recordings = [designReview, customerCall, standup]
        pendingTranscriptions = [
            PendingTranscription(id: UUID(), url: customerCall.url.resolvingSymlinksInPath(), status: .transcribing),
            PendingTranscription(id: UUID(), url: designReview.url.resolvingSymlinksInPath(), status: .waiting)
        ]
        isTranscribing = true
        systemAudioEnabled = true
        // After the recorder service's first values, which would reset these.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            state = .recording
            duration = 754
            micLevel = 0.3
            systemLevel = 0.45
            deferredLivePreviewGeneration = recordingGeneration
        }
    }
}
#endif

private extension CalendarMeetingTranscriptMetadata {
    var recorderCalendarEvent: RecorderCalendarEvent {
        func participant(_ participant: CalendarMeetingParticipant) -> RecorderCalendarParticipant {
            RecorderCalendarParticipant(
                name: participant.name,
                email: participant.emailAddress,
                status: participant.status.rawValue,
                isCurrentUser: participant.isCurrentUser
            )
        }
        return RecorderCalendarEvent(
            title: title,
            start: startDate,
            end: endDate,
            location: location,
            organizer: organizer.map(participant),
            attendees: attendees.map(participant)
        )
    }
}
