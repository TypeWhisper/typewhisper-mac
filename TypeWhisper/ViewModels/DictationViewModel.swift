import AppKit
import ApplicationServices
import Foundation
import Combine
import os
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "DictationViewModel")

struct DictationSessionTranscription: Sendable, Equatable {
    let text: String
    let rawText: String
    let timestamp: Date
    let appName: String?
    let appBundleIdentifier: String?
    let appURL: String?
    let duration: Double
    let language: String?
    let engine: String
    let model: String?
    let wordsCount: Int
}

struct DictationSessionSnapshot: Sendable, Equatable {
    enum Status: String, Sendable {
        case recording
        case processing
        case completed
        case failed
    }

    let id: UUID
    let status: Status
    let transcription: DictationSessionTranscription?
    let error: String?
}

@MainActor
enum DictationLanguageResolver {
    static func resolve(
        workflow: Workflow?,
        globalLanguageSelection: LanguageSelection
    ) -> LanguageSelection {
        if let workflow {
            let workflowSelection = workflow.inputLanguageSelection
            if workflowSelection != .inheritGlobal {
                return workflowSelection
            }
        }

        return globalLanguageSelection
    }
}

@MainActor
enum DictationTranscriptionOverrideResolver {
    static func engineId(for workflow: Workflow?) -> String? {
        guard workflow?.template == .dictation else { return nil }
        return trimmed(workflow?.behavior.transcriptionEngineId)
    }

