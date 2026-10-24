import SwiftUI

struct HistorySettingsView: View {
    @ObservedObject private var syncController = ServiceContainer.shared.cloudFolderSyncController
    @ObservedObject private var settingsNavigation = SettingsNavigationCoordinator.shared
    @State private var confirmingHistorySync = false
    @State private var confirmingClearHistory = false
    @StateObject private var restoreDeleteConfirmation = ActionConfirmation(duration: .seconds(4))

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "History & Sync"))
            Divider()

            if settingsNavigation.historyPart == .sync {
                SettingsDetailPart(
                    backTitle: String(localized: "History & Sync"),
                    onBack: { settingsNavigation.historyPart = .history }
                ) {
                    CloudFolderSyncSettingsView(controller: syncController)
                }
            } else {
            FeatureSettingsLink(feature: .cloudSync)
                .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
                .padding(.top, SettingsLayoutMetrics.pagePadding)

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

                Section(String(localized: "Sync")) {
                    Toggle(String(localized: "Sync History & Inbox"), isOn: historySyncBinding)
                        .disabled(syncController.mode == .off || syncController.isSyncing)
                }

                Section(String(localized: "Restore & Delete")) {
                    Button(String(localized: "Restore Automatically Removed History")) {
                        restoreAutomaticallyRemovedHistory()
                    }
                    Button(String(localized: "Delete History"), role: .destructive) {
                        confirmingClearHistory = true
                    }
                    if let message = restoreDeleteConfirmation.message {
                        ActionConfirmationLabel(message: message)
                    }
                    Text(String(localized: "Restoring re-imports synchronized entries removed only by local retention. Deleting history while sync is enabled removes it from all synchronized devices."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            }
        }
        // Coming back to the page later starts on the page itself.
        .onDisappear { settingsNavigation.historyPart = .history }
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
                    Text(String(localized: "Your saved text and Inbox state will be added to your private sync folder and become available on your other enabled dictum devices."))
        }
        .confirmationDialog(
            String(localized: "Delete All History?"),
            isPresented: $confirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                if ServiceContainer.shared.historyService.clearAll() {
                    restoreDeleteConfirmation.show(String(localized: "History deleted."))
                } else {
                    restoreDeleteConfirmation.show(
                        String(localized: "History could not be deleted."),
                        isError: true
                    )
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(clearHistoryMessage)
        }
    }

    /// Says what happened: nothing to restore, restored by a sync that just finished,
    /// or restored with the next sync when history sync is off or already running.
    private func restoreAutomaticallyRemovedHistory() {
        guard let preferences = syncController.historySyncPreferences,
              !preferences.suppressedRecordIDs.isEmpty else {
            restoreDeleteConfirmation.show(String(localized: "No automatically removed history to restore."))
            return
        }
        preferences.restoreSuppressedHistory()

        let restoredLater = String(localized: "Automatically removed history will be restored with the next sync.")
        guard preferences.isEnabled, syncController.mode != .off, !syncController.isSyncing else {
            // A running sync repeats once it finishes, which restores the entries.
            Task { await syncController.syncNow() }
            restoreDeleteConfirmation.show(restoredLater)
            return
        }

        let previousSyncDate = syncController.lastSyncDate
        Task {
            await syncController.syncNow()
            if syncController.lastSyncDate != previousSyncDate {
                restoreDeleteConfirmation.show(String(localized: "Automatically removed history restored."))
            } else if let errorMessage = syncController.errorMessage {
                restoreDeleteConfirmation.show(errorMessage, isError: true)
            } else {
                restoreDeleteConfirmation.show(restoredLater)
            }
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

    private var clearHistoryMessage: String {
        if syncController.historySyncPreferences?.isEnabled == true {
            return String(localized: "This deletes all history from every synchronized device. This cannot be undone.")
        }
        return String(localized: "This deletes all history stored on this Mac. This cannot be undone.")
    }
}
