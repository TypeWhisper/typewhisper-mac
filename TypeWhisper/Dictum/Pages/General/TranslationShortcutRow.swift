import SwiftUI

struct TranslationShortcutRow: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @State private var conflict = false

    private var hotkey: UnifiedHotkey? { dictation.hotkeys(for: .translation).first }

    var body: some View {
        GroupedFormRow(separated: true) {
            Text("Translate", tableName: "DictumShell")
            Spacer()
            HotkeyRecorderView(
                label: hotkey.map { HotkeyService.displayName(for: $0) } ?? "",
                title: String(localized: "Translate", table: "DictumShell"),
                presentation: .dictum,
                onRecord: { newHotkey in
                    conflict = dictation.isHotkeyAssigned(newHotkey, excluding: .translation) != nil
                    guard !conflict else { return }
                    dictation.setHotkey(newHotkey, for: .translation)
                },
                onClear: { dictation.clearHotkey(for: .translation) },
                hotkey: hotkey
            )
        }
        if conflict {
            Text("This shortcut is already assigned in dictum.", tableName: "DictumShell")
                .foregroundStyle(DictumTheme.danger).font(DictumTheme.Typography.secondary)
                .padding(10)
        }
    }
}
