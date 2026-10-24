import SwiftData
import XCTest
@testable import TypeWhisper

@MainActor
final class DictumWordCountHistoryTests: XCTestCase {
    @MainActor
    private final class CountFlag {
        var value: Int
        init(_ value: Int) { self.value = value }
    }

    func testStoredChineseRecordReportsCharacterCount() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-word-count-zh")
        defer { TestSupport.remove(directory) }
        let history = HistoryService(appSupportDirectory: directory, eventEmitter: { _ in })
        let chineseText = "今天下午三点开会讨论部署方案"
        XCTAssertTrue(history.addRecord(
            rawText: chineseText,
            finalText: chineseText,
            appName: "TextEdit",
            appBundleIdentifier: "com.apple.TextEdit",
            durationSeconds: 4,
            language: "zh",
            engineUsed: "Qwen3-ASR"
        ))
        let record = try XCTUnwrap(history.allRecords().first)
        XCTAssertEqual(record.wordsCount, DictumWordCount.count(chineseText))
        XCTAssertGreaterThan(record.wordsCount, 1)
    }

    func testStoredEnglishRecordKeepsSpaceDelimitedCount() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-word-count-en")
        defer { TestSupport.remove(directory) }
        let history = HistoryService(appSupportDirectory: directory, eventEmitter: { _ in })
        let englishText = "The quick brown fox jumps"
        XCTAssertTrue(history.addRecord(
            rawText: englishText,
            finalText: englishText,
            appName: "TextEdit",
            appBundleIdentifier: "com.apple.TextEdit",
            durationSeconds: 3,
            language: "en",
            engineUsed: "Parakeet"
        ))
        let record = try XCTUnwrap(history.allRecords().first)
        XCTAssertEqual(record.wordsCount, 5)
    }

    func testSyncedChineseRecordStoresCharacterCount() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-word-count-sync")
        defer { TestSupport.remove(directory) }
        let history = HistoryService(appSupportDirectory: directory, eventEmitter: { _ in })
        let chineseText = "两台电脑之间同步的听写记录"
        let recordID = UUID()
        let now = Date()

        try history.applyUserDataSyncMutations([
            .upsertHistoryContent(UserDataSyncHistoryContentV1(
                recordID: recordID,
                createdAt: now,
                updatedAt: now,
                originDeviceID: "remote",
                originPlatform: "macOS",
                source: "mac",
                processingState: "ready",
                rawTranscript: chineseText,
                finalText: chineseText,
                durationSeconds: 3,
                engineDisplayName: "Qwen3-ASR"
            ))
        ])

        let record = try XCTUnwrap(history.record(withID: recordID))
        XCTAssertEqual(record.wordsCount, DictumWordCount.count(chineseText))
        XCTAssertGreaterThan(record.wordsCount, 1)
    }

    func testRecountRewritesStaleStoredCountAndReturnsDayDelta() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-word-count-recount")
        defer {
            UserDefaults.standard.removeObject(forKey: HistoryService.wordCountRecountKey(for: directory))
            TestSupport.remove(directory)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let timestamp = try XCTUnwrap(DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 10, day: 20, hour: 15).date)
        let chineseText = "会议记录需要包含行动项"
        let recordID = UUID()
        do {
            let history = HistoryService(appSupportDirectory: directory, eventEmitter: { _ in })
            XCTAssertTrue(history.addRecord(id: recordID, timestamp: timestamp, rawText: chineseText, finalText: chineseText, appName: nil, appBundleIdentifier: nil, durationSeconds: 2, language: "zh", engineUsed: "Qwen3-ASR"))
        }
        try Self.setStoredWordsCount(1, inStoreAt: directory)
        XCTAssertEqual(try Self.storedWordsCount(inStoreAt: directory), 1)

        let history = HistoryService(appSupportDirectory: directory, eventEmitter: { _ in })
        XCTAssertTrue(history.wordCountRecountPending)
        let deltas = try history.recountWords(calendar: calendar)

        let expectedCount = DictumWordCount.count(chineseText)
        XCTAssertEqual(expectedCount, 11)
        XCTAssertEqual(try XCTUnwrap(history.record(withID: recordID)).wordsCount, expectedCount)
        XCTAssertEqual(try Self.storedWordsCount(inStoreAt: directory), 1, "重算只修改内存，提交前磁盘上的字数不变")
        XCTAssertEqual(deltas, [calendar.startOfDay(for: timestamp): expectedCount - 1])

        try history.commitWordCountRecount()
        XCTAssertEqual(try Self.storedWordsCount(inStoreAt: directory), expectedCount)

        history.markWordCountRecountCompleted()
        XCTAssertFalse(history.wordCountRecountPending)
        XCTAssertFalse(HistoryService(appSupportDirectory: directory, eventEmitter: { _ in }).wordCountRecountPending)
        XCTAssertEqual(try history.recountWords(calendar: calendar), [:])
    }

    func testRecountSkipsRecordsSyncedFromAnotherMac() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-word-count-remote")
        defer { TestSupport.remove(directory) }
        let suiteName = "DictumWordCountHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let timestamp = try XCTUnwrap(DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 10, day: 20, hour: 15).date)
        let localText = "本机听写的一段中文"
        let remoteText = "另一台电脑同步来的中文记录"
        let localID = UUID()
        let remoteID = UUID()

        let history = HistoryService(appSupportDirectory: directory, historySyncPreferences: preferences, eventEmitter: { _ in })
        XCTAssertTrue(history.addRecord(id: localID, timestamp: timestamp, rawText: localText, finalText: localText, appName: nil, appBundleIdentifier: nil, durationSeconds: 2, language: "zh", engineUsed: "Qwen3-ASR"))
        try history.applyUserDataSyncMutations([
            .upsertHistoryContent(UserDataSyncHistoryContentV1(
                recordID: remoteID,
                createdAt: timestamp,
                updatedAt: timestamp,
                originDeviceID: "another-mac",
                originPlatform: "macOS",
                source: "mac",
                processingState: "ready",
                rawTranscript: remoteText,
                finalText: remoteText,
                durationSeconds: 3,
                engineDisplayName: "Qwen3-ASR"
            ))
        ])
        XCTAssertEqual(try XCTUnwrap(history.record(withID: remoteID)).originDeviceID, "another-mac")
        for record in try history.allRecordsThrowing() {
            record.wordsCount = 1
        }
        try history.commitWordCountRecount()

        let deltas = try history.recountWords(calendar: calendar)

        XCTAssertEqual(deltas, [calendar.startOfDay(for: timestamp): DictumWordCount.count(localText) - 1])
        XCTAssertEqual(try XCTUnwrap(history.record(withID: remoteID)).wordsCount, DictumWordCount.count(remoteText))
    }

    static func setStoredWordsCount(_ count: Int, inStoreAt directory: URL) throws {
        let (container, context) = try SwiftDataStoreFactory.create(for: [TranscriptionRecord.self], storeName: "history", in: directory)
        for record in try context.fetch(FetchDescriptor<TranscriptionRecord>()) {
            record.wordsCount = count
        }
        try context.save()
        withExtendedLifetime(container) {}
    }

    static func storedWordsCount(inStoreAt directory: URL) throws -> Int {
        let (container, context) = try SwiftDataStoreFactory.create(for: [TranscriptionRecord.self], storeName: "history", in: directory)
        defer { withExtendedLifetime(container) {} }
        return try XCTUnwrap(context.fetch(FetchDescriptor<TranscriptionRecord>()).first).wordsCount
    }
}
