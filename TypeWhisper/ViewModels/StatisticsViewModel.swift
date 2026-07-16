import AppKit
import Combine
import Foundation
import TypeWhisperPluginSDK

enum TimePeriod: String, CaseIterable {
    case week
    case month
    case allTime

    var displayName: String {
        switch self {
        case .week: return String(localized: "Week")
        case .month: return String(localized: "Month")
        case .allTime: return String(localized: "All Time")
        }
    }

    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .allTime: return nil
        }
    }
}

struct ActivityDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let wordCount: Int
}

struct AppUsageStat: Identifiable {
    let id: String
    let bundleIdentifier: String?
    let displayName: String
    let count: Int
    let percent: Double
}

struct ModelUsageStat: Identifiable {
    let id: String
    let label: String
    let count: Int
    let percent: Double
}

@MainActor
final class StatisticsViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: StatisticsViewModel?
    static var shared: StatisticsViewModel {
        guard let instance = _shared else {
            fatalError("StatisticsViewModel not initialized")
        }
        return instance
    }

    @Published var selectedTimePeriod: TimePeriod = .allTime
    @Published var totalDaysActive: Int = 0
    @Published var currentStreak: Int = 0
    @Published var longestStreak: Int = 0
    @Published var totalTranscriptions: Int = 0
    @Published var totalWords: Int = 0
    @Published var appUsageStats: [AppUsageStat] = []
    @Published var modelUsageStats: [ModelUsageStat] = []
    @Published var hourlyActivity: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    @Published var hasAnyData: Bool = false

    // Formerly on HomeViewModel; moved here so the period picker, overview metrics, and activity
    // chart all live in one place per the Statistics-tab consolidation.
    @Published var wordsCount: Int = 0
    @Published var averageWPM: String = "—"
    @Published var appsUsed: Int = 0
    @Published var timeSaved: String = "—"
    @Published var chartData: [ActivityDataPoint] = []
    @Published var wordsTrend: Double?
    @Published var wpmTrend: Double?
    @Published var appsTrend: Double?
    @Published var timeSavedTrend: Double?

    var maxHourlyCount: Int { hourlyActivity.flatMap { $0 }.max() ?? 0 }

    // Statistics are intentionally derived only from `UsageStatisticsService`'s persistent daily
    // snapshots, never from `HistoryService` records. History is subject to retention limits, can
    // be disabled, and can be cleared independently of usage statistics, which would otherwise
    // make Top Apps/Models/heatmap inconsistent with the (retention-independent) overview cards.
    // Clearing usage statistics now clears everything shown here in one step, and every section
    // survives history being disabled, purged, or cleared - see UsageStatisticsDay for the
    // persisted per-app/model/hour aggregates this view model reads.
    private let usageStatisticsService: UsageStatisticsService
    private var cancellables = Set<AnyCancellable>()
    private var refreshWorkItem: DispatchWorkItem?

    private var appDisplayNameCache: [String: String] = [:]

    init(usageStatisticsService: UsageStatisticsService) {
        self.usageStatisticsService = usageStatisticsService

        setupBindings()
        refresh()
    }

    private func setupBindings() {
        usageStatisticsService.$days
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)

        $selectedTimePeriod
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func refresh() {
        let now = Date()
        let periodDays = daysInSelectedPeriod(now: now)

        totalDaysActive = periodDays.count
        let streaks = computeStreaks(from: periodDays, now: now)
        currentStreak = streaks.current
        longestStreak = streaks.longest
        totalTranscriptions = periodDays.reduce(0) { $0 + $1.transcriptionCount }
        totalWords = periodDays.reduce(0) { $0 + $1.totalWords }

        appUsageStats = computeAppStats(from: periodDays)
        modelUsageStats = computeModelStats(from: periodDays)
        hourlyActivity = computeHourlyActivity(from: periodDays)

        hasAnyData = usageStatisticsService.hasAnyStatistics

        // Word/WPM/apps/time-saved metrics and the activity chart, ported from the former
        // HomeViewModel dashboard.
        let stats = computeStats(for: currentSummary(now: now))
        wordsCount = stats.words
        averageWPM = stats.wpm
        appsUsed = stats.apps
        timeSaved = stats.timeSaved

        if let days = selectedTimePeriod.days {
            let prevStats = computeStats(for: usageStatisticsService.previousPeriodSummary(days: days, endingAt: now))
            wordsTrend = Self.trendPercent(current: Double(stats.words), previous: Double(prevStats.words))
            appsTrend = Self.trendPercent(current: Double(stats.apps), previous: Double(prevStats.apps))
            wpmTrend = Self.trendPercent(current: stats.rawWPM, previous: prevStats.rawWPM)
            timeSavedTrend = Self.trendPercent(current: stats.rawSavedMinutes, previous: prevStats.rawSavedMinutes)
        } else {
            wordsTrend = nil
            wpmTrend = nil
            appsTrend = nil
            timeSavedTrend = nil
        }

        chartData = buildChartData(now: now)
    }

    // MARK: - Words / WPM / apps / time-saved metrics

    private struct PeriodStats {
        let words: Int
        let wpm: String
        let rawWPM: Double
        let apps: Int
        let timeSaved: String
        let rawSavedMinutes: Double
    }

    private func currentSummary(now: Date) -> UsageStatisticsSummary {
        guard let days = selectedTimePeriod.days else {
            return usageStatisticsService.summary(from: nil, to: now)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let endDay = calendar.date(byAdding: .day, value: 1, to: today) else {
            return .empty
        }
        return usageStatisticsService.summary(startDay: startDay, endDayExclusive: endDay)
    }

    private func computeStats(for summary: UsageStatisticsSummary) -> PeriodStats {
        let words = summary.words
        let rawWPM: Double
        let wpm: String
        if summary.rawWPM > 0 {
            rawWPM = summary.rawWPM
            wpm = "\(Int(rawWPM))"
        } else {
            rawWPM = 0
            wpm = "—"
        }

        let apps = summary.appCount

        let rawSavedMinutes = summary.rawSavedMinutes
        let timeSaved: String
        if rawSavedMinutes > 0 {
            let mins = Int(rawSavedMinutes)
            if mins >= 60 {
                timeSaved = String(localized: "\(mins / 60)h \(mins % 60)m")
            } else {
                timeSaved = String(localized: "\(mins)m")
            }
        } else {
            timeSaved = "—"
        }

        return PeriodStats(words: words, wpm: wpm, rawWPM: rawWPM, apps: apps, timeSaved: timeSaved, rawSavedMinutes: rawSavedMinutes)
    }

    nonisolated static func trendPercent(current: Double, previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return ((current - previous) / previous) * 100
    }

    private func buildChartData(now: Date) -> [ActivityDataPoint] {
        usageStatisticsService
            .dailyWordCounts(days: selectedTimePeriod.days, endingAt: now)
            .map { ActivityDataPoint(date: $0.day, wordCount: $0.totalWords) }
    }

    // MARK: - Streaks

    private func computeStreaks(from days: [UsageStatisticsDaySnapshot], now: Date) -> (current: Int, longest: Int) {
        guard !days.isEmpty else { return (0, 0) }
        let calendar = Calendar.current
        let activeDays = Set(days.map { calendar.startOfDay(for: $0.day) })
        let sortedDays = activeDays.sorted()

        var longest = 1
        var run = 1
        for index in 1..<sortedDays.count {
            let diff = calendar.dateComponents([.day], from: sortedDays[index - 1], to: sortedDays[index]).day ?? 0
            if diff == 1 {
                run += 1
            } else if diff > 1 {
                run = 1
            }
            longest = max(longest, run)
        }

        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return (activeDays.contains(today) ? 1 : 0, longest)
        }

        var current = 0
        if activeDays.contains(today) || activeDays.contains(yesterday) {
            var cursor = activeDays.contains(today) ? today : yesterday
            while activeDays.contains(cursor) {
                current += 1
                guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previous
            }
        }

        return (current, longest)
    }

    // MARK: - Period filtering

    private func daysInSelectedPeriod(now: Date) -> [UsageStatisticsDaySnapshot] {
        let allDays = usageStatisticsService.days
        guard let periodLength = selectedTimePeriod.days else { return allDays }
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -(periodLength - 1), to: calendar.startOfDay(for: now)) else {
            return allDays
        }
        return allDays.filter { $0.day >= cutoff }
    }

    // MARK: - App breakdown

    private func computeAppStats(from days: [UsageStatisticsDaySnapshot]) -> [AppUsageStat] {
        var merged: [String: Int] = [:]
        for day in days {
            for (key, count) in day.appCounts {
                merged[key, default: 0] += count
            }
        }
        guard !merged.isEmpty else { return [] }
        let total = merged.values.reduce(0, +)

        return merged.map { key, count -> AppUsageStat in
            let (bundleIdentifier, fallbackName) = UsageStatisticsKeys.parseAppKey(key)
            let name = resolveAppDisplayName(bundleIdentifier: bundleIdentifier, fallbackName: fallbackName)
            return AppUsageStat(
                id: key,
                bundleIdentifier: bundleIdentifier,
                displayName: name,
                count: count,
                percent: Double(count) / Double(total) * 100
            )
        }
        .sorted { $0.count > $1.count }
        .prefix(8)
        .map { $0 }
    }

    private func resolveAppDisplayName(bundleIdentifier: String?, fallbackName: String?) -> String {
        if let bundleIdentifier {
            if let cached = appDisplayNameCache[bundleIdentifier] {
                return cached
            }
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
               let bundle = Bundle(url: appURL),
               let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty {
                appDisplayNameCache[bundleIdentifier] = name
                return name
            }
        }

        if let fallbackName, !fallbackName.isEmpty {
            return fallbackName
        }

        guard let bundleIdentifier else {
            return String(localized: "Unknown App")
        }
        let lastComponent = bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
        return lastComponent.replacingOccurrences(of: "-", with: " ").capitalized
    }

    // MARK: - Hourly activity heatmap

    /// Grid indexed [weekday][hour], weekday 0 = Monday ... 6 = Sunday.
    private func computeHourlyActivity(from days: [UsageStatisticsDaySnapshot]) -> [[Int]] {
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let calendar = Calendar.current
        for day in days {
            let weekdayRaw = calendar.component(.weekday, from: day.day) // 1 = Sunday ... 7 = Saturday
            let mondayFirstIndex = (weekdayRaw + 5) % 7
            for hour in 0..<min(24, day.hourCounts.count) {
                grid[mondayFirstIndex][hour] += day.hourCounts[hour]
            }
        }
        return grid
    }

    // MARK: - Model breakdown

    private func computeModelStats(from days: [UsageStatisticsDaySnapshot]) -> [ModelUsageStat] {
        var merged: [String: Int] = [:]
        for day in days {
            for (key, count) in day.modelCounts {
                merged[key, default: 0] += count
            }
        }
        guard !merged.isEmpty else { return [] }
        let total = merged.values.reduce(0, +)

        let grouped = Dictionary(grouping: merged.keys) { key -> String in
            let (engineUsed, modelUsed) = UsageStatisticsKeys.parseModelKey(key)
            return modelLabel(engineUsed: engineUsed, modelUsed: modelUsed)
        }

        return grouped.map { label, keys in
            let count = keys.reduce(0) { $0 + (merged[$1] ?? 0) }
            return ModelUsageStat(id: label, label: label, count: count, percent: Double(count) / Double(total) * 100)
        }
        .sorted { $0.count > $1.count }
    }

    private func modelLabel(engineUsed: String, modelUsed: String?) -> String {
        let engineName = engineDisplayName(engineUsed)
        if let modelUsed, !modelUsed.isEmpty, modelUsed != engineName {
            return "\(engineName) – \(modelUsed)"
        }
        return engineName
    }

    private func engineDisplayName(_ engineUsed: String) -> String {
        if let plugin = PluginManager.shared?.transcriptionEngine(for: engineUsed) {
            return plugin.providerDisplayName
        }
        switch engineUsed.lowercased() {
        case "whisper": return "Whisper"
        case "parakeet": return "Parakeet"
        case "unknown": return String(localized: "Unknown")
        default: return engineUsed.capitalized
        }
    }
}
