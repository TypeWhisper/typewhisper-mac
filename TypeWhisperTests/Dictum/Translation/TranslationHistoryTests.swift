import XCTest
@testable import TypeWhisper

@MainActor
final class TranslationHistoryTests: XCTestCase {
    private var directory: URL!
    private var history: HistoryService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-translation-history")
        history = HistoryService(appSupportDirectory: directory, eventEmitter: { _ in })
    }

    override func tearDown() {
        history = nil
        TestSupport.remove(directory)
        super.tearDown()
    }

    @discardableResult
    private func addTranslation(
        id: UUID = UUID(), spoken: String? = "zh-Hans", target: String = "en",
        raw: String = "我到楼下了", final: String = "I'm downstairs."
    ) -> UUID {
        XCTAssertTrue(history.addRecord(
            id: id, rawText: raw, finalText: final, appName: "Slack", appBundleIdentifier: "com.tinyspeck.slackmacgap",
            durationSeconds: 3, language: spoken, engineUsed: "Qwen3-ASR", audioFileName: nil,
            translation: HistoryTranslationInfo(spokenLanguage: spoken, targetLanguage: target)
        ))
        return id
    }

    func testTranslationRecordKeepsModeAndLanguagePair() throws {
        let id = addTranslation()
        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertEqual(record.mode, .translation)
        XCTAssertEqual(record.spokenLanguage, "zh-Hans")
        XCTAssertEqual(record.targetLanguage, "en")
        XCTAssertEqual(record.rawText, "我到楼下了")
        XCTAssertEqual(record.finalText, "I'm downstairs.")
    }

    func testRecordsWithoutTheNewFieldsReadAsDictation() throws {
        let id = UUID()
        XCTAssertTrue(history.addRecord(id: id, rawText: "你好", finalText: "你好。", appName: nil, appBundleIdentifier: nil,
                                        durationSeconds: 2, language: "zh", engineUsed: "Qwen3-ASR"))
        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertNil(record.modeRaw)
        XCTAssertEqual(record.mode, .dictation)
        XCTAssertNil(record.targetLanguage)
    }

    func testFilterSeparatesDictationFromTranslation() throws {
        let translation = addTranslation()
        let dictation = UUID()
        XCTAssertTrue(history.addRecord(id: dictation, rawText: "hello", finalText: "Hello.", appName: nil, appBundleIdentifier: nil,
                                        durationSeconds: 2, language: "en", engineUsed: "Qwen3-ASR"))
        let records = history.allRecords()
        XCTAssertEqual(Set(records.filter { HistoryRecordFilter.translation.includes($0) }.map(\.id)), [translation])
        XCTAssertEqual(Set(records.filter { HistoryRecordFilter.dictation.includes($0) }.map(\.id)), [dictation])
        XCTAssertEqual(Set(records.filter { HistoryRecordFilter.all.includes($0) }.map(\.id)), [translation, dictation])
    }

    func testSyncContentCarriesNewFieldsAndOldContentStillDecodes() throws {
        let content = UserDataSyncHistoryContentV1(
            recordID: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            originDeviceID: "mac-a", originPlatform: "macOS", source: "mac", processingState: "ready",
            rawTranscript: "我到楼下了", finalText: "I'm downstairs.", durationSeconds: 3, engineDisplayName: "Qwen3-ASR",
            mode: "translation", spokenLanguage: "zh-Hans", targetLanguage: "en"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(UserDataSyncHistoryContentV1.self, from: encoder.encode(content)), content)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(content)) as? [String: Any])
        for key in ["mode", "spokenLanguage", "targetLanguage"] { legacy.removeValue(forKey: key) }
        let old = try decoder.decode(UserDataSyncHistoryContentV1.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.mode)
        XCTAssertNil(old.targetLanguage)
    }

    func testTranslationRecordSurvivesTwoMacSync() async throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-translation-sync")
        defer { TestSupport.remove(root) }
        let suiteA = "dictum-translation-sync-a-\(UUID().uuidString)"
        let suiteB = "dictum-translation-sync-b-\(UUID().uuidString)"
        let defaultsA = try XCTUnwrap(UserDefaults(suiteName: suiteA))
        let defaultsB = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }
        struct Mac {
            let history: HistoryService
            let store: TypeWhisperUserDataSyncStore
            var state: CloudFolderSyncState
        }
        func makeMac(_ name: String, defaults: UserDefaults) -> Mac {
            let preferences = HistorySyncPreferences(defaults: defaults)
            preferences.isEnabled = true
            let dir = root.appendingPathComponent(name)
            let history = HistoryService(appSupportDirectory: dir, historySyncPreferences: preferences, eventEmitter: { _ in })
            let store = TypeWhisperUserDataSyncStore(
                dictionaryService: DictionaryService(appSupportDirectory: dir), snippetService: SnippetService(appSupportDirectory: dir),
                historyService: history, historySyncPreferences: preferences, defaults: defaults)
            return Mac(history: history, store: store, state: CloudFolderSyncState(deviceId: name))
        }
        var macA = makeMac("mac-a", defaults: defaultsA)
        var macB = makeMac("mac-b", defaults: defaultsB)
        let folder = root.appendingPathComponent("cloud")
        let translation = UUID()
        let dictation = UUID()
        XCTAssertTrue(macA.history.addRecord(
            id: translation, rawText: "我到楼下了", finalText: "I'm downstairs.", appName: nil, appBundleIdentifier: nil,
            durationSeconds: 3, language: "zh", engineUsed: "Qwen3-ASR", audioFileName: nil,
            translation: HistoryTranslationInfo(spokenLanguage: "zh-Hans", targetLanguage: "en")))
        XCTAssertTrue(macA.history.addRecord(id: dictation, rawText: "你好", finalText: "你好。", appName: nil, appBundleIdentifier: nil,
                                             durationSeconds: 2, language: "zh", engineUsed: "Qwen3-ASR"))
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: macA.store, state: &macA.state)
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: macB.store, state: &macB.state)
        let received = try XCTUnwrap(macB.history.record(withID: translation))
        XCTAssertEqual(received.mode, .translation)
        XCTAssertEqual(received.spokenLanguage, "zh-Hans")
        XCTAssertEqual(received.targetLanguage, "en")
        XCTAssertEqual(try XCTUnwrap(macB.history.record(withID: dictation)).mode, .dictation)
    }

    func testExportsIncludeTheLanguagePairForTranslationOnly() throws {
        let id = addTranslation(spoken: nil, target: "ja", raw: "Hello", final: "こんにちは")
        let record = try XCTUnwrap(history.record(withID: id))
        let markdown = HistoryExporter.exportMarkdown(record)
        XCTAssertTrue(markdown.contains("**Mode:** Translation (auto → ja)"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(HistoryExporter.exportJSON(record).utf8)) as? [String: Any])
        XCTAssertEqual(json["mode"] as? String, "translation")
        XCTAssertEqual(json["targetLanguage"] as? String, "ja")
        XCTAssertNil(json["spokenLanguage"])

        let plain = UUID()
        XCTAssertTrue(history.addRecord(id: plain, rawText: "hi", finalText: "Hi.", appName: nil, appBundleIdentifier: nil,
                                        durationSeconds: 2, language: "en", engineUsed: "Qwen3-ASR"))
        let dictation = try XCTUnwrap(history.record(withID: plain))
        XCTAssertFalse(HistoryExporter.exportMarkdown(dictation).contains("Mode:"))
        let dictationJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(HistoryExporter.exportJSON(dictation).utf8)) as? [String: Any])
        XCTAssertNil(dictationJSON["mode"])
    }

    func testRetryTranslatesTheOriginalWithTheRecordPairAndKeepsTheOldVersion() async throws {
        let id = addTranslation(spoken: "zh-Hans", target: "ja", raw: "我到楼下了", final: "我到楼下了")
        let record = try XCTUnwrap(history.record(withID: id))
        let chain = ChainDouble(result: .success("下に着きました。"))
        try await HistoryTranslationRetry.run(
            record: record, history: history, processor: chain,
            style: ResolvedStyle.resolve(bundleID: "com.tinyspeck.slackmacgap", browserURL: nil, global: StyleSettings(), apps: AppStyle.defaults),
            level: .standard, vocabulary: []
        )
        XCTAssertEqual(chain.texts, ["我到楼下了"])
        XCTAssertTrue(chain.prompts[0].contains("Japanese (ja)"))
        XCTAssertTrue(chain.prompts[0].contains("Chinese, Simplified (zh-Hans)"))
        XCTAssertEqual(record.finalText, "下に着きました。")
        XCTAssertEqual(record.rawText, "我到楼下了")
        XCTAssertEqual(record.mode, .translation)
        XCTAssertEqual(record.targetLanguage, "ja")
        XCTAssertGreaterThanOrEqual(try record.savedTranscriptionVersions().count, 2)
    }

    func testRetryOfADictationRecordIsRefused() async throws {
        let id = UUID()
        XCTAssertTrue(history.addRecord(id: id, rawText: "hi", finalText: "Hi.", appName: nil, appBundleIdentifier: nil,
                                        durationSeconds: 2, language: "en", engineUsed: "Qwen3-ASR"))
        let record = try XCTUnwrap(history.record(withID: id))
        do {
            try await HistoryTranslationRetry.run(
                record: record, history: history, processor: ChainDouble(result: .success("x")),
                style: ResolvedStyle.resolve(bundleID: nil, browserURL: nil, global: StyleSettings(), apps: AppStyle.defaults),
                level: .standard, vocabulary: []
            )
            XCTFail("听写记录不能重新翻译")
        } catch HistoryTranslationRetry.Failure.notTranslation {}
    }
}

/// 翻译模型链的测试替身：记录收到的提示词和文本，返回预设结果。
@MainActor
final class ChainDouble: TranslationModelProcessing {
    var hasReadyModel = true
    var result: Result<String, Error>
    private(set) var prompts: [String] = []
    private(set) var texts: [String] = []

    init(result: Result<String, Error>) { self.result = result }

    func translate(prompt: String, text: String) async throws -> String {
        prompts.append(prompt)
        texts.append(text)
        return try result.get()
    }
}
