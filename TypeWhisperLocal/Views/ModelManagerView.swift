import SwiftUI

struct ModelManagerView: View {
    @ObservedObject private var viewModel = ModelManagerViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            enginePicker

            Divider()

            modelList

            Spacer()
        }
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }

    @ViewBuilder
    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Engine")
                .font(.headline)

            Picker("Engine", selection: Binding(
                get: { viewModel.selectedEngine },
                set: { viewModel.selectEngine($0) }
            )) {
                ForEach(EngineType.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(engineDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var engineDescription: String {
        switch viewModel.selectedEngine {
        case .whisper:
            String(localized: "WhisperKit - 99+ languages, streaming support, translation to English")
        case .parakeet:
            String(localized: "Parakeet - 25 European languages, extremely fast on Apple Silicon")
        }
    }

    @ViewBuilder
    private var modelList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models")
                .font(.headline)

            ForEach(viewModel.models) { model in
                ModelRow(model: model, status: viewModel.status(for: model)) {
                    viewModel.downloadModel(model)
                } onDelete: {
                    viewModel.deleteModel(model)
                }
            }
        }
    }
}

struct ModelRow: View {
    let model: ModelInfo
    let status: ModelStatus
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text(model.sizeDescription)
                    Text("\(model.languageCount) languages")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            statusView
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .notDownloaded:
            Button(String(localized: "Download")) {
                onDownload()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
            }

        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Loading..."))
                    .font(.caption)
            }

        case .ready:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(localized: "Ready"))
                    .font(.caption)

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

        case .error(let message):
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(String(localized: "Error"))
                        .font(.caption)
                }
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button(String(localized: "Retry")) {
                    onDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }
}
