import AppKit
import Combine
import Foundation
import TypeWhisperPluginSDK

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

    var maxHourlyCount: Int { hourlyActivity.flatMap { $0 }.max() ?? 0 }

    private let historyService: HistoryService
    private let usageStatisticsService: UsageStatisticsService
    private var cancellables = Set<AnyCancellable>()
    private var refreshWorkItem: DispatchWorkItem?

    private var appDisplayNameCache: [String: String] = [:]

    init(historyService: HistoryService, usageStatisticsService: UsageStatisticsService) {
        self.historyService = historyService
        self.usageStatisticsService = usageStatisticsService

        setupBindings()
        refresh()
    }

    private func setupBindings() {
        historyService.$records
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)

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

        let periodRecords = recordsInSelectedPeriod(now: now)
        appUsageStats = computeAppStats(from: periodRecords)
        modelUsageStats = computeModelStats(from: periodRecords)
        hourlyActivity = computeHourlyActivity(from: periodRecords)

        hasAnyData = usageStatisticsService.hasAnyStatistics || !historyService.records.isEmpty
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

    private func recordsInSelectedPeriod(now: Date) -> [TranscriptionRecord] {
        guard let days = selectedTimePeriod.days else { return historyService.records }
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) else {
            return historyService.records
        }
        return historyService.records.filter { $0.timestamp >= cutoff }
    }

    // MARK: - App breakdown

    private func computeAppStats(from records: [TranscriptionRecord]) -> [AppUsageStat] {
        guard !records.isEmpty else { return [] }
        let total = records.count
        let grouped = Dictionary(grouping: records) { record in
            record.appBundleIdentifier ?? record.appName ?? "unknown"
        }

        return grouped.map { key, recs -> AppUsageStat in
            let bundleIdentifier = recs.first?.appBundleIdentifier
            let name = resolveAppDisplayName(bundleIdentifier: bundleIdentifier, fallbackName: recs.first?.appName)
            return AppUsageStat(
                id: key,
                bundleIdentifier: bundleIdentifier,
                displayName: name,
                count: recs.count,
                percent: Double(recs.count) / Double(total) * 100
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
            return localizedAppText("Unknown App", de: "Unbekannte App", ja: "不明なアプリ")
        }
        let lastComponent = bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
        return lastComponent.replacingOccurrences(of: "-", with: " ").capitalized
    }

    // MARK: - Hourly activity heatmap

    /// Grid indexed [weekday][hour], weekday 0 = Monday ... 6 = Sunday.
    private func computeHourlyActivity(from records: [TranscriptionRecord]) -> [[Int]] {
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let calendar = Calendar.current
        for record in records {
            let weekdayRaw = calendar.component(.weekday, from: record.timestamp) // 1 = Sunday ... 7 = Saturday
            let mondayFirstIndex = (weekdayRaw + 5) % 7
            let hour = calendar.component(.hour, from: record.timestamp)
            grid[mondayFirstIndex][hour] += 1
        }
        return grid
    }

    // MARK: - Model breakdown

    private func computeModelStats(from records: [TranscriptionRecord]) -> [ModelUsageStat] {
        guard !records.isEmpty else { return [] }
        let total = records.count
        let grouped = Dictionary(grouping: records) { modelLabel(for: $0) }

        return grouped.map { label, recs in
            ModelUsageStat(id: label, label: label, count: recs.count, percent: Double(recs.count) / Double(total) * 100)
        }
        .sorted { $0.count > $1.count }
    }

    private func modelLabel(for record: TranscriptionRecord) -> String {
        let engineName = engineDisplayName(record.engineUsed)
        if let modelUsed = record.modelUsed, !modelUsed.isEmpty, modelUsed != engineName {
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
        case "unknown": return localizedAppText("Unknown", de: "Unbekannt", ja: "不明")
        default: return engineUsed.capitalized
        }
    }
}
