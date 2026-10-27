import SwiftUI
import TypeWhisperPluginSDK
import UniformTypeIdentifiers

struct LlamaCppSettingsView: View {
    @ObservedObject var plugin: LlamaCppPlugin
    private let bundle = Bundle(for: LlamaCppPlugin.self)
    private let hostMemoryGB = LlamaCppModelCatalog.hostMemoryGB
    private let recommendedModel = LlamaCppModelCatalog.recommendedModel()

    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .custom
    @State private var generationTemperature = LlamaCppPlugin.defaultGenerationTemperature
    @State private var hfTokenInput = ""
    @State private var isValidatingToken = false
    @State private var tokenValidationResult: Bool?

    @State private var huggingFaceInput = ""
    @State private var isLookingUp = false
    @State private var lookupResult: LlamaCppHuggingFaceLookupResult?
    @State private var selectedRemotePath = ""
    @State private var customModelError: String?
    @State private var isShowingFileImporter = false

    private var isBusy: Bool {
        plugin.modelState == .downloading || plugin.modelState == .loading
    }

    private var storedHfToken: String {
        plugin.huggingFaceToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LlamaCppPlugin.pluginName)
                .font(.headline)

            Text("Runs GGUF models on this Mac with llama.cpp and Metal. Choose a recommended model, add one from Hugging Face, or import a .gguf file. No API key required.", bundle: bundle)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()
            generationSection
            Divider()
            tokenSection
            Divider()
            catalogSection
            Divider()
            customModelsSection

