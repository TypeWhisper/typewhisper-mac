import Foundation

/// Searches the app's full-text index of History.
///
/// The app keeps the index in step with History. Reads return nothing while
/// the index is off or has not been built; `prepare()` turns it on.
@MainActor
public protocol HistorySearching: AnyObject {
    /// Turns the index on and waits until it holds History as it is now.
    func prepare() async

    /// The passages that match the query best, best first. A record whose
    /// title matches adds its best passage.
    func search(_ query: ModuleHistorySearchQuery) async throws -> [ModuleHistorySearchHit]

    /// The newest records of the scope, each with its first passage, and the
    /// number of records the scope holds.
    func newestRecords(in scope: ModuleHistorySearchScope, limit: Int) async throws -> ModuleHistoryNewestRecords

    /// What was said in a record, in order, without a document written from
    /// it, and the hash of the content it comes from. Nil for a record the
    /// index does not hold.
    func transcript(ofRecord id: UUID) async throws -> ModuleHistoryTranscript?

    /// The summary kept for a record in a language, unless the record changed
    /// since or is gone.
    /// - Parameter language: An ISO 639 code, or empty for the recording's own.
    func summary(ofRecord id: UUID, language: String) async throws -> ModuleHistorySummary?

    /// Keeps a summary of a record until the record changes or is removed.
    /// Does nothing when the record no longer has the content of `contentHash`.
    func setSummary(
        _ summary: String, providerId: String, ofRecord id: UUID, contentHash: String, language: String
    ) async throws

    /// The speakers, apps and domains of the indexed records.
    func vocabulary() async throws -> ModuleHistoryVocabulary
}

/// A full-text search of History.
///
/// Only the letters and digits of `words` and `names` reach the index, so
/// operators of the query language in them have no effect.
public struct ModuleHistorySearchQuery: Equatable, Sendable {
    /// Each word also finds the words that start with it once it is long enough.
    public var words: [String]
    /// Names are searched as they are written, several words as one phrase.
    public var names: [String]
    public var scope: ModuleHistorySearchScope
    public var limit: Int
    /// Also the newest matching passages, which may rank too low to be among the best.
    public var includingNewest: Bool

    public init(
        words: [String],
        names: [String] = [],
        scope: ModuleHistorySearchScope = ModuleHistorySearchScope(),
        limit: Int = 60,
        includingNewest: Bool = false
    ) {
        self.words = words
        self.names = names
        self.scope = scope
        self.limit = limit
        self.includingNewest = includingNewest
    }

    /// The words of a text as the index splits them, lowercased.
    public static func words(in text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }
}

/// The part of History a search looks at. An empty set does not limit it.
public struct ModuleHistorySearchScope: Equatable, Sendable {
    public var period: DateInterval?
    public var sources: Set<String>
    public var bundleIDs: Set<String>
    public var domains: Set<String>
    /// The records a search is limited to. Nil for no such limit.
    public var recordIDs: Set<UUID>?

    public init(
        period: DateInterval? = nil,
        sources: Set<String> = [],
        bundleIDs: Set<String> = [],
        domains: Set<String> = [],
        recordIDs: Set<UUID>? = nil
    ) {
        self.period = period
        self.sources = sources
        self.bundleIDs = bundleIDs
        self.domains = domains
        self.recordIDs = recordIDs
    }

    /// Whether a hit lies in the scope. A hit does not carry its app's bundle
    /// ID, so a scope of apps includes none. A period does not include its end.
    public func includes(_ hit: ModuleHistorySearchHit) -> Bool {
        (period.map { $0.start <= hit.recordedAt && hit.recordedAt < $0.end } ?? true)
            && (sources.isEmpty || sources.contains(hit.source))
            && bundleIDs.isEmpty
            && (domains.isEmpty || hit.domain.map(domains.contains) == true)
            && (recordIDs?.contains(hit.recordID) ?? true)
    }
}

/// A stretch of a recording that the index stores, finds and cites as one unit.
public struct ModuleHistoryPassage: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// What was said.
        case transcript
        /// A document made from the recording, such as an email or meeting notes.
        case result
    }

    public var kind: Kind
    public var text: String
    /// The speakers in the passage, in order of appearance. Empty without speaker detection.
    public var speakers: [String]
    public var startSeconds: Double?
    public var endSeconds: Double?
    /// The passage's place in its source text, in UTF-16 units. Nil for
    /// speaker transcripts, whose passages are found by their time.
    public var utf16Range: Range<Int>?

    public init(
        kind: Kind,
        text: String,
        speakers: [String] = [],
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        utf16Range: Range<Int>? = nil
    ) {
        self.kind = kind
        self.text = text
        self.speakers = speakers
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.utf16Range = utf16Range
    }
}

/// A passage a search found, with what a list of sources shows of its record.
public struct ModuleHistorySearchHit: Equatable, Sendable {
    public var recordID: UUID
    public var recordedAt: Date
    public var source: String
    public var title: String?
    public var appName: String?
    public var domain: String?
    /// The passage's position in its record. Several once neighbours are joined.
    public var ordinals: ClosedRange<Int>
    public var passage: ModuleHistoryPassage
    /// Higher is better. Scores of different searches do not compare.
    public var score: Double

    public init(
        recordID: UUID,
        recordedAt: Date,
        source: String,
        title: String? = nil,
        appName: String? = nil,
        domain: String? = nil,
        ordinals: ClosedRange<Int>,
        passage: ModuleHistoryPassage,
        score: Double = 0
    ) {
        self.recordID = recordID
        self.recordedAt = recordedAt
        self.source = source
        self.title = title
        self.appName = appName
        self.domain = domain
        self.ordinals = ordinals
        self.passage = passage
        self.score = score
    }
}

/// The newest records of a scope and how many records it holds.
public struct ModuleHistoryNewestRecords: Equatable, Sendable {
    public var hits: [ModuleHistorySearchHit]
    public var total: Int

    public init(hits: [ModuleHistorySearchHit], total: Int) {
        self.hits = hits
        self.total = total
    }
}

/// A record's text as the index holds it.
public struct ModuleHistoryTranscript: Equatable, Sendable {
    public var passages: [ModuleHistoryPassage]
    /// Changes with the record's content; `setSummary` checks it.
    public var contentHash: String

    public init(passages: [ModuleHistoryPassage], contentHash: String) {
        self.passages = passages
        self.contentHash = contentHash
    }
}

/// A summary kept for a record and the provider that wrote it.
public struct ModuleHistorySummary: Equatable, Sendable {
    public var text: String
    public var providerId: String

    public init(text: String, providerId: String) {
        self.text = text
        self.providerId = providerId
    }
}

/// The names in the index that a search can refer to.
public struct ModuleHistoryVocabulary: Equatable, Sendable {
    public struct App: Hashable, Sendable {
        public var name: String
        public var bundleID: String

        public init(name: String, bundleID: String) {
            self.name = name
            self.bundleID = bundleID
        }
    }

    public var speakers: [String]
    public var apps: [App]
    public var domains: [String]

    public init(speakers: [String] = [], apps: [App] = [], domains: [String] = []) {
        self.speakers = speakers
        self.apps = apps
        self.domains = domains
    }
}
