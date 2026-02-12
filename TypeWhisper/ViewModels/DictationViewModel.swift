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

    private let audioRecordingService: AudioRecordingService
    private let textInsertionService: TextInsertionService
    private let hotkeyService: HotkeyService
    private let modelManager: ModelManagerService
    private let settingsViewModel: SettingsViewModel

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
        settingsViewModel: SettingsViewModel
    ) {
        self.audioRecordingService = audioRecordingService
        self.textInsertionService = textInsertionService
        self.hotkeyService = hotkeyService
        self.modelManager = modelManager
        self.settingsViewModel = settingsViewModel
        self.whisperModeEnabled = UserDefaults.standard.bool(forKey: "whisperModeEnabled")

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

        // Apply gain boost for whisper mode
        audioRecordingService.gainMultiplier = whisperModeEnabled ? 4.0 : 1.0

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

    private func stopDictation() {
        guard state == .recording else { return }

        stopStreaming()
        stopSilenceDetection()
        stopRecordingTimer()
        let samples = audioRecordingService.stopRecording()

        guard !samples.isEmpty else {
            state = .idle
            partialText = ""
            return
        }

        let audioDuration = Double(samples.count) / 16000.0
        guard audioDuration >= 0.3 else {
            // Too short to transcribe meaningfully
            state = .idle
            partialText = ""
            return
        }

        state = .processing

        Task {
            do {
                let result = try await modelManager.transcribe(
                    audioSamples: samples,
                    language: settingsViewModel.selectedLanguage,
                    task: settingsViewModel.selectedTask
                )

                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    state = .idle
                    partialText = ""
                    return
                }

                partialText = ""
                state = .inserting
                try await textInsertionService.insertText(text)
                state = .idle
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func requestMicPermission() {
        Task {
            _ = await audioRecordingService.requestMicrophonePermission()
        }
    }

    func requestAccessibilityPermission() {
        textInsertionService.requestAccessibilityPermission()
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

    private func startStreamingIfSupported() {
        guard let engine = modelManager.activeEngine, engine.supportsStreaming else { return }

        isStreaming = true
        streamingTask = Task { [weak self] in
            guard let self else { return }
            // Initial delay before first streaming attempt
            try? await Task.sleep(for: .seconds(1.5))

            while !Task.isCancelled, self.state == .recording {
                let buffer = self.audioRecordingService.getCurrentBuffer()
                let bufferDuration = Double(buffer.count) / 16000.0

                if bufferDuration > 0.5 {
                    do {
                        let result = try await self.modelManager.transcribe(
                            audioSamples: buffer,
                            language: self.settingsViewModel.selectedLanguage,
                            task: self.settingsViewModel.selectedTask,
                            onProgress: { [weak self] text in
                                guard let self, self.state == .recording else { return false }
                                DispatchQueue.main.async {
                                    self.partialText = text
                                }
                                return true
                            }
                        )
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            self.partialText = text
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
