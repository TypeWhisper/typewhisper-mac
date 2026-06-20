import Foundation
import Combine
import AppKit
import os
import UniformTypeIdentifiers
import TypeWhisperPluginSDK

@MainActor
final class FileTranscriptionViewModel: ObservableObject {
    typealias AudioProgressHandler = @MainActor @Sendable (AudioFileLoadProgress) -> Bool
    typealias TranscriptionProgressHandler = @MainActor @Sendable (String) -> Bool
    typealias SourceProgressHandler = @MainActor @Sendable (PluginTranscriptionSourceProgress) -> Bool
    typealias CancellationChecker = @Sendable () -> Bool
    typealias AudioSamplesLoader = @MainActor (
        URL,
        @escaping AudioProgressHandler,
        @escaping CancellationChecker
    ) async throws -> [Float]
    typealias TranscriptionRunner = @MainActor (
        [Float],
        LanguageSelection,
        TranscriptionTask,
        String?,
        String?,
        @escaping TranscriptionProgressHandler,
        @escaping SourceProgressHandler,
        @escaping CancellationChecker
    ) async throws -> TranscriptionResult
    typealias EngineReadinessChecker = @MainActor (String?) -> Bool
    typealias SubtitleFileSaver = @MainActor (String, SubtitleFormat, String) -> Void
    typealias SubtitleFolderPicker = @MainActor () -> URL?

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
        var phaseDescription: String?
        var progressFraction: Double?
        var progressText: String?
        var sourceProgress: PluginTranscriptionSourceProgress?
        var startedAt: Date?
        var finishedAt: Date?

