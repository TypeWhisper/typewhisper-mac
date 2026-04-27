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

            Section(localizedAppText("Workflow Palette", de: "Workflow-Palette")) {
                HotkeyRecorderView(
                    label: dictation.promptPaletteHotkeyLabel,
                    title: localizedAppText("Palette shortcut", de: "Palette-Shortcut"),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .promptPalette) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .promptPalette)
                    },
                    onClear: { dictation.clearHotkey(for: .promptPalette) }
                )

                Text(localizedAppText(
                    "Select or copy text in any app, press the shortcut, and choose a manual workflow to process the text.",
                    de: "Markiere oder kopiere Text in einer App, drücke den Shortcut und wähle einen manuellen Workflow für die Verarbeitung."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Recent Transcriptions")) {
                HotkeyRecorderView(
                    label: dictation.recentTranscriptionsHotkeyLabel,
                    title: String(localized: "Recent transcription shortcut"),
                    subtitle: String(localized: "Open your latest transcriptions and insert one into the focused app."),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .recentTranscriptions) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .recentTranscriptions)
                    },
                    onClear: { dictation.clearHotkey(for: .recentTranscriptions) }
                )

                HotkeyRecorderView(
                    label: dictation.copyLastTranscriptionHotkeyLabel,
                    title: String(localized: "Copy last transcription shortcut"),
                    subtitle: String(localized: "Copy your latest transcription to the clipboard."),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .copyLastTranscription) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .copyLastTranscription)
                    },
                    onClear: { dictation.clearHotkey(for: .copyLastTranscription) }
                )
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }
}
