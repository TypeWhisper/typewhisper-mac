import Combine
import SwiftUI
import TypeWhisperModuleKit

struct HotkeySettingsView: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @State private var secureInputDiagnostics = SecureInputDiagnosticsProvider.snapshot()
    private let secureInputRefresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "Hotkeys"))
            Divider()

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

                MultiHotkeySlotRecorder(
                    slot: .pasteLastTranscription,
                    title: String(localized: "Paste last transcription shortcut"),
                    subtitle: String(localized: "Insert your latest transcription into the focused app.")
                )

                MultiHotkeySlotRecorder(
                    slot: .correctLastDictation,
                    title: String(localized: "Correct last dictation shortcut"),
                    subtitle: String(localized: "correctLastDictation.shortcut.description")
                )
                }

                Section(String(localized: "askHistory.title")) {
                MultiHotkeySlotRecorder(
                    slot: .askHistory,
                    title: String(localized: "askHistory.shortcut.title"),
                    subtitle: String(localized: "askHistory.shortcut.description")
                )
                }

                ForEach(moduleActionGroups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.actions) { action in
                            ModuleHotkeyActionRecorder(action: action)
                        }
                    }
                }

                #if !APPSTORE
                Section(localizedAppText("Dictation Undo", de: "Diktat rückgängig")) {
                MultiHotkeySlotRecorder(
                    slot: .undoLastDictation,
                    title: localizedAppText("Undo last dictation shortcut", de: "Shortcut „Letztes Diktat rückgängig“"),
                    subtitle: localizedAppText(
                        "Delete the text inserted by the most recent dictation.",
                        de: "Löscht den Text des zuletzt eingefügten Diktats."
                    )
                )

                MultiHotkeySlotRecorder(
                    slot: .restoreRawTranscript,
                    title: localizedAppText("Restore raw transcript shortcut", de: "Shortcut „Rohtext wiederherstellen“"),
                    subtitle: localizedAppText(
                        "Replace the last inserted dictation with its raw transcript.",
                        de: "Ersetzt das zuletzt eingefügte Diktat durch sein Roh-Transkript."
                    )
                )
                }
                #endif
            }
            .formStyle(.grouped)
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, SettingsLayoutMetrics.pagePadding)
        }
        .frame(minWidth: 500, minHeight: 300)
        .onReceive(secureInputRefresh) { _ in
            secureInputDiagnostics = SecureInputDiagnosticsProvider.snapshot()
        }
    }

    /// The modules' hotkey actions by their group, in the order they come.
    private var moduleActionGroups: [(title: String, actions: [ModuleHotkeyAction])] {
        var groups: [(title: String, actions: [ModuleHotkeyAction])] = []
        for action in ServiceContainer.shared.moduleRegistry.contributions.hotkeyActions {
            let title = action.group ?? ""
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].actions.append(action)
            } else {
                groups.append((title, [action]))
            }
        }
        return groups
    }
}

/// The shortcuts of one module's hotkey action, recorded like those of a slot.
private struct ModuleHotkeyActionRecorder: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    let action: ModuleHotkeyAction
    /// Changes after every edit, so the row reads the new shortcuts.
    @State private var revision = 0

    private var hotkeyService: HotkeyService { ServiceContainer.shared.hotkeyService }

    var body: some View {
        let hotkeys = hotkeyService.hotkeys(forModuleAction: action.id)

        Group {
            if hotkeys.isEmpty {
                HotkeyRecorderView(
                    label: "",
                    title: action.title,
                    subtitle: action.subtitle,
                    onRecord: { hotkey in record(hotkey) },
                    onClear: { save([]) }
                )
            } else {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.title)
                        if let subtitle = action.subtitle {
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
                                onClear: { save(hotkeys.filter { $0 != hotkey }) },
                                hotkey: hotkey
                            )
                        }

                        HotkeyRecorderView(
                            label: "",
                            title: localizedAppText("Add Shortcut", de: "Shortcut hinzufügen"),
                            presentation: .iconButton(systemName: "plus.circle"),
                            onRecord: { hotkey in record(hotkey) },
                            onClear: {}
                        )
                    }
                }
            }
        }
        .id(revision)
    }

    private func record(_ hotkey: UnifiedHotkey, replacing existingHotkey: UnifiedHotkey? = nil) {
        var hotkeys = hotkeyService.hotkeys(forModuleAction: action.id)
        if let existingHotkey, let index = hotkeys.firstIndex(of: existingHotkey) {
            hotkeys[index] = hotkey
            hotkeys = hotkeys.enumerated().filter { $0.offset == index || !$0.element.conflicts(with: hotkey) }.map(\.element)
        } else {
            guard !hotkeys.contains(where: { $0.conflicts(with: hotkey) }) else { return }
            hotkeys.append(hotkey)
        }
        // A slot that has the shortcut gives it up; another module action does so in `save`.
        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .moduleAction) {
            dictation.removeConflictingHotkey(hotkey, for: conflict)
        }
        save(hotkeys)
    }

    private func save(_ hotkeys: [UnifiedHotkey]) {
        hotkeyService.setHotkeys(hotkeys, forModuleAction: action.id)
        revision += 1
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
                        onClear: { dictation.removeHotkey(hotkey, for: slot) },
                        hotkey: hotkey
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
