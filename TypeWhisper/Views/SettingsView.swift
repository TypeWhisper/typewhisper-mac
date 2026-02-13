import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab(String(localized: "General"), systemImage: "gear") {
                GeneralSettingsView()
            }
            Tab(String(localized: "Models"), systemImage: "square.and.arrow.down") {
                ModelManagerView()
            }
            Tab(String(localized: "Transcription"), systemImage: "text.bubble") {
                TranscriptionSettingsView()
            }
            Tab(String(localized: "Dictation"), systemImage: "mic.fill") {
                DictationSettingsView()
            }
            Tab(String(localized: "File Transcription"), systemImage: "doc.text") {
                FileTranscriptionView()
            }
            Tab(String(localized: "History"), systemImage: "clock.arrow.circlepath") {
                HistoryView()
            }
            Tab(String(localized: "Profiles"), systemImage: "person.crop.rectangle.stack") {
                ProfilesSettingsView()
            }
            Tab(String(localized: "API Server"), systemImage: "network") {
                APISettingsView()
            }
        }
        .frame(minWidth: 550, minHeight: 400)
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
