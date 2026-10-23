import Foundation

enum UserDataSyncCollection: String, Codable, Sendable {
    case dictionary
    case snippets
    case history
}

enum UserDataSyncDictionaryEntryType: String, Codable, Sendable {
    case term
    case correction
}

struct UserDataSyncDictionaryEntry: Codable, Equatable, Sendable {
    let entryType: UserDataSyncDictionaryEntryType
    let original: String
    let replacement: String?
    let caseSensitive: Bool
    let isEnabled: Bool
    let isRegex: Bool
    let isRegexFieldPresent: Bool
    let source: DictionaryEntrySource?
    let ctcMinSimilarity: Float?
    let ctcMinSimilarityFieldPresent: Bool
    let createdAt: Date
    let updatedAt: Date

    var isRegexPatternSupported: Bool {
        !isRegex || (try? NSRegularExpression(pattern: original, options: caseSensitive ? [] : [.caseInsensitive])) != nil
    }

    init(
        entryType: UserDataSyncDictionaryEntryType,
        original: String,
        replacement: String?,
        caseSensitive: Bool,
        isEnabled: Bool,
        isRegex: Bool = false,
        isRegexFieldPresent: Bool? = nil,
        source: DictionaryEntrySource? = nil,
        ctcMinSimilarity: Float? = nil,
        ctcMinSimilarityFieldPresent: Bool? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.entryType = entryType
        self.original = original
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.isEnabled = isEnabled
        self.isRegex = entryType == .correction && isRegex
        self.isRegexFieldPresent = entryType == .correction && (isRegexFieldPresent ?? true)
        self.source = source
        self.ctcMinSimilarity = entryType == .term
            ? Self.normalizedCtcMinSimilarity(ctcMinSimilarity)
            : nil
        self.ctcMinSimilarityFieldPresent = entryType == .term
            ? (ctcMinSimilarityFieldPresent ?? true)
            : false
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case entryType
        case original
        case replacement
        case caseSensitive
        case isEnabled
        case isRegex
        case source
        case ctcMinSimilarity
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entryType = try container.decode(UserDataSyncDictionaryEntryType.self, forKey: .entryType)
        original = try container.decode(String.self, forKey: .original)
        replacement = try container.decodeIfPresent(String.self, forKey: .replacement)
        caseSensitive = try container.decode(Bool.self, forKey: .caseSensitive)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        let decodedIsRegex = try container.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        isRegex = entryType == .correction && decodedIsRegex
        isRegexFieldPresent = entryType == .correction && container.contains(.isRegex)
        let sourceRawValue = try container.decodeIfPresent(String.self, forKey: .source)
        source = sourceRawValue.flatMap(DictionaryEntrySource.init(rawValue:))
        ctcMinSimilarityFieldPresent =
            entryType == .term && container.contains(.ctcMinSimilarity)
        ctcMinSimilarity = entryType == .term
            ? Self.normalizedCtcMinSimilarity(
                try container.decodeIfPresent(
                    Float.self,
                    forKey: .ctcMinSimilarity
                )
            )
            : nil
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entryType, forKey: .entryType)
        try container.encode(original, forKey: .original)
        try container.encodeIfPresent(replacement, forKey: .replacement)
        try container.encode(caseSensitive, forKey: .caseSensitive)
        try container.encode(isEnabled, forKey: .isEnabled)
        if isRegexFieldPresent {
            try container.encode(isRegex, forKey: .isRegex)
        }
        try container.encodeIfPresent(source?.rawValue, forKey: .source)
        if entryType == .term {
            try container.encode(ctcMinSimilarity, forKey: .ctcMinSimilarity)
        }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private static func normalizedCtcMinSimilarity(_ value: Float?) -> Float? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    func preservingRegexMode(_ isRegex: Bool) -> Self {
        Self(
            entryType: entryType, original: original, replacement: replacement,
            caseSensitive: caseSensitive, isEnabled: isEnabled,
            isRegex: isRegex, isRegexFieldPresent: isRegexFieldPresent,
            source: source, ctcMinSimilarity: ctcMinSimilarity,
            ctcMinSimilarityFieldPresent: ctcMinSimilarityFieldPresent,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    /// Old macOS versions retained these fields when importing a Windows regex,
    /// but dropped its mode. Edited literals must not be repaired as old copies.
    func isLegacyLiteralCopy(of regex: Self) -> Bool {
        entryType == .correction && !isRegex && regex.isRegex
            && original.utf8.elementsEqual(regex.original.utf8)
            && replacement == regex.replacement && updatedAt == regex.updatedAt
            && caseSensitive == regex.caseSensitive && isEnabled == regex.isEnabled
    }
}

struct UserDataSyncSnippet: Codable, Equatable, Sendable {
    let trigger: String
    let replacement: String
    let caseSensitive: Bool
    let isEnabled: Bool
    let tags: [String]
    let createdAt: Date
    let updatedAt: Date

    init(
        trigger: String,
        replacement: String,
        caseSensitive: Bool,
        isEnabled: Bool,
        tags: [String] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.trigger = trigger
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.isEnabled = isEnabled
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case trigger, replacement, caseSensitive, isEnabled, tags, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try container.decode(String.self, forKey: .trigger)
        replacement = try container.decode(String.self, forKey: .replacement)
        caseSensitive = try container.decode(Bool.self, forKey: .caseSensitive)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct UserDataSyncSnapshot: Codable, Equatable, Sendable {
    let dictionaryEntries: [UserDataSyncDictionaryEntry]
    let snippets: [UserDataSyncSnippet]
    let historyRecords: [UserDataSyncHistoryRecord]
    let deletedHistoryRecords: [UserDataSyncHistoryDeletion]

    init(
        dictionaryEntries: [UserDataSyncDictionaryEntry] = [],
        snippets: [UserDataSyncSnippet] = [],
        historyRecords: [UserDataSyncHistoryRecord] = [],
        deletedHistoryRecords: [UserDataSyncHistoryDeletion] = []
    ) {
        self.dictionaryEntries = dictionaryEntries
        self.snippets = snippets
        self.historyRecords = historyRecords
        self.deletedHistoryRecords = deletedHistoryRecords
    }
}

enum UserDataSyncMutation: Equatable, Sendable {
    case upsertDictionary(UserDataSyncDictionaryEntry)
    case restoreLegacyDictionaryRegex(UserDataSyncDictionaryEntry)
    case deleteDictionary(itemID: String)
    case upsertSnippet(UserDataSyncSnippet)
    case deleteSnippet(itemID: String)
    case upsertHistoryContent(UserDataSyncHistoryContentV1)
    case upsertHistoryInbox(UserDataSyncHistoryInboxV1)
    case upsertHistoryAudio(UserDataSyncHistoryAudioV1)
    case upsertHistoryTranscript(UserDataSyncHistoryTranscriptV1)
    case upsertHistorySpeakers(UserDataSyncHistorySpeakersV1)
    case deleteHistory(recordID: UUID)
}

@MainActor
protocol UserDataSyncStore: AnyObject, Sendable {
    func snapshot() -> UserDataSyncSnapshot
    func apply(_ mutations: [UserDataSyncMutation]) throws
    @discardableResult
    func observeLocalChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> UUID
    func removeLocalChangeObserver(_ id: UUID)
}
