import SQLite3
import SwiftData
import XCTest
@testable import TypeWhisper

final class HistoryPassageChunkerTests: XCTestCase {
    private func sentences(_ count: Int, about topic: String = "the quarterly numbers") -> String {
        (1...count).map { "Sentence number \($0) talks about \(topic) in detail." }.joined(separator: " ")
    }

    func testAShortTextIsOnePassageWithItsPlaceAndTheTimeOfItsWords() {
        let text = "  Hello world. Second sentence.\n"
        let passages = HistoryPassageChunker.passages(of: text, timing: [
            HistoryPassageTiming(utf16Range: 2..<7, start: 1.5, end: 2),
            HistoryPassageTiming(utf16Range: 22..<30, start: 4, end: 4.5),
        ])

        XCTAssertEqual(passages, [
            HistoryPassage(
                kind: .transcript, text: "Hello world. Second sentence.",
                startSeconds: 1.5, endSeconds: 4.5, utf16Range: 2..<31
            ),
        ])
        XCTAssertEqual(HistoryPassageChunker.passages(of: " \n "), [])
    }

    func testALongTextIsCutAtSentenceEndsIntoPassagesOfSimilarLength() throws {
        // Filling passages to the limit would leave 3 of the 31 sentences for the last one.
        let text = sentences(31)
        let timing = [
            HistoryPassageTiming(utf16Range: 0..<8, start: 0, end: 1),
            HistoryPassageTiming(utf16Range: (text.utf16.count - 7)..<text.utf16.count, start: 90, end: 91),
        ]
        let passages = HistoryPassageChunker.passages(of: text, kind: .result, timing: timing)

        XCTAssertEqual(passages.count, 3)
        XCTAssertEqual(passages.map(\.text).joined(separator: " "), text)
        for passage in passages {
            XCTAssertEqual(passage.kind, .result)
            XCTAssertTrue(passage.text.hasSuffix("in detail."), passage.text)
            XCTAssertTrue(
                (HistoryPassageChunker.minimumLength...HistoryPassageChunker.maximumLength).contains(passage.text.utf16.count),
                "\(passage.text.utf16.count)"
            )
            let range = try XCTUnwrap(passage.utf16Range)
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count)), passage.text)
        }
        XCTAssertEqual(passages.map(\.startSeconds), [0, nil, 90])
        XCTAssertEqual(passages.map(\.endSeconds), [1, nil, 91])
    }

    func testASentenceLongerThanAPassageIsCutBetweenWordsAndNeverInsideAnEmoji() {
        let words = (1...400).map { "word\($0)" }.joined(separator: " ")
        let wordPassages = HistoryPassageChunker.passages(of: words)
        XCTAssertGreaterThan(wordPassages.count, 1)
        XCTAssertEqual(wordPassages.map(\.text).joined(separator: " "), words)
        XCTAssertTrue(wordPassages.allSatisfy { $0.text.utf16.count <= HistoryPassageChunker.maximumLength })

        // The emoji's two UTF-16 units sit on both sides of the limit.
        let unbroken = String(repeating: "a", count: 899) + "😀" + String(repeating: "b", count: 500)
        let passages = HistoryPassageChunker.passages(of: unbroken)
        XCTAssertEqual(passages.map(\.text), [String(repeating: "a", count: 899), "😀" + String(repeating: "b", count: 500)])
    }

    func testSpeakerPassagesHoldWholeTurnsWithTheirSpeakersAndTimes() {
        let annaFirst = sentences(5, about: "the launch")
        let annaSecond = sentences(5, about: "the budget")
        let benLong = sentences(10, about: "hiring")
        let benMore = sentences(3, about: "the office")
        let passages = HistoryPassageChunker.passages(ofSpeakerSegments: [
            HistoryPassageSpeakerSegment(speaker: "Anna", text: annaFirst, start: 0, end: 20),
            HistoryPassageSpeakerSegment(speaker: "Ben", text: " Yes. ", start: 20, end: 21),
            HistoryPassageSpeakerSegment(speaker: "Anna", text: annaSecond, start: 21, end: 40),
            HistoryPassageSpeakerSegment(speaker: "Ben", text: benLong, start: 40, end: 80),
            HistoryPassageSpeakerSegment(speaker: "Ben", text: "", start: 80, end: 81),
            HistoryPassageSpeakerSegment(speaker: "Ben", text: benMore, start: 81, end: 95),
        ])

        XCTAssertEqual(passages, [
            HistoryPassage(
                kind: .transcript, text: "Anna: \(annaFirst)\nBen: Yes.\nAnna: \(annaSecond)",
                speakers: ["Anna", "Ben"], startSeconds: 0, endSeconds: 40
            ),
            // Ben's two segments are one turn.
            HistoryPassage(
                kind: .transcript, text: "Ben: \(benLong) \(benMore)",
                speakers: ["Ben"], startSeconds: 40, endSeconds: 95
            ),
        ])
    }

    func testATurnLongerThanAPassageIsCutAndEveryPartNamesItsSpeaker() throws {
        let monologue = sentences(40)
        let passages = HistoryPassageChunker.passages(ofSpeakerSegments: [
            HistoryPassageSpeakerSegment(speaker: "Anna", text: monologue, start: 100, end: 300),
        ])

        XCTAssertEqual(passages.count, 3)
        XCTAssertEqual(passages.map { String($0.text.dropFirst("Anna: ".count)) }.joined(separator: " "), monologue)
        for passage in passages {
            XCTAssertTrue(passage.text.hasPrefix("Anna: "))
            XCTAssertEqual(passage.speakers, ["Anna"])
            XCTAssertLessThanOrEqual(passage.text.utf16.count, HistoryPassageChunker.maximumLength)
        }
        // Without timing inside the segment, the parts share its time by their place in the text.
        let starts = try passages.map { try XCTUnwrap($0.startSeconds) }
        let ends = try passages.map { try XCTUnwrap($0.endSeconds) }
        XCTAssertEqual(starts.first, 100)
        XCTAssertEqual(ends.last, 300)
        XCTAssertEqual(starts, starts.sorted())
        XCTAssertTrue(zip(ends, starts.dropFirst()).allSatisfy { $0 <= $1 + 1 })
    }
}

