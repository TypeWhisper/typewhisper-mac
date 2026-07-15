import AppKit
import SwiftUI

struct StatisticsView: View {
    @ObservedObject private var viewModel = StatisticsViewModel.shared

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
        return Text(period.displayName)
            .font(.caption)
            .fontWeight(isSelected ? .semibold : .regular)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : Color.clear)
            .foregroundStyle(isSelected ? .white : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.selectedTimePeriod = period
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(period.displayName)
            .accessibilityValue(isSelected ? String(localized: "Selected") : "")
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
