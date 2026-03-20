import SwiftUI

struct WatchFolderSettingsView: View {
    @ObservedObject var viewModel: WatchFolderViewModel

    var body: some View {
        Form {
            Section(String(localized: "watchFolder.folders")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "watchFolder.watchFolder"))
                            .font(.body)
                        if let path = viewModel.watchFolderPath {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(String(localized: "watchFolder.noFolder"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(String(localized: "watchFolder.selectFolder")) {
                        viewModel.selectWatchFolder()
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "watchFolder.outputFolder"))
                            .font(.body)
                        if let path = viewModel.outputFolderPath {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(String(localized: "watchFolder.outputFolder.sameAsWatch"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if viewModel.outputFolderPath != nil {
                        Button {
                            viewModel.clearOutputFolder()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(String(localized: "watchFolder.selectFolder")) {
                        viewModel.selectOutputFolder()
                    }
                }
            }

            Section(String(localized: "watchFolder.settings")) {
                Picker(String(localized: "watchFolder.outputFormat"), selection: $viewModel.outputFormat) {
                    Text("Markdown (.md)").tag("md")
                    Text(String(localized: "watchFolder.plainText")).tag("txt")
                }

                Picker(String(localized: "watchFolder.language"), selection: Binding(
                    get: { viewModel.language ?? "__auto__" },
                    set: { viewModel.language = $0 == "__auto__" ? nil : $0 }
                )) {
                    Text(String(localized: "watchFolder.language.auto")).tag("__auto__")
                    Divider()
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                    Text("Francais").tag("fr")
                    Text("Espanol").tag("es")
                    Text("Italiano").tag("it")
                    Text("Portugues").tag("pt")
                    Text("Nederlands").tag("nl")
                    Text("Polski").tag("pl")
                    Text("Turkce").tag("tr")
                    Text("Русский").tag("ru")
                    Text("中文").tag("zh")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                }

                Toggle(String(localized: "watchFolder.deleteSource"), isOn: $viewModel.deleteSourceFiles)

                Toggle(String(localized: "watchFolder.autoStart"), isOn: $viewModel.autoStartOnLaunch)
            }

            Section {
                HStack {
                    Button {
                        viewModel.toggleWatching()
                    } label: {
                        Label(
                            viewModel.watchFolderService.isWatching
                                ? String(localized: "watchFolder.stopWatching")
                                : String(localized: "watchFolder.startWatching"),
                            systemImage: viewModel.watchFolderService.isWatching ? "stop.fill" : "play.fill"
                        )
                    }
                    .disabled(viewModel.watchFolderPath == nil)

                    if let processing = viewModel.watchFolderService.currentlyProcessing {
                        Spacer()
                        Label(processing, systemImage: "arrow.trianglehead.2.counterclockwise")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Text(String(localized: "watchFolder.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "watchFolder.history")) {
                if viewModel.watchFolderService.processedFiles.isEmpty {
                    Text(String(localized: "watchFolder.history.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.watchFolderService.processedFiles.prefix(20)) { item in
                        HStack {
                            Image(systemName: item.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(item.success ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.fileName)
                                    .lineLimit(1)
                                if let error = item.errorMessage {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .lineLimit(1)
                                } else {
                                    Text(item.date, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !viewModel.watchFolderService.processedFiles.isEmpty {
                        Button(String(localized: "watchFolder.history.clear"), role: .destructive) {
                            viewModel.watchFolderService.clearHistory()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }
}
