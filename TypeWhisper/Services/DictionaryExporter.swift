import AppKit
import UniformTypeIdentifiers

enum DictionaryExporter {

    struct ParsedEntry {
        let type: DictionaryEntryType
        let original: String
        let replacement: String?
        let caseSensitive: Bool
        let isEnabled: Bool
        let ctcMinSimilarity: Float?
        let source: DictionaryEntrySource
    }

    struct ImportResult {
        let imported: Int
        let skipped: Int
    }

    // MARK: - Export

    static func exportJSON(_ entries: [DictionaryEntry]) -> String {
        let dicts: [[String: Any]] = entries.map { entry in
            var dict: [String: Any] = [
                "type": entry.type.rawValue,
                "original": entry.original,
                "caseSensitive": entry.caseSensitive,
                "isEnabled": entry.isEnabled
            ]
            if let replacement = entry.replacement {
                dict["replacement"] = replacement
            }
            if entry.type == .term, let ctcMinSimilarity = entry.ctcMinSimilarity {
                dict["ctcMinSimilarity"] = ctcMinSimilarity
            }
            if entry.type == .correction, entry.source == .autoLearned {
                dict["source"] = entry.source.rawValue
            }
            return dict
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: dicts,
            options: [.prettyPrinted, .sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    @MainActor
    static func saveToFile(_ entries: [DictionaryEntry]) {
        let content = exportJSON(entries)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "dictionary-export.json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Import

    static func parseJSON(_ data: Data) throws -> [ParsedEntry] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DictionaryImportError.invalidFormat
        }

        return try array.map { dict in
            guard let original = dict["original"] as? String, !original.isEmpty else {
                throw DictionaryImportError.missingRequiredField("original")
            }

            let typeString = dict["type"] as? String ?? "term"
            let type = DictionaryEntryType(rawValue: typeString) ?? .term
            let replacement: String?

            if type == .correction {
                guard let correctionReplacement = dict["replacement"] as? String else {
                    throw DictionaryImportError.missingRequiredField("replacement")
                }
                replacement = correctionReplacement
            } else {
                replacement = nil
            }

            return ParsedEntry(
                type: type,
                original: original,
                replacement: replacement,
                caseSensitive: dict["caseSensitive"] as? Bool ?? false,
                isEnabled: dict["isEnabled"] as? Bool ?? true,
                ctcMinSimilarity: type == .term ? parseOptionalFloat(
                    dict["ctcMinSimilarity"] ?? dict["ctc_min_similarity"]
                ) : nil,
                source: type == .correction
                    ? DictionaryEntrySource.source(for: dict["source"] as? String)
                    : .manual
            )
        }
    }

    @MainActor
    static func importEntries(_ parsed: [ParsedEntry], into service: DictionaryService) -> ImportResult {
        let before = service.entries.count

        let items = parsed.map {
            (type: $0.type, original: $0.original, replacement: $0.replacement,
             caseSensitive: $0.caseSensitive, isEnabled: $0.isEnabled,
             ctcMinSimilarity: $0.ctcMinSimilarity, source: $0.source)
        }
        service.importEntries(items)

        let after = service.entries.count
        let imported = after - before
        return ImportResult(imported: imported, skipped: parsed.count - imported)
    }

    private static func parseOptionalFloat(_ rawValue: Any?) -> Float? {
        switch rawValue {
        case let value as Float:
            return value.isFinite ? min(max(value, 0), 1) : nil
        case let value as Double:
            guard value.isFinite else { return nil }
            return Float(min(max(value, 0), 1))
        case let value as Int:
            return Float(min(max(value, 0), 1))
        default:
            return nil
        }
    }
}

enum DictionaryImportError: LocalizedError {
    case invalidFormat
    case missingRequiredField(String)
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return String(localized: "The file is not a valid dictionary JSON file.")
        case .missingRequiredField(let field):
            return String(localized: "Missing required field: \(field)")
        case .emptyFile:
            return String(localized: "The file contains no dictionary entries.")
        }
    }
}
