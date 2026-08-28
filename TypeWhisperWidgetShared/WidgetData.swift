import Foundation

struct WidgetData: Codable {
    var stats: WidgetStatsData
    var chartPoints: [WidgetChartPoint]
    var recentHistory: [WidgetHistoryItem]
    var lastUpdated: Date

    static let groupIdentifier = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String ?? "2D8ALY3LCL.com.typewhisper.mac"
    static let fileName = "widgetData.json"

    static var empty: WidgetData {
        WidgetData(
            stats: .empty,
            chartPoints: [],
            recentHistory: [],
            lastUpdated: Date()
        )
    }

    private static var sharedFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appendingPathComponent(fileName)
    }

    // Serial so overlapping saves are written in submission order.
    private static let saveQueue = DispatchQueue(label: "com.typewhisper.widgetdata.save", qos: .utility)

    static func load() -> WidgetData {
        guard let url = sharedFileURL,
              let data = try? Data(contentsOf: url) else {
            return .empty
        }
        return (try? JSONDecoder().decode(WidgetData.self, from: data)) ?? .empty
    }

    /// Persists the widget payload to the App Group container off the caller's thread.
    /// - Parameter onWritten: Called on the write queue after the file has been written.
    ///   It is not called when encoding, resolving the container, or writing fails.
    func save(onWritten: (@Sendable () -> Void)? = nil) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        // App Group container access (containerURL and the write itself) can stall on a
        // broken code signature or slow disk, so resolve the URL and write here rather
        // than on the caller's thread — it must never block the main thread that
        // triggers widget refreshes.
        WidgetData.saveQueue.async {
            guard let url = WidgetData.sharedFileURL else { return }
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                // Atomic: the widget extension reads this file from another process,
                // so it must never observe a partially written payload.
                try data.write(to: url, options: .atomic)
            } catch {
                return
            }
            onWritten?()
        }
    }
}

struct WidgetStatsData: Codable {
    var wordsToday: Int
    var timeSavedToday: String
    var wordsThisWeek: Int
    var averageWPM: String
    var appsUsed: Int

    static var empty: WidgetStatsData {
        WidgetStatsData(
            wordsToday: 0,
            timeSavedToday: "-",
            wordsThisWeek: 0,
            averageWPM: "-",
            appsUsed: 0
        )
    }
}

struct WidgetHistoryItem: Codable, Identifiable {
    var id: UUID
    var timestamp: Date
    var preview: String
    var appName: String?
    var bundleId: String?
    var wordsCount: Int
}

struct WidgetChartPoint: Codable, Identifiable {
    var id: String { dateLabel }
    var dateLabel: String
    var date: Date
    var wordCount: Int
}
