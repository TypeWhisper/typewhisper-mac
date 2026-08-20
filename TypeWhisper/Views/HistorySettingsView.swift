import SwiftUI

struct HistorySettingsView: View {
    @AppStorage(UserDefaultsKeys.historyEnabled) private var historyEnabled = true
    @AppStorage(UserDefaultsKeys.historyRetentionDays) private var historyRetentionDays = 0
    @AppStorage(UserDefaultsKeys.saveAudioWithHistory) private var saveAudioWithHistory = false
    @ObservedObject private var syncController = ServiceContainer.shared.cloudFolderSyncController
    @State private var confirmingHistorySync = false
    @State private var confirmingClearHistory = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "History & Sync"))
            Divider()

            Form {
                Section(String(localized: "History Workspace")) {
                    LabeledContent {
                        Button {
                            ManagedAppWindowOpener.shared.open(id: "history")
                        } label: {
                            Label(String(localized: "Open History"), systemImage: "rectangle.split.3x1")
                        }
                        .buttonStyle(.borderedProminent)
                    } label: {
                        Text(String(localized: "Search, review, edit, export, and complete Inbox entries in a dedicated window."))
                    }
                }

                Section(String(localized: "Local History")) {
                    Toggle(String(localized: "Save history"), isOn: $historyEnabled)
                    if historyEnabled {
                        Toggle(String(localized: "Save audio with transcriptions"), isOn: $saveAudioWithHistory)
                        Picker(String(localized: "Auto-delete after"), selection: $historyRetentionDays) {
                            Text(String(localized: "Unlimited")).tag(0)
                            Text(String(localized: "30 days")).tag(30)
                            Text(String(localized: "60 days")).tag(60)
                            Text(String(localized: "90 days")).tag(90)
                            Text(String(localized: "180 days")).tag(180)
                        }
                    }
                }

                Section(String(localized: "Premium Sync")) {
                    Toggle(String(localized: "Sync History & Inbox"), isOn: historySyncBinding)
                        .disabled(syncController.mode == .off || syncController.isSyncing)

                    if syncController.historySyncPreferences?.isEnabled == true {
                        Toggle(String(localized: "Sync Audio for New Entries"), isOn: historyAudioBinding)
                        Text(String(localized: "History sync is optional on each device. Audio sync applies to new entries and downloads automatically on enabled devices."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "Enable Premium Sync first, then choose whether this Mac participates in History and Inbox sync."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(String(localized: "Restore & Delete")) {
                    Button(String(localized: "Restore Automatically Removed History")) {
                        syncController.historySyncPreferences?.restoreSuppressedHistory()
                        Task { await syncController.syncNow() }
                    }
                    Button(String(localized: "Delete History"), role: .destructive) {
                        confirmingClearHistory = true
                    }
                    Text(String(localized: "Restoring re-imports synchronized entries removed only by local retention. Deleting history while sync is enabled removes it from all synchronized devices."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .confirmationDialog(
            String(localized: "Sync History & Inbox?"),
            isPresented: $confirmingHistorySync,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Enable Sync")) {
                Task { await syncController.setHistorySyncEnabled(true) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Your saved text and Inbox state will be added to your private sync folder and become available on your other enabled TypeWhisper devices."))
        }
        .confirmationDialog(
            String(localized: "Delete All History?"),
            isPresented: $confirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                ServiceContainer.shared.historyService.clearAll()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(clearHistoryMessage)
        }
    }

    private var historySyncBinding: Binding<Bool> {
        Binding(
            get: { syncController.historySyncPreferences?.isEnabled == true },
            set: { enabled in
                if enabled {
                    confirmingHistorySync = true
                } else {
                    Task { await syncController.setHistorySyncEnabled(false) }
                }
            }
        )
    }

    private var historyAudioBinding: Binding<Bool> {
        Binding(
            get: { syncController.historySyncPreferences?.isAudioEnabled == true },
            set: { enabled in syncController.setHistoryAudioSyncEnabled(enabled) }
        )
    }

    private var clearHistoryMessage: String {
        if syncController.historySyncPreferences?.isEnabled == true {
            return String(localized: "This deletes all history from every synchronized device. This cannot be undone.")
        }
        return String(localized: "This deletes all history stored on this Mac. This cannot be undone.")
    }
}
