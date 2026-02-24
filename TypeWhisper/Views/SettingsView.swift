import SwiftUI

enum SettingsTab: Hashable {
    case home, general, models, dictation
    case fileTranscription, history, dictionary, snippets, profiles, prompts, integrations, advanced
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .home
    @ObservedObject private var fileTranscription = FileTranscriptionViewModel.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            SettingsMainTabs()
        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(minWidth: 700, idealWidth: 750, minHeight: 550, idealHeight: 600)
        .onAppear { navigateToFileTranscriptionIfNeeded() }
        .onChange(of: fileTranscription.showFilePickerFromMenu) { _, _ in
            navigateToFileTranscriptionIfNeeded()
        }
    }

    private func navigateToFileTranscriptionIfNeeded() {
        if fileTranscription.showFilePickerFromMenu {
            selectedTab = .fileTranscription
        }
    }
}

private struct SettingsMainTabs: TabContent {
    var body: some TabContent<SettingsTab> {
        Tab(String(localized: "Home"), systemImage: "house", value: SettingsTab.home) {
            HomeSettingsView()
        }
        Tab(String(localized: "General"), systemImage: "gear", value: SettingsTab.general) {
            GeneralSettingsView()
        }
        Tab(String(localized: "Models"), systemImage: "cpu", value: SettingsTab.models) {
            ModelManagerView()
        }
        Tab(String(localized: "Dictation"), systemImage: "mic.fill", value: SettingsTab.dictation) {
            DictationSettingsView()
        }
        Tab(String(localized: "File Transcription"), systemImage: "doc.text", value: SettingsTab.fileTranscription) {
            FileTranscriptionView()
        }
        Tab(String(localized: "History"), systemImage: "clock.arrow.circlepath", value: SettingsTab.history) {
            HistoryView()
        }
        SettingsExtraTabs()
    }
}

private struct SettingsExtraTabs: TabContent {
    var body: some TabContent<SettingsTab> {
        Tab(String(localized: "Dictionary"), systemImage: "book.closed", value: SettingsTab.dictionary) {
            DictionarySettingsView()
        }
        Tab(String(localized: "Snippets"), systemImage: "text.badge.plus", value: SettingsTab.snippets) {
            SnippetsSettingsView()
        }
        Tab(String(localized: "Profiles"), systemImage: "person.crop.rectangle.stack", value: SettingsTab.profiles) {
            ProfilesSettingsView()
        }
        Tab(String(localized: "Prompts"), systemImage: "sparkles", value: SettingsTab.prompts) {
            PromptActionsSettingsView()
        }
        Tab(String(localized: "Integrations"), systemImage: "puzzlepiece.extension", value: SettingsTab.integrations) {
            PluginSettingsView()
        }
        Tab(String(localized: "Advanced"), systemImage: "gearshape.2", value: SettingsTab.advanced) {
            AdvancedSettingsView()
        }
    }
}

struct DictationSettingsView: View {
    @ObservedObject private var dictation = DictationViewModel.shared

