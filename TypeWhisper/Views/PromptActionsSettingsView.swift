import SwiftUI
import TypeWhisperPluginSDK

struct PromptActionsSettingsView: View {
    @ObservedObject private var viewModel = PromptActionsViewModel.shared
    @ObservedObject private var processingService: PromptProcessingService

    init() {
        self._processingService = ObservedObject(wrappedValue: PromptActionsViewModel.shared.promptProcessingService)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Provider selection
            providerSection
                .padding(.horizontal, 8)
                .padding(.bottom, 12)

            Divider()
                .padding(.bottom, 8)

            if viewModel.promptActions.isEmpty {
                emptyState
            } else {
                // Header with add button
                HStack {
                    Text(String(format: String(localized: "%d Prompts"), viewModel.promptActions.count))
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    presetMenu

                    Button {
                        viewModel.startCreating()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help(String(localized: "Add new prompt"))
                    .accessibilityLabel(String(localized: "Add new prompt"))
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.promptActions) { action in
                            PromptActionCardView(action: action, viewModel: viewModel, processingService: processingService)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .sheet(isPresented: $viewModel.isEditing) {
            PromptActionEditorSheet(viewModel: viewModel)
        }
        .alert(String(localized: "Error"), isPresented: Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button(String(localized: "OK")) { viewModel.clearError() }
        } message: {
            Text(viewModel.error ?? "")
        }
        .onAppear {
            processingService.validateSelectionAfterPluginLoad()
        }
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        GroupBox(String(localized: "Default LLM Provider")) {
            let providers = processingService.availableProviders
            if providers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Install an LLM provider plugin (e.g. Groq, OpenAI) to use prompts."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "Go to Integrations")) {
                        viewModel.navigateToIntegrations = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(String(localized: "Provider"), selection: $processingService.selectedProviderId) {
                        ForEach(providers, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }

                    ProviderStatusView(
                        providerId: processingService.selectedProviderId,
                        processingService: processingService,
                        cloudModel: $processingService.selectedCloudModel,
                        onNavigateToIntegrations: { viewModel.navigateToIntegrations = true }
                    )

                    if PluginManager.shared.llmProviders.isEmpty {
                        Button {
                            viewModel.navigateToIntegrations = true
                        } label: {
                            Label(
                                String(localized: "Install additional LLM providers from the Integrations tab."),
                                systemImage: "info.circle"
                            )
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Empty State

    private var presetMenu: some View {
        Menu {
            let available = viewModel.availablePresets
            if available.isEmpty {
                Text(String(localized: "All presets imported"))
            } else {
                ForEach(available, id: \.name) { preset in
                    Button {
                        viewModel.importPreset(preset)
                    } label: {
                        Label(preset.name, systemImage: preset.icon)
                    }
                }

                Divider()

                Button {
                    viewModel.loadPresets()
                } label: {
                    Label(String(localized: "Import All"), systemImage: "square.and.arrow.down.on.square")
                }
            }
        } label: {
            Image(systemName: "tray.and.arrow.down")
        }
        .help(String(localized: "Import Preset"))
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text(String(localized: "No prompts yet"))
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text(String(localized: "Create prompts to process your dictated text with AI"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                HStack(spacing: 12) {
                    presetMenu
                        .buttonStyle(.borderedProminent)

                    Button(String(localized: "Add Prompt")) {
                        viewModel.startCreating()
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Provider Status (reused in main settings + editor)

struct ProviderStatusView: View {
    let providerId: String
    let processingService: PromptProcessingService
    var cloudModel: Binding<String>?
    var onNavigateToIntegrations: (() -> Void)? = nil

    var body: some View {
        let plugin = PluginManager.shared.llmProvider(for: providerId)
        let setupStatus = plugin as? any LLMProviderSetupStatusProviding
        let usesLocalSetup = setupStatus?.requiresExternalCredentials == false

        if providerId == PromptProcessingService.appleIntelligenceId {
            if processingService.isAppleIntelligenceAvailable {
                Label(String(localized: "Available"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label(String(localized: "Not available - Apple Intelligence must be enabled in System Settings"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else {
            if processingService.isProviderReady(providerId) {
                Label(usesLocalSetup ? String(localized: "Ready") : String(localized: "API key configured"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if usesLocalSetup,
                      let unavailableReason = setupStatus?.unavailableReason {
                if let onNavigateToIntegrations {
                    Button {
                        onNavigateToIntegrations()
                    } label: {
                        Label(unavailableReason, systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Label(unavailableReason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if let onNavigateToIntegrations {
                Button {
                    onNavigateToIntegrations()
                } label: {
                    Label(String(localized: "API key required - configure in Integrations tab"), systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                Label(String(localized: "API key required - configure in Integrations tab"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let plugin {
                if let modelId = (plugin as? LLMModelSelectable)?.preferredModelId as? String {
                    // Plugin manages its own model selection - just show info
                    let displayName = plugin.supportedModels.first(where: { $0.id == modelId })?.displayName ?? modelId
                    HStack(spacing: 4) {
                        Text(String(localized: "Model:"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let cloudModel {
                    // Plugin without LLMModelSelectable - show picker as before
                    let models = plugin.supportedModels
                    if !models.isEmpty {
                        ModelPickerView(models: models, selection: cloudModel)
                    }
                }
            }
        }
    }
}

// MARK: - Model Picker with Search

struct ModelPickerView: View {
    let models: [PluginModelInfo]
    @Binding var selection: String
    @State private var searchText = ""

    private var filteredModels: [PluginModelInfo] {
        if searchText.isEmpty { return models }
        let query = searchText.lowercased()
        return models.filter {
            $0.displayName.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if models.count > 20 {
                TextField(String(localized: "Search models..."), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            Picker(String(localized: "Model"), selection: $selection) {
                ForEach(filteredModels, id: \.id) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .onAppear {
                ensureValidSelection()
            }
            .onChange(of: models.map(\.id)) {
                ensureValidSelection()
            }
        }
    }

    private func ensureValidSelection() {
        if selection.isEmpty || !models.contains(where: { $0.id == selection }) {
            selection = models.first?.id ?? ""
        }
    }
}

// MARK: - Prompt Action Card

private struct PromptActionCardView: View {
    let action: PromptAction
    @ObservedObject var viewModel: PromptActionsViewModel
    let processingService: PromptProcessingService
    @State private var isHovering = false
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16, height: 28)
                .opacity(isHovering ? 1 : 0)
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                Image(systemName: action.icon)
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(action.name)
                            .font(.callout)
                            .fontWeight(.medium)

                        if let providerName = action.providerType {
                            Text(processingService.displayName(for: providerName))
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundColor(.accentColor)
                                .cornerRadius(3)
                        }

                        if let actionId = action.targetActionPluginId,
                           let plugin = PluginManager.shared.actionPlugin(for: actionId) {
                            Text(plugin.actionName)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12))
                                .foregroundColor(.orange)
                                .cornerRadius(3)
                        }
                    }
                    Text(action.prompt)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.startEditing(action)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { action.isEnabled },
                set: { _ in viewModel.toggleAction(action) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Enable \(action.name)"))
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor.opacity(0.5) : isHovering ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: isDropTargeted ? 2 : 1)
        )
        .overlay(OpenHandCursorView())
        .onHover { hovering in
            isHovering = hovering
        }
        .draggable(action.id.uuidString)
        .dropDestination(for: String.self) { droppedItems, _ in
            guard let droppedId = droppedItems.first,
                  let fromIndex = viewModel.promptActions.firstIndex(where: { $0.id.uuidString == droppedId }),
                  let toIndex = viewModel.promptActions.firstIndex(where: { $0.id == action.id }) else {
                return false
            }
            viewModel.moveAction(fromIndex: fromIndex, toIndex: toIndex)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .contextMenu {
            Button(String(localized: "Edit")) {
                viewModel.startEditing(action)
            }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) {
                viewModel.deleteAction(action)
            }
        }
    }
}

// MARK: - Editor Sheet

private struct PromptActionEditorSheet: View {
    @ObservedObject var viewModel: PromptActionsViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    enum Field {
        case name, prompt
    }

    // Common SF Symbols for prompts
    private let iconOptions = [
        "sparkles", "globe", "textformat.abc", "text.badge.minus",
        "checkmark.circle", "envelope", "list.bullet", "scissors",
        "lightbulb", "pencil", "doc.text", "text.quote",
        "wand.and.stars", "arrow.triangle.2.circlepath", "text.magnifyingglass",
        "character.textbox", "checklist", "arrowshape.turn.up.left"
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(viewModel.isCreatingNew ? String(localized: "New Prompt") : String(localized: "Edit Prompt"))
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox(String(localized: "Prompt")) {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "Name"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField(String(localized: "e.g. Make Formal"), text: $viewModel.editName)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .name)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "System Prompt"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextEditor(text: $viewModel.editPrompt)
                                    .font(.body)
                                    .frame(height: 120)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                                    )
                                    .focused($focusedField, equals: .prompt)
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    GroupBox(String(localized: "Icon")) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 8), spacing: 8) {
                            ForEach(iconOptions, id: \.self) { icon in
                                Button {
                                    viewModel.editIcon = icon
                                } label: {
                                    Image(systemName: icon)
                                        .font(.system(size: 16))
                                        .frame(width: 32, height: 32)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(viewModel.editIcon == icon ? Color.accentColor.opacity(0.2) : Color.clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(viewModel.editIcon == icon ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(icon)
                                .accessibilityValue(viewModel.editIcon == icon ? String(localized: "Selected") : "")
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    GroupBox(String(localized: "LLM Provider")) {
                        let providers = viewModel.promptProcessingService.availableProviders
                        if providers.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "puzzlepiece.extension")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.secondary)
                                Text(String(localized: "Install an LLM provider plugin (e.g. Groq, OpenAI) to use prompts."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button(String(localized: "Go to Integrations")) {
                                    viewModel.navigateToIntegrations = true
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker(String(localized: "Provider"), selection: $viewModel.editProviderId) {
                                    Text(String(localized: "Default")).tag(nil as String?)
                                    ForEach(providers, id: \.id) { provider in
                                        Text(provider.displayName).tag(provider.id as String?)
                                    }
                                }
                                .onChange(of: viewModel.editProviderId) { _, newId in
                                    if let newId {
                                        let models = viewModel.promptProcessingService.modelsForProvider(newId)
                                        viewModel.editCloudModel = models.first?.id ?? ""
                                        viewModel.clampTemperatureValueForEffectiveProvider()
                                    } else {
                                        viewModel.editCloudModel = ""
                                        viewModel.clampTemperatureValueForEffectiveProvider()
                                    }
                                }

                                Text(String(localized: "Override the default provider for this prompt. Leave on \"Default\" to use the global setting."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if let selectedId = viewModel.editProviderId {
                                    let models = viewModel.promptProcessingService.modelsForProvider(selectedId)
                                    if !models.isEmpty {
                                        Picker(String(localized: "Model"), selection: $viewModel.editCloudModel) {
                                            ForEach(models, id: \.id) { model in
                                                Text(model.displayName).tag(model.id)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    GroupBox(String(localized: "Temperature")) {
                        let effectiveProviderId = viewModel.editProviderId ?? viewModel.promptProcessingService.selectedProviderId
                        let isAppleIntelligence = effectiveProviderId == PromptProcessingService.appleIntelligenceId
                        let supportedRange = viewModel.supportedTemperatureRange(for: effectiveProviderId)
                        VStack(alignment: .leading, spacing: 8) {
                            Picker(String(localized: "Who decides?"), selection: $viewModel.editTemperatureMode) {
                                Text(String(localized: "Use my provider setting")).tag(PluginLLMTemperatureMode.inheritProviderSetting)
                                Text(String(localized: "Use provider default")).tag(PluginLLMTemperatureMode.providerDefault)
                                Text(String(localized: "Set for this prompt")).tag(PluginLLMTemperatureMode.custom)
                            }
                            .disabled(isAppleIntelligence)

                            if viewModel.editTemperatureMode == .custom {
                                HStack {
                                    Text(String(localized: "Temperature"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(viewModel.editTemperatureValue, format: .number.precision(.fractionLength(2)))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }

                                Slider(
                                    value: $viewModel.editTemperatureValue,
                                    in: supportedRange,
                                    step: effectiveProviderId == "Gemma 4 (MLX)" ? 0.05 : 0.1
                                )
                                .disabled(isAppleIntelligence)

                                HStack {
                                    Text("\(supportedRange.lowerBound, format: .number.precision(.fractionLength(1)))")
                                    Spacer()
                                    Text("\(supportedRange.upperBound, format: .number.precision(.fractionLength(1)))")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            let helperText: LocalizedStringResource = {
                                if isAppleIntelligence {
                                    return "Temperature is not available for Apple Intelligence."
                                }

                                switch viewModel.editTemperatureMode {
                                case .inheritProviderSetting:
                                    return "Uses the temperature saved in this provider's settings."
                                case .providerDefault:
                                    return "Ignores your saved provider setting and lets the provider use its own default behavior."
                                case .custom:
                                    if effectiveProviderId == "Gemma 4 (MLX)" {
                                        return "Uses this value only for this prompt. Gemma 4 supports values from 0.0 to 1.0."
                                    } else {
                                        return "Uses this value only for this prompt and overrides the provider setting."
                                    }
                                }
                            }()

                            Text(helperText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    let actionPlugins = PluginManager.shared.actionPlugins
                    if !actionPlugins.isEmpty {
                        GroupBox(String(localized: "Action Target")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker(String(localized: "Target"), selection: $viewModel.editTargetActionPluginId) {
                                    Text(String(localized: "Insert Text")).tag(nil as String?)
                                    ForEach(actionPlugins, id: \.actionId) { plugin in
                                        Label(plugin.actionName, systemImage: plugin.actionIcon)
                                            .tag(plugin.actionId as String?)
                                    }
                                }

                                Text(String(localized: "Instead of inserting the LLM result as text, send it to an action plugin."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Button(String(localized: "Cancel")) {
                    viewModel.cancelEditing()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "Save")) {
                    viewModel.saveEditing()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.editName.isEmpty || viewModel.editPrompt.isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 450, idealWidth: 500, minHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            focusedField = .name
        }
    }
}

// MARK: - Drag Handle Cursor

private struct OpenHandCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CursorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class CursorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
