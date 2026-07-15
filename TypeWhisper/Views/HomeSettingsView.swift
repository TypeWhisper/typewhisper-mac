import AppKit
import SwiftUI

struct HomeSettingsView: View {
    @ObservedObject private var viewModel = HomeViewModel.shared
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var license = LicenseService.shared
    @ObservedObject private var statistics = StatisticsViewModel.shared
    @AppStorage(UserDefaultsKeys.workUsagePromptDismissed) private var workUsagePromptDismissed = false

    var body: some View {
        dashboardView
    }

    private var dashboardView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Row 0: Permissions banner (outside scroll)
            if dictation.needsMicPermission || dictation.needsAccessibilityPermission {
                permissionsBanner
                    .padding(.horizontal)
                    .padding(.top)
            }

            // Header (outside scroll, always visible)
            HStack {
                Text(String(localized: "Dashboard"))
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if license.shouldShowWorkUsagePrompt && !workUsagePromptDismissed {
                        workUsageCard
                    }

                    // Row 1: Getting Started or Statistics summary
                    if viewModel.hasAnyTranscriptions {
                        statisticsSummarySection
                    } else {
                        gettingStartedCard
                    }

                    // Row 2: Recent transcriptions
                    recentTranscriptionsSection

                    #if DEBUG
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Seed Demo Data") {
                            let historyService = ServiceContainer.shared.historyService
                            historyService.seedDemoData()
                            ServiceContainer.shared.usageStatisticsService.replaceWithHistoryRecords(historyService.records)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                        .font(.caption)
                        Button("Clear All Data") {
                            let historyService = ServiceContainer.shared.historyService
                            historyService.clearAll()
                            ServiceContainer.shared.usageStatisticsService.clearUsageStatistics()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Statistics summary

    private var statisticsSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                viewModel.navigateToStatistics = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                    Text(String(localized: "Your Activity"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(String(localized: "View all statistics"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "View your statistics"))
            .accessibilityAddTraits(.isButton)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                statisticsSummaryCard(
                    title: String(localized: "Words"),
                    value: "\(statistics.wordsCount)",
                    systemImage: "text.word.spacing"
                )
                statisticsSummaryCard(
                    title: String(localized: "Avg. WPM"),
                    value: statistics.averageWPM,
                    systemImage: "speedometer"
                )
                statisticsSummaryCard(
                    title: String(localized: "Apps Used"),
                    value: "\(statistics.appsUsed)",
                    systemImage: "app.badge"
                )
                statisticsSummaryCard(
                    title: String(localized: "Time Saved"),
                    value: statistics.timeSaved,
                    systemImage: "clock.badge.checkmark"
                )
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statisticsSummaryCard(title: String, value: String, systemImage: String) -> some View {
        Button {
            viewModel.navigateToStatistics = true
        } label: {
            StatisticsMetricCard(title: title, value: value, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), \(value)"))
        .accessibilityAddTraits(.isButton)
    }

    private var workUsageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizedAppText("Need commercial license terms?", de: "Brauchst du kommerzielle Lizenzbedingungen?"))
                        .font(.headline)
                    Text(localizedAppText(
                        "Pricing, lifetime options, procurement, and support are clearer on the website.",
                        de: "Preise, Lifetime-Optionen, Beschaffung und Support sind auf der Website klarer erklärt."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    workUsagePromptDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(AppConstants.Website.pricingURL)
                } label: {
                    Label(localizedAppText("See licensing on the website", de: "Lizenzierung auf der Website ansehen"), systemImage: "globe")
                }
                .buttonStyle(.borderedProminent)

                Button(localizedAppText("Not now", de: "Später")) {
                    workUsagePromptDismissed = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Recent Transcriptions

    private var recentTranscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                viewModel.navigateToHistory = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                    Text(String(localized: "Recent Transcriptions"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(String(localized: "View all history"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "View all history"))
            .accessibilityAddTraits(.isButton)

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
                                    Text(record.finalText)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
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
        if !DictationSettingsHandler.loadHotkeys(for: .hybrid).isEmpty {
            return dictation.hybridHotkeyLabel
        }
        if !DictationSettingsHandler.loadHotkeys(for: .pushToTalk).isEmpty {
            return dictation.pttHotkeyLabel
        }
        if !DictationSettingsHandler.loadHotkeys(for: .toggle).isEmpty {
            return dictation.toggleHotkeyLabel
        }
        return dictation.hybridHotkeyLabel
    }

    private var gettingStartedCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
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
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
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