        var fileName: String { url.lastPathComponent }
    }

    enum FileItemState: Equatable {
        case pending
        case loading
        case transcribing
        case done
        case error
        case cancelled
    }

    enum BatchState: Equatable {
        case idle
        case processing
        case done
        case cancelled
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)

        func cancel() {
            lock.withLock { $0 = true }
        }

        var isCancelled: Bool {
            lock.withLock { $0 }
        }
    }

    @Published var files: [FileItem] = []
    @Published var showFilePickerFromMenu = false
    @Published var batchState: BatchState = .idle
    @Published var currentIndex: Int = 0
    @Published private var elapsedRefreshDate = Date()
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
    private let subtitleFileSaver: SubtitleFileSaver
    private let subtitleFolderPicker: SubtitleFolderPicker
    private var cancellables = Set<AnyCancellable>()
    private var isInitialized = false
    private var activeBatchTask: Task<Void, Never>?
    private var activeCancellationFlag: CancellationFlag?
    private var elapsedTimerTask: Task<Void, Never>?

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
        engineReadinessChecker: EngineReadinessChecker? = nil,
        subtitleFileSaver: SubtitleFileSaver? = nil,
        subtitleFolderPicker: SubtitleFolderPicker? = nil
    ) {
        self.modelManager = modelManager
        self.audioFileService = audioFileService
        self.defaults = defaults
        self.audioSamplesLoader = audioSamplesLoader ?? { [audioFileService] url, onProgress, isCancelled in
            try await audioFileService.loadAudioSamples(from: url) { progress in
                guard !isCancelled() else { return false }
                return await onProgress(progress)
            }
        }
        self.transcriptionRunner = transcriptionRunner ?? { [modelManager] samples, languageSelection, task, engineOverrideId, cloudModelOverride, onProgress, onSourceProgress, isCancelled in
            try await modelManager.transcribe(
                audioSamples: samples,
                languageSelection: languageSelection,
                task: task,
                engineOverrideId: engineOverrideId,
                cloudModelOverride: cloudModelOverride,
                onProgress: { text in
                    guard !isCancelled() else { return false }
                    Task { @MainActor in
                        _ = onProgress(text)
                    }
                    return !isCancelled()
                },
                onSourceProgress: { progress in
                    guard !isCancelled() else { return false }
                    Task { @MainActor in
                        _ = onSourceProgress(progress)
                    }
                    return !isCancelled()
                }
            )
        }
        self.engineReadinessChecker = engineReadinessChecker
        self.subtitleFileSaver = subtitleFileSaver ?? { content, format, suggestedName in
            _ = SubtitleExporter.saveToFile(content: content, format: format, suggestedName: suggestedName)
        }
        self.subtitleFolderPicker = subtitleFolderPicker ?? {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Export Here")

            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
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

    var processedFiles: Int {
        files.filter { $0.state == .done || $0.state == .error || $0.state == .cancelled }.count
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

    func canPrepareForTranscription(_ engine: TranscriptionEnginePlugin) -> Bool {
        modelManager.canPrepareForTranscription(engine)
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

        activeBatchTask?.cancel()
        activeCancellationFlag?.cancel()

        let cancellationFlag = CancellationFlag()
        activeCancellationFlag = cancellationFlag
        batchState = .processing
        currentIndex = 0
        startElapsedTimer()

        // Reset pending/error items
        for i in files.indices {
            if files[i].state != .done {
                files[i].state = .pending
                files[i].result = nil
                files[i].errorMessage = nil
                files[i].phaseDescription = nil
                files[i].progressFraction = nil
                files[i].progressText = nil
                files[i].sourceProgress = nil
                files[i].startedAt = nil
                files[i].finishedAt = nil
            }
        }

        activeBatchTask = Task { [weak self] in
            guard let self else { return }
            for i in files.indices {
                guard batchState == .processing, !cancellationFlag.isCancelled else { break }
                guard files[i].state != .done else { continue }

                currentIndex = i
                await transcribeFile(at: i, cancellationFlag: cancellationFlag)
            }

            if cancellationFlag.isCancelled {
                batchState = .cancelled
            } else {
                batchState = .done
            }
            stopElapsedTimer()
            activeBatchTask = nil
            activeCancellationFlag = nil
        }
    }

    func cancelTranscription() {
        guard batchState == .processing else { return }
        activeCancellationFlag?.cancel()
        activeBatchTask?.cancel()
        if files.indices.contains(currentIndex),
           files[currentIndex].state == .loading || files[currentIndex].state == .transcribing {
            files[currentIndex].state = .cancelled
            files[currentIndex].phaseDescription = String(localized: "Cancelled")
            files[currentIndex].progressFraction = nil
            files[currentIndex].sourceProgress = nil
            files[currentIndex].finishedAt = Date()
        }
    }

    private func transcribeFile(at index: Int, cancellationFlag: CancellationFlag) async {
        guard files.indices.contains(index) else { return }

        files[index].state = .loading
        files[index].phaseDescription = String(localized: "Loading audio")
        files[index].progressFraction = nil
        files[index].progressText = nil
        files[index].sourceProgress = nil
        files[index].startedAt = Date()
        files[index].finishedAt = nil

        do {
            let samples = try await audioSamplesLoader(
                files[index].url,
                { [weak self] progress in
                    guard let self,
                          !cancellationFlag.isCancelled,
                          self.files.indices.contains(index),
                          self.files[index].state == .loading else {
                        return false
                    }
                    self.files[index].phaseDescription = Self.loadingPhaseDescription(for: progress)
                    self.files[index].progressFraction = progress.fraction
                    return true
                },
                { cancellationFlag.isCancelled }
            )

            try Task.checkCancellation()
            guard files.indices.contains(index) else { return }
            guard !cancellationFlag.isCancelled else {
                throw CancellationError()
            }

            files[index].state = .transcribing
            files[index].phaseDescription = String(localized: "Transcribing")
            files[index].progressFraction = nil
            files[index].sourceProgress = nil

            let result = try await transcriptionRunner(
                samples,
                languageSelection,
                selectedTask,
                selectedEngine,
                selectedModel,
                { [weak self] text in
                    guard let self,
                          !cancellationFlag.isCancelled,
                          self.files.indices.contains(index),
                          self.files[index].state == .transcribing else {
                        return false
                    }
                    self.files[index].phaseDescription = String(localized: "Transcribing")
                    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if self.files[index].sourceProgress != nil {
                        self.files[index].progressText = Self.stableProgressPreviewText(
                            current: self.files[index].progressText,
                            candidate: trimmedText
                        )
                    } else {
                        self.files[index].progressText = trimmedText
                    }
                    return true
                },
                { [weak self] progress in
                    guard let self,
                          !cancellationFlag.isCancelled,
                          self.files.indices.contains(index),
                          self.files[index].state == .transcribing,
                          let normalized = Self.normalizedSourceProgress(progress) else {
                        return false
                    }
                    self.files[index].phaseDescription = String(localized: "Transcribing")
                    self.files[index].sourceProgress = normalized
                    self.files[index].progressFraction = normalized.fractionCompleted
                    if let previewText = normalized.previewText?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !previewText.isEmpty {
                        self.files[index].progressText = Self.stableProgressPreviewText(
                            current: self.files[index].progressText,
                            candidate: previewText
                        )
                    }
                    return true
                },
                { cancellationFlag.isCancelled }
            )

            guard files.indices.contains(index) else { return }
            guard !cancellationFlag.isCancelled else {
                throw CancellationError()
            }

            files[index].result = result
            files[index].state = .done
            files[index].phaseDescription = String(localized: "Done")
            files[index].progressFraction = 1.0
            files[index].sourceProgress = nil
            files[index].finishedAt = Date()
        } catch is CancellationError {
            guard files.indices.contains(index) else { return }
            files[index].state = .cancelled
            files[index].phaseDescription = String(localized: "Cancelled")
            files[index].progressFraction = nil
            files[index].sourceProgress = nil
            files[index].finishedAt = Date()
        } catch {
            guard files.indices.contains(index) else { return }
            files[index].state = .error
            files[index].errorMessage = error.localizedDescription
            files[index].phaseDescription = String(localized: "Error")
            files[index].progressFraction = nil
            files[index].sourceProgress = nil
            files[index].finishedAt = Date()
        }
    }

    func exportSubtitles(for item: FileItem, format: SubtitleFormat) {
        guard let result = item.result,
              let content = SubtitleExporter.exportContent(for: result, format: format) else { return }

        let name = item.url.deletingPathExtension().lastPathComponent
        subtitleFileSaver(content, format, name)
    }

    func exportAllSubtitles(format: SubtitleFormat) {
        let exports: [(item: FileItem, content: String)] = files.compactMap { item in
            guard item.state == .done,
                  let result = item.result,
                  let content = SubtitleExporter.exportContent(for: result, format: format) else {
                return nil
            }
            return (item, content)
        }
        guard !exports.isEmpty else { return }

        // For single file, use save panel directly
        if exports.count == 1, let export = exports.first {
            let name = export.item.url.deletingPathExtension().lastPathComponent
            subtitleFileSaver(export.content, format, name)
            return
        }

        // For multiple files, choose a folder
        guard let folder = subtitleFolderPicker() else { return }

        for export in exports {
            let name = export.item.url.deletingPathExtension().lastPathComponent
            let fileURL = folder.appendingPathComponent("\(name).\(format.fileExtension)")
            SubtitleExporter.writeContent(export.content, to: fileURL, suggestedName: name)
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
        cancelTranscription()
        files = []
        batchState = .idle
        currentIndex = 0
        activeBatchTask = nil
        activeCancellationFlag = nil
        stopElapsedTimer()
    }

    func elapsedTime(for item: FileItem) -> TimeInterval? {
        guard let startedAt = item.startedAt else { return nil }
        let end = item.finishedAt ?? elapsedRefreshDate
        return end.timeIntervalSince(startedAt)
    }

    private var selectedEngineIsReady: Bool {
        if let engineReadinessChecker {
            return engineReadinessChecker(selectedEngine)
        }

        guard let engine = resolvedEngine else { return false }
        return modelManager.canPrepareForTranscription(engine)
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

    private static func loadingPhaseDescription(for progress: AudioFileLoadProgress) -> String {
        guard let fraction = progress.fraction else {
            return String(localized: "Loading audio")
        }
        let percent = Int((fraction * 100).rounded())
        return String(localized: "Loading audio \(percent)%")
    }

    private static func normalizedSourceProgress(
        _ progress: PluginTranscriptionSourceProgress
    ) -> PluginTranscriptionSourceProgress? {
        guard progress.processedDuration.isFinite,
              progress.totalDuration.isFinite,
              progress.totalDuration > 0 else {
            return nil
        }

        let processedDuration = min(max(progress.processedDuration, 0), progress.totalDuration)
        return PluginTranscriptionSourceProgress(
            processedDuration: processedDuration,
            totalDuration: progress.totalDuration,
            previewText: progress.previewText
        )
    }

    static func stableProgressPreviewText(current: String?, candidate: String) -> String {
        let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return current ?? "" }
        guard let current = current?.trimmingCharacters(in: .whitespacesAndNewlines),
              !current.isEmpty else {
            return candidate
        }

        guard candidate != current else { return current }

        if candidate.hasPrefix(current) || candidate.count >= current.count + 24 {
            return candidate
        }

        if current.hasPrefix(candidate) || current.localizedCaseInsensitiveContains(candidate) {
            return current
        }

        let sharedPrefix = candidate.commonPrefix(
            with: current,
            options: [.caseInsensitive, .diacriticInsensitive]
        ).count
        if sharedPrefix >= min(24, min(candidate.count, current.count)) {
            return candidate.count >= current.count ? candidate : current
        }

        return current
    }

    private func startElapsedTimer() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.elapsedRefreshDate = Date()
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil
        elapsedRefreshDate = Date()
    }
}
