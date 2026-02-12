import Foundation
import Combine

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
        case error(String)
    }

    @Published var state: State = .idle
    @Published var audioLevel: Float = 0
    @Published var recordingDuration: TimeInterval = 0
    @Published var hotkeyMode: HotkeyService.HotkeyMode?
    @Published var partialText: String = ""
    @Published var isStreaming: Bool = false
    @Published var whisperModeEnabled: Bool {
        didSet { UserDefaults.standard.set(whisperModeEnabled, forKey: "whisperModeEnabled") }
    }
    @Published var activeProfileName: String?

    enum OverlayPosition: String, CaseIterable {
        case top
        case bottom
    }

    @Published var overlayPosition: OverlayPosition {
        didSet { UserDefaults.standard.set(overlayPosition.rawValue, forKey: "overlayPosition") }
    }

    private let audioRecordingService: AudioRecordingService
    private let textInsertionService: TextInsertionService
    private let hotkeyService: HotkeyService
    private let modelManager: ModelManagerService
    private let settingsViewModel: SettingsViewModel
    private let historyService: HistoryService
    private let profileService: ProfileService
    private var matchedProfile: Profile?

    private var cancellables = Set<AnyCancellable>()
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var streamingTask: Task<Void, Never>?
    private var silenceCancellable: AnyCancellable?

    init(
        audioRecordingService: AudioRecordingService,
        textInsertionService: TextInsertionService,
        hotkeyService: HotkeyService,
        modelManager: ModelManagerService,
        settingsViewModel: SettingsViewModel,
        historyService: HistoryService,
        profileService: ProfileService
    ) {
        self.audioRecordingService = audioRecordingService
        self.textInsertionService = textInsertionService
        self.hotkeyService = hotkeyService
        self.modelManager = modelManager
        self.settingsViewModel = settingsViewModel
        self.historyService = historyService
        self.profileService = profileService
        self.whisperModeEnabled = UserDefaults.standard.bool(forKey: "whisperModeEnabled")
        self.overlayPosition = UserDefaults.standard.string(forKey: "overlayPosition")
            .flatMap { OverlayPosition(rawValue: $0) } ?? .top

        setupBindings()
    }

    var canDictate: Bool {
        modelManager.activeEngine?.isModelLoaded == true
    }

    var needsMicPermission: Bool {
        !audioRecordingService.hasMicrophonePermission
    }

    var needsAccessibilityPermission: Bool {
        !textInsertionService.isAccessibilityGranted
    }

    private func setupBindings() {
        hotkeyService.onDictationStart = { [weak self] in
            self?.startRecording()
        }

        hotkeyService.onDictationStop = { [weak self] in
            self?.stopDictation()
        }

        audioRecordingService.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)

        hotkeyService.$currentMode
            .receive(on: DispatchQueue.main)
            .assign(to: &$hotkeyMode)
    }

    private func startRecording() {
        guard canDictate else {
            showError("No model loaded. Please download a model first.")
            return
        }

        guard audioRecordingService.hasMicrophonePermission else {
            showError("Microphone permission required.")
            return
        }

        // Match profile based on active app
        let activeApp = textInsertionService.captureActiveApp()
        matchedProfile = profileService.matchProfile(bundleIdentifier: activeApp.bundleId)
        activeProfileName = matchedProfile?.name

        // Apply gain boost: profile override ?? global setting
        let effectiveWhisperMode = matchedProfile?.whisperModeOverride ?? whisperModeEnabled
        audioRecordingService.gainMultiplier = effectiveWhisperMode ? 4.0 : 1.0

        do {
            try audioRecordingService.startRecording()
            state = .recording
            partialText = ""
            recordingStartTime = Date()
            startRecordingTimer()
            startStreamingIfSupported()
            startSilenceDetection()
        } catch {
            showError(error.localizedDescription)
            hotkeyService.cancelDictation()
        }
    }

    private var effectiveLanguage: String? {
        if let profileLang = matchedProfile?.outputLanguage {
            return profileLang
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

    private func stopDictation() {
        guard state == .recording else { return }

        stopStreaming()
        stopSilenceDetection()
        stopRecordingTimer()
        let samples = audioRecordingService.stopRecording()

        guard !samples.isEmpty else {
            state = .idle
            partialText = ""
            matchedProfile = nil
            activeProfileName = nil
            return
        }

        let audioDuration = Double(samples.count) / 16000.0
        guard audioDuration >= 0.3 else {
            // Too short to transcribe meaningfully
            state = .idle
            partialText = ""
            matchedProfile = nil
            activeProfileName = nil
            return
        }

        // Use the active app captured at recording start (via profile matching)
        let activeApp = textInsertionService.captureActiveApp()
        let language = effectiveLanguage
        let task = effectiveTask

        state = .processing

        Task {
            do {
                let result = try await modelManager.transcribe(
                    audioSamples: samples,
                    language: language,
                    task: task
                )

                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    state = .idle
                    partialText = ""
                    matchedProfile = nil
                    activeProfileName = nil
                    return
                }

                partialText = ""
                state = .inserting
                try await textInsertionService.insertText(text)

                historyService.addRecord(
                    rawText: text,
                    finalText: text,
                    appName: activeApp.name,
                    appBundleIdentifier: activeApp.bundleId,
                    durationSeconds: audioDuration,
                    language: language,
                    engineUsed: result.engineUsed.rawValue
                )

                state = .idle
                matchedProfile = nil
                activeProfileName = nil
            } catch {
                showError(error.localizedDescription)
                matchedProfile = nil
                activeProfileName = nil
            }
        }
    }

    func requestMicPermission() {
        Task {
            _ = await audioRecordingService.requestMicrophonePermission()
            objectWillChange.send()
        }
    }

    func requestAccessibilityPermission() {
        textInsertionService.requestAccessibilityPermission()
        pollPermissionStatus()
    }

    private var permissionPollTask: Task<Void, Never>?

    /// Polls permission status periodically until granted or timeout.
    private func pollPermissionStatus() {
        permissionPollTask?.cancel()
        permissionPollTask = Task {
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                objectWillChange.send()
                if !needsMicPermission, !needsAccessibilityPermission { return }
            }
        }
    }

    private func showError(_ message: String) {
        state = .error(message)
        Task {
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
        guard let engine = modelManager.activeEngine, engine.supportsStreaming else { return }

        isStreaming = true
        confirmedStreamingText = ""
        let streamLanguage = effectiveLanguage
        let streamTask = effectiveTask
        streamingTask = Task { [weak self] in
            guard let self else { return }
            // Initial delay before first streaming attempt
            try? await Task.sleep(for: .seconds(1.5))

            while !Task.isCancelled, self.state == .recording {
                let buffer = self.audioRecordingService.getCurrentBuffer()
                let bufferDuration = Double(buffer.count) / 16000.0

                if bufferDuration > 0.5 {
                    do {
                        let confirmed = self.confirmedStreamingText
                        let result = try await self.modelManager.transcribe(
                            audioSamples: buffer,
                            language: streamLanguage,
                            task: streamTask,
                            onProgress: { [weak self] text in
                                guard let self, self.state == .recording else { return false }
                                let stable = Self.stabilizeText(confirmed: confirmed, new: text)
                                DispatchQueue.main.async {
                                    self.partialText = stable
                                }
                                return true
                            }
                        )
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            let stable = Self.stabilizeText(confirmed: confirmed, new: text)
                            self.partialText = stable
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
    private static func stabilizeText(confirmed: String, new: String) -> String {
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

        // Very different result — keep confirmed, ignore this pass
        return confirmed
    }

    // MARK: - Silence Detection

    private func startSilenceDetection() {
        // Only auto-stop in toggle mode, not push-to-talk
        guard hotkeyMode == .toggle else { return }

        silenceCancellable = audioRecordingService.$silenceDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                guard let self, self.state == .recording else { return }
                if duration >= self.audioRecordingService.silenceAutoStopDuration {
                    self.audioRecordingService.didAutoStop = true
                    self.stopDictation()
                    self.hotkeyService.cancelDictation()
                }
            }
    }

    private func stopSilenceDetection() {
        silenceCancellable?.cancel()
        silenceCancellable = nil
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
