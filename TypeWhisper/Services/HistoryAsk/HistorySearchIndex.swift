import Foundation
import SQLite3

/// What the search index stores about one History record.
struct HistorySearchRecord: Equatable, Sendable {
    var id: UUID
    var recordedAt: Date
    var source: String
    var originDeviceID: String
    var language: String?
    var durationSeconds: Double
    /// The name of a recording or the title of its document.
    var title: String?
    /// The app a dictation was made in. Recordings with a title have none.
    var appName: String?
    var bundleID: String?
    var domain: String?
    /// The transcription version the passages were made from.
    var versionID: UUID?
    var fingerprint: HistorySearchFingerprint
    var passages: [HistoryPassage]
}

/// Tells whether an indexed record still matches its History record.
struct HistorySearchFingerprint: Equatable, Sendable {
    /// The record's change dates. Cheap to read for every record.
    var version: String
    /// A hash of everything the index takes from the record. It also catches
    /// changes that set no date, such as new word timing.
    var contentHash: String
}

struct HistorySearchIndexError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite error \(code): \(message)" }

    /// True when SQLite found the file itself damaged.
    var isCorruption: Bool {
        let primaryCode = code & 0xFF
        return primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB
    }
}

/// The full-text index over History, in a SQLite file of its own.
///
/// It is derived data: every record in it can be made again from History, so
/// a file that is damaged or has an older format is deleted and built again.
actor HistorySearchIndex {
    static let directoryName = "HistorySearch"
    /// Raise it when the tables change. An index with another format is built again.
    static let formatVersion = "1"

    /// Row IDs grow with the recording time, also for records that arrive late
    /// through sync. A period is then a range of passage IDs, which full-text
    /// search filters far faster than a join on the records.
    ///
    /// A record's ID is its time in seconds times `recordsPerSecond` plus a
    /// counter for records of the same second; a passage's ID is its record's
    /// ID times `passagesPerRecord` plus its position.
    static let recordsPerSecond: Int64 = 1 << 16
    static let passagesPerRecord: Int64 = 1 << 14

    private let directory: URL
    private var connection: SQLiteConnection?

    init(
        directory: URL = AppConstants.appSupportDirectory
            .appendingPathComponent(HistorySearchIndex.directoryName, isDirectory: true)
    ) {
        self.directory = directory
    }

    private var fileURL: URL { directory.appendingPathComponent("index.sqlite") }

    var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Adds the records, replacing what the index holds for them.
    func upsert(_ records: [HistorySearchRecord]) throws {
        guard !records.isEmpty, let connection = try open(creating: true) else { return }
        try transaction(in: connection) {
            for record in records {
                try delete(record.id, in: connection)
                let rowID = try freeRowID(at: record.recordedAt, in: connection)
                try connection.run(
                    """
                    INSERT INTO records(
                      id, uuid, recorded_at, source, origin_device_id, language, duration, title,
                      app_name, bundle_id, domain, version_id, content_version, content_hash
                    ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
                    """,
                    [
                        .integer(rowID), .text(record.id.uuidString),
                        .real(record.recordedAt.timeIntervalSince1970), .text(record.source),
                        .text(record.originDeviceID), .text(record.language), .real(record.durationSeconds),
                        .text(record.title), .text(record.appName), .text(record.bundleID), .text(record.domain),
                        .text(record.versionID?.uuidString), .text(record.fingerprint.version),
                        .text(record.fingerprint.contentHash),
                    ]
                )
                for (ordinal, passage) in record.passages.prefix(Int(Self.passagesPerRecord)).enumerated() {
                    try connection.run(
                        """
                        INSERT INTO passages(
                          id, record_id, ordinal, kind, text, speaker, start_seconds, end_seconds, char_start, char_end
                        ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                        """,
                        [
                            .integer(rowID * Self.passagesPerRecord + Int64(ordinal)), .integer(rowID),
                            .integer(Int64(ordinal)), .text(passage.kind.rawValue), .text(passage.text),
                            .text(passage.speakers.isEmpty ? nil : passage.speakers.joined(separator: "\n")),
                            .real(passage.startSeconds), .real(passage.endSeconds),
                            .integer(passage.utf16Range.map { Int64($0.lowerBound) }),
                            .integer(passage.utf16Range.map { Int64($0.upperBound) }),
                        ]
                    )
                }
            }
        }
    }

    /// Removes the records. Does nothing without an index file.
    func remove(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty, let connection = try open(creating: false) else { return }
        try transaction(in: connection) {
            for id in ids { try delete(id, in: connection) }
        }
    }

    /// Closes the index and deletes its files.
    func destroy() {
        connection = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// The fingerprint of every indexed record. Empty without an index file, and
    /// for a damaged one, which is deleted.
    func fingerprints() throws -> [UUID: HistorySearchFingerprint] {
        guard let connection = try open(creating: false) else { return [:] }
        let rows: [(UUID?, HistorySearchFingerprint)]
        do {
            rows = try connection.rows("SELECT uuid, content_version, content_hash FROM records") { row in
                (
                    UUID(uuidString: row.text(0) ?? ""),
                    HistorySearchFingerprint(version: row.text(1) ?? "", contentHash: row.text(2) ?? "")
                )
            }
        } catch let error as HistorySearchIndexError where error.isCorruption {
            destroy()
            return [:]
        }
        return Dictionary(rows.compactMap { id, fingerprint in id.map { ($0, fingerprint) } }) { first, _ in first }
    }

    func counts() throws -> (records: Int, passages: Int) {
        guard let connection = try open(creating: false) else { return (0, 0) }
        let records = try connection.rows("SELECT count(*) FROM records") { $0.integer(0) }.first ?? 0
        let passages = try connection.rows("SELECT count(*) FROM passages") { $0.integer(0) }.first ?? 0
        return (Int(records), Int(passages))
    }

    /// Throws when the full-text tables no longer match the stored passages and titles.
    func checkIntegrity() throws {
        guard let connection = try open(creating: false) else { return }
        // Without a rank of 1, FTS5 only checks the full-text tables against themselves.
        try connection.run("INSERT INTO passages_fts(passages_fts, rank) VALUES('integrity-check', 1)")
        try connection.run("INSERT INTO titles_fts(titles_fts, rank) VALUES('integrity-check', 1)")
    }

    // MARK: - Rows

    private func delete(_ id: UUID, in connection: SQLiteConnection) throws {
        let rowIDs = try connection.rows("SELECT id FROM records WHERE uuid = ?1", [.text(id.uuidString)]) {
            $0.integer(0)
        }
        for rowID in rowIDs {
            try connection.run(
                "DELETE FROM passages WHERE id BETWEEN ?1 AND ?2",
                [
                    .integer(rowID * Self.passagesPerRecord),
                    .integer((rowID + 1) * Self.passagesPerRecord - 1),
                ]
            )
            try connection.run("DELETE FROM records WHERE id = ?1", [.integer(rowID)])
        }
    }

    private func freeRowID(at date: Date, in connection: SQLiteConnection) throws -> Int64 {
        let seconds = date.timeIntervalSince1970
        var second = seconds.isFinite ? Int64(min(max(seconds, 0), Double(UInt32.max))) : 0
        while true {
            let first = second * Self.recordsPerSecond
            let last = first + Self.recordsPerSecond - 1
            let next = try connection.rows(
                "SELECT COALESCE(MAX(id) + 1, ?1) FROM records WHERE id BETWEEN ?1 AND ?2",
                [.integer(first), .integer(last)]
            ) { $0.integer(0) }.first ?? first
            if next <= last { return next }
            // More records in one second than it has IDs: continue in the next one.
            second += 1
        }
    }

    private func transaction(in connection: SQLiteConnection, _ body: () throws -> Void) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            try body()
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            // A damaged file is deleted, so the next check builds the index again.
            if (error as? HistorySearchIndexError)?.isCorruption == true { destroy() }
            throw error
        }
    }

    // MARK: - File

    private func open(creating: Bool) throws -> SQLiteConnection? {
        if let connection { return connection }
        guard creating || exists else { return nil }
        do {
            return try openFile()
        } catch {
            destroy()
            return creating ? try openFile() : nil
        }
    }

    private func openFile() throws -> SQLiteConnection {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connection = try SQLiteConnection(path: fileURL.path)
        // Memory mapping keeps queries fast when the file outgrows the page cache.
        try connection.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA mmap_size=268435456;")
        let format = try? connection.rows("SELECT value FROM index_meta WHERE key = 'format'") { $0.text(0) }.first
        if let format {
            guard format == Self.formatVersion else {
                throw HistorySearchIndexError(code: SQLITE_SCHEMA, message: "index format \(format ?? "?")")
            }
        } else {
            try connection.execute(Self.schema)
        }
        self.connection = connection
        return connection
    }

    private static let schema = """
        BEGIN;
        CREATE TABLE records(
          id INTEGER PRIMARY KEY,
          uuid TEXT NOT NULL UNIQUE,
          recorded_at REAL NOT NULL,
          source TEXT NOT NULL,
          origin_device_id TEXT NOT NULL,
          language TEXT,
          duration REAL NOT NULL,
          title TEXT,
          app_name TEXT,
          bundle_id TEXT,
          domain TEXT,
          version_id TEXT,
          content_version TEXT NOT NULL,
          content_hash TEXT NOT NULL
        );
        CREATE TABLE passages(
          id INTEGER PRIMARY KEY,
          record_id INTEGER NOT NULL,
          ordinal INTEGER NOT NULL,
          kind TEXT NOT NULL,
          text TEXT NOT NULL,
          speaker TEXT,
          start_seconds REAL,
          end_seconds REAL,
          char_start INTEGER,
          char_end INTEGER
        );
        CREATE VIRTUAL TABLE passages_fts USING fts5(
          text, speaker,
          content='passages', content_rowid='id',
          tokenize='unicode61 remove_diacritics 2'
        );
        CREATE VIRTUAL TABLE titles_fts USING fts5(
          title,
          content='records', content_rowid='id',
          tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER passages_inserted AFTER INSERT ON passages BEGIN
          INSERT INTO passages_fts(rowid, text, speaker) VALUES(new.id, new.text, new.speaker);
        END;
        CREATE TRIGGER passages_deleted AFTER DELETE ON passages BEGIN
          INSERT INTO passages_fts(passages_fts, rowid, text, speaker)
            VALUES('delete', old.id, old.text, old.speaker);
        END;
        CREATE TRIGGER records_inserted AFTER INSERT ON records BEGIN
          INSERT INTO titles_fts(rowid, title) VALUES(new.id, new.title);
        END;
        CREATE TRIGGER records_deleted AFTER DELETE ON records BEGIN
          INSERT INTO titles_fts(titles_fts, rowid, title) VALUES('delete', old.id, old.title);
        END;
        CREATE TABLE index_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        INSERT INTO index_meta(key, value) VALUES('format', '\(formatVersion)');
        COMMIT;
        """
}

/// One SQLite connection with its prepared statements. Used by one actor only.
private final class SQLiteConnection {
    /// A value to bind; nil binds NULL.
    enum Value {
        case integer(Int64?)
        case real(Double?)
        case text(String?)
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
    }

    private let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw HistorySearchIndexError(code: code, message: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        try rows(sql, values) { _ in }
    }

    @discardableResult
    func rows<T>(_ sql: String, _ values: [Value] = [], _ read: (Row) -> T) throws -> [T] {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .integer(let value?): code = sqlite3_bind_int64(statement, index, value)
            case .real(let value?): code = sqlite3_bind_double(statement, index, value)
            case .text(let value?): code = sqlite3_bind_text(statement, index, value, -1, transient)
            case .integer(nil), .real(nil), .text(nil): code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw lastError() }
        }
        var result: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: result.append(read(Row(statement: statement)))
            case SQLITE_DONE: return result
            default: throw lastError()
            }
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        statements[sql] = statement
        return statement
    }

    private func lastError() -> HistorySearchIndexError {
        HistorySearchIndexError(code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }
}
