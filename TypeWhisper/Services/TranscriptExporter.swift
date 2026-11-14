import AppKit
import os
import UniformTypeIdentifiers

private let transcriptExporterLogger = Logger(subsystem: AppConstants.loggerSubsystem, category: "TranscriptExporter")

/// The file formats a finished file transcription can be saved as.
enum TranscriptExportFormat: String, CaseIterable {
    case plainText = "txt"
    case markdown = "md"
    case srt
    case vtt

    var fileExtension: String { rawValue }

    var utType: UTType {
        switch self {
        case .plainText: .plainText
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .srt: SubtitleFormat.srt.utType
        case .vtt: SubtitleFormat.vtt.utType
        }
    }

    var displayName: String {
        switch self {
        case .plainText: String(localized: "Plain Text (.txt)")
        case .markdown: String(localized: "Markdown (.md)")
        case .srt: String(localized: "SRT")
        case .vtt: String(localized: "VTT")
        }
    }

    var subtitleFormat: SubtitleFormat? {
        switch self {
        case .srt: .srt
        case .vtt: .vtt
        case .plainText, .markdown: nil
        }
    }
}

enum TranscriptExporter {

    /// The file content for `result`, or nil when there is nothing to save.
    /// `audioPath` goes into the Markdown's frontmatter, as for Watch Folder exports.
    static func exportContent(
        for result: TranscriptionResult,
        format: TranscriptExportFormat,
        fileName: String,
        engineName: String,
        date: Date,
        audioPath: String? = nil
    ) -> String? {
        if let subtitleFormat = format.subtitleFormat {
            return SubtitleExporter.exportContent(for: result, format: subtitleFormat)
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        switch format {
        case .markdown:
            return TranscriptMarkdown.render(
                result: result,
                title: "Transcription: \(fileName)",
                engineName: engineName,
                date: date,
                audioPath: audioPath,
                timestampsPath: nil
            )
        case .plainText, .srt, .vtt:
            return text
        }
    }

    /// `baseName.fileExtension` in `folder`, or `baseName 2.fileExtension` and so
    /// on when that file exists, so an automatic save never replaces a file.
    static func availableURL(in folder: URL, baseName: String, fileExtension: String) -> URL {
        let fileManager = FileManager.default
        var candidate = folder.appendingPathComponent("\(baseName).\(fileExtension)")
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(number).\(fileExtension)")
            number += 1
        }
        return candidate
    }

    @MainActor
    @discardableResult
    static func saveToFile(content: String, format: TranscriptExportFormat, suggestedName: String) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        return writeContent(content, to: url, suggestedName: suggestedName)
    }

    @discardableResult
    static func writeContent(_ content: String, to url: URL, suggestedName: String) -> Bool {
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            transcriptExporterLogger.error(
                "Failed to export transcript '\(suggestedName, privacy: .private(mask: .hash))' to \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
