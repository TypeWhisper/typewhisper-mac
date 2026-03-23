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
    private var cancellables = Set<AnyCancellable>()
    private var refreshWorkItem: DispatchWorkItem?

    init(historyService: HistoryService) {
        self.historyService = historyService
        self.showSetupWizard = !UserDefaults.standard.bool(forKey: UserDefaultsKeys.setupWizardCompleted)

        setupBindings()
        refresh()
    }

    private func setupBindings() {
        historyService.$records
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
        hasAnyTranscriptions = !allRecords.isEmpty

        // Filter records for current period
        let filtered: [TranscriptionRecord]
        if let days = selectedTimePeriod.days {
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
            filtered = allRecords.filter { $0.timestamp >= cutoff }
        } else {
            filtered = allRecords
        }

        // Stats for current period
        let stats = computeStats(for: filtered)
        wordsCount = stats.words
        averageWPM = stats.wpm
        appsUsed = stats.apps
        timeSaved = stats.timeSaved

        // Trends (compare with previous period of same length)
        if let days = selectedTimePeriod.days {
            let currentCutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
            let prevCutoff = Calendar.current.date(byAdding: .day, value: -days, to: currentCutoff) ?? currentCutoff
            let prevFiltered = allRecords.filter { $0.timestamp >= prevCutoff && $0.timestamp < currentCutoff }
            let prevStats = computeStats(for: prevFiltered)

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
        chartData = buildChartData(records: filtered)

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

    private func computeStats(for records: [TranscriptionRecord]) -> PeriodStats {
        let words = records.reduce(0) { $0 + $1.wordsCount }
        let totalMinutes = records.reduce(0.0) { $0 + $1.durationSeconds } / 60.0

        let rawWPM: Double
        let wpm: String
        if totalMinutes > 0 && words > 0 {
            rawWPM = Double(words) / totalMinutes
            wpm = "\(Int(rawWPM))"
        } else {
            rawWPM = 0
            wpm = "—"
        }

        let apps = Set(records.compactMap { $0.appBundleIdentifier }).count

        let typingMinutes = Double(words) / 45.0
        let rawSavedMinutes = typingMinutes - totalMinutes
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

    private func buildChartData(records: [TranscriptionRecord]) -> [ActivityDataPoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = selectedTimePeriod.days ?? max(1, {
            guard let oldest = records.last?.timestamp else { return 30 }
            return calendar.dateComponents([.day], from: oldest, to: today).day.map { $0 + 1 } ?? 30
        }())

        var dataByDay: [Date: Int] = [:]
        for i in 0..<days {
            if let date = calendar.date(byAdding: .day, value: -i, to: today) {
                dataByDay[date] = 0
            }
        }

        for record in records {
            let day = calendar.startOfDay(for: record.timestamp)
            dataByDay[day, default: 0] += record.wordsCount
        }

        return dataByDay
            .map { ActivityDataPoint(date: $0.key, wordCount: $0.value) }
            .sorted { $0.date < $1.date }
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
