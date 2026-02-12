import Foundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class FileTranscriptionViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: FileTranscriptionViewModel?
    static var shared: FileTranscriptionViewModel {
        guard let instance = _shared else {
            fatalError("FileTranscriptionViewModel not initialized")
        }
        return instance
    }

    enum State: Equatable {
        case idle
        case loading
        case transcribing
        case done
        case error(String)
    }

    @Published var state: State = .idle
    @Published var transcriptionText: String = ""
    @Published var selectedFileURL: URL?
    @Published var selectedLanguage: String? = nil
    @Published var selectedTask: TranscriptionTask = .transcribe
    @Published var processingInfo: String = ""

    private let modelManager: ModelManagerService
    private let audioFileService: AudioFileService

    static let allowedContentTypes: [UTType] = [
        .wav, .mp3, .mpeg4Audio, .flac, .aiff,
        .mpeg4Movie, .quickTimeMovie, .avi, .movie
    ]

    init(modelManager: ModelManagerService, audioFileService: AudioFileService) {
        self.modelManager = modelManager
        self.audioFileService = audioFileService
    }

    var canTranscribe: Bool {
        selectedFileURL != nil && modelManager.activeEngine?.isModelLoaded == true && state != .transcribing
    }

    var supportsTranslation: Bool {
        modelManager.selectedEngine.supportsTranslation
    }

    func selectFile(_ url: URL) {
        selectedFileURL = url
        transcriptionText = ""
        state = .idle
        processingInfo = ""
    }

    func transcribe() {
        guard let url = selectedFileURL else { return }

        Task {
            state = .loading
            processingInfo = String(localized: "Loading audio file...")

            do {
                let samples = try await audioFileService.loadAudioSamples(from: url)
                let audioDuration = Double(samples.count) / 16000.0
                processingInfo = String(localized: "Transcribing \(String(format: "%.1f", audioDuration))s of audio...")
                state = .transcribing

                let result = try await modelManager.transcribe(
                    audioSamples: samples,
                    language: selectedLanguage,
                    task: selectedTask
                )

                transcriptionText = result.text
                processingInfo = String(
                    localized: "Done in \(String(format: "%.1f", result.processingTime))s (\(String(format: "%.0f", result.realTimeFactor))x realtime) - \(result.engineUsed.displayName)"
                )
                state = .done
            } catch {
                state = .error(error.localizedDescription)
                processingInfo = ""
            }
        }
    }

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptionText, forType: .string)
    }

    func reset() {
        selectedFileURL = nil
        transcriptionText = ""
        state = .idle
        processingInfo = ""
    }
}
