import XCTest
@testable import TypeWhisper

final class UsageStatisticsServiceTests: XCTestCase {
    @MainActor
    func testRecordsDailyAggregatesAndSummaries() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatistics")
        defer { TestSupport.remove(directory) }

        let calendar = Self.utcCalendar()
        let service = UsageStatisticsService(appSupportDirectory: directory, calendar: calendar)
        let today = Self.date(year: 2026, month: 7, day: 5, hour: 12, calendar: calendar)
        let yesterday = Self.date(year: 2026, month: 7, day: 4, hour: 9, calendar: calendar)

        service.recordTranscription(timestamp: today, wordsCount: 90, durationSeconds: 60, appBundleIdentifier: "com.example.editor")
        service.recordTranscription(timestamp: today, wordsCount: 45, durationSeconds: 60, appBundleIdentifier: "com.example.editor")
        service.recordTranscription(timestamp: yesterday, wordsCount: 45, durationSeconds: 30, appBundleIdentifier: "com.example.mail")

        let summary = service.summary(from: nil, to: today)
        XCTAssertEqual(summary.transcriptionCount, 3)
        XCTAssertEqual(summary.words, 180)
        XCTAssertEqual(summary.durationSeconds, 150, accuracy: 0.001)
        XCTAssertEqual(summary.appCount, 2)
        XCTAssertEqual(summary.rawWPM, 72, accuracy: 0.001)
        XCTAssertEqual(summary.rawSavedMinutes, 1.5, accuracy: 0.001)

        let daily = service.dailyWordCounts(days: 2, endingAt: today)
        XCTAssertEqual(daily.map(\.totalWords), [45, 135])
    }

    @MainActor
    func testHistoryBackfillIsIdempotentAndClearDoesNotRebackfill() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatisticsBackfill")
        defer { TestSupport.remove(directory) }

        let historyService = HistoryService(appSupportDirectory: directory)
        historyService.clearAll()
        historyService.addRecord(
            rawText: "Alpha beta gamma",
            finalText: "Alpha beta gamma",
            appName: "Editor",
            appBundleIdentifier: "com.example.editor",
            durationSeconds: 30,
            language: "en",
            engineUsed: "parakeet"
        )
        historyService.addRecord(
            rawText: "Delta epsilon",
            finalText: "Delta epsilon",
            appName: "Mail",
            appBundleIdentifier: "com.example.mail",
            durationSeconds: 20,
            language: "en",
            engineUsed: "parakeet"
        )

        let service = UsageStatisticsService(appSupportDirectory: directory)
        service.backfillFromHistoryIfNeeded(historyService.records)
        service.backfillFromHistoryIfNeeded(historyService.records)

        var summary = service.summary(from: nil)
        XCTAssertEqual(summary.transcriptionCount, 2)
        XCTAssertEqual(summary.words, 5)
        XCTAssertEqual(summary.appCount, 2)

        service.clearUsageStatistics()
        service.backfillFromHistoryIfNeeded(historyService.records)

        summary = service.summary(from: nil)
        XCTAssertEqual(summary.transcriptionCount, 0)
        XCTAssertEqual(summary.words, 0)
    }

    @MainActor
    func testHomeAndWidgetUseUsageStatisticsWhileKeepingRecentHistory() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatisticsDashboard")
        defer { TestSupport.remove(directory) }

        let calendar = Self.utcCalendar()
        let now = Self.date(year: 2026, month: 7, day: 5, hour: 12, calendar: calendar)
        let historyService = HistoryService(appSupportDirectory: directory)
        historyService.clearAll()
        historyService.addRecord(
            rawText: "Retained history only",
            finalText: "Retained history only",
            appName: "Notes",
            appBundleIdentifier: "com.example.notes",
            durationSeconds: 10,
            language: "en",
            engineUsed: "parakeet"
        )

        let usageStatisticsService = UsageStatisticsService(appSupportDirectory: directory, calendar: calendar)
        usageStatisticsService.recordTranscription(
            timestamp: now,
            wordsCount: 120,
            durationSeconds: 60,
            appBundleIdentifier: "com.example.aggregate"
        )

        let homeViewModel = HomeViewModel(
            historyService: historyService,
            usageStatisticsService: usageStatisticsService
        )
        homeViewModel.selectedTimePeriod = .week
        homeViewModel.refresh()

        XCTAssertTrue(homeViewModel.hasAnyTranscriptions)
        XCTAssertEqual(homeViewModel.wordsCount, 120)
        XCTAssertEqual(homeViewModel.averageWPM, "120")
        XCTAssertEqual(homeViewModel.appsUsed, 1)
        XCTAssertEqual(homeViewModel.recentTranscriptions.count, 1)
        XCTAssertEqual(homeViewModel.recentTranscriptions.first?.finalText, "Retained history only")

        let widgetDataService = WidgetDataService(
            historyService: historyService,
            usageStatisticsService: usageStatisticsService
        )
        let widgetData = widgetDataService.buildWidgetData(records: historyService.records, now: now)

        XCTAssertEqual(widgetData.stats.wordsToday, 120)
        XCTAssertEqual(widgetData.stats.wordsThisWeek, 120)
        XCTAssertEqual(widgetData.stats.averageWPM, "120")
        XCTAssertEqual(widgetData.stats.appsUsed, 1)
        XCTAssertEqual(widgetData.recentHistory.first?.preview, "Retained history only")
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        calendar: Calendar
    ) -> Date {
        DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ).date!
    }
}