/// Reads the index file directly, as a search will.
private func indexRows(_ sql: String, in directory: URL, writing: Bool = false) throws -> [[String]] {
    let path = directory.appendingPathComponent("index.sqlite").path
    guard FileManager.default.fileExists(atPath: path) else { return [] }
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_open_v2(path, &database, writing ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(database))
        // A file that is being built again has no tables for a moment.
        if message.hasPrefix("no such table") { return [] }
        throw HistorySearchIndexError(code: sqlite3_errcode(database), message: message)
    }
    var rows: [[String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        rows.append((0..<sqlite3_column_count(statement)).map { column in
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        })
    }
    return rows
}

/// The records with a passage that matches the full-text expression, oldest first.
private func recordIDs(matching expression: String, in directory: URL) throws -> [UUID] {
    try indexRows(
        """
        SELECT r.uuid FROM passages_fts
        JOIN passages p ON p.id = passages_fts.rowid
        JOIN records r ON r.id = p.record_id
        WHERE passages_fts MATCH '\(expression)' GROUP BY r.id ORDER BY r.id
        """,
        in: directory
    ).compactMap { UUID(uuidString: $0[0]) }
}

final class HistorySearchIndexTests: XCTestCase {
    private func record(
        _ id: UUID = UUID(),
        at seconds: TimeInterval = 1_700_000_000,
        title: String? = nil,
        version: String = "1",
        passages: [HistoryPassage]
    ) -> HistorySearchRecord {
        HistorySearchRecord(
            id: id, recordedAt: Date(timeIntervalSince1970: seconds), source: "mac", originDeviceID: "device",
            language: "en", durationSeconds: 5, title: title, appName: nil, bundleID: nil, domain: nil, versionID: nil,
            fingerprint: HistorySearchFingerprint(version: version, contentHash: "hash-\(version)"),
            passages: passages
        )
    }

    func testRecordsAreFoundByTextSpeakerAndTitleUntilTheyAreReplacedOrRemoved() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let index = HistorySearchIndex(directory: directory)
        let meetingID = UUID()
        let noteID = UUID()

