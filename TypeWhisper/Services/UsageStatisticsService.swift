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
        appBundleIdentifier: String?
    )
}

struct UsageStatisticsDaySnapshot: Equatable {
    let day: Date
    let transcriptionCount: Int
    let totalWords: Int
    let totalDurationSeconds: Double
    let appBundleIdentifiers: Set<String>
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
        appBundleIdentifier: String?
    ) {
        guard wordsCount > 0 else {
            usageStatisticsLogger.warning("Skipping usage statistics entry: empty word count")
            return
        }
        guard durationSeconds.isFinite, durationSeconds >= 0 else {
            usageStatisticsLogger.warning("Skipping usage statistics entry: invalid duration \(durationSeconds)")
            return
        }

        upsertDay(
            timestamp: timestamp,
            wordsCount: wordsCount,
            durationSeconds: durationSeconds,
            appBundleIdentifier: appBundleIdentifier
        )
        save()
        fetchDays()
    }

    func backfillFromHistoryIfNeeded(_ records: [TranscriptionRecord]) {
        guard !historyBackfillCompleted else { return }

        for record in records {
            let wordsCount = record.wordsCount > 0
                ? record.wordsCount
                : record.finalText.split(separator: " ").count
            guard wordsCount > 0,
                  record.durationSeconds.isFinite,
                  record.durationSeconds >= 0 else {
                continue
            }
            upsertDay(
                timestamp: record.timestamp,
                wordsCount: wordsCount,
                durationSeconds: record.durationSeconds,
                appBundleIdentifier: record.appBundleIdentifier
            )
        }
        setHistoryBackfillCompleted(true)
        save()
        fetchDays()
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
            setHistoryBackfillCompleted(true)
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
            setHistoryBackfillCompleted(false)
            save()
            fetchDays()
            backfillFromHistoryIfNeeded(records)
        } catch {
            usageStatisticsLogger.error("Failed to rebuild usage statistics: \(error.localizedDescription)")
        }
    }
    #endif

    private var historyBackfillCompleted: Bool {
        metadataValue(for: Self.historyBackfillCompletedKey) == "true"
    }

    private func upsertDay(
        timestamp: Date,
        wordsCount: Int,
        durationSeconds: Double,
        appBundleIdentifier: String?
    ) {
        let dayStart = calendar.startOfDay(for: timestamp)
        let statisticsDay = findDay(dayStart) ?? {
            let day = UsageStatisticsDay(day: dayStart)
            modelContext.insert(day)
            return day
        }()
        statisticsDay.add(
            wordsCount: wordsCount,
            durationSeconds: durationSeconds,
            appBundleIdentifier: appBundleIdentifier
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

    private func findDay(_ day: Date) -> UsageStatisticsDay? {
        let descriptor = FetchDescriptor<UsageStatisticsDay>()
        guard let existing = try? modelContext.fetch(descriptor) else { return nil }
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
                    appBundleIdentifiers: $0.appBundleIdentifiers
                )
            }
        } catch {
            days = []
        }
    }

    private func metadataValue(for key: String) -> String? {
        guard let metadata = try? modelContext.fetch(FetchDescriptor<UsageStatisticsMetadata>()) else {
            return nil
        }
        return metadata.first { $0.key == key }?.value
    }

    private func setHistoryBackfillCompleted(_ completed: Bool) {
        let value = completed ? "true" : "false"
        if let existing = try? modelContext.fetch(FetchDescriptor<UsageStatisticsMetadata>())
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
