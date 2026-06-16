import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "AppFormatterService")

enum WorkflowOutputFormatResolver {
    static let automaticFormat = "auto"
    static let plainTextFormat = "plaintext"

    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
        "org.mozilla.firefox",
    ]

    private static let nativeAppMappings: [String: String] = [
        // Rich-text document apps
        "com.apple.iWork.Pages": "rtf",
        "com.microsoft.Word": "rtf",
        "com.apple.TextEdit": "rtf",

        // Markdown apps
        "md.obsidian": "markdown",
        "notion.id": "markdown",
        "com.github.marktext": "markdown",
        "com.typora.Typora": "markdown",
        "com.bear.Bear": "markdown",
        "com.ulyssesapp.mac": "markdown",

        // HTML apps and web app bundles
        "com.apple.mail": "html",
        "com.microsoft.Outlook": "html",
        "com.google.Chrome.app.mail": "html",

        // Code editors and terminals
        "com.apple.dt.Xcode": "code",
        "com.microsoft.VSCode": "code",
        "com.todesktop.230313mzl4w4u92": "code",
        "dev.zed.Zed": "code",
        "com.sublimetext.4": "code",
        "com.jetbrains.intellij": "code",
        "com.googlecode.iterm2": "code",
        "com.apple.Terminal": "code",
    ]

    static func resolvedFormat(
        storedFormat: String?,
        bundleIdentifier: String?,
        url: String? = nil,
        // Reserved for future AX role hints; current auto detection stays deterministic by app and URL.
        accessibilityRole _: String? = nil
    ) -> String? {
        guard let storedFormat = trimmedNonEmpty(storedFormat) else {
            return nil
        }

        guard isAutomaticFormat(storedFormat) else {
            return storedFormat
        }

        return resolvedAutomaticFormat(bundleIdentifier: bundleIdentifier, url: url)
    }

    static func isAutomaticFormat(_ format: String?) -> Bool {
        normalized(format) == automaticFormat
    }

    static func normalized(_ format: String?) -> String? {
        trimmedNonEmpty(format)?.lowercased()
    }

    static func resolvedAutomaticFormat(bundleIdentifier: String?, url: String? = nil) -> String {
        if let bundleIdentifier,
           let nativeFormat = nativeAppMappings[bundleIdentifier] {
            return nativeFormat
        }

        guard let bundleIdentifier,
              browserBundleIdentifiers.contains(bundleIdentifier) else {
            return plainTextFormat
        }

        guard let host = host(from: url) else {
            return plainTextFormat
        }

        // Initial browser coverage is intentionally narrow; extend this list after validating more web editors.
        switch host {
        case "docs.google.com":
            return "rtf"
        case "mail.google.com":
            return "html"
        default:
            return plainTextFormat
        }
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func host(from rawURL: String?) -> String? {
        guard let trimmed = trimmedNonEmpty(rawURL) else { return nil }
        let componentSource = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URLComponents(string: componentSource)?.host?.lowercased()
    }
}

@MainActor
final class AppFormatterService {
    func format(text: String, bundleId: String?, url: String? = nil, outputFormat: String?) -> String {
        guard let outputFormat, !outputFormat.isEmpty else {
            return text
        }

        let normalizedOutputFormat = outputFormat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedFormat: String
        if WorkflowOutputFormatResolver.isAutomaticFormat(normalizedOutputFormat) {
            resolvedFormat = WorkflowOutputFormatResolver.resolvedAutomaticFormat(
                bundleIdentifier: bundleId,
                url: url
            )
        } else {
            resolvedFormat = normalizedOutputFormat
        }

        logger.debug("Formatting text as '\(resolvedFormat)' for bundleId=\(bundleId ?? "nil")")

        switch resolvedFormat {
        case "markdown":
            return formatAsMarkdown(text)
        case "html":
            return formatAsHTML(text)
        case "code", "plaintext", "plain text", "rtf", "richtext", "rich text":
            return text
        default:
            return text
        }
    }

    // MARK: - Private

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
