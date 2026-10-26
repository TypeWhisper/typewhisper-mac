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
        WorkflowOutputFormatPreset(title: String(localized: "Auto-Detect"), value: "auto"),
        WorkflowOutputFormatPreset(title: String(localized: "Markdown"), value: "markdown"),
        WorkflowOutputFormatPreset(title: String(localized: "HTML"), value: "html"),
        WorkflowOutputFormatPreset(title: String(localized: "RTF"), value: "rtf"),
        WorkflowOutputFormatPreset(title: String(localized: "Plain Text"), value: "plaintext"),
        WorkflowOutputFormatPreset(title: String(localized: "Code"), value: "code"),
        WorkflowOutputFormatPreset(title: String(localized: "JSON"), value: "json")
    ]
}

struct WorkflowsSettingsView: View {
    @ObservedObject private var workflowService = ServiceContainer.shared.workflowService
    @ObservedObject private var navigation = WorkflowsNavigationCoordinator.shared

    var body: some View {
        detailView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minWidth: 560, minHeight: 480)
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

private struct LLMFallbackProviderMenuOption: Identifiable {
    let providerId: String
    let displayName: String
    let includesProviderDefault: Bool
    let models: [PluginModelInfo]

    var id: String { providerId }
}

private struct MyWorkflowsPage: View {
    @ObservedObject private var workflowService = ServiceContainer.shared.workflowService
    @ObservedObject private var promptProcessingService = ServiceContainer.shared.promptProcessingService
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var navigation = WorkflowsNavigationCoordinator.shared

    @State private var searchText = ""
    @State private var pendingDeleteWorkflowId: UUID?
    @FocusState private var focusedFallbackArrow: ReorderArrowFocus?
    @FocusState private var focusedWorkflowArrow: ReorderArrowFocus?

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

