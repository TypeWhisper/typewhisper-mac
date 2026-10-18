import Foundation

enum UserDataSyncIdentity {
    static let regexCorrectionPrefix = "dictionary:correction:regex:"

    static func dictionaryItemID(entryType: UserDataSyncDictionaryEntryType, original: String, isRegex: Bool = false) -> String {
        if entryType == .correction, isRegex {
            // Pattern bytes are significant: \d and \D, accents, and surrounding spaces
            // must not collapse even when the expression matches case-insensitively.
            return regexCorrectionPrefix + encodedKey(original)
        }
        return "dictionary:\(entryType.rawValue):\(encodedKey(normalizedKey(original)))"
    }

    static func dictionaryItemID(entryType: DictionaryEntryType, original: String, isRegex: Bool = false) -> String {
        dictionaryItemID(entryType: UserDataSyncDictionaryEntryType(entryType), original: original, isRegex: isRegex)
    }

    static func snippetItemID(trigger: String) -> String {
        "snippet:\(encodedKey(normalizedKey(trigger)))"
    }

    static func historyItemID(recordID: UUID) -> String {
        "history:\(recordID.uuidString.lowercased())"
    }

    static func historyRecordID(from itemID: String) -> UUID? {
        guard itemID.hasPrefix("history:") else { return nil }
        return UUID(uuidString: String(itemID.dropFirst("history:".count)))
    }

    static func historyStateKey(
        itemID: String,
        component: UserDataSyncHistoryComponent
    ) -> String {
        "\(itemID)#\(component.rawValue)"
    }

    static func normalizedKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func encodedKey(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension UserDataSyncDictionaryEntryType {
    init(_ type: DictionaryEntryType) {
        switch type {
        case .term:
            self = .term
        case .correction:
            self = .correction
        }
    }
}

extension DictionaryEntryType {
    init(_ type: UserDataSyncDictionaryEntryType) {
        switch type {
        case .term:
            self = .term
        case .correction:
            self = .correction
        }
    }
}
