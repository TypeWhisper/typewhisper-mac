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

    /// Installations that already completed the totals-only backfill (before app/model/hour
    /// breakdowns existed) must have those breakdowns filled in from history on next launch,
    /// without re-adding to the already-migrated totals.
    @MainActor
    func testDetailBreakdownsAreBackfilledForInstallationsThatAlreadyMigratedTotals() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatisticsDetailBackfill")
        defer { TestSupport.remove(directory) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let historyService = HistoryService(appSupportDirectory: directory)
        historyService.clearAll()
        historyService.addRecord(
            rawText: "Alpha beta gamma",
            finalText: "Alpha beta gamma",
            appName: "Editor",
            appBundleIdentifier: "com.example.editor",
            durationSeconds: 30,
            language: "en",
            engineUsed: "parakeet",
            modelUsed: "parakeet-fast"
        )
        let recordHour = calendar.component(.hour, from: historyService.records[0].timestamp)

        do {
            // Simulate a pre-existing installation: totals already backfilled from history
            // (historyBackfillCompleted = true) but with no app/model/hour breakdowns, since
            // those fields didn't exist yet.
            let (_, context) = try SwiftDataStoreFactory.create(
                for: [UsageStatisticsDay.self, UsageStatisticsMetadata.self],
                storeName: "usage-statistics",
                in: directory
            )
            let statisticsDay = UsageStatisticsDay(
                day: today,
                transcriptionCount: 1,
                totalWords: 3,
                totalDurationSeconds: 30,
                appBundleIdentifiers: ["com.example.editor"]
            )
            context.insert(statisticsDay)
            context.insert(UsageStatisticsMetadata(key: "historyBackfillCompleted", value: "true"))
            try context.save()
        }

        let service = UsageStatisticsService(appSupportDirectory: directory, calendar: calendar)
        service.backfillFromHistoryIfNeeded(historyService.records)

        let summary = service.summary(from: today)
        XCTAssertEqual(summary.transcriptionCount, 1, "Totals must not be double-counted by the detail backfill")
        XCTAssertEqual(summary.words, 3, "Totals must not be double-counted by the detail backfill")

        let snapshot = try XCTUnwrap(service.dailyWordCounts(days: 1).first)
        XCTAssertEqual(snapshot.appCounts, [UsageStatisticsKeys.appKey(bundleIdentifier: "com.example.editor", appName: "Editor"): 1])
        XCTAssertEqual(snapshot.modelCounts, [UsageStatisticsKeys.modelKey(engineUsed: "parakeet", modelUsed: "parakeet-fast"): 1])
        XCTAssertEqual(snapshot.hourCounts[recordHour], 1)

        // Running it again must stay idempotent.
        service.backfillFromHistoryIfNeeded(historyService.records)
        let secondSnapshot = try XCTUnwrap(service.dailyWordCounts(days: 1).first)
        XCTAssertEqual(secondSnapshot.appCounts, [UsageStatisticsKeys.appKey(bundleIdentifier: "com.example.editor", appName: "Editor"): 1])
    }

    @MainActor
    func testHomeAndWidgetUseUsageStatisticsWhileKeepingRecentHistory() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatisticsDashboard")
        defer { TestSupport.remove(directory) }

        let calendar = Calendar.current
        let now = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: Date()))!
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
        homeViewModel.refresh()

        XCTAssertTrue(homeViewModel.hasAnyTranscriptions)
        XCTAssertEqual(homeViewModel.recentTranscriptions.count, 1)
        XCTAssertEqual(homeViewModel.recentTranscriptions.first?.finalText, "Retained history only")

        // Words/WPM/apps-used metrics now live on StatisticsViewModel, which - unlike Home - is
        // fed only by the persistent usage-statistics snapshots, not by (retention-dependent)
        // history records.
        let statisticsViewModel = StatisticsViewModel(usageStatisticsService: usageStatisticsService)
        statisticsViewModel.selectedTimePeriod = .week
        statisticsViewModel.refresh()

        XCTAssertEqual(statisticsViewModel.wordsCount, 120)
        XCTAssertEqual(statisticsViewModel.averageWPM, "120")
        XCTAssertEqual(statisticsViewModel.appsUsed, 1)

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

    /// Statistics (overview, Top Apps, Models Used, and the heatmap) must all be derived from the
    /// same persistent `UsageStatisticsService` snapshots, so that "Clear Usage Statistics" wipes
    /// every section together instead of leaving some populated from history.
    @MainActor
    func testClearingUsageStatisticsClearsAllStatisticsSections() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatisticsClearAll")
        defer { TestSupport.remove(directory) }

        // `StatisticsViewModel.refresh()` always buckets against the real wall-clock `Date()`
        // (via `Calendar.current`), so tests use timestamps relative to `Date()` rather than a
        // fixed/injected calendar - matching how the view model is actually driven in the app.
        let calendar = Calendar.current
        let usageStatisticsService = UsageStatisticsService(appSupportDirectory: directory, calendar: calendar)
        let today = calendar.date(byAdding: .hour, value: 9, to: calendar.startOfDay(for: Date()))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        usageStatisticsService.recordTranscription(
            timestamp: today,
            wordsCount: 50,
            durationSeconds: 30,
            appBundleIdentifier: "com.example.editor",
            appName: "Editor",
            engineUsed: "parakeet",
            modelUsed: "parakeet-fast"
        )
        usageStatisticsService.recordTranscription(
            timestamp: yesterday,
            wordsCount: 20,
            durationSeconds: 15,
            appBundleIdentifier: "com.example.mail",
            appName: "Mail",
            engineUsed: "whisper",
            modelUsed: "small.en"
        )

        let viewModel = StatisticsViewModel(usageStatisticsService: usageStatisticsService)
        viewModel.refresh()

        XCTAssertTrue(viewModel.hasAnyData)
        XCTAssertEqual(viewModel.totalDaysActive, 2)
        XCTAssertEqual(viewModel.totalTranscriptions, 2)
        XCTAssertFalse(viewModel.appUsageStats.isEmpty)
        XCTAssertFalse(viewModel.modelUsageStats.isEmpty)
        XCTAssertGreaterThan(viewModel.maxHourlyCount, 0)

        usageStatisticsService.clearUsageStatistics()
        viewModel.refresh()

        XCTAssertFalse(viewModel.hasAnyData)
        XCTAssertEqual(viewModel.totalDaysActive, 0)
        XCTAssertEqual(viewModel.currentStreak, 0)
        XCTAssertEqual(viewModel.longestStreak, 0)
        XCTAssertEqual(viewModel.totalTranscriptions, 0)
        XCTAssertTrue(viewModel.appUsageStats.isEmpty, "Clearing usage statistics must also clear Top Apps")
        XCTAssertTrue(viewModel.modelUsageStats.isEmpty, "Clearing usage statistics must also clear Models Used")
        XCTAssertEqual(viewModel.maxHourlyCount, 0, "Clearing usage statistics must also clear the heatmap")
    }

    /// Statistics must stay fully populated even when history is disabled or has a short
    /// retention window, because the view model never reads `HistoryService` records - only the
    /// persistent usage-statistics snapshots, which are unaffected by history retention/purging.
    @MainActor
    func testStatisticsSurviveHistoryBeingDisabledOrPurged() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatisticsNoHistory")
        defer { TestSupport.remove(directory) }

        let calendar = Calendar.current
        let usageStatisticsService = UsageStatisticsService(appSupportDirectory: directory, calendar: calendar)
        let today = calendar.date(byAdding: .hour, value: 10, to: calendar.startOfDay(for: Date()))!

        // Simulate history being disabled entirely: usage statistics are recorded (as they always
        // are, independent of the history toggle), but no TranscriptionRecord is ever created.
        usageStatisticsService.recordTranscription(
            timestamp: today,
            wordsCount: 100,
            durationSeconds: 40,
            appBundleIdentifier: "com.example.notes",
            appName: "Notes",
            engineUsed: "whisper",
            modelUsed: "base.en"
        )

        let historyService = HistoryService(appSupportDirectory: directory)
        historyService.clearAll() // history disabled/purged: zero retained records

        let viewModel = StatisticsViewModel(usageStatisticsService: usageStatisticsService)
        viewModel.refresh()

        XCTAssertTrue(historyService.records.isEmpty)
        XCTAssertTrue(viewModel.hasAnyData)
        XCTAssertEqual(viewModel.totalTranscriptions, 1)
        XCTAssertEqual(viewModel.totalDaysActive, 1)
        XCTAssertEqual(viewModel.currentStreak, 1)
        XCTAssertEqual(viewModel.appUsageStats.first?.count, 1)
        XCTAssertEqual(viewModel.modelUsageStats.first?.count, 1)
        XCTAssertEqual(viewModel.maxHourlyCount, 1)
    }

    /// Overview, Top Apps, Models Used, and the heatmap must agree on the same period filter.
    @MainActor
    func testPeriodFilteringIsConsistentAcrossAllSections() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatisticsPeriodFilter")
        defer { TestSupport.remove(directory) }

        let calendar = Calendar.current
        let usageStatisticsService = UsageStatisticsService(appSupportDirectory: directory, calendar: calendar)
        let now = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: Date()))!

        // Two transcriptions within the last week.
        usageStatisticsService.recordTranscription(
            timestamp: now,
            wordsCount: 10,
            durationSeconds: 5,
            appBundleIdentifier: "com.example.editor",
            appName: "Editor",
            engineUsed: "parakeet",
            modelUsed: nil
        )
        usageStatisticsService.recordTranscription(
            timestamp: calendar.date(byAdding: .day, value: -2, to: now)!,
            wordsCount: 10,
            durationSeconds: 5,
            appBundleIdentifier: "com.example.mail",
            appName: "Mail",
            engineUsed: "whisper",
            modelUsed: nil
        )
        // One transcription older than a week but within a month.
        usageStatisticsService.recordTranscription(
            timestamp: calendar.date(byAdding: .day, value: -20, to: now)!,
            wordsCount: 10,
            durationSeconds: 5,
            appBundleIdentifier: "com.example.notes",
            appName: "Notes",
            engineUsed: "whisper",
            modelUsed: nil
        )
        // One transcription older than a month, only visible in "All Time".
        usageStatisticsService.recordTranscription(
            timestamp: calendar.date(byAdding: .day, value: -90, to: now)!,
            wordsCount: 10,
            durationSeconds: 5,
            appBundleIdentifier: "com.example.old",
            appName: "Old",
            engineUsed: "whisper",
            modelUsed: nil
        )

        let viewModel = StatisticsViewModel(usageStatisticsService: usageStatisticsService)

        func totals() -> (transcriptions: Int, appCount: Int, modelCount: Int, hourlyCount: Int) {
            (
                viewModel.totalTranscriptions,
                viewModel.appUsageStats.reduce(0) { $0 + $1.count },
                viewModel.modelUsageStats.reduce(0) { $0 + $1.count },
                viewModel.hourlyActivity.flatMap { $0 }.reduce(0, +)
            )
        }

        viewModel.selectedTimePeriod = .week
        viewModel.refresh()
        var current = totals()
        XCTAssertEqual(current.transcriptions, 2)
        XCTAssertEqual(current.appCount, 2)
        XCTAssertEqual(current.modelCount, 2)
        XCTAssertEqual(current.hourlyCount, 2)

        viewModel.selectedTimePeriod = .month
        viewModel.refresh()
        current = totals()
        XCTAssertEqual(current.transcriptions, 3)
        XCTAssertEqual(current.appCount, 3)
        XCTAssertEqual(current.modelCount, 3)
        XCTAssertEqual(current.hourlyCount, 3)

        viewModel.selectedTimePeriod = .allTime
        viewModel.refresh()
        current = totals()
        XCTAssertEqual(current.transcriptions, 4)
        XCTAssertEqual(current.appCount, 4)
        XCTAssertEqual(current.modelCount, 4)
        XCTAssertEqual(current.hourlyCount, 4)
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
