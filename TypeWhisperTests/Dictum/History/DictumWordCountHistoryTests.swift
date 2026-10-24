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
        XCTAssertEqual(try Self.storedWordsCount(inStoreAt: directory), expectedCount)
        XCTAssertEqual(try XCTUnwrap(history.record(withID: recordID)).wordsCount, expectedCount)
        XCTAssertEqual(deltas, [calendar.startOfDay(for: timestamp): expectedCount - 1])

        history.markWordCountRecountCompleted()
        XCTAssertFalse(history.wordCountRecountPending)
        XCTAssertFalse(HistoryService(appSupportDirectory: directory, eventEmitter: { _ in }).wordCountRecountPending)
        XCTAssertEqual(try history.recountWords(calendar: calendar), [:])
    }

    private static func setStoredWordsCount(_ count: Int, inStoreAt directory: URL) throws {
        let (container, context) = try SwiftDataStoreFactory.create(for: [TranscriptionRecord.self], storeName: "history", in: directory)
        for record in try context.fetch(FetchDescriptor<TranscriptionRecord>()) {
            record.wordsCount = count
        }
        try context.save()
        withExtendedLifetime(container) {}
    }

    private static func storedWordsCount(inStoreAt directory: URL) throws -> Int {
        let (container, context) = try SwiftDataStoreFactory.create(for: [TranscriptionRecord.self], storeName: "history", in: directory)
        defer { withExtendedLifetime(container) {} }
        return try XCTUnwrap(context.fetch(FetchDescriptor<TranscriptionRecord>()).first).wordsCount
    }
}
