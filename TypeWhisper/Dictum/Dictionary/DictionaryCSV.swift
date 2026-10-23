import Foundation
import TabularData

enum DictionaryCSVFormat: String, CaseIterable, Identifiable {
    case wordFirst
    case wisprFlow
    var id: String { rawValue }
}

struct DictionaryCSVItem: Equatable {
    let original: String
    let replacement: String?
    var word: String { replacement ?? original }
    var identity: String { (replacement == nil ? "term:" : "correction:") + original.lowercased() }
}

struct DictionaryCSVResult {
    struct Rejection: Equatable {
        let row: Int
        let reason: String
    }
    var items: [DictionaryCSVItem] = []
    var duplicates = 0
    var rejected: [Rejection] = []
}

enum DictionaryCSVError: LocalizedError {
    case size, count, encoding
    var errorDescription: String? {
        switch self {
        case .size: String(localized: "File is too large (max 5 MB)", table: "DictumHistory")
        case .count: String(localized: "Import at most 3000 words at a time", table: "DictumHistory")
        case .encoding: String(localized: "Choose a UTF-8 CSV file", table: "DictumHistory")
        }
    }
}

enum DictionaryCSV {
    static let maximumBytes = 5_000_000
    static let maximumWords = 3000

    static func parse(_ data: Data, format: DictionaryCSVFormat, existing: Set<String> = []) throws -> DictionaryCSVResult {
        guard data.count <= maximumBytes else { throw DictionaryCSVError.size }
        guard var text = String(data: data, encoding: .utf8) else { throw DictionaryCSVError.encoding }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return DictionaryCSVResult() }
        let types: [String: CSVType] = ["Column 0": .string, "Column 1": .string]
        let options = CSVReadingOptions(hasHeaderRow: false, nilEncodings: [""], ignoresEmptyLines: true)
        var result = DictionaryCSVResult()
        let rows: [(Int, [String])]
        do {
            let frame = try DataFrame(csvData: Data(text.utf8), types: types, options: options)
            rows = frame.rows.enumerated().map { ($0.offset + 1, fields($0.element)) }
        } catch {
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            var parsed: [(Int, [String])] = []
            for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let frame = try DataFrame(csvData: Data(line.utf8), types: types, options: options)
                    if let row = frame.rows.first { parsed.append((index + 1, fields(row))) }
                } catch {
                    result.rejected.append(.init(row: index + 1, reason: error.localizedDescription))
                }
            }
            rows = parsed
        }
        guard rows.count + result.rejected.count <= maximumWords else { throw DictionaryCSVError.count }
        var seen = existing
        for (number, fields) in rows {
            guard !fields.isEmpty else { continue }
            guard fields.count <= 2 else {
                result.rejected.append(.init(row: number, reason: String(localized: "Expected one or two columns", table: "DictumHistory")))
                continue
            }
            let item: DictionaryCSVItem
            if fields.count == 1 {
                item = .init(original: fields[0], replacement: nil)
            } else if format == .wisprFlow {
                item = .init(original: fields[0], replacement: fields[1])
            } else {
                item = .init(original: fields[1], replacement: fields[0])
            }
            guard seen.insert(item.identity).inserted else { result.duplicates += 1; continue }
            result.items.append(item)
        }
        return result
    }

    private static func fields(_ row: DataFrame.Row) -> [String] {
        row.compactMap { value in
            guard let value else { return nil }
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    static func export(_ items: [DictionaryCSVItem]) throws -> Data {
        var frame = DataFrame()
        frame.append(column: Column<String>(name: "original", contents: items.map(\.original)))
        frame.append(column: Column<String>(name: "replacement", contents: items.map(\.replacement)))
        var options = CSVWritingOptions()
        options.includesHeader = false
        options.newline = "\r\n"
        return try frame.csvRepresentation(options: options)
    }
}
