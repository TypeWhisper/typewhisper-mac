import Combine
import Foundation
import SwiftData
import os.log

private let usageStatisticsLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "UsageStatisticsService"
)

@MainActor
protocol UsageStatisticsRecording: AnyObject {
    func recordTranscription(
        timestamp: Date,
        wordsCount: Int,
        durationSeconds: Double,
        appBundleIdentifier: String?,
        appName: String?,
        engineUsed: String?,
        modelUsed: String?
    )
}

struct UsageStatisticsDaySnapshot: Equatable {
    let day: Date
    let transcriptionCount: Int
    let totalWords: Int
    let totalDurationSeconds: Double
    let appBundleIdentifiers: Set<String>
    /// Per-app transcription counts keyed by `UsageStatisticsKeys.appKey`. Persisted so Top Apps
    /// stays consistent with the streak/active-days data even when history retention purges or
    /// disables the underlying `TranscriptionRecord`s.
    let appCounts: [String: Int]
    /// Per-model transcription counts keyed by `UsageStatisticsKeys.modelKey`.
    let modelCounts: [String: Int]
    /// Per-hour-of-day transcription counts (index 0...23). Combined with `day`'s weekday this
    /// reconstructs the hourly heatmap without depending on history records.
    let hourCounts: [Int]

    init(
        day: Date,
        transcriptionCount: Int,
        totalWords: Int,
        totalDurationSeconds: Double,
        appBundleIdentifiers: Set<String>,
        appCounts: [String: Int] = [:],
        modelCounts: [String: Int] = [:],
        hourCounts: [Int] = Array(repeating: 0, count: 24)
    ) {
        self.day = day
        self.transcriptionCount = transcriptionCount
        self.totalWords = totalWords
        self.totalDurationSeconds = totalDurationSeconds
        self.appBundleIdentifiers = appBundleIdentifiers
        self.appCounts = appCounts
        self.modelCounts = modelCounts
        self.hourCounts = hourCounts
    }
}

struct UsageStatisticsSummary: Equatable {
    let transcriptionCount: Int
    let words: Int
    let durationSeconds: Double
    let appBundleIdentifiers: Set<String>

    static let empty = UsageStatisticsSummary(
        transcriptionCount: 0,
        words: 0,
        durationSeconds: 0,
        appBundleIdentifiers: []
    )

    var rawWPM: Double {
        let minutes = durationSeconds / 60.0
        guard minutes > 0, words > 0 else { return 0 }
        return Double(words) / minutes
    }

    var rawSavedMinutes: Double {
        Double(words) / 45.0 - (durationSeconds / 60.0)
    }

    var appCount: Int { appBundleIdentifiers.count }
}

@MainActor
final class UsageStatisticsService: ObservableObject, UsageStatisticsRecording {
    @Published private(set) var days: [UsageStatisticsDaySnapshot] = []

    private static let historyBackfillCompletedKey = "historyBackfillCompleted"

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private var calendar: Calendar

    init(
        appSupportDirectory: URL = AppConstants.appSupportDirectory,
        calendar: Calendar = .current
    ) {
        self.calendar = calendar

        do {
            let (container, context) = try SwiftDataStoreFactory.create(
                for: [UsageStatisticsDay.self, UsageStatisticsMetadata.self],
                storeName: "usage-statistics",
                in: appSupportDirectory
            )
            modelContainer = container
            modelContext = context
        } catch {
            fatalError("Failed to initialize usage statistics store: \(error)")
        }

        fetchDays()
    }

    var hasAnyStatistics: Bool {
        days.contains { $0.transcriptionCount > 0 || $0.totalWords > 0 || $0.totalDurationSeconds > 0 }
    }

