import Foundation
import SwiftData
import AppKit

@Model
final class Snippet {
    var id: UUID
    var trigger: String
    var replacement: String
    var caseSensitive: Bool
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date?
    var usageCount: Int

    init(
        id: UUID = UUID(),
        trigger: String,
        replacement: String,
        caseSensitive: Bool = false,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        usageCount: Int = 0
    ) {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.usageCount = usageCount
    }

    var effectiveUpdatedAt: Date {
        updatedAt ?? createdAt
    }

    /// Process replacement text, expanding placeholders like {{DATE}}, {{TIME}}, {{CLIPBOARD}}
    func processedReplacement() -> String {
        var result = replacement

        result = processPlaceholder(in: result, placeholder: "DATE") { format in
            let formatter = DateFormatter()
            if let format = format {
                formatter.dateFormat = format
            } else {
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
            }
            return formatter.string(from: Date())
        }

        result = processPlaceholder(in: result, placeholder: "TIME") { format in
            let formatter = DateFormatter()
            if let format = format {
                formatter.dateFormat = format
            } else {
                formatter.dateStyle = .none
                formatter.timeStyle = .short
            }
            return formatter.string(from: Date())
        }

        result = processPlaceholder(in: result, placeholder: "DATETIME") { format in
            let formatter = DateFormatter()
            if let format = format {
                formatter.dateFormat = format
            } else {
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
            }
            return formatter.string(from: Date())
        }

        result = processBracePlaceholder(in: result, placeholder: "date") { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format ?? "yyyy-MM-dd"
            return formatter.string(from: Date())
        }

        result = processBracePlaceholder(in: result, placeholder: "time") { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format ?? "HH:mm"
            return formatter.string(from: Date())
        }

        result = processBracePlaceholder(in: result, placeholder: "datetime") { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format ?? "yyyy-MM-dd HH:mm"
            return formatter.string(from: Date())
        }

        let now = Date()
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE"
        result = result.replacingOccurrences(of: "{day}", with: dayFormatter.string(from: now))
        result = result.replacingOccurrences(of: "{year}", with: Calendar.current.component(.year, from: now).description)

        if result.contains("{{CLIPBOARD}}") {
            let pasteboard = NSPasteboard.general
            let clipboardContent = pasteboard.string(forType: .string) ?? ""
            result = result.replacingOccurrences(of: "{{CLIPBOARD}}", with: clipboardContent)
        }

        if result.contains("{clipboard}") {
            let pasteboard = NSPasteboard.general
            let clipboardContent = pasteboard.string(forType: .string) ?? ""
            result = result.replacingOccurrences(of: "{clipboard}", with: clipboardContent)
        }

        return result
    }

    private func processPlaceholder(
        in text: String,
        placeholder: String,
        handler: (String?) -> String
    ) -> String {
        var result = text

        let pattern = "\\{\\{\(placeholder)(?::([^}]+))?\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return result
        }

        let range = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: range).reversed()

        for match in matches {
            let fullRange = Range(match.range, in: result)!
            var format: String? = nil

            if match.numberOfRanges > 1, let formatRange = Range(match.range(at: 1), in: result) {
                format = String(result[formatRange])
            }

            let replacement = handler(format)
            result.replaceSubrange(fullRange, with: replacement)
        }

        return result
    }

    private func processBracePlaceholder(
        in text: String,
        placeholder: String,
        handler: (String?) -> String
    ) -> String {
        var result = text

        let pattern = "\\{\(placeholder)(?::([^}]+))?\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return result
        }

        let range = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: range).reversed()

        for match in matches {
            let fullRange = Range(match.range, in: result)!
            var format: String? = nil

            if match.numberOfRanges > 1, let formatRange = Range(match.range(at: 1), in: result) {
                format = String(result[formatRange])
            }

            let replacement = handler(format)
            result.replaceSubrange(fullRange, with: replacement)
        }

        return result
    }
}
