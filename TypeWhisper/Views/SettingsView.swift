import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab(String(localized: "Models"), systemImage: "square.and.arrow.down") {
                ModelManagerView()
            }
            Tab(String(localized: "Transcription"), systemImage: "text.bubble") {
                TranscriptionSettingsView()
            }
            Tab(String(localized: "File Transcription"), systemImage: "doc.text") {
                FileTranscriptionView()
            }
        }
        .frame(minWidth: 550, minHeight: 400)
    }
}

struct TranscriptionSettingsView: View {
    @ObservedObject private var viewModel = SettingsViewModel.shared

    var body: some View {
        Form {
            Section(String(localized: "Language")) {
                Picker(String(localized: "Language"), selection: $viewModel.selectedLanguage) {
                    Text(String(localized: "Auto-detect")).tag(nil as String?)
                    Divider()
                    ForEach(viewModel.availableLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code as String?)
                    }
                }
            }

            if viewModel.supportsTranslation {
                Section(String(localized: "Task")) {
                    Picker(String(localized: "Task"), selection: $viewModel.selectedTask) {
                        ForEach(TranscriptionTask.allCases) { task in
                            Text(task.displayName).tag(task)
                        }
                    }

                    if viewModel.selectedTask == .translate {
                        Text(String(localized: "Audio will be translated to English regardless of source language."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }
}