    static func modelId(for workflow: Workflow?) -> String? {
        guard engineId(for: workflow) != nil else { return nil }
        return trimmed(workflow?.behavior.transcriptionModelId)
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Orchestrates the dictation flow: recording → transcription → text insertion.
@MainActor
final class DictationViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: DictationViewModel?
    static var shared: DictationViewModel {
        guard let instance = _shared else {
            fatalError("DictationViewModel not initialized")
        }
        return instance
    }

    enum State: Equatable {
        case idle
        case recording
        case processing
        case inserting
        case promptSelection(String)    // text ready, user picks a prompt
        case promptProcessing(String)   // prompt name, LLM running
        case error(String)
    }

    private enum CancelWarningTarget {
        case recording
        case processing
    }

    @Published var state: State = .idle {
        didSet { clearCancelWarningIfStateNoLongerMatches() }
    }
    @Published var audioLevel: Float = 0
    @Published var recordingDuration: TimeInterval = 0
    @Published var hotkeyMode: HotkeyService.HotkeyMode?
    @Published var partialText: String = ""
    @Published var isStreaming: Bool = false
    @Published private(set) var externalStreamingDisplayCount: Int = 0
    @Published var audioDuckingEnabled: Bool {
        didSet { UserDefaults.standard.set(audioDuckingEnabled, forKey: UserDefaultsKeys.audioDuckingEnabled) }
    }
    @Published var audioDuckingLevel: Double {
        didSet { UserDefaults.standard.set(audioDuckingLevel, forKey: UserDefaultsKeys.audioDuckingLevel) }
    }
    @Published var soundFeedbackEnabled: Bool {
        didSet { UserDefaults.standard.set(soundFeedbackEnabled, forKey: UserDefaultsKeys.soundFeedbackEnabled) }
    }
    @Published var indicatorTranscriptPreviewEnabled: Bool {
        didSet { Self.persistIndicatorTranscriptPreviewEnabled(indicatorTranscriptPreviewEnabled) }
    }
    @Published var indicatorTranscriptPreviewFontSizeOffset: Int {
        didSet {
            let clampedOffset = Self.clampedIndicatorTranscriptPreviewFontSizeOffset(indicatorTranscriptPreviewFontSizeOffset)
            if clampedOffset != indicatorTranscriptPreviewFontSizeOffset {
                indicatorTranscriptPreviewFontSizeOffset = clampedOffset
                return
            }

            Self.persistIndicatorTranscriptPreviewFontSizeOffset(clampedOffset)
        }
    }
    @Published var preserveClipboard: Bool {
        didSet { UserDefaults.standard.set(preserveClipboard, forKey: UserDefaultsKeys.preserveClipboard) }
    }
    @Published var mediaPauseEnabled: Bool {
        didSet { UserDefaults.standard.set(mediaPauseEnabled, forKey: UserDefaultsKeys.mediaPauseEnabled) }
    }
    @Published var transcribeShortQuietClipsAggressively: Bool {
        didSet { Self.persistTranscribeShortQuietClipsAggressively(transcribeShortQuietClipsAggressively) }
    }
    @Published var microphoneBoostEnabled: Bool {
        didSet {
            Self.persistMicrophoneBoostEnabled(microphoneBoostEnabled)
            applyEffectiveMicrophoneBoostToAudioService()
        }
    }
    @Published var spokenFeedbackEnabled: Bool {
        didSet { speechFeedbackService.spokenFeedbackEnabled = spokenFeedbackEnabled }
    }
    @Published private(set) var lastTranscribedText: String?
    @Published private(set) var lastTranscriptionLanguage: String?
    @Published var hotkeyLabelsVersion = 0
    var hybridHotkeyLabel: String { Self.loadHotkeyLabel(for: .hybrid) }
    var pttHotkeyLabel: String { Self.loadHotkeyLabel(for: .pushToTalk) }
    var toggleHotkeyLabel: String { Self.loadHotkeyLabel(for: .toggle) }
    var promptPaletteHotkeyLabel: String { Self.loadHotkeyLabel(for: .promptPalette) }
    var recentTranscriptionsHotkeyLabel: String { Self.loadHotkeyLabel(for: .recentTranscriptions) }
    var copyLastTranscriptionHotkeyLabel: String { Self.loadHotkeyLabel(for: .copyLastTranscription) }
    var recorderToggleHotkeyLabel: String { Self.loadHotkeyLabel(for: .recorderToggle) }
    @Published var activeRuleName: String?
    @Published var activeRuleReasonLabel: String?
    @Published var activeRuleExplanation: String?
    @Published var processingPhase: String?
    @Published private(set) var isRecordingInputReady = false
    @Published var actionFeedbackMessage: String?
    @Published var actionFeedbackIcon: String?
    @Published var actionFeedbackIsError: Bool = false
    @Published var actionFeedbackUndoTitle: String?
    @Published var activeAppIcon: NSImage?
    private var actionDisplayDuration: TimeInterval = 3.5

    @Published var indicatorStyle: IndicatorStyle {
        didSet { Self.persistIndicatorStyle(indicatorStyle) }
    }

    @Published var notchIndicatorVisibility: NotchIndicatorVisibility {
        didSet { UserDefaults.standard.set(notchIndicatorVisibility.rawValue, forKey: UserDefaultsKeys.notchIndicatorVisibility) }
    }

    @Published var notchIndicatorLeftContent: NotchIndicatorContent {
        didSet { UserDefaults.standard.set(notchIndicatorLeftContent.rawValue, forKey: UserDefaultsKeys.notchIndicatorLeftContent) }
    }

    @Published var notchIndicatorRightContent: NotchIndicatorContent {
        didSet { UserDefaults.standard.set(notchIndicatorRightContent.rawValue, forKey: UserDefaultsKeys.notchIndicatorRightContent) }
    }

    @Published var notchIndicatorDisplay: NotchIndicatorDisplay {
        didSet { UserDefaults.standard.set(notchIndicatorDisplay.rawValue, forKey: UserDefaultsKeys.notchIndicatorDisplay) }
    }

    @Published var overlayPosition: OverlayPosition {
        didSet { UserDefaults.standard.set(overlayPosition.rawValue, forKey: UserDefaultsKeys.overlayPosition) }
    }

    private let audioRecordingService: AudioRecordingService
    private let textInsertionService: TextInsertionService
    private let hotkeyService: HotkeyService
    private let modelManager: ModelManagerService
    private let settingsViewModel: SettingsViewModel
    private let historyService: HistoryService
    private let recentTranscriptionStore: RecentTranscriptionStore
    private let profileService: ProfileService
    private let workflowService: WorkflowService
    private let translationService: AnyObject? // TranslationService (macOS 15+)
    private let audioDuckingService: AudioDuckingService
    private let dictionaryService: DictionaryService
    private let licenseService: LicenseService?
    private let targetAppCorrectionLearningService: TargetAppCorrectionLearningService
    private let snippetService: SnippetService
    private let soundService: SoundService
    private let audioDeviceService: AudioDeviceService
    private let promptActionService: PromptActionService
    private let promptProcessingService: PromptProcessingService
    private let workflowTextProcessingService: WorkflowTextProcessingService
    private let speechFeedbackService: SpeechFeedbackService
    private let accessibilityAnnouncementService: AccessibilityAnnouncementService
    private let errorLogService: ErrorLogService
    private let mediaPlaybackService: MediaPlaybackService
    private let postProcessingPipeline: PostProcessingPipeline
    private var matchedWorkflow: Workflow?
    private var activeWorkflowMatch: WorkflowMatchResult?
    private var forcedWorkflowId: UUID?
    private var capturedActiveApp: (name: String?, bundleId: String?, url: String?)?
    private var capturedSelectedText: String?

    private var cancellables = Set<AnyCancellable>()
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private let streamingHandler: StreamingHandler
    private let promptPaletteHandler: PromptPaletteHandler
    private let recentTranscriptionPaletteHandler: RecentTranscriptionPaletteHandler
    private let settingsHandler: DictationSettingsHandler
    private var transcriptionTask: Task<Void, Never>?
    private var targetAppCorrectionLearningTask: Task<Void, Never>?
    private var pendingLearnedCorrections: [LearnedDictionaryCorrection] = []
    private var errorResetTask: Task<Void, Never>?
    private var insertingResetTask: Task<Void, Never>?
    @Published private var cancelWarningTarget: CancelWarningTarget?
    private var urlResolutionTask: Task<Void, Never>?
    private var metadataCaptureTask: Task<Void, Never>?
    var pasteboardProvider: () -> NSPasteboard = { .general }
    /// Snapshot of the streaming params used in the most recent `streamingHandler.start(...)`.
    /// Used to detect when an on-the-fly rule refinement (e.g. browser URL resolution)
    /// changes the effective engine/language selection/task/cloud-model so the live
    /// session can be restarted and stay consistent with the final transcription
    /// (release review K3).
    private struct StreamingParamsSnapshot: Equatable {
        let engineOverrideId: String?
        let providerId: String?
        let languageSelection: LanguageSelection
        let task: TranscriptionTask
        let cloudModelOverride: String?
        let normalizeNumbers: Bool?
    }
    private var lastStreamingParams: StreamingParamsSnapshot?
    private var isStopInFlight = false
    private var activeDictationSessionID: UUID?
    private var pendingPushToTalkDiscardMessage: String?
    private var recordingStartCuePending = false
    private var firstRecordingAudioBufferSeen = false
    private var pendingRecordingStartedPayload: RecordingStartedPayload?
    private var shouldPlayRecordingStartSoundWhenReady = false
    private var pendingRecordingAudioDuckingLevel: Float?
    private var pendingRecordingAudioDuckingTask: Task<Void, Never>?
    private var dictationSessions: [UUID: DictationSessionSnapshot] = [:]
    private var dictationSessionOrder: [UUID] = []
    private let maxTrackedDictationSessions = 100

    var cancelWarningMessage: String? {
        switch (state, cancelWarningTarget) {
        case (.recording, .recording):
            return String(localized: "Press Esc again to cancel recording")
        case (.processing, .processing):
            return String(localized: "Press Esc again to cancel transcription")
        default:
            return nil
        }
    }

    init(
        audioRecordingService: AudioRecordingService,
        textInsertionService: TextInsertionService,
        hotkeyService: HotkeyService,
        modelManager: ModelManagerService,
        settingsViewModel: SettingsViewModel,
        historyService: HistoryService,
        recentTranscriptionStore: RecentTranscriptionStore,
        profileService: ProfileService,
        workflowService: WorkflowService,
        translationService: AnyObject?,
        audioDuckingService: AudioDuckingService,
        dictionaryService: DictionaryService,
        licenseService: LicenseService? = nil,
        targetAppCorrectionLearningService: TargetAppCorrectionLearningService? = nil,
        snippetService: SnippetService,
        soundService: SoundService,
        audioDeviceService: AudioDeviceService,
        promptActionService: PromptActionService,
        promptProcessingService: PromptProcessingService,
        workflowTextProcessingService: WorkflowTextProcessingService? = nil,
        appFormatterService: AppFormatterService,
        punctuationStrategyResolver: PunctuationStrategyResolver,
        speechPunctuationService: SpeechPunctuationService,
        speechFeedbackService: SpeechFeedbackService,
        accessibilityAnnouncementService: AccessibilityAnnouncementService,
        errorLogService: ErrorLogService,
        mediaPlaybackService: MediaPlaybackService
    ) {
        self.audioRecordingService = audioRecordingService
        self.textInsertionService = textInsertionService
        self.hotkeyService = hotkeyService
        self.modelManager = modelManager
        self.settingsViewModel = settingsViewModel
        self.historyService = historyService
        self.recentTranscriptionStore = recentTranscriptionStore
        self.profileService = profileService
        self.workflowService = workflowService
        self.translationService = translationService
        self.audioDuckingService = audioDuckingService
        self.dictionaryService = dictionaryService
        self.licenseService = licenseService
        self.targetAppCorrectionLearningService = targetAppCorrectionLearningService
            ?? TargetAppCorrectionLearningService(
                textInsertionService: textInsertionService,
                textDiffService: TextDiffService(),
                dictionaryService: dictionaryService
            )
        self.snippetService = snippetService
        self.soundService = soundService
        self.audioDeviceService = audioDeviceService
        self.promptActionService = promptActionService
        self.promptProcessingService = promptProcessingService
        self.workflowTextProcessingService = workflowTextProcessingService
            ?? WorkflowTextProcessingService(
                promptProcessingService: promptProcessingService,
                translationService: translationService,
                workflowService: workflowService
            )
        self.speechFeedbackService = speechFeedbackService
        self.accessibilityAnnouncementService = accessibilityAnnouncementService
        self.errorLogService = errorLogService
        self.mediaPlaybackService = mediaPlaybackService
        self.postProcessingPipeline = PostProcessingPipeline(
            snippetService: snippetService,
            dictionaryService: dictionaryService,
            appFormatterService: appFormatterService,
            speechPunctuationService: speechPunctuationService,
            punctuationStrategyResolver: punctuationStrategyResolver
        )
        self.streamingHandler = StreamingHandler(
            modelManager: modelManager,
            bufferProvider: { [weak audioRecordingService] in
                audioRecordingService?.getCurrentBuffer() ?? []
            },
            recentBufferProvider: { [weak audioRecordingService] maxDuration in
                audioRecordingService?.getRecentBuffer(maxDuration: maxDuration) ?? []
            },
            bufferDeltaProvider: { [weak audioRecordingService] offset in
                audioRecordingService?.getBufferDelta(since: offset) ?? ([], offset)
            },
            bufferedDurationProvider: { [weak audioRecordingService] in
                audioRecordingService?.totalBufferDuration ?? 0
            }
        )
        self.promptPaletteHandler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            workflowService: workflowService,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            promptProcessingService: promptProcessingService,
            workflowTextProcessingService: self.workflowTextProcessingService,
            soundService: soundService,
            accessibilityAnnouncementService: accessibilityAnnouncementService
        )
        self.recentTranscriptionPaletteHandler = RecentTranscriptionPaletteHandler(
            textInsertionService: textInsertionService,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore
        )
        self.settingsHandler = DictationSettingsHandler(
            hotkeyService: hotkeyService,
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            profileService: profileService,
            workflowService: workflowService
        )
        self.audioDuckingEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.audioDuckingEnabled)
        self.audioDuckingLevel = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingLevel) as? Double ?? 0.2
        self.soundFeedbackEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.soundFeedbackEnabled) as? Bool ?? true
        self.indicatorTranscriptPreviewEnabled = Self.loadIndicatorTranscriptPreviewEnabled()
        self.indicatorTranscriptPreviewFontSizeOffset = Self.loadIndicatorTranscriptPreviewFontSizeOffset()
        self.preserveClipboard = UserDefaults.standard.bool(forKey: UserDefaultsKeys.preserveClipboard)
        self.mediaPauseEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.mediaPauseEnabled)
        self.transcribeShortQuietClipsAggressively = Self.loadTranscribeShortQuietClipsAggressively()
        self.microphoneBoostEnabled = Self.loadMicrophoneBoostEnabled()
        self.spokenFeedbackEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.spokenFeedbackEnabled)
        self.indicatorStyle = Self.loadIndicatorStyle()
        self.notchIndicatorVisibility = UserDefaults.standard.string(forKey: UserDefaultsKeys.notchIndicatorVisibility)
            .flatMap { NotchIndicatorVisibility(rawValue: $0) } ?? .duringActivity
        self.notchIndicatorLeftContent = UserDefaults.standard.string(forKey: UserDefaultsKeys.notchIndicatorLeftContent)
            .flatMap { NotchIndicatorContent(rawValue: $0) } ?? .timer
        self.notchIndicatorRightContent = UserDefaults.standard.string(forKey: UserDefaultsKeys.notchIndicatorRightContent)
            .flatMap { NotchIndicatorContent(rawValue: $0) } ?? .waveform
        self.notchIndicatorDisplay = UserDefaults.standard.string(forKey: UserDefaultsKeys.notchIndicatorDisplay)
            .flatMap { NotchIndicatorDisplay(rawValue: $0) } ?? .activeScreen
        self.overlayPosition = UserDefaults.standard.string(forKey: UserDefaultsKeys.overlayPosition)
            .flatMap { OverlayPosition(rawValue: $0) } ?? .bottom
        audioRecordingService.microphoneBoostEnabled = microphoneBoostEnabled

        setupBindings()

        streamingHandler.onPartialTextUpdate = { [weak self] text in
            guard let self else { return }
            if self.partialText != text {
                self.partialText = text
                let elapsed = self.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
                EventBus.shared.emit(.partialTranscriptionUpdate(PartialTranscriptionPayload(
                    text: text,
                    elapsedSeconds: elapsed
                )))
            }
        }
        streamingHandler.onStreamingStateChange = { [weak self] streaming in
            self?.isStreaming = streaming
        }
        audioRecordingService.onFirstRecordingAudioBuffer = { [weak self] in
            self?.handleFirstRecordingAudioBuffer()
        }

        promptPaletteHandler.onShowNotchFeedback = { [weak self] message, icon, duration, isError, category in
            self?.showNotchFeedback(message: message, icon: icon, duration: duration, isError: isError, errorCategory: category ?? "general")
        }
        promptPaletteHandler.onShowError = { [weak self] message in
            self?.showError(message, category: "prompt")
        }
        promptPaletteHandler.executeActionPlugin = { [weak self] plugin, pluginId, text, activeApp, originalText, language in
            try await self?.executeActionPlugin(plugin, pluginId: pluginId, text: text, activeApp: activeApp, language: language, originalText: originalText)
        }
        promptPaletteHandler.getActionFeedback = { [weak self] in
            (self?.actionFeedbackMessage, self?.actionFeedbackIcon, self?.actionDisplayDuration ?? 3.5)
        }
        promptPaletteHandler.getPreserveClipboard = { [weak self] in
            self?.preserveClipboard ?? false
        }
        recentTranscriptionPaletteHandler.onShowNotchFeedback = { [weak self] message, icon, duration, isError, category in
            self?.showNotchFeedback(message: message, icon: icon, duration: duration, isError: isError, errorCategory: category ?? "general")
        }
        recentTranscriptionPaletteHandler.getPreserveClipboard = { [weak self] in
            self?.preserveClipboard ?? false
        }

        settingsHandler.onObjectWillChange = { [weak self] in
            self?.objectWillChange.send()
        }
        settingsHandler.onHotkeyLabelsChanged = { [weak self] in
            self?.hotkeyLabelsVersion += 1
        }
        hotkeyService.discardPushToTalkRecordingOnExtraKeyPress = true
    }

    var canDictate: Bool {
        modelManager.canTranscribe
    }

    @available(*, deprecated, renamed: "activeRuleName")
    var activeProfileName: String? { activeRuleName }

    nonisolated static func loadIndicatorTranscriptPreviewEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled) as? Bool ?? true
    }

    nonisolated static func persistIndicatorTranscriptPreviewEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled)
    }

    nonisolated static func loadIndicatorTranscriptPreviewFontSizeOffset(defaults: UserDefaults = .standard) -> Int {
        guard let storedValue = defaults.object(forKey: UserDefaultsKeys.indicatorTranscriptPreviewFontSizeOffset) else {
            return 0
        }

        guard let number = storedValue as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return 0
        }

        return Self.clampedIndicatorTranscriptPreviewFontSizeOffset(number.intValue)
    }

    nonisolated static func persistIndicatorTranscriptPreviewFontSizeOffset(_ offset: Int, defaults: UserDefaults = .standard) {
        defaults.set(Self.clampedIndicatorTranscriptPreviewFontSizeOffset(offset), forKey: UserDefaultsKeys.indicatorTranscriptPreviewFontSizeOffset)
    }

    nonisolated static func loadIndicatorStyle(defaults: UserDefaults = .standard) -> IndicatorStyle {
        defaults.string(forKey: UserDefaultsKeys.indicatorStyle)
            .flatMap { IndicatorStyle(rawValue: $0) } ?? .notch
    }

    nonisolated static func persistIndicatorStyle(_ style: IndicatorStyle, defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: UserDefaultsKeys.indicatorStyle)
    }

    nonisolated static func loadTranscribeShortQuietClipsAggressively(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: UserDefaultsKeys.transcribeShortQuietClipsAggressively) as? Bool ?? true
    }

    nonisolated static func persistTranscribeShortQuietClipsAggressively(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: UserDefaultsKeys.transcribeShortQuietClipsAggressively)
    }

    nonisolated static func loadMicrophoneBoostEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: UserDefaultsKeys.microphoneBoostEnabled) as? Bool ?? false
    }

    nonisolated static func persistMicrophoneBoostEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: UserDefaultsKeys.microphoneBoostEnabled)
    }

    nonisolated static func indicatorTranscriptPreviewFontSize(for style: IndicatorStyle, offset: Int) -> CGFloat {
        style.transcriptPreviewBaseFontSize + CGFloat(Self.clampedIndicatorTranscriptPreviewFontSizeOffset(offset))
    }

    nonisolated static func indicatorTranscriptPreviewExpandedHeight(for style: IndicatorStyle, offset: Int) -> CGFloat {
        let fontSize = Self.indicatorTranscriptPreviewFontSize(for: style, offset: offset)
        return style.scaledTranscriptPreviewMetric(style.transcriptPreviewBaseExpandedHeight, fontSize: fontSize)
    }

    func indicatorTranscriptPreviewFontSize(for style: IndicatorStyle) -> CGFloat {
        Self.indicatorTranscriptPreviewFontSize(for: style, offset: indicatorTranscriptPreviewFontSizeOffset)
    }

    func indicatorTranscriptPreviewExpandedHeight(for style: IndicatorStyle) -> CGFloat {
        Self.indicatorTranscriptPreviewExpandedHeight(for: style, offset: indicatorTranscriptPreviewFontSizeOffset)
    }

    nonisolated private static func clampedIndicatorTranscriptPreviewFontSizeOffset(_ offset: Int) -> Int {
        min(max(offset, 0), 8)
    }

    nonisolated private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Double? {
        guard end >= start else { return nil }
        return Double(end - start) / 1_000_000
    }

    nonisolated private static func formatMilliseconds(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f", value)
    }

    var needsMicPermission: Bool {
        !audioRecordingService.hasMicrophonePermission
    }

    var needsAccessibilityPermission: Bool {
        !textInsertionService.isAccessibilityGranted
    }

    // MARK: - HTTP API

    var isRecording: Bool {
        state == .recording
    }

    func apiStartRecording() -> UUID {
        let sessionID = UUID()
        startRecording(
            sessionID: sessionID,
            requestUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        return sessionID
    }

    func apiStopRecording() -> UUID? {
        let sessionID = activeDictationSessionID
        stopDictation()
        return sessionID
    }

    func apiDictationSession(id: UUID) -> DictationSessionSnapshot? {
        if let session = dictationSessions[id] {
            return session
        }
        if let record = historyService.records.first(where: { $0.id == id }) {
            return DictationSessionSnapshot(
                id: id,
                status: .completed,
                transcription: DictationSessionTranscription(
                    text: record.finalText,
                    rawText: record.rawText,
                    timestamp: record.timestamp,
                    appName: record.appName,
                    appBundleIdentifier: record.appBundleIdentifier,
                    appURL: record.appURL,
                    duration: record.durationSeconds,
                    language: record.language,
                    engine: record.engineUsed,
                    model: record.modelUsed,
                    wordsCount: record.wordsCount
                ),
                error: nil
            )
        }
        return nil
    }

    private func beginDictationSession(id: UUID) {
        activeDictationSessionID = id
        storeDictationSession(DictationSessionSnapshot(id: id, status: .recording, transcription: nil, error: nil))
    }

    private func markActiveDictationSessionProcessingIfNeeded() {
        guard let sessionID = activeDictationSessionID else { return }
        storeDictationSession(DictationSessionSnapshot(id: sessionID, status: .processing, transcription: nil, error: nil))
    }

    private func completeDictationSession(id: UUID, transcription: DictationSessionTranscription) {
        storeDictationSession(DictationSessionSnapshot(id: id, status: .completed, transcription: transcription, error: nil))
        if activeDictationSessionID == id {
            activeDictationSessionID = nil
        }
    }

    private func failDictationSession(id: UUID, error: String) {
        storeDictationSession(DictationSessionSnapshot(id: id, status: .failed, transcription: nil, error: error))
        if activeDictationSessionID == id {
            activeDictationSessionID = nil
        }
    }

    private func cancelActiveDictationSessionIfNeeded(message: String = String(localized: "Cancelled")) {
        guard let sessionID = activeDictationSessionID else { return }
        failDictationSession(id: sessionID, error: message)
    }

    private func restoreRecordingSideEffects() {
        audioDuckingService.restoreAudio()
        mediaPlaybackService.resumeIfWePaused()
    }

    private func prepareRecordingStartCue(playsSound: Bool) {
        isRecordingInputReady = false
        recordingStartCuePending = true
        firstRecordingAudioBufferSeen = false
        pendingRecordingStartedPayload = nil
        shouldPlayRecordingStartSoundWhenReady = playsSound
    }

    private func updateRecordingStartCuePayload(activeApp: (name: String?, bundleId: String?, url: String?)?) {
        pendingRecordingStartedPayload = RecordingStartedPayload(
            appName: activeApp?.name,
            bundleIdentifier: activeApp?.bundleId
        )
        emitRecordingStartCueIfReady()
    }

    private func handleFirstRecordingAudioBuffer() {
        firstRecordingAudioBufferSeen = true
        emitRecordingStartCueIfReady()
    }

    private func emitRecordingStartCueIfReady() {
        guard recordingStartCuePending,
              firstRecordingAudioBufferSeen,
              state == .recording,
              let payload = pendingRecordingStartedPayload else {
            return
        }

        recordingStartCuePending = false
        isRecordingInputReady = true
        if shouldPlayRecordingStartSoundWhenReady {
            let startSoundDuration = soundService.playbackDuration(for: .recordingStarted, enabled: soundFeedbackEnabled)
            if !soundService.play(.recordingStarted, enabled: soundFeedbackEnabled) {
                applyPendingRecordingAudioDuckingIfNeeded()
            } else {
                applyPendingRecordingAudioDuckingIfNeeded(after: startSoundDuration)
            }
        } else {
            applyPendingRecordingAudioDuckingIfNeeded()
        }
        accessibilityAnnouncementService.announceRecordingStarted()
        EventBus.shared.emit(.recordingStarted(payload))
    }

    private func applyPendingRecordingAudioDuckingIfNeeded(after delay: TimeInterval? = nil) {
        guard let level = pendingRecordingAudioDuckingLevel else { return }
        pendingRecordingAudioDuckingLevel = nil
        pendingRecordingAudioDuckingTask?.cancel()
        guard let delay, delay > 0 else {
            audioDuckingService.duckAudio(to: level)
            return
        }

        let nanoseconds = UInt64((delay * 1_000_000_000).rounded(.up))
        pendingRecordingAudioDuckingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.audioDuckingService.duckAudio(to: level)
            self?.pendingRecordingAudioDuckingTask = nil
        }
    }

    private func clearRecordingStartCueState(resetReadiness: Bool = true) {
        if resetReadiness {
            isRecordingInputReady = false
        }
        recordingStartCuePending = false
        firstRecordingAudioBufferSeen = false
        pendingRecordingStartedPayload = nil
        shouldPlayRecordingStartSoundWhenReady = false
        pendingRecordingAudioDuckingLevel = nil
        pendingRecordingAudioDuckingTask?.cancel()
        pendingRecordingAudioDuckingTask = nil
    }

    private func clearDeferredRecordingContext() {
        metadataCaptureTask?.cancel()
        metadataCaptureTask = nil
        urlResolutionTask?.cancel()
        urlResolutionTask = nil
        lastStreamingParams = nil
    }

    private func abortActiveRecordingImmediately(sessionMessage: String, preserveRecoveryAudio: Bool = false) {
        clearRecordingStartCueState()
        clearDeferredRecordingContext()
        restoreRecordingSideEffects()
        streamingHandler.stop()
        stopRecordingTimer()
        Task {
            _ = await audioRecordingService.stopRecording(policy: .immediate)
            if preserveRecoveryAudio {
                audioRecordingService.preserveActiveRecoveryRecording()
            } else {
                audioRecordingService.discardActiveRecoveryRecording()
            }
        }
        cancelActiveDictationSessionIfNeeded(message: sessionMessage)
        hotkeyService.cancelDictation()
    }

    private func storeDictationSession(_ session: DictationSessionSnapshot) {
        dictationSessions[session.id] = session
        dictationSessionOrder.removeAll { $0 == session.id }
        dictationSessionOrder.append(session.id)

        while dictationSessionOrder.count > maxTrackedDictationSessions {
            let removedID = dictationSessionOrder.removeFirst()
            dictationSessions.removeValue(forKey: removedID)
        }
    }

    private func setupBindings() {
        hotkeyService.onDictationStart = { [weak self] requestTimestamp in
            self?.startRecording(requestUptimeNanoseconds: requestTimestamp)
        }

        hotkeyService.onDictationStop = { [weak self] in
            self?.stopDictation()
        }

        hotkeyService.onWorkflowDictationStart = { [weak self] workflowId, requestTimestamp in
            self?.startRecording(forcedWorkflowId: workflowId, requestUptimeNanoseconds: requestTimestamp)
        }

        hotkeyService.onWorkflowTextProcessing = { [weak self] workflowId in
            self?.processWorkflowHotkeyText(workflowId: workflowId)
        }

        hotkeyService.onCancelPressed = { [weak self] in
            self?.handleCancelHotkey()
        }

        hotkeyService.onPushToTalkInterruption = { [weak self] in
            self?.handlePushToTalkInterruption()
        }

        workflowService.$workflows
            .dropFirst()
            .sink { [weak self] workflows in
                guard let self else { return }
                self.settingsHandler.syncWorkflowHotkeys(workflows)
            }
            .store(in: &cancellables)

        audioRecordingService.$audioLevel
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }
            .store(in: &cancellables)

        // When the recovery coordinator's circuit breaker gives up mid-session,
        // `AudioRecordingService` publishes the terminal error here. Surface
        // it to the UI and unwind the dictation session cleanly — restore
        // ducking, resume media, stop streaming, cancel the session.
        audioRecordingService.$recoveryError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                // Always drain the publisher so `recoveryError` never lingers
                // on `AudioRecordingService`, even when the session is no
                // longer active (stop-in-flight, already processed, etc.).
                defer { self.audioRecordingService.clearRecoveryError() }
                guard self.state == .recording, !self.isStopInFlight else { return }
                let errorMessage = error.localizedDescription
                self.abortActiveRecordingImmediately(sessionMessage: errorMessage, preserveRecoveryAudio: true)
                self.accessibilityAnnouncementService.announceError(errorMessage)
                self.showError(errorMessage, category: "recording")
            }
            .store(in: &cancellables)

        hotkeyService.$currentMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.hotkeyMode = mode
            }
            .store(in: &cancellables)

        audioDeviceService.$disconnectedDeviceName
            .compactMap { $0 }
            .sink { [weak self] _ in
                guard let self, self.state == .recording, !self.isStopInFlight else { return }
                let errorMessage = String(localized: "Microphone disconnected")
                self.abortActiveRecordingImmediately(sessionMessage: errorMessage)
                self.showNotchFeedback(
                    message: errorMessage,
                    icon: "mic.slash",
                    duration: 3.0,
                    isError: true,
                    errorCategory: "recording"
                )
            }
            .store(in: &cancellables)
    }

    func handleCancelHotkey() {
        guard let target = cancelWarningTargetForCurrentState() else { return }

        if cancelWarningTarget == target {
            clearCancelWarning()
            cancelCurrentOperation()
        } else {
            cancelWarningTarget = target
        }
    }

    private func cancelWarningTargetForCurrentState() -> CancelWarningTarget? {
        switch state {
        case .recording:
            return .recording
        case .processing:
            return .processing
        default:
            return nil
        }
    }

    private func clearCancelWarningIfStateNoLongerMatches() {
        guard let cancelWarningTarget,
              cancelWarningTargetForCurrentState() != cancelWarningTarget else {
            return
        }
        self.cancelWarningTarget = nil
    }

    private func clearCancelWarning() {
        cancelWarningTarget = nil
    }

    private func cancelCurrentOperation() {
        let cancelledMessage = String(localized: "Cancelled")
        clearCancelWarning()

        switch state {
        case .recording:
            guard !isStopInFlight else { return }
            abortActiveRecordingImmediately(sessionMessage: cancelledMessage)
            showNotchFeedback(message: cancelledMessage, icon: "xmark.circle", duration: 1.5)
        case .processing:
            cancelActiveDictationSessionIfNeeded(message: cancelledMessage)
            transcriptionTask?.cancel()
            transcriptionTask = nil
            audioRecordingService.discardActiveRecoveryRecording()
            showNotchFeedback(message: cancelledMessage, icon: "xmark.circle", duration: 1.5)
        default:
            break
        }
    }

    private func startRecording(
        forcedWorkflowId: UUID? = nil,
        sessionID: UUID = UUID(),
        requestUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let startTimestamp = CFAbsoluteTimeGetCurrent()
        clearRecordingStartCueState()

        // Cancel any pending transcription from a previous recording
        if transcriptionTask != nil {
            cancelActiveDictationSessionIfNeeded()
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        cancelTargetAppCorrectionLearning()
        clearPendingUndoActionFeedback()
        insertingResetTask?.cancel()
        insertingResetTask = nil
        clearCancelWarning()
        pendingPushToTalkDiscardMessage = nil
        metadataCaptureTask?.cancel()
        metadataCaptureTask = nil
        urlResolutionTask?.cancel()
        urlResolutionTask = nil

        self.forcedWorkflowId = forcedWorkflowId
        beginDictationSession(id: sessionID)

        guard canDictate else {
            let errorMessage = TranscriptionEngineError.modelNotLoaded.localizedDescription
            failDictationSession(id: sessionID, error: errorMessage)
            showError(errorMessage, category: "recording")
            return
        }

        guard audioRecordingService.hasMicrophonePermission else {
            let errorMessage = "Microphone permission required."
            failDictationSession(id: sessionID, error: errorMessage)
            showError(errorMessage, category: "recording")
            return
        }

        do {
            let initialForcedWorkflow = forcedWorkflow(for: forcedWorkflowId)
            audioRecordingService.microphoneBoostEnabled = microphoneBoostEnabled(for: initialForcedWorkflow)
            audioRecordingService.selectedDeviceID = audioDeviceService.selectedDeviceID
            audioRecordingService.hasExplicitDeviceSelection = audioDeviceService.selectedDeviceUID != nil
            let selectedInputUsesBluetooth = audioDeviceService.selectedDeviceUsesBluetoothTransport
            audioRecordingService.selectedInputDeviceUsesBluetoothTransport = selectedInputUsesBluetooth
            prepareRecordingStartCue(playsSound: !selectedInputUsesBluetooth)
            let audioStartTimestamp = DispatchTime.now().uptimeNanoseconds
            try audioRecordingService.startRecording(requestUptimeNanoseconds: requestUptimeNanoseconds)
            let audioStartCompletedTimestamp = DispatchTime.now().uptimeNanoseconds
            let audioStartMs = Self.elapsedMilliseconds(
                from: audioStartTimestamp,
                to: audioStartCompletedTimestamp
            )
            let requestToAudioStartMs = Self.elapsedMilliseconds(
                from: requestUptimeNanoseconds,
                to: audioStartCompletedTimestamp
            )
            promptPaletteHandler.hide()
            recentTranscriptionPaletteHandler.hide()
            modelManager.cancelAutoUnloadTimer()
            if selectedInputUsesBluetooth {
                logger.info("Skipping recording start sound for Bluetooth input device")
            }
            if mediaPauseEnabled { mediaPlaybackService.pauseIfPlaying() }
            if audioDuckingEnabled {
                pendingRecordingAudioDuckingLevel = max(0, min(1, Float(audioDuckingLevel)))
            } else {
                pendingRecordingAudioDuckingLevel = nil
            }
            state = .recording
            // Reset hotkey timer so hybrid threshold counts from recording start,
            // not from key press. Slow device init (e.g. iPhone Continuity ~2-3s)
            // would otherwise make the hold appear as "long press" → PTT stop.
            hotkeyService.resetKeyDownTime()
            partialText = ""
            isStopInFlight = false
            recordingStartTime = Date()
            startRecordingTimer()

            let contextStartTimestamp = CFAbsoluteTimeGetCurrent()
            // Match rule after the audio engine is live so app/context lookup does
            // not delay capture of the user's first spoken words.
            let activeApp = textInsertionService.captureActiveApp()
            capturedActiveApp = activeApp
            capturedSelectedText = nil
            activeAppIcon = nil

            if let forcedWorkflow = initialForcedWorkflow {
                applyWorkflowMatch(workflowService.forcedWorkflowMatch(for: forcedWorkflow), activeApp: activeApp)
            } else if let workflowMatch = workflowService.matchWorkflow(bundleIdentifier: activeApp.bundleId, url: nil) {
                applyWorkflowMatch(workflowMatch, activeApp: activeApp)
            } else {
                clearActiveRuleState()
            }
            applyEffectiveMicrophoneBoostToAudioService()
            updateRecordingStartCuePayload(activeApp: activeApp)
            let contextMs = (CFAbsoluteTimeGetCurrent() - contextStartTimestamp) * 1000

            startLiveStreaming(allowLiveTranscription: indicatorTranscriptPreviewEnabled || externalStreamingDisplayCount > 0)
            scheduleDeferredRecordingMetadataCapture(
                activeApp: activeApp,
                forcedWorkflowId: forcedWorkflowId
            )

            let totalStartMs = (CFAbsoluteTimeGetCurrent() - startTimestamp) * 1000
            logger.info(
                "Recording started: requestToAudioStartMs=\(Self.formatMilliseconds(requestToAudioStartMs), privacy: .public), audioStartMs=\(Self.formatMilliseconds(audioStartMs), privacy: .public), contextMs=\(String(format: "%.1f", contextMs), privacy: .public), totalStartMs=\(String(format: "%.1f", totalStartMs), privacy: .public)"
            )
        } catch {
            clearRecordingStartCueState()
            clearDeferredRecordingContext()
            restoreRecordingSideEffects()
            let errorMessage: String
            if let recordingError = error as? AudioRecordingService.AudioRecordingError,
               case .noMicrophoneDetected = recordingError {
                errorMessage = String(localized: "No mic detected.")
            } else if let recordingError = error as? AudioRecordingService.AudioRecordingError,
                      case .selectedInputDeviceIncompatible(let issue) = recordingError {
                audioDeviceService.markSelectedDeviceCompatibility(.incompatible(issue))
                errorMessage = recordingError.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
            accessibilityAnnouncementService.announceError(errorMessage)
            failDictationSession(id: sessionID, error: errorMessage)
            showError(errorMessage, category: "recording")
            hotkeyService.cancelDictation()
        }
    }

    private func scheduleDeferredRecordingMetadataCapture(
        activeApp: (name: String?, bundleId: String?, url: String?),
        forcedWorkflowId: UUID?
    ) {
        let metadataStartTimestamp = CFAbsoluteTimeGetCurrent()

        metadataCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let selectedText = textInsertionService.getSelectedText()
            guard !Task.isCancelled else { return }
            capturedSelectedText = selectedText
            if let selectedText {
                logger.info("Captured selected text (\(selectedText.count) chars)")
            }

            if let bundleId = activeApp.bundleId,
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                activeAppIcon = NSWorkspace.shared.icon(forFile: appURL.path)
            } else {
                activeAppIcon = nil
            }

            let elapsedMs = (CFAbsoluteTimeGetCurrent() - metadataStartTimestamp) * 1000
            logger.info("Deferred recording metadata captured in \(String(format: "%.1f", elapsedMs), privacy: .public)ms")
        }

        // Resolve browser URL asynchronously after recording has already started.
        // If a more specific URL workflow matches, update the active rule on the fly.
        // Skip URL resolution when a forced workflow is set (manual shortcut overrides app matching).
        guard forcedWorkflowId == nil, let bundleId = activeApp.bundleId else { return }
        urlResolutionTask = Task { [weak self] in
            guard let self else { return }
            logger.info("URL resolution: starting for bundleId=\(bundleId)")
            let resolvedURL = await textInsertionService.resolveBrowserURL(bundleId: bundleId)
            logger.info("URL resolution: resolvedURL=\(resolvedURL ?? "nil"), state=\(String(describing: self.state))")
            guard state == .recording || state == .processing else {
                logger.info("URL resolution: skipped - state is \(String(describing: self.state))")
                return
            }
            guard let currentApp = capturedActiveApp, currentApp.bundleId == bundleId else {
                logger.info("URL resolution: skipped - bundleId mismatch")
                return
            }

            capturedActiveApp = (name: currentApp.name, bundleId: currentApp.bundleId, url: resolvedURL)

            guard let resolvedURL else {
                logger.info("URL resolution: no URL resolved")
                return
            }

            if let workflowMatch = workflowService.matchWorkflow(bundleIdentifier: bundleId, url: resolvedURL) {
                logger.info("URL resolution: matched workflow '\(workflowMatch.workflow.name)'")
                applyWorkflowMatch(workflowMatch, activeApp: capturedActiveApp)
                refreshLiveStreamingIfParamsChanged()
                return
            }

            logger.info("URL resolution: no workflow matched for URL \(resolvedURL)")
        }
    }

    private var effectiveLanguageSelection: LanguageSelection {
        DictationLanguageResolver.resolve(
            workflow: matchedWorkflow,
            globalLanguageSelection: settingsViewModel.languageSelection
        )
    }

    private var effectiveLanguage: String? {
        effectiveLanguageSelection.requestedLanguage
    }

    private var effectiveTask: TranscriptionTask {
        return settingsViewModel.selectedTask
    }

    private var effectiveTranslationTarget: String? {
        if settingsViewModel.translationEnabled {
            return settingsViewModel.translationTargetLanguage
        }
        return nil
    }

    private var effectiveEngineOverrideId: String? {
        DictationTranscriptionOverrideResolver.engineId(for: matchedWorkflow)
    }

    private var effectiveCloudModelOverride: String? {
        DictationTranscriptionOverrideResolver.modelId(for: matchedWorkflow)
    }

    private var effectiveMicrophoneBoostEnabled: Bool {
        microphoneBoostEnabled(for: matchedWorkflow)
    }

    private var effectiveRuleName: String? {
        matchedWorkflow?.name
    }

    private var effectiveOutputFormat: String? {
        matchedWorkflow?.output.format
    }

    private func resolvedEffectiveOutputFormat(
        for activeApp: (name: String?, bundleId: String?, url: String?)
    ) -> String? {
        let storedFormat = effectiveOutputFormat
        let resolvedFormat = WorkflowOutputFormatResolver.resolvedFormat(
            storedFormat: storedFormat,
            bundleIdentifier: activeApp.bundleId,
            url: activeApp.url
        )
        if storedFormat != nil {
            logger.info(
                "Workflow output format resolved: stored=\(storedFormat ?? "nil", privacy: .public), resolved=\(resolvedFormat ?? "nil", privacy: .public), bundle=\(activeApp.bundleId ?? "nil", privacy: .public), url=\(activeApp.url ?? "nil", privacy: .public)"
            )
        }
        return resolvedFormat
    }

    private var shouldTrackTargetAppCorrectionLearning: Bool {
        (licenseService?.hasCommercialLicense ?? false) &&
            UserDefaults.standard.bool(forKey: UserDefaultsKeys.targetAppCorrectionLearningEnabled)
    }

    private var effectiveNumberNormalizationOverride: Bool? {
        matchedWorkflow?.output.numberNormalizationMode.overrideValue
    }

    private var effectiveActionPluginId: String? {
        matchedWorkflow?.output.targetActionPluginId
    }

    private var effectiveAutoEnterEnabled: Bool {
        if let matchedWorkflow {
            return matchedWorkflow.output.autoEnter
        }
        return false
    }

    private func stopDictation() {
        guard state == .recording, !isStopInFlight else { return }
        clearCancelWarning()
        isStopInFlight = true
        Task {
            await finalizeStopDictation()
        }
    }

    private func finalizeStopDictation() async {
        let sessionID = activeDictationSessionID

        clearRecordingStartCueState(resetReadiness: false)
        restoreRecordingSideEffects()
        if let discardMessage = pendingPushToTalkDiscardMessage {
            pendingPushToTalkDiscardMessage = nil
            streamingHandler.stop()
            lastStreamingParams = nil
            stopRecordingTimer()
            _ = await audioRecordingService.stopRecording(policy: .immediate)
            audioRecordingService.discardActiveRecoveryRecording()
            if let sessionID {
                failDictationSession(id: sessionID, error: discardMessage)
            }
            showNotchFeedback(
                message: discardMessage,
                icon: "xmark.circle",
                duration: 1.8
            )
            return
        }

        let liveSessionResult = await streamingHandler.finish()
        lastStreamingParams = nil
        stopRecordingTimer()
        let previewText = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPreviewText = !previewText.isEmpty
        let hasConfirmedText = hasConfirmedTranscriptionResultText(liveSessionResult)

        if !partialText.isEmpty {
            let elapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            EventBus.shared.emit(.partialTranscriptionUpdate(PartialTranscriptionPayload(
                text: partialText,
                isFinal: true,
                elapsedSeconds: elapsed
            )))
        }

        let stopPolicy = AudioRecordingService.StopPolicy.finalizeShortSpeech()
        var samples = await audioRecordingService.stopRecording(policy: stopPolicy)
        let peakLevel = audioRecordingService.peakRawAudioLevel
        let rawDuration = Double(samples.count) / AudioRecordingService.targetSampleRate
        let decision = classifyShortSpeech(
            rawDuration: rawDuration,
            peakLevel: peakLevel,
            hasConfirmedText: hasConfirmedText,
            transcribeShortQuietClipsAggressively: transcribeShortQuietClipsAggressively
        )
        let graceApplied = audioRecordingService.lastStopGraceCaptureApplied

        logger.info(
            "Stop finalized: rawDuration=\(String(format: "%.3f", rawDuration), privacy: .public)s, bufferedSamples=\(samples.count), peakLevel=\(String(format: "%.4f", peakLevel), privacy: .public), hasPreviewText=\(hasPreviewText, privacy: .public), previewTextLength=\(previewText.count, privacy: .public), hasConfirmedText=\(hasConfirmedText, privacy: .public), stopPolicy=\(stopPolicy.logDescription, privacy: .public), graceApplied=\(graceApplied, privacy: .public), decision=\(decision.logDescription, privacy: .public)"
        )

        switch decision {
        case .discardTooShort:
            audioRecordingService.discardActiveRecoveryRecording()
            let errorMessage = String(localized: "Too short, hold the hotkey a bit longer")
            if let sessionID {
                failDictationSession(id: sessionID, error: errorMessage)
            }
            showNotchFeedback(
                message: errorMessage,
                icon: "waveform.badge.exclamationmark",
                duration: 1.8
            )
            return
        case .discardNoSpeech:
            audioRecordingService.discardActiveRecoveryRecording()
            logger.info("Peak level too low (\(String(format: "%.4f", peakLevel))) - no speech detected")
            let errorMessage = String(localized: "No speech detected")
            if let sessionID {
                failDictationSession(id: sessionID, error: errorMessage)
            }
            showNotchFeedback(
                message: errorMessage,
                icon: "mic.slash",
                duration: 2.0
            )
            return
        case .transcribe:
            break
        }

        samples = paddedSamplesForFinalTranscription(samples, rawDuration: rawDuration)

        let saveAudio = UserDefaults.standard.bool(forKey: UserDefaultsKeys.saveAudioWithHistory)
        let audioSamplesForHistory: [Float]? = saveAudio ? samples : nil

        let audioDuration = Double(samples.count) / AudioRecordingService.targetSampleRate
        EventBus.shared.emit(.recordingStopped(RecordingStoppedPayload(
            durationSeconds: audioDuration
        )))

        state = .processing
        processingPhase = String(localized: "Transcribing...")
        markActiveDictationSessionProcessingIfNeeded()

        transcriptionTask = Task {
            do {
                // Wait for browser URL resolution so URL-based profile overrides apply
                await urlResolutionTask?.value

                let activeApp = capturedActiveApp ?? textInsertionService.captureActiveApp()
                let resolvedOutputFormat = self.resolvedEffectiveOutputFormat(for: activeApp)
                let languageSelection = effectiveLanguageSelection
                let language = languageSelection.requestedLanguage
                let languageCandidates = languageSelection.selectedCodes
                let task = effectiveTask
                let engineOverride = effectiveEngineOverrideId
                let cloudModelOverride = effectiveCloudModelOverride
                let translationTarget = effectiveTranslationTarget
                let termsPrompt = dictionaryService.getTermsForPrompt(
                    providerId: engineOverride ?? modelManager.selectedProviderId
                )

                let result = if let liveSessionResult {
                    liveSessionResult
                } else {
                    try await modelManager.transcribe(
                        audioSamples: samples,
                        languageSelection: languageSelection,
                        task: task,
                        engineOverrideId: engineOverride,
                        cloudModelOverride: cloudModelOverride,
                        prompt: termsPrompt,
                        normalizeNumbers: effectiveNumberNormalizationOverride
                    )
                }

                // Bail out if a new recording started while we were transcribing
                guard !Task.isCancelled else { return }

                var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    logger.info("Transcription returned empty text (duration: \(String(format: "%.2f", result.duration))s, engine: \(result.engineUsed))")
                    audioRecordingService.preserveActiveRecoveryRecording()
                    let errorMessage = String(localized: "No speech recognized")
                    if let sessionID {
                        failDictationSession(id: sessionID, error: errorMessage)
                    }
                    showNotchFeedback(
                        message: errorMessage,
                        icon: "text.magnifyingglass",
                        duration: 2.0
                    )
                    soundService.play(.error, enabled: soundFeedbackEnabled)
                    return
                }

                let llmHandler = buildLLMHandler(
                    translationTarget: translationTarget,
                    detectedLanguage: result.detectedLanguage,
                    configuredLanguage: language,
                    resolvedOutputFormat: resolvedOutputFormat
                )

                guard !Task.isCancelled else { return }

                // Post-processing pipeline (priority-based)
                let llmStepName: String? = if llmHandler != nil {
                    if self.matchedWorkflow != nil {
                        "Workflow"
                    } else {
                        "Translation"
                    }
                } else {
                    nil
                }
                self.processingPhase = String(localized: "Processing...")
                await metadataCaptureTask?.value
                let ppContext = PostProcessingContext(
                    appName: activeApp.name,
                    bundleIdentifier: activeApp.bundleId,
                    url: activeApp.url,
                    language: language,
                    ruleName: self.effectiveRuleName,
                    selectedText: self.capturedSelectedText
                )
                let dictationContext = DictationRuntimeContext(
                    engineId: result.engineUsed,
                    modelId: modelManager.resolvedModelId(
                        engineOverrideId: engineOverride,
                        cloudModelOverride: cloudModelOverride
                    ),
                    configuredLanguage: language,
                    configuredLanguageCandidates: languageCandidates,
                    detectedLanguage: result.detectedLanguage
                )
                let ppResult = try await postProcessingPipeline.process(
                    text: text, context: ppContext, dictationContext: dictationContext, llmHandler: llmHandler,
                    outputFormat: resolvedOutputFormat,
                    llmStepName: llmStepName,
                    normalizeNumbers: self.effectiveNumberNormalizationOverride
                )
                text = ppResult.text
                let transcriptionID = sessionID ?? UUID()
                let completionTimestamp = Date()
                recentTranscriptionStore.recordTranscription(
                    id: transcriptionID,
                    finalText: text,
                    timestamp: completionTimestamp,
                    appName: activeApp.name,
                    appBundleIdentifier: activeApp.bundleId
                )

                partialText = ""

                // Route to action plugin or insert text
                if let actionPluginId = self.effectiveActionPluginId,
                   let actionPlugin = PluginManager.shared.actionPlugin(for: actionPluginId) {
                    try await executeActionPlugin(
                        actionPlugin, pluginId: actionPluginId, text: text,
                        activeApp: activeApp, language: language, originalText: result.text
                    )
                } else {
                    let contextualInsertionEnabled = DictationInsertionTextFormatter.contextualInsertionEnabled()
                    let insertionContext = contextualInsertionEnabled
                        ? textInsertionService.captureInsertionContext()
                        : nil
                    let insertionText = DictationInsertionTextFormatter.textForInsertion(
                        text,
                        insertionContext: insertionContext,
                        contextualInsertionEnabled: contextualInsertionEnabled
                    )
                    let learningPreInsertionObservation = shouldTrackTargetAppCorrectionLearning && resolvedOutputFormat == nil
                        ? textInsertionService.captureFocusedTextObservation()
                        : nil
                    let insertionResult = try await textInsertionService.insertText(
                        insertionText,
                        preserveClipboard: preserveClipboard,
                        autoEnter: self.effectiveAutoEnterEnabled,
                        outputFormat: resolvedOutputFormat
                    )
                    if case .pasted(.unverified(let reason)) = insertionResult {
                        logger.info(
                            "Text insertion paste could not be verified; continuing with clipboard paste fallback. reason=\(reason.rawValue, privacy: .public), app=\(activeApp.bundleId ?? "nil", privacy: .public)"
                        )
                    }
                    let learningBaselineObservation = learningPreInsertionObservation.flatMap {
                        textInsertionService.recaptureFocusedTextObservation(matching: $0)
                    }
                    startTargetAppCorrectionLearningIfNeeded(
                        insertedText: insertionText,
                        baseline: learningBaselineObservation
                    )
                    EventBus.shared.emit(.textInserted(TextInsertedPayload(
                        text: insertionText,
                        appName: activeApp.name,
                        bundleIdentifier: activeApp.bundleId
                    )))
                }

                let modelDisplayName = modelManager.resolvedModelDisplayName(
                    engineOverrideId: engineOverride,
                    cloudModelOverride: cloudModelOverride
                )

                if UserDefaults.standard.object(forKey: UserDefaultsKeys.historyEnabled) as? Bool ?? true {
                    historyService.addRecord(
                        id: transcriptionID,
                        rawText: result.text,
                        finalText: text,
                        appName: activeApp.name,
                        appBundleIdentifier: activeApp.bundleId,
                        appURL: activeApp.url,
                        durationSeconds: audioDuration,
                        language: language,
                        engineUsed: result.engineUsed,
                        modelUsed: modelDisplayName,
                        audioSamples: audioSamplesForHistory,
                        pipelineSteps: ppResult.appliedSteps.isEmpty ? nil : ppResult.appliedSteps
                    )
                }

                EventBus.shared.emit(.transcriptionCompleted(TranscriptionCompletedPayload(
                    rawText: result.text,
                    finalText: text,
                    language: language,
                    engineUsed: result.engineUsed,
                    modelUsed: modelDisplayName,
                    durationSeconds: audioDuration,
                    appName: activeApp.name,
                    bundleIdentifier: activeApp.bundleId,
                    url: activeApp.url,
                    ruleName: self.effectiveRuleName
                )))

                audioRecordingService.discardActiveRecoveryRecording()
                soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                let wordCount = text.split(separator: " ").count
                let detectedLang = result.detectedLanguage ?? language
                let completedTranscription = DictationSessionTranscription(
                    text: text,
                    rawText: result.text,
                    timestamp: completionTimestamp,
                    appName: activeApp.name,
                    appBundleIdentifier: activeApp.bundleId,
                    appURL: activeApp.url,
                    duration: audioDuration,
                    language: detectedLang,
                    engine: result.engineUsed,
                    model: modelDisplayName,
                    wordsCount: wordCount
                )
                if let sessionID {
                    completeDictationSession(id: sessionID, transcription: completedTranscription)
                }
                accessibilityAnnouncementService.announceTranscriptionComplete(wordCount: wordCount)
                speechFeedbackService.speakAutomaticTranscription(text: text, language: detectedLang)
                lastTranscribedText = text
                lastTranscriptionLanguage = detectedLang

                state = .inserting
                insertingResetTask?.cancel()
                let resetDelay: Duration = actionFeedbackMessage != nil ? .seconds(actionDisplayDuration) : .seconds(1.5)
                insertingResetTask = Task {
                    try? await Task.sleep(for: resetDelay)
                    guard !Task.isCancelled else { return }
                    resetDictationState()
                }
            } catch {
                guard !Task.isCancelled else { return }
                audioRecordingService.preserveActiveRecoveryRecording()
                EventBus.shared.emit(.transcriptionFailed(TranscriptionFailedPayload(
                    error: error.localizedDescription,
                    appName: capturedActiveApp?.name,
                    bundleIdentifier: capturedActiveApp?.bundleId
                )))
                if let sessionID {
                    failDictationSession(id: sessionID, error: error.localizedDescription)
                }
                accessibilityAnnouncementService.announceError(error.localizedDescription)
                showError(error.localizedDescription, category: "transcription")
                clearActiveRuleState()
                capturedActiveApp = nil
                activeAppIcon = nil
            }
            self.transcriptionTask = nil
        }
    }

    func requestMicPermission() { settingsHandler.requestMicPermission() }
    func requestAccessibilityPermission() { settingsHandler.requestAccessibilityPermission() }
    func hotkeys(for slot: HotkeySlotType) -> [UnifiedHotkey] { settingsHandler.hotkeys(for: slot) }
    func setHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) { settingsHandler.setHotkey(hotkey, for: slot) }
    func addHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) { settingsHandler.addHotkey(hotkey, for: slot) }
    func replaceHotkey(_ existingHotkey: UnifiedHotkey, with newHotkey: UnifiedHotkey, for slot: HotkeySlotType) { settingsHandler.replaceHotkey(existingHotkey, with: newHotkey, for: slot) }
    func removeHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) { settingsHandler.removeHotkey(hotkey, for: slot) }
    func removeConflictingHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) { settingsHandler.removeConflictingHotkey(hotkey, for: slot) }
    func clearHotkey(for slot: HotkeySlotType) { settingsHandler.clearHotkey(for: slot) }
    func isHotkeyAssigned(_ hotkey: UnifiedHotkey, excluding: HotkeySlotType) -> HotkeySlotType? { settingsHandler.isHotkeyAssigned(hotkey, excluding: excluding) }

    private static func loadHotkeyLabel(for slotType: HotkeySlotType) -> String {
        DictationSettingsHandler.loadHotkeyLabel(for: slotType)
    }

    /// Register profile/workflow hotkeys after app is fully initialized.
    /// Called from ServiceContainer.initialize() to avoid early monitor setup.
    func registerInitialTriggerHotkeys() { settingsHandler.registerInitialTriggerHotkeys() }

    @available(*, deprecated, renamed: "registerInitialTriggerHotkeys")
    func registerInitialProfileHotkeys() { registerInitialTriggerHotkeys() }

    private func resetDictationState() {
        errorResetTask?.cancel()
        insertingResetTask?.cancel()
        insertingResetTask = nil
        urlResolutionTask?.cancel()
        urlResolutionTask = nil
        metadataCaptureTask?.cancel()
        metadataCaptureTask = nil
        lastStreamingParams = nil
        isStopInFlight = false
        activeDictationSessionID = nil
        pendingPushToTalkDiscardMessage = nil
        clearRecordingStartCueState()
        clearCancelWarning()
        state = .idle
        partialText = ""
        recordingStartTime = nil
        clearActiveRuleState()
        capturedActiveApp = nil
        capturedSelectedText = nil
        activeAppIcon = nil
        processingPhase = nil
        actionFeedbackMessage = nil
        actionFeedbackIcon = nil
        actionFeedbackIsError = false
        clearPendingUndoActionFeedback()
        actionDisplayDuration = 3.5
    }

    private func handlePushToTalkInterruption() {
        guard state == .recording, !isStopInFlight else { return }
        pendingPushToTalkDiscardMessage = String(localized: "Recording discarded because additional keys were pressed")
    }

    private func applyWorkflowMatch(
        _ match: WorkflowMatchResult?,
        activeApp: (name: String?, bundleId: String?, url: String?)?
    ) {
        activeWorkflowMatch = match
        matchedWorkflow = match?.workflow
        activeRuleName = match?.workflow.name
        activeRuleReasonLabel = match?.kind.label
        activeRuleExplanation = match.map { workflowExplanation(for: $0, activeApp: activeApp) }
        applyEffectiveMicrophoneBoostToAudioService()
    }

    private func forcedWorkflow(for id: UUID?) -> Workflow? {
        guard let id else { return nil }
        return workflowService.workflows.first { $0.id == id && $0.isEnabled }
    }

    private func microphoneBoostEnabled(for workflow: Workflow?) -> Bool {
        return workflow?.behavior.microphoneBoostOverride ?? microphoneBoostEnabled
    }

    private func applyEffectiveMicrophoneBoostToAudioService() {
        audioRecordingService.microphoneBoostEnabled = effectiveMicrophoneBoostEnabled
    }

    /// Starts the live streaming handler with the currently effective workflow/global params
    /// and records a snapshot for later change detection (release review K3).
    private func startLiveStreaming(allowLiveTranscription: Bool) {
        let params = StreamingParamsSnapshot(
            engineOverrideId: effectiveEngineOverrideId,
            providerId: modelManager.selectedProviderId,
            languageSelection: effectiveLanguageSelection,
            task: effectiveTask,
            cloudModelOverride: effectiveCloudModelOverride,
            normalizeNumbers: effectiveNumberNormalizationOverride
        )
        lastStreamingParams = allowLiveTranscription ? params : nil
        streamingHandler.start(
            streamPrompt: dictionaryService.getTermsForPrompt(
                providerId: params.engineOverrideId ?? params.providerId
            ) ?? "",
            engineOverrideId: params.engineOverrideId,
            selectedProviderId: params.providerId,
            languageSelection: params.languageSelection,
            task: params.task,
            cloudModelOverride: params.cloudModelOverride,
            normalizeNumbers: params.normalizeNumbers,
            allowLiveTranscription: allowLiveTranscription,
            stateCheck: { [weak self] in self?.state == .recording }
        )
    }

    /// Restart live streaming if the currently effective params differ from the ones
    /// used when `streamingHandler.start(...)` was last called. Called after URL
    /// resolution refines the rule, to keep live preview consistent with the final
    /// transcription. No-op when recording already stopped, when live streaming was
    /// disabled, or when no meaningful param changed.
    private func refreshLiveStreamingIfParamsChanged() {
        guard state == .recording else { return }
        guard let previous = lastStreamingParams else { return }
        let newParams = StreamingParamsSnapshot(
            engineOverrideId: effectiveEngineOverrideId,
            providerId: modelManager.selectedProviderId,
            languageSelection: effectiveLanguageSelection,
            task: effectiveTask,
            cloudModelOverride: effectiveCloudModelOverride,
            normalizeNumbers: effectiveNumberNormalizationOverride
        )
        guard newParams != previous else { return }
        logger.info("Streaming params changed after URL resolution, restarting live session")
        let allowLive = indicatorTranscriptPreviewEnabled || externalStreamingDisplayCount > 0
        startLiveStreaming(allowLiveTranscription: allowLive)
    }

    private func clearActiveRuleState() {
        matchedWorkflow = nil
        activeWorkflowMatch = nil
        forcedWorkflowId = nil
        activeRuleName = nil
        activeRuleReasonLabel = nil
        activeRuleExplanation = nil
    }

    private func workflowExplanation(
        for match: WorkflowMatchResult,
        activeApp: (name: String?, bundleId: String?, url: String?)?
    ) -> String {
        let appDescriptor = activeApp?.name ?? activeApp?.bundleId ?? "the active app"

        let base: String
        switch match.kind {
        case .appAndWebsite:
            if let domain = match.matchedDomain {
                base = localizedAppText(
                    "This workflow applies because \(appDescriptor) was detected together with \(domain).",
                    de: "Dieser Workflow greift, weil \(appDescriptor) zusammen mit \(domain) erkannt wurde.",
                    ja: "\(appDescriptor) と \(domain) が一緒に検出されたため、このワークフローが適用されます。"
                )
            } else {
                base = localizedAppText(
                    "This workflow applies because the app and website were detected together.",
                    de: "Dieser Workflow greift, weil App und Website zusammen erkannt wurden.",
                    ja: "アプリとWebサイトが一緒に検出されたため、このワークフローが適用されます。"
                )
            }
        case .website:
            if let domain = match.matchedDomain {
                base = localizedAppText(
                    "This workflow applies because \(domain) was detected.",
                    de: "Dieser Workflow greift, weil \(domain) erkannt wurde.",
                    ja: "\(domain) が検出されたため、このワークフローが適用されます。"
                )
            } else {
                base = localizedAppText(
                    "This workflow applies because the current website was detected.",
                    de: "Dieser Workflow greift, weil die aktuelle Website erkannt wurde.",
                    ja: "現在のWebサイトが検出されたため、このワークフローが適用されます。"
                )
            }
        case .app:
            base = localizedAppText(
                "This workflow applies because \(appDescriptor) was detected.",
                de: "Dieser Workflow greift, weil \(appDescriptor) erkannt wurde.",
                ja: "\(appDescriptor) が検出されたため、このワークフローが適用されます。"
            )
        case .globalFallback:
            base = localizedAppText(
                "This workflow applies because no more specific workflow matched.",
                de: "Dieser Workflow greift, weil kein spezifischerer Workflow gepasst hat.",
                ja: "より具体的なワークフローに一致しなかったため、このワークフローが適用されます。"
            )
        case .manualOverride:
            base = localizedAppText(
                "This workflow was manually triggered via its keyboard shortcut.",
                de: "Dieser Workflow wurde manuell ueber seine Tastenkombination ausgeloest.",
                ja: "このワークフローはキーボードショートカットで手動実行されました。"
            )
        }

        guard match.wonBySortOrder else { return base }
        return base + localizedAppText(
            " Among multiple matching workflows, the one higher in the list wins here.",
            de: " Unter mehreren passenden Workflows gewinnt hier der weiter oben stehende Eintrag.",
            ja: " 複数の一致するワークフローがある場合は、一覧で上位のものが優先されます。"
        )
    }

    // MARK: - Shared Helpers

    /// Builds an LLM handler for the post-processing pipeline.
    /// Priority: workflow > translation > nil.
    private func buildLLMHandler(
        translationTarget: String?,
        detectedLanguage: String?,
        configuredLanguage: String?,
        resolvedOutputFormat: String?
    ) -> ((String) async throws -> String)? {
        if let workflowHandler = buildWorkflowTextProcessingHandler(
            translationTarget: translationTarget,
            detectedLanguage: detectedLanguage,
            configuredLanguage: configuredLanguage,
            resolvedOutputFormat: resolvedOutputFormat
        ) {
            return workflowHandler
        }

        #if canImport(Translation)
        if let targetCode = translationTarget {
            if #available(macOS 15, *), let ts = translationService as? TranslationService {
                let sourceRaw = detectedLanguage ?? configuredLanguage
                let sourceNormalized = TranslationService.normalizedLanguageIdentifier(from: sourceRaw)
                if let sourceRaw {
                    if let sourceNormalized {
                        if sourceRaw.caseInsensitiveCompare(sourceNormalized) != .orderedSame {
                            logger.info("Translation source normalized \(sourceRaw, privacy: .public) -> \(sourceNormalized, privacy: .public)")
                        }
                    } else {
                        logger.warning("Translation source language \(sourceRaw, privacy: .public) invalid, using auto source")
                    }
                }
                let sourceLanguage = sourceNormalized.map { Locale.Language(identifier: $0) }
                return { text in
                    guard let targetNormalized = TranslationService.normalizedLanguageIdentifier(from: targetCode) else {
                        logger.error("Translation target language invalid: \(targetCode, privacy: .public)")
                        return text
                    }
                    if targetCode.caseInsensitiveCompare(targetNormalized) != .orderedSame {
                        logger.info("Translation target normalized \(targetCode, privacy: .public) -> \(targetNormalized, privacy: .public)")
                    }
                    let target = Locale.Language(identifier: targetNormalized)
                    return try await ts.translate(text: text, to: target, source: sourceLanguage)
                }
            }
        }
        #endif

        return nil
    }

    private func buildWorkflowTextProcessingHandler(
        translationTarget: String?,
        detectedLanguage: String?,
        configuredLanguage: String?,
        resolvedOutputFormat: String?
    ) -> ((String) async throws -> String)? {
        guard let workflow = matchedWorkflow else { return nil }

        let workflowProcessor = workflowTextProcessingService
        let workflowService = workflowService
        guard workflowProcessor.canProcess(
            workflow: workflow,
            fallbackTranslationTarget: translationTarget,
            detectedLanguage: detectedLanguage,
            configuredLanguage: configuredLanguage,
            resolvedOutputFormat: resolvedOutputFormat
        ) else {
            return nil
        }

        return { text in
            if workflowService.shouldSkipAIProcessingForShortDictation(text: text) {
                logger.info("Skipping workflow AI processing for short dictation")
                return text
            }

            return try await workflowProcessor.process(
                workflow: workflow,
                text: text,
                fallbackTranslationTarget: translationTarget,
                detectedLanguage: detectedLanguage,
                configuredLanguage: configuredLanguage,
                resolvedOutputFormat: resolvedOutputFormat
            )
        }
    }

    /// Builds the system prompt for inline command detection.
    nonisolated static func buildInlineCommandSystemPrompt(baseContext: String?) -> String {
        var prompt = """
        The user dictated text that may contain a spoken transformation instruction (e.g., "write this as an email", "summarize this", "mach daraus Stichpunkte"). \
        If found, remove the instruction and apply the transformation. If not found, return the text unchanged. \
        Return ONLY the final text - no explanations, prefixes, or quotes. The instruction can be in any language and anywhere in the text.
        """
        if let baseContext, !baseContext.isEmpty {
            prompt += "\nAlso apply this style context: \(baseContext)"
        }
        return prompt
    }

    /// Executes an action plugin and handles its result (feedback, clipboard URL, events).
    private func executeActionPlugin(
        _ plugin: any ActionPlugin,
        pluginId: String,
        text: String,
        activeApp: (name: String?, bundleId: String?, url: String?),
        language: String? = nil,
        originalText: String? = nil
    ) async throws {
        let actionContext = ActionContext(
            appName: activeApp.name,
            bundleIdentifier: activeApp.bundleId,
            url: activeApp.url,
            language: language,
            originalText: originalText ?? text
        )
        let actionResult = try await plugin.execute(input: text, context: actionContext)

        guard actionResult.success else {
            throw NSError(domain: "ActionPlugin", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: actionResult.message])
        }

        if let url = actionResult.url {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        }
        actionFeedbackMessage = actionResult.message
        actionFeedbackIcon = actionResult.icon ?? "checkmark.circle.fill"
        actionDisplayDuration = actionResult.displayDuration ?? 3.5
        EventBus.shared.emit(.actionCompleted(ActionCompletedPayload(
            actionId: pluginId, success: true, message: actionResult.message,
            url: actionResult.url, appName: activeApp.name, bundleIdentifier: activeApp.bundleId
        )))
    }

    // MARK: - Workflow Palette

    var canCopyLastTranscription: Bool {
        recentTranscriptionStore.latestEntry(historyRecords: historyService.records) != nil
    }

    func copyLastTranscriptionToClipboard() {
        guard let entry = recentTranscriptionStore.latestEntry(historyRecords: historyService.records) else { return }
        let text = entry.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let pasteboard = pasteboardProvider()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func readBackLastTranscription() {
        guard let text = lastTranscribedText else { return }
        speechFeedbackService.readBack(text: text, language: lastTranscriptionLanguage)
    }

    var canRecoverLastRecording: Bool {
        audioRecordingService.latestRecoveryRecordingURL != nil
    }

    func recoverLastRecording(openSettingsWindow: Bool = true) {
        guard audioRecordingService.latestRecoveryRecordingURL != nil else { return }

        if let navigationCoordinator = SettingsNavigationCoordinator.shared {
            navigationCoordinator.navigate(to: .dictationRecovery)
        }
        if openSettingsWindow {
            ManagedAppWindowOpener.shared.open(id: "settings")
        }
    }

    func triggerWorkflowPalette() {
        recentTranscriptionPaletteHandler.hide()
        promptPaletteHandler.triggerSelection(currentState: state, soundFeedbackEnabled: soundFeedbackEnabled)
    }

    func processWorkflowHotkeyText(workflowId: UUID) {
        recentTranscriptionPaletteHandler.hide()
        promptPaletteHandler.hide()
        guard let workflow = workflowService.workflow(id: workflowId) else { return }
        promptPaletteHandler.processWorkflowDirectly(
            workflow: workflow,
            currentState: state,
            soundFeedbackEnabled: soundFeedbackEnabled
        )
    }

    func triggerRecentTranscriptionsPalette() {
        promptPaletteHandler.hide()
        recentTranscriptionPaletteHandler.triggerSelection(currentState: state)
    }

    private func startTargetAppCorrectionLearningIfNeeded(
        insertedText: String,
        baseline: TextInsertionService.FocusedTextObservation?
    ) {
        targetAppCorrectionLearningTask?.cancel()
        targetAppCorrectionLearningTask = nil

        guard shouldTrackTargetAppCorrectionLearning,
              let baseline else {
            return
        }

        targetAppCorrectionLearningTask = Task { @MainActor [weak self, baseline, insertedText] in
            guard let self else { return }
            let learned = await self.targetAppCorrectionLearningService.trackInsertion(
                insertedText: insertedText,
                baseline: baseline
            )
            guard !Task.isCancelled else { return }
            self.targetAppCorrectionLearningTask = nil
            guard !learned.isEmpty else { return }
            self.showLearnedCorrectionsFeedback(learned)
        }
    }

    private func cancelTargetAppCorrectionLearning() {
        targetAppCorrectionLearningTask?.cancel()
        targetAppCorrectionLearningTask = nil
    }

    private func clearPendingUndoActionFeedback() {
        actionFeedbackUndoTitle = nil
        pendingLearnedCorrections = []
    }

    private func showLearnedCorrectionsFeedback(_ learned: [LearnedDictionaryCorrection]) {
        guard !learned.isEmpty else { return }

        pendingLearnedCorrections = learned
        let message: String
        if learned.count == 1, let correction = learned.first {
            message = String.localizedStringWithFormat(
                String(localized: "Learned “%@” -> “%@”"),
                correction.original,
                correction.replacement
            )
        } else {
            message = String.localizedStringWithFormat(
                String(localized: "Learned %d corrections"),
                learned.count
            )
        }

        showNotchFeedback(
            message: message,
            icon: "wand.and.sparkles",
            duration: 8.0,
            undoTitle: String(localized: "Undo")
        )
    }

    func undoActionFeedback() {
        guard !pendingLearnedCorrections.isEmpty else { return }
        dictionaryService.undoLearnedCorrections(pendingLearnedCorrections)
        pendingLearnedCorrections = []
        showNotchFeedback(
            message: String(localized: "Correction learning undone"),
            icon: "arrow.uturn.backward.circle.fill",
            duration: 2.5
        )
    }

    private func showNotchFeedback(
        message: String,
        icon: String,
        duration: TimeInterval = 2.5,
        isError: Bool = false,
        errorCategory: String = "general",
        undoTitle: String? = nil
    ) {
        actionFeedbackMessage = message
        actionFeedbackIcon = icon
        actionFeedbackIsError = isError
        if undoTitle == nil {
            clearPendingUndoActionFeedback()
        } else {
            actionFeedbackUndoTitle = undoTitle
        }
        actionDisplayDuration = duration
        state = .inserting

        if isError {
            errorLogService.addEntry(message: message, category: errorCategory)
        }

        insertingResetTask?.cancel()
        insertingResetTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            resetDictationState()
        }
    }

    func updateExternalStreamingDisplay(active: Bool) {
        externalStreamingDisplayCount += active ? 1 : -1
    }

    private func showError(_ message: String, category: String = "general") {
        soundService.play(.error, enabled: soundFeedbackEnabled)
        showNotchFeedback(message: message, icon: "xmark.circle.fill", duration: 3.0, isError: true, errorCategory: category)
    }

    private func startRecordingTimer() {
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDuration = 0
    }
}

