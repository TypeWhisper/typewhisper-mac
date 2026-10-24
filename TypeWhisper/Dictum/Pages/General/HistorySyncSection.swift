import SwiftUI

struct HistorySyncSection: View {
    @ObservedObject private var controller = ServiceContainer.shared.cloudFolderSyncController
    @State private var retention = HistoryRetention.selected()
    @State private var pendingRetention: HistoryRetention?
    @State private var confirmOff = false
    @AppStorage(UserDefaultsKeys.saveAudioWithHistory) private var keepRecordings = true

    var body: some View {
        GroupedFormSection(title: "History & Sync", footer: "Only text goes to the sync folder. Recordings stay on this Mac.", tableName: "DictumHistory") {
            GroupedFormRow {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync to iCloud Drive", tableName: "DictumHistory")
                    Text(HistorySyncPresentation.settingsStatus(controller))
                    .font(.caption).foregroundStyle(controller.errorMessage == nil ? .secondary : Color.red)
                }
                Spacer()
                Toggle(isOn: Binding(get: { controller.mode != .off }, set: { enabled in
                    if enabled { Task { await enableSync() } } else { confirmOff = true }
                })) { Text("Sync to iCloud Drive", tableName: "DictumHistory") }
                .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(controller.isSyncing)
            }
            if controller.needsSyncConsent {
                GroupedFormRow(separated: true) {
                    Text("Keep a text copy in iCloud Drive?", tableName: "DictumHistory")
                    Spacer()
                    Button { controller.declineDefaultSync() } label: { Text("Not now", tableName: "DictumHistory") }
                    Button { Task { await controller.acceptDefaultSync() } } label: { Text("Enable", tableName: "DictumHistory") }
                }
            }
            GroupedFormRow(separated: true) {
                Text("Sync folder", tableName: "DictumHistory")
                Spacer()
                Text(HistorySyncPresentation.folderDisplay(controller.selectedFolderURL)).font(.caption).lineLimit(1).truncationMode(.middle)
                Button { controller.chooseFolder() } label: { Text("Change…", tableName: "DictumHistory") }
                    .disabled(controller.isSyncing)
            }
            GroupedFormRow(separated: true) {
                Text("Keep history", tableName: "DictumHistory")
                Spacer()
                Picker(selection: Binding(get: { retention }, set: { value in
                    if ServiceContainer.shared.historyService.retentionDeletionCount(value) > 0 { pendingRetention = value }
                    else { apply(value) }
                })) {
                    ForEach(HistoryRetention.allCases) { Text($0.title).tag($0) }
                } label: { Text("Keep history", tableName: "DictumHistory") }
                .labelsHidden().frame(width: 140)
            }
            GroupedFormToggle(title: "Keep recordings", isOn: $keepRecordings, tableName: "DictumHistory")
        }
        .alert(String(localized: "Turn off sync?", table: "DictumHistory"), isPresented: $confirmOff) {
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "DictumHistory") }
            Button { Task { await controller.setMode(.off) } } label: { Text("Turn off", tableName: "DictumHistory") }
        } message: { Text("History on this Mac and files in the sync folder will be kept.", tableName: "DictumHistory") }
        .alert(String(localized: "Delete older history?", table: "DictumHistory"), isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })) {
            Button(role: .cancel) { pendingRetention = nil } label: { Text("Cancel", tableName: "DictumHistory") }
            Button(role: .destructive) { if let value = pendingRetention { apply(value) }; pendingRetention = nil } label: { Text("Delete", tableName: "DictumHistory") }
        } message: {
            if let value = pendingRetention {
                Text(String(format: String(localized: "Delete %lld records before %@.", table: "DictumHistory"),
                            Int64(ServiceContainer.shared.historyService.retentionDeletionCount(value)),
                            (value.cutoff() ?? Date()).formatted(date: .abbreviated, time: .shortened)))
            }
        }
    }

    private func apply(_ value: HistoryRetention) {
        value.save()
        retention = value
        ServiceContainer.shared.historyService.applyRetention(value)
    }

    private func enableSync() async {
        if controller.selectedFolderURL == nil { await controller.acceptDefaultSync() }
        else { await controller.setHistorySyncEnabled(true); await controller.setMode(.cloudFolder) }
    }
}
