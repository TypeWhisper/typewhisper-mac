import SwiftUI
import UniformTypeIdentifiers

/// Shared import UI scoped to the engine whose settings are currently open.
public struct PluginModelImportButton: View {
    private let importer: any PluginCustomModelImporting
    private let bundle: Bundle
    @State private var isPresented = false

    public init(importer: any PluginCustomModelImporting, bundle: Bundle) {
        self.importer = importer
        self.bundle = bundle
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(String(localized: "Import Model…", bundle: bundle), systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .sheet(isPresented: $isPresented) {
            PluginModelImportSheet(importer: importer, bundle: bundle)
        }
    }
}

private struct PluginModelImportSheet: View {
    let importer: any PluginCustomModelImporting
    let bundle: Bundle
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var token = ""
    @State private var folder: URL?
    @State private var useFolder = false
    @State private var showFolderPicker = false
    @State private var importTask: Task<Void, Never>?
    @State private var status = ""
    @State private var error: String?
    @State private var importedName: String?
    @State private var importedModelHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(importer.providerDisplayName)
                .font(.subheadline).foregroundStyle(.secondary)
            Text(String(localized: "Import Speech Model", bundle: bundle))
                .font(.title2.bold())
            Text(String(localized: "Add a model compatible with this plugin. The model is checked and loaded before the import completes.", bundle: bundle))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let importedName {
                Label(String(localized: "Imported and loaded: \(importedName)", bundle: bundle), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(localized: "You can select the engine in Dictation settings and manage the model in Integrations.", bundle: bundle))
                    .foregroundStyle(.secondary)
                if let importedModelHint {
                    Text(importedModelHint).foregroundStyle(.secondary)
                }
            } else {
                Picker(String(localized: "Source", bundle: bundle), selection: $useFolder) {
                    Text("Hugging Face").tag(false)
                    Text(String(localized: "Local Folder", bundle: bundle)).tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(importTask != nil)

                if useFolder {
                    HStack {
                        Text(folder?.lastPathComponent ?? String(localized: "No folder selected", bundle: bundle))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(String(localized: "Choose Folder…", bundle: bundle)) { showFolderPicker = true }
                            .disabled(importTask != nil)
                    }
                    Text(String(localized: "Choose the folder containing config.json, tokenizer files and weights. TypeWhisper keeps its own copy; your original files are not changed.", bundle: bundle))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("https://huggingface.co/owner/model", text: $repository)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(String(localized: "Hugging Face model URL", bundle: bundle))
                        .disabled(importTask != nil)
                    SecureField(String(localized: "Hugging Face token (optional)", bundle: bundle), text: $token)
                        .textFieldStyle(.roundedBorder)
                        .disabled(importTask != nil)
                    Text(String(localized: "A token is only needed for private or gated models. It is used for this import and is not saved.", bundle: bundle))
                        .font(.caption).foregroundStyle(.secondary)
                }

                if importTask != nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(status).foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button(importedName == nil ? String(localized: "Cancel", bundle: bundle) : String(localized: "Done", bundle: bundle)) {
                    if let importTask {
                        importTask.cancel()
                        status = String(localized: "Cancelling…", bundle: bundle)
                    } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                if importedName == nil {
                    Button(String(localized: "Import", bundle: bundle), action: startImport)
                        .keyboardShortcut(.defaultAction)
                        .disabled(importTask != nil || (useFolder ? folder == nil : repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(importTask != nil)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            do { folder = try result.get(); error = nil }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { importTask?.cancel() }
    }

    private func startImport() {
        error = nil
        status = String(localized: "Checking model compatibility…", bundle: bundle)
        let source: PluginModelImportSource
        do {
            if useFolder, let folder { source = .folder(folder) }
            else { source = try .huggingFaceInput(repository) }
        } catch { self.error = error.localizedDescription; return }
        let importToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        importTask = Task { @MainActor in
            let scopedURL: URL? = if case .folder(let url) = source { url } else { nil }
            let hasScope = scopedURL?.startAccessingSecurityScopedResource() ?? false
            defer {
                if hasScope { scopedURL?.stopAccessingSecurityScopedResource() }
                importTask = nil
            }
            do {
                let candidate = try await PluginModelImportCandidate.inspect(source, token: importToken)
                try Task.checkCancellation()
                guard importer.supportedImportModelTypes.contains(candidate.modelType) else {
                    self.error = String(localized: "This model architecture is not supported by this plugin. Open the settings of a compatible plugin to import it.", bundle: bundle)
                    return
                }
                status = String(localized: "Importing and loading with \(importer.providerDisplayName)…", bundle: bundle)
                let result = try await importer.importModel(candidate, token: importToken)
                importedName = result.displayName
                if candidate.modelType == "canary" {
                    importedModelHint = String(localized: "Canary needs an explicit source language. Choose Greek or English for Sophea in Dictation settings.", bundle: bundle)
                }
                token = ""
            } catch is CancellationError {
                status = ""
            } catch let failure as URLError where failure.code == .cancelled {
                status = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
