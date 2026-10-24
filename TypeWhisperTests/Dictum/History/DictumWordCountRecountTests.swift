import SwiftData
import XCTest
@testable import TypeWhisper

@MainActor
final class DictumWordCountRecountTests: XCTestCase {
    private struct SaveFailure: Error {}

    private struct Fixture {
        let directory: URL
        let calendar: Calendar
        let timestamp: Date
        let text = "会议记录需要包含行动项"
        var day: Date { calendar.startOfDay(for: timestamp) }
        var newCount: Int { DictumWordCount.count(text) }
    }

    private func makeFixture() throws -> Fixture {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-word-count-sequence")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let timestamp = try XCTUnwrap(
            DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 10, day: 20, hour: 15).date
        )
        let fixture = Fixture(directory: directory, calendar: calendar, timestamp: timestamp)
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: HistoryService.wordCountRecountKey(for: directory))
            TestSupport.remove(directory)
        }
        return fixture
    }

    /// 历史库里的记录带着旧字数 1，用量统计里该天也只记了 1 个字。
    private func seedStaleStores(_ fixture: Fixture, backfillCompleted: Bool = true) throws {
        do {
            let history = HistoryService(appSupportDirectory: fixture.directory, eventEmitter: { _ in })
            XCTAssertTrue(history.addRecord(
                timestamp: fixture.timestamp,
                rawText: fixture.text,
                finalText: fixture.text,
                appName: nil,
                appBundleIdentifier: nil,
                durationSeconds: 2,
                language: "zh",
                engineUsed: "Qwen3-ASR"
            ))
        }
        try DictumWordCountHistoryTests.setStoredWordsCount(1, inStoreAt: fixture.directory)

        let statistics = UsageStatisticsService(appSupportDirectory: fixture.directory, calendar: fixture.calendar)
        if backfillCompleted { statistics.backfillFromHistoryIfNeeded([]) }
        statistics.recordTranscription(
            timestamp: fixture.timestamp,
            wordsCount: 1,
            durationSeconds: 2,
            appBundleIdentifier: nil
        )
    }

    private func statisticsWords(_ fixture: Fixture, statistics: UsageStatisticsService? = nil) -> Int? {
        let service = statistics ?? UsageStatisticsService(appSupportDirectory: fixture.directory, calendar: fixture.calendar)
        return service.dailyWordCounts(days: 1, endingAt: fixture.timestamp).first?.totalWords
    }

    func testRecountUpdatesHistoryAndStatisticsTogether() throws {
        let fixture = try makeFixture()
        try seedStaleStores(fixture)
        let history = HistoryService(appSupportDirectory: fixture.directory, eventEmitter: { _ in })
        let statistics = UsageStatisticsService(appSupportDirectory: fixture.directory, calendar: fixture.calendar)
        XCTAssertTrue(history.wordCountRecountPending)

        DictumWordCountRecount.runIfPending(history: history, usageStatistics: statistics, calendar: fixture.calendar)

        XCTAssertEqual(try DictumWordCountHistoryTests.storedWordsCount(inStoreAt: fixture.directory), fixture.newCount)
        XCTAssertEqual(statisticsWords(fixture, statistics: statistics), fixture.newCount)
        XCTAssertFalse(history.wordCountRecountPending)
    }

    func testStatisticsSaveFailureLeavesHistoryUnchangedAndSecondRunAppliesDeltasOnce() throws {
        let fixture = try makeFixture()
        try seedStaleStores(fixture)
        var failNextSave = true
        let statistics = UsageStatisticsService(
            appSupportDirectory: fixture.directory,
            calendar: fixture.calendar,
            wordAdjustmentWriter: { context in
                if failNextSave {
                    failNextSave = false
                    throw SaveFailure()
                }
                try context.save()
            }
        )

        let firstLaunch = HistoryService(appSupportDirectory: fixture.directory, eventEmitter: { _ in })
        DictumWordCountRecount.runIfPending(history: firstLaunch, usageStatistics: statistics, calendar: fixture.calendar)

        XCTAssertEqual(try DictumWordCountHistoryTests.storedWordsCount(inStoreAt: fixture.directory), 1)
        XCTAssertEqual(statisticsWords(fixture, statistics: statistics), 1)
        XCTAssertTrue(firstLaunch.wordCountRecountPending)
        XCTAssertEqual(try XCTUnwrap(firstLaunch.allRecords().first).wordsCount, 1)

        let secondLaunch = HistoryService(appSupportDirectory: fixture.directory, eventEmitter: { _ in })
        DictumWordCountRecount.runIfPending(history: secondLaunch, usageStatistics: statistics, calendar: fixture.calendar)
        DictumWordCountRecount.runIfPending(history: secondLaunch, usageStatistics: statistics, calendar: fixture.calendar)

        XCTAssertEqual(try DictumWordCountHistoryTests.storedWordsCount(inStoreAt: fixture.directory), fixture.newCount)
        XCTAssertEqual(statisticsWords(fixture, statistics: statistics), fixture.newCount)
        XCTAssertFalse(secondLaunch.wordCountRecountPending)
    }

    func testInterruptionAfterStatisticsSaveAppliesDeltasExactlyOnce() throws {
        let fixture = try makeFixture()
        try seedStaleStores(fixture)
        let statistics = UsageStatisticsService(appSupportDirectory: fixture.directory, calendar: fixture.calendar)

        let interrupted = HistoryService(appSupportDirectory: fixture.directory, eventEmitter: { _ in })
        let deltas = try interrupted.recountWords(calendar: fixture.calendar)
        XCTAssertTrue(statistics.adjustWords(byDay: deltas, recountKey: interrupted.wordCountRecountStatisticsKey))
        XCTAssertEqual(statisticsWords(fixture, statistics: statistics), fixture.newCount)
        XCTAssertEqual(try DictumWordCountHistoryTests.storedWordsCount(inStoreAt: fixture.directory), 1)

        let nextLaunch = HistoryService(appSupportDirectory: fixture.directory, eventEmitter: { _ in })
        XCTAssertTrue(nextLaunch.wordCountRecountPending)
        DictumWordCountRecount.runIfPending(history: nextLaunch, usageStatistics: statistics, calendar: fixture.calendar)

        XCTAssertEqual(statisticsWords(fixture, statistics: statistics), fixture.newCount)
        XCTAssertEqual(try DictumWordCountHistoryTests.storedWordsCount(inStoreAt: fixture.directory), fixture.newCount)
        XCTAssertFalse(nextLaunch.wordCountRecountPending)
    }

    func testInterruptionAfterHistorySaveOnlyWritesTheMarker() throws {
        let fixture = try makeFixture()
        try seedStaleStores(fixture)
        let statistics = UsageStatisticsService(appSupportDirectory: fixture.directory, calendar: fixture.calendar)

        let interrupted = HistoryService(appSupportDirectory: fixture.directory, eventEmitter: { _ in })
        let deltas = try interrupted.recountWords(calendar: fixture.calendar)
        XCTAssertTrue(statistics.adjustWords(byDay: deltas, recountKey: interrupted.wordCountRecountStatisticsKey))
        try interrupted.commitWordCountRecount()
        XCTAssertTrue(interrupted.wordCountRecountPending)

        let nextLaunch = HistoryService(appSupportDirectory: fixture.directory, eventEmitter: { _ in })
        XCTAssertTrue(nextLaunch.wordCountRecountPending)
        DictumWordCountRecount.runIfPending(history: nextLaunch, usageStatistics: statistics, calendar: fixture.calendar)

        XCTAssertEqual(statisticsWords(fixture, statistics: statistics), fixture.newCount)
        XCTAssertEqual(try DictumWordCountHistoryTests.storedWordsCount(inStoreAt: fixture.directory), fixture.newCount)
        XCTAssertFalse(nextLaunch.wordCountRecountPending)
    }

    func testIncompleteBackfillAppliesNoDeltasAndStillRecountsHistory() throws {
        let fixture = try makeFixture()
        try seedStaleStores(fixture, backfillCompleted: false)
        let history = HistoryService(appSupportDirectory: fixture.directory, eventEmitter: { _ in })
        let statistics = UsageStatisticsService(appSupportDirectory: fixture.directory, calendar: fixture.calendar)

        DictumWordCountRecount.runIfPending(history: history, usageStatistics: statistics, calendar: fixture.calendar)

        XCTAssertEqual(statisticsWords(fixture, statistics: statistics), 1)
        XCTAssertEqual(try DictumWordCountHistoryTests.storedWordsCount(inStoreAt: fixture.directory), fixture.newCount)
        XCTAssertFalse(history.wordCountRecountPending)
    }
}
