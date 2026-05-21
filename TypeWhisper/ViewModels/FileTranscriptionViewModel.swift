import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import TypeWhisperPluginSDK

@MainActor
final class FileTranscriptionViewModel: ObservableObject {
    typealias AudioSamplesLoader = @MainActor (URL) async throws -> [Float]
    typealias TranscriptionRunner = @MainActor (
        [Float],
        LanguageSelection,
        TranscriptionTask,
        String?,
        String?
    ) async throws -> TranscriptionResult
    typealias EngineReadinessChecker = @MainActor (String?) -> Bool

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
    @Published var languageSelection: LanguageSelection = .auto {
        didSet {
            defaults.set(
                languageSelection.storedValue(nilBehavior: .auto),
                forKey: UserDefaultsKeys.fileTranscriptionLanguage
            )
        }
    }
    @Published var selectedTask: TranscriptionTask = .transcribe
    @Published var selectedEngine: String? {
        didSet {
            defaults.set(selectedEngine, forKey: UserDefaultsKeys.fileTranscriptionEngine)
            guard isInitialized, oldValue != selectedEngine else { return }
            selectedModel = nil
            normalizeLanguageSelectionForResolvedEngine()
        }
    }
    @Published var selectedModel: String? {
        didSet { defaults.set(selectedModel, forKey: UserDefaultsKeys.fileTranscriptionModel) }
    }

    private let modelManager: ModelManagerService
    private let audioFileService: AudioFileService
    private let defaults: UserDefaults
    private let audioSamplesLoader: AudioSamplesLoader
    private let transcriptionRunner: TranscriptionRunner
    private let engineReadinessChecker: EngineReadinessChecker?
    private var cancellables = Set<AnyCancellable>()
    private var isInitialized = false

    static let allowedContentTypes: [UTType] = [
        .wav, .mp3, .mpeg4Audio, .aiff, .audio,
        .mpeg4Movie, .quickTimeMovie, .avi, .movie
    ]

    init(
        modelManager: ModelManagerService,
        audioFileService: AudioFileService,
        defaults: UserDefaults = .standard,
        audioSamplesLoader: AudioSamplesLoader? = nil,
        transcriptionRunner: TranscriptionRunner? = nil,
        engineReadinessChecker: EngineReadinessChecker? = nil
    ) {
        self.modelManager = modelManager
        self.audioFileService = audioFileService
        self.defaults = defaults
        self.audioSamplesLoader = audioSamplesLoader ?? { [audioFileService] url in
            try await audioFileService.loadAudioSamples(from: url)
        }
        self.transcriptionRunner = transcriptionRunner ?? { [modelManager] samples, languageSelection, task, engineOverrideId, cloudModelOverride in
            try await modelManager.transcribe(
                audioSamples: samples,
                languageSelection: languageSelection,
                task: task,
                engineOverrideId: engineOverrideId,
                cloudModelOverride: cloudModelOverride
            )
        }
        self.engineReadinessChecker = engineReadinessChecker
        self.languageSelection = LanguageSelection(
            storedValue: defaults.string(forKey: UserDefaultsKeys.fileTranscriptionLanguage),
            nilBehavior: .auto
        )
        self.selectedEngine = defaults.string(forKey: UserDefaultsKeys.fileTranscriptionEngine)
        self.selectedModel = defaults.string(forKey: UserDefaultsKeys.fileTranscriptionModel)
        self.isInitialized = true
        reconcileSelectionWithAvailablePlugins()
    }

    var canTranscribe: Bool {
        !files.isEmpty && selectedEngineIsReady && batchState != .processing
    }

    var supportsTranslation: Bool {
        resolvedEngine?.supportsTranslation ?? false
    }

    var availableEngines: [TranscriptionEnginePlugin] {
        guard let pluginManager = PluginManager.shared else { return [] }
        return pluginManager.transcriptionEngines
    }

    var resolvedEngine: TranscriptionEnginePlugin? {
        let engineId = selectedEngine ?? modelManager.selectedProviderId
        guard let engineId else { return nil }
        guard let pluginManager = PluginManager.shared else { return nil }
        return pluginManager.transcriptionEngine(for: engineId)
    }

    var selectedEngineSupportedLanguages: [String] {
        resolvedEngine?.supportedLanguages.sorted() ?? []
    }

    var hasResults: Bool {
        files.contains { $0.state == .done }
    }

    var totalFiles: Int { files.count }

    var completedFiles: Int {
        files.filter { $0.state == .done }.count
    }

    func observePluginManager() {
        guard let pluginManager = PluginManager.shared else { return }
        pluginManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcileSelectionWithAvailablePlugins()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func canUseForTranscription(_ engine: TranscriptionEnginePlugin) -> Bool {
        modelManager.canUseForTranscription(engine)
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
            let samples = try await audioSamplesLoader(files[index].url)

            files[index].state = .transcribing

            let result = try await transcriptionRunner(
                samples,
                languageSelection,
                selectedTask,
                selectedEngine,
                selectedModel
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

    private var selectedEngineIsReady: Bool {
        if let engineReadinessChecker {
            return engineReadinessChecker(selectedEngine)
        }

        guard let engine = resolvedEngine else { return false }
        guard modelManager.canUseForTranscription(engine) else { return false }
        return engine.isConfigured
    }

    private func reconcileSelectionWithAvailablePlugins() {
        guard let pluginManager = PluginManager.shared else { return }
        if let selectedEngine,
           pluginManager.transcriptionEngine(for: selectedEngine) == nil {
            self.selectedEngine = nil
            selectedModel = nil
        }
        normalizeLanguageSelectionForResolvedEngine()
    }

    private func normalizeLanguageSelectionForResolvedEngine() {
        guard let engine = resolvedEngine else { return }
        let normalized = languageSelection.normalizedForSupportedLanguages(engine.supportedLanguages)
        if normalized != languageSelection {
            languageSelection = normalized
        }
    }
}
