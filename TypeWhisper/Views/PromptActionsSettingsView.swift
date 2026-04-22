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
            providerSection
                .padding(.horizontal, 8)
                .padding(.bottom, 12)

            Divider()
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 16) {
                promptsHeader

                if viewModel.promptActions.isEmpty {
                    emptyState
                } else {
                    promptsList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .sheet(isPresented: $viewModel.isEditing) {
            PromptWizardSheet(viewModel: viewModel, processingService: processingService)
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

    private var promptsHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedAppText("Prompts", de: "Prompts"))
                    .font(.headline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Build reusable AI actions for Rules or the Prompt Palette."))
                    Text(String(localized: "Prompts run automatically during dictation only when a rule assigns them. Without a rule, they remain available via the Prompt Palette."))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.startCreating()
            } label: {
                Label(localizedAppText("New Prompt", de: "Neuer Prompt"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        let providers = processingService.availableProviders
        let statusInfo = promptProviderStatusInfo(
            providerId: processingService.selectedProviderId,
            processingService: processingService
        )
        let fixedModelName = promptProviderFixedModelName(for: processingService.selectedProviderId)
        let shouldShowModelPicker = fixedModelName == nil && !processingService.modelsForProvider(processingService.selectedProviderId).isEmpty

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizedAppText("Default LLM Provider", de: "Standard-LLM-Provider"))
                        .font(.headline)
                    Text(localizedAppText(
                        "Used by prompts unless a prompt overrides provider or model in Advanced.",
                        de: "Wird von Prompts genutzt, solange ein Prompt Provider oder Modell nicht unter Erweitert überschreibt."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if !providers.isEmpty, let statusInfo {
                    PromptProviderStatusChip(statusInfo: statusInfo) {
                        if statusInfo.isActionable {
                            viewModel.navigateToIntegrations = true
                        }
                    }
                }
            }

            if providers.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Install an LLM provider plugin (e.g. Groq, OpenAI) to use prompts."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button(String(localized: "Go to Integrations")) {
                            viewModel.navigateToIntegrations = true
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(localizedAppText("Provider", de: "Provider"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .leading)

                        Picker(String(localized: "Provider"), selection: $processingService.selectedProviderId) {
                            ForEach(providers, id: \.id) { provider in
                                Text(provider.displayName).tag(provider.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240, alignment: .leading)

                        Spacer()
                    }

                    if let detail = statusInfo?.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(statusInfo?.tint ?? .secondary)
                    }

                    if let fixedModelName {
                        HStack(spacing: 6) {
                            Text(localizedAppText("Model", de: "Modell"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(fixedModelName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if shouldShowModelPicker {
                        HStack(alignment: .center, spacing: 12) {
                            Text(localizedAppText("Model", de: "Modell"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .leading)

                            ModelPickerView(
                                models: processingService.modelsForProvider(processingService.selectedProviderId),
                                selection: $processingService.selectedCloudModel
                            )
                            .frame(maxWidth: 320, alignment: .leading)

                            Spacer()
                        }
                    }

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
            }
        }
        .padding(16)
        .background {
            promptWizardGroupedListSurface(cornerRadius: 16)
        }
    }

    private var promptsList: some View {
        let indexedActions = Array(viewModel.promptActions.enumerated())

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.shouldShowRuleAssignmentCallout,
                   let action = viewModel.pendingRuleAssignmentPrompt {
                    PromptRuleAssignmentCallout(action: action, viewModel: viewModel)
                }

                LazyVStack(spacing: 0) {
                    ForEach(indexedActions, id: \.element.id) { index, action in
                        PromptActionRow(action: action, viewModel: viewModel, processingService: processingService)

                        if index < indexedActions.count - 1 {
                            Divider()
                                .padding(.leading, 64)
                        }
                    }
                }
                .background {
                    promptWizardGroupedListSurface(cornerRadius: 14)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(localizedAppText("No Prompts Yet", de: "Noch keine Prompts"), systemImage: "sparkles")
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                Text(localizedAppText(
                    "Build reusable prompt actions with the same wizard style as Rules.",
                    de: "Baue wiederverwendbare Prompt-Aktionen im gleichen Wizard-Stil wie bei den Regeln."
                ))
                Text(localizedAppText(
                    "Examples: translate English/German, draft a reply, extract JSON, or turn notes into meeting notes.",
                    de: "Beispiele: Englisch/Deutsch übersetzen, eine Antwort formulieren, JSON extrahieren oder Notizen in Meeting Notes umwandeln."
                ))
                Text(String(localized: "Prompts become automatic during dictation only when a rule assigns them. Otherwise they stay available from the Prompt Palette."))
            }
        }
        actions: {
            Button(localizedAppText("Create First Prompt", de: "Ersten Prompt erstellen")) {
                viewModel.startCreating()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .background {
            promptWizardGroupedListSurface(cornerRadius: 16)
        }
    }
}

// MARK: - Provider Status (reused in main settings + editor)

@MainActor
private struct PromptProviderStatusInfo {
    let title: String
    let detail: String?
    let icon: String
    let tint: Color
    let isActionable: Bool
}

@MainActor
private struct PromptProviderStatusChip: View {
    let statusInfo: PromptProviderStatusInfo
    let action: () -> Void

    var body: some View {
        Group {
            if statusInfo.isActionable {
                Button(action: action) {
                    chipLabel
                }
                .buttonStyle(.plain)
            } else {
                chipLabel
            }
        }
    }

    private var chipLabel: some View {
        Label(statusInfo.title, systemImage: statusInfo.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusInfo.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(statusInfo.tint.opacity(0.14), in: Capsule())
    }
}

@MainActor
private func promptProviderStatusInfo(
    providerId: String,
    processingService: PromptProcessingService
) -> PromptProviderStatusInfo? {
    if providerId == PromptProcessingService.appleIntelligenceId {
        if processingService.isAppleIntelligenceAvailable {
            return .init(
                title: localizedAppText("Ready", de: "Bereit"),
                detail: nil,
                icon: "checkmark.circle.fill",
                tint: .green,
                isActionable: false
            )
        }

        return .init(
            title: localizedAppText("Unavailable", de: "Nicht verfügbar"),
            detail: localizedAppText(
                "Apple Intelligence must be enabled in System Settings.",
                de: "Apple Intelligence muss in den Systemeinstellungen aktiviert sein."
            ),
            icon: "exclamationmark.triangle.fill",
            tint: .orange,
            isActionable: false
        )
    }

    let plugin = PluginManager.shared.llmProvider(for: providerId)
    let setupStatus = plugin as? any LLMProviderSetupStatusProviding
    let usesLocalSetup = setupStatus?.requiresExternalCredentials == false

    if processingService.isProviderReady(providerId) {
        return .init(
            title: usesLocalSetup
                ? localizedAppText("Ready", de: "Bereit")
                : localizedAppText("Configured", de: "Konfiguriert"),
            detail: nil,
            icon: "checkmark.circle.fill",
            tint: .green,
            isActionable: false
        )
    }

    if usesLocalSetup, let unavailableReason = setupStatus?.unavailableReason {
        return .init(
            title: localizedAppText("Needs Setup", de: "Setup nötig"),
            detail: unavailableReason,
            icon: "exclamationmark.triangle.fill",
            tint: .orange,
            isActionable: true
        )
    }

    return .init(
        title: localizedAppText("API Key Needed", de: "API-Key nötig"),
        detail: localizedAppText(
            "Configure the provider in Integrations.",
            de: "Konfiguriere den Provider unter Integrationen."
        ),
        icon: "exclamationmark.triangle.fill",
        tint: .orange,
        isActionable: true
    )
}

@MainActor
private func promptProviderFixedModelName(for providerId: String) -> String? {
    guard providerId != PromptProcessingService.appleIntelligenceId,
          let plugin = PluginManager.shared.llmProvider(for: providerId),
          let modelId = (plugin as? LLMModelSelectable)?.preferredModelId as? String else {
        return nil
    }

    return plugin.supportedModels.first(where: { $0.id == modelId })?.displayName ?? modelId
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

// MARK: - Prompt Action List

private struct PromptActionRow: View {
    let action: PromptAction
    @ObservedObject var viewModel: PromptActionsViewModel
    let processingService: PromptProcessingService
    @State private var isHovering = false

    var body: some View {
        let assignmentStatus = viewModel.assignmentStatus(for: action)
        let matchingRules = viewModel.rulesUsing(action)

        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 36, height: 36)

                Image(systemName: action.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(action.name)
                    .font(.headline)

                Text(promptNarrative)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(providerSummary)

                    if let targetSummary {
                        Text("•")
                        Text(targetSummary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if assignmentStatus.isAssigned {
                        Button {
                            viewModel.showRules(for: action)
                        } label: {
                            PromptRuleAssignmentChip(
                                title: viewModel.assignmentSummary(for: action),
                                isAssigned: true
                            )
                        }
                        .buttonStyle(.plain)
                        .help(localizedAppText("Show matching rules", de: "Passende Regeln anzeigen"))
                    } else {
                        PromptRuleAssignmentChip(
                            title: viewModel.assignmentSummary(for: action),
                            isAssigned: false
                        )
                    }

                    if !assignmentStatus.isAssigned {
                        Button(String(localized: "Create Rule")) {
                            viewModel.createRule(for: action)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                if !matchingRules.isEmpty {
                    PromptRuleUsageLinks(profiles: matchingRules, viewModel: viewModel)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { action.isEnabled },
                    set: { _ in viewModel.toggleAction(action) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(String(localized: "Enable \(action.name)"))

                Button {
                    viewModel.startEditing(action)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .opacity(isHovering ? 1 : 0.7)
                .help(localizedAppText("Edit prompt", de: "Prompt bearbeiten"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowHighlightColor)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(count: 2) {
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

    private var promptNarrative: String {
        let inferredDraft = PromptWizardInferenceService.infer(from: action)
        return PromptWizardComposer.reviewSummary(for: inferredDraft)
    }

    private var providerSummary: String {
        if let providerType = action.providerType {
            return localizedAppText(
                "Provider: \(processingService.displayName(for: providerType))",
                de: "Provider: \(processingService.displayName(for: providerType))"
            )
        }

        return localizedAppText("Default provider", de: "Standard-Provider")
    }

    private var targetSummary: String? {
        guard let actionId = action.targetActionPluginId,
              let plugin = PluginManager.shared.actionPlugin(for: actionId) else {
            return nil
        }

        return localizedAppText(
            "Target: \(plugin.actionName)",
            de: "Ziel: \(plugin.actionName)"
        )
    }

    private var rowHighlightColor: Color {
        if isHovering {
            return Color.white.opacity(0.025)
        }

        return Color.clear
    }
}

private struct PromptRuleAssignmentCallout: View {
    let action: PromptAction
    @ObservedObject var viewModel: PromptActionsViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.orange.opacity(0.16))
                    .frame(width: 36, height: 36)

                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Prompt saved. Create a rule to run it automatically during dictation."))
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "Without a rule, prompts remain available via the Prompt Palette."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(String(localized: "Create Rule")) {
                    viewModel.createRule(for: action)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    viewModel.dismissRuleAssignmentCallout()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct PromptRuleAssignmentChip: View {
    let title: String
    let isAssigned: Bool

    var body: some View {
        let tint: Color = isAssigned ? .green : .orange

        Label(title, systemImage: isAssigned ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct PromptRuleUsageLinks: View {
    let profiles: [Profile]
    @ObservedObject var viewModel: PromptActionsViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(profiles) { profile in
                    Button(profile.name) {
                        viewModel.openRule(profile)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Prompt Wizard

private struct PromptWizardSheet: View {
    @ObservedObject var viewModel: PromptActionsViewModel
    @ObservedObject var processingService: PromptProcessingService
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdvancedOptions = false

    private let iconOptions = [
        "sparkles", "globe", "wand.and.stars", "arrowshape.turn.up.left",
        "envelope", "envelope.badge", "list.bullet", "checklist",
        "tablecells", "curlybraces", "doc.text.magnifyingglass", "textformat.abc",
        "text.quote", "pencil", "lightbulb", "character.textbox"
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PromptWizardStepHeader(currentStep: viewModel.wizardStep)

                    switch viewModel.wizardStep {
                    case .goal:
                        PromptWizardGoalStep(viewModel: viewModel)
                    case .response:
                        PromptWizardResponseStep(viewModel: viewModel, processingService: processingService)
                    case .review:
                        PromptWizardReviewStep(
                            viewModel: viewModel,
                            showingAdvancedOptions: $showingAdvancedOptions,
                            iconOptions: iconOptions
                        )
                    }
                }
                .padding(24)
            }

            Divider()

            footer
        }
        .frame(width: 700, height: 790)
        .background(sheetBackground)
        .onAppear {
            showingAdvancedOptions = viewModel.manualPromptOverride || viewModel.editTargetActionPluginId != nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                promptWizardInfoChip(
                    viewModel.isCreatingNew
                        ? localizedAppText("Prompt Wizard", de: "Prompt-Wizard")
                        : localizedAppText("Adjust Prompt", de: "Prompt anpassen"),
                    tint: .accentColor
                )

                Text(
                    viewModel.isCreatingNew
                        ? localizedAppText("New Prompt", de: "Neuer Prompt")
                        : localizedAppText("Edit Prompt", de: "Prompt bearbeiten")
                )
                .font(.title2.weight(.semibold))

                Text(localizedAppText(
                    "From goal to final system prompt in three clear steps.",
                    de: "Vom Ziel zum finalen System-Prompt in drei klaren Schritten."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                promptWizardInfoChip(
                    localizedAppText(
                        "Step \(currentStepNumber) of \(totalSteps)",
                        de: "Schritt \(currentStepNumber) von \(totalSteps)"
                    ),
                    tint: .accentColor
                )
            }
        }
        .padding(24)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedAppText(
                    "Step \(currentStepNumber) of \(totalSteps)",
                    de: "Schritt \(currentStepNumber) von \(totalSteps)"
                ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Text(stepGuidance)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button(localizedAppText("Cancel", de: "Abbrechen")) {
                viewModel.cancelEditing()
                dismiss()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            if viewModel.wizardStep != .goal {
                Button(localizedAppText("Back", de: "Zurück")) {
                    viewModel.goToPreviousWizardStep()
                }
                .buttonStyle(.bordered)
            }

            if viewModel.wizardStep == .review {
                Button(localizedAppText("Save Prompt", de: "Prompt speichern")) {
                    viewModel.saveEditing()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 10))
                .controlSize(.large)
                .tint(.accentColor)
                .shadow(color: .accentColor.opacity(0.18), radius: 8, x: 0, y: 4)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canAdvanceFromCurrentWizardStep)
            } else {
                Button(localizedAppText("Next", de: "Weiter")) {
                    viewModel.goToNextWizardStep()
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 10))
                .controlSize(.large)
                .tint(.accentColor)
                .shadow(color: .accentColor.opacity(0.18), radius: 8, x: 0, y: 4)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canAdvanceFromCurrentWizardStep)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.bar)
    }

    private var currentStepNumber: Int { viewModel.wizardStep.rawValue + 1 }
    private var totalSteps: Int { PromptWizardStep.allCases.count }

    private var stepGuidance: String {
        switch viewModel.wizardStep {
        case .goal:
            return localizedAppText(
                "Pick the job first. Presets can be used as starters and refined in the next step.",
                de: "Wähle zuerst die Aufgabe. Presets dienen als Starter und werden im nächsten Schritt verfeinert."
            )
        case .response:
            return localizedAppText(
                "Define the response behavior first. Advanced includes provider, model, and temperature.",
                de: "Lege zuerst das Antwortverhalten fest. Erweitert enthält Provider, Modell und Temperatur."
            )
        case .review:
            return localizedAppText(
                "Review the name and preview first. Advanced includes the system prompt and target.",
                de: "Prüfe zuerst Name und Vorschau. Erweitert enthält System-Prompt und Ziel."
            )
        }
    }

    private var sheetBackground: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)

            Rectangle()
                .fill(Color.accentColor.opacity(0.028))
                .frame(height: 150)
                .blur(radius: 30)
                .offset(y: -18)
        }
    }
}

private struct PromptWizardStepHeader: View {
    let currentStep: PromptWizardStep

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(PromptWizardStep.allCases.enumerated()), id: \.element.rawValue) { index, step in
                stepItem(for: step)

                if index < PromptWizardStep.allCases.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func stepItem(for step: PromptWizardStep) -> some View {
        let isCurrent = step == currentStep
        let isCompleted = step.rawValue < currentStep.rawValue
        let isReachable = step.rawValue <= currentStep.rawValue

        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(stepCircleFill(isCurrent: isCurrent, isCompleted: isCompleted))
                    .frame(width: 30, height: 30)

                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(isCurrent ? .white : .primary)
                }
            }

            Text(step.title)
                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(stepTitleStyle(isCurrent: isCurrent, isReachable: isReachable))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(stepBackground(isCurrent: isCurrent, isCompleted: isCompleted), in: Capsule())
    }

    private func stepCircleFill(isCurrent: Bool, isCompleted: Bool) -> some ShapeStyle {
        if isCurrent {
            return AnyShapeStyle(Color.accentColor)
        }

        if isCompleted {
            return AnyShapeStyle(Color.accentColor.opacity(0.82))
        }

        return AnyShapeStyle(Color.primary.opacity(0.10))
    }

    private func stepBackground(isCurrent: Bool, isCompleted: Bool) -> some ShapeStyle {
        if isCurrent {
            return AnyShapeStyle(Color.accentColor.opacity(0.14))
        }

        if isCompleted {
            return AnyShapeStyle(Color.accentColor.opacity(0.07))
        }

        return AnyShapeStyle(Color.clear)
    }

    private func stepTitleStyle(isCurrent: Bool, isReachable: Bool) -> some ShapeStyle {
        if isCurrent {
            return AnyShapeStyle(Color.accentColor)
        }

        return AnyShapeStyle(isReachable ? .primary : .secondary)
    }
}

private struct PromptWizardGoalStep: View {
    @ObservedObject var viewModel: PromptActionsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localizedAppText("What should this prompt do?", de: "Was soll dieser Prompt tun?"))
                    .font(.title3.weight(.semibold))
                Text(localizedAppText(
                    "Pick the job first. Details and presets appear only for the active goal.",
                    de: "Wähle zuerst die Aufgabe. Details und Presets erscheinen nur für das aktive Ziel."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(PromptWizardGoal.allCases, id: \.self) { goal in
                        Button {
                            viewModel.setWizardGoal(goal)
                        } label: {
                            PromptWizardGoalRow(goal: goal, isSelected: viewModel.wizardDraft.goal == goal)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 220, alignment: .topLeading)

                PromptWizardGoalDetailPanel(
                    goal: viewModel.wizardDraft.goal,
                    starters: Array(viewModel.starterPresets(for: viewModel.wizardDraft.goal).prefix(3)),
                    onSelectPreset: viewModel.applyPresetStarter
                )
            }
        }
    }
}

private struct PromptWizardGoalRow: View {
    let goal: PromptWizardGoal
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(goal.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .primary)

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(promptWizardActiveSelectionFill()) : AnyShapeStyle(Color.white.opacity(0.03)))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.42) : Color.white.opacity(0.05), lineWidth: isSelected ? 1.2 : 1)
                }
                .shadow(color: .black.opacity(isSelected ? 0.18 : 0.08), radius: isSelected ? 14 : 8, x: 0, y: isSelected ? 8 : 4)
        }
    }
}

private struct PromptWizardGoalDetailPanel: View {
    let goal: PromptWizardGoal
    let starters: [PromptAction]
    let onSelectPreset: (PromptAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localizedAppText("Selected Goal", de: "Ausgewähltes Ziel"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                Text(goal.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(goal.promptWizardGoalSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !starters.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(localizedAppText("Starter Presets", de: "Starter-Presets"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)

                    HStack(spacing: 8) {
                        ForEach(starters, id: \.name) { preset in
                            Button {
                                onSelectPreset(preset)
                            } label: {
                                Text(preset.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                                    .overlay {
                                        Capsule()
                                            .strokeBorder(Color.accentColor.opacity(0.20), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Text(localizedAppText(
                "You can shape tone, format, language behavior, and model settings in the next step.",
                de: "Ton, Format, Sprachverhalten und Modell-Einstellungen formst du im nächsten Schritt."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background { promptWizardElevatedPanel(cornerRadius: 20) }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct PromptWizardResponseStep: View {
    @ObservedObject var viewModel: PromptActionsViewModel
    @ObservedObject var processingService: PromptProcessingService
    @State private var showingAdvancedOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localizedAppText("How should it respond?", de: "Wie soll es antworten?"))
                    .font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    promptWizardInfoChip(viewModel.wizardDraft.goal.title, tint: .accentColor)

                    Text(localizedAppText(
                        "Configure behavior first, then fine-tune the model settings for this prompt.",
                        de: "Konfiguriere zuerst das Verhalten und verfeinere danach die Modell-Einstellungen für diesen Prompt."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }

            behaviorSection
            advancedSection
        }
    }

    private var behaviorSection: some View {
        promptWizardCompactSection(
            title: behaviorSectionTitle,
            description: behaviorSectionDescription
        ) {
            goalSpecificSectionContent
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showingAdvancedOptions.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localizedAppText("Advanced", de: "Erweitert"))
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(advancedSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: showingAdvancedOptions ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingAdvancedOptions {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                        .padding(.top, 12)

                    promptWizardEditorSubsection(
                        title: localizedAppText("Provider", de: "Provider"),
                        description: localizedAppText(
                            "Override the default provider only when this prompt needs a different model stack.",
                            de: "Überschreibe den Standard-Provider nur, wenn dieser Prompt einen anderen Modell-Stack braucht."
                        )
                    ) {
                        providerSettingsContent
                    }

                    Divider()

                    promptWizardEditorSubsection(
                        title: localizedAppText("Temperature", de: "Temperatur"),
                        description: localizedAppText(
                            "Keep this on the provider default unless this prompt needs a different creativity level.",
                            de: "Lass dies beim Provider-Standard, außer dieser Prompt braucht ein anderes Kreativitätsniveau."
                        )
                    ) {
                        temperatureSettingsContent
                    }
                }
            }
        }
        .padding(16)
        .background {
            promptWizardElevatedPanel(cornerRadius: 18)
        }
    }

    @ViewBuilder
    private var goalSpecificSectionContent: some View {
        switch viewModel.wizardDraft.goal {
        case .translate:
            VStack(alignment: .leading, spacing: 14) {
                promptWizardEditorSubsection(
                    title: localizedAppText("Mode", de: "Modus"),
                    description: localizedAppText(
                        "Choose whether this prompt always translates into one language or toggles between a fixed pair.",
                        de: "Lege fest, ob dieser Prompt immer in eine Sprache übersetzt oder zwischen einem festen Paar wechselt."
                    )
                ) {
                    Picker(
                        localizedAppText("Mode", de: "Modus"),
                        selection: translationModeChoiceBinding
                    ) {
                        Text(localizedAppText("One Target", de: "Eine Zielsprache")).tag(PromptWizardTranslationChoice.direct)
                        Text(localizedAppText("Two-Way Pair", de: "Zwei-Wege-Paar")).tag(PromptWizardTranslationChoice.alternating)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.large)
                }

                Divider()

                promptWizardEditorSubsection(
                    title: localizedAppText("Languages", de: "Sprachen"),
                    description: localizedAppText(
                        "Set the target language or the two fixed languages for the pair.",
                        de: "Lege die Zielsprache oder die beiden festen Sprachen für das Paar fest."
                    )
                ) {
                    switch viewModel.wizardDraft.translationMode {
                    case .alternatingPair:
                        HStack(spacing: 14) {
                            promptWizardLanguagePicker(
                                title: localizedAppText("Primary Language", de: "Primärsprache"),
                                selection: alternatingPrimaryLanguageBinding
                            )
                            promptWizardLanguagePicker(
                                title: localizedAppText("Secondary Language", de: "Sekundärsprache"),
                                selection: alternatingSecondaryLanguageBinding
                            )
                        }
                    case .direct, .none:
                        promptWizardLanguagePicker(
                            title: localizedAppText("Target Language", de: "Zielsprache"),
                            selection: directTargetLanguageBinding
                        )
                    }
                }

                Divider()

                promptWizardEditorSubsection(
                    title: localizedAppText("Output Rules", de: "Ausgaberegeln")
                ) {
                    Toggle(
                        localizedAppText("Preserve formatting when possible", de: "Formatierung wenn möglich beibehalten"),
                        isOn: Binding(
                            get: { viewModel.wizardDraft.preserveFormatting },
                            set: { newValue in
                                viewModel.updateWizardDraft { draft in
                                    draft.preserveFormatting = newValue
                                }
                            }
                        )
                    )
                }
            }
        case .rewrite:
            VStack(alignment: .leading, spacing: 14) {
                promptWizardEditorSubsection(title: localizedAppText("Tone", de: "Ton")) {
                    promptWizardTonePicker(tone: toneBinding)
                }

                Divider()

                promptWizardEditorSubsection(title: localizedAppText("Language", de: "Sprache")) {
                    promptWizardLanguageModeSection(mode: languageChoiceBinding, targetLanguage: targetLanguageBinding)
                }

                Divider()

                promptWizardEditorSubsection(title: localizedAppText("Output", de: "Ausgabe")) {
                    Picker(localizedAppText("Output", de: "Ausgabe"), selection: rewriteFormatBinding) {
                        Text(localizedAppText("Paragraph", de: "Absatz")).tag(PromptWizardRewriteFormat.paragraph)
                        Text(localizedAppText("List", de: "Liste")).tag(PromptWizardRewriteFormat.list)
                    }
                    .pickerStyle(.segmented)
                }
            }
        case .replyEmail:
            VStack(alignment: .leading, spacing: 14) {
                promptWizardEditorSubsection(title: localizedAppText("Mode", de: "Modus")) {
                    Picker(localizedAppText("Mode", de: "Modus"), selection: replyModeBinding) {
                        Text(localizedAppText("Reply", de: "Antwort")).tag(PromptWizardReplyMode.reply)
                        Text(localizedAppText("Email", de: "E-Mail")).tag(PromptWizardReplyMode.email)
                    }
                    .pickerStyle(.segmented)
                }

                Divider()

                promptWizardEditorSubsection(title: localizedAppText("Tone", de: "Ton")) {
                    promptWizardTonePicker(tone: toneBinding)
                }

                Divider()

                promptWizardEditorSubsection(title: localizedAppText("Length", de: "Länge")) {
                    Picker(localizedAppText("Length", de: "Länge"), selection: responseLengthBinding) {
                        Text(localizedAppText("Short", de: "Kurz")).tag(PromptWizardResponseLength.short)
                        Text(localizedAppText("Balanced", de: "Ausgewogen")).tag(PromptWizardResponseLength.medium)
                        Text(localizedAppText("Detailed", de: "Detailliert")).tag(PromptWizardResponseLength.detailed)
                    }
                    .pickerStyle(.segmented)
                }

                Divider()

                promptWizardEditorSubsection(title: localizedAppText("Language", de: "Sprache")) {
                    promptWizardLanguageModeSection(mode: languageChoiceBinding, targetLanguage: targetLanguageBinding)
                }
            }
        case .extract:
            promptWizardEditorSubsection(title: localizedAppText("Output Format", de: "Ausgabeformat")) {
                Picker(localizedAppText("Format", de: "Format"), selection: extractFormatBinding) {
                    Text(localizedAppText("Checklist", de: "Checkliste")).tag(PromptWizardExtractFormat.checklist)
                    Text("JSON").tag(PromptWizardExtractFormat.json)
                    Text(localizedAppText("Table", de: "Tabelle")).tag(PromptWizardExtractFormat.table)
                    Text(localizedAppText("Key Points", de: "Kernpunkte")).tag(PromptWizardExtractFormat.keyPoints)
                }
                .pickerStyle(.segmented)
            }
        case .structure:
            VStack(alignment: .leading, spacing: 14) {
                promptWizardEditorSubsection(title: localizedAppText("Output Format", de: "Ausgabeformat")) {
                    Picker(localizedAppText("Format", de: "Format"), selection: structureFormatBinding) {
                        Text(localizedAppText("Bullet List", de: "Bullet-Liste")).tag(PromptWizardStructureFormat.bulletList)
                        Text(localizedAppText("Meeting Notes", de: "Meeting Notes")).tag(PromptWizardStructureFormat.meetingNotes)
                        Text(localizedAppText("Table", de: "Tabelle")).tag(PromptWizardStructureFormat.table)
                        Text("JSON").tag(PromptWizardStructureFormat.json)
                    }
                    .pickerStyle(.segmented)
                }

                Divider()

                promptWizardEditorSubsection(title: localizedAppText("Output Rules", de: "Ausgaberegeln")) {
                    Toggle(
                        localizedAppText("Add helpful headings when useful", de: "Hilfreiche Überschriften ergänzen"),
                        isOn: Binding(
                            get: { viewModel.wizardDraft.includeHeadings },
                            set: { newValue in
                                viewModel.updateWizardDraft { draft in
                                    draft.includeHeadings = newValue
                                }
                            }
                        )
                    )
                }
            }
        case .custom:
            VStack(alignment: .leading, spacing: 14) {
                promptWizardEditorSubsection(title: localizedAppText("Goal", de: "Ziel")) {
                    TextEditor(text: Binding(
                        get: { viewModel.wizardDraft.customGoal },
                        set: { newValue in
                            viewModel.updateWizardDraft { draft in
                                draft.customGoal = newValue
                            }
                        }
                    ))
                    .font(.body)
                    .frame(height: 80)
                    .padding(8)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                    }
                }

                Divider()

                promptWizardEditorSubsection(title: localizedAppText("Tone", de: "Ton")) {
                    promptWizardTonePicker(tone: toneBinding)
                }

                Divider()

                promptWizardEditorSubsection(title: localizedAppText("Language", de: "Sprache")) {
                    promptWizardLanguageModeSection(mode: languageChoiceBinding, targetLanguage: targetLanguageBinding)
                }

                Divider()

                promptWizardEditorSubsection(title: localizedAppText("Output Hint", de: "Ausgabehinweis")) {
                    TextField(
                        localizedAppText("e.g. Return a short bullet list", de: "z. B. Gib eine kurze Bullet-Liste zurück"),
                        text: Binding(
                            get: { viewModel.wizardDraft.customOutputHint },
                            set: { newValue in
                                viewModel.updateWizardDraft { draft in
                                    draft.customOutputHint = newValue
                                }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var providerSettingsContent: some View {
        let providers = processingService.availableProviders

        return VStack(alignment: .leading, spacing: 12) {
            Text(localizedAppText("Provider", de: "Provider"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if providers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(localizedAppText(
                        "Install an LLM provider plugin such as Groq or OpenAI to use prompt actions.",
                        de: "Installiere ein LLM-Provider-Plugin wie Groq oder OpenAI, um Prompt-Aktionen zu nutzen."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    Button(localizedAppText("Go to Integrations", de: "Zu Integrationen")) {
                        viewModel.navigateToIntegrations = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                Picker(localizedAppText("Provider", de: "Provider"), selection: providerBinding) {
                    Text(localizedAppText("Default", de: "Standard")).tag(nil as String?)
                    ForEach(providers, id: \.id) { provider in
                        Text(provider.displayName).tag(provider.id as String?)
                    }
                }

                Text(localizedAppText(
                    "When left on Default, this prompt uses the provider selected above in Prompts settings.",
                    de: "Bei Standard nutzt dieser Prompt den oben in den Prompt-Einstellungen gewählten Provider."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                if let selectedId = viewModel.editProviderId {
                    let models = processingService.modelsForProvider(selectedId)
                    if !models.isEmpty {
                        Picker(localizedAppText("Model", de: "Modell"), selection: cloudModelBinding) {
                            ForEach(models, id: \.id) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                    }
                } else {
                    Text(localizedAppText(
                        "Uses the global default provider: \(processingService.displayName(for: processingService.selectedProviderId)).",
                        de: "Verwendet den globalen Standard-Provider: \(processingService.displayName(for: processingService.selectedProviderId))."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var temperatureSettingsContent: some View {
        let effectiveProviderId = viewModel.editProviderId ?? processingService.selectedProviderId
        let isAppleIntelligence = effectiveProviderId == PromptProcessingService.appleIntelligenceId
        let supportedRange = viewModel.supportedTemperatureRange(for: effectiveProviderId)

        return VStack(alignment: .leading, spacing: 12) {
            Text(localizedAppText("Temperature", de: "Temperatur"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker(localizedAppText("Who decides?", de: "Wer entscheidet?"), selection: temperatureModeBinding) {
                Text(localizedAppText("Use my provider setting", de: "Meine Provider-Einstellung")).tag(PluginLLMTemperatureMode.inheritProviderSetting)
                Text(localizedAppText("Use provider default", de: "Provider-Standard")).tag(PluginLLMTemperatureMode.providerDefault)
                Text(localizedAppText("Set for this prompt", de: "Für diesen Prompt setzen")).tag(PluginLLMTemperatureMode.custom)
            }
            .disabled(isAppleIntelligence)

            if viewModel.editTemperatureMode == .custom {
                HStack {
                    Text(localizedAppText("Temperature", de: "Temperatur"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(viewModel.editTemperatureValue, format: .number.precision(.fractionLength(2)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: temperatureValueBinding,
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

            Text(temperatureHelperText(isAppleIntelligence: isAppleIntelligence, effectiveProviderId: effectiveProviderId))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedSummary: String {
        var items: [String] = []
        let formattedTemperature = viewModel.editTemperatureValue.formatted(.number.precision(.fractionLength(2)))

        if let providerId = viewModel.editProviderId {
            items.append(processingService.displayName(for: providerId))
        } else {
            items.append(localizedAppText("Default provider", de: "Standard-Provider"))
        }

        if !viewModel.editCloudModel.isEmpty {
            let effectiveProviderId = viewModel.editProviderId ?? processingService.selectedProviderId
            let modelName = processingService.modelsForProvider(effectiveProviderId)
                .first(where: { $0.id == viewModel.editCloudModel })?
                .displayName ?? viewModel.editCloudModel
            items.append(modelName)
        }

        switch viewModel.editTemperatureMode {
        case .inheritProviderSetting:
            items.append(localizedAppText("Provider temperature", de: "Provider-Temperatur"))
        case .providerDefault:
            items.append(localizedAppText("Provider default temp", de: "Provider-Standardtemp"))
        case .custom:
            items.append(localizedAppText(
                "Temp \(formattedTemperature)",
                de: "Temp \(formattedTemperature)"
            ))
        }

        return items.joined(separator: " • ")
    }

    private var behaviorSectionTitle: String {
        switch viewModel.wizardDraft.goal {
        case .translate:
            return localizedAppText("Translation Behavior", de: "Übersetzungsverhalten")
        case .rewrite:
            return localizedAppText("Rewrite Behavior", de: "Umformulierungsverhalten")
        case .replyEmail:
            return localizedAppText("Reply Behavior", de: "Antwortverhalten")
        case .extract:
            return localizedAppText("Extraction Output", de: "Extraktionsausgabe")
        case .structure:
            return localizedAppText("Formatting Output", de: "Formatierungsausgabe")
        case .custom:
            return localizedAppText("Custom Behavior", de: "Benutzerdefiniertes Verhalten")
        }
    }

    private var behaviorSectionDescription: String {
        switch viewModel.wizardDraft.goal {
        case .translate:
            return localizedAppText("Choose one target language or a two-way language pair.", de: "Wähle eine Zielsprache oder ein Zwei-Wege-Sprachpaar.")
        case .rewrite:
            return localizedAppText("Pick tone, language behavior, and output form.", de: "Wähle Ton, Sprachverhalten und Ausgabeform.")
        case .replyEmail:
            return localizedAppText("Decide whether this drafts a reply or a full email.", de: "Lege fest, ob eine Antwort oder eine vollständige E-Mail erstellt wird.")
        case .extract:
            return localizedAppText("Define the structure for the extracted information.", de: "Definiere die Struktur für die extrahierten Informationen.")
        case .structure:
            return localizedAppText("Choose how the input should be reformatted.", de: "Wähle, wie der Input umformatiert werden soll.")
        case .custom:
            return localizedAppText("Describe the job briefly, then add optional tone and output hints.", de: "Beschreibe die Aufgabe kurz und ergänze optionale Ton- und Ausgabehinweise.")
        }
    }

    private var translationModeChoiceBinding: Binding<PromptWizardTranslationChoice> {
        Binding(
            get: {
                switch viewModel.wizardDraft.translationMode {
                case .alternatingPair:
                    return .alternating
                case .direct, .none:
                    return .direct
                }
            },
            set: { choice in
                viewModel.updateWizardDraft { draft in
                    switch choice {
                    case .direct:
                        let currentTarget: String
                        switch draft.translationMode {
                        case .alternatingPair(let primaryLanguage, _):
                            currentTarget = primaryLanguage
                        case .direct(let targetLanguage):
                            currentTarget = targetLanguage
                        case nil:
                            currentTarget = "en"
                        }
                        draft.translationMode = .direct(targetLanguage: currentTarget)
                    case .alternating:
                        let primaryLanguage: String
                        switch draft.translationMode {
                        case .direct(let targetLanguage):
                            primaryLanguage = targetLanguage
                        case .alternatingPair(let primary, _):
                            primaryLanguage = primary
                        case nil:
                            primaryLanguage = "en"
                        }
                        let secondaryLanguage = primaryLanguage == "en" ? "de" : "en"
                        draft.translationMode = .alternatingPair(primaryLanguage: primaryLanguage, secondaryLanguage: secondaryLanguage)
                    }
                }
            }
        )
    }

    private var directTargetLanguageBinding: Binding<String> {
        Binding(
            get: {
                switch viewModel.wizardDraft.translationMode {
                case .direct(let targetLanguage):
                    return targetLanguage
                case .alternatingPair(let primaryLanguage, _):
                    return primaryLanguage
                case nil:
                    return "en"
                }
            },
            set: { newValue in
                viewModel.updateWizardDraft { draft in
                    draft.translationMode = .direct(targetLanguage: newValue)
                }
            }
        )
    }

    private var alternatingPrimaryLanguageBinding: Binding<String> {
        Binding(
            get: {
                if case .alternatingPair(let primaryLanguage, _) = viewModel.wizardDraft.translationMode {
                    return primaryLanguage
                }
                return "en"
            },
            set: { newValue in
                viewModel.updateWizardDraft { draft in
                    let secondary = (draft.translationMode?.secondaryLanguage ?? (newValue == "en" ? "de" : "en"))
                    draft.translationMode = .alternatingPair(primaryLanguage: newValue, secondaryLanguage: secondary)
                }
            }
        )
    }

    private var alternatingSecondaryLanguageBinding: Binding<String> {
        Binding(
            get: {
                if case .alternatingPair(_, let secondaryLanguage) = viewModel.wizardDraft.translationMode {
                    return secondaryLanguage
                }
                return "de"
            },
            set: { newValue in
                viewModel.updateWizardDraft { draft in
                    let primary = draft.translationMode?.primaryLanguage ?? "en"
                    draft.translationMode = .alternatingPair(primaryLanguage: primary, secondaryLanguage: newValue)
                }
            }
        )
    }

    private var toneBinding: Binding<PromptWizardTone> {
        Binding(
            get: { viewModel.wizardDraft.tone },
            set: { newValue in
                viewModel.updateWizardDraft { draft in
                    draft.tone = newValue
                }
            }
        )
    }

    private var languageChoiceBinding: Binding<PromptWizardLanguageChoice> {
        Binding(
            get: {
                switch viewModel.wizardDraft.languageMode {
                case .sameAsInput:
                    return .sameAsInput
                case .target:
                    return .targetLanguage
                }
            },
            set: { newValue in
                viewModel.updateWizardDraft { draft in
                    switch newValue {
                    case .sameAsInput:
                        draft.languageMode = .sameAsInput
                    case .targetLanguage:
                        let target = draft.languageMode.targetLanguageCode ?? "en"
                        draft.languageMode = .target(target)
                    }
                }
            }
        )
    }

    private var targetLanguageBinding: Binding<String> {
        Binding(
            get: { viewModel.wizardDraft.languageMode.targetLanguageCode ?? "en" },
            set: { newValue in
                viewModel.updateWizardDraft { draft in
                    draft.languageMode = .target(newValue)
                }
            }
        )
    }

    private var rewriteFormatBinding: Binding<PromptWizardRewriteFormat> {
        Binding(
            get: { viewModel.wizardDraft.rewriteFormat },
            set: { newValue in
                viewModel.updateWizardDraft { draft in
                    draft.rewriteFormat = newValue
                }
            }
        )
    }

    private var replyModeBinding: Binding<PromptWizardReplyMode> {
        Binding(
            get: { viewModel.wizardDraft.replyMode },
            set: { newValue in
                viewModel.updateWizardDraft { draft in
                    draft.replyMode = newValue
                }
            }
        )
    }

    private var responseLengthBinding: Binding<PromptWizardResponseLength> {
        Binding(
            get: { viewModel.wizardDraft.responseLength },
            set: { newValue in
                viewModel.updateWizardDraft { draft in
                    draft.responseLength = newValue
                }
            }
        )
    }

    private var extractFormatBinding: Binding<PromptWizardExtractFormat> {
        Binding(
            get: { viewModel.wizardDraft.extractFormat },
            set: { newValue in
                viewModel.updateWizardDraft { draft in
                    draft.extractFormat = newValue
                }
            }
        )
    }

    private var structureFormatBinding: Binding<PromptWizardStructureFormat> {
        Binding(
            get: { viewModel.wizardDraft.structureFormat },
            set: { newValue in
                viewModel.updateWizardDraft { draft in
                    draft.structureFormat = newValue
                }
            }
        )
    }

    private var providerBinding: Binding<String?> {
        Binding(
            get: { viewModel.editProviderId },
            set: { newValue in
                viewModel.setWizardProviderOverride(newValue)
            }
        )
    }

    private var cloudModelBinding: Binding<String> {
        Binding(
            get: { viewModel.editCloudModel },
            set: { newValue in
                viewModel.setWizardCloudModel(newValue)
            }
        )
    }

    private var temperatureModeBinding: Binding<PluginLLMTemperatureMode> {
        Binding(
            get: { viewModel.editTemperatureMode },
            set: { newValue in
                viewModel.setWizardTemperatureMode(newValue)
            }
        )
    }

    private var temperatureValueBinding: Binding<Double> {
        Binding(
            get: { viewModel.editTemperatureValue },
            set: { newValue in
                viewModel.setWizardTemperatureValue(newValue)
            }
        )
    }

    private func temperatureHelperText(isAppleIntelligence: Bool, effectiveProviderId: String) -> String {
        if isAppleIntelligence {
            return localizedAppText(
                "Temperature is not available for Apple Intelligence.",
                de: "Temperatur ist für Apple Intelligence nicht verfügbar."
            )
        }

        switch viewModel.editTemperatureMode {
        case .inheritProviderSetting:
            return localizedAppText(
                "Uses the temperature saved in this provider's settings.",
                de: "Verwendet die in den Provider-Einstellungen gespeicherte Temperatur."
            )
        case .providerDefault:
            return localizedAppText(
                "Ignores your saved provider setting and lets the provider use its own default behavior.",
                de: "Ignoriert deine gespeicherte Provider-Einstellung und nutzt das Standardverhalten des Providers."
            )
        case .custom:
            if effectiveProviderId == "Gemma 4 (MLX)" {
                return localizedAppText(
                    "Uses this value only for this prompt. Gemma 4 supports values from 0.0 to 1.0.",
                    de: "Verwendet diesen Wert nur für diesen Prompt. Gemma 4 unterstützt Werte von 0.0 bis 1.0."
                )
            }
            return localizedAppText(
                "Uses this value only for this prompt and overrides the provider setting.",
                de: "Verwendet diesen Wert nur für diesen Prompt und überschreibt die Provider-Einstellung."
            )
        }
    }
}

private struct PromptWizardReviewStep: View {
    @ObservedObject var viewModel: PromptActionsViewModel
    @Binding var showingAdvancedOptions: Bool
    let iconOptions: [String]

    var body: some View {
        let actionPlugins = PluginManager.shared.actionPlugins

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localizedAppText("Review & Advanced", de: "Review & Erweitert"))
                    .font(.title3.weight(.semibold))
                Text(localizedAppText(
                    "Finalize the visible prompt details first. The raw system prompt and action target live in Advanced.",
                    de: "Finalisiere zuerst die sichtbaren Prompt-Details. Roh-System-Prompt und Action-Ziel liegen unter Erweitert."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            promptWizardCompactSection(
                title: localizedAppText("Prompt Details", de: "Prompt-Details"),
                description: localizedAppText("Set the final name, enabled state, icon, and list preview.", de: "Lege finalen Namen, Aktiv-Status, Icon und Listen-Vorschau fest.")
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        TextField(
                            localizedAppText("Prompt Name", de: "Prompt-Name"),
                            text: Binding(
                                get: { viewModel.currentPromptName },
                                set: { viewModel.updateWizardName($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)

                        HStack(spacing: 10) {
                            Text(localizedAppText("Active", de: "Aktiv"))
                                .font(.subheadline.weight(.medium))

                            Toggle(
                                localizedAppText("Active", de: "Aktiv"),
                                isOn: Binding(
                                    get: { viewModel.editIsEnabled },
                                    set: { viewModel.setWizardEnabled($0) }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.03), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                        }
                        .fixedSize()
                    }

                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                                .frame(width: 42, height: 42)

                            Image(systemName: viewModel.editIcon)
                                .foregroundStyle(Color.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.currentPromptName)
                                .font(.title3.weight(.semibold))
                            Text(PromptWizardComposer.reviewSummary(for: viewModel.wizardDraft))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(localizedAppText("Icon", de: "Icon"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Picker(
                                localizedAppText("Icon", de: "Icon"),
                                selection: Binding(
                                    get: { viewModel.editIcon },
                                    set: { viewModel.setWizardIcon($0) }
                                )
                            ) {
                                ForEach(iconOptions, id: \.self) { icon in
                                    Label(promptWizardIconDisplayName(for: icon), systemImage: icon)
                                        .tag(icon)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 180, alignment: .leading)
                        }

                        Spacer()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showingAdvancedOptions.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localizedAppText("Advanced", de: "Erweitert"))
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Text(localizedAppText(
                                "System prompt editing and optional action target.",
                                de: "Bearbeitung des System-Prompts und optionales Action-Ziel."
                            ))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(reviewAdvancedSummary)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Image(systemName: showingAdvancedOptions ? "chevron.up" : "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showingAdvancedOptions {
                    VStack(alignment: .leading, spacing: 16) {
                        Divider()
                            .padding(.top, 12)

                        promptWizardEditorSubsection(
                            title: localizedAppText("System Prompt", de: "System-Prompt"),
                            description: localizedAppText("This is the final raw prompt that will be saved and executed.", de: "Das ist der finale Roh-Prompt, der gespeichert und ausgeführt wird.")
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                if viewModel.manualPromptOverride {
                                    HStack(spacing: 10) {
                                        Label(localizedAppText("Manual override active", de: "Manueller Override aktiv"), systemImage: "pencil.and.outline")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)

                                        Spacer()

                                        Button(localizedAppText("Regenerate from selections", de: "Aus Auswahl neu erzeugen")) {
                                            viewModel.regeneratePromptFromWizardSelections()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                } else {
                                    Label(localizedAppText(
                                        "Changes in the wizard still regenerate this prompt automatically.",
                                        de: "Änderungen im Wizard erzeugen diesen Prompt weiterhin automatisch neu."
                                    ), systemImage: "wand.and.stars")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                TextEditor(text: Binding(
                                    get: { viewModel.editPrompt },
                                    set: { viewModel.updateManualPrompt($0) }
                                ))
                                .font(.body)
                                .frame(height: 180)
                                .padding(8)
                                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                                }
                            }
                        }

                        if !actionPlugins.isEmpty {
                            Divider()

                            promptWizardEditorSubsection(
                                title: localizedAppText("Action Target", de: "Action-Ziel"),
                                description: localizedAppText(
                                    "Optional action target instead of direct text insertion.",
                                    de: "Optionales Action-Ziel statt direktem Texteinsatz."
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Picker(
                                        localizedAppText("Target", de: "Ziel"),
                                        selection: Binding(
                                            get: { viewModel.editTargetActionPluginId },
                                            set: { viewModel.setWizardTargetActionPluginId($0) }
                                        )
                                    ) {
                                        Text(localizedAppText("Insert Text", de: "Text einfügen")).tag(nil as String?)
                                        ForEach(actionPlugins, id: \.actionId) { plugin in
                                            Label(plugin.actionName, systemImage: plugin.actionIcon)
                                                .tag(plugin.actionId as String?)
                                        }
                                    }

                                    Text(localizedAppText(
                                        "Leave this on Insert Text unless the result should trigger a plugin action.",
                                        de: "Lass dies auf Text einfügen, wenn das Ergebnis keine Plugin-Aktion auslösen soll."
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
            .background {
                promptWizardElevatedPanel(cornerRadius: 20)
            }
        }
    }

    private var reviewAdvancedSummary: String {
        var parts: [String] = [
            viewModel.manualPromptOverride
                ? localizedAppText("Manual prompt", de: "Manueller Prompt")
                : localizedAppText("Auto prompt", de: "Auto-Prompt")
        ]

        if let targetActionPluginId = viewModel.editTargetActionPluginId,
           let plugin = PluginManager.shared.actionPlugin(for: targetActionPluginId) {
            parts.append(plugin.actionName)
        } else {
            parts.append(localizedAppText("Insert Text", de: "Text einfügen"))
        }

        return parts.joined(separator: " • ")
    }
}

private enum PromptWizardTranslationChoice: Hashable {
    case direct
    case alternating
}

private enum PromptWizardLanguageChoice: Hashable {
    case sameAsInput
    case targetLanguage
}

private struct PromptWizardLanguageOption {
    let code: String
    let name: String
}

private let promptWizardCommonLanguages: [PromptWizardLanguageOption] = [
    .init(code: "en", name: "English"),
    .init(code: "de", name: "German"),
    .init(code: "fr", name: "French"),
    .init(code: "es", name: "Spanish"),
    .init(code: "it", name: "Italian"),
    .init(code: "pt", name: "Portuguese")
]

private func promptWizardLanguagePicker(title: String, selection: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        Picker(title, selection: selection) {
            ForEach(promptWizardCommonLanguages, id: \.code) { language in
                Text(language.name).tag(language.code)
            }
        }
        .labelsHidden()
    }
}

private func promptWizardTonePicker(tone: Binding<PromptWizardTone>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(localizedAppText("Tone", de: "Ton"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        Picker(localizedAppText("Tone", de: "Ton"), selection: tone) {
            Text(localizedAppText("Neutral", de: "Neutral")).tag(PromptWizardTone.neutral)
            Text(localizedAppText("Formal", de: "Formal")).tag(PromptWizardTone.formal)
            Text(localizedAppText("Friendly", de: "Freundlich")).tag(PromptWizardTone.friendly)
            Text(localizedAppText("Concise", de: "Knapp")).tag(PromptWizardTone.concise)
            Text(localizedAppText("Clear", de: "Klar")).tag(PromptWizardTone.clear)
            Text(localizedAppText("Professional", de: "Professionell")).tag(PromptWizardTone.professional)
        }
    }
}

private func promptWizardLanguageModeSection(
    mode: Binding<PromptWizardLanguageChoice>,
    targetLanguage: Binding<String>
) -> some View {
    VStack(alignment: .leading, spacing: 14) {
        Picker(localizedAppText("Language", de: "Sprache"), selection: mode) {
            Text(localizedAppText("Same as Input", de: "Wie Input")).tag(PromptWizardLanguageChoice.sameAsInput)
            Text(localizedAppText("Target Language", de: "Zielsprache")).tag(PromptWizardLanguageChoice.targetLanguage)
        }
        .pickerStyle(.segmented)

        if mode.wrappedValue == .targetLanguage {
            promptWizardLanguagePicker(
                title: localizedAppText("Target Language", de: "Zielsprache"),
                selection: targetLanguage
            )
        }
    }
}

private func promptWizardCompactSection<Content: View>(
    title: String,
    description: String? = nil,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)

            if let description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }

        content()
    }
    .padding(16)
    .background {
        promptWizardElevatedPanel(cornerRadius: 18)
    }
}

private func promptWizardEditorSubsection<Content: View>(
    title: String,
    description: String? = nil,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            if let description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        content()
    }
}

private func promptWizardInfoChip(_ text: String, tint: Color) -> some View {
    Text(text)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(.white)
        .background(tint, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(0.95), lineWidth: 1)
        }
}

private func promptWizardActiveSelectionFill() -> some ShapeStyle {
    Color.accentColor
}

private func promptWizardElevatedPanel(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.98))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
}

private func promptWizardGroupedListSurface(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Color.white.opacity(0.022))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.038), lineWidth: 1)
        }
}

private func promptWizardIconDisplayName(for icon: String) -> String {
    switch icon {
    case "sparkles":
        return localizedAppText("Sparkles", de: "Funkeln")
    case "globe":
        return localizedAppText("Translate", de: "Übersetzen")
    case "wand.and.stars":
        return localizedAppText("Magic", de: "Magie")
    case "arrowshape.turn.up.left":
        return localizedAppText("Reply", de: "Antwort")
    case "envelope":
        return localizedAppText("Email", de: "E-Mail")
    case "envelope.badge":
        return localizedAppText("Email Action", de: "E-Mail-Aktion")
    case "list.bullet":
        return localizedAppText("List", de: "Liste")
    case "checklist":
        return localizedAppText("Checklist", de: "Checkliste")
    case "tablecells":
        return localizedAppText("Table", de: "Tabelle")
    case "curlybraces":
        return localizedAppText("JSON", de: "JSON")
    case "doc.text.magnifyingglass":
        return localizedAppText("Extract", de: "Extrahieren")
    case "textformat.abc":
        return localizedAppText("Rewrite", de: "Umschreiben")
    case "text.quote":
        return localizedAppText("Quote", de: "Zitat")
    case "pencil":
        return localizedAppText("Draft", de: "Entwurf")
    case "lightbulb":
        return localizedAppText("Idea", de: "Idee")
    case "character.textbox":
        return localizedAppText("Text Box", de: "Textfeld")
    default:
        return icon
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
