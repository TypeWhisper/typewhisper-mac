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
    let createdAt: Date
    let updatedAt: Date

    init(
        entryType: UserDataSyncDictionaryEntryType,
        original: String,
        replacement: String?,
        caseSensitive: Bool,
        isEnabled: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.entryType = entryType
        self.original = original
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
