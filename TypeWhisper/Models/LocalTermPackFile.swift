import Foundation

/// A term pack file in the format of the community registry (`termpacks/*.json`), so a local
/// pack can later be submitted there unchanged. Local packs are imported and exported by the
/// user and stay on this Mac: TypeWhisper does not review, sync or update them.
///
/// Validation follows `scripts/assemble_termpacks.py` (required metadata, a numeric dotted
/// version, terms or corrections, no duplicates) and adds two rules of its own: the ID uses
/// lowercase letters, digits and hyphens, and a correction original appears only once, because
/// the dictionary keeps one correction per original.
struct LocalTermPackFile: Equatable {
    static let maximumFileSize = 2 * 1024 * 1024
    static let maximumIDLength = 64

    let id: String
    let name: String
    let description: String
    let icon: String
    let version: String
    let author: String
    let terms: [String]
    let corrections: [TermPackCorrection]
    let names: [String: String]?
    let descriptions: [String: String]?

    var termPack: TermPack {
        TermPack(
            id: id,
            name: name,
            description: description,
            icon: icon,
            terms: terms,
            corrections: corrections,
            version: version,
            author: author,
            localizedNames: names,
            localizedDescriptions: descriptions,
            source: .local
        )
    }

    /// Pretty-printed JSON with sorted keys and a trailing newline, readable and stable across exports.
    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    // MARK: - Parsing

    /// Parses and validates one pack. Collisions with other packs are checked by the caller.
    static func decode(_ data: Data) throws -> LocalTermPackFile {
        guard data.count <= maximumFileSize else { throw LocalTermPackError.fileTooLarge }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: withoutByteOrderMark(data), options: [.fragmentsAllowed])
        } catch {
            throw LocalTermPackError.malformedJSON
        }
        guard let fields = object as? [String: Any] else {
            throw object is [Any] ? LocalTermPackError.listInsteadOfPack : LocalTermPackError.notATermPack
        }

        let id = try requiredString("id", in: fields, trimmed: false)
        guard isValidID(id) else { throw LocalTermPackError.invalidID(id) }
        let name = try requiredString("name", in: fields)
        let description = try requiredString("description", in: fields)
        let icon = try requiredString("icon", in: fields)
        let version = try requiredString("version", in: fields)
        guard isValidVersion(version) else { throw LocalTermPackError.invalidVersion(version) }
        let author = try requiredString("author", in: fields)
        let names = try localizedTexts("names", in: fields)
        let descriptions = try localizedTexts("descriptions", in: fields)
        let terms = try parseTerms(fields["terms"])
        let corrections = try parseCorrections(fields["corrections"])
        guard !terms.isEmpty || !corrections.isEmpty else { throw LocalTermPackError.emptyPack(name) }

        return LocalTermPackFile(
            id: id,
            name: name,
            description: description,
            icon: icon,
            version: version,
            author: author,
            terms: terms,
            corrections: corrections,
            names: names,
            descriptions: descriptions
        )
    }

    /// Lowercase ASCII letters and digits in hyphen-separated groups, like `rust-dev`.
    static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= maximumIDLength else { return false }
        return id.split(separator: "-", omittingEmptySubsequences: false).allSatisfy { group in
            !group.isEmpty && group.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
    }

    /// At least two dot-separated groups of digits, as the registry requires (`1.0`, `1.2.3`).
    static func isValidVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        }
    }

    private static func withoutByteOrderMark(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
    }

    private static func requiredString(_ key: String, in fields: [String: Any], trimmed: Bool = true) throws -> String {
        guard let value = fields[key], !(value is NSNull) else { throw LocalTermPackError.missingField(key) }
        guard let text = value as? String else { throw LocalTermPackError.invalidField(key) }
        let result = trimmed ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        guard !result.isEmpty else { throw LocalTermPackError.missingField(key) }
        return result
    }

    private static func localizedTexts(_ key: String, in fields: [String: Any]) throws -> [String: String]? {
        guard let value = fields[key], !(value is NSNull) else { return nil }
        guard let entries = value as? [String: Any] else { throw LocalTermPackError.invalidField(key) }
        var texts: [String: String] = [:]
        for (language, rawText) in entries {
            guard let text = rawText as? String else { throw LocalTermPackError.invalidField(key) }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                texts[language] = trimmedText
            }
        }
        return texts.isEmpty ? nil : texts
    }

    private static func parseTerms(_ value: Any?) throws -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        guard let items = value as? [Any] else { throw LocalTermPackError.invalidField("terms") }

        var terms: [String] = []
        var seenKeys = Set<String>()
        for (index, item) in items.enumerated() {
            guard let rawTerm = item as? String else { throw LocalTermPackError.invalidTerm(position: index + 1) }
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { throw LocalTermPackError.invalidTerm(position: index + 1) }
            guard seenKeys.insert(term.lowercased()).inserted else { throw LocalTermPackError.duplicateTerm(term) }
            terms.append(term)
        }
        return terms
    }

    private static func parseCorrections(_ value: Any?) throws -> [TermPackCorrection] {
        guard let value, !(value is NSNull) else { return [] }
        guard let items = value as? [Any] else { throw LocalTermPackError.invalidField("corrections") }

        var corrections: [TermPackCorrection] = []
        var seenOriginals = Set<String>()
        for (index, item) in items.enumerated() {
            let position = index + 1
            guard let fields = item as? [String: Any],
                  let rawOriginal = fields["original"] as? String,
                  let replacement = fields["replacement"] as? String else {
                throw LocalTermPackError.invalidCorrection(position: position)
            }
            let original = rawOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty else { throw LocalTermPackError.invalidCorrection(position: position) }

            // Same default as `TermPackCorrection`; exports always write the value.
            let caseSensitive: Bool
            switch fields["caseSensitive"] {
            case nil, is NSNull:
                caseSensitive = true
            case let value as Bool:
                caseSensitive = value
            default:
                throw LocalTermPackError.invalidCorrection(position: position)
            }

            guard seenOriginals.insert(original.lowercased()).inserted else {
                throw LocalTermPackError.duplicateCorrection(original)
            }
            corrections.append(TermPackCorrection(
                original: original,
                replacement: replacement,
                caseSensitive: caseSensitive
            ))
        }
        return corrections
    }
}

