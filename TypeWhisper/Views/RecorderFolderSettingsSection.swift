import AppKit
import SwiftUI

/// Where the Recorder saves new recordings, and the earlier folders it still lists.
struct RecorderFolderSettingsSection: View {
    @ObservedObject var store: RecorderFolderStore
    /// Folders cannot change while a recording or transcription uses them.
    let isLocked: Bool
    /// The folder the Watch Folder watches, which cannot take new recordings.
    let watchFolderPath: @MainActor () -> String?
    /// Called after the listed folders changed, so the recordings list can reload.
    let onFoldersChanged: () -> Void

    @State private var choiceError: String?

    var body: some View {
        Section(String(localized: "recorder.folder.section")) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "recorder.folder.saveTo"))
                    Text(RecorderFolderStore.abbreviatedPath(store.chosenFolderPath))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(store.chosenFolderPath)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                if !store.usesDefaultFolder {
                    Button(String(localized: "recorder.folder.useDefault")) {
                        choiceError = nil
                        store.useDefaultFolder()
                        onFoldersChanged()
                    }
                }
                Button(String(localized: "Choose Folder…")) {
                    chooseFolder()
                }
            }
            .disabled(isLocked)

            if let notice = store.notice {
                Label(message(for: notice), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if let choiceError {
                Label(choiceError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Text(String(localized: "recorder.folder.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            let earlierFolders = store.earlierFolders
            if !earlierFolders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "recorder.folder.earlier"))
                    ForEach(earlierFolders, id: \.path) { folder in
                        earlierFolderRow(folder)
                    }
                    Text(String(localized: "recorder.folder.earlier.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            // Resolving a bookmark can touch a slow disk; keep it off the main thread.
            let store = store
            Task.detached(priority: .utility) {
                store.refreshAvailability()
            }
        }
    }

    private func earlierFolderRow(_ folder: RecorderFolder) -> some View {
        let path = store.path(of: folder)
        let removeLabel = String(
            format: String(localized: "recorder.folder.earlier.remove"),
            RecorderFolderStore.folderName(of: path)
        )
        return HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(RecorderFolderStore.abbreviatedPath(path))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer()
            Button {
                choiceError = nil
                store.forgetEarlierFolder(folder)
                onFoldersChanged()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .help(removeLabel)
            .accessibilityLabel(removeLabel)
        }
    }

    private func message(for notice: RecorderFolderStore.Notice) -> String {
        switch notice {
        case .unavailable(let path):
            String(format: String(localized: "recorder.folder.unavailable"), RecorderFolderStore.folderName(of: path))
        case .saveFailed(let path):
            String(format: String(localized: "recorder.folder.saveFailed"), RecorderFolderStore.folderName(of: path))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "recorder.folder.panelMessage")
        let currentFolder = URL(fileURLWithPath: store.chosenFolderPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: currentFolder.path) {
            panel.directoryURL = currentFolder
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.chooseFolder(url, watchFolderPath: watchFolderPath())
            choiceError = nil
            onFoldersChanged()
        } catch {
            choiceError = error.localizedDescription
        }
    }
}
