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

/// The part of History a search looks at. An empty set does not limit it.
struct HistorySearchScope: Equatable, Sendable {
    var period: DateInterval?
    var sources: Set<String> = []
    var bundleIDs: Set<String> = []
    var domains: Set<String> = []

    fileprivate var limitsRecords: Bool { !sources.isEmpty || !bundleIDs.isEmpty || !domains.isEmpty }
}

/// A passage that a search found, with what a list of sources shows of its record.
struct HistorySearchHit: Equatable, Sendable {
    var recordID: UUID
    var recordedAt: Date
    var source: String
    var title: String?
    var appName: String?
    var domain: String?
    /// The passage's position in its record. Several once neighbours are joined.
    var ordinals: ClosedRange<Int>
    var passage: HistoryPassage
    /// Higher is better. Scores of different searches do not compare.
    var score = 0.0
}

/// The names in the index that a question can refer to.
struct HistorySearchVocabulary: Equatable, Sendable {
    struct App: Hashable, Sendable {
        var name: String
        var bundleID: String
    }

    var speakers: [String] = []
    var apps: [App] = []
    var domains: [String] = []
}

struct HistorySearchIndexError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite error \(code): \(message)" }

    /// True when the file is damaged or is not an index of this format. Other
    /// errors, such as a locked or unreadable file, can pass.
    var isUnusableFile: Bool {
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
    private var damageHandler: (@Sendable () -> Void)?
    /// What the last search read about the index's content. Every write clears it.
    private var passageCount: Int?
    private var cachedVocabulary: HistorySearchVocabulary?

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

    /// Closes the index and deletes its files. Files that cannot be deleted are
    /// emptied instead. Returns false when text of History is still on disk.
    @discardableResult
    func destroy() -> Bool {
        connection = nil
        passageCount = nil
        cachedVocabulary = nil
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        guard fileManager.fileExists(atPath: directory.path) else { return true }
        // Emptying a file needs no right to change its folder. A folder that
        // cannot be listed may still hold the files.
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return false }
        var isEmpty = true
        for name in names {
            let file = directory.appendingPathComponent(name)
            do {
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: 0)
                try handle.close()
            } catch {
                isEmpty = false
            }
        }
        return isEmpty
    }

    /// The handler is called after the index deleted a file that was damaged or
    /// had another format, and with it every record, so the index can be built again.
    func setDamageHandler(_ handler: @escaping @Sendable () -> Void) {
        damageHandler = handler
    }

    private func destroyDamagedFile() {
        destroy()
        damageHandler?()
    }

    /// The fingerprint of every indexed record. Empty without an index file, and
    /// for a damaged one, which is deleted.
    func fingerprints() throws -> [UUID: HistorySearchFingerprint] {
        let rows = try reading([]) { connection in
            try connection.rows("SELECT uuid, content_version, content_hash FROM records") { row in
                (
                    UUID(uuidString: row.text(0) ?? ""),
                    HistorySearchFingerprint(version: row.text(1) ?? "", contentHash: row.text(2) ?? "")
                )
            }
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

    // MARK: - Search

    /// A word that more than this share of the passages holds is left out of a
    /// search: it matches so much that it costs time and tells passages apart
    /// the least. Small indexes keep every word.
    private static let commonWordShare = 0.1
    private static let passagesForCommonWords = 500
    private static let titleLimit = 20
    private static let newestLimit = 20
    /// Passages of one record a search keeps. Neighbours among them are joined later.
    private static let candidatesPerRecord = 6
    private static let substringLimit = 20
    /// With fewer hits than this, a search also looks for the words inside
    /// longer ones: "zahnarzt" in "Kinderzahnarzt".
    private static let hitsWithoutSubstrings = 3
    private static let substringLength = 5
    /// The weight of a rank when rankings are merged (reciprocal rank fusion).
    private static let rankOffset = 60.0

    /// The passages that match the words and names best, best first. A record
    /// whose title matches adds its best passage. Empty without an index and
    /// for a damaged one, which is deleted.
    /// - Parameter includingNewest: Also the newest matching passages, which
    ///   may rank too low to be among the best: "when did we last talk about it".
    func search(
        words: [String],
        names: [String] = [],
        in scope: HistorySearchScope = HistorySearchScope(),
        limit: Int = 60,
        includingNewest: Bool = false
    ) throws -> [HistorySearchHit] {
        try reading([]) { connection in
            let words = try withoutCommonWords(
                HistoryFullTextQuery.words(in: words.joined(separator: " ")), keepingAll: names.isEmpty, in: connection
            )
            guard let expression = HistoryFullTextQuery.expression(words: words, names: names) else { return [] }
            let records = Self.recordIDs(of: scope.period)
            let passages = Self.passageIDs(ofRecords: records)
            let filter = Self.filterValues(of: scope)

            let recordFilter = Self.recordFilter(firstParameter: 5)
            let filtered = scope.limitsRecords ? "AND rowid / \(Self.passagesPerRecord) IN \(recordFilter)" : ""
            // At most a few passages of each record, so one long recording
            // cannot take every place.
            func matching(orderedBy order: String) -> String {
                """
                SELECT id FROM (
                    SELECT id, score,
                        row_number() OVER (PARTITION BY id / \(Self.passagesPerRecord) ORDER BY score) AS place
                    FROM (
                        SELECT rowid AS id, \(order) AS score FROM passages_fts
                        WHERE passages_fts MATCH ?1 AND rowid BETWEEN ?2 AND ?3 \(filtered)
                    )
                )
                WHERE place <= \(Self.candidatesPerRecord)
                ORDER BY score LIMIT ?4
                """
            }
            let found = try connection.rows(
                matching(orderedBy: "bm25(passages_fts, 1.0, 3.0)"),
                [.text(expression), .integer(passages.lowerBound), .integer(passages.upperBound),
                 .integer(Int64(limit))] + filter
            ) { $0.integer(0) }

            var scores: [Int64: Double] = [:]
            var order: [Int64] = []
            func add(_ passage: Int64, rank: Int) {
                if scores[passage] == nil { order.append(passage) }
                scores[passage, default: 0] += 1 / (Self.rankOffset + Double(rank))
            }
            for (offset, passage) in found.enumerated() { add(passage, rank: offset + 1) }
            if includingNewest {
                let newest = try connection.rows(
                    matching(orderedBy: "-rowid"),
                    [.text(expression), .integer(passages.lowerBound), .integer(passages.upperBound),
                     .integer(Int64(Self.newestLimit))] + filter
                ) { $0.integer(0) }
                for (offset, passage) in newest.enumerated() { add(passage, rank: offset + 1) }
            }

            func titled(orderedBy order: String, limit: Int) throws -> [Int64] {
                try connection.rows(
                    """
                    SELECT rowid FROM titles_fts
                    WHERE titles_fts MATCH ?1 AND rowid BETWEEN ?2 AND ?3
                    \(scope.limitsRecords ? "AND rowid IN \(recordFilter)" : "")
                    ORDER BY \(order) LIMIT ?4
                    """,
                    [.text(expression), .integer(records.lowerBound), .integer(records.upperBound),
                     .integer(Int64(limit))] + filter
                ) { $0.integer(0) }
            }
            var titleRankings = [try titled(orderedBy: "bm25(titles_fts)", limit: Self.titleLimit)]
            if includingNewest { titleRankings.append(try titled(orderedBy: "rowid DESC", limit: Self.newestLimit)) }
            for (offset, record) in titleRankings.flatMap({ $0.enumerated() }) {
                let own = Self.passageIDs(ofRecords: record...record)
                // The record's best passage: one already found, the best match
                // further down the ranking, or its first one.
                let best = try found.first(where: own.contains) ?? connection.rows(
                    """
                    SELECT rowid FROM passages_fts
                    WHERE passages_fts MATCH ?1 AND rowid BETWEEN ?2 AND ?3
                    ORDER BY bm25(passages_fts, 1.0, 3.0) LIMIT 1
                    """,
                    [.text(expression), .integer(own.lowerBound), .integer(own.upperBound)]
                ) { $0.integer(0) }.first ?? own.lowerBound
                add(best, rank: offset + 1)
            }

            if order.count < Self.hitsWithoutSubstrings {
                for word in words where word.count >= Self.substringLength {
                    let containing = try connection.rows(
                        """
                        SELECT id FROM (
                            SELECT id, row_number() OVER (PARTITION BY record_id ORDER BY id DESC) AS place
                            FROM passages
                            WHERE text LIKE ?1 AND id BETWEEN ?2 AND ?3
                            \(scope.limitsRecords ? "AND record_id IN \(recordFilter)" : "")
                        )
                        WHERE place <= \(Self.candidatesPerRecord)
                        ORDER BY id DESC LIMIT ?4
                        """,
                        [.text("%\(word)%"), .integer(passages.lowerBound), .integer(passages.upperBound),
                         .integer(Int64(Self.substringLimit))] + filter
                    ) { $0.integer(0) }
                    for passage in containing where scores[passage] == nil { add(passage, rank: order.count + 1) }
                }
            }

            let ranked = order.enumerated()
                .sorted { (scores[$0.element] ?? 0, -$0.offset) > (scores[$1.element] ?? 0, -$1.offset) }
                .prefix(limit)
            return try ranked.compactMap { passage in
                var hit = try self.hit(forPassage: passage.element, in: connection)
                hit?.score = scores[passage.element] ?? 0
                return hit
            }
        }
    }

    /// The newest records of the scope, each with its first passage, and the
    /// number of records the scope holds.
    func newestRecords(
        in scope: HistorySearchScope, limit: Int
    ) throws -> (hits: [HistorySearchHit], total: Int) {
        try reading(([], 0)) { connection in
            let records = Self.recordIDs(of: scope.period)
            let bounds: [SQLiteConnection.Value] = [.integer(records.lowerBound), .integer(records.upperBound)]
            let filter = Self.filterValues(of: scope)
            // Records without text have no passage and are left out.
            func scoped(firstFilterParameter: Int) -> String {
                """
                id BETWEEN ?1 AND ?2
                \(scope.limitsRecords ? "AND id IN \(Self.recordFilter(firstParameter: firstFilterParameter))" : "")
                AND EXISTS (SELECT 1 FROM passages WHERE passages.id = records.id * \(Self.passagesPerRecord))
                """
            }
            let found = try connection.rows(
                "SELECT id FROM records WHERE \(scoped(firstFilterParameter: 4)) ORDER BY id DESC LIMIT ?3",
                bounds + [.integer(Int64(limit))] + filter
            ) { $0.integer(0) }
            let total = try connection.rows(
                "SELECT count(*) FROM records WHERE \(scoped(firstFilterParameter: 3))", bounds + filter
            ) { $0.integer(0) }.first ?? 0
            let hits = try found.compactMap { record in
                try self.hit(forPassage: record * Self.passagesPerRecord, in: connection)
            }
            return (hits, Int(total))
        }
    }

    /// The speakers, apps and domains of the indexed records.
    func vocabulary() throws -> HistorySearchVocabulary {
        if let cachedVocabulary { return cachedVocabulary }
        let vocabulary = try reading(HistorySearchVocabulary()) { connection in
            var seen = Set<String>()
            let speakers = try connection.rows("SELECT DISTINCT speaker FROM passages WHERE speaker IS NOT NULL") {
                $0.text(0) ?? ""
            }
            .flatMap { $0.split(separator: "\n").map(String.init) }
            .filter { seen.insert($0).inserted }
            let apps = try connection.rows(
                "SELECT DISTINCT app_name, bundle_id FROM records WHERE app_name IS NOT NULL AND bundle_id IS NOT NULL"
            ) { HistorySearchVocabulary.App(name: $0.text(0) ?? "", bundleID: $0.text(1) ?? "") }
            let domains = try connection.rows("SELECT DISTINCT domain FROM records WHERE domain IS NOT NULL") {
                $0.text(0) ?? ""
            }
            return HistorySearchVocabulary(speakers: speakers.sorted(), apps: apps, domains: domains.sorted())
        }
        if connection != nil { cachedVocabulary = vocabulary }
        return vocabulary
    }

    /// Runs a query. Without an index file, and for a damaged one, which is
    /// deleted, the result is `empty`.
    private func reading<T>(_ empty: T, _ body: (SQLiteConnection) throws -> T) throws -> T {
        guard let connection = try open(creating: false) else { return empty }
        do {
            return try body(connection)
        } catch let error as HistorySearchIndexError where error.isUnusableFile {
            destroyDamagedFile()
            return empty
        }
    }

    private func withoutCommonWords(
        _ words: [String], keepingAll: Bool, in connection: SQLiteConnection
    ) throws -> [String] {
        let total: Int
        if let passageCount {
            total = passageCount
        } else {
            // The full-text table's row sizes: one small row per passage.
            total = Int(try connection.rows("SELECT count(*) FROM passages_fts_docsize") { $0.integer(0) }.first ?? 0)
            passageCount = total
        }
        guard total >= Self.passagesForCommonWords else { return words }
        try connection.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS temp.passage_words USING fts5vocab(main, passages_fts, row)"
        )
        let maximum = Int64(Self.commonWordShare * Double(total))
        let rare = try words.filter { word in
            // As the index stores the word. A longer word also counts those that start with it.
            let stored = word.folding(options: .diacriticInsensitive, locale: nil)
            let isPrefix = word.count >= HistoryFullTextQuery.prefixLength
            let sum = try connection.rows(
                "SELECT COALESCE(SUM(doc), 0) FROM temp.passage_words WHERE term >= ?1 AND term <= ?2",
                [.text(stored), .text(isPrefix ? stored + "\u{10FFFF}" : stored)]
            ) { $0.integer(0) }.first ?? 0
            guard isPrefix, sum > maximum else { return sum <= maximum }
            // The sum counts a passage once for every word with the prefix it
            // holds: "budget budgets". Counted up to the share, each passage is once.
            let passages = try connection.rows(
                "SELECT count(*) FROM (SELECT rowid FROM passages_fts WHERE passages_fts MATCH ?1 LIMIT ?2)",
                [.text("\"\(stored.replacingOccurrences(of: "\"", with: "\"\""))\"*"), .integer(maximum + 1)]
            ) { $0.integer(0) }.first ?? 0
            return passages <= maximum
        }
        // A question made of common words only still searches for them.
        return rare.isEmpty && keepingAll ? words : rare
    }

    /// The IDs that records of the period have. Seconds are whole, so a period
    /// that does not start and end on a second is widened to the next ones.
    private static func recordIDs(of period: DateInterval?) -> ClosedRange<Int64> {
        guard let period else { return 0...Int64(UInt32.max) * recordsPerSecond + recordsPerSecond - 1 }
        func second(_ date: Date, roundingUp: Bool) -> Int64 {
            let seconds = date.timeIntervalSince1970
            guard seconds.isFinite else { return 0 }
            return Int64(min(max(roundingUp ? seconds.rounded(.up) : seconds.rounded(.down), 0), Double(UInt32.max)))
        }
        let first = second(period.start, roundingUp: false) * recordsPerSecond
        let end = second(period.end, roundingUp: true) * recordsPerSecond
        return first...max(first, end - 1)
    }

    private static func passageIDs(ofRecords records: ClosedRange<Int64>) -> ClosedRange<Int64> {
        records.lowerBound * passagesPerRecord...records.upperBound * passagesPerRecord + passagesPerRecord - 1
    }

    /// The records of a scope's sources, apps and domains, as a subquery that
    /// takes the values of `filterValues(of:)` from the given parameter on.
    private static func recordFilter(firstParameter: Int) -> String {
        let (sources, apps, domains) = (firstParameter, firstParameter + 1, firstParameter + 2)
        return """
            (SELECT id FROM records
             WHERE (?\(sources) IS NULL OR source IN (SELECT value FROM json_each(?\(sources))))
               AND (?\(apps) IS NULL OR bundle_id IN (SELECT value FROM json_each(?\(apps))))
               AND (?\(domains) IS NULL OR domain IN (SELECT value FROM json_each(?\(domains)))))
            """
    }

    private static func filterValues(of scope: HistorySearchScope) -> [SQLiteConnection.Value] {
        guard scope.limitsRecords else { return [] }
        return [scope.sources, scope.bundleIDs, scope.domains].map { values in
            guard !values.isEmpty, let data = try? JSONEncoder().encode(values.sorted()) else { return .text(nil) }
            return .text(String(decoding: data, as: UTF8.self))
        }
    }

    private func hit(forPassage id: Int64, in connection: SQLiteConnection) throws -> HistorySearchHit? {
        try connection.rows(
            """
            SELECT p.ordinal, p.kind, p.text, p.speaker, p.start_seconds, p.end_seconds, p.char_start, p.char_end,
                   r.uuid, r.recorded_at, r.source, r.title, r.app_name, r.domain
            FROM passages p JOIN records r ON r.id = p.record_id
            WHERE p.id = ?1
            """,
            [.integer(id)]
        ) { row -> HistorySearchHit? in
            guard let recordID = UUID(uuidString: row.text(8) ?? ""),
                  let kind = HistoryPassage.Kind(rawValue: row.text(1) ?? "") else { return nil }
            let ordinal = Int(row.integer(0))
            var range: Range<Int>?
            if let start = row.optionalInteger(6), let end = row.optionalInteger(7), start <= end {
                range = Int(start)..<Int(end)
            }
            return HistorySearchHit(
                recordID: recordID,
                recordedAt: Date(timeIntervalSince1970: row.real(9) ?? 0),
                source: row.text(10) ?? "",
                title: row.text(11),
                appName: row.text(12),
                domain: row.text(13),
                ordinals: ordinal...ordinal,
                passage: HistoryPassage(
                    kind: kind,
                    text: row.text(2) ?? "",
                    speakers: row.text(3)?.split(separator: "\n").map(String.init) ?? [],
                    startSeconds: row.real(4),
                    endSeconds: row.real(5),
                    utf16Range: range
                )
            )
        }.first ?? nil
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
        passageCount = nil
        cachedVocabulary = nil
        try connection.execute("BEGIN IMMEDIATE")
        do {
            try body()
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            if (error as? HistorySearchIndexError)?.isUnusableFile == true { destroyDamagedFile() }
            throw error
        }
    }

    // MARK: - File

    private func open(creating: Bool) throws -> SQLiteConnection? {
        if let connection { return connection }
        let existed = exists
        guard creating || existed else { return nil }
        do {
            return try openFile()
        } catch let error as HistorySearchIndexError where existed && error.isUnusableFile {
            destroyDamagedFile()
            return creating ? try openFile() : nil
        }
    }

    private func openFile() throws -> SQLiteConnection {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connection = try SQLiteConnection(path: fileURL.path)
        // Memory mapping keeps queries fast when the file outgrows the page cache.
        try connection.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA mmap_size=268435456;")
        let formats: [String?]?
        do {
            formats = try connection.rows("SELECT value FROM index_meta WHERE key = 'format'") { $0.text(0) }
        } catch let error as HistorySearchIndexError where error.code & 0xFF == SQLITE_ERROR {
            // No such table: a new file. Other errors, such as a locked file, pass.
            formats = nil
        }
        if let formats {
            let format = formats.first.flatMap { $0 }
            guard format == Self.formatVersion else {
                throw HistorySearchIndexError(code: SQLITE_NOTADB, message: "index format \(format ?? "?")")
            }
        } else {
            do {
                try connection.execute(Self.schema)
            } catch let error as HistorySearchIndexError where error.code & 0xFF == SQLITE_ERROR {
                // A database with other tables in the way.
                throw HistorySearchIndexError(code: SQLITE_NOTADB, message: "not a search index: \(error.message)")
            }
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
        func optionalInteger(_ column: Int32) -> Int64? { isNull(column) ? nil : integer(column) }
        func real(_ column: Int32) -> Double? { isNull(column) ? nil : sqlite3_column_double(statement, column) }
        private func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
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
