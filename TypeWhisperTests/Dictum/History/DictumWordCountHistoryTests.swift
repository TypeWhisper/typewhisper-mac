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

    func testHistoryLoadRecountsStoredRecordsWithCurrentRule() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-word-count-migration")
        defer { TestSupport.remove(directory) }
        let chineseText = "会议记录需要包含行动项"
        let staleCount = chineseText.split(separator: " ").count
        let recordID = UUID()
        do {
            let history = HistoryService(appSupportDirectory: directory, eventEmitter: { _ in })
            XCTAssertTrue(history.addRecord(id: recordID, rawText: chineseText, finalText: chineseText, appName: nil, appBundleIdentifier: nil, durationSeconds: 2, language: "zh", engineUsed: "Qwen3-ASR"))
            let record = try XCTUnwrap(history.record(withID: recordID))
            record.wordsCount = staleCount
        }
        let reopened = HistoryService(appSupportDirectory: directory, eventEmitter: { _ in })
        let record = try XCTUnwrap(reopened.record(withID: recordID))
        XCTAssertEqual(staleCount, 1)
        XCTAssertEqual(record.wordsCount, DictumWordCount.count(chineseText))
    }
}
