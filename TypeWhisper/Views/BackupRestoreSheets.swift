import SwiftUI

/// Category-selection sheet shown from "Export Settings…" in Advanced
/// settings, mirroring `SnippetEditorSheet`'s header/content/footer layout.
/// The backup is already built (from live state) by the time this sheet
/// appears — the sheet only decides which categories make it into the file.
struct BackupExportSheet: View {
    let backup: SettingsBackupExporter.SettingsBackup
    let onExport: (Set<SettingsBackupExporter.Category>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<SettingsBackupExporter.Category>

    init(backup: SettingsBackupExporter.SettingsBackup, onExport: @escaping (Set<SettingsBackupExporter.Category>) -> Void) {
        self.backup = backup
        self.onExport = onExport
        _selected = State(initialValue: Self.availableCategories(in: backup))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localizedAppText("Export Settings", de: "Einstellungen exportieren"))
                        .font(.headline)
                    Text(localizedAppText(
                        "Choose what to include in the backup file.",
                        de: "Wähle aus, was in die Sicherungsdatei aufgenommen werden soll."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            VStack(spacing: 0) {
                BackupCategorySelectAllRow(selected: $selected, available: Self.availableCategories(in: backup))

                ScrollView {
                    BackupCategoryList(backup: backup, selected: $selected)
                }
            }
            .padding()

            Divider()

            BackupSheetFooter(
                selectedCount: selected.count,
                totalCount: SettingsBackupExporter.Category.allCases.count,
                actionTitle: localizedAppText("Export…", de: "Exportieren…"),
                actionDisabled: selected.isEmpty
            ) {
                dismiss()
                onExport(selected)
            } onCancel: {
                dismiss()
            }
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 420, idealHeight: 480)
    }

    private static func availableCategories(in backup: SettingsBackupExporter.SettingsBackup) -> Set<SettingsBackupExporter.Category> {
        Set(SettingsBackupExporter.Category.allCases.filter { SettingsBackupExporter.Category.count($0, in: backup) > 0 })
    }
}

/// File-picker + category-selection sheet shown from "Import Settings…" in
/// Advanced settings. Unlike export, there's no live data to show until a
/// backup file has been chosen and parsed, so this sheet has two steps.
struct BackupImportSheet: View {
    let onImport: (SettingsBackupExporter.SettingsBackup, Set<SettingsBackupExporter.Category>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var backup: SettingsBackupExporter.SettingsBackup?
    @State private var selected: Set<SettingsBackupExporter.Category> = []
    @State private var loadErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localizedAppText("Import Settings", de: "Einstellungen importieren"))
                        .font(.headline)
                    Text(backup == nil
                         ? localizedAppText("Choose a TypeWhisper settings backup file.", de: "Wähle eine TypeWhisper-Sicherungsdatei aus.")
                         : localizedAppText("Choose what to restore from this file.", de: "Wähle aus, was aus dieser Datei wiederhergestellt werden soll."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if let backup {
                VStack(spacing: 0) {
                    BackupCategorySelectAllRow(selected: $selected, available: Self.availableCategories(in: backup))

                    ScrollView {
                        BackupCategoryList(backup: backup, selected: $selected)
                    }
                }
                .padding()
            } else {
                filePicker
            }

            Divider()

            BackupSheetFooter(
                selectedCount: backup == nil ? 0 : selected.count,
                totalCount: SettingsBackupExporter.Category.allCases.count,
                actionTitle: localizedAppText("Import…", de: "Importieren…"),
                actionDisabled: backup == nil || selected.isEmpty,
                showCount: backup != nil
            ) {
                guard let backup else { return }
                dismiss()
                onImport(backup, selected)
            } onCancel: {
                dismiss()
            }
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: backup == nil ? 260 : 420, idealHeight: backup == nil ? 260 : 480)
    }

    private var filePicker: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Button(localizedAppText("Choose File…", de: "Datei auswählen…")) {
                chooseFile()
            }
            .buttonStyle(.borderedProminent)
            if let loadErrorMessage {
                Text(loadErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private func chooseFile() {
        loadErrorMessage = nil
        guard let url = SettingsBackupExporter.presentOpenPanel() else { return }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try SettingsBackupExporter.parse(data)
            backup = parsed
            selected = Self.availableCategories(in: parsed)
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    private static func availableCategories(in backup: SettingsBackupExporter.SettingsBackup) -> Set<SettingsBackupExporter.Category> {
        Set(SettingsBackupExporter.Category.allCases.filter { SettingsBackupExporter.Category.count($0, in: backup) > 0 })
    }
}

// MARK: - Shared row list

private struct BackupCategoryList: View {
    let backup: SettingsBackupExporter.SettingsBackup
    @Binding var selected: Set<SettingsBackupExporter.Category>

    var body: some View {
        VStack(spacing: 0) {
            ForEach(SettingsBackupExporter.Category.allCases) { category in
                let count = SettingsBackupExporter.Category.count(category, in: backup)
                BackupCategoryRow(
                    category: category,
                    count: count,
                    isOn: Binding(
                        get: { selected.contains(category) },
                        set: { isOn in
                            if isOn { selected.insert(category) } else { selected.remove(category) }
                        }
                    )
                )
                if category != SettingsBackupExporter.Category.allCases.last {
                    Divider().padding(.leading, 34)
                }
            }
        }
    }
}

private struct BackupCategoryRow: View {
    let category: SettingsBackupExporter.Category
    let count: Int
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text(category.title)
                SettingsInfoButton(text: category.infoText)
            }

            Spacer()

            Text("\(count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(count == 0)
                .accessibilityLabel(String(format: String(localized: "Include %@"), category.title))
        }
        .padding(.vertical, 6)
        .opacity(count == 0 ? 0.45 : 1)
    }
}

private struct BackupCategorySelectAllRow: View {
    @Binding var selected: Set<SettingsBackupExporter.Category>
    let available: Set<SettingsBackupExporter.Category>

    var body: some View {
        HStack {
            Spacer()
            Button(String(localized: "Select All")) {
                selected = available
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Button(String(localized: "Select None")) {
                selected.removeAll()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.bottom, 6)
    }
}

private struct BackupSheetFooter: View {
    let selectedCount: Int
    let totalCount: Int
    let actionTitle: String
    let actionDisabled: Bool
    var showCount: Bool = true
    let onAction: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack {
            Button(String(localized: "Cancel")) { onCancel() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            if showCount {
                Text(String(format: String(localized: "%d of %d categories selected"), selectedCount, totalCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(actionTitle) { onAction() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(actionDisabled)
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
}
