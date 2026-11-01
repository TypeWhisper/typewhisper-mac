import Foundation
import os
import Combine
import CryptoKit
import TypeWhisperPluginSDK

enum WatchFolderOutputFormat: String, CaseIterable {
    case markdown = "md"
    case plainText = "txt"
    case srt = "srt"
    case vtt = "vtt"

    init(storedValue: String?) {
        self = WatchFolderOutputFormat(rawValue: storedValue ?? "") ?? .markdown
    }

    var fileExtension: String {
        rawValue
    }

    var isSubtitleFormat: Bool {
        switch self {
        case .srt, .vtt:
            true
        case .markdown, .plainText:
            false
        }
    }

    var displayName: String {
        switch self {
        case .markdown:
            String(localized: "Markdown (.md)")
        case .plainText:
            String(localized: "watchFolder.plainText")
        case .srt:
            String(localized: "SRT")
        case .vtt:
            String(localized: "VTT")
        }
    }
}

struct WatchFolderExportArtifact {
    let fileExtension: String
    let content: String
}

@MainActor
struct FileJobAutomationPipeline {
    private let automationsProvider: @MainActor () -> [any FileJobAutomationPlugin]
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "FileJobAutomation")

    init(automationsProvider: @escaping @MainActor () -> [any FileJobAutomationPlugin] = {
        PluginManager.shared.fileJobAutomations
    }) {
        self.automationsProvider = automationsProvider
    }

    func process(artifact: FileJobArtifact, context: FileJobContext) async -> FileJobAutomationResult {
        var currentArtifact = artifact
        var appliedSteps: [String] = []
        var outputPathWasWritten = false

        for automation in automationsProvider() {
            let before = currentArtifact
            do {
                let result = try await automation.process(artifact: currentArtifact, context: context)
                currentArtifact = result.artifact
                outputPathWasWritten = outputPathWasWritten || result.outputPathWasWritten

                if !result.appliedSteps.isEmpty {
                    appliedSteps.append(contentsOf: result.appliedSteps)
                } else if result.artifact != before || result.outputPathWasWritten {
                    appliedSteps.append(automation.automationName)
                }
            } catch {
                logger.error("File job automation '\(automation.automationName)' failed: \(error.localizedDescription)")
            }
        }

        return FileJobAutomationResult(
            artifact: currentArtifact,
            appliedSteps: appliedSteps,
            outputPathWasWritten: outputPathWasWritten
        )
    }
}

enum WatchFolderExportBuilder {
    enum Error: LocalizedError {
        case missingSubtitleSegments

        var errorDescription: String? {
            switch self {
            case .missingSubtitleSegments:
                String(localized: "watchFolder.export.subtitleSegmentsRequired")
            }
        }
    }

    /// `audioPath` and `timestampsPath` go into the Markdown's frontmatter, so a
    /// manuscript that links the note leads to the recording and its word timestamps.
    static func build(
        format: WatchFolderOutputFormat,
        result: TranscriptionResult,
        fileName: String,
        engineName: String,
        date: Date,
        audioPath: String? = nil,
        timestampsPath: String? = nil
    ) throws -> WatchFolderExportArtifact {
        switch format {
        case .markdown:
            let content = TranscriptMarkdown.render(
                result: result,
                title: "Transcription: \(fileName)",
                engineName: engineName,
                date: date,
                audioPath: audioPath,
                timestampsPath: timestampsPath
            )
            return WatchFolderExportArtifact(fileExtension: format.fileExtension, content: content)

        case .plainText:
            return WatchFolderExportArtifact(fileExtension: format.fileExtension, content: result.text)

        case .srt:
            guard !result.segments.isEmpty else {
                throw Error.missingSubtitleSegments
            }
            return WatchFolderExportArtifact(
                fileExtension: format.fileExtension,
                content: SubtitleExporter.exportSRT(segments: result.segments)
            )

        case .vtt:
            guard !result.segments.isEmpty else {
                throw Error.missingSubtitleSegments
            }
            return WatchFolderExportArtifact(
                fileExtension: format.fileExtension,
                content: SubtitleExporter.exportVTT(segments: result.segments)
            )
        }
    }
}

/// A Markdown transcript, for example for Obsidian: frontmatter with the recording, its
/// word timestamps and how it was transcribed, then a paragraph per speaker turn that
/// starts with its time and speaker.
enum TranscriptMarkdown {
    /// A long turn gets a new paragraph with its time after this many seconds.
    static let paragraphSeconds: TimeInterval = 60

