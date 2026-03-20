import Foundation
import Combine
import AppKit

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
        case idle, recording
    }

    struct RecordingItem: Identifiable {
        let id = UUID()
        let url: URL
        let date: Date
        let duration: TimeInterval
        let fileSize: Int64
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
    @Published var recordings: [RecordingItem] = []
    @Published var errorMessage: String?

    private let recorderService: AudioRecorderService
    private var cancellables = Set<AnyCancellable>()
    private var currentOutputURL: URL?

    init(recorderService: AudioRecorderService) {
        self.recorderService = recorderService

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
        errorMessage = nil
        Task {
            do {
                let url = try await recorderService.startRecording(
                    micEnabled: micEnabled,
                    systemAudioEnabled: systemAudioEnabled,
                    format: outputFormat
                )
                currentOutputURL = url
                state = .recording
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        Task {
            let url = await recorderService.stopRecording()
            state = .idle
            if url != nil {
                loadRecordings()
            }
        }
    }

    func deleteRecording(_ item: RecordingItem) {
        do {
            try FileManager.default.removeItem(at: item.url)
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
                    return RecordingItem(url: url, date: date, duration: duration, fileSize: size)
                }
                .sorted { $0.date > $1.date }

            recordings = items
        } catch {
            recordings = []
        }
    }

    private func audioDuration(for url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return asset.duration.seconds.isFinite ? asset.duration.seconds : 0
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
}

import AVFoundation