    func recordTranscription(
        timestamp: Date = Date(),
        wordsCount: Int,
        durationSeconds: Double,
        appBundleIdentifier: String?,
        appName: String? = nil,
        engineUsed: String? = nil,
        modelUsed: String? = nil
    ) {
        guard wordsCount > 0 else {
            usageStatisticsLogger.warning("Skipping usage statistics entry: empty word count")
            return
        }
        guard durationSeconds.isFinite, durationSeconds >= 0 else {
            usageStatisticsLogger.warning("Skipping usage statistics entry: invalid duration \(durationSeconds)")
            return
        }

        do {
            try upsertDay(
                timestamp: timestamp,
                wordsCount: wordsCount,
                durationSeconds: durationSeconds,
                appBundleIdentifier: appBundleIdentifier,
                appName: appName,
                engineUsed: engineUsed,
                modelUsed: modelUsed
            )
            save()
            fetchDays()
        } catch {
            usageStatisticsLogger.error("Failed to record usage statistics: \(error.localizedDescription)")
        }
    }

    func backfillFromHistoryIfNeeded(_ records: [TranscriptionRecord]) {
        guard !historyBackfillCompleted else { return }

        do {
            for record in records {
                let wordsCount = record.wordsCount > 0
                    ? record.wordsCount
                    : record.finalText.split(separator: " ").count
                guard wordsCount > 0,
                      record.durationSeconds.isFinite,
                      record.durationSeconds >= 0 else {
                    continue
                }
                try upsertDay(
                    timestamp: record.timestamp,
                    wordsCount: wordsCount,
                    durationSeconds: record.durationSeconds,
                    appBundleIdentifier: record.appBundleIdentifier,
                    appName: record.appName,
                    engineUsed: record.engineUsed,
                    modelUsed: record.modelUsed
                )
            }
            try setHistoryBackfillCompleted(true)
            save()
            fetchDays()
        } catch {
            usageStatisticsLogger.error("Failed to backfill usage statistics: \(error.localizedDescription)")
        }
    }

    func summary(from start: Date?, to end: Date = Date()) -> UsageStatisticsSummary {
        let startDay = start.map { calendar.startOfDay(for: $0) }
        let endDay = calendar.startOfDay(for: end)

        return summarize(days.filter { snapshot in
            if let startDay, snapshot.day < startDay { return false }
            return snapshot.day <= endDay
        })
    }

    func summary(startDay: Date, endDayExclusive: Date) -> UsageStatisticsSummary {
        let normalizedStart = calendar.startOfDay(for: startDay)
        return summarize(days.filter { $0.day >= normalizedStart && $0.day < endDayExclusive })
    }

