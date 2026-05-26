import AppKit
import SwiftUI
import TypeWhisperPluginSDK

enum WorkflowRoute: Equatable {
    case create
    case edit(UUID)
}

@MainActor
final class WorkflowsNavigationCoordinator: ObservableObject {
    nonisolated(unsafe) static var shared: WorkflowsNavigationCoordinator!

    @Published private(set) var route: WorkflowRoute?

    func showMine() {
        route = nil
    }

    func createWorkflow() {
        route = .create
    }

    func editWorkflow(id: UUID) {
        route = .edit(id)
    }

    func goBackToList() {
        route = nil
    }
}

struct WorkflowOutputFormatPreset: Identifiable, Equatable {
    let title: String
    let value: String

    var id: String { value }

    static let all: [WorkflowOutputFormatPreset] = [
        WorkflowOutputFormatPreset(title: "Markdown", value: "markdown"),
        WorkflowOutputFormatPreset(title: "HTML", value: "html"),
        WorkflowOutputFormatPreset(title: "RTF", value: "rtf"),
        WorkflowOutputFormatPreset(title: "Plain Text", value: "plaintext"),
        WorkflowOutputFormatPreset(title: "Code", value: "code"),
        WorkflowOutputFormatPreset(title: "JSON", value: "json")
    ]
}

struct WorkflowsSettingsView: View {
    @ObservedObject private var workflowService = ServiceContainer.shared.workflowService
    @ObservedObject private var navigation = WorkflowsNavigationCoordinator.shared

    var body: some View {
        detailView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minWidth: 760, minHeight: 480)
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigation.route {
        case .none:
            MyWorkflowsPage()
        case .create:
            WorkflowEditorPage(workflow: nil)
        case .edit(let id):
            if let workflow = workflowService.workflow(id: id) {
                WorkflowEditorPage(workflow: workflow)
            } else {
                MissingWorkflowPage()
            }
        }
    }
}

private struct MyWorkflowsPage: View {
    @ObservedObject private var workflowService = ServiceContainer.shared.workflowService
    @ObservedObject private var promptProcessingService = ServiceContainer.shared.promptProcessingService
    @ObservedObject private var navigation = WorkflowsNavigationCoordinator.shared

    @State private var searchText = ""
    @State private var pendingDeleteWorkflowId: UUID?

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFilteringWorkflows: Bool {
        !trimmedSearchText.isEmpty
    }

