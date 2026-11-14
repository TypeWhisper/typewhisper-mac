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

    /// Writes `content` to `baseName.fileExtension` in `folder`, or to
    /// `baseName 2.fileExtension` and so on, and returns the file written, or nil.
    /// Each name is only created when no file has it yet, so no file is ever
    /// replaced, also not one another app creates while this one writes.
    @discardableResult
    static func writeNewFile(
        _ content: String,
        in folder: URL,
        baseName: String,
        fileExtension: String
    ) -> URL? {
        let data = Data(content.utf8)
        for number in 1...maximumFileNumber {
            let name = number == 1 ? "\(baseName).\(fileExtension)" : "\(baseName) \(number).\(fileExtension)"
            let url = folder.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                transcriptExporterLogger.error(
                    "Failed to export transcript '\(baseName, privacy: .private(mask: .hash))' to \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
        return nil
    }

    /// Stops `writeNewFile` in a folder that already holds this many files of one name.
    private static let maximumFileNumber = 10_000

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