    func dailyWordCounts(days count: Int?, endingAt now: Date = Date()) -> [UsageStatisticsDaySnapshot] {
        let today = calendar.startOfDay(for: now)
        let requestedDays: Int
        if let count {
            requestedDays = max(count, 1)
        } else if let oldest = days.map(\.day).min() {
            requestedDays = max(1, (calendar.dateComponents([.day], from: oldest, to: today).day ?? 0) + 1)
        } else {
            requestedDays = 30
        }

        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
        return (0..<requestedDays).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return byDay[day] ?? UsageStatisticsDaySnapshot(
                day: day,
                transcriptionCount: 0,
                totalWords: 0,
                totalDurationSeconds: 0,
                appBundleIdentifiers: []
            )
        }
    }

    func previousPeriodSummary(days count: Int, endingAt now: Date = Date()) -> UsageStatisticsSummary {
        let today = calendar.startOfDay(for: now)
        guard let currentStart = calendar.date(byAdding: .day, value: -(max(count, 1) - 1), to: today),
              let previousStart = calendar.date(byAdding: .day, value: -max(count, 1), to: currentStart) else {
            return .empty
        }
        return summary(startDay: previousStart, endDayExclusive: currentStart)
    }

    func clearUsageStatistics() {
        do {
            for day in try modelContext.fetch(FetchDescriptor<UsageStatisticsDay>()) {
                modelContext.delete(day)
            }
            try setHistoryBackfillCompleted(true)
            save()
            fetchDays()
        } catch {
            usageStatisticsLogger.error("Failed to clear usage statistics: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    func replaceWithHistoryRecords(_ records: [TranscriptionRecord]) {
        do {
            for day in try modelContext.fetch(FetchDescriptor<UsageStatisticsDay>()) {
                modelContext.delete(day)
            }
            try setHistoryBackfillCompleted(false)
            save()
            fetchDays()
            backfillFromHistoryIfNeeded(records)
        } catch {
            usageStatisticsLogger.error("Failed to rebuild usage statistics: \(error.localizedDescription)")
        }
    }
    #endif

    private var historyBackfillCompleted: Bool {
        do {
            return try metadataValue(for: Self.historyBackfillCompletedKey) == "true"
        } catch {
            usageStatisticsLogger.error("Failed to read usage statistics metadata: \(error.localizedDescription)")
            return true
        }
    }

    private func upsertDay(
        timestamp: Date,
        wordsCount: Int,
        durationSeconds: Double,
        appBundleIdentifier: String?,
        appName: String? = nil,
        engineUsed: String? = nil,
        modelUsed: String? = nil
    ) throws {
        let dayStart = calendar.startOfDay(for: timestamp)
        let statisticsDay: UsageStatisticsDay
        if let existingDay = try findDay(dayStart) {
            statisticsDay = existingDay
        } else {
            let day = UsageStatisticsDay(day: dayStart)
            modelContext.insert(day)
            statisticsDay = day
        }
        statisticsDay.add(
            wordsCount: wordsCount,
            durationSeconds: durationSeconds,
            appBundleIdentifier: appBundleIdentifier,
            appName: appName,
            engineUsed: engineUsed,
            modelUsed: modelUsed,
            hour: calendar.component(.hour, from: timestamp)
        )
    }

    private func summarize(_ snapshots: [UsageStatisticsDaySnapshot]) -> UsageStatisticsSummary {
        snapshots.reduce(.empty) { partial, snapshot in
            UsageStatisticsSummary(
                transcriptionCount: partial.transcriptionCount + snapshot.transcriptionCount,
                words: partial.words + snapshot.totalWords,
                durationSeconds: partial.durationSeconds + snapshot.totalDurationSeconds,
                appBundleIdentifiers: partial.appBundleIdentifiers.union(snapshot.appBundleIdentifiers)
            )
        }
    }

    private func findDay(_ day: Date) throws -> UsageStatisticsDay? {
        let descriptor = FetchDescriptor<UsageStatisticsDay>()
        let existing = try modelContext.fetch(descriptor)
        return existing.first { $0.day == day }
    }

    private func fetchDays() {
        let descriptor = FetchDescriptor<UsageStatisticsDay>(
            sortBy: [SortDescriptor(\.day, order: .reverse)]
        )
        do {
            days = try modelContext.fetch(descriptor).map {
                UsageStatisticsDaySnapshot(
                    day: $0.day,
                    transcriptionCount: $0.transcriptionCount,
                    totalWords: $0.totalWords,
                    totalDurationSeconds: $0.totalDurationSeconds,
                    appBundleIdentifiers: $0.appBundleIdentifiers,
                    appCounts: $0.appCounts,
                    modelCounts: $0.modelCounts,
                    hourCounts: $0.hourCounts
                )
            }
        } catch {
            usageStatisticsLogger.error("Failed to fetch usage statistics days: \(error.localizedDescription)")
            days = []
        }
    }

    private func metadataValue(for key: String) throws -> String? {
        let metadata = try modelContext.fetch(FetchDescriptor<UsageStatisticsMetadata>())
        return metadata.first { $0.key == key }?.value
    }

    private func setHistoryBackfillCompleted(_ completed: Bool) throws {
        let value = completed ? "true" : "false"
        if let existing = try modelContext.fetch(FetchDescriptor<UsageStatisticsMetadata>())
            .first(where: { $0.key == Self.historyBackfillCompletedKey }) {
            existing.value = value
        } else {
            modelContext.insert(UsageStatisticsMetadata(key: Self.historyBackfillCompletedKey, value: value))
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            usageStatisticsLogger.error("Save failed: \(error.localizedDescription)")
        }
    }
}
