import XCTest
@testable import TypeWhisper

final class DictionaryExporterTests: XCTestCase {

    @MainActor
    func testExportEmptyDictionary() throws {
        let json = DictionaryExporter.exportJSON([])
        let array = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        XCTAssertEqual(array?.count, 0)
    }

    @MainActor
    func testExportContainsExpectedFields() throws {
        let appDir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appDir) }
        let service = DictionaryService(appSupportDirectory: appDir)

        service.addEntry(type: .correction, original: "teh", replacement: "the", caseSensitive: true)
        service.addEntry(type: .term, original: "Kubernetes", ctcMinSimilarity: 0.65)

        let json = DictionaryExporter.exportJSON(service.entries)
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(array.count, 2)

        let correction = try XCTUnwrap(array.first { ($0["type"] as? String) == "correction" })
        XCTAssertEqual(correction["original"] as? String, "teh")
        XCTAssertEqual(correction["replacement"] as? String, "the")
        XCTAssertEqual(correction["caseSensitive"] as? Bool, true)
        XCTAssertEqual(correction["isEnabled"] as? Bool, true)
        // Released Windows importers reject unknown fields, even when set to false.
        XCTAssertNil(correction["isRegex"])

        let term = try XCTUnwrap(array.first { ($0["type"] as? String) == "term" })
        XCTAssertEqual(term["original"] as? String, "Kubernetes")
        XCTAssertNil(term["replacement"])
        XCTAssertEqual(term["caseSensitive"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(term["ctcMinSimilarity"] as? Double), 0.65, accuracy: 0.0001)
    }

    @MainActor
    func testExportExcludesInternalFields() throws {
        let appDir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appDir) }
        let service = DictionaryService(appSupportDirectory: appDir)

        service.addEntry(type: .term, original: "Swift")

        let json = DictionaryExporter.exportJSON(service.entries)
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let entry = try XCTUnwrap(array.first)

        XCTAssertNil(entry["id"])
        XCTAssertNil(entry["createdAt"])
        XCTAssertNil(entry["usageCount"])
    }

    @MainActor
    func testParseValidJSON() throws {
        let json = """
        [
            {"type": "term", "original": "Kubernetes", "caseSensitive": true, "isEnabled": true},
            {"type": "correction", "original": "teh", "replacement": "the", "caseSensitive": false, "isEnabled": true}
        ]
        """
        let items = try DictionaryExporter.parseJSON(Data(json.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].type, .term)
        XCTAssertEqual(items[0].original, "Kubernetes")
        XCTAssertTrue(items[0].caseSensitive)
        XCTAssertNil(items[0].ctcMinSimilarity)
        XCTAssertEqual(items[1].type, .correction)
        XCTAssertEqual(items[1].replacement, "the")
    }

    @MainActor
    func testParseDefaultsForMissingOptionalFields() throws {
        let json = """
        [{"type": "term", "original": "Docker"}]
        """
        let items = try DictionaryExporter.parseJSON(Data(json.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].caseSensitive)
        XCTAssertFalse(items[0].isRegex)
        XCTAssertTrue(items[0].isEnabled)
        XCTAssertNil(items[0].replacement)
        XCTAssertNil(items[0].ctcMinSimilarity)
    }

    @MainActor
    func testRegexDictionaryRoundTripPreservesPatternModeAndEnabledState() throws {
        let sourceDirectory = try TestSupport.makeTemporaryDirectory()
        let destinationDirectory = try TestSupport.makeTemporaryDirectory()
        defer {
            TestSupport.remove(sourceDirectory)
            TestSupport.remove(destinationDirectory)
        }
        let source = DictionaryService(appSupportDirectory: sourceDirectory)
        source.addEntry(type: .correction, original: #"\s+new line\s+"#, replacement: #"\n"#, caseSensitive: true, isRegex: true)
        source.setEntryEnabled(try XCTUnwrap(source.corrections.first), enabled: false)
        let exported = DictionaryExporter.exportJSON(source.entries)
        let parsed = try DictionaryExporter.parseJSON(Data(exported.utf8))
        let entry = try XCTUnwrap(parsed.first)
        XCTAssertTrue(entry.isRegex)
        XCTAssertTrue(entry.caseSensitive)
        XCTAssertFalse(entry.isEnabled)
        XCTAssertEqual(entry.original, #"\s+new line\s+"#)
        XCTAssertEqual(entry.replacement, #"\n"#)

        let destination = DictionaryService(appSupportDirectory: destinationDirectory)
        XCTAssertEqual(DictionaryExporter.importEntries(parsed, into: destination).imported, 1)
        XCTAssertTrue(try XCTUnwrap(destination.entries.first).isRegex)
        destination.setEntryEnabled(try XCTUnwrap(destination.entries.first), enabled: true)
        XCTAssertEqual(destination.applyCorrections(to: "First new line Second"), "First\nSecond")
    }

    @MainActor
    func testLegacyDictionaryImportDefaultsToLiteralAndTermsIgnoreRegexFlag() throws {
        let json = #"[{"type":"correction","original":"command","replacement":"\\n"},{"type":"term","original":"Term","isRegex":true}]"#
        let entries = try DictionaryExporter.parseJSON(Data(json.utf8))
        XCTAssertTrue(entries.allSatisfy { !$0.isRegex })
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = DictionaryService(appSupportDirectory: directory)
        XCTAssertEqual(DictionaryExporter.importEntries(entries, into: service).imported, 2)
        XCTAssertEqual(service.applyCorrections(to: "command"), #"\n"#)
    }

    @MainActor
    func testParseAndRoundTripTermCtcMinSimilarity() throws {
        let json = """
        [{"type": "term", "original": "Caivex", "ctcMinSimilarity": 0.65}]
        """

        let items = try DictionaryExporter.parseJSON(Data(json.utf8))

        XCTAssertEqual(try XCTUnwrap(items.first?.ctcMinSimilarity), 0.65, accuracy: 0.0001)

        let appDir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appDir) }
        let service = DictionaryService(appSupportDirectory: appDir)
        let result = DictionaryExporter.importEntries(items, into: service)

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(try XCTUnwrap(service.entries.first?.ctcMinSimilarity), 0.65, accuracy: 0.0001)
    }

    @MainActor
    func testParseRejectsInvalidJSON() {
        XCTAssertThrowsError(try DictionaryExporter.parseJSON(Data("not json".utf8)))
    }

    @MainActor
    func testParseRejectsEntriesWithoutOriginal() {
        let json = """
        [{"type": "term"}]
        """
        XCTAssertThrowsError(try DictionaryExporter.parseJSON(Data(json.utf8)))
    }

    @MainActor
    func testParseRejectsCorrectionWithoutReplacement() {
        let json = """
        [{"type": "correction", "original": "teh"}]
        """
        XCTAssertThrowsError(try DictionaryExporter.parseJSON(Data(json.utf8)))
    }

    @MainActor
    func testParseAcceptsCorrectionWithEmptyReplacement() throws {
        let json = """
        [{"type": "correction", "original": "¿", "replacement": ""}]
        """

        let items = try DictionaryExporter.parseJSON(Data(json.utf8))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].type, .correction)
        XCTAssertEqual(items[0].original, "¿")
        XCTAssertEqual(items[0].replacement, "")
    }

    @MainActor
    func testRoundTrip() throws {
        let appDir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appDir) }
        let service = DictionaryService(appSupportDirectory: appDir)

        service.addEntry(type: .correction, original: "langauge", replacement: "language", caseSensitive: false)
        service.addEntry(type: .term, original: "TypeWhisper", caseSensitive: true)

        let json = DictionaryExporter.exportJSON(service.entries)
        let parsed = try DictionaryExporter.parseJSON(Data(json.utf8))

        XCTAssertEqual(parsed.count, 2)
        let correction = try XCTUnwrap(parsed.first { $0.type == .correction })
        XCTAssertEqual(correction.original, "langauge")
        XCTAssertEqual(correction.replacement, "language")
        let term = try XCTUnwrap(parsed.first { $0.type == .term })
        XCTAssertEqual(term.original, "TypeWhisper")
        XCTAssertTrue(term.caseSensitive)
    }

    @MainActor
    func testRoundTripPreservesEmptyCorrectionReplacement() throws {
        let appDir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appDir) }
        let service = DictionaryService(appSupportDirectory: appDir)

        service.addEntry(type: .correction, original: "¿", replacement: "", caseSensitive: false)

        let json = DictionaryExporter.exportJSON(service.entries)
        let parsed = try DictionaryExporter.parseJSON(Data(json.utf8))

        XCTAssertEqual(parsed.count, 1)
        let correction = try XCTUnwrap(parsed.first)
        XCTAssertEqual(correction.type, .correction)
        XCTAssertEqual(correction.original, "¿")
        XCTAssertEqual(correction.replacement, "")
    }

    @MainActor
    func testRoundTripPreservesAutoLearnedSource() throws {
        let appDir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appDir) }
        let service = DictionaryService(appSupportDirectory: appDir)
        service.learnCorrection(original: "recieve", replacement: "receive")

        let json = DictionaryExporter.exportJSON(service.entries)
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(array.first?["source"] as? String, DictionaryEntrySource.autoLearned.rawValue)

        let parsed = try DictionaryExporter.parseJSON(Data(json.utf8))
        let correction = try XCTUnwrap(parsed.first)
        XCTAssertEqual(correction.source, .autoLearned)

        let importedDir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(importedDir) }
        let importedService = DictionaryService(appSupportDirectory: importedDir)
        let result = DictionaryExporter.importEntries(parsed, into: importedService)

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(importedService.entries.first?.source, .autoLearned)
    }

    @MainActor
    func testParseDefaultsUnknownSourceToManual() throws {
        let json = """
        [{"type": "correction", "original": "teh", "replacement": "the", "source": "future"}]
        """

        let items = try DictionaryExporter.parseJSON(Data(json.utf8))

        XCTAssertEqual(items.first?.source, .manual)
    }

    @MainActor
    func testImportWithDuplicateDetection() throws {
        let appDir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appDir) }
        let service = DictionaryService(appSupportDirectory: appDir)

        service.addEntry(type: .term, original: "Existing")

        let json = """
        [
            {"type": "term", "original": "Existing", "caseSensitive": false, "isEnabled": true},
            {"type": "term", "original": "NewTerm", "caseSensitive": false, "isEnabled": true},
            {"type": "correction", "original": "teh", "replacement": "the", "caseSensitive": false, "isEnabled": true}
        ]
        """
        let parsed = try DictionaryExporter.parseJSON(Data(json.utf8))
        let result = DictionaryExporter.importEntries(parsed, into: service)

        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(service.entries.count, 3)
    }

    @MainActor
    func testImportSkipsDuplicatesWithinSameFile() throws {
        let appDir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appDir) }
        let service = DictionaryService(appSupportDirectory: appDir)

        let json = """
        [
            {"type": "term", "original": "NewTerm", "caseSensitive": false, "isEnabled": true},
            {"type": "term", "original": "newterm", "caseSensitive": true, "isEnabled": false},
            {"type": "correction", "original": "teh", "replacement": "the", "caseSensitive": false, "isEnabled": true}
        ]
        """
        let parsed = try DictionaryExporter.parseJSON(Data(json.utf8))
        let result = DictionaryExporter.importEntries(parsed, into: service)

        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(service.entries.count, 2)
    }
}
