import Foundation

enum AppVocabularyImport {
    enum Destination: Sendable {
        case dictionary, snippets
    }

    enum Source: String, CaseIterable, Identifiable, Sendable {
        case wisprFlow, handy, wisprCSV
        var id: String { rawValue }
        var name: String {
            switch self {
            case .wisprFlow: "Wispr Flow"
            case .handy: "Handy"
            case .wisprCSV: "CSV (Wispr Flow-compatible)"
            }
        }
        var defaultURL: URL? {
            defaultURL(in: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
            )
        }

        func defaultURL(in support: URL) -> URL? {
            switch self {
            case .wisprFlow: return support.appendingPathComponent("Wispr Flow/flow.sqlite")
            case .handy: return support.appendingPathComponent("com.pais.handy/settings_store.json")
            case .wisprCSV: return nil
            }
        }
    }

    /// Discovery checks only the two known paths, never the contents or app usage history.
    static func detectedSources(
        applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
    ) -> [Source] {
        [.wisprFlow, .handy].filter { source in
            guard let url = source.defaultURL(in: applicationSupport),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
            return attributes[.type] as? FileAttributeType == .typeRegular
        }
    }

    struct Entry: Equatable, Sendable {
        enum Kind: String, Sendable { case term, correction, snippet }
        let kind: Kind
        let original: String
        let replacement: String?

        func key(dictionaryLocale: Locale) -> String {
            // Dictionary comparisons use the current locale; snippet searches use no locale.
            let locale: Locale? = kind == .snippet ? nil : dictionaryLocale
            return kind.rawValue + ":" + original.folding(options: .caseInsensitive, locale: locale)
        }
    }

    struct Batch: Sendable {
        var entries: [Entry] = []
        var excluded = 0
    }

    struct Existing: Equatable, Sendable {
        let id: UUID
        let entry: Entry
        let caseSensitive: Bool
        let isEnabled: Bool
    }

    struct Review: Identifiable, Sendable {
        enum Outcome: Sendable { case add, duplicate, conflict }
        let id: Int
        let entry: Entry
        let outcome: Outcome
    }

    static let maximumRows = 25_000
    static let maximumTextBytes = 8 * 1024 * 1024

    static func review(_ batch: Batch, existing: [Existing], dictionaryLocale: Locale = .current) -> [Review] {
        var known: [String: [(replacement: String?, caseSensitive: Bool, isEnabled: Bool)]] = [:]
        for item in existing {
            known[item.entry.key(dictionaryLocale: dictionaryLocale), default: []].append((item.entry.replacement, item.caseSensitive, item.isEnabled))
        }
        return batch.entries.enumerated().map { index, entry in
            let outcome: Review.Outcome
            let key = entry.key(dictionaryLocale: dictionaryLocale)
            if let collisions = known[key] {
                outcome = collisions.allSatisfy {
                    $0.replacement == entry.replacement && !$0.caseSensitive && $0.isEnabled
                } ? .duplicate : .conflict
            } else {
                outcome = .add
                known[key] = [(entry.replacement, false, true)]
            }
            return Review(id: index, entry: entry, outcome: outcome)
        }
    }

    static func appendWisprWord(original: String, replacement: String?, to batch: inout Batch) {
        let phrase = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        let spelling = replacement.flatMap { $0.isEmpty ? nil : $0 } ?? phrase
        // Keep the recognition hint as well as the alternate-spelling correction.
        append(original: spelling, replacement: nil, destination: .dictionary, to: &batch)
        if spelling != phrase {
            append(original: phrase, replacement: spelling, destination: .dictionary, to: &batch)
        }
    }

    static func load(source: Source, url: URL, destination: Destination, csvHasHeader: Bool = false) throws -> Batch {
        switch source {
        case .wisprFlow:
            return try WisprFlowImportReader.read(url: url, destination: destination)
        case .handy:
            guard destination == .dictionary else { throw AppVocabularyImportError.invalidFormat }
            return try readHandy { try boundedData(url) }
        case .wisprCSV:
            return try parseCSV(boundedData(url), destination: destination, hasHeader: csvHasHeader)
        }
    }

    static func readHandy(read: () throws -> Data) throws -> Batch {
        // Handy rewrites its JSON in place. Only accept two identical, valid reads.
        for _ in 0..<3 {
            try Task.checkCancellation()
            let first = try read()
            let second = try read()
            if first == second {
                do { return try parseHandy(first) }
                catch AppVocabularyImportError.tooLarge { throw AppVocabularyImportError.tooLarge }
                // A truncated mid-write read is a prefix of valid JSON, so it
                // may settle into a parseable pair on retry. Undecodable input
                // that is not truncated is a stable invalid format.
                catch DecodingError.dataCorrupted where looksTruncated(first) { continue }
                catch is DecodingError { throw AppVocabularyImportError.invalidFormat }
                catch { continue }
            }
        }
        throw AppVocabularyImportError.unstableSource
    }

