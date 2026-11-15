import Combine
import Foundation

/// Reads history records and their changes.
@MainActor
public protocol HistoryReading: AnyObject {
    /// The records with these identifiers, in no particular order. Records
    /// that are gone, still being transcribed or failed are left out.
    func records(withIDs ids: Set<UUID>) async throws -> [ModuleHistoryRecord]

    /// The identifiers among `ids` whose records History still has.
    func existingRecordIDs(among ids: Set<UUID>) async throws -> Set<UUID>

    /// Calls `handler` after each saved change to History, on the main actor,
    /// until the returned value is cancelled or released.
    func observeChanges(_ handler: @escaping @MainActor (ModuleHistoryChange) -> Void) -> AnyCancellable

    /// Opens the record in the History window. With `seconds`, a recording
    /// shows the passage at that time.
    func showRecord(withID id: UUID, atSeconds seconds: Double?)
}

/// A saved change to History's records.
public enum ModuleHistoryChange: Equatable, Sendable {
    /// Records that were added, or whose text, title, timing, speakers or
    /// speaker names changed.
    case upserted(Set<UUID>)
    case removed(Set<UUID>)
    /// Every record was removed.
    case cleared
}

/// One History record as a module sees it.
public struct ModuleHistoryRecord: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var recordedAt: Date
    /// Where the record came from, such as a dictation on this Mac, a file or
    /// another device. Stable values, for filters.
    public var source: String
    /// An ISO 639 code, nil when unknown.
    public var language: String?
    public var durationSeconds: Double
    /// The name of a recording or the title of its document.
    public var title: String?
    /// The app a dictation was made in. Recordings with a title have none.
    public var appName: String?
    public var bundleID: String?
    public var domain: String?
    /// The text as transcribed and corrected.
    public var text: String
    /// A document made from the recording, such as an email or meeting notes.
    public var document: String?

    public init(
        id: UUID,
        recordedAt: Date,
        source: String,
        language: String? = nil,
        durationSeconds: Double = 0,
        title: String? = nil,
        appName: String? = nil,
        bundleID: String? = nil,
        domain: String? = nil,
        text: String,
        document: String? = nil
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.source = source
        self.language = language
        self.durationSeconds = durationSeconds
        self.title = title
        self.appName = appName
        self.bundleID = bundleID
        self.domain = domain
        self.text = text
        self.document = document
    }
}
