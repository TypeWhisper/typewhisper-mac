import Foundation
import SwiftData

@Model
final class UsageStatisticsDay {
    @Attribute(.unique)
    var day: Date
    var transcriptionCount: Int
    var totalWords: Int
    var totalDurationSeconds: Double
    var appBundleIdentifiersJSON: String?

    /// Per-app transcription counts for this day, keyed by `UsageStatisticsKeys.appKey`.
    /// Persisted alongside the totals above so Top Apps stays retention-independent, just like
    /// the streak/active-days data already did.
    var appCountsJSON: String?
    /// Per-model transcription counts for this day, keyed by `UsageStatisticsKeys.modelKey`.
    var modelCountsJSON: String?
    /// Per-hour-of-day transcription counts for this day (index 0...23, in `day`'s calendar).
    /// Combined with `day`'s weekday, this reconstructs the hourly heatmap without touching
    /// history records.
    var hourCountsJSON: String?

    init(
        day: Date,
        transcriptionCount: Int = 0,
        totalWords: Int = 0,
        totalDurationSeconds: Double = 0,
        appBundleIdentifiers: Set<String> = [],
        appCounts: [String: Int] = [:],
        modelCounts: [String: Int] = [:],
        hourCounts: [Int] = Array(repeating: 0, count: 24)
    ) {
        self.day = day
        self.transcriptionCount = transcriptionCount
        self.totalWords = totalWords
        self.totalDurationSeconds = totalDurationSeconds
        self.appBundleIdentifiersJSON = Self.encode(appBundleIdentifiers)
        self.appCountsJSON = Self.encodeCounts(appCounts)
        self.modelCountsJSON = Self.encodeCounts(modelCounts)
        self.hourCountsJSON = Self.encodeHours(hourCounts)
    }

    var appBundleIdentifiers: Set<String> {
        get { Self.decode(appBundleIdentifiersJSON) }
        set { appBundleIdentifiersJSON = Self.encode(newValue) }
    }

    var appCounts: [String: Int] {
        get { Self.decodeCounts(appCountsJSON) }
        set { appCountsJSON = Self.encodeCounts(newValue) }
    }

    var modelCounts: [String: Int] {
        get { Self.decodeCounts(modelCountsJSON) }
        set { modelCountsJSON = Self.encodeCounts(newValue) }
    }

    var hourCounts: [Int] {
        get { Self.decodeHours(hourCountsJSON) }
        set { hourCountsJSON = Self.encodeHours(newValue) }
    }

    func add(
        wordsCount: Int,
        durationSeconds: Double,
        appBundleIdentifier: String?,
        appName: String? = nil,
        engineUsed: String? = nil,
        modelUsed: String? = nil,
        hour: Int? = nil
    ) {
        transcriptionCount += 1
        totalWords += wordsCount
        totalDurationSeconds += durationSeconds

        let trimmedBundleIdentifier = appBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedBundleIdentifier, !trimmedBundleIdentifier.isEmpty {
            var identifiers = appBundleIdentifiers
            identifiers.insert(trimmedBundleIdentifier)
            appBundleIdentifiers = identifiers
        }

        addDetailCounts(
            appBundleIdentifier: trimmedBundleIdentifier,
            appName: appName,
            engineUsed: engineUsed,
            modelUsed: modelUsed,
            hour: hour
        )
    }

    /// Updates only the per-app, per-model, and per-hour breakdowns, leaving the totals
    /// untouched. Used to backfill these fields for installations whose totals were already
    /// migrated from history before the breakdowns existed, without double-counting totals.
    func addDetailCounts(
        appBundleIdentifier: String?,
        appName: String? = nil,
        engineUsed: String? = nil,
        modelUsed: String? = nil,
        hour: Int? = nil
    ) {
        let appKey = UsageStatisticsKeys.appKey(bundleIdentifier: appBundleIdentifier, appName: appName)
        var apps = appCounts
        apps[appKey, default: 0] += 1
        appCounts = apps

        if let engineUsed = engineUsed?.trimmingCharacters(in: .whitespacesAndNewlines), !engineUsed.isEmpty {
            let modelKey = UsageStatisticsKeys.modelKey(engineUsed: engineUsed, modelUsed: modelUsed)
            var models = modelCounts
            models[modelKey, default: 0] += 1
            modelCounts = models
        }

        if let hour, hour >= 0, hour < 24 {
            var hours = hourCounts
            hours[hour] += 1
            hourCounts = hours
        }
    }

    private static func encode(_ identifiers: Set<String>) -> String? {
        let values = identifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func decode(_ value: String?) -> Set<String> {
        guard let value,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(decoded.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private static func encodeCounts(_ counts: [String: Int]) -> String? {
        guard !counts.isEmpty,
              let data = try? JSONEncoder().encode(counts),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func decodeCounts(_ value: String?) -> [String: Int] {
        guard let value,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func encodeHours(_ hours: [Int]) -> String? {
        guard hours.contains(where: { $0 != 0 }),
              let data = try? JSONEncoder().encode(hours),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func decodeHours(_ value: String?) -> [Int] {
        guard let value,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Int].self, from: data),
              decoded.count == 24 else {
            return Array(repeating: 0, count: 24)
        }
        return decoded
    }
}
