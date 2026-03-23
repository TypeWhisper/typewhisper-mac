import SwiftUI
import Charts

struct HomeSettingsView: View {
    @ObservedObject private var viewModel = HomeViewModel.shared
    @ObservedObject private var dictation = DictationViewModel.shared

    var body: some View {
        if viewModel.showSetupWizard {
            SetupWizardView()
                .frame(minWidth: 500, minHeight: 400)
        } else {
            dashboardView
        }
    }

    private var dashboardView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Row 0: Permissions banner (outside scroll)
            if dictation.needsMicPermission || dictation.needsAccessibilityPermission {
                permissionsBanner
                    .padding(.horizontal)
                    .padding(.top)
            }

            // Header: Title + picker (outside scroll, always clickable)
            HStack {
                Text(String(localized: "Dashboard"))
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
                    // Row 1: Stats grid or Getting Started
                    if viewModel.hasAnyTranscriptions {
                        statsGrid
                    } else {
                        gettingStartedCard
                    }

                    // Row 2: Activity chart
                    chartSection

                    // Row 3: Recent transcriptions
                    recentTranscriptionsSection

                    // Footer
                    HStack {
                        Spacer()
                        Button {
                            viewModel.resetSetupWizard()
                        } label: {
                            Label(String(localized: "Run setup again"), systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    }

                    #if DEBUG
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Seed Demo Data") {
                            let historyService = ServiceContainer.shared.historyService
                            historyService.seedDemoData()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                        .font(.caption)
                        Button("Clear All Data") {
                            let historyService = ServiceContainer.shared.historyService
                            historyService.clearAll()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.caption)
                    }
                    #endif
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Time Period Picker

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

    // MARK: - Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            StatCard(
                title: String(localized: "Words"),
                value: "\(viewModel.wordsCount)",
                systemImage: "text.word.spacing",
                trend: viewModel.wordsTrend
            )
            StatCard(
                title: String(localized: "Avg. WPM"),
                value: viewModel.averageWPM,
                systemImage: "speedometer",
                trend: viewModel.wpmTrend
            )
            StatCard(
                title: String(localized: "Apps Used"),
                value: "\(viewModel.appsUsed)",
                systemImage: "app.badge",
                trend: viewModel.appsTrend
            )
            StatCard(
                title: String(localized: "Time Saved"),
                value: viewModel.timeSaved,
                systemImage: "clock.badge.checkmark",
                trend: viewModel.timeSavedTrend
            )
        }
    }

    // MARK: - Chart

    @State private var hoveredDate: Date?
    @State private var hoverLocation: CGPoint = .zero

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Activity"))
                .font(.headline)

            if viewModel.chartData.isEmpty || viewModel.chartData.allSatisfy({ $0.wordCount == 0 }) {
                Text(viewModel.hasAnyTranscriptions
                    ? String(localized: "No activity in this period.")
                    : String(localized: "Your activity will appear here after your first transcription."))
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
                                Text("\(point.wordCount)")
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
                .accessibilityHidden(true)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var chartAxisStride: Int {
        switch viewModel.selectedTimePeriod {
        case .week: return 1
        case .month: return 5
        case .allTime: return 7
        }
    }

    // MARK: - Recent Transcriptions

    private var recentTranscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Recent Transcriptions"))
                .font(.headline)

            if viewModel.recentTranscriptions.isEmpty {
                Text(String(localized: "Press \(primaryHotkeyLabel) in any app to get started."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.recentTranscriptions, id: \.id) { record in
                        Button {
                            viewModel.navigateToHistory = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.preview)
                                        .lineLimit(1)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 4) {
                                        Text(record.timestamp, format: .relative(presentation: .named))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let appName = record.appName {
                                            Text("- \(appName)")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if record.id != viewModel.recentTranscriptions.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Getting Started Card

    private var primaryHotkeyLabel: String {
        if UserDefaults.standard.data(forKey: UserDefaultsKeys.hybridHotkey) != nil {
            return dictation.hybridHotkeyLabel
        }
        if UserDefaults.standard.data(forKey: UserDefaultsKeys.pttHotkey) != nil {
            return dictation.pttHotkeyLabel
        }
        if UserDefaults.standard.data(forKey: UserDefaultsKeys.toggleHotkey) != nil {
            return dictation.toggleHotkeyLabel
        }
        return dictation.hybridHotkeyLabel
    }

    private var gettingStartedCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            Text(String(localized: "Ready to start dictating?"))
                .font(.headline)

            HStack(spacing: 6) {
                Text(String(localized: "Press"))
                    .foregroundStyle(.secondary)
                Text(primaryHotkeyLabel)
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.blue.opacity(0.1)))
                Text(String(localized: "in any app to begin."))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Permissions Banner

    private var permissionsBanner: some View {
        VStack(spacing: 8) {
            if dictation.needsMicPermission {
                HStack {
                    Label(
                        String(localized: "Microphone access required"),
                        systemImage: "mic.slash"
                    )
                    Spacer()
                    Button(String(localized: "Grant Access")) {
                        dictation.requestMicPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if dictation.needsAccessibilityPermission {
                HStack {
                    Label(
                        String(localized: "Accessibility access required"),
                        systemImage: "lock.shield"
                    )
                    Spacer()
                    Button(String(localized: "Grant Access")) {
                        dictation.requestAccessibilityPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .foregroundStyle(.red)
        .padding()
        .background(.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String
    var trend: Double? = nil

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
