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

    static func load() -> WidgetData {
        guard let url = sharedFileURL,
              let data = try? Data(contentsOf: url) else {
            return .empty
        }
        return (try? JSONDecoder().decode(WidgetData.self, from: data)) ?? .empty
    }

    func save() {
        guard let url = WidgetData.sharedFileURL,
              let data = try? JSONEncoder().encode(self) else { return }
        // Ensure the group container directory exists
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url)
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
