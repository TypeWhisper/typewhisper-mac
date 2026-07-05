import Foundation
import Combine
import WidgetKit

@MainActor
final class WidgetDataService {
    private let historyService: HistoryService
    private let usageStatisticsService: UsageStatisticsService
    private var cancellable: AnyCancellable?

    init(historyService: HistoryService, usageStatisticsService: UsageStatisticsService) {
        self.historyService = historyService
        self.usageStatisticsService = usageStatisticsService

        cancellable = Publishers.CombineLatest(historyService.$records, usageStatisticsService.$days)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] records, _ in
                self?.updateWidgetData(records: records, now: Date())
            }
    }

    private func updateWidgetData(records: [TranscriptionRecord], now: Date) {
        let data = buildWidgetData(records: records, now: now)
        data.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func buildWidgetData(records: [TranscriptionRecord], now: Date = Date()) -> WidgetData {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let startOfWeek = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        let todaySummary = usageStatisticsService.summary(startDay: startOfToday, endDayExclusive: startOfTomorrow)
        let weekSummary = usageStatisticsService.summary(startDay: startOfWeek, endDayExclusive: startOfTomorrow)

        // Stats
        let wordsToday = todaySummary.words
        let wordsThisWeek = weekSummary.words

        let averageWPM: String
        if weekSummary.rawWPM > 0 {
            averageWPM = "\(Int(weekSummary.rawWPM))"
        } else {
            averageWPM = "-"
        }

        // Time saved today (typing at 45 WPM baseline)
        let savedMinutes = todaySummary.rawSavedMinutes
        let timeSavedToday: String
        if savedMinutes > 0 {
            let mins = Int(savedMinutes)
            if mins >= 60 {
                timeSavedToday = "\(mins / 60)h \(mins % 60)m"
            } else {
                timeSavedToday = "\(mins)m"
            }
        } else {
            timeSavedToday = "-"
        }

        let stats = WidgetStatsData(
            wordsToday: wordsToday,
            timeSavedToday: timeSavedToday,
            wordsThisWeek: wordsThisWeek,
            averageWPM: averageWPM,
            appsUsed: weekSummary.appCount
        )

        // Chart - 7 days
        var chartPoints: [WidgetChartPoint] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "E"
        for snapshot in usageStatisticsService.dailyWordCounts(days: 7, endingAt: now) {
            chartPoints.append(WidgetChartPoint(
                dateLabel: dateFormatter.string(from: snapshot.day),
                date: snapshot.day,
                wordCount: snapshot.totalWords
            ))
        }

        // Recent history - last 5
        let recentHistory = Array(records.prefix(5)).map { record in
            WidgetHistoryItem(
                id: record.id,
                timestamp: record.timestamp,
                preview: String(record.finalText.prefix(100)),
                appName: record.appName,
                bundleId: record.appBundleIdentifier,
                wordsCount: record.wordsCount
            )
        }

        return WidgetData(
            stats: stats,
            chartPoints: chartPoints,
            recentHistory: recentHistory,
            lastUpdated: now
        )
    }
}
