import Foundation

enum UserDataSyncIdentity {
    static func dictionaryItemID(entryType: UserDataSyncDictionaryEntryType, original: String) -> String {
        "dictionary:\(entryType.rawValue):\(encodedKey(normalizedKey(original)))"
    }

    static func dictionaryItemID(entryType: DictionaryEntryType, original: String) -> String {
        dictionaryItemID(entryType: UserDataSyncDictionaryEntryType(entryType), original: original)
    }

    static func snippetItemID(trigger: String) -> String {
        "snippet:\(encodedKey(normalizedKey(trigger)))"
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
