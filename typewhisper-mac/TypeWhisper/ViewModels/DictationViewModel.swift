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

    private let audioRecordingService: AudioRecordingService
    private let textInsertionService: TextInsertionService
    private let hotkeyService: HotkeyService
    private let modelManager: ModelManagerService
    private let settingsViewModel: SettingsViewModel

    private var cancellables = Set<AnyCancellable>()
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?

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

        do {
            try audioRecordingService.startRecording()
            state = .recording
            recordingStartTime = Date()
            startRecordingTimer()
        } catch {
            showError(error.localizedDescription)
            hotkeyService.cancelDictation()
        }
    }

    private func stopDictation() {
        guard state == .recording else { return }

        stopRecordingTimer()
        let samples = audioRecordingService.stopRecording()

        guard !samples.isEmpty else {
            state = .idle
            return
        }

        let audioDuration = Double(samples.count) / 16000.0
        guard audioDuration >= 0.3 else {
            // Too short to transcribe meaningfully
            state = .idle
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
                    return
                }

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
