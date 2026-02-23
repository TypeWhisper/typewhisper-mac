import AppKit
import ApplicationServices
import Foundation
import Combine
import os
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "DictationViewModel")

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
        case paused          // silence detected, waiting for speech to resume
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
    @Published var whisperModeEnabled: Bool {
        didSet { UserDefaults.standard.set(whisperModeEnabled, forKey: UserDefaultsKeys.whisperModeEnabled) }
    }
    @Published var audioDuckingEnabled: Bool {
        didSet { UserDefaults.standard.set(audioDuckingEnabled, forKey: UserDefaultsKeys.audioDuckingEnabled) }
    }
    @Published var audioDuckingLevel: Double {
        didSet { UserDefaults.standard.set(audioDuckingLevel, forKey: UserDefaultsKeys.audioDuckingLevel) }
    }
    @Published var mediaPauseEnabled: Bool {
        didSet { UserDefaults.standard.set(mediaPauseEnabled, forKey: UserDefaultsKeys.mediaPauseEnabled) }
    }
    @Published var soundFeedbackEnabled: Bool {
        didSet { UserDefaults.standard.set(soundFeedbackEnabled, forKey: UserDefaultsKeys.soundFeedbackEnabled) }
    }
    @Published var silencePauseEnabled: Bool {
        didSet { UserDefaults.standard.set(silencePauseEnabled, forKey: UserDefaultsKeys.silencePauseEnabled) }
    }
    @Published var silenceAutoStopDuration: Double {
        didSet {
            UserDefaults.standard.set(silenceAutoStopDuration, forKey: UserDefaultsKeys.silenceAutoStopDuration)
            audioRecordingService.silenceAutoStopDuration = silenceAutoStopDuration
        }
    }
    @Published var silenceThreshold: Double {
        didSet {
            UserDefaults.standard.set(silenceThreshold, forKey: UserDefaultsKeys.silenceThreshold)
            audioRecordingService.silenceThreshold = Float(silenceThreshold)
        }
    }
    @Published var hybridHotkeyLabel: String
    @Published var pttHotkeyLabel: String
    @Published var toggleHotkeyLabel: String
    @Published var promptPaletteHotkeyLabel: String
    @Published var activeProfileName: String?
    @Published var actionFeedbackMessage: String?
    @Published var actionFeedbackIcon: String?
    private var actionDisplayDuration: TimeInterval = 3.5
    @Published var promptDisplayDuration: Double {
        didSet { UserDefaults.standard.set(promptDisplayDuration, forKey: UserDefaultsKeys.promptDisplayDuration) }
    }

    enum OverlayPosition: String, CaseIterable {
        case top
        case bottom
    }

    enum NotchIndicatorVisibility: String, CaseIterable {
        case always
        case duringActivity
        case never
    }

    enum NotchIndicatorContent: String, CaseIterable {
        case indicator
        case timer
        case waveform
        case clock
        case battery
        case none
    }

    @Published var overlayPosition: OverlayPosition {
        didSet { UserDefaults.standard.set(overlayPosition.rawValue, forKey: UserDefaultsKeys.overlayPosition) }
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

    private let audioRecordingService: AudioRecordingService
    private let textInsertionService: TextInsertionService
    private let hotkeyService: HotkeyService
    private let modelManager: ModelManagerService
    private let settingsViewModel: SettingsViewModel
    private let historyService: HistoryService
    private let profileService: ProfileService
    private let translationService: TranslationService
    private let audioDuckingService: AudioDuckingService
    private let mediaPlaybackService: MediaPlaybackService
    private let dictionaryService: DictionaryService
    private let snippetService: SnippetService
    private let soundService: SoundService
    private let audioDeviceService: AudioDeviceService
    private let promptActionService: PromptActionService
    private let promptProcessingService: PromptProcessingService
    private let postProcessingPipeline: PostProcessingPipeline
    private var matchedProfile: Profile?
    private var capturedActiveApp: (name: String?, bundleId: String?, url: String?)?

    private var cancellables = Set<AnyCancellable>()
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var streamingTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var silenceTimer: Timer?
    private var errorResetTask: Task<Void, Never>?
    private var insertingResetTask: Task<Void, Never>?
    private var urlResolutionTask: Task<Void, Never>?

    init(
        audioRecordingService: AudioRecordingService,
        textInsertionService: TextInsertionService,
        hotkeyService: HotkeyService,
        modelManager: ModelManagerService,
        settingsViewModel: SettingsViewModel,
        historyService: HistoryService,
        profileService: ProfileService,
        translationService: TranslationService,
        audioDuckingService: AudioDuckingService,
        mediaPlaybackService: MediaPlaybackService,
        dictionaryService: DictionaryService,
        snippetService: SnippetService,
        soundService: SoundService,
        audioDeviceService: AudioDeviceService,
        promptActionService: PromptActionService,
        promptProcessingService: PromptProcessingService
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
        self.mediaPlaybackService = mediaPlaybackService
        self.dictionaryService = dictionaryService
        self.snippetService = snippetService
        self.soundService = soundService
        self.audioDeviceService = audioDeviceService
        self.promptActionService = promptActionService
        self.promptProcessingService = promptProcessingService
        self.postProcessingPipeline = PostProcessingPipeline(
            snippetService: snippetService,
            dictionaryService: dictionaryService
        )
        self.whisperModeEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.whisperModeEnabled)
        self.audioDuckingEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.audioDuckingEnabled)
        self.audioDuckingLevel = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingLevel) as? Double ?? 0.2
        self.mediaPauseEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.mediaPauseEnabled)
        self.soundFeedbackEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.soundFeedbackEnabled) as? Bool ?? true
        self.silencePauseEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.silencePauseEnabled)
        let storedDuration = UserDefaults.standard.object(forKey: UserDefaultsKeys.silenceAutoStopDuration) as? Double ?? 4.0
        self.silenceAutoStopDuration = storedDuration
        audioRecordingService.silenceAutoStopDuration = storedDuration
        let storedThreshold = UserDefaults.standard.object(forKey: UserDefaultsKeys.silenceThreshold) as? Double ?? 0.015
        self.silenceThreshold = storedThreshold
        audioRecordingService.silenceThreshold = Float(storedThreshold)
        self.promptDisplayDuration = UserDefaults.standard.object(forKey: UserDefaultsKeys.promptDisplayDuration) as? Double ?? 8.0
        self.hybridHotkeyLabel = Self.loadHotkeyLabel(for: .hybrid)
        self.pttHotkeyLabel = Self.loadHotkeyLabel(for: .pushToTalk)
        self.toggleHotkeyLabel = Self.loadHotkeyLabel(for: .toggle)
        self.promptPaletteHotkeyLabel = Self.loadHotkeyLabel(for: .promptPalette)
        self.overlayPosition = UserDefaults.standard.string(forKey: UserDefaultsKeys.overlayPosition)
            .flatMap { OverlayPosition(rawValue: $0) } ?? .top
        self.notchIndicatorVisibility = UserDefaults.standard.string(forKey: UserDefaultsKeys.notchIndicatorVisibility)
            .flatMap { NotchIndicatorVisibility(rawValue: $0) } ?? .duringActivity
        self.notchIndicatorLeftContent = UserDefaults.standard.string(forKey: UserDefaultsKeys.notchIndicatorLeftContent)
            .flatMap { NotchIndicatorContent(rawValue: $0) } ?? .timer
        self.notchIndicatorRightContent = UserDefaults.standard.string(forKey: UserDefaultsKeys.notchIndicatorRightContent)
            .flatMap { NotchIndicatorContent(rawValue: $0) } ?? .waveform

        setupBindings()
    }

    var canDictate: Bool {
        if modelManager.activeEngine?.isModelLoaded == true {
            return true
        }
        // Cloud models don't use activeEngine - check if plugin is configured
        if let selectedId = modelManager.selectedModelId, CloudProvider.isCloudModel(selectedId) {
            let (providerId, _) = CloudProvider.parse(selectedId)
            return PluginManager.shared.transcriptionEngine(for: providerId)?.isConfigured ?? false
        }
        return false
    }

    var needsMicPermission: Bool {
        !audioRecordingService.hasMicrophonePermission
    }

    var needsAccessibilityPermission: Bool {
        !textInsertionService.isAccessibilityGranted
    }

    // MARK: - HTTP API

    var isRecording: Bool {
        state == .recording || state == .paused
    }

    func apiStartRecording() {
        startRecording()
    }

    func apiStopRecording() {
        stopDictation()
    }

    private func setupBindings() {
        hotkeyService.onDictationStart = { [weak self] in
            self?.startRecording()
        }

        hotkeyService.onDictationStop = { [weak self] in
            self?.stopDictation()
        }

        audioRecordingService.$audioLevel
            .dropFirst()
            .sink { [weak self] level in
                DispatchQueue.main.async {
                    self?.audioLevel = level
                }
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
                guard let self, self.state == .recording || self.state == .paused else { return }
                self.stopDictation()
                self.hotkeyService.cancelDictation()
                self.showError(String(localized: "Microphone disconnected. Falling back to system default."))
            }
            .store(in: &cancellables)
    }

    private func startRecording() {
        // Dismiss prompt palette if active
        promptPaletteController.hide()

        guard canDictate else {
            showError("No model loaded. Please download a model first.")
            return
        }

        guard audioRecordingService.hasMicrophonePermission else {
            showError("Microphone permission required.")
            return
        }

        // Cancel any pending transcription from a previous recording
        transcriptionTask?.cancel()
        transcriptionTask = nil
        insertingResetTask?.cancel()
        insertingResetTask = nil

        // Match profile based on active app — store for reuse in stopDictation
        let activeApp = textInsertionService.captureActiveApp()
        capturedActiveApp = activeApp
        matchedProfile = profileService.matchProfile(bundleIdentifier: activeApp.bundleId, url: nil)
        activeProfileName = matchedProfile?.name

        // Apply gain boost: profile override ?? global setting
        let effectiveWhisperMode = matchedProfile?.whisperModeOverride ?? whisperModeEnabled
        audioRecordingService.gainMultiplier = effectiveWhisperMode ? 4.0 : 1.0

        // Resolve browser URL asynchronously to avoid blocking the main thread.
        // If a more specific URL profile matches, update the active profile on the fly.
        if let bundleId = activeApp.bundleId {
            urlResolutionTask = Task { [weak self] in
                guard let self else { return }
                logger.info("URL resolution: starting for bundleId=\(bundleId)")
                let resolvedURL = await textInsertionService.resolveBrowserURL(bundleId: bundleId)
                logger.info("URL resolution: resolvedURL=\(resolvedURL ?? "nil"), state=\(String(describing: self.state))")
                guard state == .recording || state == .paused || state == .processing else {
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
                guard let refinedProfile = profileService.matchProfile(bundleIdentifier: bundleId, url: resolvedURL) else {
                    logger.info("URL resolution: no profile matched for URL \(resolvedURL)")
                    return
                }

                logger.info("URL resolution: matched profile '\(refinedProfile.name)'")
                matchedProfile = refinedProfile
                activeProfileName = refinedProfile.name
                let refinedWhisperMode = refinedProfile.whisperModeOverride ?? whisperModeEnabled
                audioRecordingService.gainMultiplier = refinedWhisperMode ? 4.0 : 1.0
            }
        }

        do {
            audioRecordingService.selectedDeviceID = audioDeviceService.selectedDeviceID
            try audioRecordingService.startRecording()
            if audioDuckingEnabled {
                audioDuckingService.duckAudio(to: Float(audioDuckingLevel))
            }
            if mediaPauseEnabled {
                mediaPlaybackService.pausePlayback()
            }
            state = .recording
            soundService.play(.recordingStarted, enabled: soundFeedbackEnabled)
            partialText = ""
            recordingStartTime = Date()
            startRecordingTimer()
            startStreamingIfSupported()
            startSilenceDetection()
            EventBus.shared.emit(.recordingStarted(RecordingStartedPayload(
                appName: capturedActiveApp?.name,
                bundleIdentifier: capturedActiveApp?.bundleId
            )))
        } catch {
            audioDuckingService.restoreAudio()
            mediaPlaybackService.resumePlayback()
            soundService.play(.error, enabled: soundFeedbackEnabled)
            showError(error.localizedDescription)
            hotkeyService.cancelDictation()
        }
    }

    private var effectiveLanguage: String? {
        if let profileLang = matchedProfile?.inputLanguage {
            return profileLang == "auto" ? nil : profileLang
        }
        return settingsViewModel.selectedLanguage
    }

    private var effectiveTask: TranscriptionTask {
        if let profileTask = matchedProfile?.selectedTask,
           let task = TranscriptionTask(rawValue: profileTask) {
            return task
        }
        return settingsViewModel.selectedTask
    }

    private var effectiveTranslationTarget: String? {
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
        if let globalId = settingsViewModel.defaultPromptActionId {
            return promptActionService.action(byId: globalId)
        }
        return nil
    }

    private func stopDictation() {
        guard state == .recording || state == .paused else { return }

        // Capture state before stopping - pause already trimmed via trimTrailingSilence()
        let wasPaused = (state == .paused)
        let trailingSilence = audioRecordingService.silenceDuration
        audioDuckingService.restoreAudio()
        mediaPlaybackService.resumePlayback()
        stopStreaming()
        stopSilenceDetection()
        stopRecordingTimer()
        var samples = audioRecordingService.stopRecording()

        // Only trim if we weren't paused (pause already trimmed via trimTrailingSilence)
        if !wasPaused && trailingSilence > 0.3 {
            let trimCount = Int(trailingSilence * AudioRecordingService.targetSampleRate)
            if samples.count > trimCount {
                samples = Array(samples.dropLast(trimCount))
            }
        }

        // Add silence padding so Whisper can properly finish decoding the last tokens
        let padCount = Int(0.3 * AudioRecordingService.targetSampleRate)
        samples.append(contentsOf: [Float](repeating: 0, count: padCount))

        let audioDurationForEvent = Double(samples.count) / 16000.0
        EventBus.shared.emit(.recordingStopped(RecordingStoppedPayload(
            durationSeconds: audioDurationForEvent
        )))

        guard !samples.isEmpty else {
            resetDictationState()
            return
        }

        let audioDuration = Double(samples.count) / 16000.0
        guard audioDuration >= 0.3 else {
            // Too short to transcribe meaningfully
            resetDictationState()
            return
        }

        state = .processing

        transcriptionTask = Task {
            do {
                // Wait for browser URL resolution so URL-based profile overrides apply
                await urlResolutionTask?.value

                let activeApp = capturedActiveApp ?? textInsertionService.captureActiveApp()
                let language = effectiveLanguage
                let task = effectiveTask
                let engineOverride = effectiveEngineOverrideId
                let cloudModelOverride = effectiveCloudModelOverride
                let translationTarget = effectiveTranslationTarget
                let termsPrompt = dictionaryService.getTermsForPrompt()

                let result = try await modelManager.transcribe(
                    audioSamples: samples,
                    language: language,
                    task: task,
                    engineOverrideId: engineOverride,
                    cloudModelOverride: cloudModelOverride,
                    prompt: termsPrompt
                )

                // Bail out if a new recording started while we were transcribing
                guard !Task.isCancelled else { return }

                var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    resetDictationState()
                    return
                }

                // Build LLM/translation handler for pipeline
                let llmHandler: ((String) async throws -> String)?
                if let promptAction = self.effectivePromptAction {
                    let pps = self.promptProcessingService
                    let providerOverride = promptAction.providerType
                    let modelOverride = promptAction.cloudModel
                    let prompt = promptAction.prompt
                    llmHandler = { text in
                        try await pps.process(
                            prompt: prompt, text: text,
                            providerOverride: providerOverride,
                            cloudModelOverride: modelOverride
                        )
                    }
                } else if let targetCode = translationTarget {
                    let ts = self.translationService
                    llmHandler = { text in
                        let target = Locale.Language(identifier: targetCode)
                        return try await ts.translate(text: text, to: target)
                    }
                } else {
                    llmHandler = nil
                }

                guard !Task.isCancelled else { return }

                // Post-processing pipeline (priority-based)
                let ppContext = PostProcessingContext(
                    appName: activeApp.name,
                    bundleIdentifier: activeApp.bundleId,
                    url: activeApp.url,
                    language: language
                )
                text = try await postProcessingPipeline.process(
                    text: text, context: ppContext, llmHandler: llmHandler
                )

                partialText = ""

                // Route to action plugin or insert text
                if let actionPluginId = self.effectivePromptAction?.targetActionPluginId,
                   let actionPlugin = PluginManager.shared.actionPlugin(for: actionPluginId) {
                    let actionContext = ActionContext(
                        appName: activeApp.name,
                        bundleIdentifier: activeApp.bundleId,
                        url: activeApp.url,
                        language: language,
                        originalText: result.text
                    )
                    let actionResult = try await actionPlugin.execute(input: text, context: actionContext)

                    if actionResult.success {
                        if let url = actionResult.url {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        }
                        self.actionFeedbackMessage = actionResult.message
                        self.actionFeedbackIcon = actionResult.icon ?? "checkmark.circle.fill"
                        self.actionDisplayDuration = actionResult.displayDuration ?? 3.5
                        EventBus.shared.emit(.actionCompleted(ActionCompletedPayload(
                            actionId: actionPluginId, success: true, message: actionResult.message,
                            url: actionResult.url, appName: activeApp.name, bundleIdentifier: activeApp.bundleId
                        )))
                    } else {
                        throw NSError(domain: "ActionPlugin", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: actionResult.message])
                    }
                } else {
                    // Default flow: always insert text (clipboard + Cmd+V)
                    _ = try await textInsertionService.insertText(text)
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

                historyService.addRecord(
                    rawText: result.text,
                    finalText: text,
                    appName: activeApp.name,
                    appBundleIdentifier: activeApp.bundleId,
                    appURL: activeApp.url,
                    durationSeconds: audioDuration,
                    language: language,
                    engineUsed: result.engineUsed,
                    modelUsed: modelDisplayName
                )

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
                    profileName: self.matchedProfile?.name
                )))

                soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)

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
                soundService.play(.error, enabled: soundFeedbackEnabled)
                showError(error.localizedDescription)
                matchedProfile = nil
                capturedActiveApp = nil
                activeProfileName = nil
            }
        }
    }

    func requestMicPermission() {
        Task {
            _ = await audioRecordingService.requestMicrophonePermission()
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
            pollPermissionStatus()
        }
    }

    func requestAccessibilityPermission() {
        textInsertionService.requestAccessibilityPermission()
        pollPermissionStatus()
    }

    func setHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) {
        let label = HotkeyService.displayName(for: hotkey)
        switch slot {
        case .hybrid: hybridHotkeyLabel = label
        case .pushToTalk: pttHotkeyLabel = label
        case .toggle: toggleHotkeyLabel = label
        case .promptPalette: promptPaletteHotkeyLabel = label
        }
        hotkeyService.updateHotkey(hotkey, for: slot)
    }

    func clearHotkey(for slot: HotkeySlotType) {
        switch slot {
        case .hybrid: hybridHotkeyLabel = ""
        case .pushToTalk: pttHotkeyLabel = ""
        case .toggle: toggleHotkeyLabel = ""
        case .promptPalette: promptPaletteHotkeyLabel = ""
        }
        hotkeyService.clearHotkey(for: slot)
    }

    func isHotkeyAssigned(_ hotkey: UnifiedHotkey, excluding: HotkeySlotType) -> HotkeySlotType? {
        hotkeyService.isHotkeyAssigned(hotkey, excluding: excluding)
    }

    private static func loadHotkeyLabel(for slotType: HotkeySlotType) -> String {
        if let data = UserDefaults.standard.data(forKey: slotType.defaultsKey),
           let hotkey = try? JSONDecoder().decode(UnifiedHotkey.self, from: data) {
            return HotkeyService.displayName(for: hotkey)
        }
        return ""
    }

    private var permissionPollTask: Task<Void, Never>?

    /// Polls permission status periodically until granted or timeout.
    private func pollPermissionStatus() {
        permissionPollTask?.cancel()
        permissionPollTask = Task {
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.objectWillChange.send()
                }
                if !needsMicPermission, !needsAccessibilityPermission { return }
            }
        }
    }

    private func resetDictationState() {
        errorResetTask?.cancel()
        insertingResetTask?.cancel()
        insertingResetTask = nil
        urlResolutionTask?.cancel()
        urlResolutionTask = nil
        state = .idle
        partialText = ""
        matchedProfile = nil
        capturedActiveApp = nil
        activeProfileName = nil
        actionFeedbackMessage = nil
        actionFeedbackIcon = nil
        actionDisplayDuration = 3.5
    }

    // MARK: - Standalone Prompt Palette

    private let promptPaletteController = PromptPaletteController()

    private struct PaletteContext {
        let text: String
        let selection: TextInsertionService.TextSelection?
        let focusedElement: AXUIElement?
        let activeApp: (name: String?, bundleId: String?, url: String?)
        let browserInfoTask: Task<(url: String?, title: String?), Never>?
    }
    private var paletteContext: PaletteContext?

    func triggerStandalonePromptSelection() {
        // Toggle behavior
        if promptPaletteController.isVisible {
            promptPaletteController.hide()
            return
        }
        guard state == .idle else { return }

        guard promptProcessingService.isCurrentProviderReady else {
            soundService.play(.error, enabled: soundFeedbackEnabled)
            showError(String(localized: "noLLMProvider"))
            return
        }

        let actions = promptActionService.getEnabledActions()
        guard !actions.isEmpty else { return }

        // Capture active app BEFORE the palette steals focus
        let activeApp = textInsertionService.captureActiveApp()

        // Start resolving browser URL + title asynchronously
        var browserInfoTask: Task<(url: String?, title: String?), Never>?
        if let bundleId = activeApp.bundleId {
            let tis = textInsertionService
            browserInfoTask = Task {
                await tis.resolveBrowserInfo(bundleId: bundleId)
            }
        }

        // Try to get selected text (with element reference), fall back to clipboard
        let text: String
        var selection: TextInsertionService.TextSelection?
        var focusedElement: AXUIElement?
        if let sel = textInsertionService.getTextSelection() {
            text = sel.text
            selection = sel
            logger.info("[PromptPalette] Got selected text: \(text.prefix(80))")
        } else if let clipboard = NSPasteboard.general.string(forType: .string), !clipboard.isEmpty {
            text = clipboard
            focusedElement = textInsertionService.getFocusedTextElement()
            logger.info("[PromptPalette] No selection, using clipboard: \(text.prefix(80))")
        } else {
            logger.info("[PromptPalette] No text available, aborting")
            return
        }

        paletteContext = PaletteContext(
            text: text,
            selection: selection,
            focusedElement: focusedElement,
            activeApp: activeApp,
            browserInfoTask: browserInfoTask
        )

        promptPaletteController.show(actions: actions, sourceText: text) { [weak self] action in
            self?.processStandalonePrompt(action: action)
        }
    }

    private func processStandalonePrompt(action: PromptAction) {
        guard let ctx = paletteContext else { return }
        paletteContext = nil

        showNotchFeedback(message: action.name + "...", icon: "ellipsis.circle", duration: 30)

        Task {
            do {
                let result = try await promptProcessingService.process(
                    prompt: action.prompt,
                    text: ctx.text,
                    providerOverride: action.providerType,
                    cloudModelOverride: action.cloudModel
                )
                guard !Task.isCancelled else { return }

                // Route to action plugin if configured
                if let actionPluginId = action.targetActionPluginId,
                   let actionPlugin = PluginManager.shared.actionPlugin(for: actionPluginId) {
                    let browserInfo = await ctx.browserInfoTask?.value
                    let resolvedUrl = browserInfo?.url ?? ctx.activeApp.url
                    let actionContext = ActionContext(
                        appName: browserInfo?.title ?? ctx.activeApp.name,
                        bundleIdentifier: ctx.activeApp.bundleId,
                        url: resolvedUrl,
                        originalText: ctx.text
                    )
                    let actionResult = try await actionPlugin.execute(input: result, context: actionContext)
                    if actionResult.success {
                        if let url = actionResult.url {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        }
                        soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                        showNotchFeedback(
                            message: actionResult.message,
                            icon: actionResult.icon ?? "checkmark.circle.fill",
                            duration: actionResult.displayDuration ?? 4
                        )
                    } else {
                        throw NSError(domain: "ActionPlugin", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: actionResult.message])
                    }
                    return
                }

                if let selection = ctx.selection {
                    logger.info("[PromptPalette] Replacing selection with result (\(result.count) chars): \(result.prefix(80))")
                    let replaced = textInsertionService.replaceSelectedText(in: selection, with: result)
                    logger.info("[PromptPalette] replaceSelectedText succeeded: \(replaced)")
                    if !replaced {
                        logger.info("[PromptPalette] Falling back to clipboard")
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(result, forType: .string)
                    }
                    soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                    showNotchFeedback(
                        message: replaced ? String(localized: "Text replaced") : String(localized: "Copied to clipboard"),
                        icon: replaced ? "checkmark.circle.fill" : "doc.on.clipboard.fill"
                    )
                } else if let element = ctx.focusedElement {
                    let inserted = textInsertionService.insertTextAt(element: element, text: result)
                    if inserted {
                        soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                        showNotchFeedback(message: String(localized: "Text inserted"), icon: "checkmark.circle.fill")
                    } else {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(result, forType: .string)
                        soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                        showNotchFeedback(message: String(localized: "Copied to clipboard"), icon: "doc.on.clipboard.fill")
                    }
                } else {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(result, forType: .string)
                    soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                    showNotchFeedback(message: String(localized: "Copied to clipboard"), icon: "doc.on.clipboard.fill")
                }
            } catch {
                guard !Task.isCancelled else { return }
                soundService.play(.error, enabled: soundFeedbackEnabled)
                showNotchFeedback(message: error.localizedDescription, icon: "xmark.circle.fill", isError: true)
            }
        }
    }

    private func showNotchFeedback(message: String, icon: String, duration: TimeInterval = 2.5, isError: Bool = false) {
        actionFeedbackMessage = message
        actionFeedbackIcon = icon
        actionDisplayDuration = duration
        state = isError ? .error(message) : .inserting
        insertingResetTask?.cancel()
        insertingResetTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            resetDictationState()
        }
    }

    private func showError(_ message: String) {
        state = .error(message)
        errorResetTask?.cancel()
        errorResetTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if case .error = state {
                state = .idle
            }
        }
    }

    // MARK: - Streaming

    /// Text confirmed from previous streaming passes — never changes once set.
    private var confirmedStreamingText = ""

    private func startStreamingIfSupported() {
        // Plugin engines don't support streaming
        if let overrideId = effectiveEngineOverrideId, modelManager.isPluginEngine(overrideId) {
            return
        }
        let resolvedEngine = modelManager.resolveEngine(override: effectiveEngineOverrideId, cloudModelOverride: effectiveCloudModelOverride)
        guard let engine = resolvedEngine, engine.supportsStreaming else { return }

        isStreaming = true
        confirmedStreamingText = ""
        let streamLanguage = effectiveLanguage
        let streamTask = effectiveTask
        let streamEngineOverride = effectiveEngineOverrideId
        let streamCloudModelOverride = effectiveCloudModelOverride
        let streamPrompt = dictionaryService.getTermsForPrompt()
        streamingTask = Task { [weak self] in
            guard let self else { return }
            // Initial delay before first streaming attempt
            try? await Task.sleep(for: .seconds(1.5))

            while !Task.isCancelled, self.state == .recording || self.state == .paused {
                let buffer = self.audioRecordingService.getRecentBuffer(maxDuration: 3600)
                let bufferDuration = Double(buffer.count) / 16000.0

                if bufferDuration > 0.5 {
                    do {
                        let confirmed = self.confirmedStreamingText
                        let result = try await self.modelManager.transcribe(
                            audioSamples: buffer,
                            language: streamLanguage,
                            task: streamTask,
                            engineOverrideId: streamEngineOverride,
                            cloudModelOverride: streamCloudModelOverride,
                            prompt: streamPrompt,
                            onProgress: { [weak self] text in
                                guard let self, !Task.isCancelled else { return false }
                                let stable = Self.stabilizeText(confirmed: confirmed, new: text)
                                DispatchQueue.main.async {
                                    if self.partialText != stable {
                                        self.partialText = stable
                                    }
                                }
                                return true
                            }
                        )
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            let stable = Self.stabilizeText(confirmed: confirmed, new: text)
                            if self.partialText != stable {
                                self.partialText = stable
                            }
                            self.confirmedStreamingText = stable
                        }
                    } catch {
                        // Streaming errors are non-fatal; final transcription will still run
                    }
                }

                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func stopStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        isStreaming = false
        confirmedStreamingText = ""
    }

    /// Keeps confirmed text stable and only appends new content.
    nonisolated private static func stabilizeText(confirmed: String, new: String) -> String {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmed.isEmpty else { return new }
        guard !new.isEmpty else { return confirmed }

        // Best case: new text starts with confirmed text
        if new.hasPrefix(confirmed) { return new }

        // Find how far the texts match from the start
        let confirmedChars = Array(confirmed.unicodeScalars)
        let newChars = Array(new.unicodeScalars)
        var matchEnd = 0
        for i in 0..<min(confirmedChars.count, newChars.count) {
            if confirmedChars[i] == newChars[i] {
                matchEnd = i + 1
            } else {
                break
            }
        }

        // If more than half matches, keep confirmed and append the new tail
        if matchEnd > confirmed.count / 2 {
            let newContent = String(new.unicodeScalars.dropFirst(matchEnd))
            return confirmed + newContent
        }

        // Suffix-prefix overlap: new text starts with a suffix of confirmed
        // (happens when the streaming window has shifted forward)
        let minOverlap = min(20, confirmedChars.count / 4)
        let maxShift = min(confirmedChars.count - minOverlap, 150)
        if maxShift > 0 {
            for dropCount in 1...maxShift {
                let suffix = String(confirmed.unicodeScalars.dropFirst(dropCount))
                if new.hasPrefix(suffix) {
                    let newTail = String(new.unicodeScalars.dropFirst(confirmed.unicodeScalars.count - dropCount))
                    return newTail.isEmpty ? confirmed : confirmed + newTail
                }
            }
        }

        // Very different result — accept the new text to avoid freezing the preview
        return new
    }

    // MARK: - Silence Detection

    private func startSilenceDetection() {
        stopSilenceDetection()

        logger.info("startSilenceDetection: starting timer, hotkeyMode=\(String(describing: self.hotkeyMode))")
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.checkSilenceState()
            }
        }
    }

    private func checkSilenceState() {
        // Only auto-stop in toggle mode, not push-to-talk
        // Read directly from hotkeyService — self.hotkeyMode may lag behind due to Combine async dispatch
        guard hotkeyService.currentMode == .toggle else { return }

        let duration = audioRecordingService.silenceDuration
        let threshold = audioRecordingService.silenceAutoStopDuration

        if state == .recording {
            if duration >= threshold {
                logger.info("Silence detected: \(duration)s >= \(threshold)s, pauseEnabled=\(self.silencePauseEnabled)")
                if silencePauseEnabled {
                    audioRecordingService.pauseRecording()
                    state = .paused
                } else {
                    audioRecordingService.didAutoStop = true
                    stopDictation()
                    hotkeyService.cancelDictation()
                }
            }
        } else if state == .paused {
            if !audioRecordingService.isSilent {
                logger.info("Speech resumed - unpausing")
                audioRecordingService.resumeRecording()
                state = .recording
            }
        }
    }

    private func stopSilenceDetection() {
        silenceTimer?.invalidate()
        silenceTimer = nil
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
