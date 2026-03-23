import Foundation
import Combine
import AppKit
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

    struct FileItem: Identifiable {
        let id = UUID()
        let url: URL
        var state: FileItemState = .pending
        var result: TranscriptionResult?
        var errorMessage: String?

        var fileName: String { url.lastPathComponent }
    }

    enum FileItemState: Equatable {
        case pending
        case loading
        case transcribing
        case done
        case error
    }

    enum BatchState: Equatable {
        case idle
        case processing
        case done
    }

    @Published var files: [FileItem] = []
    @Published var showFilePickerFromMenu = false
    @Published var batchState: BatchState = .idle
    @Published var currentIndex: Int = 0
    @Published var selectedLanguage: String? = nil
    @Published var selectedTask: TranscriptionTask = .transcribe

    private let modelManager: ModelManagerService
    private let audioFileService: AudioFileService

    static let allowedContentTypes: [UTType] = [
        .wav, .mp3, .mpeg4Audio, .aiff, .audio,
        .mpeg4Movie, .quickTimeMovie, .avi, .movie
    ]

    init(modelManager: ModelManagerService, audioFileService: AudioFileService) {
        self.modelManager = modelManager
        self.audioFileService = audioFileService
    }

    var canTranscribe: Bool {
        !files.isEmpty && modelManager.isModelReady && batchState != .processing
    }

    var supportsTranslation: Bool {
        modelManager.supportsTranslation
    }

    var hasResults: Bool {
        files.contains { $0.state == .done }
    }

    var totalFiles: Int { files.count }

    var completedFiles: Int {
        files.filter { $0.state == .done }.count
    }

    func addFiles(_ urls: [URL]) {
        let validExtensions = AudioFileService.supportedExtensions
        let existingURLs = Set(files.map(\.url))

        let newFiles = urls
            .filter { validExtensions.contains($0.pathExtension.lowercased()) }
            .filter { !existingURLs.contains($0) }
            .map { FileItem(url: $0) }

        files.append(contentsOf: newFiles)
    }

    func removeFile(_ item: FileItem) {
        files.removeAll { $0.id == item.id }
        if files.isEmpty {
            batchState = .idle
        }
    }

    func transcribeAll() {
        guard canTranscribe else { return }

        batchState = .processing
        currentIndex = 0

        // Reset pending/error items
        for i in files.indices {
            if files[i].state != .done {
                files[i].state = .pending
                files[i].result = nil
                files[i].errorMessage = nil
            }
        }

        Task {
            for i in files.indices {
                guard batchState == .processing else { break }
                guard files[i].state != .done else { continue }

                currentIndex = i
                await transcribeFile(at: i)
            }
            batchState = .done
        }
    }

    private func transcribeFile(at index: Int) async {
        files[index].state = .loading

        do {
            let samples = try await audioFileService.loadAudioSamples(from: files[index].url)

            files[index].state = .transcribing

            let result = try await modelManager.transcribe(
                audioSamples: samples,
                language: selectedLanguage,
                task: selectedTask,
                engineOverrideId: nil,
                cloudModelOverride: nil
            )

            files[index].result = result
            files[index].state = .done
        } catch {
            files[index].state = .error
            files[index].errorMessage = error.localizedDescription
        }
    }

    func exportSubtitles(for item: FileItem, format: SubtitleFormat) {
        guard let result = item.result, !result.segments.isEmpty else { return }

        let content: String
        switch format {
        case .srt: content = SubtitleExporter.exportSRT(segments: result.segments)
        case .vtt: content = SubtitleExporter.exportVTT(segments: result.segments)
        }

        let name = item.url.deletingPathExtension().lastPathComponent
        SubtitleExporter.saveToFile(content: content, format: format, suggestedName: name)
    }

    func exportAllSubtitles(format: SubtitleFormat) {
        let completedFiles = files.filter { $0.state == .done && $0.result != nil }
        guard !completedFiles.isEmpty else { return }

        // For single file, use save panel directly
        if completedFiles.count == 1, let item = completedFiles.first {
            exportSubtitles(for: item, format: format)
            return
        }

        // For multiple files, choose a folder
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")

        guard panel.runModal() == .OK, let folder = panel.url else { return }

        for item in completedFiles {
            guard let result = item.result, !result.segments.isEmpty else { continue }

            let content: String
            switch format {
            case .srt: content = SubtitleExporter.exportSRT(segments: result.segments)
            case .vtt: content = SubtitleExporter.exportVTT(segments: result.segments)
            }

            let name = item.url.deletingPathExtension().lastPathComponent
            let fileURL = folder.appendingPathComponent("\(name).\(format.fileExtension)")
            try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func copyAllText() {
        let allText = files
            .compactMap { $0.result?.text }
            .joined(separator: "\n\n")

        guard !allText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allText, forType: .string)
    }

    func copyText(for item: FileItem) {
        guard let text = item.result?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reset() {
        files = []
        batchState = .idle
        currentIndex = 0
    }
}
