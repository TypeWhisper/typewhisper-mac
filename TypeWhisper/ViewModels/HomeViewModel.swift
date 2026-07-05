import Foundation
import Combine

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

@MainActor
final class HomeViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: HomeViewModel?
    static var shared: HomeViewModel {
        guard let instance = _shared else {
            fatalError("HomeViewModel not initialized")
        }
        return instance
    }

    @Published var selectedTimePeriod: TimePeriod = .week
    @Published var wordsCount: Int = 0
    @Published var averageWPM: String = "—"
    @Published var appsUsed: Int = 0
    @Published var timeSaved: String = "—"
    @Published var chartData: [ActivityDataPoint] = []
    @Published var wordsTrend: Double? = nil
    @Published var wpmTrend: Double? = nil
    @Published var appsTrend: Double? = nil
    @Published var timeSavedTrend: Double? = nil
    @Published var recentTranscriptions: [TranscriptionRecord] = []
    @Published var navigateToHistory = false
    @Published var hasAnyTranscriptions = false
    @Published var showSetupWizard: Bool {
        didSet { UserDefaults.standard.set(!showSetupWizard, forKey: UserDefaultsKeys.setupWizardCompleted) }
    }

    private let historyService: HistoryService
    private let usageStatisticsService: UsageStatisticsService
    private var cancellables = Set<AnyCancellable>()
    private var refreshWorkItem: DispatchWorkItem?

    init(historyService: HistoryService, usageStatisticsService: UsageStatisticsService) {
        self.historyService = historyService
        self.usageStatisticsService = usageStatisticsService
        self.showSetupWizard = !UserDefaults.standard.bool(forKey: UserDefaultsKeys.setupWizardCompleted)

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
        let allRecords = historyService.records
        hasAnyTranscriptions = usageStatisticsService.hasAnyStatistics || !allRecords.isEmpty

        // Stats for current period
        let stats = computeStats(for: currentSummary(now: now))
        wordsCount = stats.words
        averageWPM = stats.wpm
        appsUsed = stats.apps
        timeSaved = stats.timeSaved

        // Trends (compare with previous period of same length)
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

        // Chart data
        chartData = buildChartData(now: now)

        // Recent transcriptions
        recentTranscriptions = Array(allRecords.prefix(3))
    }

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

    func completeSetupWizard() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.setupWizardCurrentStep)
        showSetupWizard = false
    }

    func resetSetupWizard() {
        UserDefaults.standard.set(0, forKey: UserDefaultsKeys.setupWizardCurrentStep)
        showSetupWizard = true
    }
}
