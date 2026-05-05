import AppKit
import Foundation
import os

private let clipboardFormatterLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "ClipboardContentFormatter"
)

struct ClipboardContentPayload {
    struct Representation {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    let plainText: String
    let additionalRepresentations: [Representation]

    init(
        plainText: String,
        additionalRepresentations: [Representation] = []
    ) {
        self.plainText = plainText
        self.additionalRepresentations = additionalRepresentations
    }

    var requiresPasteboardInsertion: Bool {
        !additionalRepresentations.isEmpty
    }

    func write(to pasteboard: NSPasteboard) {
        guard !additionalRepresentations.isEmpty else {
            pasteboard.setString(plainText, forType: .string)
            return
        }

        let item = NSPasteboardItem()
        item.setString(plainText, forType: .string)
        for representation in additionalRepresentations {
            item.setData(representation.data, forType: representation.type)
        }
        pasteboard.writeObjects([item])
    }
}

enum ClipboardContentFormatter {
    static func payload(for text: String, outputFormat: String?) -> ClipboardContentPayload? {
        guard let format = ClipboardOutputFormat(outputFormat) else {
            return nil
        }

        switch format {
        case .richText:
            return RichTextClipboardContentFormatter.payload(for: text)
        }
    }

    static func requiresPasteboardInsertion(outputFormat: String?) -> Bool {
        guard let format = ClipboardOutputFormat(outputFormat) else {
            return false
        }

        return format.requiresPasteboardInsertion
    }
}

private enum ClipboardOutputFormat {
    case richText

    var requiresPasteboardInsertion: Bool {
        switch self {
        case .richText:
            return true
        }
    }

    init?(_ rawValue: String?) {
        guard let rawValue else { return nil }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rtf", "richtext", "rich text":
            self = .richText
        default:
            return nil
        }
    }
}

private enum RichTextClipboardContentFormatter {
    private static let emphasizedIntent = Int(InlinePresentationIntent.emphasized.rawValue)
    private static let stronglyEmphasizedIntent = Int(InlinePresentationIntent.stronglyEmphasized.rawValue)
    private static let codeIntent = Int(InlinePresentationIntent.code.rawValue)

    static func payload(for text: String) -> ClipboardContentPayload? {
        let source = richTextSource(from: text)
        let attributed = attributedString(from: source)
        let range = NSRange(location: 0, length: attributed.length)
        guard let rtfData = try? attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            clipboardFormatterLogger.warning("Failed to generate RTF pasteboard data")
            return nil
        }

        return ClipboardContentPayload(
            plainText: plainText(from: source),
            additionalRepresentations: [
                ClipboardContentPayload.Representation(type: .rtf, data: rtfData)
            ]
        )
    }

    private static func richTextSource(from text: String) -> String {
        let normalized = normalizeNewlines(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let source = extractFirstMarkdownFence(from: normalized) ?? normalized
        return removingTypeWhisperBoundaryMarkers(from: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractFirstMarkdownFence(from text: String) -> String? {
        let lines = normalizeNewlines(text).components(separatedBy: "\n")
        var fencedLines: [String] = []
        var isInsideFence = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isInsideFence {
                if trimmed == "```" {
                    return fencedLines.joined(separator: "\n")
                }
                fencedLines.append(line)
                continue
            }

            guard trimmed.hasPrefix("```") else { continue }
            let language = String(trimmed.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard language.isEmpty || language == "markdown" || language == "md" else { continue }
            isInsideFence = true
        }

        return nil
    }

    private static func removingTypeWhisperBoundaryMarkers(from text: String) -> String {
        normalizeNewlines(text)
            .components(separatedBy: "\n")
            .filter { line in
                let normalizedLine = line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                return normalizedLine != "BEGIN TYPEWHISPER DICTATED TEXT"
                    && normalizedLine != "END TYPEWHISPER DICTATED TEXT"
            }
            .joined(separator: "\n")
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func attributedString(from text: String) -> NSAttributedString {
        markdownAttributedString(from: richTextMarkdown(from: text))
    }

    private static func plainText(from text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                if let item = listItem(from: line) {
                    return item.plainPrefix + markdownPlainText(from: item.content)
                }
                return markdownPlainText(from: line)
            }
            .joined(separator: "\n")
    }

    private static func richTextMarkdown(from text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                guard let item = listItem(from: line) else {
                    return line
                }
                return item.richPrefix + item.content
            }
            .joined(separator: "\n")
    }

    private static func markdownPlainText(from text: String) -> String {
        markdownAttributedString(from: text).string
    }

    private static func markdownAttributedString(from text: String) -> NSAttributedString {
        do {
            let parsed = try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
            let attributed = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
            applyDisplayFonts(to: attributed)
            return attributed
        } catch {
            clipboardFormatterLogger.warning(
                "Failed to parse Markdown for RTF clipboard content: \(error.localizedDescription, privacy: .public)"
            )
            return NSAttributedString(string: text, attributes: baseAttributes())
        }
    }

    private static func applyDisplayFonts(to attributed: NSMutableAttributedString) {
        let range = NSRange(location: 0, length: attributed.length)
        guard range.length > 0 else { return }

        attributed.addAttributes(baseAttributes(), range: range)
        attributed.enumerateAttribute(.inlinePresentationIntent, in: range) { value, intentRange, _ in
            guard let rawIntent = inlinePresentationIntentRawValue(from: value) else {
                return
            }

            attributed.addAttributes(
                attributes(
                    isBold: rawIntent & stronglyEmphasizedIntent != 0,
                    isItalic: rawIntent & emphasizedIntent != 0,
                    isCode: rawIntent & codeIntent != 0
                ),
                range: intentRange
            )
        }
    }

    private static func inlinePresentationIntentRawValue(from value: Any?) -> Int? {
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? InlinePresentationIntent {
            return Int(value.rawValue)
        }
        if let value = value as? Int {
            return value
        }
        return nil
    }

    private static func listItem(from line: String) -> (richPrefix: String, plainPrefix: String, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return ("\u{2022} ", "- ", String(trimmed.dropFirst(2)))
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("bullet ") {
            return ("\u{2022} ", "- ", String(trimmed.dropFirst(7)))
        }

        guard let markerRange = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) else {
            return nil
        }

        let marker = String(trimmed[markerRange]).replacingOccurrences(of: ")", with: ".")
        let content = String(trimmed[markerRange.upperBound...])
        return (marker, marker, content)
    }

    private static func baseAttributes() -> [NSAttributedString.Key: Any] {
        attributes(isBold: false, isItalic: false, isCode: false)
    }

    private static func attributes(isBold: Bool, isItalic: Bool, isCode: Bool) -> [NSAttributedString.Key: Any] {
        let baseFont = isCode
            ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var font = baseFont
        let fontManager = NSFontManager.shared

        if isBold {
            font = fontManager.convert(font, toHaveTrait: .boldFontMask)
        }
        if isItalic {
            font = fontManager.convert(font, toHaveTrait: .italicFontMask)
        }

        return [.font: font]
    }
}