            if case .error(let message) = plugin.modelState {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("Error", bundle: bundle))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Text("llama.cpp \(LlamaCppRuntimeRelease.pinned.version) (\(LlamaCppRuntimeRelease.pinned.build)) is downloaded from GitHub with the first model and runs as a local server that only this Mac can reach.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            llmTemperatureMode = plugin.llmTemperatureMode
            generationTemperature = plugin.generationTemperature
            hfTokenInput = storedHfToken
        }
        .onChange(of: hfTokenInput) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines) != storedHfToken {
                tokenValidationResult = nil
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    // MARK: - Sections

    private var generationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generation", bundle: bundle)
                .font(.subheadline)
                .fontWeight(.medium)

            Picker(String(localized: "Temperature Mode", bundle: bundle), selection: $llmTemperatureMode) {
                Text("Provider Default", bundle: bundle).tag(PluginLLMTemperatureMode.providerDefault)
                Text("Custom", bundle: bundle).tag(PluginLLMTemperatureMode.custom)
            }
            .onChange(of: llmTemperatureMode) { _, newValue in
                plugin.setLLMTemperatureMode(newValue)
            }

            if llmTemperatureMode == .custom {
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
                    .accessibilityLabel(Text("Temperature", bundle: bundle))

                HStack {
                    Text("Precise", bundle: bundle)
                    Spacer()
                    Text("Creative", bundle: bundle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Uses the plugin's default temperature of 0.1.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HuggingFace Token", bundle: bundle)
                .font(.subheadline)
                .fontWeight(.medium)

            Text("Optional. Increases download rate limits and opens private or gated models you have access to. Free at huggingface.co/settings/tokens", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                SecureField("hf_...", text: $hfTokenInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text("Hugging Face token", bundle: bundle))

                Button(String(localized: "Save", bundle: bundle)) {
                    validateAndSaveHuggingFaceToken()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingToken)
                .accessibilityLabel(Text("Save Hugging Face token", bundle: bundle))

                if !storedHfToken.isEmpty {
                    Button(String(localized: "Remove", bundle: bundle)) {
                        hfTokenInput = ""
                        tokenValidationResult = nil
                        plugin.clearHuggingFaceToken()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Remove Hugging Face token", bundle: bundle))
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
                        .accessibilityHidden(true)
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
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommended Models", bundle: bundle)
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(LlamaCppModelCatalog.models) { model in
                modelRow(model)
            }

            if let recommendedModel {
                Text("For this Mac with \(hostMemoryGB) GB of memory, \(recommendedModel.displayName) is recommended. Smaller models respond faster but follow instructions less reliably.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var customModelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Models", bundle: bundle)
                .font(.subheadline)
                .fontWeight(.medium)

            Text("Add any GGUF model from Hugging Face, for example a small 0.5B to 4B model for fast cleanup, or import a .gguf file from this Mac. Models with a chat template work best.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(plugin.customModels) { model in
                modelRow(model)
            }

            HStack(spacing: 8) {
                TextField(
                    String(localized: "owner/model-GGUF or owner/model-GGUF:Q4_K_M", bundle: bundle),
                    text: $huggingFaceInput
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(lookUpHuggingFaceModels)
                .accessibilityLabel(Text("Hugging Face repository", bundle: bundle))

                Button(String(localized: "Find GGUF Files", bundle: bundle)) {
                    lookUpHuggingFaceModels()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(huggingFaceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLookingUp)
            }

            if isLookingUp {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Looking up repository...", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let lookupResult {
                lookupResultView(lookupResult)
            }

            HStack(spacing: 8) {
                Button(String(localized: "Import GGUF File…", bundle: bundle)) {
                    customModelError = nil
                    isShowingFileImporter = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(plugin.isImportingModel)

                if plugin.isImportingModel {
                    ProgressView().controlSize(.small)
                    Text("Importing...", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let customModelError {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("Error", bundle: bundle))
                    Text(customModelError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func lookupResultView(_ result: LlamaCppHuggingFaceLookupResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(String(localized: "File", bundle: bundle), selection: $selectedRemotePath) {
                Text("Choose a file", bundle: bundle).tag("")
                ForEach(result.models, id: \.path) { file in
                    Text(verbatim: "\(file.fileName) (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))")
                        .tag(file.path)
                }
            }

            HStack {
                Text("\(result.repositoryId) at commit \(String(result.revision.prefix(7))). The file is checked against its SHA-256 after the download.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Add & Download", bundle: bundle)) {
                    addSelectedHuggingFaceModel(from: result)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(selectedRemotePath.isEmpty || isBusy)
            }

            if result.skippedSplitModelCount > 0 {
                Text("Models split into several files are not listed because they are not supported yet.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Model rows

    @ViewBuilder
    private func modelRow(_ model: LlamaCppModelDefinition) -> some View {
        let isDownloaded = plugin.isModelDownloaded(model)
        let isCurrent = plugin.loadingModelId == model.id
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.body)
                    if model.id == recommendedModel?.id {
                        Text("Recommended for this Mac", bundle: bundle)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                if let usageHint = model.usageHint {
                    Text(LocalizedStringKey(usageHint), bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let source = model.sourceDescription {
                    Text(verbatim: source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let minimumMemoryGB = model.minimumMemoryGB {
                    Text(verbatim: "\(model.sizeDescription) - RAM: \(minimumMemoryGB) GB+")
                        .font(.caption)
                        .foregroundStyle(minimumMemoryGB > hostMemoryGB ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    if minimumMemoryGB > hostMemoryGB {
                        Text("This Mac has \(hostMemoryGB) GB of memory, less than this model needs.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(verbatim: model.sizeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilitySortPriority(1)

            Spacer()

            modelActions(model, isDownloaded: isDownloaded, isCurrent: isCurrent)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func modelActions(_ model: LlamaCppModelDefinition, isDownloaded: Bool, isCurrent: Bool) -> some View {
        if isCurrent, plugin.modelState == .downloading {
            HStack(spacing: 8) {
                if plugin.hasVisibleDownloadProgress {
                    ProgressView(value: plugin.downloadProgress)
                        .frame(width: 80)
                        .accessibilityLabel(Text("Downloading \(model.displayName)", bundle: bundle))
                    Text("\(Int(plugin.downloadProgress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .accessibilityHidden(true)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Downloading \(model.displayName)", bundle: bundle))
                }
                cancelButton(model)
            }
        } else if isCurrent, plugin.modelState == .loading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Loading \(model.displayName)", bundle: bundle))
                cancelButton(model)
            }
        } else if plugin.modelState == .ready(model.id) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("Loaded", bundle: bundle))
                Button(String(localized: "Unload", bundle: bundle)) {
                    plugin.unloadModel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(Text("Unload \(model.displayName)", bundle: bundle))
                removeButton(model)
            }
        } else if isDownloaded || plugin.hasModelFiles(model) || model.isCustom {
            HStack(spacing: 8) {
                if isDownloaded, model.id == plugin.modelIdLoadedOnDemand, plugin.modelState == .notLoaded {
                    PluginModelLoadsOnDemandStatus(bundle: bundle)
                } else {
                    Button(
                        isDownloaded
                            ? String(localized: "Load", bundle: bundle)
                            : String(localized: "Download & Load", bundle: bundle)
                    ) {
                        load(model)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isBusy)
                    .accessibilityLabel(
                        isDownloaded
                            ? Text("Load \(model.displayName)", bundle: bundle)
                            : Text("Download and load \(model.displayName)", bundle: bundle)
                    )
                }
                removeButton(model)
            }
        } else if let warning = model.experimentalWarning {
            VStack(alignment: .trailing, spacing: 6) {
                Text("Experimental", bundle: bundle)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                Text(LocalizedStringKey(warning), bundle: bundle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
                Button(String(localized: "Try anyway", bundle: bundle)) {
                    load(model)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)
                .accessibilityLabel(Text("Try \(model.displayName) anyway", bundle: bundle))
            }
        } else {
            Button(String(localized: "Download & Load", bundle: bundle)) {
                load(model)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isBusy)
            .accessibilityLabel(Text("Download and load \(model.displayName)", bundle: bundle))
        }
    }

    private func cancelButton(_ model: LlamaCppModelDefinition) -> some View {
        Button(String(localized: "Cancel", bundle: bundle)) {
            plugin.cancelLoad()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(Text("Cancel loading \(model.displayName)", bundle: bundle))
    }

    private func removeButton(_ model: LlamaCppModelDefinition) -> some View {
        Button(String(localized: "Remove", bundle: bundle), role: .destructive) {
            do {
                try plugin.removeModel(model)
            } catch {
                customModelError = error.localizedDescription
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isBusy && plugin.loadingModelId != model.id)
        .accessibilityLabel(Text("Remove \(model.displayName)", bundle: bundle))
    }

    // MARK: - Actions

    private func load(_ model: LlamaCppModelDefinition) {
        customModelError = nil
        plugin.startLoading(model)
    }

    private func lookUpHuggingFaceModels() {
        let input = huggingFaceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isLookingUp else { return }
        isLookingUp = true
        lookupResult = nil
        customModelError = nil
        Task {
            do {
                let result = try await plugin.lookUpHuggingFaceModels(input)
                await MainActor.run {
                    lookupResult = result
                    selectedRemotePath = result.preselectedPath ?? ""
                    isLookingUp = false
                }
            } catch {
                await MainActor.run {
                    customModelError = LlamaCppPlugin.userFacingMessage(for: error)
                    isLookingUp = false
                }
            }
        }
    }

    private func addSelectedHuggingFaceModel(from result: LlamaCppHuggingFaceLookupResult) {
        guard let file = result.models.first(where: { $0.path == selectedRemotePath }) else { return }
        do {
            let model = try plugin.addHuggingFaceModel(file)
            lookupResult = nil
            huggingFaceInput = ""
            selectedRemotePath = ""
            load(model)
        } catch {
            customModelError = LlamaCppPlugin.userFacingMessage(for: error)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            customModelError = nil
            Task {
                do {
                    let model = try await plugin.importModelFile(url)
                    await MainActor.run { load(model) }
                } catch {
                    await MainActor.run {
                        customModelError = LlamaCppPlugin.userFacingMessage(for: error)
                    }
                }
            }
        case .failure(let error):
            customModelError = error.localizedDescription
        }
    }

    private func validateAndSaveHuggingFaceToken() {
        let token = hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        isValidatingToken = true
        tokenValidationResult = nil
        Task {
            let isValid = await plugin.validateHuggingFaceToken(token)
            await MainActor.run {
                isValidatingToken = false
                tokenValidationResult = isValid
                if isValid {
                    hfTokenInput = token
                    plugin.saveHuggingFaceToken(token)
                }
            }
        }
    }
}
