import XCTest
@testable import TypeWhisper

@MainActor
final class TwoMacSyncConvergenceTests: XCTestCase {
    private struct Mac {
        let history: HistoryService
        let dictionary: DictionaryService
        let store: TypeWhisperUserDataSyncStore
        var state: CloudFolderSyncState
    }

    private func makeMac(named name: String, root: URL, defaults: UserDefaults) -> Mac {
        let directory = root.appendingPathComponent(name)
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        let history = HistoryService(appSupportDirectory: directory, historySyncPreferences: preferences, eventEmitter: { _ in })
        let dictionary = DictionaryService(appSupportDirectory: directory)
        let snippets = SnippetService(appSupportDirectory: directory)
        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionary, snippetService: snippets, historyService: history,
            historySyncPreferences: preferences, defaults: defaults)
        return Mac(history: history, dictionary: dictionary, store: store, state: CloudFolderSyncState(deviceId: name))
    }

    private func sync(_ mac: inout Mac, folder: URL) async throws {
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: mac.store, state: &mac.state)
    }

    private func dictionaryPairs(_ mac: Mac) -> [String] {
        mac.dictionary.entries.map { "\($0.original)→\($0.replacement ?? "")" }.sorted()
    }

    func testConflictingEditsConvergeAndEveryUniqueItemSurvives() async throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-two-macs")
        defer { TestSupport.remove(root) }
        let suiteA = "dictum-two-macs-a-\(UUID().uuidString)"
        let suiteB = "dictum-two-macs-b-\(UUID().uuidString)"
        let defaultsA = try XCTUnwrap(UserDefaults(suiteName: suiteA))
        let defaultsB = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }
        let folder = root.appendingPathComponent("cloud")
        var macA = makeMac(named: "mac-a", root: root, defaults: defaultsA)
        var macB = makeMac(named: "mac-b", root: root, defaults: defaultsB)

        let sharedRecord = UUID()
        macA.dictionary.addEntry(type: .correction, original: "新河", replacement: "星河")
        XCTAssertTrue(macA.history.addRecord(id: sharedRecord, rawText: "周四开会", finalText: "周四开会。", appName: "TextEdit", appBundleIdentifier: "com.apple.TextEdit", durationSeconds: 3, language: "zh", engineUsed: "Qwen3-ASR"))
        try await sync(&macA, folder: folder)
        try await sync(&macB, folder: folder)
        XCTAssertEqual(dictionaryPairs(macB), ["新河→星河"])
        XCTAssertEqual(macB.history.record(withID: sharedRecord)?.finalText, "周四开会。")

        let entryA = try XCTUnwrap(macA.dictionary.entries.first)
        XCTAssertTrue(macA.dictionary.updateEntry(entryA, original: "新河", replacement: "星河项目", caseSensitive: false))
        macA.history.updateRecord(try XCTUnwrap(macA.history.record(withID: sharedRecord)), finalText: "周四下午三点开会。")
        macA.dictionary.addEntry(type: .term, original: "Kubernetes")
        let recordOnA = UUID()
        XCTAssertTrue(macA.history.addRecord(id: recordOnA, rawText: "only on a", finalText: "Only on A.", appName: nil, appBundleIdentifier: nil, durationSeconds: 2, language: "en", engineUsed: "Qwen3-ASR"))

        try await Task.sleep(for: .milliseconds(50))
        let entryB = try XCTUnwrap(macB.dictionary.entries.first)
        XCTAssertTrue(macB.dictionary.updateEntry(entryB, original: "新河", replacement: "星河计划", caseSensitive: false))
        macB.history.updateRecord(try XCTUnwrap(macB.history.record(withID: sharedRecord)), finalText: "周四上午九点开会。")
        macB.dictionary.addEntry(type: .term, original: "Qwen3")
        let recordOnB = UUID()
        XCTAssertTrue(macB.history.addRecord(id: recordOnB, rawText: "只在 b", finalText: "只在 B。", appName: nil, appBundleIdentifier: nil, durationSeconds: 2, language: "zh", engineUsed: "Qwen3-ASR"))

        try await sync(&macA, folder: folder)
        try await sync(&macB, folder: folder)
        try await sync(&macA, folder: folder)
        try await sync(&macB, folder: folder)

        XCTAssertEqual(dictionaryPairs(macA), dictionaryPairs(macB))
        XCTAssertEqual(dictionaryPairs(macA), ["Kubernetes→", "Qwen3→", "新河→星河计划"])
        for mac in [macA, macB] {
            XCTAssertEqual(Set(mac.history.allRecords().map(\.id)), [sharedRecord, recordOnA, recordOnB])
            XCTAssertEqual(mac.history.record(withID: sharedRecord)?.finalText, "周四上午九点开会。")
            XCTAssertEqual(mac.history.record(withID: recordOnA)?.finalText, "Only on A.")
            XCTAssertEqual(mac.history.record(withID: recordOnB)?.finalText, "只在 B。")
        }

        let settledA = try await CloudFolderSyncEngine.sync(folderURL: folder, store: macA.store, state: &macA.state)
        let settledB = try await CloudFolderSyncEngine.sync(folderURL: folder, store: macB.store, state: &macB.state)
        XCTAssertEqual(settledA.operationsWritten, 0)
        XCTAssertEqual(settledB.operationsWritten, 0)
    }
}
