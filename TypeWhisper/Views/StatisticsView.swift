import AppKit
import SwiftUI
import Charts

struct StatisticsView: View {
    @ObservedObject private var viewModel = StatisticsViewModel.shared

    @State private var hoveredDate: Date?
    @State private var hoverLocation: CGPoint = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(localizedAppText("Statistics", de: "Statistiken", ja: "統計"))
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                timePeriodPicker
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.hasAnyData {
                        overviewGrid
                        metricsGrid
                        chartSection
                        HStack(alignment: .top, spacing: 16) {
                            appsSection
                            modelsSection
                        }
                        heatmapSection
                    } else {
                        emptyStateCard
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Time period picker

    private var timePeriodPicker: some View {
        HStack(spacing: 2) {
            periodButton(.week)
            periodButton(.month)
            periodButton(.allTime)
        }
        .padding(2)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func periodButton(_ period: TimePeriod) -> some View {
        let isSelected = viewModel.selectedTimePeriod == period
        return Button {
            viewModel.selectedTimePeriod = period
        } label: {
            Text(period.displayName)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.clear)
                .foregroundStyle(isSelected ? .white : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(period.displayName)
    }

    // MARK: - Overview

    private var overviewGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            StatisticsStatCard(
                title: localizedAppText("Days Active", de: "Aktive Tage", ja: "利用日数"),
                value: "\(viewModel.totalDaysActive)",
                systemImage: "calendar"
            )
            StatisticsStatCard(
                title: localizedAppText("Current Streak", de: "Aktuelle Serie", ja: "現在の連続日数"),
                value: localizedAppText("\(viewModel.currentStreak)d", de: "\(viewModel.currentStreak)T", ja: "\(viewModel.currentStreak)日"),
                systemImage: "flame"
            )
            StatisticsStatCard(
                title: localizedAppText("Longest Streak", de: "Längste Serie", ja: "最長連続日数"),
                value: localizedAppText("\(viewModel.longestStreak)d", de: "\(viewModel.longestStreak)T", ja: "\(viewModel.longestStreak)日"),
                systemImage: "trophy"
            )
            StatisticsStatCard(
                title: localizedAppText("Transcriptions", de: "Transkriptionen", ja: "文字起こし数"),
                value: "\(viewModel.totalTranscriptions)",
                systemImage: "waveform"
            )
        }
    }

    // MARK: - Words / WPM / apps / time-saved metrics

    private var metricsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            StatisticsMetricCard(
                title: String(localized: "Words"),
                value: "\(viewModel.wordsCount)",
                systemImage: "text.word.spacing",
                trend: viewModel.wordsTrend
            )
            StatisticsMetricCard(
                title: String(localized: "Avg. WPM"),
                value: viewModel.averageWPM,
                systemImage: "speedometer",
                trend: viewModel.wpmTrend
            )
            StatisticsMetricCard(
                title: String(localized: "Apps Used"),
                value: "\(viewModel.appsUsed)",
                systemImage: "app.badge",
                trend: viewModel.appsTrend
            )
            StatisticsMetricCard(
                title: String(localized: "Time Saved"),
                value: viewModel.timeSaved,
                systemImage: "clock.badge.checkmark",
                trend: viewModel.timeSavedTrend
            )
        }
    }

    // MARK: - Activity chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Activity"))
                .font(.headline)

            if viewModel.chartData.isEmpty || viewModel.chartData.allSatisfy({ $0.wordCount == 0 }) {
                Text(String(localized: "No activity in this period."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ZStack(alignment: .top) {
                    Chart(viewModel.chartData) { point in
                        BarMark(
                            x: .value(String(localized: "Date"), point.date, unit: .day),
                            y: .value(String(localized: "Words"), point.wordCount)
                        )
                        .foregroundStyle(
                            hoveredDate != nil && Calendar.current.isDate(point.date, inSameDayAs: hoveredDate!)
                                ? Color.blue
                                : Color.blue.opacity(0.7)
                        )
                        .cornerRadius(4)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: chartAxisStride)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { _ in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        hoverLocation = location
                                        if let date: Date = proxy.value(atX: location.x) {
                                            hoveredDate = Calendar.current.startOfDay(for: date)
                                        }
                                    case .ended:
                                        hoveredDate = nil
                                    }
                                }
                        }
                    }
                    .id(viewModel.selectedTimePeriod)
                    .overlay(alignment: .topLeading) {
                        if let hoveredDate, let point = viewModel.chartData.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hoveredDate) }), point.wordCount > 0 {
                            VStack(spacing: 2) {
                                Text("\(point.wordCount) \(String(localized: "words"))")
                                    .font(.caption.bold())
                                    .monospacedDigit()
                                Text(point.date.formatted(.dateTime.month(.abbreviated).day()))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .offset(x: max(0, hoverLocation.x - 30), y: max(0, hoverLocation.y - 50))
                            .allowsHitTesting(false)
                        }
                    }
                }
                .frame(height: 200)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(chartAccessibilitySummary)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var chartAccessibilitySummary: Text {
        let totalWords = viewModel.chartData.reduce(0) { $0 + $1.wordCount }
        guard let peak = viewModel.chartData.max(by: { $0.wordCount < $1.wordCount }), peak.wordCount > 0 else {
            return Text(String(localized: "Activity chart, no words in this period."))
        }
        let peakDay = peak.date.formatted(.dateTime.month(.abbreviated).day())
        return Text(
            "\(String(localized: "Activity chart")), \(totalWords) \(String(localized: "words total")), " +
            "\(String(localized: "peak")) \(peak.wordCount) \(String(localized: "words on")) \(peakDay)."
        )
    }

    private var chartAxisStride: Int {
        switch viewModel.selectedTimePeriod {
        case .week: return 1
        case .month: return 5
        case .allTime: return 7
        }
    }

    // MARK: - Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localizedAppText("Top Apps", de: "Top Apps", ja: "よく使うアプリ"))
                .font(.headline)

            if viewModel.appUsageStats.isEmpty {
                Text(localizedAppText(
                    "No app usage data for this period.",
                    de: "Keine App-Nutzungsdaten für diesen Zeitraum.",
                    ja: "この期間のアプリ利用データはありません。"
                ))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.appUsageStats) { stat in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(stat.displayName)
                                    .font(.callout)
                                Spacer()
                                Text("\(stat.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(.quaternary.opacity(0.5))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.accentColor)
                                        .frame(width: geometry.size.width * CGFloat(stat.percent / 100))
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Heatmap

    private var weekdayLabels: [String] {
        [
            localizedAppText("Mon", de: "Mo", ja: "月"),
            localizedAppText("Tue", de: "Di", ja: "火"),
            localizedAppText("Wed", de: "Mi", ja: "水"),
            localizedAppText("Thu", de: "Do", ja: "木"),
            localizedAppText("Fri", de: "Fr", ja: "金"),
            localizedAppText("Sat", de: "Sa", ja: "土"),
            localizedAppText("Sun", de: "So", ja: "日")
        ]
    }

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localizedAppText("Usage by Time of Day", de: "Nutzung nach Tageszeit", ja: "時間帯別の利用状況"))
                .font(.headline)

            if viewModel.maxHourlyCount == 0 {
                Text(localizedAppText(
                    "No activity for this period.",
                    de: "Keine Aktivität für diesen Zeitraum.",
                    ja: "この期間のアクティビティはありません。"
                ))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                heatmapGrid
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private let heatmapLabelWidth: CGFloat = 28
    private let heatmapCellSpacing: CGFloat = 2
    private let heatmapCellHeight: CGFloat = 16

    private var heatmapGrid: some View {
        GeometryReader { geometry in
            let cellWidth = max(
                8,
                (geometry.size.width - heatmapLabelWidth - heatmapCellSpacing * 24) / 24
            )

            Grid(horizontalSpacing: heatmapCellSpacing, verticalSpacing: heatmapCellSpacing) {
                GridRow {
                    Color.clear.frame(width: heatmapLabelWidth, height: heatmapCellHeight)
                    ForEach(0..<24, id: \.self) { hour in
                        Group {
                            if hour % 6 == 0 {
                                Text("\(hour)")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: cellWidth, height: heatmapCellHeight, alignment: .leading)
                    }
                }
                ForEach(0..<7, id: \.self) { weekday in
                    GridRow {
                        Text(weekdayLabels[weekday])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: heatmapLabelWidth, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let count = viewModel.hourlyActivity[weekday][hour]
                            RoundedRectangle(cornerRadius: 2)
                                .fill(heatmapCellColor(count: count))
                                .frame(width: cellWidth, height: heatmapCellHeight)
                                .help(heatmapCellTooltip(count: count))
                                .accessibilityElement()
                                .accessibilityLabel(
                                    Text("\(weekdayLabels[weekday]), \(hour):00, \(heatmapCellTooltip(count: count))")
                                )
                        }
                    }
                }
            }
        }
        .frame(height: heatmapCellHeight * 8 + heatmapCellSpacing * 7)
    }

    private func heatmapCellColor(count: Int) -> Color {
        guard count > 0, viewModel.maxHourlyCount > 0 else {
            return Color.gray.opacity(0.12)
        }
        let intensity = Double(count) / Double(viewModel.maxHourlyCount)
        return Color.accentColor.opacity(0.15 + intensity * 0.75)
    }

    private func heatmapCellTooltip(count: Int) -> String {
        localizedAppText(
            "\(count) dictations",
            de: "\(count) Diktate",
            ja: "\(count)件の文字起こし"
        )
    }

    // MARK: - Models

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localizedAppText("Models Used", de: "Verwendete Modelle", ja: "使用したモデル"))
                .font(.headline)

            if viewModel.modelUsageStats.isEmpty {
                Text(localizedAppText(
                    "No transcription data for this period.",
                    de: "Keine Transkriptionsdaten für diesen Zeitraum.",
                    ja: "この期間の文字起こしデータはありません。"
                ))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.modelUsageStats) { stat in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(stat.label)
                                    .font(.callout)
                                Spacer()
                                Text("\(stat.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(.quaternary.opacity(0.5))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.blue)
                                        .frame(width: geometry.size.width * CGFloat(stat.percent / 100))
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Empty state

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            Text(localizedAppText(
                "Your statistics will appear here after your first transcription.",
                de: "Deine Statistiken erscheinen hier nach deiner ersten Transkription.",
                ja: "最初の文字起こしの後、ここに統計が表示されます。"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatisticsStatCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(value)
                .font(.title)
                .fontWeight(.bold)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title), \(value)"))
    }
}

private struct StatisticsMetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    var trend: Double?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(value)
                .font(.title)
                .fontWeight(.bold)
                .monospacedDigit()
            if let trend {
                trendLabel(trend)
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title), \(value)"))
    }

    @ViewBuilder
    private func trendLabel(_ percent: Double) -> some View {
        let isPositive = percent >= 0
        let displayPercent = Int(abs(percent))
        HStack(spacing: 2) {
            Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                .font(.caption2)
            Text("\(displayPercent)%")
                .font(.caption2)
                .monospacedDigit()
        }
        .foregroundStyle(isPositive ? .green : .red)
    }
}
