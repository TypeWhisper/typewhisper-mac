import Foundation
import Combine
import WidgetKit

@MainActor
final class WidgetDataService {
    private let historyService: HistoryService
    private var cancellable: AnyCancellable?

    init(historyService: HistoryService) {
        self.historyService = historyService

        cancellable = historyService.$records
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] records in
                self?.updateWidgetData(records: records)
            }
    }

    private func updateWidgetData(records: [TranscriptionRecord]) {
        let data = buildWidgetData(records: records)
        data.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func buildWidgetData(records: [TranscriptionRecord]) -> WidgetData {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        let todayRecords = records.filter { $0.timestamp >= startOfToday }
        let weekRecords = records.filter { $0.timestamp >= startOfWeek }

        // Stats
        let wordsToday = todayRecords.reduce(0) { $0 + $1.wordsCount }
        let wordsThisWeek = weekRecords.reduce(0) { $0 + $1.wordsCount }

        let totalMinutesWeek = weekRecords.reduce(0.0) { $0 + $1.durationSeconds } / 60.0
        let averageWPM: String
        if totalMinutesWeek > 0 && wordsThisWeek > 0 {
            averageWPM = "\(Int(Double(wordsThisWeek) / totalMinutesWeek))"
        } else {
            averageWPM = "-"
        }

        let uniqueApps = Set(weekRecords.compactMap { $0.appBundleIdentifier })

        // Time saved today (typing at 45 WPM baseline)
        let todayMinutes = todayRecords.reduce(0.0) { $0 + $1.durationSeconds } / 60.0
        let typingMinutes = Double(wordsToday) / 45.0
        let savedMinutes = typingMinutes - todayMinutes
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
            appsUsed: uniqueApps.count
        )

        // Chart - 7 days
        var chartPoints: [WidgetChartPoint] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "E"
        for i in (0..<7).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -i, to: now) else { continue }
            let dayStart = calendar.startOfDay(for: day)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            let dayWords = records.filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
                .reduce(0) { $0 + $1.wordsCount }
            chartPoints.append(WidgetChartPoint(
                dateLabel: dateFormatter.string(from: day),
                date: dayStart,
                wordCount: dayWords
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