enum ShortSpeechDecision: Equatable {
    case discardTooShort
    case discardNoSpeech
    case transcribe

    var logDescription: String {
        switch self {
        case .discardTooShort:
            "discardTooShort"
        case .discardNoSpeech:
            "discardNoSpeech"
        case .transcribe:
            "transcribe"
        }
    }
}

func hasConfirmedTranscriptionResultText(_ result: TranscriptionResult?) -> Bool {
    guard let result else { return false }
    return !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

enum DictationInsertionTextFormatter {
    static func contextualInsertionEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: UserDefaultsKeys.appFormattingEnabled)
    }

    static func textForInsertion(
        _ text: String,
        insertionContext: TextInsertionService.InsertionContext? = nil,
        contextualInsertionEnabled: Bool = true
    ) -> String {
        guard contextualInsertionEnabled, let insertionContext else {
            return textWithTrailingSpaceIfNeeded(text)
        }

        let boundaries = insertionBoundaries(for: insertionContext)
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isHighConfidenceMidSentenceInsertion(boundaries) {
            result = lowercasingFirstWordIfSafe(result)
        }
        if shouldStripFinalPeriod(boundaries) {
            result = strippingSingleFinalPeriod(result)
        }

        if let previous = boundaries.previousCharacter,
           let first = result.first,
           shouldInsertSpace(between: previous, and: first) {
            result = " " + result
        }

        if let next = boundaries.nextCharacter {
            if let last = result.last,
               shouldInsertSpace(between: last, and: next) {
                result += " "
            }
        } else {
            result = textWithTrailingSpaceIfNeeded(result)
        }

        return result
    }

    private static func textWithTrailingSpaceIfNeeded(_ text: String) -> String {
        guard let lastScalar = text.unicodeScalars.last else { return text }
        guard !CharacterSet.whitespacesAndNewlines.contains(lastScalar) else { return text }
        return text + " "
    }

    private struct InsertionBoundaries {
        let previousCharacter: Character?
        let nextCharacter: Character?
        let previousNonWhitespaceCharacter: Character?
        let nextNonWhitespaceCharacter: Character?
    }

    private static func insertionBoundaries(
        for context: TextInsertionService.InsertionContext
    ) -> InsertionBoundaries {
        guard let selectedRange = Range(context.selectedRange, in: context.value) else {
            return InsertionBoundaries(
                previousCharacter: context.previousCharacter,
                nextCharacter: context.nextCharacter,
                previousNonWhitespaceCharacter: nonWhitespaceCharacter(context.previousCharacter),
                nextNonWhitespaceCharacter: nonWhitespaceCharacter(context.nextCharacter)
            )
        }

        let previousCharacter = selectedRange.lowerBound > context.value.startIndex
            ? context.value[context.value.index(before: selectedRange.lowerBound)]
            : nil
        let nextCharacter = selectedRange.upperBound < context.value.endIndex
            ? context.value[selectedRange.upperBound]
            : nil

        return InsertionBoundaries(
            previousCharacter: previousCharacter,
            nextCharacter: nextCharacter,
            previousNonWhitespaceCharacter: previousNonWhitespaceCharacter(
                before: selectedRange.lowerBound,
                in: context.value
            ),
            nextNonWhitespaceCharacter: nextNonWhitespaceCharacter(
                after: selectedRange.upperBound,
                in: context.value
            )
        )
    }

    private static func previousNonWhitespaceCharacter(
        before index: String.Index,
        in value: String
    ) -> Character? {
        var currentIndex = index
        while currentIndex > value.startIndex {
            let previousIndex = value.index(before: currentIndex)
            let character = value[previousIndex]
            if !isWhitespace(character) {
                return character
            }
            currentIndex = previousIndex
        }
        return nil
    }

    private static func nextNonWhitespaceCharacter(
        after index: String.Index,
        in value: String
    ) -> Character? {
        var currentIndex = index
        while currentIndex < value.endIndex {
            let character = value[currentIndex]
            if !isWhitespace(character) {
                return character
            }
            currentIndex = value.index(after: currentIndex)
        }
        return nil
    }

    private static func nonWhitespaceCharacter(_ character: Character?) -> Character? {
        guard let character, !isWhitespace(character) else { return nil }
        return character
    }

    private static func isHighConfidenceMidSentenceInsertion(
        _ boundaries: InsertionBoundaries
    ) -> Bool {
        guard let previous = boundaries.previousNonWhitespaceCharacter else { return false }
        return isWordLike(previous)
    }

    private static func shouldStripFinalPeriod(_ boundaries: InsertionBoundaries) -> Bool {
        guard isHighConfidenceMidSentenceInsertion(boundaries),
              let next = boundaries.nextNonWhitespaceCharacter else {
            return false
        }
        return isWordLike(next) || closingPunctuation.contains(next)
    }

    private static func lowercasingFirstWordIfSafe(_ text: String) -> String {
        var result = text
        guard let wordRange = firstWordRange(in: result),
              shouldLowercaseFirstWord(String(result[wordRange])) else {
            return result
        }

        let firstIndex = wordRange.lowerBound
        let nextIndex = result.index(after: firstIndex)
        result.replaceSubrange(firstIndex..<nextIndex, with: String(result[firstIndex]).lowercased())
        return result
    }

    private static func firstWordRange(in text: String) -> Range<String.Index>? {
        var start = text.startIndex
        while start < text.endIndex, isWhitespace(text[start]) {
            start = text.index(after: start)
        }
        guard start < text.endIndex, isWordLike(text[start]) else {
            return nil
        }

        var end = text.index(after: start)
        while end < text.endIndex, isWordLike(text[end]) {
            end = text.index(after: end)
        }
        return start..<end
    }

    private static func shouldLowercaseFirstWord(_ word: String) -> Bool {
        guard word.count > 1,
              let first = word.first,
              isUppercaseLetter(first) else {
            return false
        }

        let remainder = word.dropFirst()
        guard remainder.contains(where: isLowercaseLetter) else {
            return false
        }
        return !remainder.contains(where: isUppercaseLetter)
    }

    private static func strippingSingleFinalPeriod(_ text: String) -> String {
        var result = text
        var currentIndex = result.endIndex

        while currentIndex > result.startIndex {
            let previousIndex = result.index(before: currentIndex)
            if isWhitespace(result[previousIndex]) {
                currentIndex = previousIndex
                continue
            }

            guard result[previousIndex] == "." else {
                return result
            }
            if previousIndex > result.startIndex {
                let beforePeriod = result.index(before: previousIndex)
                guard result[beforePeriod] != "." else {
                    return result
                }
            }
            result.removeSubrange(previousIndex..<currentIndex)
            return result
        }

        return result
    }

    private static func shouldInsertSpace(between left: Character, and right: Character) -> Bool {
        if isWhitespace(left) || isWhitespace(right) {
            return false
        }
        if closingPunctuation.contains(right) || openingPunctuation.contains(left) {
            return false
        }
        if isWordLike(left) && isWordLike(right) {
            return true
        }
        if isWordLike(right) && punctuationThatTakesFollowingSpace.contains(left) {
            return true
        }
        return false
    }

    private static let openingPunctuation: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘"]
    private static let closingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "\"", "'", "”", "’"]
    private static let punctuationThatTakesFollowingSpace: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "\"", "'", "”", "’"]

    private static func isWordLike(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func isUppercaseLetter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
    }

    private static func isLowercaseLetter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }
    }
}

