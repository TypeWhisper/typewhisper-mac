import SwiftUI

struct ShortcutsSection: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @State private var conflict = false

    private var primarySlot: HotkeySlotType { dictation.hotkeys(for: .hybrid).isEmpty ? .toggle : .hybrid }
    private var hotkeys: [UnifiedHotkey] { dictation.hotkeys(for: primarySlot) }

    var body: some View {
        GroupedFormSection(title: "Shortcuts", footer: "Use this shortcut on keyboards without an fn key.") {
            GroupedFormRow {
                Text("Dictate", tableName: "DictumShell")
                Spacer()
                recorder(hotkeys.first, slot: primarySlot)
            }
            TranslationShortcutRow()
            GroupedFormRow(separated: true) {
                Text("Cancel", tableName: "DictumShell")
                Spacer()
                KeyCapView(key: "esc")
            }
            GroupedFormRow(separated: true) {
                Text("When held", tableName: "DictumShell")
                Spacer()
                Picker(selection: Binding(
                    get: { primarySlot == .hybrid },
                    set: setPushToTalk
                )) {
                    Text("Push to talk", tableName: "DictumShell").tag(true)
                    Text("Off", tableName: "DictumShell").tag(false)
                } label: {
                    Text("When held", tableName: "DictumShell")
                }
                .labelsHidden().fixedSize().pickerStyle(.menu).buttonStyle(.bordered).tint(.primary)
            }
            GroupedFormRow(separated: true) {
                Text("External keyboard", tableName: "DictumShell")
                Spacer()
                ForEach(Array(hotkeys.dropFirst()), id: \.self) { hotkey in
                    recorder(hotkey, slot: primarySlot)
                    Button { dictation.removeHotkey(hotkey, for: primarySlot) } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove", tableName: "DictumShell"))
                }
                if hotkeys.count < 2 {
                    recorder(nil, slot: primarySlot)
                }
            }
            if conflict {
                Text("This shortcut is already assigned in dictum.", tableName: "DictumShell")
                    .foregroundStyle(DictumTheme.danger).font(DictumTheme.Typography.secondary)
                    .padding(10)
            }
        }
    }

    private func recorder(_ hotkey: UnifiedHotkey?, slot: HotkeySlotType) -> some View {
        HotkeyRecorderView(
            label: hotkey.map { HotkeyService.displayName(for: $0) } ?? "",
            title: String(localized: "Add Backup Shortcut", table: "DictumShell"),
            presentation: .dictum,
            onRecord: { newHotkey in
                conflict = dictation.isHotkeyAssigned(newHotkey, excluding: slot) != nil
                    || hotkeys.contains(where: { $0 != hotkey && $0.conflicts(with: newHotkey) })
                guard !conflict else { return }
                if let hotkey { dictation.replaceHotkey(hotkey, with: newHotkey, for: slot) }
                else { dictation.addHotkey(newHotkey, for: slot) }
            },
            onClear: { if let hotkey { dictation.removeHotkey(hotkey, for: slot) } },
            hotkey: hotkey
        )
    }

    private func setPushToTalk(_ enabled: Bool) {
        let source = primarySlot
        let destination: HotkeySlotType = enabled ? .hybrid : .toggle
        guard source != destination else { return }
        for hotkey in hotkeys {
            dictation.removeHotkey(hotkey, for: source)
            dictation.addHotkey(hotkey, for: destination)
        }
    }
}
