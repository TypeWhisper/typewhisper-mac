import XCTest
@testable import TypeWhisper

@MainActor
final class DictionaryImportPersistenceTests: XCTestCase {
    func testLearnedMarkerOnlyAcknowledgesLearnedEntries() throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-learned")
        defer { TestSupport.remove(root) }
        let suite = "dictum-learned-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = DictionaryService(appSupportDirectory: root)
        service.addEntry(type: .term, original: "Qwen3")
        let learned = service.learnCorrectionsWithResult([CorrectionSuggestion(original: "星河项木", replacement: "星河项目")])
        XCTAssertFalse(learned.failed)
        XCTAssertEqual(service.learnedSinceLastSeen(defaults: defaults).map(\.replacement), ["星河项目"])
        service.markLearnedWordsSeen(defaults: defaults)
        XCTAssertTrue(service.learnedSinceLastSeen(defaults: defaults).isEmpty)
        XCTAssertEqual(service.entries.count, 2)
    }

    func testWordFirstFileImportedWithDefaultFormatKeepsTheWordAndItsMishearing() throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-import-default")
        defer { TestSupport.remove(root) }
        let service = DictionaryService(appSupportDirectory: root)
        let data = Data("dictum,迪克腾\nKubernetes,酷伯尼特斯\n".utf8)
        XCTAssertEqual(try service.importCSV(data, format: .default).items.count, 2)
        let entry = try XCTUnwrap(service.entries.first { $0.replacement == "dictum" })
        XCTAssertEqual(entry.original, "迪克腾")
        XCTAssertEqual(entry.type, .correction)
    }

    func testImportPersistsAndRepeatedImportSkipsDuplicates() throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-import")
        defer { TestSupport.remove(root) }
        let service = DictionaryService(appSupportDirectory: root)
        let data = Data("Whisper Flow,Wispr Flow\n星河项目,\n".utf8)
        XCTAssertEqual(try service.importCSV(data, format: .wisprFlow).items.count, 2)
        let restored = DictionaryService(appSupportDirectory: root)
        XCTAssertEqual(restored.entries.count, 2)
        let duplicate = try restored.importCSV(data, format: .wisprFlow)
        XCTAssertEqual(duplicate.duplicates, 2)
        XCTAssertTrue(duplicate.items.isEmpty)
        XCTAssertEqual(restored.applyCorrections(to: "Whisper Flow"), "Wispr Flow")
    }
}