        try await index.upsert([
            record(meetingID, title: "Weekly sync", passages: [
                HistoryPassage(
                    kind: .transcript, text: "Anna: The invoice export ships on Friday.",
                    speakers: ["Anna", "Ben"], startSeconds: 1, endSeconds: 9
                ),
                HistoryPassage(kind: .result, text: "Decision: ship the export.", utf16Range: 0..<26),
            ]),
            record(noteID, at: 1_700_000_100, passages: [
                HistoryPassage(kind: .transcript, text: "Termin bei Zahnärztin Müller verschieben.", utf16Range: 0..<41),
            ]),
        ])

        XCTAssertEqual(try recordIDs(matching: "invoice", in: directory), [meetingID])
        XCTAssertEqual(try recordIDs(matching: "speaker:ben", in: directory), [meetingID])
        XCTAssertEqual(try recordIDs(matching: "export", in: directory), [meetingID])
        // Diacritics fold, so a question typed without them finds the word.
        XCTAssertEqual(try recordIDs(matching: "zahnarztin", in: directory), [noteID])
        let titleHits = try indexRows(
            "SELECT r.uuid FROM titles_fts JOIN records r ON r.id = titles_fts.rowid WHERE titles_fts MATCH 'weekly'",
            in: directory
        )
        XCTAssertEqual(titleHits, [[meetingID.uuidString]])
        XCTAssertEqual(
            try indexRows("SELECT kind, speaker, start_seconds, char_end FROM passages ORDER BY id", in: directory),
            [["transcript", "Anna\nBen", "1.0", ""], ["result", "", "", "26"], ["transcript", "", "", "41"]]
        )

        try await index.upsert([
            record(meetingID, title: "Weekly sync", version: "2", passages: [
                HistoryPassage(kind: .transcript, text: "Anna: The payroll export ships on Friday.", speakers: ["Anna"]),
            ]),
        ])
        XCTAssertEqual(try recordIDs(matching: "invoice", in: directory), [])
        XCTAssertEqual(try recordIDs(matching: "payroll", in: directory), [meetingID])
        XCTAssertEqual(try recordIDs(matching: "speaker:ben", in: directory), [])
        let fingerprints = try await index.fingerprints()
        XCTAssertEqual(fingerprints, [
            meetingID: HistorySearchFingerprint(version: "2", contentHash: "hash-2"),
            noteID: HistorySearchFingerprint(version: "1", contentHash: "hash-1"),
        ])

        try await index.remove([meetingID, UUID()])
        XCTAssertEqual(try recordIDs(matching: "payroll OR export", in: directory), [])
        let counts = try await index.counts()
        XCTAssertEqual(counts.records, 1)
        XCTAssertEqual(counts.passages, 1)
        try await index.checkIntegrity()

