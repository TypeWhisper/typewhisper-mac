import Foundation

struct PaidEntitlements: Sendable, Equatable {
    let canUseCloudFolderSync: Bool

    init(canUseCloudFolderSync: Bool = false) {
        self.canUseCloudFolderSync = canUseCloudFolderSync
    }
}

enum UserDataSyncCollection: String, Codable, Sendable {
    case dictionary
    case snippets
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
    let source: DictionaryEntrySource?
    let createdAt: Date
    let updatedAt: Date

    init(
        entryType: UserDataSyncDictionaryEntryType,
        original: String,
        replacement: String?,
        caseSensitive: Bool,
        isEnabled: Bool,
        source: DictionaryEntrySource? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.entryType = entryType
        self.original = original
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.isEnabled = isEnabled
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case entryType
        case original
        case replacement
        case caseSensitive
        case isEnabled
        case source
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
        let sourceRawValue = try container.decodeIfPresent(String.self, forKey: .source)
        source = sourceRawValue.flatMap(DictionaryEntrySource.init(rawValue:))
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
        try container.encodeIfPresent(source?.rawValue, forKey: .source)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
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

    init(
        dictionaryEntries: [UserDataSyncDictionaryEntry] = [],
        snippets: [UserDataSyncSnippet] = []
    ) {
        self.dictionaryEntries = dictionaryEntries
        self.snippets = snippets
    }
}

enum UserDataSyncMutation: Equatable, Sendable {
    case upsertDictionary(UserDataSyncDictionaryEntry)
    case deleteDictionary(itemID: String)
    case upsertSnippet(UserDataSyncSnippet)
    case deleteSnippet(itemID: String)
}

@MainActor
protocol UserDataSyncStore: AnyObject, Sendable {
    func snapshot() -> UserDataSyncSnapshot
    func apply(_ mutations: [UserDataSyncMutation]) throws
    @discardableResult
    func observeLocalChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> UUID
    func removeLocalChangeObserver(_ id: UUID)
}
