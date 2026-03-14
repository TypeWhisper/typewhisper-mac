import SwiftUI
import TypeWhisperPluginSDK

struct SetupWizardView: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var registryService = PluginRegistryService.shared
    @ObservedObject private var audioDevice = ServiceContainer.shared.audioDeviceService
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var processingService = ServiceContainer.shared.promptProcessingService
    @State private var currentStep = 0
    @State private var selectedProvider: String?

    private let totalSteps = 3

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            navigation
        }
        .frame(minHeight: 350)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(String(localized: "Setup"))
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            Text(String(localized: "Step \(currentStep + 1) of \(totalSteps)"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { index in
                    Circle()
                        .fill(index <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding()
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            switch currentStep {
            case 0: permissionsStep
            case 1: engineStep
            case 2: hotkeyStep
            default: EmptyView()
            }
        }
        .padding()
    }

    // MARK: - Step 1: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Microphone access is required for dictation."))
                .font(.callout)
                .foregroundStyle(.secondary)

            permissionRow(
                label: String(localized: "Microphone"),
                iconGranted: "mic.fill",
                iconMissing: "mic.slash",
                isGranted: !dictation.needsMicPermission
            ) {
                dictation.requestMicPermission()
            }

            Text(String(localized: "Accessibility access is required to paste text into other apps."))
                .font(.callout)
                .foregroundStyle(.secondary)

            permissionRow(
                label: String(localized: "Accessibility"),
                iconGranted: "lock.shield.fill",
                iconMissing: "lock.shield",
                isGranted: !dictation.needsAccessibilityPermission
            ) {
                dictation.requestAccessibilityPermission()
            }

            if !dictation.needsMicPermission {
                Divider()

                Text(String(localized: "Select your preferred microphone:"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker(String(localized: "Microphone"), selection: $audioDevice.selectedDeviceUID) {
                    Text(String(localized: "System Default")).tag(nil as String?)
                    Divider()
                    ForEach(audioDevice.inputDevices) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }

                if audioDevice.isPreviewActive {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.quaternary)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.green.gradient)
                                    .frame(width: max(0, geo.size.width * CGFloat(audioDevice.previewAudioLevel)))
                                    .animation(.easeOut(duration: 0.08), value: audioDevice.previewAudioLevel)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.vertical, 4)
                }

                Button(audioDevice.isPreviewActive
                    ? String(localized: "Stop Preview")
                    : String(localized: "Test Microphone")
                ) {
                    if audioDevice.isPreviewActive {
                        audioDevice.stopPreview()
                    } else {
                        audioDevice.startPreview()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func permissionRow(
        label: String,
        iconGranted: String,
        iconMissing: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Label(label, systemImage: isGranted ? iconGranted : iconMissing)
                .foregroundStyle(isGranted ? .green : .orange)

            Spacer()

            if isGranted {
                Text(String(localized: "Granted"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(String(localized: "Grant Access")) {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    // MARK: - Step 2: Engines

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Install a transcription engine to get started. Each engine needs to download a model before it can be used."))
                .font(.callout)
                .foregroundStyle(.secondary)

            let engines = pluginManager.transcriptionEngines
            if !engines.isEmpty {
                Text(String(localized: "Installed"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(engines, id: \.providerId) { engine in
                    SetupEngineRow(engine: engine)
                }

                if !hasAnyEngineReady {
                    Text(String(localized: "Open an engine's settings to download a model."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // Default engine picker
                if engines.count > 1 {
                    Picker(String(localized: "Default Engine"), selection: $selectedProvider) {
                        ForEach(engines, id: \.providerId) { engine in
                            HStack {
                                Text(engine.providerDisplayName)
                                if !engine.isConfigured {
                                    Text("(\(String(localized: "not ready")))")
                                        .foregroundStyle(.secondary)
                                }
                            }.tag(engine.providerId as String?)
                        }
                    }
                    .onChange(of: selectedProvider) { _, newValue in
                        if let newValue {
                            modelManager.selectProvider(newValue)
                        }
                    }
                }

                // Default LLM picker
                let llmProviders = processingService.availableProviders
                if llmProviders.count > 1 {
                    Picker(String(localized: "Default LLM"), selection: $processingService.selectedProviderId) {
                        ForEach(llmProviders, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                }
            }

            // Available engines from marketplace
            switch registryService.fetchState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "Loading plugins..."))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            case .error(let message):
                VStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button(String(localized: "Retry")) {
                        Task { await registryService.fetchRegistry() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            case .loaded:
                let available = availableTranscriptionPlugins
                if available.isEmpty {
                    if engines.isEmpty {
                        Text(String(localized: "No engines available. Check your internet connection."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        Text(String(localized: "All engines installed."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(String(localized: "Available"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(available) { plugin in
                        AvailablePluginRow(
                            plugin: plugin,
                            installState: registryService.installStates[plugin.id],
                            onInstall: {
                                Task {
                                    await registryService.downloadAndInstall(plugin)
                                    PluginManager.shared.setPluginEnabled(plugin.id, enabled: true)
                                }
                            }
                        )
                    }
                }

                if PluginManager.shared.llmProviders.isEmpty {
                    Divider()
                    Text(String(localized: "To use AI prompts, install an LLM provider (e.g. Groq, OpenAI) from the Integrations tab after setup."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            if registryService.fetchState == .idle {
                await registryService.fetchRegistry()
            }
        }
        .onAppear {
            selectedProvider = modelManager.selectedProviderId
        }
        .onChange(of: pluginManager.transcriptionEngines.map(\.providerId)) { _, engines in
            // Auto-select first engine when only one is installed and none was selected
            if selectedProvider == nil || !engines.contains(where: { $0 == selectedProvider }),
               let first = engines.first {
                selectedProvider = first
                modelManager.selectProvider(first)
            }
        }
    }

    private var availableTranscriptionPlugins: [RegistryPlugin] {
        let installedIds = Set(pluginManager.loadedPlugins.map(\.manifest.id))
        return registryService.registry.filter {
            $0.category == "transcription" && !installedIds.contains($0.id) && $0.isCompatibleWithCurrentOS
        }
    }

    // MARK: - Step 3: Hotkey

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Choose how to trigger dictation."))
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                HotkeyRecorderView(
                    label: dictation.hybridHotkeyLabel,
                    title: String(localized: "Hybrid"),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .hybrid) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .hybrid)
                    },
                    onClear: { dictation.clearHotkey(for: .hybrid) }
                )
                Text(String(localized: "Short press to toggle, hold to push-to-talk."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HotkeyRecorderView(
                    label: dictation.pttHotkeyLabel,
                    title: String(localized: "Push-to-Talk"),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .pushToTalk) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .pushToTalk)
                    },
                    onClear: { dictation.clearHotkey(for: .pushToTalk) }
                )
                Text(String(localized: "Hold to record, release to stop."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HotkeyRecorderView(
                    label: dictation.toggleHotkeyLabel,
                    title: String(localized: "Toggle"),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .toggle) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .toggle)
                    },
                    onClear: { dictation.clearHotkey(for: .toggle) }
                )
                Text(String(localized: "Press to start, press again to stop."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        }
    }

    // MARK: - Navigation

    private var navigation: some View {
        HStack {
            if currentStep > 0 {
                Button(String(localized: "Back")) {
                    withAnimation { currentStep -= 1 }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if currentStep < totalSteps - 1 {
                Button(String(localized: "Next")) {
                    withAnimation { currentStep += 1 }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(String(localized: "Finish")) {
                    HomeViewModel.shared.completeSetupWizard()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private var hasAnyEngineReady: Bool {
        pluginManager.transcriptionEngines.contains { $0.isConfigured }
    }
}

// MARK: - Engine Row

private struct SetupEngineRow: View {
    let engine: any TranscriptionEnginePlugin
    @ObservedObject private var pluginManager = PluginManager.shared
    @State private var showSettings = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.providerDisplayName)
                    .font(.body.weight(.medium))

                if engine.isConfigured, let modelId = engine.selectedModelId,
                   let model = engine.transcriptionModels.first(where: { $0.id == modelId }) {
                    Text(model.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if engine.isConfigured {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(localized: "Ready"))
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } else {
                Text(String(localized: "Not configured"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Find the loaded plugin to access settingsView
            if let loaded = PluginManager.shared.loadedPlugins.first(where: {
                ($0.instance as? any TranscriptionEnginePlugin)?.providerId == engine.providerId
            }), loaded.instance.settingsView != nil {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        .sheet(isPresented: $showSettings) {
            if let loaded = PluginManager.shared.loadedPlugins.first(where: {
                ($0.instance as? any TranscriptionEnginePlugin)?.providerId == engine.providerId
            }), let view = loaded.instance.settingsView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(loaded.manifest.name)
                            .font(.headline)
                        Spacer()
                        Button {
                            showSettings = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.title2)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding()

                    Divider()

                    view
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 500, minHeight: 400)
            }
        }
    }
}