func classifyShortSpeech(
    rawDuration: TimeInterval,
    peakLevel: Float,
    hasConfirmedText: Bool,
    transcribeShortQuietClipsAggressively: Bool = true
) -> ShortSpeechDecision {
    guard rawDuration >= 0.04 else { return .discardTooShort }
    if hasConfirmedText { return .transcribe }

    if rawDuration < 1.0 {
        // Bias toward transcribing short clips. False negatives here are worse than
        // letting the recognizer return empty text for actual silence.
        if peakLevel < 0.003 {
            return transcribeShortQuietClipsAggressively ? .transcribe : .discardNoSpeech
        }
        return .transcribe
    }

    if peakLevel < 0.006 { return .discardNoSpeech }
    return .transcribe
}

func paddedSamplesForFinalTranscription(_ samples: [Float], rawDuration: TimeInterval) -> [Float] {
    var paddedSamples = samples

    if rawDuration < 0.75 {
        let targetSampleCount = Int(0.75 * AudioRecordingService.targetSampleRate)
        let padCount = max(0, targetSampleCount - samples.count)
        paddedSamples.append(contentsOf: [Float](repeating: 0, count: padCount))
    } else {
        let tailPadCount = Int(0.3 * AudioRecordingService.targetSampleRate)
        paddedSamples.append(contentsOf: [Float](repeating: 0, count: tailPadCount))
    }

    return paddedSamples
}
