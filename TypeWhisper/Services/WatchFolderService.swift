import Foundation
import os
import Combine

@MainActor
final class WatchFolderService: ObservableObject {
    @Published var isWatching: Bool = false
    @Published var currentlyProcessing: String?
    @Published var processedFiles: [ProcessedFileItem] = []

    struct ProcessedFileItem: Identifiable, Codable {
        let id: UUID
        let fileName: String
        let date: Date
        let outputPath: String
        let success: Bool
        let errorMessage: String?
    }

    private var dispatchSource: (any DispatchSourceFileSystemObject)?
    private var fileDescriptor: Int32 = -1
    private var processingTask: Task<Void, Never>?
    private var processedFileFingerprints: Set<String> = []
    private var debounceTask: Task<Void, Never>?
    private var needsRescanAfterProcessing = false

    private let audioFileService: AudioFileService
    private let modelManagerService: ModelManagerService
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "WatchFolder")

    init(audioFileService: AudioFileService, modelManagerService: ModelManagerService) {
        self.audioFileService = audioFileService
        self.modelManagerService = modelManagerService
        loadProcessedFileFingerprints()
        loadProcessedFiles()
    }

    func startWatching(folderURL: URL) {
        stopWatching()

        _ = folderURL.startAccessingSecurityScopedResource()

        fileDescriptor = open(folderURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logger.error("Failed to open watch folder: \(folderURL.path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.debouncedScan(folderURL)
            }
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
        }

        dispatchSource = source
        source.resume()
        isWatching = true
        needsRescanAfterProcessing = false
        logger.info("Started watching folder: \(folderURL.path)")

        // Initial scan
        scanFolder(folderURL)
    }

    func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil
        processingTask?.cancel()
        processingTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        needsRescanAfterProcessing = false
        isWatching = false
    }

    func clearHistory() {
        processedFiles.removeAll()
        processedFileFingerprints.removeAll()
        saveProcessedFileFingerprints()
        saveProcessedFiles()
    }

    // MARK: - Private

    private func debouncedScan(_ folderURL: URL) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            scanFolder(folderURL)
        }
    }

    private func scanFolder(_ folderURL: URL) {
        guard processingTask == nil || processingTask?.isCancelled == true else {
            needsRescanAfterProcessing = true
            return
        }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let audioFiles = contents.compactMap { url -> (url: URL, fingerprint: String)? in
            let ext = url.pathExtension.lowercased()
            guard AudioFileService.supportedExtensions.contains(ext),
                  let fingerprint = fileFingerprint(for: url),
                  !processedFileFingerprints.contains(fingerprint) else {
                return nil
            }
            return (url, fingerprint)
        }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }

        guard !audioFiles.isEmpty else { return }

        let outputFormat = UserDefaults.standard.string(forKey: UserDefaultsKeys.watchFolderOutputFormat) ?? "md"
        let deleteSource = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchFolderDeleteSource)
        let overrides = WatchFolderViewModel.shared.transcriptionOverrides

        // Resolve output folder from bookmark, or use watch folder
        let outputFolder: URL
        if let outputBookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.watchFolderOutputBookmark) {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: outputBookmark,
                options: .withSecurityScope,
                bookmarkDataIsStale: &isStale
            ) {
                _ = resolved.startAccessingSecurityScopedResource()
                outputFolder = resolved
            } else {
                outputFolder = folderURL
            }
        } else {
            outputFolder = folderURL
        }

        processingTask = Task { [weak self] in
            for file in audioFiles {
                guard !Task.isCancelled else { break }
                await self?.transcribeFile(
                    url: file.url,
                    fingerprint: file.fingerprint,
                    outputFolder: outputFolder,
                    format: outputFormat,
                    overrides: overrides,
                    deleteSource: deleteSource
                )
            }

            guard let self else { return }
            self.processingTask = nil

            guard self.needsRescanAfterProcessing else { return }
            self.needsRescanAfterProcessing = false
            self.scanFolder(folderURL)
        }
    }

    private func transcribeFile(
        url: URL,
        fingerprint: String,
        outputFolder: URL,
        format: String,
        overrides: WatchFolderViewModel.TranscriptionOverrides,
        deleteSource: Bool
    ) async {
        let fileName = url.lastPathComponent
        currentlyProcessing = fileName

        do {
            let samples = try await audioFileService.loadAudioSamples(from: url)
            let result = try await modelManagerService.transcribe(
                audioSamples: samples,
                language: overrides.language,
                task: .transcribe,
                engineOverrideId: overrides.engineId,
                cloudModelOverride: overrides.modelId
            )

            let outputName = url.deletingPathExtension().lastPathComponent
            let outputExt = format == "md" ? "md" : "txt"
            let outputURL = outputFolder
                .appendingPathComponent(outputName)
                .appendingPathExtension(outputExt)

            let content: String
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .medium
            let dateString = dateFormatter.string(from: Date())
            let engineName: String
            if let overrideId = overrides.engineId,
               let engine = PluginManager.shared.transcriptionEngine(for: overrideId) {
                engineName = engine.providerDisplayName
            } else {
                engineName = modelManagerService.activeEngineName ?? "Unknown"
            }

            if format == "md" {
                content = """
                # Transcription: \(fileName)
                - Date: \(dateString)
                - Engine: \(engineName)

                \(result.text)
                """
            } else {
                content = result.text
            }

            try content.write(to: outputURL, atomically: true, encoding: .utf8)

            if deleteSource {
                try? FileManager.default.removeItem(at: url)
            }

            let item = ProcessedFileItem(
                id: UUID(),
                fileName: fileName,
                date: Date(),
                outputPath: outputURL.path,
                success: true,
                errorMessage: nil
            )
            processedFiles.insert(item, at: 0)
            processedFileFingerprints.insert(fingerprint)
            saveProcessedFileFingerprints()
            saveProcessedFiles()
            logger.info("Transcribed: \(fileName)")

        } catch {
            let item = ProcessedFileItem(
                id: UUID(),
                fileName: fileName,
                date: Date(),
                outputPath: "",
                success: false,
                errorMessage: error.localizedDescription
            )
            processedFiles.insert(item, at: 0)
            saveProcessedFiles()
            logger.error("Failed to transcribe \(fileName): \(error.localizedDescription)")
        }

        currentlyProcessing = nil
    }

    // MARK: - Persistence

    private var processedFingerprintsURL: URL {
        AppConstants.appSupportDirectory.appendingPathComponent("watch-folder-processed.json")
    }

    private var processedHistoryURL: URL {
        AppConstants.appSupportDirectory.appendingPathComponent("watch-folder-history.json")
    }

    private func loadProcessedFileFingerprints() {
        guard let data = try? Data(contentsOf: processedFingerprintsURL),
              let fingerprints = try? JSONDecoder().decode(Set<String>.self, from: data) else { return }
        processedFileFingerprints = fingerprints
    }

    private func saveProcessedFileFingerprints() {
        let fm = FileManager.default
        let dir = AppConstants.appSupportDirectory
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(processedFileFingerprints) else { return }
        try? data.write(to: processedFingerprintsURL, options: .atomic)
    }

    private func loadProcessedFiles() {
        guard let data = try? Data(contentsOf: processedHistoryURL),
              let items = try? JSONDecoder().decode([ProcessedFileItem].self, from: data) else { return }
        processedFiles = items
    }

    private func saveProcessedFiles() {
        // Keep at most 100 items
        if processedFiles.count > 100 {
            processedFiles = Array(processedFiles.prefix(100))
        }
        guard let data = try? JSONEncoder().encode(processedFiles) else { return }
        try? data.write(to: processedHistoryURL, options: .atomic)
    }

    private func fileFingerprint(for url: URL) -> String? {
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: resourceKeys)

        let fileSize = values?.fileSize ?? 0
        let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0

        return "\(url.path)|\(fileSize)|\(modifiedAt)"
    }
}
