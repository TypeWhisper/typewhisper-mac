import SwiftUI
import AVFoundation
import ApplicationServices

struct HomePage: View {
    @ObservedObject private var statistics = ServiceContainer.shared.usageStatisticsService
    @ObservedObject private var history = ServiceContainer.shared.historyService
    @State private var period = 30
    @State private var hovered: UUID?
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    var body: some View {
        DictumPageFrame(page: .home, actions: {
            if statistics.hasAnyStatistics {
                Picker(selection: $period) {
                    Text("7 days", tableName: "DictumHome").tag(7)
                    Text("30 days", tableName: "DictumHome").tag(30)
                    Text("All", tableName: "DictumHome").tag(0)
                } label: { Text("Period", tableName: "DictumHome") }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            }
        }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if !accessibilityGranted { permission("dictum needs Accessibility access to type into other apps.", pane: "Privacy_Accessibility") }
                    if !microphoneGranted { permission("dictum needs microphone access to dictate.", pane: "Privacy_Microphone") }
                    stats
                    if history.recentRecords.isEmpty { firstRun }
                    activity
                    if !history.recentRecords.isEmpty { recent }
                }.padding(.horizontal, 28).padding(.top, 4).padding(.bottom, 28)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    private var stats: some View {
        let start = period == 0 ? nil : Calendar.current.date(byAdding: .day, value: -(period - 1), to: Date())
        let current = statistics.summary(from: start)
        let previous = statistics.previousPeriodSummary(days: max(period, 1))
        return HStack(spacing: 12) {
            tile("Words dictated", value: current.words.formatted(), unit: "words", current: Double(current.words), previous: Double(previous.words))
            tile("Time saved", value: HomeMetrics.duration(max(0, current.rawSavedMinutes) * 60), duration: max(0, current.rawSavedMinutes) * 60, current: max(0, current.rawSavedMinutes), previous: max(0, previous.rawSavedMinutes))
            tile("Average speed", value: current.durationSeconds > 0 ? current.rawWPM.formatted(.number.precision(.fractionLength(0))) : "—", unit: "WPM", current: current.rawWPM, previous: previous.rawWPM)
            tile("Dictation time", value: HomeMetrics.duration(current.durationSeconds), duration: current.durationSeconds, current: current.durationSeconds, previous: previous.durationSeconds)
        }
    }

    private func tile(_ title: LocalizedStringKey, value: String, unit: LocalizedStringKey? = nil, duration: Double? = nil, current: Double, previous: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title, tableName: "DictumHome").font(.system(size: 12)).foregroundStyle(DictumTheme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                (duration.map(durationValue) ?? numberValue(value)).monospacedDigit().minimumScaleFactor(0.55).lineLimit(1)
                if let unit { Text(unit, tableName: "DictumHome").font(.system(size: 13)).foregroundStyle(DictumTheme.textSecondary) }
            }
            if period != 0 {
                Text(verbatim: HomeMetrics.delta(current, previous)).font(.system(size: 11.5)).foregroundStyle(current > previous ? DictumTheme.success : DictumTheme.textTertiary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14).padding(.horizontal, 16)
            .background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func numberValue(_ value: String) -> Text {
        Text(verbatim: value).font(.system(size: 28, weight: .semibold, design: .rounded))
    }

    private func durationValue(_ seconds: Double) -> Text {
        let minutes = max(0, Int(seconds / 60))
        func unit(_ key: LocalizedStringKey) -> Text {
            Text(verbatim: " ") + Text(key, tableName: "DictumHome").font(.system(size: 13)).foregroundColor(DictumTheme.textSecondary)
        }
        if minutes < 60 { return numberValue(minutes.formatted()) + unit("min") }
        let hours = numberValue((minutes / 60).formatted()) + unit("h")
        if minutes >= 6000 { return hours }
        return hours + Text(verbatim: " ") + numberValue((minutes % 60).formatted()) + unit("min short")
    }

    private var activity: some View {
        let streak = HomeMetrics.streaks(statistics.days)
        return VStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Activity", tableName: "DictumHome").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "flame.fill").font(.system(size: 14)).foregroundStyle(DictumTheme.flame)
                Text(String(localized: "\(streak.current)-day streak", table: "DictumHome")).font(.system(size: 13))
                Text(String(localized: "Longest \(streak.longest) days", table: "DictumHome")).font(.system(size: 11)).foregroundStyle(DictumTheme.textTertiary)
            }
            HomeHeatmap(days: statistics.days).padding(.top, 16).padding(.horizontal, 18).padding(.bottom, 14).background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var firstRun: some View {
        HStack(spacing: 28) {
            Text(verbatim: "fn")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 56, height: 48)
                .background(DictumTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DictumTheme.separatorStrong, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 4) {
                Text("Press fn and say your first sentence", tableName: "DictumHome").font(.system(size: 17, weight: .semibold))
                Text("Works in any text field. Press fn again when you're done and the text appears at the cursor.", tableName: "DictumHome").font(.system(size: 13)).foregroundStyle(DictumTheme.textSecondary)
            }
            Spacer(minLength: 0)
            Button { UserDefaults.standard.set(true, forKey: "dictumPracticeRequested"); ManagedAppWindowOpener.shared.open(id: "setup") } label: { Text("Try it", tableName: "DictumHome") }
        }.padding(.vertical, 28).padding(.horizontal, 30)
            .background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent", tableName: "DictumHome").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { DictumNavigation.shared.open(.history) } label: { Text("All history", tableName: "DictumHome") }.buttonStyle(.plain).foregroundStyle(DictumTheme.accent)
            }
            VStack(spacing: 0) {
                ForEach(Array(history.recentRecords.prefix(5))) { record in
                    HStack(spacing: 12) {
                        if let bundle = record.appBundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                        } else { Image(systemName: "app").frame(width: 20, height: 20).foregroundStyle(.secondary) }
                        if record.mode == .translation {
                            Badge(text: "translation.badge", tint: DictumTheme.translate, tableName: "DictumTranslation")
                        }
                        Button {
                            HistoryViewModel.shared.requestOpenRecord(withID: record.id)
                            DictumNavigation.shared.open(.history)
                        } label: { Text(verbatim: record.finalText).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                        if hovered == record.id {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(record.finalText, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).accessibilityLabel(Text("Copy", tableName: "DictumHome"))
                        } else {
                            Text(verbatim: HomeMetrics.recentDate(record.timestamp))
                                .font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(DictumTheme.textTertiary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }.padding(.horizontal, 12).frame(height: 44)
                        .background(hovered == record.id ? DictumTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .onHover { hovered = $0 ? record.id : nil }
                }
            }.padding(4).background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func permission(_ key: LocalizedStringKey, pane: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DictumTheme.warning)
            Text(key, tableName: "DictumHome")
            Spacer()
            Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!) } label: { Text("Open System Settings", tableName: "DictumHome") }
        }.font(.system(size: 12)).padding(12).background(DictumTheme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }
}
