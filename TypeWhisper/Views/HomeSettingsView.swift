import AppKit
import SwiftUI

struct HomeSettingsView: View {
    @ObservedObject private var viewModel = HomeViewModel.shared
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var statistics = StatisticsViewModel.shared
    @State private var copiedRecordID: UUID?
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        dashboardView
            .onDisappear {
                copyFeedbackTask?.cancel()
                copiedRecordID = nil
            }
    }

    private var dashboardView: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(String(localized: "Dashboard"))
            Divider()

            if needsPermissions {
                permissionsBanner
                    .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
                    .padding(.top, SettingsLayoutMetrics.sectionSpacing)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
                    // Row 1: Getting Started or Statistics summary
                    if viewModel.hasAnyTranscriptions {
                        statisticsSummarySection
                    } else {
                        gettingStartedCard
                    }

                    // Row 2: Recent transcriptions
                    recentTranscriptionsSection

                    #if DEBUG
                    if !AppConstants.isScreenshotAutomation {
                        HStack(spacing: 8) {
                            Spacer()
                            Button("Seed Demo Data") {
                                let historyService = ServiceContainer.shared.historyService
                                historyService.seedDemoData()
                                ServiceContainer.shared.usageStatisticsService.replaceWithHistoryRecords(historyService.allRecords())
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
                    }
                    #endif
                }
                .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
                .padding(.vertical, SettingsLayoutMetrics.sectionSpacing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Statistics summary

    private var statisticsSummarySection: some View {
        SettingsCard {
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
                .accessibilityElement(children: .combine)
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
                        systemImage: "clock.badge.checkmark",
                        accessibilityValue: StatisticsViewModel.spokenTimeSaved(
                            minutes: statistics.timeSavedMinutes,
                            locale: HistoryAccessibilityText.locale
                        )
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Your Activity"))
    }

    private func statisticsSummaryCard(
        title: String,
        value: String,
        systemImage: String,
        accessibilityValue: String? = nil
    ) -> some View {
        Button {
            viewModel.navigateToStatistics = true
        } label: {
            StatisticsMetricCard(title: title, value: value, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        // "—" while there is no data is read as "No data", as on the Statistics page.
        .accessibilityLabel(Text("\(title), \(accessibilityValue ?? statisticsSpokenValue(value))"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Recent Transcriptions

    private var recentTranscriptionsSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    ManagedAppWindowOpener.shared.open(id: "history")
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
                .accessibilityElement(children: .combine)
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
                                openInHistory(record)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.displayText)
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
                                    if copiedRecordID == record.id {
                                        Label(String(localized: "Copied to clipboard"), systemImage: "checkmark")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(recentTranscriptionAccessibilityLabel(record))
                            .accessibilityHint(localizedAppText(
                                "Opens this transcription in History.",
                                de: "Öffnet diese Transkription im Verlauf.",
                                ja: "この文字起こしを履歴で開きます。",
                                zh: "在历史记录中打开此转录。"
                            ))
                            // The context menu is hard to reach with VoiceOver;
                            // offer its copy command as an action as well.
                            .accessibilityAction(named: Text(String(localized: "Copy"))) {
                                copyTranscription(record)
                            }
                            .contextMenu {
                                Button {
                                    copyTranscription(record)
                                } label: {
                                    Label(String(localized: "Copy"), systemImage: "doc.on.doc")
                                }
                                Button {
                                    openInHistory(record)
                                } label: {
                                    Label(String(localized: "Open in History"), systemImage: "clock.arrow.circlepath")
                                }
                            }

                            if record.id != viewModel.recentTranscriptions.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Recent Transcriptions"))
    }

    /// Full text, time and app, without the visual "- App" dash and chevron.
    private func recentTranscriptionAccessibilityLabel(_ record: TranscriptionRecord) -> String {
        // The relative time is spoken in the app language, like the History rows.
        var parts = [
            record.displayText,
            record.timestamp.formatted(.relative(presentation: .named).locale(HistoryAccessibilityText.locale))
        ]
        if let appName = record.appName, !appName.isEmpty {
            parts.append(appName)
        }
        if copiedRecordID == record.id {
            parts.append(String(localized: "Copied to clipboard"))
        }
        return parts.joined(separator: ", ")
    }

    private func openInHistory(_ record: TranscriptionRecord) {
        HistoryViewModel.shared.requestOpenRecord(withID: record.id)
        ManagedAppWindowOpener.shared.open(id: "history")
    }

    private func copyTranscription(_ record: TranscriptionRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.displayText, forType: .string)
        copyFeedbackTask?.cancel()
        copiedRecordID = record.id
        ServiceContainer.shared.accessibilityAnnouncementService.announce(String(localized: "Copied to clipboard"))
        copyFeedbackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
                copiedRecordID = nil
            } catch {}
        }
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
        SettingsCard {
            VStack(spacing: 12) {
                Image(systemName: "mic.badge.plus")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                Text(String(localized: "Ready to start dictating?"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                HStack(spacing: 6) {
                    Text(String(localized: "Press"))
                        .foregroundStyle(.secondary)
                    Text(primaryHotkeyLabel)
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.compactCornerRadius)
                                .fill(Color.accentColor.opacity(0.1))
                        )
                    Text(String(localized: "in any app to begin."))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                // Read as one sentence instead of three fragments.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(localizedAppText(
                    "Press \(primaryHotkeyLabel) in any app to begin.",
                    de: "Drücke \(primaryHotkeyLabel) in einer beliebigen App, um zu beginnen.",
                    ja: "任意のアプリで\(primaryHotkeyLabel)を押して開始します。",
                    zh: "在任意应用中按 \(primaryHotkeyLabel) 开始。"
                ))
                .accessibilityAddTraits(.isStaticText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Permissions Banner

    private var needsPermissions: Bool {
        dictation.needsMicPermission || dictation.needsAccessibilityPermission
    }

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
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Microphone access required"))
            }
            if dictation.needsAccessibilityPermission {
                HStack {
                    Label(
                        AccessibilityPermissionPane.accessRequiredText(),
                        systemImage: "lock.shield"
                    )
                    Spacer()
                    Button(String(localized: "Grant Access")) {
                        dictation.requestAccessibilityPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(AccessibilityPermissionPane.accessRequiredText())
            }
        }
        .foregroundStyle(.red)
        .padding(SettingsLayoutMetrics.cardPadding)
        .background(.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
    }
}
