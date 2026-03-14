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
    @Published var audioDuckingEnabled: Bool {
        didSet { UserDefaults.standard.set(audioDuckingEnabled, forKey: UserDefaultsKeys.audioDuckingEnabled) }
    }
    @Published var audioDuckingLevel: Double {
        didSet { UserDefaults.standard.set(audioDuckingLevel, forKey: UserDefaultsKeys.audioDuckingLevel) }
    }
    @Published var soundFeedbackEnabled: Bool {
        didSet { UserDefaults.standard.set(soundFeedbackEnabled, forKey: UserDefaultsKeys.soundFeedbackEnabled) }
    }
    @Published var hotkeyLabelsVersion = 0
    var hybridHotkeyLabel: String { Self.loadHotkeyLabel(for: .hybrid) }
    var pttHotkeyLabel: String { Self.loadHotkeyLabel(for: .pushToTalk) }
    var toggleHotkeyLabel: String { Self.loadHotkeyLabel(for: .toggle) }
    var promptPaletteHotkeyLabel: String { Self.loadHotkeyLabel(for: .promptPalette) }
    @Published var activeProfileName: String?
    @Published var actionFeedbackMessage: String?
    @Published var actionFeedbackIcon: String?
    @Published var activeAppIcon: NSImage?
    private var actionDisplayDuration: TimeInterval = 3.5

    @Published var indicatorStyle: IndicatorStyle {
        didSet { UserDefaults.standard.set(indicatorStyle.rawValue, forKey: UserDefaultsKeys.indicatorStyle) }
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
    private let postProcessingPipeline: PostProcessingPipeline
    private var matchedProfile: Profile?
    private var forcedProfileId: UUID?
    private var capturedActiveApp: (name: String?, bundleId: String?, url: String?)?

    private var cancellables = Set<AnyCancellable>()
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private let streamingHandler: StreamingHandler
    private let promptPaletteHandler: PromptPaletteHandler
    private let settingsHandler: DictationSettingsHandler
    private var transcriptionTask: Task<Void, Never>?
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
        translationService: AnyObject?,
        audioDuckingService: AudioDuckingService,
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
        self.streamingHandler = StreamingHandler(
            modelManager: modelManager,
            audioRecordingService: audioRecordingService,
            dictionaryService: dictionaryService
        )
        self.promptPaletteHandler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            soundService: soundService
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
        self.indicatorStyle = UserDefaults.standard.string(forKey: UserDefaultsKeys.indicatorStyle)
            .flatMap { IndicatorStyle(rawValue: $0) } ?? .notch
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
            }
        }
        streamingHandler.onStreamingStateChange = { [weak self] streaming in
            self?.isStreaming = streaming
        }

        promptPaletteHandler.onShowNotchFeedback = { [weak self] message, icon, duration, isError in
            self?.showNotchFeedback(message: message, icon: icon, duration: duration, isError: isError)
        }
        promptPaletteHandler.onShowError = { [weak self] message in
            self?.showError(message)
        }
        promptPaletteHandler.executeActionPlugin = { [weak self] plugin, pluginId, text, activeApp, originalText, language in
            try await self?.executeActionPlugin(plugin, pluginId: pluginId, text: text, activeApp: activeApp, language: language, originalText: originalText)
        }
        promptPaletteHandler.getActionFeedback = { [weak self] in
            (self?.actionFeedbackMessage, self?.actionFeedbackIcon, self?.actionDisplayDuration ?? 3.5)
        }

        settingsHandler.onObjectWillChange = { [weak self] in
            self?.objectWillChange.send()
        }
        settingsHandler.onHotkeyLabelsChanged = { [weak self] in
            self?.hotkeyLabelsVersion += 1
        }
    }

    var canDictate: Bool {
        modelManager.canTranscribe
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

    func apiStartRecording() {
        startRecording()
    }

    func apiStopRecording() {
        stopDictation()
    }

    deinit {
        MainActor.assumeIsolated {
            recordingTimer?.invalidate()
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
            self?.cancelCurrentOperation()
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
                guard let self, self.state == .recording else { return }
                self.audioDuckingService.restoreAudio()
                self.streamingHandler.stop()
                self.stopRecordingTimer()
                _ = self.audioRecordingService.stopRecording()
                self.hotkeyService.cancelDictation()
                self.showNotchFeedback(
                    message: String(localized: "Microphone disconnected"),
                    icon: "mic.slash",
                    duration: 3.0,
                    isError: true
                )
            }
            .store(in: &cancellables)
    }

    private func cancelCurrentOperation() {
        switch state {
        case .recording:
            audioDuckingService.restoreAudio()
            streamingHandler.stop()
            stopRecordingTimer()
            _ = audioRecordingService.stopRecording()
            hotkeyService.cancelDictation()
            showNotchFeedback(message: String(localized: "Cancelled"), icon: "xmark.circle", duration: 1.5)
        case .processing:
            transcriptionTask?.cancel()
            transcriptionTask = nil
            showNotchFeedback(message: String(localized: "Cancelled"), icon: "xmark.circle", duration: 1.5)
        default:
            break
        }
    }

    private func startRecording(forcedProfileId: UUID? = nil) {
        // Dismiss prompt palette if active
        promptPaletteHandler.hide()

        // Cancel auto-unload timer to prevent unloading during recording
        modelManager.cancelAutoUnloadTimer()

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

        self.forcedProfileId = forcedProfileId

        // Match profile: forced profile or app-based matching
        let activeApp = textInsertionService.captureActiveApp()
        capturedActiveApp = activeApp
        if let bundleId = activeApp.bundleId,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            activeAppIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            activeAppIcon = nil
        }

        if let forcedProfileId,
           let forcedProfile = profileService.profiles.first(where: { $0.id == forcedProfileId && $0.isEnabled }) {
            matchedProfile = forcedProfile
            activeProfileName = forcedProfile.name
        } else {
            matchedProfile = profileService.matchProfile(bundleIdentifier: activeApp.bundleId, url: nil)
            activeProfileName = matchedProfile?.name
        }

        // Resolve browser URL asynchronously to avoid blocking the main thread.
        // If a more specific URL profile matches, update the active profile on the fly.
        // Skip URL resolution when a forced profile is set (profile hotkey overrides app matching).
        if forcedProfileId == nil, let bundleId = activeApp.bundleId {
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
                guard let refinedProfile = profileService.matchProfile(bundleIdentifier: bundleId, url: resolvedURL) else {
                    logger.info("URL resolution: no profile matched for URL \(resolvedURL)")
                    return
                }

                logger.info("URL resolution: matched profile '\(refinedProfile.name)'")
                matchedProfile = refinedProfile
                activeProfileName = refinedProfile.name
            }
        }

        do {
            audioRecordingService.selectedDeviceID = audioDeviceService.selectedDeviceID
            try audioRecordingService.startRecording()
            if audioDuckingEnabled {
                audioDuckingService.duckAudio(to: Float(audioDuckingLevel))
            }
            state = .recording
            // Reset hotkey timer so hybrid threshold counts from recording start,
            // not from key press. Slow device init (e.g. iPhone Continuity ~2-3s)
            // would otherwise make the hold appear as "long press" → PTT stop.
            hotkeyService.resetKeyDownTime()
            soundService.play(.recordingStarted, enabled: soundFeedbackEnabled)
            partialText = ""
            recordingStartTime = Date()
            startRecordingTimer()
            streamingHandler.start(
                engineOverrideId: effectiveEngineOverrideId,
                selectedProviderId: modelManager.selectedProviderId,
                language: effectiveLanguage,
                task: effectiveTask,
                cloudModelOverride: effectiveCloudModelOverride,
                stateCheck: { @MainActor [weak self] in self?.state ?? .idle }
            )
            EventBus.shared.emit(.recordingStarted(RecordingStartedPayload(
                appName: capturedActiveApp?.name,
                bundleIdentifier: capturedActiveApp?.bundleId
            )))
        } catch {
            audioDuckingService.restoreAudio()
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
        return nil
    }

    private func stopDictation() {
        guard state == .recording else { return }

        audioDuckingService.restoreAudio()
        streamingHandler.stop()
        stopRecordingTimer()
        var samples = audioRecordingService.stopRecording()

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

        let peakLevel = audioRecordingService.peakRawAudioLevel
        guard peakLevel >= 0.01 else {
            showNotchFeedback(
                message: String(localized: "No speech detected"),
                icon: "mic.slash",
                duration: 2.0
            )
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

                let llmHandler = buildLLMHandler(
                    translationTarget: translationTarget,
                    detectedLanguage: result.detectedLanguage,
                    configuredLanguage: language
                )

                guard !Task.isCancelled else { return }

                // Post-processing pipeline (priority-based)
                let ppContext = PostProcessingContext(
                    appName: activeApp.name,
                    bundleIdentifier: activeApp.bundleId,
                    url: activeApp.url,
                    language: language,
                    profileName: self.matchedProfile?.name
                )
                text = try await postProcessingPipeline.process(
                    text: text, context: ppContext, llmHandler: llmHandler
                )

                partialText = ""

                // Route to action plugin or insert text
                if let actionPluginId = self.effectivePromptAction?.targetActionPluginId,
                   let actionPlugin = PluginManager.shared.actionPlugin(for: actionPluginId) {
                    try await executeActionPlugin(
                        actionPlugin, pluginId: actionPluginId, text: text,
                        activeApp: activeApp, language: language, originalText: result.text
                    )
                } else {
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
                forcedProfileId = nil
                capturedActiveApp = nil
                activeAppIcon = nil
                activeProfileName = nil
            }
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
        state = .idle
        partialText = ""
        matchedProfile = nil
        forcedProfileId = nil
        capturedActiveApp = nil
        activeAppIcon = nil
        activeProfileName = nil
        actionFeedbackMessage = nil
        actionFeedbackIcon = nil
        actionDisplayDuration = 3.5
    }

    // MARK: - Shared Helpers

    /// Builds an LLM handler for the post-processing pipeline.
    /// Priority: prompt action > translation > nil.
    private func buildLLMHandler(
        translationTarget: String?,
        detectedLanguage: String?,
        configuredLanguage: String?
    ) -> ((String) async throws -> String)? {
        if let promptAction = effectivePromptAction {
            let pps = promptProcessingService
            let providerOverride = promptAction.providerType
            let modelOverride = promptAction.cloudModel
            let prompt = promptAction.prompt
            return { text in
                try await pps.process(
                    prompt: prompt, text: text,
                    providerOverride: providerOverride,
                    cloudModelOverride: modelOverride
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

    func triggerStandalonePromptSelection() {
        promptPaletteHandler.triggerSelection(currentState: state, soundFeedbackEnabled: soundFeedbackEnabled)
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
