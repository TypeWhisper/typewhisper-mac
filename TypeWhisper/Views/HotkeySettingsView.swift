import Combine
import SwiftUI

struct HotkeySettingsView: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @State private var secureInputDiagnostics = SecureInputDiagnosticsProvider.snapshot()
    private let secureInputRefresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if secureInputDiagnostics.isActive {
                Section {
                    Label {
                        Text(String(localized: "Secure Input is active in \(secureInputDiagnostics.userFacingOwner). Standard key+modifier shortcuts should keep working. Fallback-only shortcut types may not work until that app leaves password or sensitive input."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section(String(localized: "Hotkeys")) {
                MultiHotkeySlotRecorder(
                    slot: .hybrid,
                    title: String(localized: "Hybrid"),
                    subtitle: String(localized: "Short press to toggle, hold to push-to-talk.")
                )

                MultiHotkeySlotRecorder(
                    slot: .pushToTalk,
                    title: String(localized: "Push-to-Talk"),
                    subtitle: String(localized: "Hold to record, release to stop.")
                )

                MultiHotkeySlotRecorder(
                    slot: .toggle,
                    title: String(localized: "Toggle"),
                    subtitle: String(localized: "Press to start, press again to stop.")
                )
            }

            Section(localizedAppText("Workflow Palette", de: "Workflow-Palette")) {
                MultiHotkeySlotRecorder(
                    slot: .promptPalette,
                    title: localizedAppText("Palette shortcut", de: "Palette-Shortcut"),
                    subtitle: nil
                )

                Text(localizedAppText(
                    "Select or copy text in any app, press the shortcut, and choose a manual workflow to process the text.",
                    de: "Markiere oder kopiere Text in einer App, drücke den Shortcut und wähle einen manuellen Workflow für die Verarbeitung."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "settings.tab.recorder")) {
                MultiHotkeySlotRecorder(
                    slot: .recorderToggle,
                    title: String(localized: "recorder.shortcut.title"),
                    subtitle: String(localized: "recorder.shortcut.description")
                )
            }

            Section(String(localized: "Recent Transcriptions")) {
                MultiHotkeySlotRecorder(
                    slot: .recentTranscriptions,
                    title: String(localized: "Recent transcription shortcut"),
                    subtitle: String(localized: "Open your latest transcriptions and insert one into the focused app.")
                )

                MultiHotkeySlotRecorder(
                    slot: .copyLastTranscription,
                    title: String(localized: "Copy last transcription shortcut"),
                    subtitle: String(localized: "Copy your latest transcription to the clipboard.")
                )
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .onReceive(secureInputRefresh) { _ in
            secureInputDiagnostics = SecureInputDiagnosticsProvider.snapshot()
        }
    }
}

private struct MultiHotkeySlotRecorder: View {
    @ObservedObject private var dictation = DictationViewModel.shared

    let slot: HotkeySlotType
    let title: String
    let subtitle: String?

    var body: some View {
        let hotkeys = dictation.hotkeys(for: slot)

        Group {
            if hotkeys.isEmpty {
                HotkeyRecorderView(
                    label: "",
                    title: title,
                    subtitle: subtitle,
                    onRecord: { hotkey in record(hotkey) },
                    onClear: { dictation.clearHotkey(for: slot) }
                )
            } else {
                assignedHotkeysRow(hotkeys)
            }
        }
    }

    private func assignedHotkeysRow(_ hotkeys: [UnifiedHotkey]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                ForEach(hotkeys, id: \.self) { hotkey in
                    HotkeyRecorderView(
                        label: HotkeyService.displayName(for: hotkey),
                        presentation: .compactChip,
                        onRecord: { newHotkey in record(newHotkey, replacing: hotkey) },
                        onClear: { dictation.removeHotkey(hotkey, for: slot) }
                    )
                }

                addShortcutButton
            }
        }
    }

    private var addShortcutButton: some View {
        HotkeyRecorderView(
            label: "",
            title: localizedAppText("Add Shortcut", de: "Shortcut hinzufügen"),
            presentation: .iconButton(systemName: "plus.circle"),
            onRecord: { hotkey in record(hotkey) },
            onClear: {}
        )
    }

    private func record(_ hotkey: UnifiedHotkey, replacing existingHotkey: UnifiedHotkey? = nil) {
        if let existingHotkey, existingHotkey.conflicts(with: hotkey) {
            dictation.replaceHotkey(existingHotkey, with: hotkey, for: slot)
            return
        }

        let currentHotkeys = dictation.hotkeys(for: slot)
        if currentHotkeys.contains(where: { candidate in
            if let existingHotkey, candidate == existingHotkey {
                return false
            }
            return candidate.conflicts(with: hotkey)
        }) {
            return
        }

        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: slot) {
            dictation.removeConflictingHotkey(hotkey, for: conflict)
        }

        if let existingHotkey {
            dictation.replaceHotkey(existingHotkey, with: hotkey, for: slot)
        } else {
            dictation.addHotkey(hotkey, for: slot)
        }
    }
}
