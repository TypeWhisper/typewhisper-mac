import SwiftUI

struct HotkeySettingsView: View {
    @ObservedObject private var dictation = DictationViewModel.shared

    var body: some View {
        Form {
            Section(String(localized: "Hotkeys")) {
                HotkeyRecorderView(
                    label: dictation.hybridHotkeyLabel,
                    title: String(localized: "Hybrid"),
                    subtitle: String(localized: "Short press to toggle, hold to push-to-talk."),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .hybrid) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .hybrid)
                    },
                    onClear: { dictation.clearHotkey(for: .hybrid) }
                )

                HotkeyRecorderView(
                    label: dictation.pttHotkeyLabel,
                    title: String(localized: "Push-to-Talk"),
                    subtitle: String(localized: "Hold to record, release to stop."),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .pushToTalk) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .pushToTalk)
                    },
                    onClear: { dictation.clearHotkey(for: .pushToTalk) }
                )

                HotkeyRecorderView(
                    label: dictation.toggleHotkeyLabel,
                    title: String(localized: "Toggle"),
                    subtitle: String(localized: "Press to start, press again to stop."),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .toggle) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .toggle)
                    },
                    onClear: { dictation.clearHotkey(for: .toggle) }
                )
            }

            Section(String(localized: "Prompt Palette")) {
                HotkeyRecorderView(
                    label: dictation.promptPaletteHotkeyLabel,
                    title: String(localized: "Palette shortcut"),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .promptPalette) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .promptPalette)
                    },
                    onClear: { dictation.clearHotkey(for: .promptPalette) }
                )

                Text(String(localized: "Select text in any app, press the shortcut, and choose a prompt to process the text."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }
}
