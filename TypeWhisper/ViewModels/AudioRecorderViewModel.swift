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

    enum RecorderState {
        case idle, recording, finalizing
    }

    private struct FinalTranscriptionRequest {
        let outputURL: URL
        let buffer: [Float]
        let language: String?
        let task: TranscriptionTask
        let providerId: String?
        let modelId: String?
        let prompt: String?
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
        didSet { UserDefaults.standard.set(micEnabled, forKey: UserDefaultsKeys.recorderMicEnabled) }
    }
    @Published var systemAudioEnabled: Bool {
        didSet { UserDefaults.standard.set(systemAudioEnabled, forKey: UserDefaultsKeys.recorderSystemAudioEnabled) }
    }
    @Published var outputFormat: AudioRecorderService.OutputFormat {
        didSet { UserDefaults.standard.set(outputFormat.rawValue, forKey: UserDefaultsKeys.recorderOutputFormat) }
    }
    @Published var micDuckingMode: AudioRecorderService.MicDuckingMode {
        didSet {
            UserDefaults.standard.set(micDuckingMode.rawValue, forKey: UserDefaultsKeys.recorderMicDuckingMode)
            recorderService.micDuckingMode = micDuckingMode
        }
    }
    @Published var transcriptionEnabled: Bool {
        didSet { UserDefaults.standard.set(transcriptionEnabled, forKey: UserDefaultsKeys.recorderTranscriptionEnabled) }
    }
    @Published var selectedLanguage: String? = nil
    @Published var selectedTask: TranscriptionTask = .transcribe
    @Published var recordings: [RecordingItem] = []
    @Published var errorMessage: String?
    @Published var partialText: String = ""
    @Published var isTranscribing: Bool = false

    var activeEngineName: String? { modelManager.activeEngineName }
    var activeModelName: String? { modelManager.activeModelName }
    var isModelReady: Bool { modelManager.isModelReady }
    var supportsTranslation: Bool { modelManager.supportsTranslation }

    private let recorderService: AudioRecorderService
    private let modelManager: ModelManagerService
    private let dictionaryService: DictionaryService
    private var cancellables = Set<AnyCancellable>()
    private var currentOutputURL: URL?
    private var streamingTask: Task<Void, Never>?
    private var confirmedStreamingText = ""

    init(recorderService: AudioRecorderService, modelManager: ModelManagerService, dictionaryService: DictionaryService) {
        self.recorderService = recorderService
        self.modelManager = modelManager
        self.dictionaryService = dictionaryService

        // Load saved preferences with defaults
        let defaults = UserDefaults.standard
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

        if defaults.object(forKey: UserDefaultsKeys.recorderTranscriptionEnabled) == nil {
            self.transcriptionEnabled = true
        } else {
            self.transcriptionEnabled = defaults.bool(forKey: UserDefaultsKeys.recorderTranscriptionEnabled)
        }

        recorderService.micDuckingMode = micDuckingMode

        setupBindings()
        loadRecordings()
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
    }

    func startRecording() {
        guard state == .idle else { return }
        errorMessage = nil
        partialText = ""
        confirmedStreamingText = ""
        Task {
            do {
                let url = try await recorderService.startRecording(
                    micEnabled: micEnabled,
                    systemAudioEnabled: systemAudioEnabled,
                    format: outputFormat
                )
                currentOutputURL = url
                state = .recording

                EventBus.shared.emit(.recordingStarted(RecordingStartedPayload()))

                if transcriptionEnabled {
                    startStreamingTranscription()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        let wasTranscribing = streamingTask != nil
        let recordingDuration = duration
        stopStreamingTranscription()

        Task {
            let url = await recorderService.stopRecording()

            let finalTranscriptionRequest: FinalTranscriptionRequest?
            if wasTranscribing, let url {
                finalTranscriptionRequest = FinalTranscriptionRequest(
                    outputURL: url,
                    buffer: recorderService.getCurrentBuffer(),
                    language: selectedLanguage,
                    task: selectedTask,
                    providerId: modelManager.selectedProviderId,
                    modelId: modelManager.selectedModelId,
                    prompt: dictionaryService.getTermsForPrompt()
                )
                state = .finalizing
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
            if !partialText.isEmpty {
                EventBus.shared.emit(.partialTranscriptionUpdate(PartialTranscriptionPayload(
                    text: partialText, isFinal: true, elapsedSeconds: recordingDuration
                )))
            }

            if url != nil {
                loadRecordings()
            }
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
        guard let providerId = modelManager.selectedProviderId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else {
            logger.info("No transcription engine available, skipping live transcription")
            return
        }

        isTranscribing = true
        let pollInterval: Double = plugin.supportsStreaming ? 1.5 : 3.0
        let streamPrompt = dictionaryService.getTermsForPrompt()
        let language = selectedLanguage
        // Fall back to transcribe if engine doesn't support translation
        let task = (selectedTask == .translate && !plugin.supportsTranslation) ? .transcribe : selectedTask

        streamingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(pollInterval))

            while !Task.isCancelled, self.state == .recording {
                let buffer = self.recorderService.getRecentBuffer(maxDuration: 3600)
                let bufferDuration = Double(buffer.count) / 16000.0

                if bufferDuration > 0.5 {
                    do {
                        let confirmed = self.confirmedStreamingText
                        let result = try await self.modelManager.transcribe(
                            audioSamples: buffer,
                            language: language,
                            task: task,
                            engineOverrideId: nil,
                            cloudModelOverride: nil,
                            prompt: streamPrompt,
                            onProgress: { [weak self] text in
                                guard let self, !Task.isCancelled else { return false }
                                let stable = StreamingHandler.stabilizeText(confirmed: confirmed, new: text)
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    self.partialText = stable
                                    EventBus.shared.emit(.partialTranscriptionUpdate(PartialTranscriptionPayload(
                                        text: stable, elapsedSeconds: self.duration
                                    )))
                                }
                                return true
                            }
                        )
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            let stable = StreamingHandler.stabilizeText(confirmed: confirmed, new: text)
                            self.partialText = stable
                            self.confirmedStreamingText = stable
                            EventBus.shared.emit(.partialTranscriptionUpdate(PartialTranscriptionPayload(
                                text: stable, elapsedSeconds: self.duration
                            )))
                        }
                    } catch {
                        logger.warning("Streaming transcription error: \(error.localizedDescription)")
                    }
                }

                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    private func stopStreamingTranscription() {
        streamingTask?.cancel()
        streamingTask = nil
    }

    private func runFinalTranscription(_ request: FinalTranscriptionRequest) async {
        isTranscribing = true
        defer { isTranscribing = false }

        let buffer = request.buffer
        guard buffer.count > 8000 else { // At least 0.5s of audio
            // Use streaming result as final if buffer too short
            if !partialText.isEmpty {
                saveTranscript(partialText, for: request.outputURL)
            }
            return
        }

        // Fall back to transcribe if engine doesn't support translation
        let effectiveTask: TranscriptionTask
        if request.task == .translate,
           let providerId = request.providerId,
           let plugin = PluginManager.shared.transcriptionEngine(for: providerId),
           !plugin.supportsTranslation {
            effectiveTask = .transcribe
        } else {
            effectiveTask = request.task
        }

        do {
            let result = try await modelManager.transcribe(
                audioSamples: buffer,
                language: request.language,
                task: effectiveTask,
                engineOverrideId: request.providerId,
                cloudModelOverride: request.modelId,
                prompt: request.prompt
            )
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
