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

            Section(String(localized: "Overlay")) {
                Picker(String(localized: "Position"), selection: $dictation.overlayPosition) {
                    Text(String(localized: "Top")).tag(DictationViewModel.OverlayPosition.top)
                    Text(String(localized: "Bottom")).tag(DictationViewModel.OverlayPosition.bottom)
                }

                Text(String(localized: "The overlay appears centered at the top or bottom of the active screen."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    /// Output language binding that maps to the underlying selectedTask
    private var outputLanguage: Binding<String> {
        Binding(
            get: {
                viewModel.selectedTask == .translate ? "en" : (viewModel.selectedLanguage ?? "auto")
            },
            set: { newValue in
                if newValue == "en" && viewModel.selectedLanguage != "en" {
                    viewModel.selectedTask = .translate
                } else {
                    viewModel.selectedTask = .transcribe
                    if newValue == "auto" {
                        viewModel.selectedLanguage = nil
                    } else {
                        viewModel.selectedLanguage = newValue
                    }
                }
            }
        )
    }

    var body: some View {
        Form {
            Section(String(localized: "Input Language")) {
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

            Section(String(localized: "Output Language")) {
                Picker(String(localized: "Text output"), selection: outputLanguage) {
                    Text(String(localized: "Same as input")).tag("auto")
                    if let lang = viewModel.selectedLanguage, lang != "en" {
                        Text(inputLanguageName).tag(lang)
                    }
                    if viewModel.supportsTranslation {
                        Divider()
                        Text(String(localized: "English (translation)")).tag("en")
                    }
                }

                if viewModel.selectedTask == .translate {
                    Text(String(localized: "Audio will be translated to English regardless of source language."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }

    private var inputLanguageName: String {
        guard let code = viewModel.selectedLanguage else { return "" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