    /// Whether undecodable JSON looks like a prefix of valid JSON: it ends
    /// inside a string, with an unclosed bracket or brace, or right after a
    /// separator or opening bracket. Only such reads are worth retrying,
    /// since Handy may still be writing them; anything else that fails to
    /// parse cannot settle into a valid store.
    private static func looksTruncated(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty mid-write read never parses; treat it as still being written.
        guard let last = trimmed.last else { return true }
        // Input expecting more after a separator or opening bracket.
        if ",:[{".contains(last) { return true }
        var depth = 0
        var inString = false
        var escaped = false
        for char in trimmed {
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == "{" || char == "[" {
                depth += 1
            } else if char == "}" || char == "]" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        // An unterminated string or unclosed structure never finishes parsing.
        return inString || depth > 0
    }

    private static func boundedData(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumTextBytes + 1) ?? Data()
        guard data.count <= maximumTextBytes else { throw AppVocabularyImportError.tooLarge }
        return data
    }

    static func parseHandy(_ data: Data) throws -> Batch {
        guard data.count <= maximumTextBytes else { throw AppVocabularyImportError.tooLarge }
        struct Store: Decodable {
            struct Settings: Decodable { let custom_words: [String]? }
            let settings: Settings?
        }
        let store = try JSONDecoder().decode(Store.self, from: data)
        let words = store.settings?.custom_words ?? []
        guard words.count <= maximumRows else { throw AppVocabularyImportError.tooLarge }
        var batch = Batch()
        for word in words {
            append(original: word, replacement: nil, destination: .dictionary, to: &batch)
        }
        return batch
    }

    static func append(original: String, replacement: String?, destination: Destination, to batch: inout Batch) {
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReplacement = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, original.utf8.count <= 1_000,
              !original.contains("\0"), replacement?.contains("\0") != true,
              (replacement?.utf8.count ?? 0) <= 100_000 else {
            batch.excluded += 1
            return
        }
        if destination == .snippets {
            guard let replacement, normalizedReplacement?.isEmpty == false,
                  !containsDynamicPlaceholder(replacement) else {
                batch.excluded += 1
                return
            }
            // Preserve expansion whitespace, including multiline signatures.
            batch.entries.append(Entry(kind: .snippet, original: original, replacement: replacement))
        } else if let replacement = normalizedReplacement, !replacement.isEmpty, replacement != original {
            batch.entries.append(Entry(kind: .correction, original: original, replacement: replacement))
        } else {
            batch.entries.append(Entry(kind: .term, original: original, replacement: nil))
        }
    }

    private static func containsDynamicPlaceholder(_ text: String) -> Bool {
        // Foreign literal text must not unexpectedly read the clipboard or become a date.
        text.range(of: #"\{\{(?:DATE|TIME|DATETIME|CLIPBOARD)(?::[^}]*)?\}\}|\{(?:date|time|datetime)(?::[^}]*)?\}|\{(?:day|year|clipboard)\}"#,
                   options: .regularExpression) != nil
    }

    static func parseCSV(_ data: Data, destination: Destination, hasHeader: Bool = false) throws -> Batch {
        guard data.count <= maximumTextBytes else { throw AppVocabularyImportError.tooLarge }
        guard var text = String(data: data, encoding: .utf8) else { throw AppVocabularyImportError.invalidFormat }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // Normalize line endings before scanning; Swift treats CRLF as a single Character.
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closedQuote = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            if quoted {
                if char == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    quoted = false
                    closedQuote = true
                } else { field.append(char) }
            } else if char == "," || char == "\n" {
                row.append(field)
                field = ""
                closedQuote = false
                if char == "\n" {
                    rows.append(row)
                    row = []
                    guard rows.count <= maximumRows + 1 else { throw AppVocabularyImportError.tooLarge }
                }
            } else if char == "\"", field.isEmpty, !closedQuote {
                quoted = true
            } else {
                guard !closedQuote, char != "\"" else { throw AppVocabularyImportError.invalidFormat }
                field.append(char)
            }
            index = next
        }
        guard !quoted else { throw AppVocabularyImportError.invalidFormat }
        if !field.isEmpty || !row.isEmpty || closedQuote { rows.append(row + [field]) }
        // Cell contents cannot distinguish a header from a legitimate first entry.
        if hasHeader, !rows.isEmpty { rows.removeFirst() }
        guard rows.count <= maximumRows else { throw AppVocabularyImportError.tooLarge }
        var batch = Batch()
        for row in rows {
            if row.allSatisfy({ $0.isEmpty }) { continue }
            guard (1...2).contains(row.count) else { batch.excluded += 1; continue }
            append(original: row[0], replacement: row.count == 2 ? row[1] : nil, destination: destination, to: &batch)
        }
        return batch
    }
}

enum AppVocabularyImportError: LocalizedError {
    case invalidFormat, unstableSource, tooLarge, storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidFormat: String(localized: "This file does not have a supported import format.")
        case .unstableSource: String(localized: "The source could not be read safely. Quitting the source app and trying again may help. Nothing was imported.")
        case .tooLarge: String(localized: "The source exceeds the import limits. Nothing was imported.")
        case .storageUnavailable: String(localized: "The import could not be saved. Nothing was imported.")
        }
    }
}
