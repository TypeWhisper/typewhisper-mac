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
        service.addEntry(type: .term, original: "Kubernetes")

        let json = DictionaryExporter.exportJSON(service.entries)
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(array.count, 2)

        let correction = try XCTUnwrap(array.first { ($0["type"] as? String) == "correction" })
        XCTAssertEqual(correction["original"] as? String, "teh")
        XCTAssertEqual(correction["replacement"] as? String, "the")
        XCTAssertEqual(correction["caseSensitive"] as? Bool, true)
        XCTAssertEqual(correction["isEnabled"] as? Bool, true)

        let term = try XCTUnwrap(array.first { ($0["type"] as? String) == "term" })
        XCTAssertEqual(term["original"] as? String, "Kubernetes")
        XCTAssertNil(term["replacement"])
        XCTAssertEqual(term["caseSensitive"] as? Bool, false)
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
        XCTAssertTrue(items[0].isEnabled)
        XCTAssertNil(items[0].replacement)
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
}
