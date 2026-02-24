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

                    Button {
                        viewModel.showingPresetLibrary = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .help(String(localized: "Preset Library"))

                    Button {
                        viewModel.startCreating()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help(String(localized: "Add new prompt"))
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
        .sheet(isPresented: $viewModel.showingPresetLibrary) {
            PresetLibrarySheet(viewModel: viewModel)
        }
        .alert(String(localized: "Error"), isPresented: Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button(String(localized: "OK")) { viewModel.clearError() }
        } message: {
            Text(viewModel.error ?? "")
        }
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        GroupBox(String(localized: "Default LLM Provider")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(String(localized: "Provider"), selection: $processingService.selectedProviderId) {
                    ForEach(processingService.availableProviders, id: \.id) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }
                .onChange(of: processingService.selectedProviderId) { _, newId in
                    // Reset cloud model when switching providers
                    let models = processingService.modelsForProvider(newId)
                    processingService.selectedCloudModel = models.first?.id ?? ""
                }

                ProviderStatusView(
                    providerId: processingService.selectedProviderId,
                    processingService: processingService,
                    cloudModel: $processingService.selectedCloudModel
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Empty State

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
                    Button {
                        viewModel.showingPresetLibrary = true
                    } label: {
                        Label(String(localized: "Preset Library"), systemImage: "sparkles")
                    }
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

    var body: some View {
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
                Label(String(localized: "API key configured"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label(String(localized: "API key required - configure in Integrations tab"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            let models = processingService.modelsForProvider(providerId)
            if let cloudModel, !models.isEmpty {
                Picker(String(localized: "Model"), selection: cloudModel) {
                    ForEach(models, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .onAppear {
                    if cloudModel.wrappedValue.isEmpty || !models.contains(where: { $0.id == cloudModel.wrappedValue }) {
                        cloudModel.wrappedValue = models.first?.id ?? ""
                    }
                }
            }
        }
    }
}

// MARK: - Prompt Action Card

private struct PromptActionCardView: View {
    let action: PromptAction
    @ObservedObject var viewModel: PromptActionsViewModel
    let processingService: PromptProcessingService
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)

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

            Spacer()

            if action.isPreset {
                Text(String(localized: "Preset"))
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundColor(.secondary)
                    .cornerRadius(3)
            }

            Toggle("", isOn: Binding(
                get: { action.isEnabled },
                set: { _ in viewModel.toggleAction(action) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .onTapGesture {}
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHovering ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            viewModel.startEditing(action)
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
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    GroupBox(String(localized: "LLM Provider")) {
                        VStack(alignment: .leading, spacing: 8) {
                            let providers = viewModel.promptProcessingService.availableProviders
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
                                } else {
                                    viewModel.editCloudModel = ""
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

// MARK: - Preset Library Sheet

private struct PresetLibrarySheet: View {
    @ObservedObject var viewModel: PromptActionsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Preset Library"))
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(PromptAction.presets, id: \.name) { preset in
                        PresetLibraryRow(preset: preset, viewModel: viewModel)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 400, idealWidth: 440, minHeight: 340, idealHeight: 400)
    }
}

private struct PresetLibraryRow: View {
    let preset: PromptAction
    @ObservedObject var viewModel: PromptActionsViewModel
    @State private var justAdded = false

    private var isAdded: Bool {
        viewModel.isPresetAdded(preset)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: preset.icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.callout)
                    .fontWeight(.medium)
                Text(preset.prompt)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isAdded || justAdded {
                Label(String(localized: "Added"), systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(String(localized: "Add")) {
                    viewModel.addPreset(preset)
                    justAdded = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
