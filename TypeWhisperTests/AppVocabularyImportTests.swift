import CryptoKit
import SQLite3
import XCTest
@testable import TypeWhisper

final class AppVocabularyImportTests: XCTestCase {
    private typealias Entry = AppVocabularyImport.Entry

    func testWizardDiscoveryChecksKnownFilePathsWithoutParsingOrCreatingFiles() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        XCTAssertEqual(AppVocabularyImport.detectedSources(applicationSupport: directory), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])

        // Invalid contents still count as a presence hint; validation only happens after opt-in.
        for source in [AppVocabularyImport.Source.wisprFlow, .handy] {
            let url = try XCTUnwrap(source.defaultURL(in: directory))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Not parsed during discovery".utf8).write(to: url)
        }
        XCTAssertEqual(AppVocabularyImport.detectedSources(applicationSupport: directory), [.wisprFlow, .handy])
        XCTAssertNil(AppVocabularyImport.Source.wisprCSV.defaultURL(in: directory))
    }

    func testWizardDiscoveryRejectsDirectoriesAndSymlinks() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let wispr = try XCTUnwrap(AppVocabularyImport.Source.wisprFlow.defaultURL(in: directory))
        let handy = try XCTUnwrap(AppVocabularyImport.Source.handy.defaultURL(in: directory))
        try FileManager.default.createDirectory(at: wispr, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: handy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = directory.appendingPathComponent("other.json")
        try Data("{}".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: handy, withDestinationURL: other)
        XCTAssertEqual(AppVocabularyImport.detectedSources(applicationSupport: directory), [])
    }

    @MainActor
    func testWizardCanPreselectHandyWithoutReadingOrWriting() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let dictionary = DictionaryService(appSupportDirectory: directory)
        let snippets = SnippetService(appSupportDirectory: directory)
        let model = AppVocabularyImportViewModel(destination: .dictionary, source: .handy, dictionary: dictionary, snippets: snippets)
        XCTAssertEqual(model.source, .handy)
        XCTAssertNil(model.batch)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(dictionary.entries.isEmpty)
        XCTAssertTrue(snippets.snippets.isEmpty)
        let snippetModel = AppVocabularyImportViewModel(destination: .snippets, source: .handy, dictionary: dictionary, snippets: snippets)
        XCTAssertEqual(snippetModel.source, .wisprFlow)
        XCTAssertTrue(snippetModel.sources.contains(snippetModel.source))
    }

    func testHandyOnlyImportsCustomWords() throws {
        let data = Data(#"{"settings":{"custom_words":[" Kubernetes ","Swift","  "],"custom_filler_words":["um"],"api_key":"ignored"}}"#.utf8)
        let batch = try AppVocabularyImport.parseHandy(data)
        XCTAssertEqual(batch.entries.map(\.original), ["Kubernetes", "Swift"])
        XCTAssertEqual(batch.excluded, 1)
        XCTAssertTrue(batch.entries.allSatisfy { $0.kind == .term })
        XCTAssertTrue(try AppVocabularyImport.parseHandy(Data("{}".utf8)).entries.isEmpty)
        XCTAssertThrowsError(try AppVocabularyImport.parseHandy(Data(#"{"settings":{"custom_words":[42]}}"#.utf8)))
    }

    func testHandyLimitsBeforeFiltering() throws {
        let data = try JSONSerialization.data(withJSONObject: ["settings": ["custom_words": Array(repeating: "", count: 25_001)]])
        XCTAssertThrowsError(try AppVocabularyImport.parseHandy(data))
    }

    func testHandyRetriesIdenticalTruncatedReadsAndRejectsUnstableReads() throws {
        let valid = Data(#"{"settings":{"custom_words":["Stable"]}}"#.utf8)
        var reads = [Data(), Data(), valid, valid]
        let batch = try AppVocabularyImport.readHandy { reads.removeFirst() }
        XCTAssertEqual(batch.entries.first?.original, "Stable")
        XCTAssertTrue(reads.isEmpty)
        var count = 0
        XCTAssertThrowsError(try AppVocabularyImport.readHandy {
            count += 1
            return count % 2 == 0 ? valid : Data("{}".utf8)
        })
        XCTAssertEqual(count, 6)
    }

    func testHandyReportsInvalidFormatForStableUnparseableReads() throws {
        let invalid = Data(#"[1, 2, 3]"#.utf8)
        var reads = [invalid, invalid]
        XCTAssertThrowsError(try AppVocabularyImport.readHandy { reads.removeFirst() }) { error in
            guard case AppVocabularyImportError.invalidFormat = error else {
                return XCTFail("expected invalidFormat, got \(error)")
            }
        }
        XCTAssertTrue(reads.isEmpty)
    }

    func testHandyRetriesTruncatedJSONUntilAStablePairParses() throws {
        // A mid-write read is a prefix of valid JSON; it must be retried
        // until two identical reads parse.
        let truncated = Data(#"{"settings":{"custom_words":["Stable"]"#.utf8)
        let valid = Data(#"{"settings":{"custom_words":["Stable"]}}"#.utf8)
        var reads = [truncated, truncated, valid, valid]
        let batch = try AppVocabularyImport.readHandy { reads.removeFirst() }
        XCTAssertEqual(batch.entries.first?.original, "Stable")
        XCTAssertTrue(reads.isEmpty)
    }

    func testHandyRetriesReadSplitInsideMultibyteCharacter() throws {
        // A mid-write read can stop inside a multibyte character. The trailing
        // bytes are potentially incomplete, not invalid, so the read must be
        // retried until two identical reads parse.
        let valid = Data(#"{"settings":{"custom_words":["Stäble"]}}"#.utf8)
        let lead = valid.firstIndex(of: 0xC3)!
        let partial = Data(valid.prefix(through: lead))
        var reads = [partial, partial, valid, valid]
        let batch = try AppVocabularyImport.readHandy { reads.removeFirst() }
        XCTAssertEqual(batch.entries.first?.original, "Stäble")
        XCTAssertTrue(reads.isEmpty)
    }

    func testHandyReportsInvalidFormatForIrrecoverableUTF8Tail() throws {
        // A stray continuation byte cannot complete on retry, so it must fail
        // fast as an invalid format instead of burning the bounded retries.
        var broken = Data(#"{"settings":{"custom_words":["St"#.utf8)
        broken.append(0x80)
        broken.append(contentsOf: Data(#"]}}"#.utf8))
        var reads = 0
        XCTAssertThrowsError(try AppVocabularyImport.readHandy {
            reads += 1
            return broken
        }) { error in
            guard case AppVocabularyImportError.invalidFormat = error else {
                return XCTFail("expected invalidFormat, got \(error)")
            }
        }
        XCTAssertEqual(reads, 2)
    }

    func testHandyReportsInvalidFormatForStableMalformedJSON() throws {
        // Syntactically broken but complete input cannot settle into valid
        // JSON, so it must fail fast as an invalid format, not unstableSource.
        var reads = 0
        XCTAssertThrowsError(try AppVocabularyImport.readHandy {
            reads += 1
            return Data("not handy json".utf8)
        }) { error in
            guard case AppVocabularyImportError.invalidFormat = error else {
                return XCTFail("expected invalidFormat, got \(error)")
            }
        }
        // Only the first pair is read; no retry is attempted.
        XCTAssertEqual(reads, 2)
    }

    func testHeaderlessCSVPreservesHeaderLikeFirstEntries() throws {
        for word in ["word", "term", "phrase", "original", "trigger"] {
            let batch = try AppVocabularyImport.parseCSV(Data("\(word)\nsecond\n".utf8), destination: .dictionary)
            XCTAssertEqual(batch.entries.map(\.original), [word, "second"])
        }
        let batch = try AppVocabularyImport.parseCSV(Data("original,replacement\nsecond,value\n".utf8), destination: .snippets)
        XCTAssertEqual(batch.entries.map(\.original), ["original", "second"])
    }

    @MainActor
    func testReviewUsesRuntimeUnicodeCaseFolding() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let snippets = SnippetService(appSupportDirectory: dir)
        snippets.addSnippet(trigger: "straße", replacement: "Keep")
        XCTAssertEqual(snippets.applySnippets(to: "STRASSE"), "Keep")
        let candidate = Entry(kind: .snippet, original: "STRASSE", replacement: "Different")
        XCTAssertEqual(AppVocabularyImport.review(.init(entries: [candidate]), existing: snippets.appImportSnapshot).first?.outcome, .conflict)
        for (a, b) in [("straße", "STRASSE"), ("ς", "Σ"), ("é", "e\u{301}")] {
            let batch = AppVocabularyImport.Batch(entries: [Entry(kind: .term, original: a, replacement: nil), Entry(kind: .term, original: b, replacement: nil)])
            XCTAssertEqual(AppVocabularyImport.review(batch, existing: []).map(\.outcome), [.add, .duplicate])
        }
    }

    func testTurkishDictionaryCollisionsMatchLocaleWhileSnippetsRemainLocaleIndependent() {
        let turkish = Locale(identifier: "tr_TR")
        XCTAssertNotEqual("I".compare("i", options: .caseInsensitive, locale: turkish), .orderedSame)
        XCTAssertEqual("I".compare("ı", options: .caseInsensitive, locale: turkish), .orderedSame)
        XCTAssertEqual("İ".compare("i", options: .caseInsensitive, locale: turkish), .orderedSame)
        let existing = AppVocabularyImport.Existing(id: UUID(), entry: Entry(kind: .correction, original: "I", replacement: "Same"), caseSensitive: false, isEnabled: true)
        let batch = AppVocabularyImport.Batch(entries: [
            Entry(kind: .correction, original: "i", replacement: "Same"),
            Entry(kind: .correction, original: "ı", replacement: "Different"),
            Entry(kind: .correction, original: "İ", replacement: "Same")
        ])
        XCTAssertEqual(AppVocabularyImport.review(batch, existing: [existing], dictionaryLocale: turkish).map(\.outcome), [.add, .conflict, .duplicate])
        let snippets = AppVocabularyImport.Batch(entries: [
            Entry(kind: .snippet, original: "I", replacement: "Same"),
            Entry(kind: .snippet, original: "i", replacement: "Same")
        ])
        XCTAssertNotNil("I".range(of: "i", options: .caseInsensitive))
        XCTAssertEqual(AppVocabularyImport.review(snippets, existing: [], dictionaryLocale: turkish).map(\.outcome), [.add, .duplicate])
    }

    @MainActor
    func testFailedImportsPreserveDeferredUsageCounts() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let dictionary = DictionaryService(appSupportDirectory: dir)
        dictionary.addEntry(type: .correction, original: "teh", replacement: "the")
        XCTAssertEqual(dictionary.applyCorrections(to: "teh", deferUsageCountSave: true), "the")
        dictionary.appImportSaveOverride = { throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try dictionary.importReviewedEntries([Entry(kind: .term, original: "Discard", replacement: nil)], baseline: dictionary.appImportSnapshot))
        XCTAssertEqual(dictionary.entries.first?.usageCount, 1)
        dictionary.saveDeferredUsageCounts()
        let reloadedDictionary = DictionaryService(appSupportDirectory: dir)
        XCTAssertEqual(reloadedDictionary.entries.map(\.original), ["teh"])
        XCTAssertEqual(reloadedDictionary.entries.first?.usageCount, 1)

        let snippets = SnippetService(appSupportDirectory: dir)
        snippets.addSnippet(trigger: "sig", replacement: "Signature")
        XCTAssertEqual(snippets.applySnippets(to: "sig", deferUsageCountSave: true), "Signature")
        snippets.appImportSaveOverride = { throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try snippets.importReviewedEntries([Entry(kind: .snippet, original: "Discard", replacement: "No")], baseline: snippets.appImportSnapshot))
        XCTAssertEqual(snippets.snippets.first?.usageCount, 1)
        snippets.saveDeferredUsageCounts()
        let reloadedSnippets = SnippetService(appSupportDirectory: dir)
        XCTAssertEqual(reloadedSnippets.snippets.map(\.trigger), ["sig"])
        XCTAssertEqual(reloadedSnippets.snippets.first?.usageCount, 1)
    }

    func testCSVWordsCorrectionsBOMAndCRLF() throws {
        let data = Data("\u{FEFF}phrase,replacement\r\nKubernetes,\r\nante ropic,Anthropic\r\n\"ACME, Inc.\",\r\n".utf8)
        let batch = try AppVocabularyImport.parseCSV(data, destination: .dictionary, hasHeader: true)
        XCTAssertEqual(batch.entries, [
            Entry(kind: .term, original: "Kubernetes", replacement: nil),
            Entry(kind: .correction, original: "ante ropic", replacement: "Anthropic"),
            Entry(kind: .term, original: "ACME, Inc.", replacement: nil)
        ])
    }

    func testCSVSnippetWhitespaceQuotesAndMultiline() throws {
        let data = Data("trigger,replacement\r\nsig,\" Hello \"\"there\"\"\r\nRegards  \"\r\n".utf8)
        let batch = try AppVocabularyImport.parseCSV(data, destination: .snippets, hasHeader: true)
        XCTAssertEqual(batch.entries.first?.replacement, " Hello \"there\"\nRegards  ")
    }

    func testMalformedCSVNeverReturnsPartialImport() {
        for csv in ["good,ok\n\"unterminated", "good,ok\nbad\"quote,x", "\"bad\"suffix,x"] {
            XCTAssertThrowsError(try AppVocabularyImport.parseCSV(Data(csv.utf8), destination: .dictionary))
        }
    }

    func testSnippetPlaceholdersAreNotActivatedByImport() throws {
        let batch = try AppVocabularyImport.parseCSV(
            Data("trigger,replacement\nclip,{{CLIPBOARD}}\ndate,{date:yyyy}\nplain,Hello\n".utf8), destination: .snippets, hasHeader: true)
        XCTAssertEqual(batch.entries.map(\.original), ["plain"])
        XCTAssertEqual(batch.excluded, 2)
    }

    func testReviewSeparatesDuplicateConflictAndSourceCollision() {
        let existing = AppVocabularyImport.Existing(id: UUID(), entry: Entry(kind: .correction, original: "teh", replacement: "the"), caseSensitive: false, isEnabled: true)
        let entries = [existing.entry,
                       Entry(kind: .correction, original: "TEH", replacement: "different"),
                       Entry(kind: .term, original: "New", replacement: nil),
                       Entry(kind: .term, original: "New", replacement: nil)]
        let review = AppVocabularyImport.review(.init(entries: entries), existing: [existing])
        XCTAssertEqual(review.map(\.outcome), [.duplicate, .conflict, .add, .duplicate])
    }

    func testReviewTreatsDisabledAndCaseSensitiveMatchesAsConflicts() {
        let entry = Entry(kind: .snippet, original: "signature", replacement: "My signature")
        let enabled = AppVocabularyImport.Existing(id: UUID(), entry: entry, caseSensitive: false, isEnabled: true)
        let disabled = AppVocabularyImport.Existing(id: UUID(), entry: entry, caseSensitive: false, isEnabled: false)
        let caseSensitive = AppVocabularyImport.Existing(id: UUID(), entry: entry, caseSensitive: true, isEnabled: true)
        for existing in [[disabled], [caseSensitive], [enabled, disabled], [enabled, caseSensitive]] {
            XCTAssertEqual(AppVocabularyImport.review(.init(entries: [entry]), existing: existing).first?.outcome, .conflict)
        }
        XCTAssertEqual(AppVocabularyImport.review(.init(entries: [entry]), existing: [enabled]).first?.outcome, .duplicate)
    }

    @MainActor
    func testWisprCanonicalSpellingBecomesBothRecognitionHintAndCorrection() throws {
        var batch = AppVocabularyImport.Batch()
        AppVocabularyImport.appendWisprWord(original: "type whisper", replacement: "TypeWhisper", to: &batch)
        XCTAssertEqual(batch.entries, [
            Entry(kind: .term, original: "TypeWhisper", replacement: nil),
            Entry(kind: .correction, original: "type whisper", replacement: "TypeWhisper")
        ])
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let dictionary = DictionaryService(appSupportDirectory: directory)
        XCTAssertTrue(try dictionary.importReviewedEntries(batch.entries, baseline: dictionary.appImportSnapshot))
        XCTAssertEqual(dictionary.enabledTerms(), ["TypeWhisper"])
        XCTAssertEqual(dictionary.applyCorrections(to: "I use type whisper"), "I use TypeWhisper")
    }

    @MainActor
    func testMacCorrectionsPreserveLiteralBackslashes() throws {
        var batch = AppVocabularyImport.Batch()
        AppVocabularyImport.appendWisprWord(original: "path", replacement: #"C:\new"#, to: &batch)
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let dictionary = DictionaryService(appSupportDirectory: directory)
        XCTAssertTrue(try dictionary.importReviewedEntries(batch.entries, baseline: dictionary.appImportSnapshot))
        XCTAssertEqual(dictionary.applyCorrections(to: "path"), #"C:\new"#)
    }

    func testWisprIncludesCommittedWALWithoutTouchingSource() throws {
        try withDatabase(wal: true) { db, url, scratch in
            try execute(db, "INSERT INTO Dictionary VALUES ('1','Kubernetes',NULL,0,0), ('2','teh','the',0,0), ('3','sig','Hello\nWorld',0,1), ('4','removed',NULL,1,0)")
            let before = try sourceBytes(url)
            let words = try WisprFlowImportReader.read(url: url, destination: .dictionary, scratchParent: scratch)
            let snippets = try WisprFlowImportReader.read(url: url, destination: .snippets, scratchParent: scratch)
            XCTAssertEqual(words.entries.map(\.original), ["Kubernetes", "the", "teh"])
            XCTAssertEqual(words.entries.last?.replacement, "the")
            XCTAssertEqual(words.excluded, 2)
            XCTAssertEqual(snippets.entries.map(\.original), ["sig"])
            XCTAssertEqual(snippets.entries.first?.replacement, "Hello\nWorld")
            XCTAssertEqual(snippets.excluded, 3)
            XCTAssertEqual(try sourceBytes(url), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
        }
    }

    func testWisprReadsCleanlyClosedWALDatabaseWithoutCreatingSourceSidecars() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let url = directory.appendingPathComponent("flow.sqlite")
        let scratch = directory.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Match a real Wispr Flow database after the app has checkpointed and quit.
        func createSource() throws {
            var pointer: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
            let db = try XCTUnwrap(pointer)
            defer { XCTAssertEqual(sqlite3_close(db), SQLITE_OK) }
            try execute(db, "PRAGMA journal_mode=WAL; CREATE TABLE Dictionary (id TEXT PRIMARY KEY, phrase TEXT, replacement TEXT, isDeleted INTEGER, isSnippet INTEGER); INSERT INTO Dictionary VALUES ('1','CleanWAL',NULL,0,0)")
            try execute(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try createSource()
        // Some system SQLite configurations retain empty sidecars after closing.
        // Remove only the checkpointed fixture's sidecars to reproduce their absence.
        let wal = URL(fileURLWithPath: url.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            XCTAssertEqual(try Data(contentsOf: wal).count, 0)
            try FileManager.default.removeItem(at: wal)
        }
        let shm = URL(fileURLWithPath: url.path + "-shm")
        if FileManager.default.fileExists(atPath: shm.path) {
            try FileManager.default.removeItem(at: shm)
        }
        let before = try sourceBytes(url)
        XCTAssertEqual(Set(before.keys), [""])
        let batch = try WisprFlowImportReader.read(url: url, destination: .dictionary, scratchParent: scratch)
        XCTAssertEqual(batch.entries, [Entry(kind: .term, original: "CleanWAL", replacement: nil)])
        XCTAssertEqual(try sourceBytes(url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    func testWisprRejectsSourceChangesAndCleansUp() throws {
        try withDatabase { db, url, scratch in
            try execute(db, "INSERT INTO Dictionary VALUES ('1','aaa',NULL,0,0)")
            var attempts = 0
            XCTAssertThrowsError(try WisprFlowImportReader.read(url: url, destination: .dictionary, scratchParent: scratch, afterCopy: {
                attempts += 1
                let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]!
                try self.execute(db, "UPDATE Dictionary SET phrase = '\(attempts % 2 == 0 ? "aaa" : "bbb")'")
                // Same size and restored mtime must not bypass content verification.
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }))
            XCTAssertEqual(attempts, 3)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
        }
    }

    func testWisprRetriesTransientChange() throws {
        try withDatabase { db, url, scratch in
            try execute(db, "INSERT INTO Dictionary VALUES ('1','old',NULL,0,0)")
            var attempts = 0
            let batch = try WisprFlowImportReader.read(url: url, destination: .dictionary, scratchParent: scratch, afterCopy: {
                attempts += 1
                if attempts == 1 { try self.execute(db, "UPDATE Dictionary SET phrase = 'new'") }
            })
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(batch.entries.first?.original, "new")
        }
    }

    func testWisprRejectsRollbackJournalAndSymlink() throws {
        try withDatabase { db, url, scratch in
            try execute(db, "INSERT INTO Dictionary VALUES ('1','test',NULL,0,0)")
            let journal = URL(fileURLWithPath: url.path + "-journal")
            try Data().write(to: journal)
            XCTAssertThrowsError(try WisprFlowImportReader.read(url: url, destination: .dictionary, scratchParent: scratch))
            try FileManager.default.removeItem(at: journal)
            let link = url.deletingLastPathComponent().appendingPathComponent("link.sqlite")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            XCTAssertThrowsError(try WisprFlowImportReader.read(url: link, destination: .dictionary, scratchParent: scratch))
        }
    }

    func testWisprRejectsMalformedRowsWithoutPartialBatch() throws {
        try withDatabase { db, url, scratch in
            try execute(db, "INSERT INTO Dictionary VALUES ('1','valid',NULL,0,0), ('2','bad',NULL,2,0)")
            var attempts = 0
            XCTAssertThrowsError(try WisprFlowImportReader.read(url: url, destination: .dictionary, scratchParent: scratch, afterCopy: { attempts += 1 })) { error in
                guard case AppVocabularyImportError.invalidFormat = error else { return XCTFail("Wrong error: \(error)") }
            }
            XCTAssertEqual(attempts, 1)
        }
    }

    func testWisprMissingTableReportsInvalidFormatWithoutRetrying() throws {
        try withDatabase { db, url, scratch in
            try execute(db, "DROP TABLE Dictionary")
            var attempts = 0
            XCTAssertThrowsError(try WisprFlowImportReader.read(url: url, destination: .dictionary, scratchParent: scratch, afterCopy: { attempts += 1 })) { error in
                guard case AppVocabularyImportError.invalidFormat = error else { return XCTFail("Wrong error: \(error)") }
            }
            XCTAssertEqual(attempts, 1)
        }
    }

    @MainActor
    func testCSVHeaderChoiceReloadsPreviewWithoutWriting() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let dictionary = DictionaryService(appSupportDirectory: dir)
        let snippets = SnippetService(appSupportDirectory: dir)
        let model = AppVocabularyImportViewModel(destination: .dictionary, dictionary: dictionary, snippets: snippets)
        let file = dir.appendingPathComponent("words.csv")
        try Data("word\nSwift\n".utf8).write(to: file)
        model.source = .wisprCSV
        model.load(file)
        try await waitForLoad(model)
        XCTAssertEqual(model.rows.map(\.entry.original), ["word", "Swift"])
        model.csvHasHeader = true
        model.reloadCSV()
        try await waitForLoad(model)
        XCTAssertEqual(model.rows.map(\.entry.original), ["Swift"])
        XCTAssertTrue(dictionary.entries.isEmpty)
        model.csvHasHeader = false
        model.reloadCSV()
        try await waitForLoad(model)
        XCTAssertEqual(model.rows.map(\.entry.original), ["word", "Swift"])
        XCTAssertTrue(dictionary.entries.isEmpty)
        model.reset()
        model.reloadCSV()
        XCTAssertNil(model.batch)
        XCTAssertFalse(model.isLoading)
    }

    func testWisprVerifiesCopiedBytes() throws {
        try withDatabase { db, url, scratch in
            try execute(db, "INSERT INTO Dictionary VALUES ('1','original',NULL,0,0)")
            var attempt = 0
            XCTAssertThrowsError(try WisprFlowImportReader.read(url: url, destination: .dictionary, scratchParent: scratch, afterCopy: {
                let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil).first)
                let copy = folder.appendingPathComponent("\(attempt)/flow.sqlite")
                attempt += 1
                var pointer: OpaquePointer?
                XCTAssertEqual(sqlite3_open(copy.path, &pointer), SQLITE_OK)
                defer { sqlite3_close(pointer) }
                try self.execute(try XCTUnwrap(pointer), "UPDATE Dictionary SET phrase = 'tampered'")
            }))
            XCTAssertEqual(attempt, 3)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
        }
    }

    func testWisprCountsDeletedRowsTowardLimit() throws {
        try withDatabase { db, url, scratch in
            try execute(db, "WITH RECURSIVE rows(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM rows WHERE n<25001) INSERT INTO Dictionary SELECT CAST(n AS TEXT),'deleted',NULL,1,0 FROM rows")
            XCTAssertThrowsError(try WisprFlowImportReader.read(url: url, destination: .dictionary, scratchParent: scratch)) { error in
                guard case AppVocabularyImportError.tooLarge = error else { return XCTFail("Wrong error: \(error)") }
            }
        }
    }

    @MainActor
    func testDictionaryCommitPersistsAndRejectsStaleReview() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = DictionaryService(appSupportDirectory: dir)
        let baseline = service.appImportSnapshot
        let entries = [Entry(kind: .term, original: "Swift", replacement: nil), Entry(kind: .correction, original: "teh", replacement: "the")]
        XCTAssertTrue(try service.importReviewedEntries(entries, baseline: baseline))
        XCTAssertEqual(DictionaryService(appSupportDirectory: dir).entries.count, 2)
        XCTAssertFalse(try service.importReviewedEntries([Entry(kind: .term, original: "stale", replacement: nil)], baseline: baseline))
        XCTAssertEqual(service.entries.count, 2)
        XCTAssertTrue(try service.importReviewedEntries(entries, baseline: service.appImportSnapshot))
        XCTAssertEqual(service.entries.count, 2)
    }

    @MainActor
    func testDictionarySaveFailureRollsBack() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = DictionaryService(appSupportDirectory: dir)
        service.addEntry(type: .term, original: "Keep")
        service.appImportSaveOverride = { throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try service.importReviewedEntries([Entry(kind: .term, original: "New", replacement: nil)], baseline: service.appImportSnapshot))
        XCTAssertEqual(service.entries.map(\.original), ["Keep"])
        XCTAssertEqual(DictionaryService(appSupportDirectory: dir).entries.map(\.original), ["Keep"])
    }

    @MainActor
    func testSnippetCommitConflictStaleAndSaveFailure() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = SnippetService(appSupportDirectory: dir)
        service.addSnippet(trigger: "sig", replacement: "Existing")
        let baseline = service.appImportSnapshot
        let entries = [Entry(kind: .snippet, original: "SIG", replacement: "Do not overwrite"), Entry(kind: .snippet, original: "new", replacement: "New\nText")]
        XCTAssertTrue(try service.importReviewedEntries(entries, baseline: baseline))
        XCTAssertEqual(service.snippets.count, 2)
        XCTAssertEqual(service.snippets.first { $0.trigger == "sig" }?.replacement, "Existing")
        XCTAssertEqual(SnippetService(appSupportDirectory: dir).snippets.count, 2)
        XCTAssertFalse(try service.importReviewedEntries(entries, baseline: baseline))
        service.appImportSaveOverride = { throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try service.importReviewedEntries([Entry(kind: .snippet, original: "fail", replacement: "Fail")], baseline: service.appImportSnapshot))
        XCTAssertEqual(service.snippets.count, 2)
        XCTAssertEqual(SnippetService(appSupportDirectory: dir).snippets.count, 2)
    }

    @MainActor
    func testPreviewWritesOnlySelectedEntriesAfterConfirmation() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let dictionary = DictionaryService(appSupportDirectory: dir)
        let snippets = SnippetService(appSupportDirectory: dir)
        let model = AppVocabularyImportViewModel(destination: .dictionary, dictionary: dictionary, snippets: snippets)
        let file = dir.appendingPathComponent("words.csv")
        try Data("word\nSwift\nKubernetes\n".utf8).write(to: file)
        model.source = .wisprCSV
        model.csvHasHeader = true
        model.load(file)
        try await waitForLoad(model)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.focusedRowID, model.rows.first?.id)
        XCTAssertTrue(dictionary.entries.isEmpty)
        model.selected = [1]
        model.commit()
        XCTAssertEqual(model.importedCount, 1)
        XCTAssertEqual(dictionary.entries.map(\.original), ["Kubernetes"])
        XCTAssertTrue(snippets.snippets.isEmpty)
    }

    @MainActor
    func testPreviewRequiresConfirmationAgainWhenDestinationChanges() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let dictionary = DictionaryService(appSupportDirectory: dir)
        let snippets = SnippetService(appSupportDirectory: dir)
        let model = AppVocabularyImportViewModel(destination: .dictionary, dictionary: dictionary, snippets: snippets)
        let file = dir.appendingPathComponent("words.csv")
        try Data("word\nSwift\n".utf8).write(to: file)
        model.source = .wisprCSV
        model.csvHasHeader = true
        model.load(file)
        try await waitForLoad(model)
        dictionary.addEntry(type: .term, original: "Added while reviewing")
        model.commit()
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.importedCount)
        XCTAssertEqual(dictionary.entries.count, 1)
        model.commit()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.importedCount, 1)
        XCTAssertEqual(dictionary.entries.count, 2)
    }

    @MainActor
    private func waitForLoad(_ model: AppVocabularyImportViewModel) async throws {
        for _ in 0..<300 {
            if !model.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Import did not finish")
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func withDatabase(wal: Bool = false, body: (OpaquePointer, URL, URL) throws -> Void) throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let url = directory.appendingPathComponent("flow.sqlite")
        let scratch = directory.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        defer { sqlite3_close(db) }
        if wal { try execute(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;") }
        try execute(db, "CREATE TABLE Dictionary (id TEXT PRIMARY KEY, phrase TEXT, replacement TEXT, isDeleted INTEGER, isSnippet INTEGER)")
        try body(db, url, scratch)
    }

    private func sourceBytes(_ url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let part = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: part.path) {
                result[suffix] = Data(SHA256.hash(data: try Data(contentsOf: part)))
            }
        }
        return result
    }
}
