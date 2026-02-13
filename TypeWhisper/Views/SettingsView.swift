import SwiftUI
import KeyboardShortcuts

enum SettingsTab: Hashable {
    case home, general, models, transcription, dictation
    case fileTranscription, history, dictionary, snippets, profiles, apiServer
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            SettingsMainTabs(selectedTab: $selectedTab)
        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(minWidth: 700, idealWidth: 750, minHeight: 550, idealHeight: 600)
    }
}

private struct SettingsMainTabs: TabContent {
    @Binding var selectedTab: SettingsTab

    var body: some TabContent<SettingsTab> {
        Tab(String(localized: "Home"), systemImage: "house", value: SettingsTab.home) {
            HomeSettingsView(selectedTab: $selectedTab)
        }
        Tab(String(localized: "General"), systemImage: "gear", value: SettingsTab.general) {
            GeneralSettingsView()
        }
        Tab(String(localized: "Models"), systemImage: "square.and.arrow.down", value: SettingsTab.models) {
            ModelManagerView()
        }
        Tab(String(localized: "Transcription"), systemImage: "text.bubble", value: SettingsTab.transcription) {
            TranscriptionSettingsView()
        }
        Tab(String(localized: "Dictation"), systemImage: "mic.fill", value: SettingsTab.dictation) {
            DictationSettingsView()
                .task {
                    if !UserDefaults.standard.bool(forKey: "hotkeyCustomized") {
                        UserDefaults.standard.set(true, forKey: "hotkeyCustomized")
                        HomeViewModel.shared.refresh()
                    }
                }
        }
        Tab(String(localized: "File Transcription"), systemImage: "doc.text", value: SettingsTab.fileTranscription) {
            FileTranscriptionView()
        }
        Tab(String(localized: "History"), systemImage: "clock.arrow.circlepath", value: SettingsTab.history) {
            HistoryView()
                .task {
                    if !UserDefaults.standard.bool(forKey: "historyTabVisited") {
                        UserDefaults.standard.set(true, forKey: "historyTabVisited")
                        HomeViewModel.shared.refresh()
                    }
                }
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
        Tab(String(localized: "API Server"), systemImage: "network", value: SettingsTab.apiServer) {
            APISettingsView()
        }
    }
}

struct DictationSettingsView: View {
    @ObservedObject private var dictation = DictationViewModel.shared

    var body: some View {
        Form {
            Section(String(localized: "Hotkey")) {
                KeyboardShortcuts.Recorder(String(localized: "Dictation shortcut"), name: .toggleDictation)

                Text(String(localized: "Quick press: toggle mode (press again to stop). Hold 1+ seconds: push-to-talk (release to stop)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

struct TranscriptionSettingsView: View {
    @ObservedObject private var viewModel = SettingsViewModel.shared

    var body: some View {
        Form {
            Section(String(localized: "Language")) {
                Picker(String(localized: "Spoken language"), selection: $viewModel.selectedLanguage) {
                    Text(String(localized: "Auto-detect")).tag(nil as String?)
                    Divider()
                    ForEach(viewModel.availableLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code as String?)
                    }
                }

                Text(String(localized: "The language being spoken. Setting this explicitly improves accuracy."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Translation")) {
                Toggle(String(localized: "Enable translation"), isOn: $viewModel.translationEnabled)

                if viewModel.translationEnabled {
                    Picker(String(localized: "Target language"), selection: $viewModel.translationTargetLanguage) {
                        ForEach(TranslationService.availableTargetLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                }

                Text(String(localized: "Uses Apple Translate (on-device)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }
}