    static func render(
        result: TranscriptionResult,
        title: String,
        engineName: String,
        date: Date,
        audioPath: String?,
        timestampsPath: String?
    ) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        var lines = ["---"]
        if let audioPath { lines.append("audio: \(yamlScalar(audioPath))") }
        if let timestampsPath { lines.append("timestamps: \(yamlScalar(timestampsPath))") }
        lines.append("date: \(dateFormatter.string(from: date))")
        if result.duration.isFinite, result.duration > 0 {
            lines.append("duration: \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), result.duration))")
        }
        if let language = result.detectedLanguage, !language.isEmpty {
            lines.append("language: \(yamlScalar(language))")
        }
        lines.append("engine: \(yamlScalar(engineName))")
        var speakers: [String] = []
        for label in result.segments.compactMap(\.speakerLabel) where !speakers.contains(label) {
            speakers.append(label)
        }
        if !speakers.isEmpty {
            lines.append("speakers:")
            lines += speakers.map { "  - \(yamlScalar($0))" }
        }
        lines.append("---")
        lines.append("")
        lines.append("# \(title)")
        lines.append("")
        lines.append(body(result))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Paragraphs that start with their time, `**[00:12:03] Speaker 1:** text`, or the
    /// plain text when the engine returned no segments.
    static func body(_ result: TranscriptionResult) -> String {
        let segments = result.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.start.isFinite
        }
        if segments.contains(where: { $0.speakerLabel != nil }) {
            return speakerParagraphs(segments)
        }
        return timedParagraphs(of: result.text, segments: segments)
    }

    /// A paragraph per speaker turn. A labelled transcript's text is made of its
    /// segments, so the paragraphs are too.
    private static func speakerParagraphs(_ segments: [TranscriptionSegment]) -> String {
        var paragraphs: [(start: TimeInterval, label: String?, text: String)] = []
        for segment in segments {
            var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Cloud engines also write the label into the text.
            if let label = segment.speakerLabel, text.hasPrefix("\(label):") {
                text = String(text.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !text.isEmpty else { continue }
            if let last = paragraphs.last, last.label == segment.speakerLabel,
               segment.start - last.start < paragraphSeconds {
                paragraphs[paragraphs.count - 1].text += " " + text
            } else {
                paragraphs.append((segment.start, segment.speakerLabel, text))
            }
        }
        return paragraphs.map { paragraph in
            let label = paragraph.label.map { " \($0):" } ?? ""
            return "**[\(clock(paragraph.start))]\(label)** \(paragraph.text)"
        }.joined(separator: "\n\n")
    }

    /// The transcript's own text, split into paragraphs about a minute apart. The text
    /// is kept as it is: corrections and number formatting treat it as a whole, so it
    /// can differ from its segments ("23" against "20 three" from one segment per word).
    /// The segments are found in the text one after the other, close to where the one
    /// before ended; a segment the text does not contain there is passed over. A
    /// paragraph starts at a segment that was found.
    private static func timedParagraphs(of text: String, segments: [TranscriptionSegment]) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = segments.first, !text.isEmpty else { return text }
        // The text without whitespace and where each character is, so a segment is
        // found whatever spacing joins the segments, also in Chinese or Japanese.
        var compact: [Character] = []
        var positions: [String.Index] = []
        for index in text.indices where !text[index].isWhitespace {
            compact.append(text[index])
            positions.append(index)
        }

        var starts: [(time: TimeInterval, offset: Int)] = [(first.start, 0)]
        var cursor = 0
        // Characters of the segments passed over since the last one found: the text
        // moved on by about as much.
        var passedOver = 0
        for segment in segments {
            let needle = Array(segment.text.filter { !$0.isWhitespace })
            guard !needle.isEmpty else { continue }
            let window = 40 + 2 * passedOver
            guard let offset = firstOffset(of: needle, in: compact, from: cursor, within: window) else {
                passedOver += needle.count
                continue
            }
            cursor = offset + needle.count
            passedOver = 0
            if segment.start - starts[starts.count - 1].time >= paragraphSeconds,
               offset > starts[starts.count - 1].offset {
                starts.append((segment.start, offset))
            }
        }

        var paragraphs: [String] = []
        for (number, start) in starts.enumerated() {
            let from = positions[start.offset]
            let to = number + 1 < starts.count ? positions[starts[number + 1].offset] : text.endIndex
            let paragraph = text[from..<to].trimmingCharacters(in: .whitespacesAndNewlines)
            paragraphs.append("**[\(clock(start.time))]** \(paragraph)")
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Where `needle` starts in `haystack`, at most `window` characters after `start`.
    private static func firstOffset(of needle: [Character], in haystack: [Character], from start: Int, within window: Int) -> Int? {
        let last = min(start + window, haystack.count - needle.count)
        guard start <= last else { return nil }
        for offset in start...last
        where haystack[offset] == needle[0] && haystack[offset..<(offset + needle.count)].elementsEqual(needle) {
            return offset
        }
        return nil
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// A double-quoted YAML scalar; JSON string escaping is valid YAML.
    private static func yamlScalar(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }
}

@MainActor
final class WatchFolderService: ObservableObject {
    @Published var isWatching: Bool = false
    /// Labels a transcription's segments by speaker; throws without Premium.
    var speakerLabeler: (@MainActor (TranscriptionResult, [Float]) async throws -> [TranscriptionSegment])?
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

    private let loadAudio: @MainActor (URL) async throws -> [Float]
    private let appSupportDirectory: URL
    private let modelManagerService: ModelManagerService
    private let fileJobAutomationPipeline: FileJobAutomationPipeline
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "WatchFolder")

    init(
        audioFileService: AudioFileService,
        modelManagerService: ModelManagerService,
        fileJobAutomationPipeline: FileJobAutomationPipeline = FileJobAutomationPipeline(),
        appSupportDirectory: URL = AppConstants.appSupportDirectory,
        audioSamplesLoader: (@MainActor (URL) async throws -> [Float])? = nil
    ) {
        self.loadAudio = audioSamplesLoader ?? { try await audioFileService.loadAudioSamples(from: $0) }
        self.appSupportDirectory = appSupportDirectory
        self.modelManagerService = modelManagerService
        self.fileJobAutomationPipeline = fileJobAutomationPipeline
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

        let outputFormat = WatchFolderOutputFormat(
            storedValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.watchFolderOutputFormat)
        )
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

    /// A result whose text and segments carry the speaker labels, as cloud
    /// engines with speaker labels return them.
    static func result(_ result: TranscriptionResult, labelledWith segments: [TranscriptionSegment]) -> TranscriptionResult {
        TranscriptionResult(
            text: SpeakerTranscriptBuilder.textWithSpeakers(segments),
            detectedLanguage: result.detectedLanguage,
            duration: result.duration,
            processingTime: result.processingTime,
            engineUsed: result.engineUsed,
            segments: segments,
            words: result.words
        )
    }

    func transcribeFile(
        url: URL,
        fingerprint: String,
        outputFolder: URL,
        format: WatchFolderOutputFormat,
        overrides: WatchFolderViewModel.TranscriptionOverrides,
        deleteSource: Bool
    ) async {
        let fileName = url.lastPathComponent
        currentlyProcessing = fileName
        defer { currentlyProcessing = nil }

        do {
            // A new folder job waits for the comparison instead of failing the file.
            try await HistoryRetranscriptionActivity.waitForEngineAvailability()
            let samples = try await loadAudio(url)
            try Task.checkCancellation()
            var result = try await modelManagerService.transcribe(
                audioSamples: samples,
                languageSelection: overrides.languageSelection,
                task: .transcribe,
                engineOverrideId: overrides.engineId,
                cloudModelOverride: overrides.modelId
            )
            if overrides.detectSpeakers, let speakerLabeler {
                // Without Premium or without speakers the file is still written, unlabelled.
                do {
                    let labelled = try await speakerLabeler(result, samples)
                    if labelled.contains(where: { $0.speakerLabel != nil }) {
                        result = Self.result(result, labelledWith: labelled)
                    }
                } catch {
                    logger.error("Speaker detection failed for watch-folder file: \(error.localizedDescription, privacy: .public)")
                }
            }

            let outputName = url.deletingPathExtension().lastPathComponent
            let exportDate = Date()
            // The engine that produced the result; the default engine can change
            // while a file runs, for example when a plugin comes back from an update.
            let engineId = result.engineUsed
            let engineName = PluginManager.shared.transcriptionEngine(for: engineId)?.providerDisplayName ?? engineId

            let modelId = modelManagerService.resolvedModelId(
                engineOverrideId: engineId,
                cloudModelOverride: engineId == overrides.engineId ? overrides.modelId : nil
            )
            // A Markdown transcript gets the word timestamps in a file of their own,
            // named in its frontmatter, for tools that cut audio by the transcript.
            let timestampsURL = format == .markdown
                ? writeTimestampsFile(for: url, result: result, modelId: modelId, outputFolder: outputFolder, keepsSource: !deleteSource)
                : nil

            let artifact = try WatchFolderExportBuilder.build(
                format: format,
                result: result,
                fileName: fileName,
                engineName: engineName,
                date: exportDate,
                audioPath: deleteSource ? nil : url.path,
                timestampsPath: timestampsURL?.path
            )
            let outputURL = outputFolder
                .appendingPathComponent(outputName)
                .appendingPathExtension(artifact.fileExtension)

            let fileJobContext = FileJobContext(
                jobKind: .watchFolder,
                sourceFilePath: url.path,
                outputDirectoryPath: outputFolder.path,
                outputFilePath: outputURL.path,
                outputFormat: artifact.fileExtension,
                engineId: engineId,
                engineName: engineName,
                modelId: modelId,
                transcriptText: result.text,
                detectedLanguage: result.detectedLanguage,
                segments: result.segments.map {
                    FileJobTranscriptSegment(
                        text: $0.text,
                        start: $0.start,
                        end: $0.end,
                        speakerLabel: $0.speakerLabel,
                        speakerConfidence: $0.speakerConfidence
                    )
                }
            )
            let automationResult = await fileJobAutomationPipeline.process(
                artifact: FileJobArtifact(fileExtension: artifact.fileExtension, content: artifact.content),
                context: fileJobContext
            )

            try automationResult.artifact.content.write(to: outputURL, atomically: true, encoding: .utf8)

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

        } catch is CancellationError {
            return
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
    }

    /// Writes `<file>.timestamps.json` next to the source file, or next to the output
    /// when the source is deleted afterwards or its folder cannot be written. Returns
    /// where it went, or nil without word timestamps.
    private func writeTimestampsFile(
        for url: URL,
        result: TranscriptionResult,
        modelId: String?,
        outputFolder: URL,
        keepsSource: Bool
    ) -> URL? {
        let data: Data
        do {
            guard let encoded = try TranscriptTimestampsFile.data(text: result.text, result: result, model: modelId) else {
                return nil
            }
            data = encoded
        } catch {
            logger.error("Failed to encode word timestamps: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        var candidates: [URL] = []
        if keepsSource { candidates.append(TranscriptTimestampsFile.url(besideAudio: url)) }
        let besideOutput = TranscriptTimestampsFile.url(besideAudio: outputFolder.appendingPathComponent(url.lastPathComponent))
        if !candidates.contains(besideOutput) { candidates.append(besideOutput) }
        for candidate in candidates {
            do {
                try data.write(to: candidate, options: .atomic)
                return candidate
            } catch {
                logger.error("Failed to write word timestamps: \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    // MARK: - Persistence

    private var processedFingerprintsURL: URL {
        appSupportDirectory.appendingPathComponent("watch-folder-processed.json")
    }

    private var processedHistoryURL: URL {
        appSupportDirectory.appendingPathComponent("watch-folder-history.json")
    }

    private func loadProcessedFileFingerprints() {
        guard let data = try? Data(contentsOf: processedFingerprintsURL),
              let fingerprints = try? JSONDecoder().decode(Set<String>.self, from: data) else { return }
        processedFileFingerprints = fingerprints
    }

    private func saveProcessedFileFingerprints() {
        let fm = FileManager.default
        let dir = appSupportDirectory
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

    func fileFingerprint(for url: URL) -> String? {
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: resourceKeys)

        let fileSize = values?.fileSize ?? 0
        let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0

        var checksum = "no-data"
        if let fileHandle = try? FileHandle(forReadingFrom: url) {
            var hasher = SHA256()
            while let data = try? fileHandle.read(upToCount: 8192), !data.isEmpty {
                hasher.update(data: data)
            }
            checksum = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
            try? fileHandle.close()
        }

        return "\(url.path)|\(fileSize)|\(modifiedAt)|\(checksum)"
    }
}
