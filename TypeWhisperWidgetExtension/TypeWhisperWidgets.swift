import WidgetKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.schneidervvv.dictum.widgets", category: "Timeline")

struct TypeWhisperEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

struct TypeWhisperTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TypeWhisperEntry {
        TypeWhisperEntry(date: .now, data: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (TypeWhisperEntry) -> Void) {
        let data = loadWithLogging()
        completion(TypeWhisperEntry(date: .now, data: data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TypeWhisperEntry>) -> Void) {
        let data = loadWithLogging()
        let entry = TypeWhisperEntry(date: .now, data: data)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadWithLogging() -> WidgetData {
        let data = WidgetData.load()
        logger.info("Loaded: wordsToday=\(data.stats.wordsToday) history=\(data.recentHistory.count)")
        return data
    }
}

struct StatsWidget: Widget {
    let kind = "StatsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TypeWhisperTimelineProvider()) { entry in
            StatsWidgetView(data: entry.data.stats)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Dictation Stats")
        .description("Words dictated today and time saved.")
        .supportedFamilies([.systemSmall])
    }
}

struct LastTranscriptionWidget: Widget {
    let kind = "LastTranscriptionWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TypeWhisperTimelineProvider()) { entry in
            LastTranscriptionWidgetView(item: entry.data.recentHistory.first)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Last Transcription")
        .description("Preview of your latest dictation.")
        .supportedFamilies([.systemSmall])
    }
}

struct ActivityWidget: Widget {
    let kind = "ActivityWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TypeWhisperTimelineProvider()) { entry in
            ChartWidgetView(chartPoints: entry.data.chartPoints, stats: entry.data.stats)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Activity")
        .description("7-day dictation activity chart.")
        .supportedFamilies([.systemMedium])
    }
}

struct HistoryWidget: Widget {
    let kind = "HistoryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TypeWhisperTimelineProvider()) { entry in
            HistoryWidgetView(data: entry.data)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("History")
        .description("Recent transcriptions and stats.")
        .supportedFamilies([.systemLarge])
    }
}

@main
struct TypeWhisperWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatsWidget()
        LastTranscriptionWidget()
        ActivityWidget()
        HistoryWidget()
    }
}
