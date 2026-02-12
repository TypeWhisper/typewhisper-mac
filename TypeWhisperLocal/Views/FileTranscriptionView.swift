import SwiftUI
import UniformTypeIdentifiers

struct FileTranscriptionView: View {
    @ObservedObject private var viewModel = FileTranscriptionViewModel.shared

    @State private var isDragTargeted = false
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 16) {
            dropZone

            if viewModel.selectedFileURL != nil {
                transcriptionControls
            }

            if !viewModel.transcriptionText.isEmpty {
                resultView
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: FileTranscriptionViewModel.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.selectFile(url)
            }
        }
    }

    @ViewBuilder
    private var dropZone: some View {
        VStack(spacing: 12) {
            if let url = viewModel.selectedFileURL {
                HStack {
                    Image(systemName: "doc.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent)
                            .font(.body.weight(.medium))
                        Text(url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        viewModel.reset()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.largeTitle)
                        .foregroundStyle(isDragTargeted ? .blue : .secondary)

                    Text(String(localized: "Drop audio or video file here"))
                        .font(.headline)

                    Text(String(localized: "or"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(String(localized: "Choose File...")) {
                        showFilePicker = true
                    }
                    .buttonStyle(.bordered)

                    Text("WAV, MP3, M4A, FLAC, MP4, MOV")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(32)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDragTargeted ? Color.blue.opacity(0.1) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isDragTargeted ? Color.blue : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2, dash: [8])
                        )
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var transcriptionControls: some View {
        HStack {
            if viewModel.supportsTranslation {
                Picker(String(localized: "Task"), selection: $viewModel.selectedTask) {
                    ForEach(TranscriptionTask.allCases) { task in
                        Text(task.displayName).tag(task)
                    }
                }
                .frame(width: 200)
            }

            Spacer()

            if !viewModel.processingInfo.isEmpty {
                Text(viewModel.processingInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                viewModel.transcribe()
            } label: {
                switch viewModel.state {
                case .loading, .transcribing:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "Transcribing..."))
                    }
                default:
                    Label(String(localized: "Transcribe"), systemImage: "waveform")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canTranscribe)
        }
    }

    @ViewBuilder
    private var resultView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Result"))
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.copyToClipboard()
                } label: {
                    Label(String(localized: "Copy"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ScrollView {
                Text(viewModel.transcriptionText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

            let ext = url.pathExtension.lowercased()
            guard AudioFileService.supportedExtensions.contains(ext) else { return }

            Task { @MainActor in
                viewModel.selectFile(url)
            }
        }
        return true
    }
}
