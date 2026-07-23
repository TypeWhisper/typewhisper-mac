import AppKit
import SwiftUI
import Charts

struct StatisticsView: View {
    @ObservedObject private var viewModel = StatisticsViewModel.shared

    @State private var hoveredDate: Date?
    @State private var hoverLocation: CGPoint = .zero
    @State private var animateBars = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(String(localized: "Statistics")) {
                timePeriodPicker
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
                    if viewModel.hasAnyData {
                        overviewGrid
                        metricsGrid
                        chartSection
                        HStack(alignment: .top, spacing: SettingsLayoutMetrics.cardSpacing) {
                            appsSection
                            modelsSection
                        }
                        heatmapSection
                    } else {
                        emptyStateCard
                    }
                }
                .padding(SettingsLayoutMetrics.pagePadding)
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
        .clipShape(RoundedRectangle(cornerRadius: SettingsLayoutMetrics.compactCornerRadius))
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
                .clipShape(RoundedRectangle(cornerRadius: SettingsLayoutMetrics.compactCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(period.displayName)
    }

    // MARK: - Overview

    private var overviewGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            StatisticsStatCard(
                title: String(localized: "Days Active"),
                value: "\(viewModel.totalDaysActive)",
                systemImage: "calendar"
            )
            StatisticsStatCard(
                title: String(localized: "Current Streak"),
                value: String(localized: "\(viewModel.currentStreak)d"),
                systemImage: "flame",
                accessibilityValue: String.localizedStringWithFormat(String(localized: "%lld days"), viewModel.currentStreak)
            )
            StatisticsStatCard(
                title: String(localized: "Longest Streak"),
                value: String(localized: "\(viewModel.longestStreak)d"),
                systemImage: "trophy",
                accessibilityValue: String.localizedStringWithFormat(String(localized: "%lld days"), viewModel.longestStreak)
            )
            StatisticsStatCard(
                title: String(localized: "Transcriptions"),
                value: "\(viewModel.totalTranscriptions)",
                systemImage: "waveform",
                accessibilityValue: String.localizedStringWithFormat(String(localized: "%lld dictations"), viewModel.totalTranscriptions)
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
        SettingsCard {
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
                            y: .value(String(localized: "Words"), animateBars ? point.wordCount : 0)
                        )
                        .foregroundStyle(
                            hoveredDate != nil && Calendar.current.isDate(point.date, inSameDayAs: hoveredDate!)
                                ? Color.accentColor
                                : Color.accentColor.opacity(0.7)
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
                                Text(String.localizedStringWithFormat(String(localized: "%lld words"), point.wordCount))
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
                    // Keep the y-axis fixed so the bars visibly grow from the
                    // baseline instead of the whole chart rescaling.
                    .chartYScale(domain: 0...chartYMax)
                    .onAppear {
                        guard !animateBars else { return }
                        if reduceMotion {
                            animateBars = true
                        } else {
                            withAnimation(.easeOut(duration: 0.6)) { animateBars = true }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(chartAccessibilitySummary)
                }
            }
        }
    }

    /// Fixed upper bound for the activity chart's y-axis (with a little headroom),
    /// so bars animate up into a stable axis rather than rescaling as they grow.
    private var chartYMax: Int {
        // ~15% headroom above the tallest bar so it doesn't sit flush against the
        // top edge, and the axis stays stable while the bars animate up.
        let peak = viewModel.chartData.map(\.wordCount).max() ?? 0
        return max(Int((Double(peak) * 1.15).rounded(.up)), 1)
    }

    private var chartAccessibilitySummary: Text {
        let totalWords = viewModel.chartData.reduce(0) { $0 + $1.wordCount }
        guard let peak = viewModel.chartData.max(by: { $0.wordCount < $1.wordCount }), peak.wordCount > 0 else {
            return Text(String(localized: "Activity chart, no words in this period."))
        }
        let peakDay = peak.date.formatted(.dateTime.month(.abbreviated).day())
        let totalWordsPhrase = String.localizedStringWithFormat(String(localized: "%lld words"), totalWords)
        let peakWordsPhrase = String.localizedStringWithFormat(String(localized: "%lld words"), peak.wordCount)
        return Text(String(localized: "Activity chart, \(totalWordsPhrase) total, peak \(peakWordsPhrase) on \(peakDay)."))
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
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Top Apps"))
                .font(.headline)

            if viewModel.appUsageStats.isEmpty {
                Text(String(localized: "No app usage data for this period."))
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
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            Text("\(stat.displayName), \(String.localizedStringWithFormat(String(localized: "%lld dictations"), stat.count))")
                        )
                    }
                }
            }
            }
        }
    }

    // MARK: - Heatmap

    private var weekdayLabels: [String] {
        [
            String(localized: "Mon"),
            String(localized: "Tue"),
            String(localized: "Wed"),
            String(localized: "Thu"),
            String(localized: "Fri"),
            String(localized: "Sat"),
            String(localized: "Sun")
        ]
    }

    private var heatmapSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Usage by Time of Day"))
                    .font(.headline)

                if viewModel.maxHourlyCount == 0 {
                    Text(String(localized: "No activity for this period."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    heatmapGrid
                }
            }
        }
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
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isStaticText)
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
        String.localizedStringWithFormat(String(localized: "%lld dictations"), count)
    }

    // MARK: - Models

    private var modelsSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Models Used"))
                .font(.headline)

            if viewModel.modelUsageStats.isEmpty {
                Text(String(localized: "No transcription data for this period."))
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
                                        .fill(Color.accentColor)
                                        .frame(width: geometry.size.width * CGFloat(stat.percent / 100))
                                }
                            }
                            .frame(height: 6)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            Text("\(stat.label), \(String.localizedStringWithFormat(String(localized: "%lld dictations"), stat.count))")
                        )
                    }
                }
            }
            }
        }
    }

    // MARK: - Empty state

    private var emptyStateCard: some View {
        SettingsCard {
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(String(localized: "Your statistics will appear here after your first transcription."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

private struct StatisticsStatCard: View {
    let title: String
    let value: String
    let systemImage: String
    /// Overrides `value` for VoiceOver, e.g. spelling out "3 days" instead of the compact "3d" badge text.
    var accessibilityValue: String?

    var body: some View {
        SettingsCard {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                CountUpText(value: value)
                    .font(.title)
                    .fontWeight(.bold)
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title), \(accessibilityValue ?? value)"))
    }
}

struct StatisticsMetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    var trend: Double?

    var body: some View {
        SettingsCard {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                CountUpText(value: value)
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
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(trendAwareAccessibilityLabel)
    }

    private var trendAwareAccessibilityLabel: Text {
        guard let trend else {
            return Text("\(title), \(value)")
        }
        let displayPercent = Int(abs(trend))
        let trendPhrase = trend >= 0
            ? String.localizedStringWithFormat(String(localized: "up %lld percent"), displayPercent)
            : String.localizedStringWithFormat(String(localized: "down %lld percent"), displayPercent)
        return Text("\(title), \(value), \(trendPhrase)")
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

// MARK: - Count-up number

/// Renders a stat value, counting up from zero on appear when the value is a
/// plain whole number (e.g. "42", "1,234"). Values with units or non-numeric
/// characters (e.g. "3d", "12:34", "18 WPM") are shown as-is so nothing is
/// mis-animated. Respects Reduce Motion.
private struct CountUpText: View {
    let value: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    /// The integer to count up to, but only when `value` is a plain whole number
    /// with no grouping separators or units, so the displayed count-up matches the
    /// source string exactly (values like "3d", "12:34", "42.5", "1,234" are left
    /// untouched).
    private var target: Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let intValue = Int(trimmed), "\(intValue)" == trimmed else { return nil }
        return intValue
    }

    var body: some View {
        if let target, !reduceMotion {
            AnimatableNumberText(number: animate ? Double(target) : 0)
                .onAppear { withAnimation(.easeOut(duration: 0.7)) { animate = true } }
        } else {
            Text(value)
        }
    }
}

/// A `Text` whose numeric content animates smoothly via `Animatable`.
private struct AnimatableNumberText: View, Animatable {
    var number: Double

    nonisolated var animatableData: Double {
        get { number }
        set { number = newValue }
    }

    var body: some View {
        // Plain integer string (no grouping) to match the source value formatting.
        Text("\(Int(number.rounded()))")
    }
}
