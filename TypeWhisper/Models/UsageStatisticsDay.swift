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

    init(
        day: Date,
        transcriptionCount: Int = 0,
        totalWords: Int = 0,
        totalDurationSeconds: Double = 0,
        appBundleIdentifiers: Set<String> = []
    ) {
        self.day = day
        self.transcriptionCount = transcriptionCount
        self.totalWords = totalWords
        self.totalDurationSeconds = totalDurationSeconds
        self.appBundleIdentifiersJSON = Self.encode(appBundleIdentifiers)
    }

    var appBundleIdentifiers: Set<String> {
        get { Self.decode(appBundleIdentifiersJSON) }
        set { appBundleIdentifiersJSON = Self.encode(newValue) }
    }

    func add(wordsCount: Int, durationSeconds: Double, appBundleIdentifier: String?) {
        transcriptionCount += 1
        totalWords += wordsCount
        totalDurationSeconds += durationSeconds

        guard let appBundleIdentifier = appBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !appBundleIdentifier.isEmpty else {
            return
        }
        var identifiers = appBundleIdentifiers
        identifiers.insert(appBundleIdentifier)
        appBundleIdentifiers = identifiers
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
}