    private var filteredWorkflows: [Workflow] {
        let trimmedQuery = trimmedSearchText
        guard !trimmedQuery.isEmpty else { return workflowService.workflows }

        return workflowService.workflows.filter { workflow in
            workflow.name.localizedCaseInsensitiveContains(trimmedQuery)
                || workflow.template.definition.name.localizedCaseInsensitiveContains(trimmedQuery)
                || workflowTriggerSummary(for: workflow).localizedCaseInsensitiveContains(trimmedQuery)
                || workflowTriggerDetail(for: workflow).localizedCaseInsensitiveContains(trimmedQuery)
                || workflowInputLanguageSummary(for: workflow.inputLanguageSelection).localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    providerDefaultsCard

                    if workflowService.workflows.isEmpty {
                        emptyState
                    } else {
                        searchField

                        if isFilteringWorkflows {
                            reorderDisabledNotice
                        }

                        if filteredWorkflows.isEmpty {
                            filteredEmptyState
                        } else {
                            workflowsList
                        }
                    }
                }
                .padding(16)
            }
        }
        .confirmationDialog(
            String(localized: "Delete workflow?"),
            isPresented: Binding(
                get: { pendingDeleteWorkflowId != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteWorkflowId = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                guard let pendingDeleteWorkflowId,
                      let workflow = workflowService.workflow(id: pendingDeleteWorkflowId) else {
                    self.pendingDeleteWorkflowId = nil
                    return
                }
                workflowService.deleteWorkflow(workflow)
                self.pendingDeleteWorkflowId = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingDeleteWorkflowId = nil
            }
        } message: {
            if let pendingDeleteWorkflowId,
               let workflow = workflowService.workflow(id: pendingDeleteWorkflowId) {
                Text(
                    String(localized: "This removes “\(workflow.name)” from the active workflow list.")
                )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Workflows"))
                    .font(.headline)
                Text(
                    String(localized: "Create and manage the workflows TypeWhisper should actively run.")
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                navigation.createWorkflow()
            } label: {
                Label(String(localized: "New Workflow"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(16)
        .background(.bar)
    }

    private var providerDefaultsCard: some View {
        WorkflowSectionCard(
            title: String(localized: "Default LLM"),
            description: String(localized: "New workflows use this provider unless a workflow overrides it in Advanced.")
        ) {
            let providers = promptProcessingService.availableProviders

            VStack(alignment: .leading, spacing: 10) {
                if providers.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            String(localized: "No LLM providers are installed yet.")
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                        Button(String(localized: "Open Integrations")) {
                            SettingsNavigationCoordinator.shared.navigate(to: .integrations)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    let models = promptProcessingService.modelsForProvider(workflowService.defaultProviderId)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            compactDefaultLLMField(title: String(localized: "Provider")) {
                                Picker(
                                    String(localized: "Provider"),
                                    selection: workflowDefaultProviderBinding
                                ) {
                                    ForEach(providers, id: \.id) { provider in
                                        Text(provider.displayName).tag(provider.id)
                                    }
                                }
                            }

                            if !models.isEmpty {
                                compactDefaultLLMField(title: String(localized: "Model")) {
                                    Picker(
                                        String(localized: "Model"),
                                        selection: $workflowService.defaultCloudModel
                                    ) {
                                        Text(String(localized: "Provider Default"))
                                            .tag("")
                                        ForEach(models, id: \.id) { model in
                                            Text(model.displayName).tag(model.id)
                                        }
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            compactDefaultLLMField(title: String(localized: "Provider")) {
                                Picker(
                                    String(localized: "Provider"),
                                    selection: workflowDefaultProviderBinding
                                ) {
                                    ForEach(providers, id: \.id) { provider in
                                        Text(provider.displayName).tag(provider.id)
                                    }
                                }
                            }

                            if !models.isEmpty {
                                compactDefaultLLMField(title: String(localized: "Model")) {
                                    Picker(
                                        String(localized: "Model"),
                                        selection: $workflowService.defaultCloudModel
                                    ) {
                                        Text(String(localized: "Provider Default"))
                                            .tag("")
                                        ForEach(models, id: \.id) { model in
                                            Text(model.displayName).tag(model.id)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(
                            promptProcessingService.isProviderReady(workflowService.defaultProviderId)
                                ? String(localized: "Ready for new workflows.")
                                : String(localized: "Provider setup not finished yet.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Button(String(localized: "Manage in Integrations")) {
                            SettingsNavigationCoordinator.shared.navigate(to: .integrations)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var workflowDefaultProviderBinding: Binding<String> {
        Binding(
            get: { workflowService.defaultProviderId },
            set: { providerId in
                workflowService.defaultProviderId = providerId
                let models = promptProcessingService.modelsForProvider(providerId)
                if !workflowService.defaultCloudModel.isEmpty,
                   !models.contains(where: { $0.id == workflowService.defaultCloudModel }) {
                    workflowService.defaultCloudModel = ""
                }
            }
        )
    }

    @ViewBuilder
    private func compactDefaultLLMField<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            content()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search workflows"), text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No Workflows Yet"), systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text(
                String(localized: "Workflows replace the old split between rules and prompts. Start with a concrete outcome and attach exactly one trigger.")
            )
            .frame(maxWidth: 440)
        } actions: {
            Button(String(localized: "Create First Workflow")) {
                navigation.createWorkflow()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .background {
            workflowsGroupedSurface(cornerRadius: 16)
        }
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No Matching Workflows"), systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(String(localized: "Adjust the search to see more workflows."))
        } actions: {
            Button(String(localized: "Clear Search")) {
                searchText = ""
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background {
            workflowsGroupedSurface(cornerRadius: 16)
        }
    }

    private var reorderDisabledNotice: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.body)
                .foregroundStyle(.secondary)

            Text(
                String(localized: "Reordering is disabled while search is active to keep the global workflow order deterministic.")
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button(String(localized: "Clear Search")) {
                searchText = ""
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var workflowsList: some View {
        let orderedIds = workflowService.workflows.map(\.id)
        let canReorder = !isFilteringWorkflows

        return LazyVStack(spacing: 0) {
            ForEach(Array(filteredWorkflows.enumerated()), id: \.element.id) { index, workflow in
                WorkflowRow(
                    workflow: workflow,
                    canMoveUp: canReorder && (orderedIds.firstIndex(of: workflow.id).map { $0 > 0 } ?? false),
                    canMoveDown: canReorder && (orderedIds.firstIndex(of: workflow.id).map { $0 < orderedIds.count - 1 } ?? false),
                    isReorderingEnabled: canReorder,
                    onToggle: { workflowService.toggleWorkflow(workflow) },
                    onEdit: { navigation.editWorkflow(id: workflow.id) },
                    onDelete: { pendingDeleteWorkflowId = workflow.id },
                    onMoveUp: { move(workflow: workflow, by: -1) },
                    onMoveDown: { move(workflow: workflow, by: 1) },
                    onDropWorkflow: { droppedId in
                        guard let draggedWorkflowId = UUID(uuidString: droppedId) else {
                            return false
                        }
                        return workflowService.moveWorkflow(
                            draggedWorkflowId: draggedWorkflowId,
                            droppedOn: workflow.id
                        )
                    }
                )

                if index < filteredWorkflows.count - 1 {
                    Divider()
                        .padding(.leading, 62)
                }
            }
        }
        .background {
            workflowsGroupedSurface(cornerRadius: 16)
        }
    }

    private func move(workflow: Workflow, by offset: Int) {
        guard let currentIndex = workflowService.workflows.firstIndex(where: { $0.id == workflow.id }) else {
            return
        }

        let targetIndex = currentIndex + offset
        guard workflowService.workflows.indices.contains(targetIndex) else { return }

        var reordered = workflowService.workflows
        reordered.swapAt(currentIndex, targetIndex)
        workflowService.reorderWorkflows(reordered)
    }
}

private struct WorkflowRow: View {
    let workflow: Workflow
    let canMoveUp: Bool
    let canMoveDown: Bool
    let isReorderingEnabled: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDropWorkflow: (String) -> Bool

    @State private var isDropTargeted = false
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: workflow.template.definition.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 6) {
                    Text(workflow.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    WorkflowBadge(
                        title: workflow.template.definition.name,
                        compact: true,
                        tint: .accentColor.opacity(0.14),
                        foreground: .accentColor
                    )

                    WorkflowBadge(
                        title: workflow.isEnabled
                            ? String(localized: "Enabled")
                            : String(localized: "Disabled"),
                        compact: true,
                        tint: workflow.isEnabled ? .green.opacity(0.14) : .secondary.opacity(0.14),
                        foreground: workflow.isEnabled ? .green : .secondary
                    )
                }

                Text(workflowReviewText(for: workflow))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    WorkflowBadge(title: workflowTriggerSummary(for: workflow), compact: true)
                    if !workflowTriggerDetail(for: workflow).isEmpty {
                        WorkflowBadge(
                            title: workflowTriggerDetail(for: workflow),
                            compact: true,
                            tint: .secondary.opacity(0.12),
                            foreground: .secondary
                        )
                    }
                    WorkflowBadge(
                        title: workflowInputLanguageSummary(for: workflow.inputLanguageSelection),
                        compact: true,
                        tint: .secondary.opacity(0.12),
                        foreground: .secondary
                    )
                    Spacer(minLength: 0)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Toggle("", isOn: Binding(
                    get: { workflow.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)

                Button(action: onMoveUp) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)

                Button(action: onMoveDown) {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(rowBackgroundColor)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onEdit()
        }
        .workflowReordering(
            isEnabled: isReorderingEnabled,
            workflowId: workflow.id.uuidString,
            isTargeted: $isDropTargeted
        ) { droppedItems in
            guard let droppedId = droppedItems.first else {
                return false
            }
            return onDropWorkflow(droppedId)
        }
        .help(
            isReorderingEnabled
                ? String(localized: "Drag to reorder workflow")
                : String(localized: "Clear search to reorder workflows")
        )
        .accessibilityHint(
            isReorderingEnabled
                ? String(localized: "Drag this row to reorder workflows.")
                : String(localized: "Reordering is disabled while search is active.")
        )
    }

    private var rowBackgroundColor: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.08)
        }

        if isHovered, isReorderingEnabled {
            return Color.primary.opacity(0.035)
        }

        return Color.clear
    }
}

private extension View {
    @ViewBuilder
    func workflowReordering(
        isEnabled: Bool,
        workflowId: String,
        isTargeted: Binding<Bool>,
        onDrop: @escaping ([String]) -> Bool
    ) -> some View {
        if isEnabled {
            self
                .draggable(workflowId)
                .dropDestination(for: String.self) { droppedItems, _ in
                    onDrop(droppedItems)
                } isTargeted: { targeted in
                    isTargeted.wrappedValue = targeted
                }
                .overlay {
                    OpenHandCursorView()
                        .allowsHitTesting(false)
                }
        } else {
            self
        }
    }
}

private struct OpenHandCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CursorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CursorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

private struct WorkflowEditorPage: View {
    let workflow: Workflow?

    @ObservedObject private var workflowService = ServiceContainer.shared.workflowService
    @ObservedObject private var hotkeyService = ServiceContainer.shared.hotkeyService
    @ObservedObject private var profilesViewModel = ServiceContainer.shared.profilesViewModel
    @ObservedObject private var historyService = ServiceContainer.shared.historyService
    @ObservedObject private var promptProcessingService = ServiceContainer.shared.promptProcessingService
    @ObservedObject private var settingsViewModel = SettingsViewModel.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var navigation = WorkflowsNavigationCoordinator.shared

    @State private var draft: WorkflowDraft
    @State private var validationMessage: String?
    @State private var isAdvancedExpanded = false
    @State private var showingAppPicker = false
    @State private var websiteInput = ""

    init(workflow: Workflow?) {
        self.workflow = workflow
        _draft = State(initialValue: workflow.map(WorkflowDraft.init) ?? WorkflowDraft(template: .cleanedText))
    }

    private var isEditing: Bool { workflow != nil }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let validationMessage {
                        ValidationBanner(message: validationMessage)
                    }

                    templateSection
                    triggerSection
                    behaviorSection
                    reviewSection
                }
                .padding(16)
            }
        }
        .sheet(isPresented: $showingAppPicker) {
            WorkflowAppPickerSheet(
                installedApps: profilesViewModel.installedApps,
                selectedBundleIdentifiers: $draft.appBundleIdentifiers
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Button {
                    navigation.goBackToList()
                } label: {
                    Label(String(localized: "Back"), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(String(localized: "Save Workflow")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isEditing
                    ? String(localized: "Edit Workflow")
                    : String(localized: "New Workflow")
                )
                .font(.headline)

                Text(
                    isEditing
                        ? String(localized: "Adjust the current workflow without changing its template.")
                        : String(localized: "Pick a concrete outcome first, then add behavior and one or more triggers.")
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.bar)
    }

    private var templateSection: some View {
        WorkflowSectionCard(
            title: String(localized: "Template"),
            description: isEditing
                ? String(localized: "The template stays fixed after creation.")
                : String(localized: "Choose the concrete outcome this workflow should produce.")
        ) {
            if isEditing {
                selectedTemplateCard(definition: draft.template.definition)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    ForEach(WorkflowTemplate.catalog) { definition in
                        WorkflowTemplateCard(
                            definition: definition,
                            isSelected: definition.template == draft.template
                        ) {
                            draft.selectTemplate(definition.template)
                        }
                    }
                }
            }
        }
    }

    private var behaviorSection: some View {
        WorkflowSectionCard(
            title: String(localized: "Behavior"),
            description: String(localized: "Define the outcome, optional fine-tuning, and the output settings.")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Name"))
                        .font(.subheadline.weight(.semibold))
                    TextField(String(localized: "Workflow name"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }

                if draft.template == .dictation {
                    workflowInputLanguageEditor
                    workflowTranscriptionEngineSection
                }

                if draft.template == .translation {
                    translationProcessorSection
                }

                if draft.template == .custom {
                    WorkflowTextEditorField(
                        title: String(localized: "Instruction"),
                        placeholder: String(localized: "Describe what this custom workflow should do."),
                        text: $draft.customInstruction
                    )
                }

                if draft.usesLLMProcessing {
                    WorkflowTextEditorField(
                        title: String(localized: "Fine-Tuning"),
                        placeholder: String(localized: "Optional: add tone, length, or wording hints."),
                        text: $draft.fineTuning
                    )
                }

                if shouldShowActionTargetSection {
                    actionTargetSection
                }

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isAdvancedExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(String(localized: "Advanced"))
                                .font(.subheadline.weight(.semibold))

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isAdvancedExpanded ? 90 : 0))
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isAdvancedExpanded {
                        VStack(alignment: .leading, spacing: 14) {
                            if draft.template != .dictation {
                                workflowInputLanguageEditor

                                Divider()
                            }

                            if draft.usesLLMProcessing {
                                workflowProviderOverrideSection

                                Divider()

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(String(localized: "Output Format"))
                                        .font(.subheadline.weight(.semibold))
                                    HStack(spacing: 8) {
                                        TextField(String(localized: "e.g. Markdown, RTF, JSON, plain text"), text: $draft.outputFormat)
                                            .textFieldStyle(.roundedBorder)

                                        Menu {
                                            ForEach(WorkflowOutputFormatPreset.all) { preset in
                                                Button(preset.title) {
                                                    draft.outputFormat = preset.value
                                                }
                                            }
                                        } label: {
                                            Label(String(localized: "Presets"), systemImage: "list.bullet.rectangle")
                                        }
                                        .menuStyle(.borderlessButton)
                                        .help(String(localized: "Choose an output format preset"))
                                    }
                                }

                                Divider()
                            }

                            Toggle(String(localized: "Press Enter after inserting"), isOn: $draft.autoEnter)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var shouldShowActionTargetSection: Bool {
        draft.template != .dictation
            && (!sortedActionPlugins.isEmpty || draft.targetActionPluginId != nil)
    }

    private var sortedActionPlugins: [ActionPlugin] {
        pluginManager.actionPlugins.sorted {
            $0.actionName.localizedCaseInsensitiveCompare($1.actionName) == .orderedAscending
        }
    }

    private var selectedActionTargetIsUnavailable: Bool {
        guard let targetActionPluginId = draft.targetActionPluginId else { return false }
        return !sortedActionPlugins.contains { $0.actionId == targetActionPluginId }
    }

    private var actionTargetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Action Target"))
                .font(.subheadline.weight(.semibold))

            Picker(
                String(localized: "Target"),
                selection: $draft.targetActionPluginId
            ) {
                Text(String(localized: "Insert Text"))
                    .tag(nil as String?)

                ForEach(sortedActionPlugins, id: \.actionId) { plugin in
                    Label(plugin.actionName, systemImage: plugin.actionIcon)
                        .tag(plugin.actionId as String?)
                }

                if let targetActionPluginId = draft.targetActionPluginId,
                   selectedActionTargetIsUnavailable {
                    Text(
                        String(localized: "Unavailable Action Target (\(targetActionPluginId))")
                    )
                    .tag(targetActionPluginId as String?)
                }
            }

            Text(
                String(localized: "Leave this on Insert Text unless the workflow result should trigger a plugin action.")
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if selectedActionTargetIsUnavailable {
                Text(
                    String(localized: "The selected action target is not currently enabled or installed. Saving keeps it unless you choose Insert Text or another action.")
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var workflowTranscriptionEngineSection: some View {
        let engines = pluginManager.transcriptionEngines.sorted {
            $0.providerDisplayName.localizedCaseInsensitiveCompare($1.providerDisplayName) == .orderedAscending
        }

        return VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Transcription Engine"))
                .font(.subheadline.weight(.semibold))

            if engines.isEmpty {
                Text(
                    String(localized: "Install a transcription engine in Integrations before using workflow engine overrides.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Picker(
                    String(localized: "Engine"),
                    selection: workflowTranscriptionEngineBinding
                ) {
                    Text(String(localized: "Use Global Engine"))
                        .tag(nil as String?)
                    ForEach(engines, id: \.providerId) { engine in
                        Text(engine.providerDisplayName).tag(engine.providerId as String?)
                    }
                }

                Text(
                    draft.transcriptionEngineId == nil
                        ? String(localized: "This workflow follows the global transcription engine setting.")
                        : String(localized: "This workflow starts dictation with its own transcription engine.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let engineId = draft.transcriptionEngineId {
                    let models = transcriptionModels(for: engineId)
                    if !models.isEmpty {
                        Picker(
                            String(localized: "Model"),
                            selection: workflowTranscriptionModelBinding
                        ) {
                            Text(String(localized: "Engine Default"))
                                .tag(nil as String?)
                            ForEach(models, id: \.id) { model in
                                Text(model.displayName).tag(model.id as String?)
                            }
                        }

                        Text(
                            String(localized: "Leave the model on Engine Default to follow the engine's selected model.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var workflowInputLanguageEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Spoken Language"))
                .font(.subheadline.weight(.semibold))
            LanguageSelectionEditor(
                selection: $draft.inputLanguageSelection,
                availableLanguages: settingsViewModel.availableLanguages,
                nilBehavior: .inheritGlobal,
                inheritTitle: String(localized: "Global Setting")
            )
        }
    }

    @ViewBuilder
    private var translationProcessorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Translation Mode"))
                    .font(.subheadline.weight(.semibold))
                Picker(String(localized: "Translation Mode"), selection: $draft.translationProcessor) {
                    ForEach(WorkflowTranslationProcessor.allCases, id: \.self) { processor in
                        Text(processor.label).tag(processor)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: draft.translationProcessor) { _, newValue in
                    draft.normalizeTranslationTarget(for: newValue)
                }
            }

            if draft.usesAppleTranslate {
                #if canImport(Translation)
                if #available(macOS 15, *) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Target Language"))
                            .font(.subheadline.weight(.semibold))
                        Picker(String(localized: "Target Language"), selection: $draft.translationTargetLanguage) {
                            ForEach(TranslationService.availableTargetLanguages, id: \.code) { language in
                                Text(language.name).tag(language.code)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } else {
                    Text(String(localized: "Apple Translate requires macOS 15 or later. Choose LLM Prompt on this Mac."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                #else
                Text(String(localized: "Apple Translate is not available in this build. Choose LLM Prompt instead."))
                .font(.caption)
                .foregroundStyle(.orange)
                #endif
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Target Language"))
                        .font(.subheadline.weight(.semibold))
                    TextField(String(localized: "e.g. English"), text: $draft.translationTargetLanguage)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var workflowProviderOverrideSection: some View {
        let providers = promptProcessingService.availableProviders

        return VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "LLM Override"))
                .font(.subheadline.weight(.semibold))

            if providers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        String(localized: "Install an LLM provider in Integrations before using workflow overrides.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button(String(localized: "Open Integrations")) {
                        SettingsNavigationCoordinator.shared.navigate(to: .integrations)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            } else {
                Picker(
                    String(localized: "Provider"),
                    selection: workflowProviderOverrideBinding
                ) {
                    Text(
                        String(localized: "Use Workflow Default (\(promptProcessingService.displayName(for: workflowService.defaultProviderId)))")
                    )
                    .tag(nil as String?)

                    ForEach(providers, id: \.id) { provider in
                        Text(provider.displayName).tag(provider.id as String?)
                    }
                }

                Text(
                    draft.providerId == nil
                        ? String(localized: "This workflow currently inherits the default provider from the workflow settings.")
                        : String(localized: "This workflow uses its own provider selection instead of the workflow default.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let providerId = draft.providerId {
                    let models = promptProcessingService.modelsForProvider(providerId)
                    if !models.isEmpty {
                        Picker(
                            String(localized: "Model"),
                            selection: workflowModelOverrideBinding
                        ) {
                            Text(String(localized: "Provider Default"))
                                .tag(nil as String?)
                            ForEach(models, id: \.id) { model in
                                Text(model.displayName).tag(model.id as String?)
                            }
                        }

                        Text(
                            String(localized: "Leave the model on Provider Default to follow the selected provider's preferred model.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if !promptProcessingService.isProviderReady(providerId) {
                        Text(
                            String(localized: "This provider is not ready yet. Finish its setup in Integrations before this workflow can use it.")
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var triggerSection: some View {
        WorkflowSectionCard(
            title: String(localized: "Trigger"),
            description: String(localized: "Choose how this workflow starts. Automatic can use app, website, hotkey, or combinations.")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker(String(localized: "Trigger"), selection: $draft.triggerMode) {
                    Text(String(localized: "Automatic")).tag(WorkflowTriggerMode.automatic)
                    if draft.template != .dictation {
                        Text(String(localized: "Manual")).tag(WorkflowTriggerMode.manual)
                    }
                    Text(String(localized: "Always")).tag(WorkflowTriggerMode.global)
                }
                .pickerStyle(.segmented)

                switch draft.triggerMode {
                case .manual:
                    manualTriggerEditor
                case .automatic:
                    automaticTriggerEditor
                case .global:
                    alwaysTriggerEditor
                }
            }
        }
    }

    private var reviewSection: some View {
        WorkflowSectionCard(
            title: String(localized: "Review"),
            description: String(localized: "This is how the workflow currently reads before saving.")
        ) {
            Text(draft.reviewText)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                }
        }
    }

    private var manualTriggerEditor: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Manual"))
                    .font(.subheadline.weight(.medium))

                Text(
                    String(localized: "Available from the Workflow Palette. It never runs automatically after dictation.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(workflowsGroupedSurface(cornerRadius: 12))
    }

    private var automaticTriggerEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            triggerComponentEditor(
                title: String(localized: "App"),
                isOn: $draft.isAppTriggerEnabled
            ) {
                appTriggerEditor
            }

            Divider()

            triggerComponentEditor(
                title: String(localized: "Website"),
                isOn: $draft.isWebsiteTriggerEnabled
            ) {
                websiteTriggerEditor
            }

            Divider()

            triggerComponentEditor(
                title: String(localized: "Hotkey"),
                isOn: $draft.isHotkeyTriggerEnabled
            ) {
                hotkeyTriggerEditor
            }
        }
        .background(workflowsGroupedSurface(cornerRadius: 12))
    }

    private func triggerComponentEditor<Content: View>(
        title: String,
        isOn: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .toggleStyle(.checkbox)

            if isOn.wrappedValue {
                content()
                    .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var appTriggerEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if draft.appBundleIdentifiers.isEmpty {
                Text(String(localized: "No apps selected yet."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(draft.appBundleIdentifiers, id: \.self) { bundleId in
                        WorkflowSelectionRow(
                            title: installedAppName(for: bundleId),
                            subtitle: bundleId,
                            icon: installedAppIcon(for: bundleId)
                        ) {
                            draft.appBundleIdentifiers.removeAll { $0 == bundleId }
                        }
                    }
                }
            }

            Button(String(localized: "Select Apps…")) {
                showingAppPicker = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var websiteTriggerEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if draft.websitePatterns.isEmpty {
                Text(String(localized: "No websites added yet."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(draft.websitePatterns, id: \.self) { pattern in
                        WorkflowSelectionRow(
                            title: pattern,
                            subtitle: String(localized: "Website trigger"),
                            iconSystemName: "globe"
                        ) {
                            draft.websitePatterns.removeAll { $0 == pattern }
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                TextField("docs.github.com", text: $websiteInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addWebsiteInput()
                    }

                Button(String(localized: "Add")) {
                    addWebsiteInput()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !websiteSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Suggested websites"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(websiteSuggestions, id: \.self) { domain in
                            Button(domain) {
                                draft.addWebsitePattern(domain)
                                websiteInput = ""
                                validationMessage = nil
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                            }
                        }
                    }
                }
            }

            Text(String(localized: "You can paste a full URL; only the domain is kept."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hotkeyTriggerEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Shortcut Behavior"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker(
                    String(localized: "Shortcut Behavior"),
                    selection: $draft.hotkeyBehavior
                ) {
                    ForEach(WorkflowHotkeyBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.editorLabel).tag(behavior)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(draft.hotkeyBehavior.editorDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if draft.hotkeys.isEmpty {
                Text(String(localized: "No shortcuts recorded yet."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(draft.hotkeys, id: \.self) { hotkey in
                        WorkflowSelectionRow(
                            title: HotkeyService.displayName(for: hotkey),
                            subtitle: draft.hotkeyBehavior.shortcutSubtitle,
                            iconSystemName: "keyboard"
                        ) {
                            draft.hotkeys.removeAll { $0 == hotkey }
                        }
                    }
                }
            }

            HotkeyRecorderView(
                label: "",
                title: String(localized: "Add Shortcut"),
                subtitle: nil,
                onRecord: { hotkey in
                    addRecordedHotkey(hotkey)
                },
                onClear: {}
            )
        }
    }

    private var alwaysTriggerEditor: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "infinity")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Always"))
                    .font(.subheadline.weight(.medium))

                Text(
                    String(localized: "Runs when no app or website workflow matches. Hotkeys stay direct triggers.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(workflowsGroupedSurface(cornerRadius: 12))
    }

    private var websiteSuggestions: [String] {
        let query = workflowNormalizedDomain(websiteInput)
        let source = historyService.uniqueDomains(limit: 8)

        if query.isEmpty {
            return source.filter { !draft.websitePatterns.contains($0) }
        }

        return source.filter { domain in
            !draft.websitePatterns.contains(domain) && domain.localizedCaseInsensitiveContains(query)
        }
    }

    private func save() {
        if let validationError = draft.validationError(
            hotkeyService: hotkeyService,
            workflowService: workflowService,
            pluginManager: pluginManager,
            existingWorkflowId: workflow?.id
        ) {
            validationMessage = validationError
            return
        }

        guard let trigger = draft.resolvedTrigger() else {
            validationMessage = String(localized: "The selected trigger is incomplete.")
            return
        }

        let behavior = draft.resolvedBehavior()
        let output = draft.resolvedOutput()

        if let workflow {
            workflow.name = draft.resolvedName
            workflow.isEnabled = draft.isEnabled
            workflow.trigger = trigger
            workflow.behavior = behavior
            workflow.output = output
            workflow.updatedAt = Date()
            workflowService.updateWorkflow(workflow)
        } else {
            _ = workflowService.addWorkflow(
                name: draft.resolvedName,
                template: draft.template,
                trigger: trigger,
                behavior: behavior,
                output: output,
                isEnabled: draft.isEnabled
            )
        }

        validationMessage = nil
        navigation.goBackToList()
    }

    private func installedAppName(for bundleId: String) -> String {
        profilesViewModel.installedApps.first(where: { $0.id == bundleId })?.name
            ?? workflowAppDisplayName(for: bundleId)
    }

    private func installedAppIcon(for bundleId: String) -> NSImage? {
        profilesViewModel.installedApps.first(where: { $0.id == bundleId })?.icon
    }

    private func addWebsiteInput() {
        let normalized = workflowNormalizedDomainFromInput(websiteInput)
        guard !normalized.isEmpty else { return }
        draft.addWebsitePattern(normalized)
        websiteInput = ""
        validationMessage = nil
    }

    private func addRecordedHotkey(_ hotkey: UnifiedHotkey) {
        if draft.containsEquivalentHotkey(hotkey) {
            validationMessage = String(localized: "This shortcut is already part of the workflow.")
            return
        }

        if let workflowId = hotkeyService.isHotkeyAssignedToWorkflow(hotkey, excludingWorkflowId: workflow?.id),
           let conflictWorkflow = workflowService.workflow(id: workflowId) {
            validationMessage = String(localized: "This hotkey is already used by workflow “\(conflictWorkflow.name)”.")
            return
        }

        if let slot = hotkeyService.isHotkeyAssignedToGlobalSlot(hotkey) {
            validationMessage = String(localized: "This hotkey is already used by the global slot “\(slot.rawValue)”.")
            return
        }

        draft.hotkeys.append(hotkey)
        validationMessage = nil
    }

    private func transcriptionModels(for engineId: String) -> [PluginModelInfo] {
        guard let engine = pluginManager.transcriptionEngine(for: engineId) else { return [] }
        return engine.modelCatalog
    }

    private func selectedTemplateCard(definition: WorkflowTemplateDefinition) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: definition.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(definition.name)
                    .font(.headline)
                Text(definition.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                WorkflowBadge(title: String(localized: "Template fixed after creation"))
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        }
    }

    private var workflowProviderOverrideBinding: Binding<String?> {
        Binding(
            get: { draft.providerId },
            set: { providerId in
                draft.providerId = providerId
                if providerId == nil {
                    draft.cloudModel = nil
                    return
                }

                if let cloudModel = draft.cloudModel,
                   let providerId,
                   !promptProcessingService.modelsForProvider(providerId).contains(where: { $0.id == cloudModel }) {
                    draft.cloudModel = nil
                }
            }
        )
    }

    private var workflowModelOverrideBinding: Binding<String?> {
        Binding(
            get: { draft.cloudModel },
            set: { modelId in
                draft.cloudModel = modelId
            }
        )
    }

    private var workflowTranscriptionEngineBinding: Binding<String?> {
        Binding(
            get: { draft.transcriptionEngineId },
            set: { engineId in
                draft.transcriptionEngineId = engineId
                if engineId == nil {
                    draft.transcriptionModelId = nil
                    return
                }

                if let transcriptionModelId = draft.transcriptionModelId,
                   let engineId,
                   !transcriptionModels(for: engineId).contains(where: { $0.id == transcriptionModelId }) {
                    draft.transcriptionModelId = nil
                }
            }
        )
    }

    private var workflowTranscriptionModelBinding: Binding<String?> {
        Binding(
            get: { draft.transcriptionModelId },
            set: { modelId in
                draft.transcriptionModelId = modelId
            }
        )
    }
}

private struct WorkflowTemplateCard: View {
    let definition: WorkflowTemplateDefinition
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                            .frame(width: 32, height: 32)

                        Image(systemName: definition.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(definition.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(definition.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.15), lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

private struct WorkflowSelectionRow: View {
    let title: String
    let subtitle: String?
    var icon: NSImage? = nil
    var iconSystemName: String? = nil
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else if let iconSystemName {
                Image(systemName: iconSystemName)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(workflowsGroupedSurface(cornerRadius: 12))
    }
}

private struct WorkflowTextEditorField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 86

    private let editorFont: Font = .body
    private let editorHorizontalPadding: CGFloat = 10
    private let editorTopPadding: CGFloat = 10
    private let editorBottomPadding: CGFloat = 8
    private let placeholderLeadingInset: CGFloat = 15
    private let placeholderTopInset: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(editorFont)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: minHeight)
                    .padding(.leading, editorHorizontalPadding)
                    .padding(.trailing, editorHorizontalPadding)
                    .padding(.top, editorTopPadding)
                    .padding(.bottom, editorBottomPadding)
                    .background(Color.clear)

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholder)
                        .font(editorFont)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, placeholderLeadingInset)
                        .padding(.top, placeholderTopInset)
                        .padding(.trailing, 12)
                        .allowsHitTesting(false)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                    )
            }
        }
    }
}

private struct WorkflowAppPickerSheet: View {
    let installedApps: [InstalledApp]
    @Binding var selectedBundleIdentifiers: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredApps: [InstalledApp] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return installedApps }
        return installedApps.filter { app in
            app.name.localizedCaseInsensitiveContains(trimmed)
                || app.id.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Select Apps"))
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Search Apps…"), text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)

            Divider()

            List(filteredApps) { app in
                HStack {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                    }
                    Text(app.name)
                    Spacer()
                    if selectedBundleIdentifiers.contains(app.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleSelection(app.id)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 500)
    }

    private func toggleSelection(_ bundleId: String) {
        if selectedBundleIdentifiers.contains(bundleId) {
            selectedBundleIdentifiers.removeAll { $0 == bundleId }
        } else {
            selectedBundleIdentifiers.append(bundleId)
        }
    }
}

private struct WorkflowSectionCard<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(16)
        .background {
            workflowsElevatedPanel(cornerRadius: 18)
        }
    }
}

private struct WorkflowBadge: View {
    let title: String
    var compact: Bool = false
    var tint: Color = .secondary.opacity(0.12)
    var foreground: Color = .secondary

    var body: some View {
        Text(title)
            .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 6)
            .background(tint, in: Capsule())
            .foregroundStyle(foreground)
    }
}

private struct ValidationBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        }
    }
}

private struct MissingWorkflowPage: View {
    @ObservedObject private var navigation = WorkflowsNavigationCoordinator.shared

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "Workflow Not Found"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(String(localized: "The selected workflow no longer exists."))
        } actions: {
            Button(String(localized: "Back to List")) {
                navigation.goBackToList()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum WorkflowTriggerMode: String, CaseIterable, Hashable {
    case manual
    case automatic
    case global
}

struct WorkflowDraft {
    var name: String
    var isEnabled: Bool
    var template: WorkflowTemplate
    var triggerMode: WorkflowTriggerMode
    var isAppTriggerEnabled: Bool
    var isWebsiteTriggerEnabled: Bool
    var isHotkeyTriggerEnabled: Bool
    var appBundleIdentifiers: [String]
    var websitePatterns: [String]
    var hotkeys: [UnifiedHotkey]
    var hotkeyBehavior: WorkflowHotkeyBehavior
    var fineTuning: String
    var inputLanguageSelection: LanguageSelection
    var translationTargetLanguage: String
    var translationProcessor: WorkflowTranslationProcessor
    var customInstruction: String
    var outputFormat: String
    var autoEnter: Bool
    var transcriptionEngineId: String?
    var transcriptionModelId: String?

    private var preservedBehaviorSettings: [String: String]
    var providerId: String?
    var cloudModel: String?
    private let temperatureModeRaw: String?
    private let temperatureValue: Double?
    var targetActionPluginId: String?

    init(template: WorkflowTemplate) {
        self.name = template.definition.name
        self.isEnabled = true
        self.template = template
        self.triggerMode = template == .dictation ? .automatic : .manual
        self.isAppTriggerEnabled = false
        self.isWebsiteTriggerEnabled = false
        self.isHotkeyTriggerEnabled = template == .dictation
        self.appBundleIdentifiers = []
        self.websitePatterns = []
        self.hotkeys = []
        self.hotkeyBehavior = .startDictation
        self.fineTuning = ""
        self.inputLanguageSelection = .inheritGlobal
        self.translationProcessor = template == .translation ? Self.defaultTranslationProcessor : .llmPrompt
        self.translationTargetLanguage = template == .translation
            ? Self.defaultTranslationTargetLanguage(for: translationProcessor)
            : ""
        self.customInstruction = ""
        self.outputFormat = ""
        self.autoEnter = false
        self.transcriptionEngineId = nil
        self.transcriptionModelId = nil
        self.preservedBehaviorSettings = [:]
        self.providerId = nil
        self.cloudModel = nil
        self.temperatureModeRaw = nil
        self.temperatureValue = nil
        self.targetActionPluginId = nil
    }

    init(_ workflow: Workflow) {
        let behavior = workflow.behavior
        let output = workflow.output

        self.name = workflow.name
        self.isEnabled = workflow.isEnabled
        self.template = workflow.template
        self.fineTuning = behavior.fineTuning
        self.inputLanguageSelection = workflow.inputLanguageSelection
        self.translationProcessor = workflow.translationProcessor
        let rawTranslationTargetLanguage = workflow.translationTargetLanguage ?? ""
        if workflow.usesAppleTranslate,
           let normalized = WorkflowTranslationLanguageNormalizer.normalizedLanguageIdentifier(from: rawTranslationTargetLanguage) {
            self.translationTargetLanguage = normalized
        } else {
            self.translationTargetLanguage = rawTranslationTargetLanguage
        }
        self.customInstruction = behavior.settings["instruction"] ?? behavior.settings["goal"] ?? behavior.settings["prompt"] ?? ""
        self.outputFormat = output.format ?? ""
        self.autoEnter = output.autoEnter
        self.transcriptionEngineId = workflow.template == .dictation ? behavior.transcriptionEngineId : nil
        self.transcriptionModelId = workflow.template == .dictation ? behavior.transcriptionModelId : nil
        self.hotkeyBehavior = .startDictation
        self.preservedBehaviorSettings = behavior.settings
        self.providerId = behavior.providerId
        self.cloudModel = behavior.cloudModel
        self.temperatureModeRaw = behavior.temperatureModeRaw
        self.temperatureValue = behavior.temperatureValue
        self.targetActionPluginId = workflow.template == .dictation ? nil : output.targetActionPluginId

        if let trigger = workflow.trigger {
            self.appBundleIdentifiers = trigger.appBundleIdentifiers
            self.websitePatterns = trigger.websitePatterns
            self.hotkeys = trigger.hotkeys
            self.hotkeyBehavior = trigger.hotkeyBehavior

            switch trigger.kind {
            case .global:
                self.triggerMode = .global
                self.isAppTriggerEnabled = false
                self.isWebsiteTriggerEnabled = false
                self.isHotkeyTriggerEnabled = false
            case .manual:
                self.triggerMode = .manual
                self.isAppTriggerEnabled = false
                self.isWebsiteTriggerEnabled = false
                self.isHotkeyTriggerEnabled = false
            case .app, .website, .hotkey:
                self.triggerMode = .automatic
                self.isAppTriggerEnabled = !trigger.appBundleIdentifiers.isEmpty
                self.isWebsiteTriggerEnabled = !trigger.websitePatterns.isEmpty
                self.isHotkeyTriggerEnabled = !trigger.hotkeys.isEmpty
            }
        } else {
            self.triggerMode = .manual
            self.isAppTriggerEnabled = false
            self.isWebsiteTriggerEnabled = false
            self.isHotkeyTriggerEnabled = false
            self.appBundleIdentifiers = []
            self.websitePatterns = []
            self.hotkeys = []
        }

        if self.template == .dictation && self.triggerMode == .manual {
            self.triggerMode = .automatic
            if !hasEnabledAutomaticTriggerComponent {
                self.isHotkeyTriggerEnabled = true
            }
        }
    }

    var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? template.definition.name : trimmed
    }

    var usesAppleTranslate: Bool {
        template == .translation && translationProcessor == .appleTranslate
    }

    var usesLLMProcessing: Bool {
        !usesAppleTranslate && template != .dictation
    }

    var reviewText: String {
        let languageSentence = String(localized: " Spoken language: \(workflowInputLanguageSummary(for: inputLanguageSelection)).")
        let outputRouteSentence = workflowOutputRouteSentence(targetActionPluginId: targetActionPluginId)

        if triggerMode == .manual {
            return String(localized: "\(resolvedName) is available as \(template.definition.name) from the Workflow Palette.\(languageSentence)\(outputRouteSentence)")
        }

        if triggerMode == .global {
            return String(localized: "\(resolvedName) runs always as \(template.definition.name).\(languageSentence)\(outputRouteSentence)")
        }

        return String(localized: "\(resolvedName) runs as \(template.definition.name) via \(triggerReviewText).\(languageSentence)\(outputRouteSentence)")
    }

    mutating func selectTemplate(_ newTemplate: WorkflowTemplate) {
        let currentTrimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousDefaultName = template.definition.name

        template = newTemplate

        if currentTrimmedName.isEmpty || currentTrimmedName == previousDefaultName {
            name = newTemplate.definition.name
        }

        if newTemplate != .translation {
            translationProcessor = .llmPrompt
            translationTargetLanguage = ""
        } else {
            translationProcessor = Self.defaultTranslationProcessor
            if translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                translationTargetLanguage = Self.defaultTranslationTargetLanguage(for: translationProcessor)
            }
        }

        if newTemplate != .custom {
            customInstruction = ""
        }

        if newTemplate == .dictation {
            fineTuning = ""
            outputFormat = ""
            providerId = nil
            cloudModel = nil
            targetActionPluginId = nil
            if triggerMode == .manual {
                triggerMode = .automatic
            }
            if !hasEnabledAutomaticTriggerComponent {
                isHotkeyTriggerEnabled = true
            }
        } else {
            transcriptionEngineId = nil
            transcriptionModelId = nil
        }
    }

    @MainActor
    func validationError(
        hotkeyService: HotkeyService,
        workflowService: WorkflowService,
        pluginManager: PluginManager,
        existingWorkflowId: UUID?
    ) -> String? {
        if template == .dictation && triggerMode == .manual {
            return String(localized: "Dictation Only workflows need a recording trigger.")
        }

        if template == .dictation,
           let transcriptionEngineId,
           !transcriptionEngineId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let engine = pluginManager.transcriptionEngine(for: transcriptionEngineId) else {
                return String(localized: "The selected transcription engine is not installed.")
            }

            if let transcriptionModelId,
               !transcriptionModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !engine.modelCatalog.contains(where: { $0.id == transcriptionModelId }) {
                return String(localized: "The selected transcription model is not available for this engine.")
            }
        }

        switch triggerMode {
        case .automatic:
            if !hasEnabledAutomaticTriggerComponent {
                return String(localized: "Please enable at least one automatic trigger.")
            }

            if isAppTriggerEnabled && appBundleIdentifiers.isEmpty {
                return String(localized: "Please select at least one app.")
            }

            if isWebsiteTriggerEnabled && websitePatterns.isEmpty {
                return String(localized: "Please add at least one website or domain.")
            }

            if isHotkeyTriggerEnabled {
                guard !hotkeys.isEmpty else {
                    return String(localized: "Please record at least one workflow shortcut.")
                }

                for hotkey in hotkeys {
                    if hotkeys.contains(where: { candidate in
                        candidate != hotkey && workflowHotkeysConflict(candidate, hotkey)
                    }) {
                        return String(localized: "The workflow contains duplicate shortcuts.")
                    }

                    if let conflictWorkflowId = hotkeyService.isHotkeyAssignedToWorkflow(hotkey, excludingWorkflowId: existingWorkflowId),
                       let conflictWorkflow = workflowService.workflow(id: conflictWorkflowId) {
                        return String(localized: "This hotkey is already used by workflow “\(conflictWorkflow.name)”.")
                    }

                    if let conflictSlot = hotkeyService.isHotkeyAssignedToGlobalSlot(hotkey) {
                        return String(localized: "This hotkey is already used by the global slot “\(conflictSlot.rawValue)”.")
                    }
                }
            }
        case .global, .manual:
            break
        }

        if template == .translation && translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Translation workflows need a target language.")
        }

        if usesAppleTranslate {
            #if canImport(Translation)
            if #available(macOS 15, *) {
            } else {
                return String(localized: "Apple Translate workflows require macOS 15 or later.")
            }
            #else
            return String(localized: "Apple Translate is not available in this build.")
            #endif
        }

        if template == .custom {
            let hasCustomInstruction = !customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasFineTuning = !fineTuning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasCustomInstruction && !hasFineTuning {
                return String(localized: "Custom workflows need an instruction or fine-tuning text.")
            }
        }

        return nil
    }

    func resolvedTrigger() -> WorkflowTrigger? {
        switch triggerMode {
        case .automatic:
            let resolvedApps = isAppTriggerEnabled ? appBundleIdentifiers : []
            let resolvedWebsites = isWebsiteTriggerEnabled ? websitePatterns : []
            let resolvedHotkeys = isHotkeyTriggerEnabled ? hotkeys : []
            guard !resolvedApps.isEmpty || !resolvedWebsites.isEmpty || !resolvedHotkeys.isEmpty else {
                return nil
            }

            let kind: WorkflowTriggerKind
            if !resolvedApps.isEmpty {
                kind = .app
            } else if !resolvedWebsites.isEmpty {
                kind = .website
            } else {
                kind = .hotkey
            }

            return WorkflowTrigger(
                kind: kind,
                appBundleIdentifiers: resolvedApps,
                websitePatterns: resolvedWebsites,
                hotkeys: resolvedHotkeys,
                hotkeyBehavior: hotkeyBehavior
            )
        case .global:
            return .global()
        case .manual:
            return .manual()
        }
    }

    func resolvedBehavior() -> WorkflowBehavior {
        var settings = preservedBehaviorSettings
        settings.removeValue(forKey: "targetLanguage")
        settings.removeValue(forKey: "target")
        settings.removeValue(forKey: WorkflowBehavior.translationProcessorSettingKey)
        settings.removeValue(forKey: WorkflowBehavior.inputLanguageSettingKey)
        settings.removeValue(forKey: "instruction")
        settings.removeValue(forKey: "goal")
        settings.removeValue(forKey: "prompt")

        if let storedInputLanguage = inputLanguageSelection.storedValue(nilBehavior: .inheritGlobal) {
            settings[WorkflowBehavior.inputLanguageSettingKey] = storedInputLanguage
        }

        let trimmedTargetLanguage = translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if template == .translation && !trimmedTargetLanguage.isEmpty {
            settings[WorkflowBehavior.targetLanguageSettingKey] = trimmedTargetLanguage
            settings[WorkflowBehavior.translationProcessorSettingKey] = translationProcessor.rawValue
        }

        let trimmedInstruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if template == .custom && !trimmedInstruction.isEmpty {
            settings["instruction"] = trimmedInstruction
        }

        let trimmedProviderId = providerId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCloudModel = cloudModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscriptionEngineId = template == .dictation ? Self.trimmedOptional(transcriptionEngineId) : nil

        return WorkflowBehavior(
            settings: settings,
            fineTuning: usesLLMProcessing ? fineTuning.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            providerId: usesLLMProcessing && trimmedProviderId?.isEmpty == false ? trimmedProviderId : nil,
            cloudModel: usesLLMProcessing && trimmedCloudModel?.isEmpty == false ? trimmedCloudModel : nil,
            transcriptionEngineId: trimmedTranscriptionEngineId,
            transcriptionModelId: trimmedTranscriptionEngineId != nil ? Self.trimmedOptional(transcriptionModelId) : nil,
            temperatureModeRaw: temperatureModeRaw,
            temperatureValue: temperatureValue
        )
    }

    func resolvedOutput() -> WorkflowOutput {
        let trimmedFormat = outputFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkflowOutput(
            format: usesLLMProcessing && !trimmedFormat.isEmpty ? trimmedFormat : nil,
            autoEnter: autoEnter,
            targetActionPluginId: template == .dictation ? nil : targetActionPluginId
        )
    }

    private var triggerReviewText: String {
        switch triggerMode {
        case .automatic:
            var parts: [String] = []

            if isAppTriggerEnabled {
                if appBundleIdentifiers.isEmpty {
                    parts.append(String(localized: "an app trigger"))
                } else {
                    parts.append(String(localized: "the apps \(workflowCompactList(appBundleIdentifiers.map(workflowAppDisplayName(for:)), conjunction: String(localized: \"and\")))"))
                }
            }

            if isWebsiteTriggerEnabled {
                if websitePatterns.isEmpty {
                    parts.append(String(localized: "a website trigger"))
                } else {
                    parts.append(String(localized: "the websites \(workflowCompactList(websitePatterns, conjunction: String(localized: \"and\")))"))
                }
            }

            if isHotkeyTriggerEnabled {
                let shortcuts = workflowCompactList(
                    hotkeys.map(HotkeyService.displayName(for:)),
                    conjunction: String(localized: "and")
                )
                if shortcuts.isEmpty {
                    parts.append(String(localized: "a hotkey"))
                } else {
                    switch hotkeyBehavior {
                    case .startDictation:
                        parts.append(String(localized: "the shortcuts \(shortcuts) to start dictation"))
                    case .processSelectedText:
                        parts.append(String(localized: "the shortcuts \(shortcuts) to process selected text"))
                    }
                }
            }

            if parts.isEmpty {
                return String(localized: "an automatic trigger")
            }

            return workflowCompactList(parts, conjunction: String(localized: "and"))
        case .global:
            return String(localized: "always")
        case .manual:
            return String(localized: "the Workflow Palette")
        }
    }

    private var hasEnabledAutomaticTriggerComponent: Bool {
        isAppTriggerEnabled || isWebsiteTriggerEnabled || isHotkeyTriggerEnabled
    }

    mutating func addWebsitePattern(_ value: String) {
        let normalized = workflowNormalizedDomainFromInput(value)
        guard !normalized.isEmpty, !websitePatterns.contains(normalized) else { return }
        websitePatterns.append(normalized)
    }

    func containsEquivalentHotkey(_ hotkey: UnifiedHotkey) -> Bool {
        hotkeys.contains { candidate in
            workflowHotkeysConflict(candidate, hotkey)
        }
    }

    mutating func normalizeTranslationTarget(for processor: WorkflowTranslationProcessor) {
        guard template == .translation else { return }
        let current = translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)

        switch processor {
        case .appleTranslate:
            if let normalized = WorkflowTranslationLanguageNormalizer.normalizedLanguageIdentifier(from: current) {
                translationTargetLanguage = normalized
            } else {
                translationTargetLanguage = Self.defaultTranslationTargetLanguage(for: processor)
            }
        case .llmPrompt:
            if current.isEmpty || current == "en" {
                translationTargetLanguage = Self.defaultTranslationTargetLanguage(for: processor)
            }
        }
    }

    private static var defaultTranslationProcessor: WorkflowTranslationProcessor {
        #if canImport(Translation)
        if #available(macOS 15, *) {
            return .appleTranslate
        }
        #endif
        return .llmPrompt
    }

    private static func defaultTranslationTargetLanguage(for processor: WorkflowTranslationProcessor) -> String {
        switch processor {
        case .appleTranslate:
            "en"
        case .llmPrompt:
            "English"
        }
    }

    private static func trimmedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private func workflowSummaryText(for workflow: Workflow) -> String {
    let templateName = workflow.template.definition.name
    switch workflow.template {
    case .translation:
        let targetLanguage = workflow.translationTargetLanguage
        if let targetLanguage, !targetLanguage.isEmpty {
            if workflow.usesAppleTranslate {
                return String(localized: "Apple Translate to \(localizedAppLanguageName(for: targetLanguage))")
            }
            return String(localized: "\(templateName) to \(targetLanguage)")
        }
        return templateName
    case .custom:
        let instruction = workflow.behavior.settings["instruction"]
            ?? workflow.behavior.settings["goal"]
            ?? workflow.behavior.settings["prompt"]
        if let instruction, !instruction.isEmpty {
            return instruction
        }
        return templateName
    default:
        return templateName
    }
}

private func workflowOutputRouteSentence(targetActionPluginId: String?) -> String {
    guard targetActionPluginId != nil else { return "" }
    return String(localized: " Output: action plugin.")
}

private func workflowInputLanguageSummary(for selection: LanguageSelection) -> String {
    switch selection {
    case .inheritGlobal:
        return String(localized: "Global Setting")
    case .auto:
        return String(localized: "Auto-detect")
    case .exact(let code):
        return localizedAppLanguageName(for: code)
    case .hints(let codes):
        let normalizedCodes = LanguageSelection.hints(codes).selectedCodes
        guard !normalizedCodes.isEmpty else {
            return String(localized: "Auto-detect")
        }
        return String(localized: "Auto-detect between \(workflowLanguageNameList(normalizedCodes))")
    }
}

private func workflowLanguageNameList(_ codes: [String]) -> String {
    let names = localizedAppLanguageNames(for: codes)
    switch names.count {
    case 0:
        return ""
    case 1:
        return names[0]
    case 2:
        return String(localized: "\(names[0]) and \(names[1])")
    default:
        let allButLast = names.dropLast().joined(separator: ", ")
        return String(localized: "\(allButLast), and \(names[names.count - 1])")
    }
}

private func workflowTriggerSummary(for workflow: Workflow) -> String {
    guard let trigger = workflow.trigger else {
        return String(localized: "No Trigger")
    }

    switch trigger.kind {
    case .manual:
        return String(localized: "Manual")
    case .global:
        return String(localized: "Always")
    case .app, .website, .hotkey:
        let parts = workflowTriggerSummaryParts(for: trigger)
        return parts.isEmpty ? trigger.kind.paletteLabel : parts.joined(separator: " + ")
    }
}

private func workflowTriggerDetail(for workflow: Workflow) -> String {
    guard let trigger = workflow.trigger else { return "" }

    switch trigger.kind {
    case .manual:
        return String(localized: "Workflow Palette")
    case .global:
        return ""
    case .app, .website, .hotkey:
        return workflowTriggerDetailParts(for: trigger).joined(separator: " · ")
    }
}

private func workflowTriggerSummaryParts(for trigger: WorkflowTrigger) -> [String] {
    var parts: [String] = []
    if !trigger.appBundleIdentifiers.isEmpty {
        parts.append(trigger.appBundleIdentifiers.count == 1
            ? String(localized: "App")
            : String(localized: "Apps"))
    }
    if !trigger.websitePatterns.isEmpty {
        parts.append(trigger.websitePatterns.count == 1
            ? String(localized: "Website")
            : String(localized: "Websites"))
    }
    if !trigger.hotkeys.isEmpty {
        parts.append(trigger.hotkeys.count == 1
            ? String(localized: "Hotkey")
            : String(localized: "Hotkeys"))
    }
    return parts
}

private func workflowTriggerDetailParts(for trigger: WorkflowTrigger) -> [String] {
    var parts: [String] = []
    if !trigger.appBundleIdentifiers.isEmpty {
        parts.append(workflowCompactList(trigger.appBundleIdentifiers.map(workflowAppDisplayName(for:))))
    }
    if !trigger.websitePatterns.isEmpty {
        parts.append(workflowCompactList(trigger.websitePatterns))
    }
    if !trigger.hotkeys.isEmpty {
        let shortcuts = workflowCompactList(trigger.hotkeys.map(HotkeyService.displayName(for:)))
        parts.append(shortcuts.isEmpty ? trigger.hotkeyBehavior.shortcutSubtitle : "\(shortcuts) · \(trigger.hotkeyBehavior.shortcutSubtitle)")
    }
    return parts
}

private func workflowReviewText(for workflow: Workflow) -> String {
    let summary = workflowSummaryText(for: workflow)
    let triggerSummary = workflowTriggerSummary(for: workflow)
    let triggerDetail = workflowTriggerDetail(for: workflow)
    let languageSentence = String(localized: ". Spoken language: \(workflowInputLanguageSummary(for: workflow.inputLanguageSelection))")
    let outputRouteSentence = workflowOutputRouteSentence(targetActionPluginId: workflow.output.targetActionPluginId)

    if workflow.trigger?.kind == .global {
        return String(localized: "\(summary) runs always\(languageSentence)\(outputRouteSentence)")
    }

    if workflow.trigger?.kind == .manual {
        return String(localized: "\(summary) is available from the Workflow Palette\(languageSentence)\(outputRouteSentence)")
    }

    if triggerDetail.isEmpty {
        return String(localized: "\(summary) via \(triggerSummary)\(languageSentence)\(outputRouteSentence)")
    }

    return String(localized: "\(summary) via \(triggerSummary): \(triggerDetail)\(languageSentence)\(outputRouteSentence)")
}

private func workflowAppDisplayName(for bundleIdentifier: String) -> String {
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
       let bundle = Bundle(url: appURL),
       let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
       !name.isEmpty {
        return name
    }

    let fallback = bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
    return fallback.replacingOccurrences(of: "-", with: " ").capitalized
}

private func workflowCompactList(_ values: [String], conjunction: String = String(localized: "and")) -> String {
    let filtered = values.filter { !$0.isEmpty }
    switch filtered.count {
    case 0:
        return ""
    case 1:
        return filtered[0]
    case 2:
        return "\(filtered[0]) \(conjunction) \(filtered[1])"
    default:
        return "\(filtered[0]), \(filtered[1]) +\(filtered.count - 2)"
    }
}

private func workflowHotkeysConflict(_ lhs: UnifiedHotkey, _ rhs: UnifiedHotkey) -> Bool {
    lhs.conflicts(with: rhs)
}

private func workflowNormalizedDomainFromInput(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    if let url = URL(string: trimmed), let host = url.host() {
        return workflowNormalizedDomain(host)
    }

    let withoutScheme = trimmed.replacingOccurrences(
        of: #"^[a-zA-Z][a-zA-Z0-9+\-.]*://"#,
        with: "",
        options: .regularExpression
    )
    let hostCandidate = withoutScheme.split(separator: "/").first.map(String.init) ?? withoutScheme
    return workflowNormalizedDomain(hostCandidate)
}

private func workflowNormalizedDomain(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return "" }
    if trimmed.hasPrefix("www.") {
        return String(trimmed.dropFirst(4))
    }
    return trimmed
}

private func workflowsElevatedPanel(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Color(nsColor: .windowBackgroundColor))
        .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 10)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
}

private func workflowsGroupedSurface(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
}
