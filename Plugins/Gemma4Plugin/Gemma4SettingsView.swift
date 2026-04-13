import SwiftUI
import TypeWhisperPluginSDK

struct Gemma4SettingsView: View {
    let plugin: Gemma4Plugin
    private let bundle = Bundle(for: Gemma4Plugin.self)
    @State private var modelState: Gemma4ModelState = .notLoaded
    @State private var selectedModelId: String = ""
    @State private var generationTemperature: Double = Gemma4Plugin.defaultGenerationTemperature
    @State private var isPolling = false

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gemma 4 (MLX)")
                .font(.headline)

            Text("Local LLM powered by Google Gemma 4 on Apple Silicon. No API key required.", bundle: bundle)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Generation", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack {
                    Text("Temperature", bundle: bundle)
                    Spacer()
                    Text(generationTemperature, format: .number.precision(.fractionLength(2)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)

                Slider(value: $generationTemperature, in: 0...1, step: 0.05)
                    .onChange(of: generationTemperature) { _, newValue in
                        plugin.setGenerationTemperature(newValue)
                    }

                HStack {
                    Text("Precise", bundle: bundle)
                    Spacer()
                    Text("Creative", bundle: bundle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Model", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                ForEach(Gemma4Plugin.availableModels) { modelDef in
                    modelRow(modelDef)
                }
            }

            if case .error(let message) = modelState {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .onAppear {
            modelState = plugin.modelState
            selectedModelId = plugin.selectedLLMModelId ?? Gemma4Plugin.availableModels.first?.id ?? ""
            generationTemperature = plugin.generationTemperature
        }
        .task {
            if case .notLoaded = plugin.modelState {
                isPolling = true
                await plugin.restoreLoadedModel()
                isPolling = false
                modelState = plugin.modelState
            }
        }
        .onReceive(pollTimer) { _ in
            guard isPolling else { return }
            let pluginState = plugin.modelState
            if pluginState != .notLoaded {
                modelState = pluginState
            }
            if case .ready = pluginState { isPolling = false }
            else if case .error = pluginState { isPolling = false }
        }
    }

    @ViewBuilder
    private func modelRow(_ modelDef: Gemma4ModelDef) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(modelDef.displayName)
                    .font(.body)
                Text("\(modelDef.sizeDescription) - RAM: \(modelDef.ramRequirement)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .loading = modelState, selectedModelId == modelDef.id {
                ProgressView()
                    .controlSize(.small)
            } else if case .ready(let loadedId) = modelState, loadedId == modelDef.id {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button(String(localized: "Unload", bundle: bundle)) {
                        plugin.unloadModel()
                        plugin.deleteModelFiles(modelDef)
                        modelState = plugin.modelState
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Button(String(localized: "Download & Load", bundle: bundle)) {
                    selectedModelId = modelDef.id
                    modelState = .loading
                    isPolling = true
                    Task {
                        try? await plugin.loadModel(modelDef)
                        isPolling = false
                        modelState = plugin.modelState
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(modelState == .loading)
            }
        }
        .padding(.vertical, 4)
    }
}
