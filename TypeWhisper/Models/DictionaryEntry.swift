import Foundation
import SwiftData

enum DictionaryEntryType: String, Codable, CaseIterable {
    case term = "term"
    case correction = "correction"

    var displayName: String {
        switch self {
        case .term: return String(localized: "Term")
        case .correction: return String(localized: "Correction")
        }
    }

    var description: String {
        switch self {
        case .term: return String(localized: "Helps Whisper recognize technical terms")
        case .correction: return String(localized: "Replaces incorrect transcriptions")
        }
    }
}

@Model
final class DictionaryEntry {
    var id: UUID
    var entryType: String
    var original: String
    var replacement: String?
    var caseSensitive: Bool
    var isEnabled: Bool
    var createdAt: Date
    var usageCount: Int

    var type: DictionaryEntryType {
        get { DictionaryEntryType(rawValue: entryType) ?? .term }
        set { entryType = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        type: DictionaryEntryType,
        original: String,
        replacement: String? = nil,
        caseSensitive: Bool = false,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        usageCount: Int = 0
    ) {
        self.id = id
        self.entryType = type.rawValue
        self.original = original
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.usageCount = usageCount
    }

    var displayText: String {
        if type == .correction, let replacement = replacement {
            let displayReplacement = replacement.isEmpty ? "\"\"" : replacement
            return "\(original) → \(displayReplacement)"
        }
        return original
    }
}