    var body: some View {
        Form {
            Section(String(localized: "Hotkeys")) {
                HotkeyRecorderView(
                    label: dictation.hybridHotkeyLabel,
                    title: String(localized: "Hybrid"),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .hybrid) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .hybrid)
                    },
                    onClear: { dictation.clearHotkey(for: .hybrid) }
                )
                Text(String(localized: "Short press to toggle, hold to push-to-talk."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HotkeyRecorderView(
                    label: dictation.pttHotkeyLabel,
                    title: String(localized: "Push-to-Talk"),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .pushToTalk) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .pushToTalk)
                    },
                    onClear: { dictation.clearHotkey(for: .pushToTalk) }
                )
                Text(String(localized: "Hold to record, release to stop."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HotkeyRecorderView(
                    label: dictation.toggleHotkeyLabel,
                    title: String(localized: "Toggle"),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .toggle) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .toggle)
                    },
                    onClear: { dictation.clearHotkey(for: .toggle) }
                )
                Text(String(localized: "Press to start, press again to stop."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                HStack {
                    Text(String(localized: "Display duration"))
                    Slider(value: $dictation.promptDisplayDuration, in: 3...30, step: 1)
                    Text("\(Int(dictation.promptDisplayDuration))s")
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
            }

            Section(String(localized: "Permissions")) {
                HStack {
                    Label(
                        String(localized: "Microphone"),
                        systemImage: dictation.needsMicPermission ? "mic.slash" : "mic.fill"
                    )
                    .foregroundStyle(dictation.needsMicPermission ? .orange : .green)

                    Spacer()

                    if dictation.needsMicPermission {
                        Button(String(localized: "Grant Access")) {
                            dictation.requestMicPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Text(String(localized: "Granted"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Label(
                        String(localized: "Accessibility"),
                        systemImage: dictation.needsAccessibilityPermission ? "lock.shield" : "lock.shield.fill"
                    )
                    .foregroundStyle(dictation.needsAccessibilityPermission ? .orange : .green)

                    Spacer()

                    if dictation.needsAccessibilityPermission {
                        Button(String(localized: "Grant Access")) {
                            dictation.requestAccessibilityPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Text(String(localized: "Granted"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(String(localized: "Behavior")) {
                Toggle(String(localized: "Whisper Mode"), isOn: $dictation.whisperModeEnabled)

                Text(String(localized: "Boosts microphone gain for quiet speech. Useful when you can't speak loudly."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(String(localized: "Transcribed text is automatically pasted into the active application using the clipboard. The previous clipboard content is restored after pasting."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }
}

// MARK: - Hotkey Recorder

struct HotkeyRecorderView: View {
    let label: String
    var title: String = String(localized: "Dictation shortcut")
    let onRecord: (UnifiedHotkey) -> Void
    let onClear: () -> Void

    @State private var isRecording = false
    @State private var pendingModifiers: NSEvent.ModifierFlags = []
    @State private var eventMonitor: Any?
    private static var activeRecorder: UUID?
    @State private var id = UUID()

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if isRecording {
                Button {
                    cancelRecording()
                } label: {
                    Text(pendingModifierString.isEmpty
                        ? String(localized: "Press a key…")
                        : pendingModifierString)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if label.isEmpty {
                Button {
                    startRecording()
                } label: {
                    Text(String(localized: "Record Shortcut"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                HStack(spacing: 4) {
                    Button {
                        startRecording()
                    } label: {
                        Text(label)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var pendingModifierString: String {
        var parts: [String] = []
        if pendingModifiers.contains(.control) { parts.append("⌃") }
        if pendingModifiers.contains(.option) { parts.append("⌥") }
        if pendingModifiers.contains(.shift) { parts.append("⇧") }
        if pendingModifiers.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    private func startRecording() {
        if let activeId = Self.activeRecorder, activeId != id {
            return
        }
        Self.activeRecorder = id
        isRecording = true
        pendingModifiers = []
        ServiceContainer.shared.hotkeyService.suspendMonitoring()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                if event.modifierFlags.contains(.function) {
                    finishRecording(UnifiedHotkey(keyCode: 0, modifierFlags: 0, isFn: true))
                    return nil
                }

                let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
                let current = event.modifierFlags.intersection(relevantMask)

                if current.isEmpty, !pendingModifiers.isEmpty {
                    if HotkeyService.modifierKeyCodes.contains(event.keyCode) {
                        finishRecording(UnifiedHotkey(keyCode: event.keyCode, modifierFlags: 0, isFn: false))
                        return nil
                    }
                }

                pendingModifiers = current
            }

            if event.type == .keyDown {
                if event.keyCode == 0x35, pendingModifiers.isEmpty {
                    cancelRecording()
                    return nil
                }

                let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
                let modifiers = event.modifierFlags.intersection(relevantMask).rawValue

                finishRecording(UnifiedHotkey(keyCode: event.keyCode, modifierFlags: modifiers, isFn: false))
                return nil
            }

            return event
        }
    }

    private func finishRecording(_ hotkey: UnifiedHotkey) {
        if Self.activeRecorder == id {
            Self.activeRecorder = nil
        }
        isRecording = false
        pendingModifiers = []
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        ServiceContainer.shared.hotkeyService.resumeMonitoring()
        onRecord(hotkey)
    }

    private func cancelRecording() {
        if Self.activeRecorder == id {
            Self.activeRecorder = nil
        }
        isRecording = false
        pendingModifiers = []
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        ServiceContainer.shared.hotkeyService.resumeMonitoring()
    }
}
