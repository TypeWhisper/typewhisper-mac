import SwiftUI
import TypeWhisperPluginSDK

struct Gemma4SettingsView: View {
    let plugin: Gemma4Plugin
    private let bundle = Bundle(for: Gemma4Plugin.self)
    @State private var modelState: Gemma4ModelState = .notLoaded
    @State private var selectedModelId: String = ""
    @State private var generationTemperature: Double = Gemma4Plugin.defaultGenerationTemperature
    @State private var downloadProgress: Double = 0
    @State private var hfTokenInput = ""
    @State private var isValidatingToken = false
    @State private var tokenValidationResult: Bool?
    @State private var isPolling = false
    @State private var loadTask: Task<Void, Never>?

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var trimmedHfTokenInput: String {
        hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var storedHfToken: String {
        plugin.huggingFaceToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var hasStoredHfToken: Bool {
        !storedHfToken.isEmpty
    }

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

            VStack(alignment: .leading, spacing: 10) {
                Text("HuggingFace Token", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Optional. Increases download rate limits. Free at huggingface.co/settings/tokens", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    SecureField("hf_...", text: $hfTokenInput)
                        .textFieldStyle(.roundedBorder)

                    Button(String(localized: "Save", bundle: bundle)) {
                        validateAndSaveHuggingFaceToken()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedHfTokenInput.isEmpty || isValidatingToken)

                    if hasStoredHfToken {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            hfTokenInput = ""
                            tokenValidationResult = nil
                            isValidatingToken = false
                            plugin.clearHuggingFaceToken()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if isValidatingToken {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating token...", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let tokenValidationResult {
                    HStack(spacing: 4) {
                        Image(systemName: tokenValidationResult ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(tokenValidationResult ? .green : .red)
                        Text(
                            tokenValidationResult
                                ? String(localized: "Valid HuggingFace Token", bundle: bundle)
                                : String(localized: "Invalid HuggingFace Token", bundle: bundle)
                        )
                        .font(.caption)
                        .foregroundStyle(tokenValidationResult ? .green : .red)
                    }
                }
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

            Text("Gemma 4 E2B/E4B 4-bit models are recommended. Larger variants are experimental and may fail depending on hardware.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

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
            downloadProgress = plugin.currentDownloadProgress
            if let token = plugin.huggingFaceToken, !token.isEmpty {
                hfTokenInput = token
            }
        }
        .task {
            if case .notLoaded = plugin.modelState {
                isPolling = true
                await plugin.restoreLoadedModel(allowDownloads: false)
                isPolling = false
                modelState = plugin.modelState
            }
        }
        .onReceive(pollTimer) { _ in
            guard isPolling else { return }
            downloadProgress = plugin.currentDownloadProgress
            let pluginState = plugin.modelState
            if pluginState != .notLoaded {
                modelState = pluginState
            }
            if case .ready = pluginState { isPolling = false }
            else if case .error = pluginState { isPolling = false }
        }
        .onChange(of: hfTokenInput) { _, newValue in
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedValue != storedHfToken {
                tokenValidationResult = nil
            }
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

            if case .downloading = modelState, selectedModelId == modelDef.id {
                HStack(spacing: 8) {
                    ProgressView(value: downloadProgress)
                        .frame(width: 80)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                    Button(String(localized: "Cancel", bundle: bundle)) {
                        cancelCurrentLoad()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if case .loading = modelState, selectedModelId == modelDef.id {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Button(String(localized: "Cancel", bundle: bundle)) {
                        cancelCurrentLoad()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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
            } else if let experimentalWarning = modelDef.experimentalWarning {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Experimental", bundle: bundle)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                    Text(LocalizedStringKey(experimentalWarning), bundle: bundle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 220, alignment: .trailing)

                    Button(String(localized: "Try anyway", bundle: bundle)) {
                        startLoading(modelDef)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(modelState == .downloading || modelState == .loading)
                }
            } else {
                Button(String(localized: "Download & Load", bundle: bundle)) {
                    startLoading(modelDef)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(modelState == .downloading || modelState == .loading)
            }
        }
        .padding(.vertical, 4)
    }

    private func startLoading(_ modelDef: Gemma4ModelDef) {
        selectedModelId = modelDef.id
        let alreadyDownloaded = plugin.isModelDownloaded(modelDef)
        plugin.beginModelLoad(for: modelDef, isAlreadyDownloaded: alreadyDownloaded)
        modelState = plugin.modelState
        downloadProgress = plugin.currentDownloadProgress
        isPolling = true
        loadTask?.cancel()
        loadTask = Task {
            do {
                try await plugin.loadModel(modelDef)
            } catch is CancellationError {
            } catch {
            }

            await MainActor.run {
                isPolling = false
                modelState = plugin.modelState
                downloadProgress = plugin.currentDownloadProgress
                loadTask = nil
            }
        }
    }

    private func cancelCurrentLoad() {
        loadTask?.cancel()
        loadTask = nil
        isPolling = false
        plugin.cancelModelLoad()
        modelState = plugin.modelState
        downloadProgress = plugin.currentDownloadProgress
    }

    private func validateAndSaveHuggingFaceToken() {
        let trimmedToken = trimmedHfTokenInput
        guard !trimmedToken.isEmpty else { return }

        isValidatingToken = true
        tokenValidationResult = nil

        Task {
            let isValid = await plugin.validateHuggingFaceToken(trimmedToken)
            await MainActor.run {
                isValidatingToken = false
                tokenValidationResult = isValid
                if isValid {
                    hfTokenInput = trimmedToken
                    plugin.saveHuggingFaceToken(trimmedToken)
                }
            }
        }
    }
}