extension LocalTermPackFile: Encodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, description, names, descriptions, icon, version, author, terms, corrections
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(names, forKey: .names)
        try container.encodeIfPresent(descriptions, forKey: .descriptions)
        try container.encode(icon, forKey: .icon)
        try container.encode(version, forKey: .version)
        try container.encode(author, forKey: .author)
        // Registry files leave out the list a pack does not use.
        if !terms.isEmpty {
            try container.encode(terms, forKey: .terms)
        }
        if !corrections.isEmpty {
            try container.encode(corrections, forKey: .corrections)
        }
    }
}

// MARK: - Errors

enum LocalTermPackError: LocalizedError, Equatable {
    case unreadableFile
    case fileTooLarge
    case malformedJSON
    case listInsteadOfPack
    case notATermPack
    case missingField(String)
    case invalidField(String)
    case invalidID(String)
    case invalidVersion(String)
    case invalidTerm(position: Int)
    case duplicateTerm(String)
    case invalidCorrection(position: Int)
    case duplicateCorrection(String)
    case emptyPack(String)
    case builtInID(String)
    case communityID(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return String(localized: "The file could not be read.")
        case .fileTooLarge:
            return String(localized: "The file is larger than 2 MB, which is too large for a term pack.")
        case .malformedJSON:
            return String(localized: "The file is not valid JSON.")
        case .listInsteadOfPack:
            return String(localized: "The file contains a list instead of a term pack. To import a dictionary export, use Import... in the Dictionary actions menu.")
        case .notATermPack:
            return String(localized: "The file is not a term pack. A term pack is a JSON object with an id, a name, metadata and terms or corrections.")
        case .missingField(let field):
            return String(localized: "The required field “\(field)” is missing or empty.")
        case .invalidField(let field):
            return String(localized: "The field “\(field)” has the wrong format.")
        case .invalidID(let id):
            let id = Self.clipped(id)
            return String(localized: "The id “\(id)” is not valid. Use lowercase letters, numbers and hyphens, for example “my-team-terms”.")
        case .invalidVersion(let version):
            let version = Self.clipped(version)
            return String(localized: "The version “\(version)” is not valid. Use numbers separated by dots, for example “1.0.0”.")
        case .invalidTerm(let position):
            return String(localized: "Term \(position) is empty or not text.")
        case .duplicateTerm(let term):
            let term = Self.clipped(term)
            return String(localized: "The term “\(term)” appears more than once.")
        case .invalidCorrection(let position):
            return String(localized: "Correction \(position) needs an original and a replacement text.")
        case .duplicateCorrection(let original):
            let original = Self.clipped(original)
            return String(localized: "There is more than one correction for “\(original)”.")
        case .emptyPack(let name):
            let name = Self.clipped(name)
            return String(localized: "The term pack “\(name)” has no terms or corrections.")
        case .builtInID(let id):
            return String(localized: "The id “\(id)” belongs to a built-in term pack. Change the id in the file and import it again.")
        case .communityID(let id):
            return String(localized: "The id “\(id)” belongs to a community term pack. Change the id in the file and import it again.")
        }
    }

    /// Text from the file can be very long; the alert shows its start.
    private static func clipped(_ text: String) -> String {
        text.count > 80 ? String(text.prefix(80)) + "…" : text
    }
}
