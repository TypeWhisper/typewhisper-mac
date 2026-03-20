import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "AppFormatterService")

@MainActor
final class AppFormatterService {
    // Known app mappings for "auto" mode
    private static let autoMappings: [String: String] = [
        // Markdown apps
        "md.obsidian": "markdown",
        "notion.id": "markdown",
        "com.github.marktext": "markdown",
        "com.typora.Typora": "markdown",
        "com.bear.Bear": "markdown",
        "com.ulyssesapp.mac": "markdown",

        // HTML apps (email clients)
        "com.apple.mail": "html",
        "com.microsoft.Outlook": "html",
        "com.google.Chrome.app.mail": "html",

        // Code editors
        "com.apple.dt.Xcode": "code",
        "com.microsoft.VSCode": "code",
        "com.todesktop.230313mzl4w4u92": "code", // Cursor
        "dev.zed.Zed": "code",
        "com.sublimetext.4": "code",
        "com.jetbrains.intellij": "code",
        "com.googlecode.iterm2": "code",
        "com.apple.Terminal": "code",
    ]

    func format(text: String, bundleId: String?, outputFormat: String?) -> String {
        guard let outputFormat, !outputFormat.isEmpty else {
            return text
        }

        let resolvedFormat: String
        if outputFormat == "auto" {
            resolvedFormat = Self.resolveAutoFormat(bundleId: bundleId)
        } else {
            resolvedFormat = outputFormat
        }

        logger.debug("Formatting text as '\(resolvedFormat)' for bundleId=\(bundleId ?? "nil")")

        switch resolvedFormat {
        case "markdown":
            return formatAsMarkdown(text)
        case "html":
            return formatAsHTML(text)
        case "code", "plaintext":
            return text
        default:
            return text
        }
    }

    // MARK: - Private

    private static func resolveAutoFormat(bundleId: String?) -> String {
        guard let bundleId else { return "plaintext" }
        return autoMappings[bundleId] ?? "plaintext"
    }

    private func formatAsMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Convert bullet-like lines to markdown list items
            if let bulletContent = extractBulletContent(trimmed) {
                result.append("- " + bulletContent)
            } else {
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
    }

    private func formatAsHTML(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var inList = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                if inList {
                    result.append("</ul>")
                    inList = false
                }
                continue
            }

            if let bulletContent = extractBulletContent(trimmed) {
                if !inList {
                    result.append("<ul>")
                    inList = true
                }
                let escaped = escapeHTML(bulletContent)
                result.append("<li>\(escaped)</li>")
            } else {
                if inList {
                    result.append("</ul>")
                    inList = false
                }
                let escaped = escapeHTML(trimmed)
                result.append("<p>\(escaped)</p>")
            }
        }

        if inList {
            result.append("</ul>")
        }

        return result.joined(separator: "\n")
    }

    /// Detects bullet-like patterns and returns the content without the bullet marker.
    /// Matches: "- text", "* text", "bullet text" (dictated "bullet" prefix)
    private func extractBulletContent(_ line: String) -> String? {
        if line.hasPrefix("- ") {
            return String(line.dropFirst(2))
        }
        if line.hasPrefix("* ") {
            return String(line.dropFirst(2))
        }
        let lower = line.lowercased()
        if lower.hasPrefix("bullet ") {
            return String(line.dropFirst(7))
        }
        return nil
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
