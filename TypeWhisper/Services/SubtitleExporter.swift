import AppKit
import os
import UniformTypeIdentifiers

private let subtitleExporterLogger = Logger(subsystem: AppConstants.loggerSubsystem, category: "SubtitleExporter")

enum SubtitleFormat: String, CaseIterable {
    case srt
    case vtt

    var fileExtension: String { rawValue }

    var utType: UTType {
        switch self {
        case .srt: UTType(filenameExtension: "srt") ?? .plainText
        case .vtt: UTType(filenameExtension: "vtt") ?? .plainText
        }
    }
}

enum SubtitleExporter {

    static func exportContent(for result: TranscriptionResult, format: SubtitleFormat) -> String? {
        let segments = subtitleSegments(for: result)
        guard !segments.isEmpty else { return nil }

        switch format {
        case .srt:
            return exportSRT(segments: segments)
        case .vtt:
            return exportVTT(segments: segments)
        }
    }

    static func exportSRT(segments: [TranscriptionSegment]) -> String {
        segments.enumerated().map { index, segment in
            let start = formatSRTTime(segment.start)
            let end = formatSRTTime(segment.end)
            return "\(index + 1)\n\(start) --> \(end)\n\(displayText(for: segment))"
        }.joined(separator: "\n\n")
    }

    static func exportVTT(segments: [TranscriptionSegment]) -> String {
        var lines = ["WEBVTT", ""]
        for (index, segment) in segments.enumerated() {
            let start = formatVTTTime(segment.start)
            let end = formatVTTTime(segment.end)
            lines.append("\(index + 1)")
            lines.append("\(start) --> \(end)")
            lines.append(displayText(for: segment))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    @discardableResult
    static func saveToFile(content: String, format: SubtitleFormat, suggestedName: String) -> Bool {
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
            subtitleExporterLogger.error(
                "Failed to export subtitle '\(suggestedName, privacy: .private(mask: .hash))' to \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Time Formatting

    private static func subtitleSegments(for result: TranscriptionResult) -> [TranscriptionSegment] {
        guard result.segments.isEmpty else { return result.segments }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let endTime = result.duration.isFinite && result.duration > 0 ? result.duration : 1
        return [TranscriptionSegment(text: text, start: 0, end: endTime)]
    }

    private static func displayText(for segment: TranscriptionSegment) -> String {
        guard let speakerLabel = segment.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !speakerLabel.isEmpty else {
            return segment.text
        }

        let trimmedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.hasPrefix("\(speakerLabel):") {
            return segment.text
        }
        return "\(speakerLabel): \(segment.text)"
    }

    private static func formatSRTTime(_ time: TimeInterval) -> String {
        formatTime(time, millisecondSeparator: ",")
    }

    private static func formatVTTTime(_ time: TimeInterval) -> String {
        formatTime(time, millisecondSeparator: ".")
    }

    /// The largest time with two-digit hours, 99:59:59.999.
    private static let maximumMilliseconds = 359_999_999.0

    /// Rounds to whole milliseconds before splitting the time. 18.72 is
    /// 18.7199… as a Double; truncating it wrote 18.719, a millisecond before
    /// the end of the previous cue. The value is clamped first because
    /// `Int(_:)` traps on NaN, infinity and out-of-range values.
    private static func formatTime(_ time: TimeInterval, millisecondSeparator: String) -> String {
        let rounded = (time * 1000).rounded()
        let totalMilliseconds = rounded.isNaN
            ? 0
            : Int(min(max(rounded, 0), maximumMilliseconds))
        let hours = totalMilliseconds / 3_600_000
        let minutes = totalMilliseconds / 60_000 % 60
        let seconds = totalMilliseconds / 1000 % 60
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, millisecondSeparator, milliseconds)
    }
}