    private var fallbackAddOptions: [LLMFallbackProviderMenuOption] {
        let configuredFallbacks = promptProcessingService.fallbackPriorityList

        return promptProcessingService.availableProviders.compactMap { provider in
            let includesProviderDefault = !configuredFallbacks.contains {
                $0.providerId == provider.id && $0.modelId == nil
            }
            let remainingModels = promptProcessingService.modelsForProvider(provider.id).filter { model in
                !configuredFallbacks.contains {
                    $0.providerId == provider.id && $0.modelId == model.id
                }
            }

            guard includesProviderDefault || !remainingModels.isEmpty else { return nil }
            return LLMFallbackProviderMenuOption(
                providerId: provider.id,
                displayName: provider.displayName,
                includesProviderDefault: includesProviderDefault,
                models: remainingModels
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
                    fallbackPriorityCard

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
                .padding(SettingsLayoutMetrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .confirmationDialog(
            localizedAppText("Delete workflow?", de: "Workflow löschen?"),
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
            Button(localizedAppText("Delete", de: "Löschen"), role: .destructive) {
                guard let pendingDeleteWorkflowId,
                      let workflow = workflowService.workflow(id: pendingDeleteWorkflowId) else {
                    self.pendingDeleteWorkflowId = nil
                    return
                }
                workflowService.deleteWorkflow(workflow)
                self.pendingDeleteWorkflowId = nil
            }
            Button(localizedAppText("Cancel", de: "Abbrechen"), role: .cancel) {
                pendingDeleteWorkflowId = nil
            }
        } message: {
            if let pendingDeleteWorkflowId,
               let workflow = workflowService.workflow(id: pendingDeleteWorkflowId) {
                Text(
                    localizedAppText(
                        "This removes “\(workflow.name)” from the active workflow list.",
                        de: "Dadurch wird „\(workflow.name)“ aus der aktiven Workflow-Liste entfernt.",
                        ja: "「\(workflow.name)」を有効なワークフロー一覧から削除します。",
                        es: "Esto quita “\(workflow.name)” de la lista de flujos de trabajo activos."
                    )
                )
            }
        }
    }

    private var header: some View {
        SettingsPageHeader(
            localizedAppText("Workflows", de: "Workflows"),
            summary: localizedAppText(
                "Create and manage the workflows TypeWhisper should actively run.",
                de: "Erstelle und verwalte die Workflows, die TypeWhisper aktiv ausführen soll."
            )
        ) {
            Button {
                navigation.createWorkflow()
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label(localizedAppText("New Workflow", de: "Neuer Workflow"), systemImage: "plus")
                    Image(systemName: "plus")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
            .help(localizedAppText("New Workflow", de: "Neuer Workflow"))
        }
    }

    private var fallbackPriorityCard: some View {
        WorkflowSectionCard(
            title: localizedAppText("Global LLM Fallbacks", de: "Globale LLM-Fallbacks"),
            description: localizedAppText(
                "Inherited LLM workflows try these providers in order. A workflow override uses only its selected provider.",
                de: "Vererbte LLM-Workflows probieren diese Provider der Reihe nach. Ein Workflow-Override verwendet nur seinen ausgewählten Provider."
            ),
            compact: true
        ) {
            let providers = promptProcessingService.availableProviders

            VStack(alignment: .leading, spacing: 8) {
                if let enforced = pluginManager.enforcedLlmResolution {
                    ManagedByOrganizationLabel(text: enforced.unavailableReason ?? String(localized: "Managed by your organization."))
                }

                if promptProcessingService.fallbackPriorityList.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            localizedAppText(
                                "No global LLM fallbacks are configured yet.",
                                de: "Es sind noch keine globalen LLM-Fallbacks eingerichtet."
                            )
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    fallbackPriorityList
                        .disabled(promptProcessingService.isFallbackListLocked)
                }

                HStack(alignment: .center, spacing: 12) {
                    if providers.isEmpty {
                        Button(localizedAppText("Open Integrations", de: "Integrationen öffnen")) {
                            SettingsNavigationCoordinator.shared.navigate(to: .integrations)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else if !fallbackAddOptions.isEmpty {
                        fallbackPriorityAddMenu
                            .disabled(promptProcessingService.isFallbackListLocked)
                            .managedLockAccessibilityHint(
                                isLocked: promptProcessingService.isFallbackListLocked,
                                reason: pluginManager.enforcedLlmResolution?.unavailableReason
                            )
                    }

                    Spacer(minLength: 0)

                    if !providers.isEmpty {
                        Button(localizedAppText("Manage in Integrations", de: "In Integrationen verwalten")) {
                            SettingsNavigationCoordinator.shared.navigate(to: .integrations)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var fallbackPriorityList: some View {
        let fallbacks = promptProcessingService.fallbackPriorityList

        return VStack(spacing: 0) {
            // Rows are identified by position, so the keyboard focus can follow a moved row (see
            // ReorderArrowButtons).
            ForEach(Array(fallbacks.enumerated()), id: \.offset) { index, item in
                LLMFallbackPriorityRow(
                    item: item,
                    index: index,
                    count: fallbacks.count,
                    promptProcessingService: promptProcessingService,
                    onMove: { item, offset in
                        moveFallback(item, by: offset)
                    },
                    onDrop: moveFallback(draggedID:droppedOn:),
                    arrowFocus: $focusedFallbackArrow
                )

                if index < fallbacks.count - 1 {
                    Divider()
                        .padding(.leading, 34)
                }
            }
        }
    }

    private var fallbackPriorityAddMenu: some View {
        let options = fallbackAddOptions

        return Menu {
            ForEach(options) { option in
                if option.models.isEmpty {
                    Button(option.displayName) {
                        promptProcessingService.addLLMFallback(providerId: option.providerId, modelId: nil)
                    }
                } else {
                    Menu(option.displayName) {
                        if option.includesProviderDefault {
                            Button(localizedAppText("Provider Default", de: "Provider-Standard")) {
                                promptProcessingService.addLLMFallback(providerId: option.providerId, modelId: nil)
                            }

                            Divider()
                        }

                        ForEach(option.models, id: \.id) { model in
                            Button(model.displayName) {
                                promptProcessingService.addLLMFallback(providerId: option.providerId, modelId: model.id)
                            }
                        }
                    }
                }
            }
        } label: {
            Label(localizedAppText("Add Fallback", de: "Fallback hinzufügen"), systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help(localizedAppText("Add Fallback", de: "Fallback hinzufügen"))
    }

    private func moveFallback(_ item: LLMFallbackPriorityItem, by offset: Int) {
        let fallbacks = promptProcessingService.fallbackPriorityList
        guard let currentIndex = fallbacks.firstIndex(where: { $0.id == item.id }) else { return }

        let targetIndex = currentIndex + offset
        guard fallbacks.indices.contains(targetIndex) else { return }

        let destination = offset < 0 ? targetIndex : targetIndex + 1
        promptProcessingService.moveLLMFallbacks(
            from: IndexSet(integer: currentIndex),
            to: destination
        )
    }

    private func moveFallback(draggedID: UUID, droppedOn item: LLMFallbackPriorityItem) -> Bool {
        let fallbacks = promptProcessingService.fallbackPriorityList
        guard draggedID != item.id,
              let fromIndex = fallbacks.firstIndex(where: { $0.id == draggedID }),
              let toIndex = fallbacks.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
        promptProcessingService.moveLLMFallbacks(
            from: IndexSet(integer: fromIndex),
            to: destination
        )
        return true
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(localizedAppText("Search workflows", de: "Workflows durchsuchen"), text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel(localizedAppText("Search workflows", de: "Workflows durchsuchen"))
                .accessibilityAddTraits(.isSearchField)
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
            Label(localizedAppText("No Workflows Yet", de: "Noch keine Workflows"), systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text(
                localizedAppText(
                    "Workflows replace the old split between rules and prompts. Start with a concrete outcome and attach exactly one trigger.",
                    de: "Workflows ersetzen die alte Trennung zwischen Regeln und Prompts. Starte mit einem konkreten Ergebnis und hänge genau einen Trigger daran."
                )
            )
            .frame(maxWidth: 440)
        } actions: {
            Button(localizedAppText("Create First Workflow", de: "Ersten Workflow erstellen")) {
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
            Label(localizedAppText("No Matching Workflows", de: "Keine passenden Workflows"), systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(localizedAppText("Adjust the search to see more workflows.", de: "Passe die Suche an, um mehr Workflows zu sehen."))
        } actions: {
            Button(localizedAppText("Clear Search", de: "Suche löschen")) {
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
                .accessibilityHidden(true)

            Text(
                localizedAppText(
                    "Reordering is disabled while search is active to keep the global workflow order deterministic.",
                    de: "Die Sortierung ist während der Suche deaktiviert, damit die globale Workflow-Reihenfolge eindeutig bleibt."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button(localizedAppText("Clear Search", de: "Suche löschen")) {
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
            // Rows are identified by position, so the keyboard focus can follow a moved row (see
            // ReorderArrowButtons).
            ForEach(Array(filteredWorkflows.enumerated()), id: \.offset) { index, workflow in
                WorkflowRow(
                    workflow: workflow,
                    position: orderedIds.firstIndex(of: workflow.id) ?? index,
                    count: orderedIds.count,
                    arrowFocus: $focusedWorkflowArrow,
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

private struct LLMFallbackPriorityRow: View {
    let item: LLMFallbackPriorityItem
    let index: Int
    let count: Int
    @ObservedObject var promptProcessingService: PromptProcessingService
    let onMove: (LLMFallbackPriorityItem, Int) -> Void
    let onDrop: (UUID, LLMFallbackPriorityItem) -> Bool
    let arrowFocus: FocusState<ReorderArrowFocus?>.Binding

    @State private var isDropTargeted = false
    @State private var isHovered = false

    private var availableModels: [PluginModelInfo] {
        promptProcessingService.modelsForProvider(item.providerId)
    }

    private var availableEfforts: [PluginLLMEffortInfo] {
        promptProcessingService.effortsForProvider(item.providerId, modelId: item.modelId)
    }

    private var providerOptions: [(id: String, displayName: String)] {
        let otherFallbacks = promptProcessingService.fallbackPriorityList.filter { $0.id != item.id }
        var providers = promptProcessingService.availableProviders.filter { provider in
            provider.id == item.providerId || !otherFallbacks.contains {
                $0.providerId == provider.id && $0.modelId == nil
            }
        }
        if !providers.contains(where: { $0.id == item.providerId }) {
            providers.insert(
                (id: item.providerId, displayName: promptProcessingService.displayName(for: item.providerId)),
                at: 0
            )
        }
        return providers
    }

    private var modelOptions: [PluginModelInfo] {
        let otherFallbacks = promptProcessingService.fallbackPriorityList.filter { $0.id != item.id }
        return availableModels.filter { model in
            model.id == item.modelId || !otherFallbacks.contains {
                $0.providerId == item.providerId && $0.modelId == model.id
            }
        }
    }

    private var canSelectProviderDefault: Bool {
        item.modelId == nil || !promptProcessingService.fallbackPriorityList.contains {
            $0.id != item.id && $0.providerId == item.providerId && $0.modelId == nil
        }
    }

    private var canMoveUp: Bool { index > 0 }
    private var canMoveDown: Bool { index < count - 1 }
    private var showsModelPicker: Bool { !availableModels.isEmpty || item.modelId != nil }
    private var showsEffortPicker: Bool { !availableEfforts.isEmpty || item.effortId != nil }
    private var isReady: Bool { promptProcessingService.isProviderReady(item.providerId) }
    private var statusText: String {
        isReady
            ? localizedAppText("Ready", de: "Bereit")
            : localizedAppText("Unavailable", de: "Nicht verfügbar")
    }

    /// Names the row by its priority, provider and status, since the drag handle and the
    /// position number are hidden from accessibility.
    private var accessibilityRowLabel: String {
        let position = index + 1
        let providerName = promptProcessingService.displayName(for: item.providerId)
        let name = localizedAppText(
            "Fallback \(position) of \(count): \(providerName)",
            de: "Fallback \(position) von \(count): \(providerName)",
            ja: "フォールバック \(count)件中\(position)件目: \(providerName)",
            zh: "第 \(position) 个备用项（共 \(count) 个）：\(providerName)",
            es: "Respaldo \(position) de \(count): \(providerName)"
        )
        var parts = [name, statusText]
        // The list is disabled under an enforced LLM pair; a hint on this container
        // would replace its role description, so the reason is part of the name.
        if promptProcessingService.isFallbackListLocked {
            parts.append(
                PluginManager.shared.enforcedLlmResolution?.unavailableReason
                    ?? ManagedByOrganizationLabel.defaultText
            )
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 10)

                Text("\(index + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .help(localizedAppText("Drag to reorder global LLM fallbacks", de: "Ziehen, um globale LLM-Fallbacks zu sortieren"))
            .accessibilityHidden(true)

            selectionFields

            Spacer(minLength: 6)

            statusLabel

            moveButtons

            Button {
                promptProcessingService.removeLLMFallback(item)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 12))
            .help(localizedAppText("Remove fallback", de: "Fallback entfernen"))
            .accessibilityLabel(localizedAppText("Remove fallback", de: "Fallback entfernen"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(rowBackgroundColor)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                onMove(item, -1)
            } label: {
                Label(localizedAppText("Move Up", de: "Nach oben bewegen"), systemImage: "chevron.up")
            }
            .disabled(!canMoveUp)

            Button {
                onMove(item, 1)
            } label: {
                Label(localizedAppText("Move Down", de: "Nach unten bewegen"), systemImage: "chevron.down")
            }
            .disabled(!canMoveDown)

            Divider()

            Button(role: .destructive) {
                promptProcessingService.removeLLMFallback(item)
            } label: {
                Label(localizedAppText("Remove", de: "Entfernen"), systemImage: "trash")
            }
        }
        .fallbackPriorityReordering(
            fallbackID: item.id.uuidString,
            isTargeted: $isDropTargeted,
            onDrop: { droppedItems in
                guard let droppedID = droppedItems.first,
                      let draggedID = UUID(uuidString: droppedID) else {
                    return false
                }
                return onDrop(draggedID, item)
            }
        )
        // One container per fallback keeps its controls together for VoiceOver. The drag
        // tooltip sits on the grip and reordering is offered as Move Up and Move Down actions:
        // a tooltip or hint on the container would replace its "group" role description, and
        // on the row's content it would be repeated on every control.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityRowLabel)
        // A locked list cannot be reordered, so it offers no move actions either.
        .modifier(ReorderAccessibilityActions(
            canMoveUp: canMoveUp && !promptProcessingService.isFallbackListLocked,
            canMoveDown: canMoveDown && !promptProcessingService.isFallbackListLocked,
            moveUp: { onMove(item, -1) },
            moveDown: { onMove(item, 1) }
        ))
    }

    /// Moves the row with the keyboard as well as by dragging. They use the same move as the
    /// context menu and the VoiceOver actions; the locked list disables them with the whole row.
    private var moveButtons: some View {
        let providerName = promptProcessingService.displayName(for: item.providerId)
        let isLocked = promptProcessingService.isFallbackListLocked
        return ReorderArrowButtons(
            position: index,
            count: count,
            canMoveUp: canMoveUp && !isLocked,
            canMoveDown: canMoveDown && !isLocked,
            upLabel: String(localized: "Move \(providerName) up"),
            downLabel: String(localized: "Move \(providerName) down"),
            spacing: 2,
            focus: arrowFocus,
            moveUp: { onMove(item, -1) },
            moveDown: { onMove(item, 1) }
        )
        .font(.system(size: 12))
    }

    @ViewBuilder
    private var selectionFields: some View {
        // An enforced LLM pair replaces the fallback list; the saved rows stay as they are.
        Group {
            providerPicker
            if showsModelPicker {
                modelPicker
            }
            if showsEffortPicker {
                effortPicker
            }
        }
        .disabled(PluginManager.shared.selectionPolicy.enforcesLlm)
        .managedLockAccessibilityHint(
            isLocked: PluginManager.shared.selectionPolicy.enforcesLlm,
            reason: PluginManager.shared.enforcedLlmResolution?.unavailableReason
        )
    }

    private var providerPicker: some View {
        Picker(localizedAppText("Provider", de: "Provider"), selection: providerBinding) {
            ForEach(providerOptions, id: \.id) { provider in
                Text(provider.displayName).tag(provider.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: 170, alignment: .leading)
    }

    private var modelPicker: some View {
        Picker(localizedAppText("Model", de: "Modell"), selection: modelBinding) {
            if canSelectProviderDefault {
                Text(localizedAppText("Provider Default", de: "Provider-Standard"))
                    .tag(nil as String?)
            }

            if let selectedModelID = item.modelId,
               !availableModels.contains(where: { $0.id == selectedModelID }) {
                Text(selectedModelID).tag(selectedModelID as String?)
            }

            ForEach(modelOptions, id: \.id) { model in
                Text(model.displayName).tag(model.id as String?)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: 170, alignment: .leading)
    }

    private var effortPicker: some View {
        Picker(localizedAppText("Effort", de: "Effort"), selection: effortBinding) {
            Text(providerDefaultEffortLabel)
                .tag(nil as String?)

            if let selectedEffortID = item.effortId,
               !availableEfforts.contains(where: { $0.id == selectedEffortID }) {
                Text(selectedEffortID).tag(selectedEffortID as String?)
            }

            ForEach(availableEfforts, id: \.id) { effort in
                Text(effort.displayName).tag(effort.id as String?)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: 125, alignment: .leading)
    }

    private var providerDefaultEffortLabel: String {
        guard let defaultEffortID = promptProcessingService.defaultEffortId(
            for: item.providerId,
            modelId: item.modelId
        ),
        let displayName = availableEfforts.first(where: { $0.id == defaultEffortID })?.displayName
        else {
            return localizedAppText("Provider Default", de: "Provider-Standard")
        }
        return localizedAppText(
            "Provider Default (\(displayName))",
            de: "Provider-Standard (\(displayName))",
            es: "Predeterminado del proveedor (\(displayName))"
        )
    }

    private var statusLabel: some View {
        ViewThatFits(in: .horizontal) {
            Label(statusText, systemImage: isReady ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption)
                .fixedSize()

            Image(systemName: isReady ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption)
                .help(statusText)
                .accessibilityLabel(statusText)
        }
        .foregroundStyle(isReady ? Color.secondary : Color.orange)
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { item.providerId },
            set: { providerID in
                promptProcessingService.updateLLMFallback(
                    item,
                    providerId: providerID,
                    modelId: nil,
                    effortId: nil
                )
            }
        )
    }

    private var modelBinding: Binding<String?> {
        Binding(
            get: { item.modelId },
            set: { modelID in
                promptProcessingService.updateLLMFallback(
                    item,
                    providerId: item.providerId,
                    modelId: modelID,
                    effortId: nil
                )
            }
        )
    }

    private var effortBinding: Binding<String?> {
        Binding(
            get: { item.effortId },
            set: { effortID in
                promptProcessingService.updateLLMFallback(
                    item,
                    providerId: item.providerId,
                    modelId: item.modelId,
                    effortId: effortID
                )
            }
        )
    }

    private var rowBackgroundColor: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.08)
        }

        if isHovered {
            return Color.primary.opacity(0.035)
        }

        return Color.clear
    }
}

/// The reorder arrow that has the keyboard focus, by row position.
private struct ReorderArrowFocus: Hashable {
    enum Arrow: Hashable {
        case up
        case down
    }

    let position: Int
    let arrow: Arrow
}

/// Up and down buttons that reorder a row from the keyboard as well as by dragging. With keyboard
/// navigation on, Tab reaches them and Space presses them. After a move the focus goes to the
/// row's new position: to the same arrow, or to the other one once the row reaches the top or
/// bottom, so the row can be moved again right away.
///
/// The list must identify its rows by position. A row identified by its item is rebuilt when it
/// moves, and its arrows then show the focus ring without receiving key presses.
private struct ReorderArrowButtons: View {
    let position: Int
    let count: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let upLabel: String
    let downLabel: String
    var spacing: CGFloat = 6
    let focus: FocusState<ReorderArrowFocus?>.Binding
    let moveUp: () -> Void
    let moveDown: () -> Void

    var body: some View {
        HStack(spacing: spacing) {
            arrowButton(.up)
            arrowButton(.down)
        }
    }

    private func arrowButton(_ arrow: ReorderArrowFocus.Arrow) -> some View {
        let canMove = arrow == .up ? canMoveUp : canMoveDown
        // Plain buttons: in the fallback list, a focused borderless (AppKit-backed) arrow that
        // was disabled while it handled Space hung the app in SwiftUI's focus update.
        return Button {
            press(arrow)
        } label: {
            Image(systemName: arrow == .up ? "arrow.up" : "arrow.down")
        }
        .buttonStyle(.plain)
        .disabled(!canMove)
        .reorderArrowStyle(canMove: canMove)
        .focused(focus, equals: ReorderArrowFocus(position: position, arrow: arrow))
        .help(arrow == .up ? String(localized: "Move Up") : String(localized: "Move Down"))
        .accessibilityLabel(arrow == .up ? upLabel : downLabel)
    }

    private func press(_ arrow: ReorderArrowFocus.Arrow) {
        let hadFocus = focus.wrappedValue == ReorderArrowFocus(position: position, arrow: arrow)
        arrow == .up ? moveUp() : moveDown()
        guard hadFocus else { return }

        let newPosition = position + (arrow == .up ? -1 : 1)
        let canMoveAgain = arrow == .up ? newPosition > 0 : newPosition < count - 1
        let target = ReorderArrowFocus(
            position: newPosition,
            arrow: canMoveAgain ? arrow : (arrow == .up ? .down : .up)
        )
        // The arrow at the new position is enabled once the moved row is drawn there.
        DispatchQueue.main.async {
            focus.wrappedValue = target
        }
    }
}

/// Offers Move Up and Move Down as accessibility actions so rows that sort by drag and drop
/// can also be reordered with VoiceOver.
private struct ReorderAccessibilityActions: ViewModifier {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canMoveUp && canMoveDown {
            content
                .accessibilityAction(named: Text(localizedAppText("Move Up", de: "Nach oben bewegen")), moveUp)
                .accessibilityAction(named: Text(localizedAppText("Move Down", de: "Nach unten bewegen")), moveDown)
        } else if canMoveUp {
            content
                .accessibilityAction(named: Text(localizedAppText("Move Up", de: "Nach oben bewegen")), moveUp)
        } else if canMoveDown {
            content
                .accessibilityAction(named: Text(localizedAppText("Move Down", de: "Nach unten bewegen")), moveDown)
        } else {
            content
        }
    }
}

private extension View {
    /// Reorder arrows use the secondary colour, which hides the dimmed look of a disabled
    /// button, so an arrow that cannot move gets a fainter colour.
    func reorderArrowStyle(canMove: Bool) -> some View {
        foregroundStyle(canMove ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
    }

    @ViewBuilder
    func fallbackPriorityReordering(
        fallbackID: String,
        isTargeted: Binding<Bool>,
        onDrop: @escaping ([String]) -> Bool
    ) -> some View {
        self
            .draggable(fallbackID)
            .dropDestination(for: String.self) { droppedItems, _ in
                onDrop(droppedItems)
            } isTargeted: { targeted in
                isTargeted.wrappedValue = targeted
            }
            .overlay {
                OpenHandCursorView()
                    .allowsHitTesting(false)
            }
    }
}

private struct WorkflowRow: View {
    let workflow: Workflow
    /// The row's place in the full workflow order.
    let position: Int
    let count: Int
    let arrowFocus: FocusState<ReorderArrowFocus?>.Binding
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

    private var statusText: String {
        workflow.isEnabled
            ? localizedAppText("Enabled", de: "Aktiviert")
            : localizedAppText("Disabled", de: "Deaktiviert")
    }

    private var accessibilityRowLabel: String {
        [workflow.name, statusText].joined(separator: ", ")
    }

    private var reorderTooltip: String {
        isReorderingEnabled
            ? localizedAppText("Drag to reorder workflow", de: "Workflow ziehen, um die Reihenfolge zu ändern")
            : localizedAppText("Clear search to reorder workflows", de: "Suche löschen, um Workflows zu sortieren")
    }

    /// Reads the row's texts and badges as one sentence instead of many separate fragments.
    private var accessibilitySummary: String {
        let reviewText = workflowReviewText(for: workflow)
        let templateName = workflow.template.definition.name
        var parts = [workflow.name, statusText]
        if !reviewText.localizedCaseInsensitiveContains(templateName) {
            parts.append(templateName)
        }
        parts.append(reviewText)
        if workflow.usesInlineCommands {
            parts.append(String(localized: "Inline Commands"))
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: workflow.template.definition.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .help(reorderTooltip)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                titleRow

                Text(workflowReviewText(for: workflow))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                FlowLayout(spacing: 6) {
                    WorkflowBadge(
                        title: workflowTriggerSummary(for: workflow),
                        compact: true
                    )
                    if !workflowTriggerDetail(for: workflow).isEmpty {
                        WorkflowBadge(
                            title: workflowTriggerDetail(for: workflow),
                            compact: true,
                            tint: .secondary.opacity(0.12),
                            foreground: .secondary,
                            maxTextWidth: 240
                        )
                    }
                    WorkflowBadge(
                        title: workflowInputLanguageSummary(for: workflow.inputLanguageSelection),
                        compact: true,
                        tint: .secondary.opacity(0.12),
                        foreground: .secondary
                    )
                    if workflow.usesInlineCommands {
                        WorkflowBadge(
                            title: String(localized: "Inline Commands"),
                            compact: true,
                            tint: .secondary.opacity(0.12),
                            foreground: .secondary
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .contentShape(Rectangle())
            .help(reorderTooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(.isStaticText)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Toggle("", isOn: Binding(
                    get: { workflow.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Enable \(workflow.name)"))

                ReorderArrowButtons(
                    position: position,
                    count: count,
                    canMoveUp: canMoveUp,
                    canMoveDown: canMoveDown,
                    upLabel: localizedAppText(
                        "Move \(workflow.name) up",
                        de: "\(workflow.name) nach oben bewegen",
                        ja: "\(workflow.name)を上へ移動",
                        zh: "上移 \(workflow.name)",
                        es: "Subir \(workflow.name)"
                    ),
                    downLabel: localizedAppText(
                        "Move \(workflow.name) down",
                        de: "\(workflow.name) nach unten bewegen",
                        ja: "\(workflow.name)を下へ移動",
                        zh: "下移 \(workflow.name)",
                        es: "Bajar \(workflow.name)"
                    ),
                    focus: arrowFocus,
                    moveUp: onMoveUp,
                    moveDown: onMoveDown
                )

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Edit"))
                .accessibilityLabel(String(localized: "Edit \(workflow.name)"))

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Delete"))
                .accessibilityLabel(String(localized: "Delete \(workflow.name)"))
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
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
        // One container per workflow keeps its controls together for VoiceOver. The drag
        // tooltip sits on the icon and text, the controls have their own, and reordering is
        // offered as Move Up and Move Down actions: a tooltip or hint on the container would
        // replace its "group" role description, and on the whole row it would be repeated on
        // every control.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityRowLabel)
        .modifier(ReorderAccessibilityActions(
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            moveUp: onMoveUp,
            moveDown: onMoveDown
        ))
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

    @ViewBuilder
    private var titleRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 6) {
                workflowTitle
                workflowTemplateBadge
                workflowStatusBadge
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 5) {
                workflowTitle
                FlowLayout(spacing: 6) {
                    workflowTemplateBadge
                    workflowStatusBadge
                }
            }
        }
    }

    private var workflowTitle: some View {
        Text(workflow.name)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
    }

    private var workflowTemplateBadge: some View {
        WorkflowBadge(
            title: workflow.template.definition.name,
            compact: true,
            tint: .accentColor.opacity(0.14),
            foreground: .accentColor,
            maxTextWidth: 180
        )
    }

    private var workflowStatusBadge: some View {
        WorkflowBadge(
            title: statusText,
            compact: true,
            tint: workflow.isEnabled ? .green.opacity(0.14) : .secondary.opacity(0.14),
            foreground: workflow.isEnabled ? .green : .secondary
        )
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
    @ObservedObject private var installedAppsViewModel = ServiceContainer.shared.installedAppsViewModel
    @ObservedObject private var promptProcessingService = ServiceContainer.shared.promptProcessingService
    @ObservedObject private var settingsViewModel = SettingsViewModel.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var navigation = WorkflowsNavigationCoordinator.shared

    @State private var draft: WorkflowDraft
    /// The draft as the editor opened it, to tell whether closing would lose changes.
    @State private var savedDraft: WorkflowDraft
    @State private var isConfirmingDiscard = false
    @State private var validationMessage: String?
    @State private var isAdvancedExpanded = false
    @State private var testInput = ""
    @State private var testOutput: String?
    @State private var testError: String?
    @State private var testDurationMs: Int?
    @State private var isRunningTest = false
    @State private var isShowingTestPrompt = false
    @State private var testTask: Task<Void, Never>?
    /// Identifies the current test run, so a canceled run that finishes late cannot
    /// clear the state or overwrite the result of a newer one.
    @State private var testRunID: UUID?
    @State private var appPickerTarget: AppPickerTarget?
    @State private var websiteInput = ""
    @State private var excludedWebsiteInput = ""
    #if APPSTORE
    @AppStorage(UserDefaultsKeys.browserExtensionConnected) private var browserExtensionConnected = false
    #endif
    @StateObject private var websiteSuggestionStore = WorkflowWebsiteSuggestionStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(workflow: Workflow?) {
        self.workflow = workflow
        let initialDraft = workflow.map(WorkflowDraft.init) ?? WorkflowDraft(template: .cleanedText)
        _draft = State(initialValue: initialDraft)
        _savedDraft = State(initialValue: initialDraft)
    }

    private var isEditing: Bool { workflow != nil }

    /// The app list the app picker edits: the App trigger or the apps an Always trigger excludes.
    private enum AppPickerTarget: Identifiable {
        case trigger
        case exclusions

        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
                    if let validationMessage {
                        ValidationBanner(message: validationMessage)
                    }

                    templateSection
                    behaviorSection
                    if draftCanBeTested {
                        testSection
                    }
                    triggerSection
                    advancedSection
                    reviewSection
                }
                .padding(SettingsLayoutMetrics.pagePadding)
            }
        }
        .sheet(item: $appPickerTarget) { target in
            WorkflowAppPickerSheet(
                installedApps: installedAppsViewModel.installedApps,
                selectedBundleIdentifiers: target == .trigger
                    ? $draft.appBundleIdentifiers
                    : $draft.excludedAppBundleIdentifiers
            )
        }
        .alert(
            String(localized: "Do you want to save the changes to “\(draft.resolvedName)”?"),
            isPresented: $isConfirmingDiscard
        ) {
            Button(String(localized: "Save")) {
                save()
            }
            Button(String(localized: "Discard Changes"), role: .destructive) {
                navigation.goBackToList()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Your changes will be lost if you don’t save them."))
        }
    }

    /// Back and Esc leave the editor; with unsaved changes they ask first.
    private func close() {
        if draft.hasUnsavedChanges(comparedTo: savedDraft) {
            isConfirmingDiscard = true
        } else {
            navigation.goBackToList()
        }
    }

    private var header: some View {
        SettingsPageHeader(
            isEditing
                ? localizedAppText("Edit Workflow", de: "Workflow bearbeiten")
                : localizedAppText("New Workflow", de: "Neuer Workflow"),
            summary: isEditing
                ? localizedAppText("Adjust the current workflow without changing its template.", de: "Passe den aktuellen Workflow an, ohne seine Vorlage zu ändern.")
                : localizedAppText("Pick a concrete outcome first, then add behavior and one or more triggers.", de: "Wähle zuerst ein konkretes Ergebnis und ergänze dann Verhalten und einen oder mehrere Trigger.")
        ) {
            HStack(spacing: 12) {
                Button {
                    close()
                } label: {
                    Label(localizedAppText("Back", de: "Zurück"), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                // Esc, like Cancel in a sheet, also when no control has focus. Open menus, the
                // search field and the shortcut recorder still get Esc first.
                .keyboardShortcut(.cancelAction)

                Button(localizedAppText("Save Workflow", de: "Workflow speichern")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private var templateSection: some View {
        WorkflowSectionCard(
            title: localizedAppText("Template", de: "Vorlage"),
            description: isEditing
                ? localizedAppText("The template stays fixed after creation.", de: "Die Vorlage bleibt nach dem Erstellen fix.")
                : localizedAppText("Choose the concrete outcome this workflow should produce.", de: "Wähle das konkrete Ergebnis, das dieser Workflow erzeugen soll.")
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
            title: localizedAppText("Behavior", de: "Verhalten"),
            description: localizedAppText(
                "Name the workflow and describe what it should do with your dictation.",
                de: "Benenne den Workflow und beschreibe, was er mit deinem Diktat machen soll.",
                es: "Ponle nombre al flujo de trabajo y describe qué debe hacer con tu dictado."
            )
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localizedAppText("Name", de: "Name"))
                        .font(.subheadline.weight(.semibold))
                    TextField(localizedAppText("Workflow name", de: "Workflow-Name"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(localizedAppText("Workflow name", de: "Workflow-Name"))
                }

                if draft.template == .dictation {
                    workflowInlineCommandsSection
                }

                if draft.template == .translation {
                    translationProcessorSection
                }

                if draft.template == .custom {
                    customInstructionEditor
                } else if draft.usesLLMProcessing {
                    fineTuningEditor
                }
            }
        }
    }

    private var customInstructionEditor: some View {
        WorkflowTextEditorField(
            title: localizedAppText("Instruction", de: "Anweisung"),
            placeholder: localizedAppText(
                "Describe what this custom workflow should do.",
                de: "Beschreibe, was dieser eigene Workflow tun soll."
            ),
            text: $draft.customInstruction
        )
    }

    private var fineTuningEditor: some View {
        WorkflowTextEditorField(
            title: localizedAppText("Fine-Tuning", de: "Feinabstimmung"),
            placeholder: localizedAppText(
                "Optional: add tone, length, or wording hints.",
                de: "Optional: ergänze Hinweise zu Ton, Länge oder Formulierung."
            ),
            text: $draft.fineTuning
        )
    }

    // MARK: - Try it out

    /// Whether the draft does anything to the text that a test run could show.
    private var draftCanBeTested: Bool {
        draft.template != .dictation || draft.inlineCommandsEnabled == true
    }

    /// Runs the unsaved draft through the same processing as a real dictation, so a
    /// prompt can be tried before saving. Nothing is inserted or stored.
    private var testSection: some View {
        WorkflowSectionCard(
            title: localizedAppText("Try It Out", de: "Ausprobieren", es: "Probar"),
            description: localizedAppText(
                "Type or paste a sample dictation and run the workflow with the current settings. Nothing is saved or inserted. The test uses the workflow's AI provider.",
                de: "Gib ein Beispiel-Diktat ein und führe den Workflow mit den aktuellen Einstellungen aus. Nichts wird gespeichert oder eingefügt. Der Test nutzt den KI-Anbieter des Workflows.",
                es: "Escribe o pega un dictado de ejemplo y ejecuta el flujo de trabajo con los ajustes actuales. No se guarda ni se inserta nada. La prueba usa el proveedor de IA del flujo de trabajo."
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
                WorkflowTextEditorField(
                    title: localizedAppText("Sample dictation", de: "Beispiel-Diktat", es: "Dictado de ejemplo"),
                    placeholder: localizedAppText(
                        "What you would say, including filler words and corrections.",
                        de: "Was du sagen würdest, mit Füllwörtern und Korrekturen.",
                        es: "Lo que dirías, con muletillas y correcciones."
                    ),
                    text: $testInput,
                    minHeight: 72
                )

                HStack(spacing: 10) {
                    Button {
                        runTest()
                    } label: {
                        HStack(spacing: 6) {
                            if isRunningTest {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(localizedAppText("Run Test", de: "Test starten", es: "Ejecutar prueba"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunningTest || testInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(localizedAppText("Run the test (⌘↩)", de: "Test starten (⌘↩)", es: "Ejecutar la prueba (⌘↩)"))

                    if isRunningTest {
                        Button(localizedAppText("Cancel", de: "Abbrechen")) {
                            cancelTest()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(localizedAppText("Insert Example", de: "Beispiel einfügen", es: "Insertar ejemplo")) {
                            testInput = Self.exampleDictation
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    if testSystemPrompt != nil {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                                isShowingTestPrompt.toggle()
                            }
                        } label: {
                            Label(
                                isShowingTestPrompt
                                    ? localizedAppText("Hide Prompt", de: "Prompt ausblenden", es: "Ocultar prompt")
                                    : localizedAppText("Show Prompt", de: "Prompt anzeigen", es: "Mostrar prompt"),
                                systemImage: "text.alignleft"
                            )
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }

                if !isRunningTest, workflowService.shouldSkipAIProcessingForShortDictation(text: testInput) {
                    Text(
                        localizedAppText(
                            "A real dictation this short is inserted without AI processing. The test still runs it.",
                            de: "Ein so kurzes echtes Diktat wird ohne KI-Verarbeitung eingefügt. Der Test führt es trotzdem aus.",
                            es: "Un dictado real tan corto se inserta sin procesamiento de IA. La prueba lo ejecuta de todos modos."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if isShowingTestPrompt, let testSystemPrompt {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localizedAppText("System prompt", de: "System-Prompt", es: "Prompt del sistema"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ScrollView {
                            Text(testSystemPrompt)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(maxHeight: 220)
                        .background(workflowsGroupedSurface(cornerRadius: 10))

                        Text(
                            localizedAppText(
                                "Dictionary terms are added when the workflow runs.",
                                de: "Wörterbuch-Begriffe kommen beim Ausführen dazu.",
                                es: "Los términos del diccionario se añaden al ejecutarse."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let testError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(testError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }

                if let testOutput {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(localizedAppText("Result", de: "Ergebnis", es: "Resultado"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Spacer()

                            if let testDurationSeconds {
                                Text(
                                    localizedAppText(
                                        "\(testDurationSeconds) s",
                                        de: "\(testDurationSeconds) s",
                                        es: "\(testDurationSeconds) s"
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            }

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(testOutput, forType: .string)
                            } label: {
                                Label(localizedAppText("Copy", de: "Kopieren"), systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }

                        Text(testOutput)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.08))
                            }
                    }
                }
            }
        }
        .onDisappear { cancelTest() }
    }

    private static var exampleDictation: String {
        localizedAppText(
            "um so i think we should move the meeting to thursday at three, no wait, at four, and can you ask anna to bring the slides. thanks",
            de: "ähm also ich denke wir sollten das Meeting auf Donnerstag um drei verschieben, nee warte, um vier, und kannst du Anna bitten die Folien mitzubringen. danke",
            es: "eh bueno creo que deberíamos mover la reunión al jueves a las tres, no espera, a las cuatro, y puedes pedirle a Anna que traiga las diapositivas. gracias"
        )
    }

    /// An unsaved workflow with the draft's current settings, for test runs and the prompt preview.
    private func makeTestWorkflow() -> Workflow {
        Workflow(
            name: draft.resolvedName,
            template: draft.template,
            trigger: draft.resolvedTrigger() ?? .manual(),
            behavior: draft.resolvedBehavior(),
            output: draft.resolvedOutput()
        )
    }

    /// The translation target a real dictation would fall back to when the workflow has none.
    private var testFallbackTranslationTarget: String? {
        settingsViewModel.translationEnabled ? settingsViewModel.translationTargetLanguage : nil
    }

    private var testSystemPrompt: String? {
        guard draftCanBeTested, !draft.usesAppleTranslate else { return nil }
        return makeTestWorkflow().systemPrompt(fallbackTranslationTarget: testFallbackTranslationTarget)
    }

    private var testDurationSeconds: String? {
        testDurationMs.map { String(format: "%.1f", Double($0) / 1000) }
    }

    private func runTest() {
        let text = testInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunningTest else { return }

        let container = ServiceContainer.shared
        let processor = WorkflowTextProcessingService(
            promptProcessingService: container.promptProcessingService,
            translationService: container.translationService,
            workflowService: container.workflowService,
            vocabularyProvider: { [dictionaryService = container.dictionaryService] in
                dictionaryService.vocabularyForPrompt()
            }
        )
        let workflow = makeTestWorkflow()
        let fallbackTranslationTarget = testFallbackTranslationTarget

        let runID = UUID()
        testRunID = runID
        isRunningTest = true
        testOutput = nil
        testError = nil
        testDurationMs = nil
        let start = CFAbsoluteTimeGetCurrent()

        testTask = Task { @MainActor in
            defer {
                if testRunID == runID {
                    isRunningTest = false
                    testRunID = nil
                }
            }
            do {
                let result = try await processor.process(
                    workflow: workflow,
                    text: text,
                    fallbackTranslationTarget: fallbackTranslationTarget
                )
                guard !Task.isCancelled, testRunID == runID else { return }
                testOutput = result
                testDurationMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, testRunID == runID else { return }
                testError = error.localizedDescription
            }
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testRunID = nil
        isRunningTest = false
    }

    /// Everything that only matters once the defaults are not enough. Collapsed by
    /// default; the header lists the settings that differ from the defaults so saved
    /// overrides stay visible without opening the card.
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isAdvancedExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localizedAppText("Advanced", de: "Erweitert"))
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)

                        Text(advancedSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isAdvancedExpanded ? 90 : 0))
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localizedAppText("Advanced", de: "Erweitert"))
            .accessibilityValue(workflowDisclosureState(isExpanded: isAdvancedExpanded))

            if isAdvancedExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    workflowInputLanguageEditor

                    if draft.template == .dictation {
                        Divider()
                        workflowTranscriptionEngineSection
                    }

                    Divider()
                    workflowMicrophoneBoostSection

                    if draft.template == .custom {
                        Divider()
                        fineTuningEditor
                    }

                    if shouldShowActionTargetSection {
                        Divider()
                        actionTargetSection
                    }

                    if draft.usesLLMProcessing {
                        Divider()
                        workflowProviderOverrideSection

                        if draft.supportsSegmentedPostProcessing {
                            Divider()
                            workflowSegmentedPostProcessingSection
                        }

                        Divider()
                        outputFormatEditor
                    }

                    Divider()
                    numberNormalizationSection

                    Divider()
                    autoEnterEditor
                }
                .padding(.top, 16)
            }
        }
        .padding(16)
        .background {
            workflowsElevatedPanel(cornerRadius: 18)
        }
    }

    /// The advanced settings that differ from the defaults, or a hint that the
    /// defaults are in use.
    private var advancedSummary: String {
        var items: [String] = []

        if draft.inputLanguageSelection != .inheritGlobal {
            items.append(workflowInputLanguageSummary(for: draft.inputLanguageSelection))
        }
        if draft.template == .dictation, let engineId = draft.transcriptionEngineId {
            items.append(pluginManager.transcriptionEngine(for: engineId)?.providerDisplayName ?? engineId)
        }
        if draft.microphoneBoostOverride != nil {
            items.append(
                localizedAppText(
                    "Whisper Mode: \(WorkflowMicrophoneBoostOverride(value: draft.microphoneBoostOverride).title)",
                    de: "Whisper-Modus: \(WorkflowMicrophoneBoostOverride(value: draft.microphoneBoostOverride).title)",
                    es: "Modo susurro: \(WorkflowMicrophoneBoostOverride(value: draft.microphoneBoostOverride).title)"
                )
            )
        }
        if draft.template == .custom, !draft.fineTuning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(localizedAppText("Fine-Tuning", de: "Feinabstimmung"))
        }
        if let targetActionPluginId = draft.targetActionPluginId {
            items.append(
                sortedActionPlugins.first { $0.actionId == targetActionPluginId }?.actionName ?? targetActionPluginId
            )
        }
        if draft.usesLLMProcessing {
            if let providerId = draft.providerId {
                items.append(
                    promptProcessingService.availableProviders.first { $0.id == providerId }?.displayName ?? providerId
                )
            }
            if draft.supportsSegmentedPostProcessing, draft.segmentedPostProcessingEnabled == true {
                items.append(String(localized: "Process long dictations in segments"))
            }
            let outputFormat = draft.outputFormat.trimmingCharacters(in: .whitespacesAndNewlines)
            if !outputFormat.isEmpty {
                items.append(outputFormat)
            }
        }
        if draft.numberNormalizationMode != .inherit {
            items.append(
                localizedAppText(
                    "Numbers: \(draft.numberNormalizationMode.displayName)",
                    de: "Zahlen: \(draft.numberNormalizationMode.displayName)",
                    es: "Números: \(draft.numberNormalizationMode.displayName)"
                )
            )
        }
        if draft.autoEnterMode != .never {
            items.append(
                localizedAppText(
                    "Enter: \(draft.autoEnterMode.displayName)",
                    de: "Enter: \(draft.autoEnterMode.displayName)",
                    es: "Intro: \(draft.autoEnterMode.displayName)"
                )
            )
        }

        if items.isEmpty {
            return localizedAppText(
                "Language, engine, provider, and output settings. The defaults work for most workflows.",
                de: "Sprache, Engine, Provider und Ausgabe. Die Standardwerte passen für die meisten Workflows.",
                es: "Idioma, motor, proveedor y salida. Los valores predeterminados sirven para la mayoría de los flujos de trabajo."
            )
        }
        return items.joined(separator: " · ")
    }

    private var outputFormatEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localizedAppText("Output Format", de: "Ausgabeformat"))
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                TextField(localizedAppText("e.g. Auto, Markdown, RTF, JSON, plain text", de: "z. B. Auto, Markdown, RTF, JSON, Plain Text"), text: $draft.outputFormat)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(localizedAppText("Output Format", de: "Ausgabeformat"))

                Menu {
                    ForEach(WorkflowOutputFormatPreset.all) { preset in
                        Button(preset.title) {
                            draft.outputFormat = preset.value
                        }
                    }
                } label: {
                    Label(localizedAppText("Presets", de: "Presets"), systemImage: "list.bullet.rectangle")
                }
                .menuStyle(.borderlessButton)
                .help(localizedAppText("Choose an output format preset", de: "Ausgabeformat-Preset wählen"))
            }
        }
    }

    private var autoEnterEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(
                localizedAppText("Press Enter after inserting", de: "Nach dem Einfügen Enter drücken"),
                selection: $draft.autoEnterMode
            ) {
                ForEach(WorkflowAutoEnterMode.allCases.filter { $0.isAvailable || $0 == draft.autoEnterMode }) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                }
            }
            .pickerStyle(.menu)

            Text(draft.autoEnterMode.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            Text(localizedAppText("Action Target", de: "Action-Ziel"))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Picker(
                localizedAppText("Target", de: "Ziel"),
                selection: $draft.targetActionPluginId
            ) {
                Text(localizedAppText("Insert Text", de: "Text einfügen"))
                    .tag(nil as String?)

                ForEach(sortedActionPlugins, id: \.actionId) { plugin in
                    Label(plugin.actionName, systemImage: plugin.actionIcon)
                        .tag(plugin.actionId as String?)
                }

                if let targetActionPluginId = draft.targetActionPluginId,
                   selectedActionTargetIsUnavailable {
                    Text(
                        localizedAppText(
                            "Unavailable Action Target (\(targetActionPluginId))",
                            de: "Nicht verfügbares Action-Ziel (\(targetActionPluginId))",
                            ja: "利用できないアクション対象（\(targetActionPluginId)）",
                            es: "Destino de acción no disponible (\(targetActionPluginId))"
                        )
                    )
                    .tag(targetActionPluginId as String?)
                }
            }

            Text(
                localizedAppText(
                    "Leave this on Insert Text unless the workflow result should trigger a plugin action.",
                    de: "Lass dies auf Text einfügen, wenn das Workflow-Ergebnis keine Plugin-Aktion auslösen soll."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if selectedActionTargetIsUnavailable {
                Text(
                    localizedAppText(
                        "The selected action target is not currently enabled or installed. Saving keeps it unless you choose Insert Text or another action.",
                        de: "Das ausgewählte Action-Ziel ist aktuell nicht aktiviert oder installiert. Speichern behält es bei, solange du nicht Text einfügen oder eine andere Aktion wählst."
                    )
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
            Text(localizedAppText("Transcription Engine", de: "Transkriptions-Engine"))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if engines.isEmpty {
                Text(
                    localizedAppText(
                        "Install a transcription engine in Integrations before using workflow engine overrides.",
                        de: "Installiere zuerst eine Transkriptions-Engine in Integrationen, bevor du Workflow-Engine-Overrides nutzt."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Picker(
                    localizedAppText("Engine", de: "Engine"),
                    selection: workflowTranscriptionEngineBinding
                ) {
                    Text(localizedAppText("Use Global Engine", de: "Globale Engine verwenden"))
                        .tag(nil as String?)
                    ForEach(engines, id: \.providerId) { engine in
                        Text(engine.providerDisplayName).tag(engine.providerId as String?)
                    }
                }
                .disabled(PluginManager.shared.selectionPolicy.enforcesTranscription)
                .managedLockAccessibilityHint(
                    isLocked: PluginManager.shared.selectionPolicy.enforcesTranscription,
                    reason: PluginManager.shared.enforcedTranscriptionResolution?.unavailableReason
                )

                if let enforced = pluginManager.enforcedTranscriptionResolution {
                    ManagedByOrganizationLabel(text: enforced.unavailableReason ?? String(localized: "Managed by your organization."))
                }

                Text(
                    draft.transcriptionEngineId == nil
                        ? localizedAppText(
                            "This workflow follows the global transcription engine setting.",
                            de: "Dieser Workflow folgt der globalen Transkriptions-Engine-Einstellung."
                        )
                        : localizedAppText(
                            "This workflow starts dictation with its own transcription engine.",
                            de: "Dieser Workflow startet das Diktat mit einer eigenen Transkriptions-Engine."
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let engineId = draft.transcriptionEngineId {
                    let models = transcriptionModels(for: engineId)
                    if !models.isEmpty {
                        Picker(
                            localizedAppText("Model", de: "Modell"),
                            selection: workflowTranscriptionModelBinding
                        ) {
                            Text(localizedAppText("Engine Default", de: "Engine-Standard"))
                                .tag(nil as String?)
                            ForEach(models, id: \.id) { model in
                                Text(model.displayName).tag(model.id as String?)
                            }
                        }
                        .disabled(PluginManager.shared.selectionPolicy.enforcesTranscription)
                        .managedLockAccessibilityHint(
                            isLocked: PluginManager.shared.selectionPolicy.enforcesTranscription,
                            reason: PluginManager.shared.enforcedTranscriptionResolution?.unavailableReason
                        )

                        Text(
                            localizedAppText(
                                "Leave the model on Engine Default to follow the engine's selected model.",
                                de: "Lass das Modell auf Engine-Standard, um dem ausgewählten Modell der Engine zu folgen."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var workflowMicrophoneBoostSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localizedAppText("Whisper Mode (AGC)", de: "Whisper-Modus (AGC)"))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Picker(
                localizedAppText("Whisper Mode", de: "Whisper-Modus"),
                selection: workflowMicrophoneBoostBinding
            ) {
                ForEach(WorkflowMicrophoneBoostOverride.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            Text(
                draft.microphoneBoostOverride == nil
                    ? localizedAppText(
                        "This workflow follows the global Whisper Mode setting.",
                        de: "Dieser Workflow folgt der globalen Whisper-Modus-Einstellung."
                    )
                    : localizedAppText(
                        "This workflow overrides Whisper Mode while it records.",
                        de: "Dieser Workflow überschreibt den Whisper-Modus während der Aufnahme."
                    )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var workflowInlineCommandsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(String(localized: "Inline Commands"), isOn: workflowInlineCommandsBinding)

            Text(
                draft.inlineCommandsEnabled == true
                    ? localizedAppText(
                        "A spoken instruction like \"write this as a friendly email\" is detected, removed, and applied to the dictation.",
                        de: "Eine gesprochene Anweisung wie \"schreib das als freundliche E-Mail\" wird erkannt, entfernt und auf das Diktat angewendet."
                    )
                    : localizedAppText(
                        "Dictated text is inserted unchanged. Turn on to detect a spoken transformation instruction in the dictation.",
                        de: "Diktierter Text wird unverändert eingefügt. Aktivieren, um eine gesprochene Umwandlungsanweisung im Diktat zu erkennen."
                    )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workflowSegmentedPostProcessingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                String(localized: "Process long dictations in segments"),
                isOn: workflowSegmentedPostProcessingBinding
            )

            Text(
                String(
                    localized: "Speeds up long dictations by processing the text in parts. With a streaming engine and live preview, finished sentences are processed while you speak; otherwise, with cloud providers, the parts run in parallel after recording. Uses more requests. Not suitable for workflows that need the whole text at once, such as summaries or JSON."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workflowSegmentedPostProcessingBinding: Binding<Bool> {
        Binding(
            get: { draft.segmentedPostProcessingEnabled ?? false },
            set: { draft.segmentedPostProcessingEnabled = $0 }
        )
    }

    private var workflowInlineCommandsBinding: Binding<Bool> {
        Binding(
            get: { draft.inlineCommandsEnabled ?? false },
            set: { draft.inlineCommandsEnabled = $0 }
        )
    }

    private var workflowInputLanguageEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localizedAppText("Spoken Language", de: "Gesprochene Sprache"))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            LanguageSelectionEditor(
                selection: $draft.inputLanguageSelection,
                availableLanguages: settingsViewModel.availableLanguages,
                nilBehavior: .inheritGlobal,
                inheritTitle: localizedAppText("Global Setting", de: "Globale Einstellung"),
                hintBehavior: LanguageSelectionHintBehavior(engine: workflowLanguageEngine)
            )
        }
    }

    private var workflowLanguageEngine: TranscriptionEnginePlugin? {
        if let engineId = draft.transcriptionEngineId,
           let engine = pluginManager.transcriptionEngine(for: engineId) {
            return engine
        }
        return settingsViewModel.activeTranscriptionEngine
    }

    @ViewBuilder
    private var translationProcessorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localizedAppText("Translation Mode", de: "Übersetzungsmodus"))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Picker(localizedAppText("Translation Mode", de: "Übersetzungsmodus"), selection: $draft.translationProcessor) {
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
                        Text(localizedAppText("Target Language", de: "Zielsprache"))
                            .font(.subheadline.weight(.semibold))
                        Picker(localizedAppText("Target Language", de: "Zielsprache"), selection: $draft.translationTargetLanguage) {
                            ForEach(TranslationService.availableTargetLanguages, id: \.code) { language in
                                Text(language.name).tag(language.code)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } else {
                    Text(localizedAppText(
                        "Apple Translate requires macOS 15 or later. Choose LLM Prompt on this Mac.",
                        de: "Apple Translate benötigt macOS 15 oder neuer. Wähle auf diesem Mac LLM-Prompt."
                    ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                #else
                Text(localizedAppText(
                    "Apple Translate is not available in this build. Choose LLM Prompt instead.",
                    de: "Apple Translate ist in diesem Build nicht verfügbar. Wähle stattdessen LLM-Prompt."
                ))
                .font(.caption)
                .foregroundStyle(.orange)
                #endif
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localizedAppText("Target Language", de: "Zielsprache"))
                        .font(.subheadline.weight(.semibold))
                    TextField(localizedAppText("e.g. English", de: "z. B. Englisch"), text: $draft.translationTargetLanguage)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(localizedAppText("Target Language", de: "Zielsprache"))
                }
            }
        }
    }

    private var workflowProviderOverrideSection: some View {
        let providers = promptProcessingService.availableProviders

        return VStack(alignment: .leading, spacing: 12) {
            Text(localizedAppText("LLM Override", de: "LLM-Override"))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if providers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        localizedAppText(
                            "Install an LLM provider in Integrations before using workflow overrides.",
                            de: "Installiere zuerst einen LLM-Provider in Integrationen, bevor du Workflow-Overrides nutzt."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button(localizedAppText("Open Integrations", de: "Integrationen öffnen")) {
                        SettingsNavigationCoordinator.shared.navigate(to: .integrations)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            } else {
                Picker(
                    localizedAppText("Provider", de: "Provider"),
                    selection: workflowProviderOverrideBinding
                ) {
                    Text(globalFallbackListPickerLabel)
                    .tag(nil as String?)

                    ForEach(providers, id: \.id) { provider in
                        Text(provider.displayName).tag(provider.id as String?)
                    }
                }
                .disabled(PluginManager.shared.selectionPolicy.enforcesLlm)
                .managedLockAccessibilityHint(
                    isLocked: PluginManager.shared.selectionPolicy.enforcesLlm,
                    reason: PluginManager.shared.enforcedLlmResolution?.unavailableReason
                )

                if let enforced = pluginManager.enforcedLlmResolution {
                    ManagedByOrganizationLabel(text: enforced.unavailableReason ?? String(localized: "Managed by your organization."))
                }

                Text(
                    draft.providerId == nil
                        ? localizedAppText(
                            "This workflow currently inherits the global LLM fallback list from Workflow settings.",
                            de: "Dieser Workflow übernimmt aktuell die globale LLM-Fallback-Liste aus den Workflow-Einstellungen."
                        )
                        : localizedAppText(
                            "This workflow uses only its selected provider and does not use global fallbacks.",
                            de: "Dieser Workflow verwendet nur seinen ausgewählten Provider und keine globalen Fallbacks."
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let providerId = draft.providerId {
                    let models = promptProcessingService.modelsForProvider(providerId)
                    if !models.isEmpty {
                        Picker(
                            localizedAppText("Model", de: "Modell"),
                            selection: workflowModelOverrideBinding
                        ) {
                            Text(localizedAppText("Provider Default", de: "Provider-Standard"))
                                .tag(nil as String?)
                            ForEach(models, id: \.id) { model in
                                Text(model.displayName).tag(model.id as String?)
                            }
                        }
                        .disabled(PluginManager.shared.selectionPolicy.enforcesLlm)
                        .managedLockAccessibilityHint(
                            isLocked: PluginManager.shared.selectionPolicy.enforcesLlm,
                            reason: PluginManager.shared.enforcedLlmResolution?.unavailableReason
                        )

                        Text(
                            localizedAppText(
                                "Leave the model on Provider Default to follow the selected provider's preferred model.",
                                de: "Lass das Modell auf Provider-Standard, um dem bevorzugten Modell des ausgewählten Providers zu folgen."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    let efforts = promptProcessingService.effortsForProvider(
                        providerId,
                        modelId: draft.cloudModel
                    )
                    if !efforts.isEmpty || draft.effortId != nil {
                        Picker(
                            localizedAppText("Effort", de: "Effort"),
                            selection: workflowEffortOverrideBinding
                        ) {
                            Text(workflowProviderDefaultEffortLabel(
                                providerId: providerId,
                                efforts: efforts
                            ))
                            .tag(nil as String?)

                            if let selectedEffortID = draft.effortId,
                               !efforts.contains(where: { $0.id == selectedEffortID }) {
                                Text(selectedEffortID).tag(selectedEffortID as String?)
                            }

                            ForEach(efforts, id: \.id) { effort in
                                Text(effort.displayName).tag(effort.id as String?)
                            }
                        }
                        .disabled(PluginManager.shared.selectionPolicy.enforcesLlm)
                        .managedLockAccessibilityHint(
                            isLocked: PluginManager.shared.selectionPolicy.enforcesLlm,
                            reason: PluginManager.shared.enforcedLlmResolution?.unavailableReason
                        )

                        Text(
                            localizedAppText(
                                "Leave effort on Provider Default to follow the selected model's recommended setting.",
                                de: "Lass Effort auf Provider-Standard, um der empfohlenen Einstellung des ausgewählten Modells zu folgen."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if !promptProcessingService.isProviderReady(providerId) {
                        Text(
                            localizedAppText(
                                "This provider is not ready yet. Finish its setup in Integrations before this workflow can use it.",
                                de: "Dieser Provider ist noch nicht einsatzbereit. Schließe sein Setup in Integrationen ab, bevor der Workflow ihn nutzen kann."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var globalFallbackListPickerLabel: String {
        guard let primaryFallbackItem = promptProcessingService.primaryFallbackItem else {
            return localizedAppText("Use Global Fallback List", de: "Globale Fallback-Liste verwenden")
        }

        let providerName = promptProcessingService.displayName(for: primaryFallbackItem.providerId)
        return localizedAppText(
            "Use Global Fallback List (starts with \(providerName))",
            de: "Globale Fallback-Liste verwenden (beginnt mit \(providerName))",
            ja: "グローバルフォールバックリストを使用（最初: \(providerName)）",
            es: "Usar la lista global de respaldos (empieza por \(providerName))"
        )
    }

    private func workflowProviderDefaultEffortLabel(
        providerId: String,
        efforts: [PluginLLMEffortInfo]
    ) -> String {
        guard let defaultEffortID = promptProcessingService.defaultEffortId(
            for: providerId,
            modelId: draft.cloudModel
        ),
        let displayName = efforts.first(where: { $0.id == defaultEffortID })?.displayName
        else {
            return localizedAppText("Provider Default", de: "Provider-Standard")
        }
        return localizedAppText(
            "Provider Default (\(displayName))",
            de: "Provider-Standard (\(displayName))",
            es: "Predeterminado del proveedor (\(displayName))"
        )
    }

    private var triggerSection: some View {
        WorkflowSectionCard(
            title: localizedAppText("Trigger", de: "Trigger"),
            description: localizedAppText(
                "Choose how this workflow starts. Automatic can use app, website, hotkey, or combinations.",
                de: "Wähle, wie dieser Workflow startet. Automatisch kann App, Website, Hotkey oder Kombinationen nutzen."
            )
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker(localizedAppText("Trigger", de: "Trigger"), selection: $draft.triggerMode) {
                    Text(localizedAppText("Automatic", de: "Automatisch")).tag(WorkflowTriggerMode.automatic)
                    if draft.template != .dictation {
                        Text(localizedAppText("Manual", de: "Manuell")).tag(WorkflowTriggerMode.manual)
                    }
                    Text(localizedAppText("Always", de: "Immer")).tag(WorkflowTriggerMode.global)
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
            title: localizedAppText("Review", de: "Review"),
            description: localizedAppText("This is how the workflow currently reads before saving.", de: "So liest sich der Workflow aktuell vor dem Speichern.")
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
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(localizedAppText("Manual", de: "Manuell"))
                    .font(.subheadline.weight(.medium))

                Text(
                    localizedAppText(
                        "Available from the Workflow Palette. It never runs automatically after dictation.",
                        de: "Verfügbar über die Workflow-Palette. Läuft nach dem Diktat nie automatisch."
                    )
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
        .accessibilityElement(children: .combine)
    }

    private var automaticTriggerEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            triggerComponentEditor(
                title: localizedAppText("App", de: "App"),
                isOn: $draft.isAppTriggerEnabled
            ) {
                appTriggerEditor
            }

            // The sandboxed App Store edition cannot read browser URLs itself. A
            // website trigger only matches once a browser extension reports tabs.
            #if APPSTORE
            if browserExtensionConnected {
                Divider()
                websiteTriggerComponent
            }
            #else
            Divider()
            websiteTriggerComponent
            #endif

            Divider()

            triggerComponentEditor(
                title: localizedAppText("Hotkey", de: "Hotkey"),
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
        appListEditor(
            bundleIdentifiers: $draft.appBundleIdentifiers,
            emptyText: localizedAppText("No apps selected yet.", de: "Noch keine Apps ausgewählt."),
            pickerTarget: .trigger
        )
    }

    /// The selected apps with remove buttons and the button that opens the app picker.
    private func appListEditor(
        bundleIdentifiers: Binding<[String]>,
        emptyText: String,
        pickerTarget: AppPickerTarget
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if bundleIdentifiers.wrappedValue.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(bundleIdentifiers.wrappedValue, id: \.self) { bundleId in
                        WorkflowSelectionRow(
                            title: installedAppName(for: bundleId),
                            subtitle: bundleId,
                            icon: installedAppIcon(for: bundleId)
                        ) {
                            bundleIdentifiers.wrappedValue.removeAll { $0 == bundleId }
                        }
                    }
                }
            }

            Button(localizedAppText("Select Apps…", de: "Apps auswählen…")) {
                appPickerTarget = pickerTarget
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var websiteTriggerComponent: some View {
        triggerComponentEditor(
            title: localizedAppText("Website", de: "Website"),
            isOn: $draft.isWebsiteTriggerEnabled
        ) {
            websiteTriggerEditor
        }
    }

    private var websiteTriggerEditor: some View {
        websiteListEditor(
            patterns: draft.websitePatterns,
            input: $websiteInput,
            emptyText: localizedAppText("No websites added yet.", de: "Noch keine Websites hinzugefügt."),
            rowSubtitle: localizedAppText("Website trigger", de: "Website-Trigger"),
            fieldLabel: localizedAppText("Website", de: "Website"),
            add: { draft.addWebsitePattern($0) },
            remove: { pattern in draft.websitePatterns.removeAll { $0 == pattern } }
        )
    }

    /// The added websites with remove buttons, the domain field, and history suggestions.
    private func websiteListEditor(
        patterns: [String],
        input: Binding<String>,
        emptyText: String,
        rowSubtitle: String,
        fieldLabel: String,
        add: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        let suggestions = websiteSuggestionStore.suggestions(for: input.wrappedValue, excluding: patterns)

        return VStack(alignment: .leading, spacing: 10) {
            #if APPSTORE
            Text(localizedAppText(
                "Matches in browsers with the TypeWhisper extension.",
                de: "Greift in Browsern mit der TypeWhisper-Erweiterung."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            #endif

            if patterns.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(patterns, id: \.self) { pattern in
                        WorkflowSelectionRow(
                            title: pattern,
                            subtitle: rowSubtitle,
                            iconSystemName: "globe"
                        ) {
                            remove(pattern)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                TextField(String(localized: "docs.github.com"), text: input)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(fieldLabel)
                    .onSubmit {
                        addWebsite(from: input, add: add)
                    }

                Button(localizedAppText("Add", de: "Hinzufügen")) {
                    addWebsite(from: input, add: add)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localizedAppText("Suggested websites", de: "Vorgeschlagene Websites"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(suggestions, id: \.self) { domain in
                            Button(domain) {
                                add(domain)
                                input.wrappedValue = ""
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

            Text(localizedAppText("You can paste a full URL; only the domain is kept.", de: "Du kannst eine komplette URL einfügen; gespeichert wird nur die Domain."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            await websiteSuggestionStore.loadIfNeeded()
        }
    }

    private var hotkeyTriggerEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localizedAppText("Shortcut Behavior", de: "Shortcut-Verhalten"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker(
                    localizedAppText("Shortcut Behavior", de: "Shortcut-Verhalten"),
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
                Text(localizedAppText("No shortcuts recorded yet.", de: "Noch keine Shortcuts aufgenommen."))
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
                title: localizedAppText("Add Shortcut", de: "Shortcut hinzufügen"),
                subtitle: nil,
                onRecord: { hotkey in
                    addRecordedHotkey(hotkey)
                },
                onClear: {},
                visualKeyboardExistingAssignment: { candidate in
                    if draft.containsEquivalentHotkey(candidate) {
                        return localizedAppText("this workflow", de: "diesem Workflow")
                    }
                    if let workflowId = hotkeyService.isHotkeyAssignedToWorkflow(
                        candidate,
                        excludingWorkflowId: workflow?.id
                    ),
                        let conflictWorkflow = workflowService.workflow(id: workflowId) {
                        return String(localized: "the “\(conflictWorkflow.name)” workflow shortcut")
                    }
                    return HotkeyRecorderView.globalSlotAssignmentDescription(for: candidate)
                }
            )
        }
    }

    private var alwaysTriggerEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "infinity")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localizedAppText("Always", de: "Immer"))
                        .font(.subheadline.weight(.medium))

                    Text(
                        localizedAppText(
                            "Runs when no app or website workflow matches. Hotkeys stay direct triggers.",
                            de: "Läuft, wenn kein App- oder Website-Workflow passt. Hotkeys bleiben direkte Trigger."
                        )
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
            .accessibilityElement(children: .combine)

            alwaysTriggerExclusionsEditor

            Text(localizedAppText(
                "This workflow does not run in excluded apps and websites. Other matching workflows still do.",
                de: "In ausgeschlossenen Apps und Websites läuft dieser Workflow nicht. Andere passende Workflows laufen dort weiterhin."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var alwaysTriggerExclusionsEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            triggerComponentEditor(
                title: localizedAppText("Exclude apps", de: "Apps ausschließen"),
                isOn: $draft.isAppExclusionEnabled
            ) {
                appListEditor(
                    bundleIdentifiers: $draft.excludedAppBundleIdentifiers,
                    emptyText: localizedAppText("No apps excluded yet.", de: "Noch keine Apps ausgeschlossen."),
                    pickerTarget: .exclusions
                )
            }

            // Like the website trigger, this needs browser URLs, which the sandboxed
            // App Store edition only gets from the browser extension.
            #if APPSTORE
            if browserExtensionConnected {
                Divider()
                excludedWebsitesComponent
            }
            #else
            Divider()
            excludedWebsitesComponent
            #endif
        }
        .background(workflowsGroupedSurface(cornerRadius: 12))
    }

    private var excludedWebsitesComponent: some View {
        triggerComponentEditor(
            title: localizedAppText("Exclude websites", de: "Websites ausschließen"),
            isOn: $draft.isWebsiteExclusionEnabled
        ) {
            websiteListEditor(
                patterns: draft.excludedWebsitePatterns,
                input: $excludedWebsiteInput,
                emptyText: localizedAppText("No websites excluded yet.", de: "Noch keine Websites ausgeschlossen."),
                rowSubtitle: localizedAppText("Excluded website", de: "Ausgeschlossene Website"),
                fieldLabel: localizedAppText("Website to exclude", de: "Auszuschließende Website"),
                add: { draft.addExcludedWebsitePattern($0) },
                remove: { pattern in draft.excludedWebsitePatterns.removeAll { $0 == pattern } }
            )
        }
    }

    private func save() {
        if let validationError = draft.validationError(
            hotkeyService: hotkeyService,
            workflowService: workflowService,
            pluginManager: pluginManager,
            existingWorkflowId: workflow?.id
        ) {
            presentValidationMessage(validationError)
            return
        }

        guard let trigger = draft.resolvedTrigger() else {
            presentValidationMessage(localizedAppText(
                "The selected trigger is incomplete.",
                de: "Der ausgewählte Trigger ist unvollständig."
            ))
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

    /// Shows a validation problem and announces it, because the banner appears at the top of
    /// the scrolled editor where a VoiceOver user would not otherwise notice it.
    private func presentValidationMessage(_ message: String) {
        validationMessage = message
        AccessibilityNotification.Announcement(message).post()
    }

    private func installedAppName(for bundleId: String) -> String {
        installedAppsViewModel.installedApps.first(where: { $0.id == bundleId })?.name
            ?? workflowAppDisplayName(for: bundleId)
    }

    private func installedAppIcon(for bundleId: String) -> NSImage? {
        installedAppsViewModel.installedApps.first(where: { $0.id == bundleId })?.icon
    }

    private func addWebsite(from input: Binding<String>, add: (String) -> Void) {
        let normalized = workflowNormalizedDomainFromInput(input.wrappedValue)
        guard !normalized.isEmpty else { return }
        add(normalized)
        input.wrappedValue = ""
        validationMessage = nil
    }

    private func addRecordedHotkey(_ hotkey: UnifiedHotkey) {
        if draft.containsEquivalentHotkey(hotkey) {
            presentValidationMessage(localizedAppText(
                "This shortcut is already part of the workflow.",
                de: "Dieser Shortcut ist bereits Teil des Workflows."
            ))
            return
        }

        if let workflowId = hotkeyService.isHotkeyAssignedToWorkflow(hotkey, excludingWorkflowId: workflow?.id),
           let conflictWorkflow = workflowService.workflow(id: workflowId) {
            presentValidationMessage(localizedAppText(
                "This hotkey is already used by workflow “\(conflictWorkflow.name)”.",
                de: "Dieser Hotkey wird bereits vom Workflow „\(conflictWorkflow.name)“ verwendet.",
                ja: "このホットキーはすでにワークフロー「\(conflictWorkflow.name)」で使用されています。",
                es: "El flujo de trabajo “\(conflictWorkflow.name)” ya usa este atajo de teclado."
            ))
            return
        }

        if let slot = hotkeyService.isHotkeyAssignedToGlobalSlot(hotkey) {
            presentValidationMessage(localizedAppText(
                "This hotkey is already used by the global slot “\(slot.rawValue)”.",
                de: "Dieser Hotkey wird bereits vom globalen Slot „\(slot.rawValue)“ verwendet.",
                ja: "このホットキーはすでにグローバルスロット「\(slot.rawValue)」で使用されています。",
                es: "El espacio global “\(slot.rawValue)” ya usa este atajo de teclado."
            ))
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
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(definition.name)
                    .font(.headline)
                Text(definition.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                WorkflowBadge(title: localizedAppText("Template fixed after creation", de: "Vorlage nach Erstellung fix"))
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        }
        .accessibilityElement(children: .combine)
    }

    private var workflowProviderOverrideBinding: Binding<String?> {
        Binding(
            get: { draft.providerId },
            set: { providerId in
                let providerChanged = draft.providerId != providerId
                draft.providerId = providerId
                if providerId == nil {
                    draft.cloudModel = nil
                    draft.effortId = nil
                    return
                }

                if providerChanged {
                    draft.effortId = nil
                }

                if let cloudModel = draft.cloudModel,
                   let providerId,
                   !promptProcessingService.modelsForProvider(providerId).contains(where: { $0.id == cloudModel }) {
                    draft.cloudModel = nil
                    draft.effortId = nil
                }
            }
        )
    }

    private var workflowModelOverrideBinding: Binding<String?> {
        Binding(
            get: { draft.cloudModel },
            set: { modelId in
                if draft.cloudModel != modelId {
                    draft.effortId = nil
                }
                draft.cloudModel = modelId
            }
        )
    }

    private var workflowEffortOverrideBinding: Binding<String?> {
        Binding(
            get: { draft.effortId },
            set: { effortId in
                draft.effortId = effortId
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

    private var workflowMicrophoneBoostBinding: Binding<WorkflowMicrophoneBoostOverride> {
        Binding(
            get: { WorkflowMicrophoneBoostOverride(value: draft.microphoneBoostOverride) },
            set: { option in
                draft.microphoneBoostOverride = option.value
            }
        )
    }

    private var numberNormalizationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(localizedAppText("Number formatting", de: "Zahlenformatierung"), selection: $draft.numberNormalizationMode) {
                ForEach(WorkflowNumberNormalizationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Text(localizedAppText(
                "Controls whether spoken numbers in supported languages are converted to digits for this workflow.",
                de: "Steuert, ob gesprochene Zahlen in unterstützten Sprachen in diesem Workflow zu Ziffern werden."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
        // The selection is otherwise only shown by the tint and the checkmark.
        .accessibilityLabel(definition.name)
        .accessibilityHint(definition.description)
        .accessibilityValue(isSelected ? String(localized: "Selected") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                    .accessibilityHidden(true)
            } else if let iconSystemName {
                Image(systemName: iconSystemName)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
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
            .accessibilityElement(children: .combine)

            Spacer()

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Remove"))
            .accessibilityLabel(String(localized: "Remove \(title)"))
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
                    .accessibilityLabel(title)
                    .accessibilityHint(placeholder)

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholder)
                        .font(editorFont)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, placeholderLeadingInset)
                        .padding(.top, placeholderTopInset)
                        .padding(.trailing, 12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
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
                Text(localizedAppText("Select Apps", de: "Apps auswählen"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding()

            Divider()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(localizedAppText("Search Apps…", de: "Apps durchsuchen…"), text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(localizedAppText("Search Apps…", de: "Apps durchsuchen…"))
                    .accessibilityAddTraits(.isSearchField)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Clear search"))
                    .accessibilityLabel(String(localized: "Clear search"))
                }
            }
            .padding(8)

            Divider()

            List(filteredApps) { app in
                let isSelected = selectedBundleIdentifiers.contains(app.id)

                // A plain button keeps the row's look but makes it reachable by keyboard and
                // VoiceOver, which a tap gesture alone is not.
                Button {
                    toggleSelection(app.id)
                } label: {
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .accessibilityHidden(true)
                        }
                        Text(app.name)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.name)
                .accessibilityValue(isSelected ? String(localized: "Selected") : "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Spacer()
                Button(localizedAppText("Done", de: "Fertig")) {
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
    var compact = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                Text(title)
                    .font(compact ? Font.subheadline.weight(.semibold) : Font.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(description)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(compact ? 12 : 16)
        .background {
            workflowsElevatedPanel(cornerRadius: compact ? 14 : 18)
        }
    }
}

private struct WorkflowBadge: View {
    let title: String
    var compact: Bool = false
    var tint: Color = .secondary.opacity(0.12)
    var foreground: Color = .secondary
    var maxTextWidth: CGFloat?

    var body: some View {
        label
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 6)
            .background(tint, in: Capsule())
            .foregroundStyle(foreground)
            .help(title)
    }

    @ViewBuilder
    private var label: some View {
        let text = Text(title)
            .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)

        if let maxTextWidth {
            text.frame(maxWidth: maxTextWidth, alignment: .leading)
        } else {
            text
        }
    }
}

private struct ValidationBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        }
        .accessibilityElement(children: .combine)
    }
}

/// The spoken state of a custom disclosure button, which otherwise only shows it by the
/// direction of its chevron.
private func workflowDisclosureState(isExpanded: Bool) -> String {
    isExpanded
        ? localizedAppText("Expanded", de: "Ausgeklappt", ja: "展開", zh: "已展开")
        : localizedAppText("Collapsed", de: "Eingeklappt", ja: "折りたたみ", zh: "已折叠")
}

private struct MissingWorkflowPage: View {
    @ObservedObject private var navigation = WorkflowsNavigationCoordinator.shared

    var body: some View {
        ContentUnavailableView {
            Label(localizedAppText("Workflow Not Found", de: "Workflow nicht gefunden"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(localizedAppText("The selected workflow no longer exists.", de: "Der ausgewählte Workflow existiert nicht mehr."))
        } actions: {
            Button(localizedAppText("Back to List", de: "Zurück zur Liste")) {
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

enum WorkflowMicrophoneBoostOverride: String, CaseIterable, Hashable, Identifiable {
    case inherit
    case on
    case off

    var id: String { rawValue }

    var value: Bool? {
        switch self {
        case .inherit:
            nil
        case .on:
            true
        case .off:
            false
        }
    }

    init(value: Bool?) {
        switch value {
        case .some(true):
            self = .on
        case .some(false):
            self = .off
        case .none:
            self = .inherit
        }
    }

    var title: String {
        switch self {
        case .inherit:
            localizedAppText("Use Global Whisper Mode", de: "Globalen Whisper-Modus verwenden")
        case .on:
            localizedAppText("Whisper Mode On", de: "Whisper-Modus ein")
        case .off:
            localizedAppText("Whisper Mode Off", de: "Whisper-Modus aus")
        }
    }
}

/// Loads the most frequent history domains once per workflow editor and filters that cached
/// list while typing, instead of scanning the complete history on every render.
@MainActor
final class WorkflowWebsiteSuggestionStore: ObservableObject {
    static let domainLimit = 8

    @Published private(set) var domains: [String] = []
    private let loadDomains: @MainActor () async -> [String]
    private var hasLoadedDomains = false
    private var loadGeneration = 0

    init(
        loadDomains: @escaping @MainActor () async -> [String] = {
            await ServiceContainer.shared.historyService.uniqueDomainsInBackground(
                limit: WorkflowWebsiteSuggestionStore.domainLimit
            )
        }
    ) {
        self.loadDomains = loadDomains
    }

    /// Loads the domains unless an earlier load finished. A load whose task was cancelled, such
    /// as when the editor disappears, stops its scan and leaves the next appearance to load again.
    func loadIfNeeded() async {
        guard !hasLoadedDomains else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        let loaded = await loadDomains()
        guard !Task.isCancelled, generation == loadGeneration else { return }
        hasLoadedDomains = true
        domains = loaded
    }

    func suggestions(for input: String, excluding websitePatterns: [String]) -> [String] {
        let query = workflowNormalizedDomain(input)

        if query.isEmpty {
            return domains.filter { !websitePatterns.contains($0) }
        }

        return domains.filter { domain in
            !websitePatterns.contains(domain) && domain.localizedCaseInsensitiveContains(query)
        }
    }
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
    /// Exclusions of the Always trigger. Like the automatic trigger components, a list
    /// is only saved while its checkbox is on.
    var isAppExclusionEnabled: Bool
    var isWebsiteExclusionEnabled: Bool
    var excludedAppBundleIdentifiers: [String]
    var excludedWebsitePatterns: [String]
    var fineTuning: String
    var inputLanguageSelection: LanguageSelection
    var translationTargetLanguage: String
    var translationProcessor: WorkflowTranslationProcessor
    var customInstruction: String
    var outputFormat: String
    var autoEnterMode: WorkflowAutoEnterMode
    var numberNormalizationMode: WorkflowNumberNormalizationMode
    var transcriptionEngineId: String?
    var transcriptionModelId: String?
    var microphoneBoostOverride: Bool?
    var inlineCommandsEnabled: Bool?
    var segmentedPostProcessingEnabled: Bool?

    private var preservedBehaviorSettings: [String: String]
    var providerId: String?
    var cloudModel: String?
    var effortId: String?
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
        self.isAppExclusionEnabled = false
        self.isWebsiteExclusionEnabled = false
        self.excludedAppBundleIdentifiers = []
        self.excludedWebsitePatterns = []
        self.fineTuning = ""
        self.inputLanguageSelection = .inheritGlobal
        self.translationProcessor = template == .translation ? Self.defaultTranslationProcessor : .llmPrompt
        self.translationTargetLanguage = template == .translation
            ? Self.defaultTranslationTargetLanguage(for: translationProcessor)
            : ""
        self.customInstruction = ""
        self.outputFormat = ""
        self.autoEnterMode = .never
        self.numberNormalizationMode = .inherit
        self.transcriptionEngineId = nil
        self.transcriptionModelId = nil
        self.microphoneBoostOverride = nil
        self.inlineCommandsEnabled = nil
        self.segmentedPostProcessingEnabled = nil
        self.preservedBehaviorSettings = [:]
        self.providerId = nil
        self.cloudModel = nil
        self.effortId = nil
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
        self.autoEnterMode = output.autoEnterMode
        self.numberNormalizationMode = output.numberNormalizationMode
        self.transcriptionEngineId = workflow.template == .dictation ? behavior.transcriptionEngineId : nil
        self.transcriptionModelId = workflow.template == .dictation ? behavior.transcriptionModelId : nil
        self.microphoneBoostOverride = behavior.microphoneBoostOverride
        self.inlineCommandsEnabled = workflow.template == .dictation ? behavior.inlineCommandsEnabled : nil
        self.segmentedPostProcessingEnabled = behavior.segmentedPostProcessingEnabled
        self.hotkeyBehavior = .startDictation
        self.preservedBehaviorSettings = behavior.settings
        self.providerId = behavior.providerId
        self.cloudModel = behavior.cloudModel
        self.effortId = behavior.effortId
        self.temperatureModeRaw = behavior.temperatureModeRaw
        self.temperatureValue = behavior.temperatureValue
        self.targetActionPluginId = workflow.template == .dictation ? nil : output.targetActionPluginId

        if let trigger = workflow.trigger {
            self.appBundleIdentifiers = trigger.appBundleIdentifiers
            self.websitePatterns = trigger.websitePatterns
            self.hotkeys = trigger.hotkeys
            self.hotkeyBehavior = trigger.hotkeyBehavior
            self.excludedAppBundleIdentifiers = trigger.excludedAppBundleIdentifiers
            self.excludedWebsitePatterns = trigger.excludedWebsitePatterns
            // Only Always uses exclusions, so other kinds open with them off and drop them on save.
            self.isAppExclusionEnabled = trigger.kind == .global && !trigger.excludedAppBundleIdentifiers.isEmpty
            self.isWebsiteExclusionEnabled = trigger.kind == .global && !trigger.excludedWebsitePatterns.isEmpty

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
            self.isAppExclusionEnabled = false
            self.isWebsiteExclusionEnabled = false
            self.excludedAppBundleIdentifiers = []
            self.excludedWebsitePatterns = []
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
        !usesAppleTranslate && (template != .dictation || inlineCommandsEnabled == true)
    }

    /// Mirrors `Workflow.supportsSegmentedPostProcessing`: a per-sentence
    /// prompt template that is not processed by Apple Translate.
    var supportsSegmentedPostProcessing: Bool {
        template.allowsSegmentedPostProcessing && !usesAppleTranslate
    }

    var reviewText: String {
        let languageSentence = localizedAppText(
            " Spoken language: \(workflowInputLanguageSummary(for: inputLanguageSelection)).",
            de: " Gesprochene Sprache: \(workflowInputLanguageSummary(for: inputLanguageSelection)).",
            ja: " 話す言語: \(workflowInputLanguageSummary(for: inputLanguageSelection))。",
            es: " Idioma hablado: \(workflowInputLanguageSummary(for: inputLanguageSelection))."
        )
        let outputRouteSentence = workflowOutputRouteSentence(targetActionPluginId: targetActionPluginId)

        if triggerMode == .manual {
            return localizedAppText(
                "\(resolvedName) is available as \(template.definition.name) from the Workflow Palette.\(languageSentence)\(outputRouteSentence)",
                de: "\(resolvedName) ist als \(template.definition.name) über die Workflow-Palette verfügbar.\(languageSentence)\(outputRouteSentence)",
                ja: "\(resolvedName)はワークフローパレットから\(template.definition.name)として利用できます。\(languageSentence)\(outputRouteSentence)",
                es: "\(resolvedName) está disponible como \(template.definition.name) desde la paleta de flujos de trabajo.\(languageSentence)\(outputRouteSentence)"
            )
        }

        if triggerMode == .global {
            let exclusions = workflowExclusionSummary(for: resolvedTrigger())
            let exclusionSentence = exclusions.isEmpty ? "" : localizedAppText(
                " \(exclusions).",
                de: " \(exclusions).",
                ja: " \(exclusions)。",
                es: " \(exclusions)."
            )
            return localizedAppText(
                "\(resolvedName) runs always as \(template.definition.name).\(exclusionSentence)\(languageSentence)\(outputRouteSentence)",
                de: "\(resolvedName) läuft immer als \(template.definition.name).\(exclusionSentence)\(languageSentence)\(outputRouteSentence)",
                ja: "\(resolvedName)は常に\(template.definition.name)として実行されます。\(exclusionSentence)\(languageSentence)\(outputRouteSentence)",
                es: "\(resolvedName) se ejecuta siempre como \(template.definition.name).\(exclusionSentence)\(languageSentence)\(outputRouteSentence)"
            )
        }

        return localizedAppText(
            "\(resolvedName) runs as \(template.definition.name) via \(triggerReviewText).\(languageSentence)\(outputRouteSentence)",
            de: "\(resolvedName) läuft als \(template.definition.name) über \(triggerReviewText).\(languageSentence)\(outputRouteSentence)",
            ja: "\(resolvedName)は\(triggerReviewText)により\(template.definition.name)として実行されます。\(languageSentence)\(outputRouteSentence)",
            es: "\(resolvedName) se ejecuta como \(template.definition.name) mediante \(triggerReviewText).\(languageSentence)\(outputRouteSentence)"
        )
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
            effortId = nil
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
            inlineCommandsEnabled = nil
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
            return localizedAppText(
                "Dictation Only workflows need a recording trigger.",
                de: "Nur-Diktat-Workflows brauchen einen Aufnahme-Trigger."
            )
        }

        // An enforced pair replaces the override and locks its pickers; the saved override is kept
        // for when the pair is removed and must not block other edits.
        if template == .dictation,
           !pluginManager.selectionPolicy.enforcesTranscription,
           let transcriptionEngineId,
           !transcriptionEngineId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let engine = pluginManager.transcriptionEngine(for: transcriptionEngineId) else {
                return localizedAppText(
                    "The selected transcription engine is not installed.",
                    de: "Die ausgewählte Transkriptions-Engine ist nicht installiert."
                )
            }

            if let transcriptionModelId,
               !transcriptionModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !engine.modelCatalog.contains(where: { $0.id == transcriptionModelId }) {
                return localizedAppText(
                    "The selected transcription model is not available for this engine.",
                    de: "Das ausgewählte Transkriptionsmodell ist für diese Engine nicht verfügbar."
                )
            }
        }

        switch triggerMode {
        case .automatic:
            if !hasEnabledAutomaticTriggerComponent {
                return localizedAppText(
                    "Please enable at least one automatic trigger.",
                    de: "Bitte aktiviere mindestens einen automatischen Trigger."
                )
            }

            if isAppTriggerEnabled && appBundleIdentifiers.isEmpty {
                return localizedAppText(
                    "Please select at least one app.",
                    de: "Bitte wähle mindestens eine App aus."
                )
            }

            if isWebsiteTriggerEnabled && websitePatterns.isEmpty {
                return localizedAppText(
                    "Please add at least one website or domain.",
                    de: "Bitte füge mindestens eine Website oder Domain hinzu."
                )
            }

            if isHotkeyTriggerEnabled {
                guard !hotkeys.isEmpty else {
                    return localizedAppText(
                        "Please record at least one workflow shortcut.",
                        de: "Bitte nimm mindestens einen Workflow-Shortcut auf."
                    )
                }

                for hotkey in hotkeys {
                    if hotkeys.contains(where: { candidate in
                        candidate != hotkey && workflowHotkeysConflict(candidate, hotkey)
                    }) {
                        return localizedAppText(
                            "The workflow contains duplicate shortcuts.",
                            de: "Der Workflow enthält doppelte Shortcuts."
                        )
                    }

                    if let conflictWorkflowId = hotkeyService.isHotkeyAssignedToWorkflow(hotkey, excludingWorkflowId: existingWorkflowId),
                       let conflictWorkflow = workflowService.workflow(id: conflictWorkflowId) {
                        return localizedAppText(
                            "This hotkey is already used by workflow “\(conflictWorkflow.name)”.",
                            de: "Dieser Hotkey wird bereits vom Workflow „\(conflictWorkflow.name)“ verwendet.",
                            ja: "このホットキーはすでにワークフロー「\(conflictWorkflow.name)」で使用されています。",
                            es: "El flujo de trabajo “\(conflictWorkflow.name)” ya usa este atajo de teclado."
                        )
                    }

                    if let conflictSlot = hotkeyService.isHotkeyAssignedToGlobalSlot(hotkey) {
                        return localizedAppText(
                            "This hotkey is already used by the global slot “\(conflictSlot.rawValue)”.",
                            de: "Dieser Hotkey wird bereits vom globalen Slot „\(conflictSlot.rawValue)“ verwendet.",
                            ja: "このホットキーはすでにグローバルスロット「\(conflictSlot.rawValue)」で使用されています。",
                            es: "El espacio global “\(conflictSlot.rawValue)” ya usa este atajo de teclado."
                        )
                    }
                }
            }
        case .global, .manual:
            break
        }

        if template == .translation && translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return localizedAppText(
                "Translation workflows need a target language.",
                de: "Übersetzungs-Workflows brauchen eine Zielsprache."
            )
        }

        if usesAppleTranslate {
            #if canImport(Translation)
            if #available(macOS 15, *) {
            } else {
                return localizedAppText(
                    "Apple Translate workflows require macOS 15 or later.",
                    de: "Apple-Translate-Workflows benötigen macOS 15 oder neuer."
                )
            }
            #else
            return localizedAppText(
                "Apple Translate is not available in this build.",
                de: "Apple Translate ist in diesem Build nicht verfügbar."
            )
            #endif
        }

        if template == .custom {
            let hasCustomInstruction = !customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasFineTuning = !fineTuning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasCustomInstruction && !hasFineTuning {
                return localizedAppText(
                    "Custom workflows need an instruction or fine-tuning text.",
                    de: "Eigene Workflows brauchen eine Anweisung oder Feinabstimmung."
                )
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
            return .global(
                excludingApps: isAppExclusionEnabled ? excludedAppBundleIdentifiers : [],
                websites: isWebsiteExclusionEnabled ? excludedWebsitePatterns : []
            )
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
        let trimmedEffortId = effortId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscriptionEngineId = template == .dictation ? Self.trimmedOptional(transcriptionEngineId) : nil

        return WorkflowBehavior(
            settings: settings,
            fineTuning: usesLLMProcessing ? fineTuning.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            providerId: usesLLMProcessing && trimmedProviderId?.isEmpty == false ? trimmedProviderId : nil,
            cloudModel: usesLLMProcessing && trimmedCloudModel?.isEmpty == false ? trimmedCloudModel : nil,
            effortId: usesLLMProcessing && trimmedEffortId?.isEmpty == false ? trimmedEffortId : nil,
            transcriptionEngineId: trimmedTranscriptionEngineId,
            transcriptionModelId: trimmedTranscriptionEngineId != nil ? Self.trimmedOptional(transcriptionModelId) : nil,
            microphoneBoostOverride: microphoneBoostOverride,
            inlineCommandsEnabled: template == .dictation ? inlineCommandsEnabled : nil,
            temperatureModeRaw: temperatureModeRaw,
            temperatureValue: temperatureValue,
            segmentedPostProcessingEnabled: supportsSegmentedPostProcessing && segmentedPostProcessingEnabled == true
                ? true
                : nil
        )
    }

    func resolvedOutput() -> WorkflowOutput {
        let trimmedFormat = outputFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkflowOutput(
            format: usesLLMProcessing && !trimmedFormat.isEmpty ? trimmedFormat : nil,
            autoEnterMode: autoEnterMode,
            targetActionPluginId: template == .dictation ? nil : targetActionPluginId,
            numberNormalizationModeRaw: numberNormalizationMode == .inherit ? nil : numberNormalizationMode.rawValue
        )
    }

    /// Whether saving this draft would store something other than saving `savedDraft` would.
    /// It compares what the editor saves, so an edit that was undone, or one that saving drops
    /// (such as apps picked for an app trigger that is switched off), is not an unsaved change.
    func hasUnsavedChanges(comparedTo savedDraft: WorkflowDraft) -> Bool {
        savedValues != savedDraft.savedValues
    }

    private struct SavedValues: Equatable {
        let name: String
        let isEnabled: Bool
        let template: WorkflowTemplate
        let trigger: WorkflowTrigger?
        let behavior: WorkflowBehavior
        let output: WorkflowOutput
    }

    /// The values `WorkflowEditorPage.save()` writes to the workflow.
    private var savedValues: SavedValues {
        SavedValues(
            name: resolvedName,
            isEnabled: isEnabled,
            template: template,
            trigger: resolvedTrigger(),
            behavior: resolvedBehavior(),
            output: resolvedOutput()
        )
    }

    private var triggerReviewText: String {
        switch triggerMode {
        case .automatic:
            var parts: [String] = []

            if isAppTriggerEnabled {
                if appBundleIdentifiers.isEmpty {
                    parts.append(localizedAppText("an app trigger", de: "einen App-Trigger"))
                } else {
                    parts.append(localizedAppText(
                        "the apps \(workflowCompactList(appBundleIdentifiers.map(workflowAppDisplayName(for:)), conjunction: localizedAppText("and", de: "und")))",
                        de: "die Apps \(workflowCompactList(appBundleIdentifiers.map(workflowAppDisplayName(for:)), conjunction: "und"))",
                        ja: "アプリ \(workflowCompactList(appBundleIdentifiers.map(workflowAppDisplayName(for:)), conjunction: "と"))",
                        es: "las apps \(workflowCompactList(appBundleIdentifiers.map(workflowAppDisplayName(for:)), conjunction: localizedAppText("and", de: "und")))"
                    ))
                }
            }

            if isWebsiteTriggerEnabled {
                if websitePatterns.isEmpty {
                    parts.append(localizedAppText("a website trigger", de: "einen Website-Trigger"))
                } else {
                    parts.append(localizedAppText(
                        "the websites \(workflowCompactList(websitePatterns, conjunction: localizedAppText("and", de: "und")))",
                        de: "die Websites \(workflowCompactList(websitePatterns, conjunction: "und"))",
                        ja: "Webサイト \(workflowCompactList(websitePatterns, conjunction: "と"))",
                        es: "los sitios web \(workflowCompactList(websitePatterns, conjunction: localizedAppText("and", de: "und")))"
                    ))
                }
            }

            if isHotkeyTriggerEnabled {
                let shortcuts = workflowCompactList(
                    hotkeys.map(HotkeyService.displayName(for:)),
                    conjunction: localizedAppText("and", de: "und", ja: "と")
                )
                if shortcuts.isEmpty {
                    parts.append(localizedAppText("a hotkey", de: "einen Hotkey"))
                } else {
                    switch hotkeyBehavior {
                    case .startDictation:
                        parts.append(localizedAppText(
                            "the shortcuts \(shortcuts) to start dictation",
                            de: "die Shortcuts \(shortcuts) zum Starten des Diktats",
                            ja: "音声入力を開始するショートカット \(shortcuts)",
                            es: "los atajos \(shortcuts) para iniciar el dictado"
                        ))
                    case .processSelectedText:
                        parts.append(localizedAppText(
                            "the shortcuts \(shortcuts) to process selected text",
                            de: "die Shortcuts \(shortcuts) zum Verarbeiten markierten Texts",
                            ja: "選択テキストを処理するショートカット \(shortcuts)",
                            es: "los atajos \(shortcuts) para procesar el texto seleccionado"
                        ))
                    }
                }
            }

            if parts.isEmpty {
                return localizedAppText("an automatic trigger", de: "einen automatischen Trigger")
            }

            return workflowCompactList(parts, conjunction: localizedAppText("and", de: "und", ja: "と"))
        case .global:
            return localizedAppText("always", de: "immer")
        case .manual:
            return localizedAppText("the Workflow Palette", de: "die Workflow-Palette")
        }
    }

    private var hasEnabledAutomaticTriggerComponent: Bool {
        isAppTriggerEnabled || isWebsiteTriggerEnabled || isHotkeyTriggerEnabled
    }

    mutating func addWebsitePattern(_ value: String) {
        Self.addNormalizedWebsite(value, to: &websitePatterns)
    }

    mutating func addExcludedWebsitePattern(_ value: String) {
        Self.addNormalizedWebsite(value, to: &excludedWebsitePatterns)
    }

    private static func addNormalizedWebsite(_ value: String, to patterns: inout [String]) {
        let normalized = workflowNormalizedDomainFromInput(value)
        guard !normalized.isEmpty, !patterns.contains(normalized) else { return }
        patterns.append(normalized)
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
                return localizedAppText(
                    "Apple Translate to \(localizedAppLanguageName(for: targetLanguage))",
                    de: "Apple Translate nach \(localizedAppLanguageName(for: targetLanguage))",
                    ja: "\(localizedAppLanguageName(for: targetLanguage))へのApple Translate",
                    es: "Apple Translate al \(localizedAppLanguageName(for: targetLanguage))"
                )
            }
            return localizedAppText(
                "\(templateName) to \(targetLanguage)",
                de: "\(templateName) nach \(targetLanguage)",
                ja: "\(targetLanguage)への\(templateName)",
                es: "\(templateName) a \(targetLanguage)"
            )
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
    return localizedAppText(
        " Output: action plugin.",
        de: " Ausgabe: Action-Plugin.",
        ja: "。出力: アクションプラグイン。"
    )
}

func workflowInputLanguageSummary(for selection: LanguageSelection) -> String {
    switch selection {
    case .inheritGlobal:
        return localizedAppText("Global Setting", de: "Globale Einstellung")
    case .auto:
        return localizedAppText("Auto-detect", de: "Automatische Erkennung")
    case .exact(let code):
        return localizedAppLanguageName(for: code)
    case .hints(let codes):
        let normalizedCodes = LanguageSelection.hints(codes).selectedCodes
        guard !normalizedCodes.isEmpty else {
            return localizedAppText("Auto-detect", de: "Automatische Erkennung")
        }
        return localizedAppText(
            "Auto-detect between \(workflowLanguageNameList(normalizedCodes))",
            de: "Automatische Erkennung zwischen \(workflowLanguageNameList(normalizedCodes))",
            ja: "\(workflowLanguageNameList(normalizedCodes))間で自動検出",
            es: "Detección automática entre \(workflowLanguageNameList(normalizedCodes))"
        )
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
        return localizedAppText(
            "\(names[0]) and \(names[1])",
            de: "\(names[0]) und \(names[1])",
            ja: "\(names[0])と\(names[1])",
            es: "\(names[0]) y \(names[1])"
        )
    default:
        let allButLast = names.dropLast().joined(separator: ", ")
        return localizedAppText(
            "\(allButLast), and \(names[names.count - 1])",
            de: "\(allButLast) und \(names[names.count - 1])",
            ja: "\(allButLast)、\(names[names.count - 1])",
            es: "\(allButLast) y \(names[names.count - 1])"
        )
    }
}

private func workflowTriggerSummary(for workflow: Workflow) -> String {
    guard let trigger = workflow.trigger else {
        return localizedAppText("No Trigger", de: "Kein Trigger")
    }

    switch trigger.kind {
    case .manual:
        return localizedAppText("Manual", de: "Manuell")
    case .global:
        return localizedAppText("Always", de: "Immer")
    case .app, .website, .hotkey:
        let parts = workflowTriggerSummaryParts(for: trigger)
        return parts.isEmpty ? trigger.kind.paletteLabel : parts.joined(separator: " + ")
    }
}

private func workflowTriggerDetail(for workflow: Workflow) -> String {
    guard let trigger = workflow.trigger else { return "" }

    switch trigger.kind {
    case .manual:
        return localizedAppText("Workflow Palette", de: "Workflow-Palette")
    case .global:
        return workflowExclusionSummary(for: trigger)
    case .app, .website, .hotkey:
        return workflowTriggerDetailParts(for: trigger).joined(separator: " · ")
    }
}

/// "Excluded: Messages and github.com" for an Always trigger with exclusions, otherwise empty.
private func workflowExclusionSummary(for trigger: WorkflowTrigger?) -> String {
    guard let trigger, trigger.kind == .global else { return "" }
    let names = trigger.excludedAppBundleIdentifiers.map(workflowAppDisplayName(for:))
        + trigger.excludedWebsitePatterns
    let list = workflowCompactList(names)
    guard !list.isEmpty else { return "" }
    return localizedAppText(
        "Excluded: \(list)",
        de: "Ausgeschlossen: \(list)",
        ja: "除外: \(list)",
        zh: "排除：\(list)",
        es: "Excluidos: \(list)"
    )
}

private func workflowTriggerSummaryParts(for trigger: WorkflowTrigger) -> [String] {
    var parts: [String] = []
    if !trigger.appBundleIdentifiers.isEmpty {
        parts.append(trigger.appBundleIdentifiers.count == 1
            ? localizedAppText("App", de: "App")
            : localizedAppText("Apps", de: "Apps"))
    }
    if !trigger.websitePatterns.isEmpty {
        parts.append(trigger.websitePatterns.count == 1
            ? localizedAppText("Website", de: "Website")
            : localizedAppText("Websites", de: "Websites"))
    }
    if !trigger.hotkeys.isEmpty {
        parts.append(trigger.hotkeys.count == 1
            ? localizedAppText("Hotkey", de: "Hotkey")
            : localizedAppText("Hotkeys", de: "Hotkeys"))
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
    let languageSentence = localizedAppText(
        ". Spoken language: \(workflowInputLanguageSummary(for: workflow.inputLanguageSelection))",
        de: ". Gesprochene Sprache: \(workflowInputLanguageSummary(for: workflow.inputLanguageSelection))",
        ja: "。話す言語: \(workflowInputLanguageSummary(for: workflow.inputLanguageSelection))",
        es: ". Idioma hablado: \(workflowInputLanguageSummary(for: workflow.inputLanguageSelection))"
    )
    let outputRouteSentence = workflowOutputRouteSentence(targetActionPluginId: workflow.output.targetActionPluginId)

    if workflow.trigger?.kind == .global {
        let exclusionSentence = triggerDetail.isEmpty ? "" : localizedAppText(
            ". \(triggerDetail)",
            de: ". \(triggerDetail)",
            ja: "。\(triggerDetail)",
            es: ". \(triggerDetail)"
        )
        return localizedAppText(
            "\(summary) runs always\(exclusionSentence)\(languageSentence)\(outputRouteSentence)",
            de: "\(summary) läuft immer\(exclusionSentence)\(languageSentence)\(outputRouteSentence)",
            ja: "\(summary)は常に実行されます\(exclusionSentence)\(languageSentence)\(outputRouteSentence)",
            es: "\(summary) se ejecuta siempre\(exclusionSentence)\(languageSentence)\(outputRouteSentence)"
        )
    }

    if workflow.trigger?.kind == .manual {
        return localizedAppText(
            "\(summary) is available from the Workflow Palette\(languageSentence)\(outputRouteSentence)",
            de: "\(summary) ist über die Workflow-Palette verfügbar\(languageSentence)\(outputRouteSentence)",
            ja: "\(summary)はワークフローパレットから利用できます\(languageSentence)\(outputRouteSentence)",
            es: "\(summary) está disponible desde la paleta de flujos de trabajo\(languageSentence)\(outputRouteSentence)"
        )
    }

    if triggerDetail.isEmpty {
        return localizedAppText(
            "\(summary) via \(triggerSummary)\(languageSentence)\(outputRouteSentence)",
            de: "\(summary) über \(triggerSummary)\(languageSentence)\(outputRouteSentence)",
            ja: "\(summary)は\(triggerSummary)で実行されます\(languageSentence)\(outputRouteSentence)",
            es: "\(summary) mediante \(triggerSummary)\(languageSentence)\(outputRouteSentence)"
        )
    }

    return localizedAppText(
        "\(summary) via \(triggerSummary): \(triggerDetail)\(languageSentence)\(outputRouteSentence)",
        de: "\(summary) über \(triggerSummary): \(triggerDetail)\(languageSentence)\(outputRouteSentence)",
        ja: "\(summary)は\(triggerSummary): \(triggerDetail)で実行されます\(languageSentence)\(outputRouteSentence)",
        es: "\(summary) mediante \(triggerSummary): \(triggerDetail)\(languageSentence)\(outputRouteSentence)"
    )
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

private func workflowCompactList(_ values: [String], conjunction: String = localizedAppText("and", de: "und", ja: "と")) -> String {
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
