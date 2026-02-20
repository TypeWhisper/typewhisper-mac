import SwiftUI

struct ModelManagerView: View {
    @ObservedObject private var viewModel = ModelManagerViewModel.shared
    @State private var selectedSection: ModelSection = .localModels

    private enum ModelSection: String, CaseIterable {
        case localModels
        case cloudProvider
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "Section"), selection: $selectedSection) {
                Text(String(localized: "Local Models")).tag(ModelSection.localModels)
                Text(String(localized: "Cloud Provider")).tag(ModelSection.cloudProvider)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedSection {
                    case .localModels:
                        // Engine Picker
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "Engine"))
                                .font(.headline)

                            Picker(String(localized: "Engine"), selection: Binding(
                                get: { viewModel.selectedEngine },
                                set: { viewModel.selectEngine($0) }
                            )) {
                                ForEach(EngineType.availableCases) { engine in
                                    Text(engine.displayName).tag(engine)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text(engineDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        // Local Models
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "Models"))
                                .font(.headline)

                            ForEach(viewModel.models) { model in
                                ModelRow(model: model, status: viewModel.status(for: model)) {
                                    viewModel.downloadModel(model)
                                } onDelete: {
                                    viewModel.deleteModel(model)
                                }
                            }
                        }

                    case .cloudProvider:
                        Text(String(localized: "Configure cloud providers for transcription and AI prompts. An API key is required for each provider."))
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        ForEach(EngineType.cloudCases) { provider in
                            CloudProviderSection(provider: provider, viewModel: viewModel)
                        }

                        ForEach(LLMProviderType.llmOnlyCases) { provider in
                            LLMProviderSection(providerType: provider)
                        }

                        Text(String(localized: "API keys are stored securely in the Keychain"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 500, minHeight: 300)
    }

    private var engineDescription: String {
        switch viewModel.selectedEngine {
        case .whisper:
            String(localized: "WhisperKit - 99+ languages, streaming support, translation to English")
        case .parakeet:
            String(localized: "Parakeet - 25 European languages, extremely fast on Apple Silicon")
        case .speechAnalyzer:
            String(localized: "Apple Speech - system-managed models, streaming support, ~40 languages")
        case .groq, .openai:
            ""
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
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.body.weight(.medium))
                    if model.isRecommended {
                        Text(String(localized: "Recommended"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                HStack(spacing: 8) {
                    Text(model.sizeDescription)
                    Text(String(localized: "\(model.languageCount) languages"))
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

        case .downloading(let progress, let bytesPerSecond):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                if let speed = bytesPerSecond, speed > 0 {
                    Text(Self.formatSpeed(speed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

        case .loading(let phase):
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(Self.phaseText(phase))
                        .font(.caption)
                }
                Text(String(localized: "First launch takes a few minutes. Subsequent launches are fast."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    private static func phaseText(_ phase: String?) -> String {
        switch phase {
        case "prewarming":
            String(localized: "Optimizing for Neural Engine...")
        case "loading":
            String(localized: "Loading model...")
        default:
            String(localized: "Loading...")
        }
    }

    private static func formatSpeed(_ bytesPerSecond: Double) -> String {
        let mbps = bytesPerSecond / (1024 * 1024)
        if mbps >= 1 {
            return String(format: "%.1f MB/s", mbps)
        } else {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024)
        }
    }
}

struct LLMProviderSection: View {
    let providerType: LLMProviderType

    @State private var apiKeyInput = ""
    @State private var showApiKey = false
    @State private var isConfigured = false

    private var keychainId: String? { providerType.cloudConfig?.keychainId }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(providerType.displayName)
                    .font(.body.weight(.medium))

                Text(String(localized: "Prompts Only"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.purple.opacity(0.15), in: Capsule())
                    .foregroundStyle(.purple)

                Spacer()

                if isConfigured {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "API Key Saved"))
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            HStack(spacing: 8) {
                if showApiKey {
                    TextField("API Key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    SecureField("API Key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                }

                Button {
                    showApiKey.toggle()
                } label: {
                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)

                if isConfigured {
                    Button(String(localized: "Remove")) {
                        apiKeyInput = ""
                        if let id = keychainId {
                            try? KeychainService.delete(service: id)
                        }
                        isConfigured = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                } else {
                    Button(String(localized: "Save")) {
                        guard let id = keychainId else { return }
                        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        try? KeychainService.save(key: trimmed, service: id)
                        isConfigured = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        .onAppear {
            if let id = keychainId, let existingKey = KeychainService.load(service: id) {
                apiKeyInput = existingKey
                isConfigured = !existingKey.isEmpty
            }
        }
    }
}