        // A passage that full-text search has lost is a reason to build the index again.
        _ = try indexRows(
            "INSERT INTO passages_fts(passages_fts, rowid, text, speaker) SELECT 'delete', id, text, speaker FROM passages",
            in: directory, writing: true
        )
        XCTAssertEqual(try recordIDs(matching: "zahnarztin", in: directory), [])
        do {
            try await index.checkIntegrity()
            XCTFail("The check passed although full-text search lost a passage")
        } catch {}
    }

    func testPassageIDsFollowTheRecordingTimeAlsoForRecordsAddedLaterOrInTheSameSecond() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let index = HistorySearchIndex(directory: directory)
        let passages = [
            HistoryPassage(kind: .transcript, text: "First part."),
            HistoryPassage(kind: .transcript, text: "Second part."),
        ]
        let newer = UUID()
        let older = UUID()
        let sameSecond = UUID()

        try await index.upsert([record(newer, at: 1_700_000_500.2, passages: passages)])
        // Synced in later, and an import with the same time as another record.
        try await index.upsert([
            record(older, at: 1_600_000_000.9, passages: passages),
            record(sameSecond, at: 1_600_000_000.1, passages: passages),
        ])

        XCTAssertEqual(
            try indexRows("SELECT r.uuid, p.ordinal FROM passages p JOIN records r ON r.id = p.record_id ORDER BY p.id", in: directory),
            [older, sameSecond, newer].flatMap { [[$0.uuidString, "0"], [$0.uuidString, "1"]] }
        )
        // A period is a range of passage IDs.
        let perSecond = HistorySearchIndex.recordsPerSecond * HistorySearchIndex.passagesPerRecord
        XCTAssertEqual(
            try indexRows(
                "SELECT count(*) FROM passages WHERE id BETWEEN \(1_600_000_000 * perSecond) AND \(1_600_000_001 * perSecond - 1)",
                in: directory
            ),
            [["4"]]
        )
        XCTAssertEqual(
            try indexRows(
                "SELECT count(*) FROM passages WHERE id / \(HistorySearchIndex.passagesPerRecord) != record_id",
                in: directory
            ),
            [["0"]]
        )
    }

    func testADamagedOrOutdatedIndexFileIsReplacedAndAMissingOneIsNotCreatedByReading() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let file = directory.appendingPathComponent("index.sqlite")

        do {
            let index = HistorySearchIndex(directory: directory)
            try await index.remove([UUID()])
            let fingerprints = try await index.fingerprints()
            XCTAssertEqual(fingerprints, [:])
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

            try Data("not a database".utf8).write(to: file)
            try await index.upsert([record(passages: [HistoryPassage(kind: .transcript, text: "Hello.")])])
            let counts = try await index.counts()
            XCTAssertEqual(counts.records, 1)
            _ = try indexRows("UPDATE index_meta SET value = '0' WHERE key = 'format'", in: directory, writing: true)
        }

        // An index of another format is deleted instead of read.
        let reopened = HistorySearchIndex(directory: directory)
        let fingerprints = try await reopened.fingerprints()
        XCTAssertEqual(fingerprints, [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnIndexWithADamagedTableIsDeletedWhenItIsRead() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let file = directory.appendingPathComponent("index.sqlite")
        do {
            let index = HistorySearchIndex(directory: directory)
            try await index.upsert([record(passages: [HistoryPassage(kind: .transcript, text: "Hello.")])])
        }
        // The file still opens and names its format, but the records table is unreadable.
        _ = try indexRows("PRAGMA wal_checkpoint(TRUNCATE)", in: directory, writing: true)
        let page = try XCTUnwrap(Int(try indexRows("SELECT rootpage FROM sqlite_schema WHERE name = 'records'", in: directory)[0][0]))
        let pageSize = try XCTUnwrap(Int(try indexRows("PRAGMA page_size", in: directory)[0][0]))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64((page - 1) * pageSize))
        try handle.write(contentsOf: Data(repeating: 0xFF, count: pageSize))
        try handle.close()

        let index = HistorySearchIndex(directory: directory)
        let fingerprints = try await index.fingerprints()
        XCTAssertEqual(fingerprints, [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

@MainActor
final class HistorySearchIndexerTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let appSupportDirectory: URL
        let indexDirectory: URL
        let history: HistoryService
        let index: HistorySearchIndex
        var isEnabled = true
        var isBusy = false

        init(indexDirectory: URL? = nil) throws {
            appSupportDirectory = try TestSupport.makeTemporaryDirectory()
            self.indexDirectory = indexDirectory
                ?? appSupportDirectory.appendingPathComponent(HistorySearchIndex.directoryName, isDirectory: true)
            history = HistoryService(appSupportDirectory: appSupportDirectory)
            index = HistorySearchIndex(directory: self.indexDirectory)
        }

        func makeIndexer(retryDelay: Duration = .milliseconds(5)) -> HistorySearchIndexer {
            HistorySearchIndexer(
                historyService: history,
                index: index,
                isEnabled: { [unowned self] in self.isEnabled },
                isBusy: { [unowned self] in self.isBusy },
                upsertDelay: .milliseconds(5),
                busyRetryDelay: retryDelay
            )
        }

        @discardableResult
        func addDictation(_ text: String, id: UUID = UUID()) -> UUID {
            XCTAssertTrue(history.addRecord(
                id: id, rawText: text, finalText: text, appName: "Notes", appBundleIdentifier: "com.apple.Notes",
                durationSeconds: 3, language: "en", engineUsed: "test"
            ))
            return id
        }

        func matches(_ expression: String) throws -> [UUID] {
            try recordIDs(matching: expression, in: indexDirectory)
        }

        func indexedIDs() async throws -> Set<UUID> {
            Set(try await index.fingerprints().keys)
        }
    }

    private func eventually(
        _ condition: () async throws -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The index did not reach the expected state", file: file, line: line)
    }

    func testAddedChangedAndDeletedRecordsReachTheIndexAndDeleteHistoryDeletesIt() async throws {
        let fixture = try Fixture()
        defer { TestSupport.remove(fixture.appSupportDirectory) }
        let indexer = fixture.makeIndexer()

        let id = fixture.addDictation("We ship the invoice export on Friday.")
        try await eventually { try fixture.matches("invoice") == [id] }

        fixture.history.updateRecord(
            try XCTUnwrap(fixture.history.record(withID: id)), finalText: "We ship the payroll export on Friday."
        )
        try await eventually { try fixture.matches("payroll") == [id] }
        // The corrected word replaces the misheard one.
        XCTAssertEqual(try fixture.matches("invoice"), [])

        let otherID = fixture.addDictation("Book the dentist for Monday.")
        try await eventually { try await fixture.indexedIDs() == [id, otherID] }
        XCTAssertTrue(fixture.history.deleteRecord(withID: id))
        try await eventually { try await fixture.indexedIDs() == [otherID] }
        XCTAssertEqual(try fixture.matches("payroll"), [])

        XCTAssertTrue(fixture.history.clearAll())
        try await eventually { !FileManager.default.fileExists(atPath: fixture.indexDirectory.path) }
        withExtendedLifetime(indexer) {}
    }

    func testReconcileAddsMissingUpdatesChangedAndRemovesDeletedRecords() async throws {
        let fixture = try Fixture()
        defer { TestSupport.remove(fixture.appSupportDirectory) }
        let keptID = fixture.addDictation("The roadmap stays as planned.")
        let changedID = fixture.addDictation("We ship the invoice export on Friday.")
        let deletedID = fixture.addDictation("Book the dentist for Monday.")

        var indexer: HistorySearchIndexer? = fixture.makeIndexer()
        await indexer?.reconcile()
        try await eventually { try await fixture.indexedIDs() == [keptID, changedID, deletedID] }

        // History changes while nothing listens, as while the index is off.
        indexer = nil
        fixture.history.updateRecord(
            try XCTUnwrap(fixture.history.record(withID: changedID)), finalText: "We ship the payroll export on Friday."
        )
        XCTAssertTrue(fixture.history.deleteRecord(withID: deletedID))
        // Another device's record keeps that device's dates, which lie before the last check.
        let remoteID = UUID()
        let remoteDate = Date(timeIntervalSince1970: 1_600_000_000)
        try fixture.history.applyUserDataSyncMutations([
            .upsertHistoryContent(UserDataSyncHistoryContentV1(
                recordID: remoteID, createdAt: remoteDate, updatedAt: remoteDate,
                originDeviceID: "iphone", originPlatform: "iOS", source: RecordingSource.iPhone.rawValue,
                processingState: RecordingProcessingState.ready.rawValue,
                rawTranscript: "The budget review moves to March.", finalText: "The budget review moves to March.",
                durationSeconds: 4, detectedLanguage: "en", engineDisplayName: "test"
            )),
        ])

        indexer = fixture.makeIndexer()
        await indexer?.reconcile()
        try await eventually {
            try await fixture.indexedIDs() == [keptID, changedID, remoteID]
                && fixture.matches("payroll") == [changedID]
        }
        XCTAssertEqual(try fixture.matches("invoice OR dentist"), [])
        // The older record sorts before the ones indexed first.
        XCTAssertEqual(try fixture.matches("budget OR roadmap"), [remoteID, keptID])
        try await fixture.index.checkIntegrity()

        // Full-text search loses its entries while the records still look current.
        _ = try indexRows(
            "INSERT INTO passages_fts(passages_fts, rowid, text, speaker) SELECT 'delete', id, text, speaker FROM passages",
            in: fixture.indexDirectory, writing: true
        )
        XCTAssertEqual(try fixture.matches("budget"), [])
        await indexer?.reconcile(checkingContent: true)
        try await eventually { try fixture.matches("budget OR roadmap") == [remoteID, keptID] }
    }

    func testTheContentCheckFindsChangesThatSetNoDate() async throws {
        let fixture = try Fixture()
        defer { TestSupport.remove(fixture.appSupportDirectory) }
        let id = fixture.addDictation("Hello world.")
        var indexer: HistorySearchIndexer? = fixture.makeIndexer()
        await indexer?.reconcile()
        try await eventually { try await fixture.indexedIDs() == [id] }
        indexer = nil

        fixture.history.setTimedText(
            [TimedTextEntry(text: "Hello", start: 1.5, end: 2, utf16Location: 0, utf16Length: 5)],
            granularity: .word, forRecordID: id
        )
        indexer = fixture.makeIndexer()
        let passageTimes = "SELECT start_seconds, end_seconds FROM passages"
        await indexer?.reconcile()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try indexRows(passageTimes, in: fixture.indexDirectory), [["", ""]])

        await indexer?.reconcile(checkingContent: true)
        try await eventually { try indexRows(passageTimes, in: fixture.indexDirectory) == [["1.5", "2.0"]] }
    }

    func testWithoutPermissionTheIndexOnlyLosesDeletedAndChangedRecords() async throws {
        let fixture = try Fixture()
        defer { TestSupport.remove(fixture.appSupportDirectory) }
        let indexer = fixture.makeIndexer()
        let changedID = fixture.addDictation("We ship the invoice export on Friday.")
        let deletedID = fixture.addDictation("Book the dentist for Monday.")
        try await eventually { try await fixture.indexedIDs() == [changedID, deletedID] }

        // As after Premium ended: the old text of a changed record must not stay behind.
        fixture.isEnabled = false
        fixture.history.updateRecord(
            try XCTUnwrap(fixture.history.record(withID: changedID)), finalText: "We ship the payroll export on Friday."
        )
        try await eventually { try await fixture.indexedIDs() == [deletedID] }
        let addedID = fixture.addDictation("The roadmap stays as planned.")
        XCTAssertTrue(fixture.history.deleteRecord(withID: deletedID))
        try await eventually { try await fixture.indexedIDs().isEmpty }
        await indexer.reconcile(checkingContent: true)
        try await Task.sleep(for: .milliseconds(100))
        let whileOff = try await fixture.indexedIDs()
        XCTAssertEqual(whileOff, [])

        fixture.isEnabled = true
        await indexer.reconcile()
        try await eventually { try await fixture.indexedIDs() == [changedID, addedID] }
        XCTAssertEqual(try fixture.matches("payroll"), [changedID])
    }

    func testIndexingWaitsWhileADictationOrRecordingRunsButDeletionsDoNot() async throws {
        let fixture = try Fixture()
        defer { TestSupport.remove(fixture.appSupportDirectory) }
        let indexer = fixture.makeIndexer()
        let firstID = fixture.addDictation("We ship the invoice export on Friday.")
        try await eventually { try await fixture.indexedIDs() == [firstID] }

        fixture.isBusy = true
        let secondID = fixture.addDictation("Book the dentist for Monday.")
        XCTAssertTrue(fixture.history.deleteRecord(withID: firstID))
        try await eventually { try await fixture.indexedIDs().isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        let whileBusy = try await fixture.indexedIDs()
        XCTAssertEqual(whileBusy, [])

        fixture.isBusy = false
        try await eventually { try await fixture.indexedIDs() == [secondID] }
        withExtendedLifetime(indexer) {}
    }

    func testAnUpdateThatFailsIsTriedAgain() async throws {
        let lockedDirectory = try TestSupport.makeTemporaryDirectory()
        func setLocked(_ locked: Bool) throws {
            try FileManager.default.setAttributes(
                [.posixPermissions: locked ? 0o555 : 0o755], ofItemAtPath: lockedDirectory.path
            )
        }
        let fixture = try Fixture(indexDirectory: lockedDirectory.appendingPathComponent("HistorySearch", isDirectory: true))
        defer {
            try? setLocked(false)
            TestSupport.remove(lockedDirectory)
            TestSupport.remove(fixture.appSupportDirectory)
        }
        let indexer = fixture.makeIndexer(retryDelay: .milliseconds(300))

        // The index folder cannot be created, so the first attempt fails.
        try setLocked(true)
        let id = fixture.addDictation("We ship the invoice export on Friday.")
        let deletedID = fixture.addDictation("Book the dentist for Monday.")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.indexDirectory.path))

        // A record deleted before the next attempt is not part of it.
        XCTAssertTrue(fixture.history.deleteRecord(withID: deletedID))
        try setLocked(false)
        try await eventually { try await fixture.indexedIDs() == [id] }
        withExtendedLifetime(indexer) {}
    }

    func testAnUpdateThatKeepsFailingIsLeftToTheNextCheck() async throws {
        let lockedDirectory = try TestSupport.makeTemporaryDirectory()
        func setLocked(_ locked: Bool) throws {
            try FileManager.default.setAttributes(
                [.posixPermissions: locked ? 0o555 : 0o755], ofItemAtPath: lockedDirectory.path
            )
        }
        let fixture = try Fixture(indexDirectory: lockedDirectory.appendingPathComponent("HistorySearch", isDirectory: true))
        defer {
            try? setLocked(false)
            TestSupport.remove(lockedDirectory)
            TestSupport.remove(fixture.appSupportDirectory)
        }
        let indexer = fixture.makeIndexer(retryDelay: .milliseconds(20))

        // The first attempt and its three retries all fail.
        try setLocked(true)
        let id = fixture.addDictation("We ship the invoice export on Friday.")
        try await Task.sleep(for: .milliseconds(1_500))
        try setLocked(false)
        try await Task.sleep(for: .milliseconds(200))
        let afterRetries = try await fixture.indexedIDs()
        XCTAssertEqual(afterRetries, [])

        await indexer.reconcile()
        try await eventually { try await fixture.indexedIDs() == [id] }
    }

    func testADeletionDoesNotWaitForAWorkerThatPauses() async throws {
        let fixture = try Fixture()
        defer { TestSupport.remove(fixture.appSupportDirectory) }
        let indexer = fixture.makeIndexer(retryDelay: .seconds(60))
        let id = fixture.addDictation("We ship the invoice export on Friday.")
        try await eventually { try await fixture.indexedIDs() == [id] }

        // The worker now waits a minute before it looks at the new record again.
        fixture.isBusy = true
        fixture.addDictation("Book the dentist for Monday.")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.history.deleteRecord(withID: id))
        try await eventually { try await fixture.indexedIDs().isEmpty }
        await indexer.stop()
    }

    func testAfterStoppingNothingIsWrittenAnymore() async throws {
        let fixture = try Fixture()
        defer { TestSupport.remove(fixture.appSupportDirectory) }
        let indexer = fixture.makeIndexer()
        let firstID = fixture.addDictation("We ship the invoice export on Friday.")
        try await eventually { try await fixture.indexedIDs() == [firstID] }

        // As before "Delete All Data": a change that waits and later ones stay out.
        fixture.addDictation("Book the dentist for Monday.")
        await indexer.stop()
        fixture.addDictation("The roadmap stays as planned.")
        await indexer.reconcile(checkingContent: true)
        try await Task.sleep(for: .milliseconds(100))
        let indexed = try await fixture.indexedIDs()
        XCTAssertEqual(indexed, [firstID])
    }

    func testADictationKeepsItsAppARecordingItsTitleAndAWrittenResultStandsNextToWhatWasSaid() throws {
        let dictation = TranscriptionRecord(
            rawText: "we ship the invoice export on friday", finalText: "We ship the invoice export on Friday.",
            appName: "Safari", appBundleIdentifier: "com.apple.Safari", appURL: "https://github.com/TypeWhisper",
            durationSeconds: 3, engineUsed: "test"
        )
        dictation.timedText = [
            TimedTextEntry(text: "We", start: 0.5, end: 0.7, utf16Location: 0, utf16Length: 2),
            // The engine wrote "friday"; the corrected text has another word there.
            TimedTextEntry(text: "friday", start: 2.5, end: 3, utf16Location: 30, utf16Length: 6),
        ]
        let indexedDictation = try XCTUnwrap(HistorySearchRecord(dictation))
        XCTAssertNil(indexedDictation.title)
        XCTAssertEqual(indexedDictation.appName, "Safari")
        XCTAssertEqual(indexedDictation.bundleID, "com.apple.Safari")
        XCTAssertEqual(indexedDictation.domain, "github.com")
        XCTAssertEqual(indexedDictation.passages, [
            HistoryPassage(
                kind: .transcript, text: "We ship the invoice export on Friday.",
                startSeconds: 0.5, endSeconds: 0.7, utf16Range: 0..<37
            ),
        ])

        let recording = TranscriptionRecord(
            rawText: "The roadmap stays as planned.", finalText: "The roadmap stays as planned.",
            appName: "Weekly sync", durationSeconds: 60, engineUsed: "test"
        )
        recording.source = .recorder
        let indexedRecording = try XCTUnwrap(HistorySearchRecord(recording))
        XCTAssertEqual(indexedRecording.title, "Weekly sync")
        XCTAssertNil(indexedRecording.appName)
        XCTAssertEqual(indexedRecording.source, "recorder")

        let email = TranscriptionRecord(
            rawText: "schreib dem team dass das meeting morgen ausfällt",
            finalText: "Hallo Team,\n\nder Termin findet morgen nicht statt.\n\nViele Grüße",
            appName: "Mail", appBundleIdentifier: "com.apple.mail", durationSeconds: 4, engineUsed: "test"
        )
        XCTAssertEqual(try XCTUnwrap(HistorySearchRecord(email)).passages.map(\.kind), [.transcript, .result])
        XCTAssertEqual(try XCTUnwrap(HistorySearchRecord(email)).passages.first?.text, email.rawText)

        email.processingState = .transcribing
        XCTAssertNil(HistorySearchRecord(email))
    }

    func testARecordWithSpeakersIsIndexedByTurnsWithTheirNames() throws {
        let record = TranscriptionRecord(
            rawText: "Good morning. Fine, thanks.", finalText: "Good morning. Fine, thanks.",
            appName: "Standup", durationSeconds: 5, engineUsed: "test"
        )
        let transcript = SpeakerTranscript(source: .localDiarizer, segments: [
            SpeakerTranscriptSegment(text: "Good morning.", start: 0, end: 2, speakerID: "S1"),
            SpeakerTranscriptSegment(text: "Fine,", start: 2, end: 3, speakerID: "S2"),
            SpeakerTranscriptSegment(text: "thanks.", start: 3, end: 4, speakerID: nil),
        ])
        record.speakerTranscript = transcript
        record.speakerNames = SpeakerNameTable(transcriptRevision: transcript.revision, entries: [
            SpeakerNameTable.Entry(speakerID: "S1", displayName: "Anna"),
            SpeakerNameTable.Entry(speakerID: "S2", displayName: "Ben"),
        ])

        // Until detection has finished, the record is indexed as plain text.
        record.speakerTranscriptState = .pending
        XCTAssertEqual(try XCTUnwrap(HistorySearchRecord(record)).passages.map(\.speakers), [[]])
        let pendingVersion = HistorySearchRecord.version(of: record)

        record.speakerTranscriptState = .ready
        XCTAssertNotEqual(HistorySearchRecord.version(of: record), pendingVersion)
        let turns = HistoryPassage(
            kind: .transcript, text: "Anna: Good morning.\nBen: Fine, thanks.",
            speakers: ["Anna", "Ben"], startSeconds: 0, endSeconds: 4
        )
        XCTAssertEqual(try XCTUnwrap(HistorySearchRecord(record)).passages, [turns])

        // The speaker transcript keeps the engine's words, so a corrected text is indexed next to it.
        record.finalText = "Good morning. Fine, thank you."
        XCTAssertEqual(try XCTUnwrap(HistorySearchRecord(record)).passages, [
            turns,
            HistoryPassage(kind: .result, text: "Good morning. Fine, thank you.", utf16Range: 0..<30),
        ])
    }
}
