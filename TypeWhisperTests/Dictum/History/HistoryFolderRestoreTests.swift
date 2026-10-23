import XCTest
@testable import TypeWhisper

@MainActor
final class HistoryFolderRestoreTests: XCTestCase {
    func testFreshStoresRestoreTextDictionaryAndSnippetsIdempotently() async throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-restore")
        defer { TestSupport.remove(root) }
        let suite = "dictum-restore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let cloud = root.appendingPathComponent("cloud")
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        let history = HistoryService(appSupportDirectory: first, historySyncPreferences: preferences, eventEmitter: { _ in })
        let dictionary = DictionaryService(appSupportDirectory: first)
        let snippets = SnippetService(appSupportDirectory: first)
        dictionary.addEntry(type: .term, original: "星河项目")
        snippets.addSnippet(trigger: "项目地址", replacement: "https://example.com/project")
        let id = UUID()
        try FileManager.default.copyItem(at: TestSupport.repoRoot.appendingPathComponent("TypeWhisper/Resources/Sounds/recording_start.wav"), to: first.appendingPathComponent("audio/recording.wav"))
        XCTAssertTrue(history.addRecord(id: id, rawText: "周四下午开会", finalText: "周四下午开会。", appName: "TextEdit", appBundleIdentifier: "com.apple.TextEdit", durationSeconds: 3, language: "zh", engineUsed: "Qwen3-ASR", audioFileName: "recording.wav"))
        let store = TypeWhisperUserDataSyncStore(dictionaryService: dictionary, snippetService: snippets, historyService: history, historySyncPreferences: preferences, defaults: defaults)
        XCTAssertTrue(store.snapshot().historyRecords.allSatisfy { $0.audio == nil && $0.localAudioFileURL == nil && !$0.audioEligible })
        var firstState = CloudFolderSyncState()
        _ = try await CloudFolderSyncEngine.sync(folderURL: cloud, store: store, state: &firstState)
        let restoredHistory = HistoryService(appSupportDirectory: second, historySyncPreferences: preferences, eventEmitter: { _ in })
        let restoredDictionary = DictionaryService(appSupportDirectory: second)
        let restoredSnippets = SnippetService(appSupportDirectory: second)
        let restored = TypeWhisperUserDataSyncStore(dictionaryService: restoredDictionary, snippetService: restoredSnippets, historyService: restoredHistory, historySyncPreferences: preferences, defaults: defaults)
        var secondState = CloudFolderSyncState()
        _ = try await CloudFolderSyncEngine.sync(folderURL: cloud, store: restored, state: &secondState)
        _ = try await CloudFolderSyncEngine.sync(folderURL: cloud, store: restored, state: &secondState)
        XCTAssertEqual(restoredHistory.record(withID: id)?.finalText, "周四下午开会。")
        XCTAssertEqual(restoredHistory.recordCount(), 1)
        XCTAssertEqual(restoredDictionary.entries.map(\.original), ["星河项目"])
        XCTAssertEqual(restoredSnippets.snippets.count, 1)
        XCTAssertTrue(restored.snapshot().historyRecords.allSatisfy { $0.audio == nil && $0.localAudioFileURL == nil && !$0.audioEligible })
    }
}
