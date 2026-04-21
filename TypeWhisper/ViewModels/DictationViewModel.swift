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

    @Published var state: State = .idle
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
    @Published var preserveClipboard: Bool {
        didSet { UserDefaults.standard.set(preserveClipboard, forKey: UserDefaultsKeys.preserveClipboard) }
    }
    @Published var mediaPauseEnabled: Bool {
        didSet { UserDefaults.standard.set(mediaPauseEnabled, forKey: UserDefaultsKeys.mediaPauseEnabled) }
    }
    @Published var transcribeShortQuietClipsAggressively: Bool {
        didSet { Self.persistTranscribeShortQuietClipsAggressively(transcribeShortQuietClipsAggressively) }
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
    @Published var activeRuleName: String?
    @Published var activeRuleReasonLabel: String?
    @Published var activeRuleExplanation: String?
    @Published var processingPhase: String?
    @Published var actionFeedbackMessage: String?
    @Published var actionFeedbackIcon: String?
    @Published var actionFeedbackIsError: Bool = false
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
    private let profileService: ProfileService
    private let translationService: AnyObject? // TranslationService (macOS 15+)
    private let audioDuckingService: AudioDuckingService
    private let dictionaryService: DictionaryService
    private let snippetService: SnippetService
    private let soundService: SoundService
    private let audioDeviceService: AudioDeviceService
    private let promptActionService: PromptActionService
    private let promptProcessingService: PromptProcessingService
    private let speechFeedbackService: SpeechFeedbackService
    private let accessibilityAnnouncementService: AccessibilityAnnouncementService
    private let errorLogService: ErrorLogService
    private let mediaPlaybackService: MediaPlaybackService
    private let postProcessingPipeline: PostProcessingPipeline
    private var matchedProfile: Profile?
    private var activeRuleMatch: RuleMatchResult?
    private var forcedProfileId: UUID?
    private var capturedActiveApp: (name: String?, bundleId: String?, url: String?)?
    private var capturedSelectedText: String?

    private var cancellables = Set<AnyCancellable>()
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private let streamingHandler: StreamingHandler
    private let promptPaletteHandler: PromptPaletteHandler
    private let settingsHandler: DictationSettingsHandler
    private var transcriptionTask: Task<Void, Never>?
    private var errorResetTask: Task<Void, Never>?
    private var insertingResetTask: Task<Void, Never>?
    @Published private(set) var recordingCancelWarningActive: Bool = false
    private var urlResolutionTask: Task<Void, Never>?
    private var metadataCaptureTask: Task<Void, Never>?
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
    }
    private var lastStreamingParams: StreamingParamsSnapshot?
    private var isStopInFlight = false
    private var activeDictationSessionID: UUID?
    private var pendingPushToTalkDiscardMessage: String?
    private var dictationSessions: [UUID: DictationSessionSnapshot] = [:]
    private var dictationSessionOrder: [UUID] = []
    private let maxTrackedDictationSessions = 100

    var recordingCancelWarningMessage: String? {
        guard state == .recording, recordingCancelWarningActive else { return nil }
        return String(localized: "Press Esc again to cancel recording")
    }

    init(
        audioRecordingService: AudioRecordingService,
        textInsertionService: TextInsertionService,
        hotkeyService: HotkeyService,
        modelManager: ModelManagerService,
        settingsViewModel: SettingsViewModel,
        historyService: HistoryService,
        profileService: ProfileService,
        translationService: AnyObject?,
        audioDuckingService: AudioDuckingService,
        dictionaryService: DictionaryService,
        snippetService: SnippetService,
        soundService: SoundService,
        audioDeviceService: AudioDeviceService,
        promptActionService: PromptActionService,
        promptProcessingService: PromptProcessingService,
        appFormatterService: AppFormatterService,
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
        self.profileService = profileService
        self.translationService = translationService
        self.audioDuckingService = audioDuckingService
        self.dictionaryService = dictionaryService
        self.snippetService = snippetService
        self.soundService = soundService
        self.audioDeviceService = audioDeviceService
        self.promptActionService = promptActionService
        self.promptProcessingService = promptProcessingService
        self.speechFeedbackService = speechFeedbackService
        self.accessibilityAnnouncementService = accessibilityAnnouncementService
        self.errorLogService = errorLogService
        self.mediaPlaybackService = mediaPlaybackService
        self.postProcessingPipeline = PostProcessingPipeline(
            snippetService: snippetService,
            dictionaryService: dictionaryService,
            appFormatterService: appFormatterService
        )
        self.streamingHandler = StreamingHandler(
            modelManager: modelManager,
            streamPromptProvider: { [weak dictionaryService] in
                dictionaryService?.getTermsForPrompt() ?? ""
            },
            bufferProvider: { [weak audioRecordingService] in
                audioRecordingService?.getCurrentBuffer() ?? []
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
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            soundService: soundService,
            accessibilityAnnouncementService: accessibilityAnnouncementService
        )
        self.settingsHandler = DictationSettingsHandler(
            hotkeyService: hotkeyService,
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            profileService: profileService
        )
        self.audioDuckingEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.audioDuckingEnabled)
        self.audioDuckingLevel = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingLevel) as? Double ?? 0.2
        self.soundFeedbackEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.soundFeedbackEnabled) as? Bool ?? true
        self.indicatorTranscriptPreviewEnabled = Self.loadIndicatorTranscriptPreviewEnabled()
        self.preserveClipboard = UserDefaults.standard.bool(forKey: UserDefaultsKeys.preserveClipboard)
        self.mediaPauseEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.mediaPauseEnabled)
        self.transcribeShortQuietClipsAggressively = Self.loadTranscribeShortQuietClipsAggressively()
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

    nonisolated static func loadIndicatorStyle(defaults: UserDefaults = .standard) -> IndicatorStyle {
        defaults.string(forKey: UserDefaultsKeys.indicatorStyle)
            .flatMap { IndicatorStyle(rawValue: $0) } ?? .notch
    }

    nonisolated static func persistIndicatorStyle(_ style: IndicatorStyle, defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: UserDefaultsKeys.indicatorStyle)
    }

    nonisolated static func loadTranscribeShortQuietClipsAggressively(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: UserDefaultsKeys.transcribeShortQuietClipsAggressively) as? Bool ?? false
    }

    nonisolated static func persistTranscribeShortQuietClipsAggressively(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: UserDefaultsKeys.transcribeShortQuietClipsAggressively)
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
        startRecording(sessionID: sessionID)
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

    private func clearDeferredRecordingContext() {
        metadataCaptureTask?.cancel()
        metadataCaptureTask = nil
        urlResolutionTask?.cancel()
        urlResolutionTask = nil
        lastStreamingParams = nil
    }

    private func abortActiveRecordingImmediately(sessionMessage: String) {
        clearDeferredRecordingContext()
        restoreRecordingSideEffects()
        streamingHandler.stop()
        stopRecordingTimer()
        Task {
            _ = await audioRecordingService.stopRecording(policy: .immediate)
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
        hotkeyService.onDictationStart = { [weak self] in
            self?.startRecording()
        }

        hotkeyService.onDictationStop = { [weak self] in
            self?.stopDictation()
        }

        hotkeyService.onProfileDictationStart = { [weak self] profileId in
            self?.startRecording(forcedProfileId: profileId)
        }

        hotkeyService.onCancelPressed = { [weak self] in
            self?.handleCancelHotkey()
        }

        hotkeyService.onPushToTalkInterruption = { [weak self] in
            self?.handlePushToTalkInterruption()
        }

        // Sync profile hotkeys whenever profiles change
        // dropFirst: avoid early monitor setup during ServiceContainer.init() before app is ready
        profileService.$profiles
            .dropFirst()
            .sink { [weak self] profiles in
                guard let self else { return }
                self.settingsHandler.syncProfileHotkeys(profiles)
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
                self.abortActiveRecordingImmediately(sessionMessage: errorMessage)
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
        switch state {
        case .recording:
            if recordingCancelWarningActive {
                recordingCancelWarningActive = false
                cancelCurrentOperation()
            } else {
                recordingCancelWarningActive = true
            }
        case .processing:
            cancelCurrentOperation()
        default:
            break
        }
    }

    private func clearRecordingCancelWarning() {
        recordingCancelWarningActive = false
    }

    private func cancelCurrentOperation() {
        let cancelledMessage = String(localized: "Cancelled")

        switch state {
        case .recording:
            guard !isStopInFlight else { return }
            abortActiveRecordingImmediately(sessionMessage: cancelledMessage)
            showNotchFeedback(message: cancelledMessage, icon: "xmark.circle", duration: 1.5)
        case .processing:
            cancelActiveDictationSessionIfNeeded(message: cancelledMessage)
            transcriptionTask?.cancel()
            transcriptionTask = nil
            showNotchFeedback(message: cancelledMessage, icon: "xmark.circle", duration: 1.5)
        default:
            break
        }
    }

    private func startRecording(forcedProfileId: UUID? = nil, sessionID: UUID = UUID()) {
        let startTimestamp = CFAbsoluteTimeGetCurrent()

        // Dismiss prompt palette if active
        promptPaletteHandler.hide()

        // Cancel auto-unload timer to prevent unloading during recording
        modelManager.cancelAutoUnloadTimer()

        // Cancel any pending transcription from a previous recording
        if transcriptionTask != nil {
            cancelActiveDictationSessionIfNeeded()
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        insertingResetTask?.cancel()
        insertingResetTask = nil
        clearRecordingCancelWarning()
        pendingPushToTalkDiscardMessage = nil
        metadataCaptureTask?.cancel()
        metadataCaptureTask = nil
        urlResolutionTask?.cancel()
        urlResolutionTask = nil

        self.forcedProfileId = forcedProfileId
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

        // Match rule: forced manual override or app-based matching
        let activeApp = textInsertionService.captureActiveApp()
        capturedActiveApp = activeApp
        capturedSelectedText = nil
        activeAppIcon = nil

        if let forcedProfileId,
           let forcedProfile = profileService.profiles.first(where: { $0.id == forcedProfileId && $0.isEnabled }) {
            applyRuleMatch(profileService.forcedRuleMatch(for: forcedProfile), activeApp: activeApp)
        } else {
            applyRuleMatch(profileService.matchRule(bundleIdentifier: activeApp.bundleId, url: nil), activeApp: activeApp)
        }
        let immediateContextMs = (CFAbsoluteTimeGetCurrent() - startTimestamp) * 1000

        do {
            // Play start sound BEFORE engine setup - AVAudioEngine reconfigures
            // audio hardware (aggregate device) which disrupts NSSound playback.
            soundService.play(.recordingStarted, enabled: soundFeedbackEnabled)
            audioRecordingService.selectedDeviceID = audioDeviceService.selectedDeviceID
            audioRecordingService.hasExplicitDeviceSelection = audioDeviceService.selectedDeviceUID != nil
            try audioRecordingService.startRecording()
            if mediaPauseEnabled { mediaPlaybackService.pauseIfPlaying() }
            if audioDuckingEnabled {
                audioDuckingService.duckAudio(to: Float(audioDuckingLevel))
            }
            state = .recording
            // Reset hotkey timer so hybrid threshold counts from recording start,
            // not from key press. Slow device init (e.g. iPhone Continuity ~2-3s)
            // would otherwise make the hold appear as "long press" → PTT stop.
            hotkeyService.resetKeyDownTime()
            accessibilityAnnouncementService.announceRecordingStarted()
            partialText = ""
            isStopInFlight = false
            recordingStartTime = Date()
            startRecordingTimer()
            startLiveStreaming(allowLiveTranscription: indicatorTranscriptPreviewEnabled || externalStreamingDisplayCount > 0)
            EventBus.shared.emit(.recordingStarted(RecordingStartedPayload(
                appName: capturedActiveApp?.name,
                bundleIdentifier: capturedActiveApp?.bundleId
            )))
            scheduleDeferredRecordingMetadataCapture(activeApp: activeApp, forcedProfileId: forcedProfileId)

            let totalStartMs = (CFAbsoluteTimeGetCurrent() - startTimestamp) * 1000
            logger.info(
                "Recording started: immediateContextMs=\(String(format: "%.1f", immediateContextMs), privacy: .public), totalStartMs=\(String(format: "%.1f", totalStartMs), privacy: .public)"
            )
        } catch {
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
        forcedProfileId: UUID?
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
        // If a more specific URL rule matches, update the active rule on the fly.
        // Skip URL resolution when a forced rule is set (manual rule shortcut overrides app matching).
        guard forcedProfileId == nil, let bundleId = activeApp.bundleId else { return }
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
            guard let refinedRule = profileService.matchRule(bundleIdentifier: bundleId, url: resolvedURL) else {
                logger.info("URL resolution: no rule matched for URL \(resolvedURL)")
                return
            }

            logger.info("URL resolution: matched rule '\(refinedRule.profile.name)'")
            applyRuleMatch(refinedRule, activeApp: capturedActiveApp)
            refreshLiveStreamingIfParamsChanged()
        }
    }

    private var effectiveLanguageSelection: LanguageSelection {
        if let profileLang = matchedProfile?.inputLanguage {
            let profileSelection = LanguageSelection(
                storedValue: profileLang,
                nilBehavior: .inheritGlobal
            )
            if profileSelection != .inheritGlobal {
                return profileSelection
            }
        }
        return settingsViewModel.languageSelection
    }

    private var effectiveLanguage: String? {
        effectiveLanguageSelection.requestedLanguage
    }

    private var effectiveTask: TranscriptionTask {
        if let profileTask = matchedProfile?.selectedTask,
           let task = TranscriptionTask(rawValue: profileTask) {
            return task
        }
        return settingsViewModel.selectedTask
    }

    private var effectiveTranslationTarget: String? {
        // Per-profile translation override
        if let profileEnabled = matchedProfile?.translationEnabled {
            if !profileEnabled { return nil }
            return matchedProfile?.translationTargetLanguage ?? settingsViewModel.translationTargetLanguage
        }
        // Existing behavior: profile target language override, then global setting
        if let profileTarget = matchedProfile?.translationTargetLanguage {
            return profileTarget
        }
        if settingsViewModel.translationEnabled {
            return settingsViewModel.translationTargetLanguage
        }
        return nil
    }

    private var effectiveEngineOverrideId: String? {
        matchedProfile?.engineOverride
    }

    private var effectiveCloudModelOverride: String? {
        matchedProfile?.cloudModelOverride
    }

    private var effectivePromptAction: PromptAction? {
        if let actionId = matchedProfile?.promptActionId {
            return promptActionService.action(byId: actionId)
        }
        return nil
    }

    private func stopDictation() {
        guard state == .recording, !isStopInFlight else { return }
        clearRecordingCancelWarning()
        isStopInFlight = true
        Task {
            await finalizeStopDictation()
        }
    }

    private func finalizeStopDictation() async {
        let sessionID = activeDictationSessionID

        restoreRecordingSideEffects()
        if let discardMessage = pendingPushToTalkDiscardMessage {
            pendingPushToTalkDiscardMessage = nil
            streamingHandler.stop()
            lastStreamingParams = nil
            stopRecordingTimer()
            _ = await audioRecordingService.stopRecording(policy: .immediate)
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
                let languageSelection = effectiveLanguageSelection
                let language = languageSelection.requestedLanguage
                let task = effectiveTask
                let engineOverride = effectiveEngineOverrideId
                let cloudModelOverride = effectiveCloudModelOverride
                let translationTarget = effectiveTranslationTarget
                let termsPrompt = dictionaryService.getTermsForPrompt()

                let result = if let liveSessionResult {
                    liveSessionResult
                } else {
                    try await modelManager.transcribe(
                        audioSamples: samples,
                        languageSelection: languageSelection,
                        task: task,
                        engineOverrideId: engineOverride,
                        cloudModelOverride: cloudModelOverride,
                        prompt: termsPrompt
                    )
                }

                // Bail out if a new recording started while we were transcribing
                guard !Task.isCancelled else { return }

                var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    logger.info("Transcription returned empty text (duration: \(String(format: "%.2f", result.duration))s, engine: \(result.engineUsed))")
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
                    configuredLanguage: language
                )

                guard !Task.isCancelled else { return }

                // Post-processing pipeline (priority-based)
                let llmStepName: String? = if llmHandler != nil {
                    (self.effectivePromptAction != nil || self.matchedProfile?.inlineCommandsEnabled == true) ? "Prompt" : "Translation"
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
                    ruleName: self.matchedProfile?.name,
                    selectedText: self.capturedSelectedText
                )
                let ppResult = try await postProcessingPipeline.process(
                    text: text, context: ppContext, llmHandler: llmHandler,
                    outputFormat: self.matchedProfile?.outputFormat,
                    llmStepName: llmStepName
                )
                text = ppResult.text

                partialText = ""

                // Route to action plugin or insert text
                if let actionPluginId = self.effectivePromptAction?.targetActionPluginId,
                   let actionPlugin = PluginManager.shared.actionPlugin(for: actionPluginId) {
                    try await executeActionPlugin(
                        actionPlugin, pluginId: actionPluginId, text: text,
                        activeApp: activeApp, language: language, originalText: result.text
                    )
                } else {
                    _ = try await textInsertionService.insertText(
                        text,
                        preserveClipboard: preserveClipboard,
                        autoEnter: self.matchedProfile?.autoEnterEnabled == true
                    )
                    EventBus.shared.emit(.textInserted(TextInsertedPayload(
                        text: text,
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
                        id: sessionID ?? UUID(),
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
                    ruleName: self.matchedProfile?.name
                )))

                soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                let wordCount = text.split(separator: " ").count
                let detectedLang = result.detectedLanguage ?? language
                let completedTranscription = DictationSessionTranscription(
                    text: text,
                    rawText: result.text,
                    timestamp: Date(),
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
    func setHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) { settingsHandler.setHotkey(hotkey, for: slot) }
    func clearHotkey(for slot: HotkeySlotType) { settingsHandler.clearHotkey(for: slot) }
    func isHotkeyAssigned(_ hotkey: UnifiedHotkey, excluding: HotkeySlotType) -> HotkeySlotType? { settingsHandler.isHotkeyAssigned(hotkey, excluding: excluding) }

    private static func loadHotkeyLabel(for slotType: HotkeySlotType) -> String {
        DictationSettingsHandler.loadHotkeyLabel(for: slotType)
    }

    /// Register profile hotkeys after app is fully initialized.
    /// Called from ServiceContainer.initialize() to avoid early monitor setup.
    func registerInitialProfileHotkeys() { settingsHandler.registerInitialProfileHotkeys() }

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
        clearRecordingCancelWarning()
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
        actionDisplayDuration = 3.5
    }

    private func handlePushToTalkInterruption() {
        guard state == .recording, !isStopInFlight else { return }
        pendingPushToTalkDiscardMessage = String(localized: "Recording discarded because additional keys were pressed")
    }

    private func applyRuleMatch(
        _ match: RuleMatchResult?,
        activeApp: (name: String?, bundleId: String?, url: String?)?
    ) {
        activeRuleMatch = match
        matchedProfile = match?.profile
        activeRuleName = match?.profile.name
        activeRuleReasonLabel = match?.kind.label
        activeRuleExplanation = match.map { ruleExplanation(for: $0, activeApp: activeApp) }
    }

    /// Starts the live streaming handler with the currently effective profile params
    /// and records a snapshot for later change detection (release review K3).
    private func startLiveStreaming(allowLiveTranscription: Bool) {
        let params = StreamingParamsSnapshot(
            engineOverrideId: effectiveEngineOverrideId,
            providerId: modelManager.selectedProviderId,
            languageSelection: effectiveLanguageSelection,
            task: effectiveTask,
            cloudModelOverride: effectiveCloudModelOverride
        )
        lastStreamingParams = allowLiveTranscription ? params : nil
        streamingHandler.start(
            engineOverrideId: params.engineOverrideId,
            selectedProviderId: params.providerId,
            languageSelection: params.languageSelection,
            task: params.task,
            cloudModelOverride: params.cloudModelOverride,
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
            cloudModelOverride: effectiveCloudModelOverride
        )
        guard newParams != previous else { return }
        logger.info("Streaming params changed after URL resolution, restarting live session")
        let allowLive = indicatorTranscriptPreviewEnabled || externalStreamingDisplayCount > 0
        startLiveStreaming(allowLiveTranscription: allowLive)
    }

    private func clearActiveRuleState() {
        matchedProfile = nil
        activeRuleMatch = nil
        forcedProfileId = nil
        activeRuleName = nil
        activeRuleReasonLabel = nil
        activeRuleExplanation = nil
    }

    private func ruleExplanation(
        for match: RuleMatchResult,
        activeApp: (name: String?, bundleId: String?, url: String?)?
    ) -> String {
        let appDescriptor = activeApp?.name ?? activeApp?.bundleId ?? "the active app"

        let base: String
        switch match.kind {
        case .appAndWebsite:
            if let domain = match.matchedDomain {
                base = localizedAppText(
                    "This rule applies because \(appDescriptor) was detected together with \(domain).",
                    de: "Diese Regel greift, weil \(appDescriptor) zusammen mit \(domain) erkannt wurde."
                )
            } else {
                base = localizedAppText(
                    "This rule applies because the app and website were detected together.",
                    de: "Diese Regel greift, weil App und Website zusammen erkannt wurden."
                )
            }
        case .websiteOnly:
            if let domain = match.matchedDomain {
                base = localizedAppText(
                    "This rule applies because \(domain) was detected.",
                    de: "Diese Regel greift, weil \(domain) erkannt wurde."
                )
            } else {
                base = localizedAppText(
                    "This rule applies because the current website was detected.",
                    de: "Diese Regel greift, weil die aktuelle Website erkannt wurde."
                )
            }
        case .appOnly:
            base = localizedAppText(
                "This rule applies because \(appDescriptor) was detected.",
                de: "Diese Regel greift, weil \(appDescriptor) erkannt wurde."
            )
        case .globalFallback:
            base = localizedAppText(
                "This rule applies because no more specific rule matched the current context.",
                de: "Diese Regel greift, weil keine spezifischere Regel zum aktuellen Kontext gepasst hat."
            )
        case .manualOverride:
            base = localizedAppText(
                "This rule was manually forced via its keyboard shortcut.",
                de: "Diese Regel wurde manuell über ihre Tastenkombination erzwungen."
            )
        }

        guard match.wonByPriority else { return base }
        return base + localizedAppText(
            " Among equally specific rules, the higher priority wins here.",
            de: " Unter gleich spezifischen Regeln gewinnt hier die höhere Priorität."
        )
    }

    // MARK: - Shared Helpers

    /// Builds an LLM handler for the post-processing pipeline.
    /// Priority: inline commands > prompt action > translation > nil.
    private func buildLLMHandler(
        translationTarget: String?,
        detectedLanguage: String?,
        configuredLanguage: String?
    ) -> ((String) async throws -> String)? {
        // Inline commands compose with profile prompt; otherwise use prompt action directly
        let inlineEnabled = matchedProfile?.inlineCommandsEnabled == true
        if inlineEnabled || effectivePromptAction != nil {
            let pps = promptProcessingService
            let promptAction = effectivePromptAction
            let prompt = inlineEnabled
                ? Self.buildInlineCommandSystemPrompt(baseContext: promptAction?.prompt)
                : promptAction!.prompt
            let providerOverride = promptAction?.providerType
            let modelOverride = promptAction?.cloudModel
            return { text in
                try await pps.process(
                    prompt: prompt, text: text,
                    providerOverride: providerOverride,
                    cloudModelOverride: modelOverride,
                    temperatureDirective: promptAction?.temperatureDirective ?? .inheritProviderSetting
                )
            }
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

    // MARK: - Standalone Prompt Palette

    func readBackLastTranscription() {
        guard let text = lastTranscribedText else { return }
        speechFeedbackService.readBack(text: text, language: lastTranscriptionLanguage)
    }

    func triggerStandalonePromptSelection() {
        promptPaletteHandler.triggerSelection(currentState: state, soundFeedbackEnabled: soundFeedbackEnabled)
    }

    private func showNotchFeedback(message: String, icon: String, duration: TimeInterval = 2.5, isError: Bool = false, errorCategory: String = "general") {
        actionFeedbackMessage = message
        actionFeedbackIcon = icon
        actionFeedbackIsError = isError
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

func classifyShortSpeech(
    rawDuration: TimeInterval,
    peakLevel: Float,
    hasConfirmedText: Bool,
    transcribeShortQuietClipsAggressively: Bool = false
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

    if peakLevel < 0.006 {
        return transcribeShortQuietClipsAggressively ? .transcribe : .discardNoSpeech
    }
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
