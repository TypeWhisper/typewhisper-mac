import Foundation

/// Produces bounded, human-readable summaries for HTTP error response bodies.
public enum PluginHTTPErrorBodyFormatter {
    static let maximumTextCharacters = 512
    static let maximumTitleCharacters = 160
    static let sniffByteLimit = 4_096

    public static func summary(from data: Data, response: HTTPURLResponse) -> String {
        summary(
            from: data,
            contentType: response.value(forHTTPHeaderField: "Content-Type")
        )
    }

    public static func summary(from data: Data, contentType: String?) -> String {
        guard !data.isEmpty else {
            return "upstream returned an empty error body"
        }

        guard let head = decodedHead(from: data) else {
            return "upstream returned non-UTF-8 error data (\(data.count) bytes)"
        }

        let trimmedHead = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstCharacter = trimmedHead.first else {
            return "upstream returned an empty error body (\(data.count) bytes)"
        }

        if firstCharacter == "{" || firstCharacter == "[" {
            return boundedTextSummary(trimmedHead, totalByteCount: data.count, headWasTruncated: data.count > sniffByteLimit)
        }

        if firstCharacter == "<", isHTMLPage(trimmedHead: trimmedHead, contentType: contentType) {
            var message = "upstream returned an HTML error page (\(data.count) bytes)"
            if let title = htmlTitle(in: trimmedHead) {
                message += ": \(title)"
            }
            return message
        }

        return boundedTextSummary(trimmedHead, totalByteCount: data.count, headWasTruncated: data.count > sniffByteLimit)
    }

    static func isHTMLPage(data: Data, response: HTTPURLResponse) -> Bool {
        guard let head = decodedHead(from: data) else { return false }
        let trimmedHead = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHead.first == "<" else { return false }
        return isHTMLPage(
            trimmedHead: trimmedHead,
            contentType: response.value(forHTTPHeaderField: "Content-Type")
        )
    }

    private static func decodedHead(from data: Data) -> String? {
        var prefix = Data(data.prefix(sniffByteLimit))
        for _ in 0...3 {
            if let decoded = String(data: prefix, encoding: .utf8) {
                return decoded
            }
            guard !prefix.isEmpty else { break }
            prefix.removeLast()
        }
        return nil
    }

    private static func isHTMLPage(trimmedHead: String, contentType: String?) -> Bool {
        if mimeType(from: contentType) == "text/html" {
            return true
        }

        let lowercasedHead = trimmedHead.lowercased()
        return containsTagPrefix("<!doctype html", in: lowercasedHead)
            || containsTagPrefix("<html", in: lowercasedHead)
    }

    private static func mimeType(from contentType: String?) -> String? {
        contentType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func containsTagPrefix(_ prefix: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: prefix, range: searchStart..<text.endIndex) {
            if isTagBoundary(text[range.upperBound...].first) {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func htmlTitle(in head: String) -> String? {
        guard let openingTag = tagRange(prefix: "<title", in: head),
              let openingTagEnd = head[openingTag.upperBound...].firstIndex(of: ">") else {
            return nil
        }

        let contentStart = head.index(after: openingTagEnd)
        guard contentStart < head.endIndex,
              let closingTag = tagRange(
                prefix: "</title",
                in: head,
                range: contentStart..<head.endIndex
              ) else {
            return nil
        }

        let title = String(head[contentStart..<closingTag.lowerBound])
        let normalizedTitle = normalizedSingleLine(strippingTags(from: title))
        guard !normalizedTitle.isEmpty else { return nil }
        return truncated(normalizedTitle, maximumCharacters: maximumTitleCharacters).text
    }

    private static func tagRange(
        prefix: String,
        in text: String,
        range: Range<String.Index>? = nil
    ) -> Range<String.Index>? {
        let searchRange = range ?? text.startIndex..<text.endIndex
        var searchStart = searchRange.lowerBound
        while searchStart < searchRange.upperBound,
              let candidate = text.range(
                of: prefix,
                options: .caseInsensitive,
                range: searchStart..<searchRange.upperBound
              ) {
            if isTagBoundary(text[candidate.upperBound...].first) {
                return candidate
            }
            searchStart = candidate.upperBound
        }
        return nil
    }

    private static func isTagBoundary(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character == ">" || character.isWhitespace
    }

    private static func strippingTags(from text: String) -> String {
        var result = ""
        var isInsideTag = false
        for character in text {
            if character == "<" {
                isInsideTag = true
                continue
            }
            if character == ">", isInsideTag {
                isInsideTag = false
                continue
            }
            if !isInsideTag {
                result.append(character)
            }
        }
        return decodeCommonHTMLEntities(in: result)
    }

    private static func decodeCommonHTMLEntities(in text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
    }

    private static func boundedTextSummary(
        _ text: String,
        totalByteCount: Int,
        headWasTruncated: Bool
    ) -> String {
        let normalizedText = normalizedSingleLine(text)
        guard !normalizedText.isEmpty else {
            return "upstream returned an empty error body (\(totalByteCount) bytes)"
        }

        let result = truncated(normalizedText, maximumCharacters: maximumTextCharacters)
        if result.wasTruncated || headWasTruncated {
            return "\(result.text)… (truncated from \(totalByteCount) bytes)"
        }
        return result.text
    }

    private static func normalizedSingleLine(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func truncated(
        _ text: String,
        maximumCharacters: Int
    ) -> (text: String, wasTruncated: Bool) {
        guard text.count > maximumCharacters else { return (text, false) }
        return (String(text.prefix(maximumCharacters)), true)
    }
}
