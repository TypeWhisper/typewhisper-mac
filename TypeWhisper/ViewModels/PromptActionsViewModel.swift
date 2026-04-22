import Foundation
import Combine
import TypeWhisperPluginSDK

struct PromptRuleAssignmentStatus: Equatable {
    let ruleCount: Int

    var isAssigned: Bool { ruleCount > 0 }
}

@MainActor
class PromptActionsViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: PromptActionsViewModel?
    static var shared: PromptActionsViewModel {
        guard let instance = _shared else {
            fatalError("PromptActionsViewModel not initialized")
        }
        return instance
    }

    @Published var promptActions: [PromptAction] = []
    @Published var error: String?
    @Published var navigateToIntegrations = false
    @Published var pendingRuleAssignmentPromptId: String?

    // Editor state
    @Published var isEditing = false
    @Published var isCreatingNew = false
    @Published var isEditingExistingPrompt = false
    @Published var editName = ""
    @Published var editPrompt = ""
    @Published var editIcon = "sparkles"
    @Published var editIsEnabled = true
    @Published var editProviderId: String?
    @Published var editCloudModel = ""
    @Published var editTemperatureMode: PluginLLMTemperatureMode = .inheritProviderSetting
    @Published var editTemperatureValue: Double = 0.3
    @Published var editTargetActionPluginId: String?
    @Published var wizardStep: PromptWizardStep = .goal
    @Published var wizardDraft = PromptWizardDraft(goal: .custom)
    @Published var manualPromptOverride = false

    private let promptActionService: PromptActionService
    private let profileService: ProfileService?
    var promptProcessingService: PromptProcessingService
    private var cancellables = Set<AnyCancellable>()
    private var selectedAction: PromptAction?
    private var editNameManuallyEdited = false

    var enabledCount: Int { promptActionService.getEnabledActions().count }
    var totalCount: Int { promptActions.count }
    var suggestedPromptName: String { PromptWizardNameSuggester.suggestedName(for: wizardDraft) }
    var currentPromptName: String {
        let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        if editNameManuallyEdited, !trimmed.isEmpty {
            return trimmed
        }
        if !trimmed.isEmpty {
            return trimmed
        }
        return suggestedPromptName
    }
    var pendingRuleAssignmentPrompt: PromptAction? {
        guard let pendingRuleAssignmentPromptId else { return nil }
        return promptActionService.action(byId: pendingRuleAssignmentPromptId)
    }
    var shouldShowRuleAssignmentCallout: Bool {
        guard let action = pendingRuleAssignmentPrompt else { return false }
        return !assignmentStatus(for: action).isAssigned
    }

    init(
        promptActionService: PromptActionService,
        promptProcessingService: PromptProcessingService,
        profileService: ProfileService? = nil
    ) {
        self.promptActionService = promptActionService
        self.profileService = profileService
        self.promptProcessingService = promptProcessingService
        self.promptActions = promptActionService.promptActions
        setupBindings()
    }

    private func setupBindings() {
        promptActionService.$promptActions
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] actions in
                self?.promptActions = actions
            }
            .store(in: &cancellables)

        profileService?.$profiles
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshPendingRuleAssignmentCalloutState()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Editor Actions

    func startCreating() {
        selectedAction = nil
        isCreatingNew = true
        isEditingExistingPrompt = false
        isEditing = true
        wizardStep = .goal
        manualPromptOverride = false
        editNameManuallyEdited = false
        wizardDraft = PromptWizardDraft(goal: .custom)
        wizardDraft.temperatureValue = defaultTemperatureValue(for: promptProcessingService.selectedProviderId)
        syncEditorFieldsFromWizardDraft(resetName: true)
        regeneratePromptFromWizardSelections()
    }

    func startEditing(_ action: PromptAction) {
        selectedAction = action
        isCreatingNew = false
        isEditingExistingPrompt = true
        isEditing = true
        wizardStep = .goal
        manualPromptOverride = false
        editNameManuallyEdited = true
        wizardDraft = PromptWizardInferenceService.infer(from: action)
        if let temperatureValue = action.temperatureValue {
            wizardDraft.temperatureValue = temperatureValue
        } else {
            wizardDraft.temperatureValue = defaultTemperatureValue(for: action.providerType ?? promptProcessingService.selectedProviderId)
        }
        syncEditorFieldsFromWizardDraft(resetName: false)
        editName = action.name
        editPrompt = action.prompt
    }

    func cancelEditing() {
        isEditing = false
        isCreatingNew = false
        isEditingExistingPrompt = false
        selectedAction = nil
        wizardStep = .goal
        wizardDraft = PromptWizardDraft(goal: .custom)
        manualPromptOverride = false
        editNameManuallyEdited = false
        editName = ""
        editPrompt = ""
        editIcon = "sparkles"
        editIsEnabled = true
        editProviderId = nil
        editCloudModel = ""
        editTemperatureMode = .inheritProviderSetting
        editTemperatureValue = defaultTemperatureValue(for: promptProcessingService.selectedProviderId)
        editTargetActionPluginId = nil
    }

    func saveEditing() {
        let resolvedName = currentPromptName
        guard !resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !editPrompt.isEmpty else {
            error = String(localized: "Name and prompt cannot be empty")
            return
        }

        if !manualPromptOverride {
            regeneratePromptFromWizardSelections()
        }

        let savedAction: PromptAction?
        if isCreatingNew {
            savedAction = promptActionService.addAction(
                name: resolvedName,
                prompt: editPrompt,
                icon: editIcon,
                isEnabled: editIsEnabled,
                providerType: editProviderId,
                cloudModel: editCloudModel.isEmpty ? nil : editCloudModel,
                temperatureModeRaw: editTemperatureMode.rawValue,
                temperatureValue: editTemperatureMode == .custom ? editTemperatureValue : nil,
                targetActionPluginId: editTargetActionPluginId
            )
        } else if let action = selectedAction {
            savedAction = promptActionService.updateAction(
                action,
                name: resolvedName,
                prompt: editPrompt,
                icon: editIcon,
                isEnabled: editIsEnabled,
                providerType: editProviderId,
                cloudModel: editCloudModel.isEmpty ? nil : editCloudModel,
                temperatureModeRaw: editTemperatureMode.rawValue,
                temperatureValue: editTemperatureMode == .custom ? editTemperatureValue : nil,
                targetActionPluginId: editTargetActionPluginId
            )
        } else {
            savedAction = nil
        }

        updatePendingRuleAssignment(for: savedAction)
        cancelEditing()
    }

    func deleteAction(_ action: PromptAction) {
        if pendingRuleAssignmentPromptId == action.id.uuidString {
            pendingRuleAssignmentPromptId = nil
        }
        promptActionService.deleteAction(action)
    }

    func toggleAction(_ action: PromptAction) {
        promptActionService.toggleAction(action)
    }

    func moveAction(fromIndex: Int, toIndex: Int) {
        promptActionService.moveAction(fromIndex: fromIndex, toIndex: toIndex)
    }

    var availablePresets: [PromptAction] {
        promptActionService.availablePresets
    }

    func importPreset(_ preset: PromptAction) {
        promptActionService.addPreset(preset)
    }

    func loadPresets() {
        promptActionService.seedPresetsIfNeeded()
    }

    func clearError() {
        error = nil
    }

    func assignmentStatus(for action: PromptAction) -> PromptRuleAssignmentStatus {
        PromptRuleAssignmentStatus(ruleCount: ruleCount(forPromptActionId: action.id.uuidString))
    }

    func assignmentSummary(for action: PromptAction) -> String {
        let status = assignmentStatus(for: action)
        if status.isAssigned {
            let ruleCount = status.ruleCount
            return localizedAppText(
                "Used in \(ruleCount) rule\(ruleCount == 1 ? "" : "s")",
                de: "In \(ruleCount) Regel\(ruleCount == 1 ? "" : "n") verwendet"
            )
        }

        return localizedAppText(
            "Not used in any rules",
            de: "Nicht in Regeln verwendet"
        )
    }

    func rulesUsing(_ action: PromptAction) -> [Profile] {
        profilesForAssignmentStatus.filter { $0.promptActionId == action.id.uuidString }
    }

    func showRules(for action: PromptAction) {
        pendingRuleAssignmentPromptId = nil
        ProfilesViewModel.shared.focusRules(usingPromptActionId: action.id.uuidString)
        SettingsNavigationCoordinator.shared.navigate(to: .profiles)
    }

    func openRule(_ profile: Profile) {
        if let promptActionId = profile.promptActionId {
            ProfilesViewModel.shared.focusRules(usingPromptActionId: promptActionId)
        } else {
            ProfilesViewModel.shared.clearPromptRuleFocus()
        }
        ProfilesViewModel.shared.prepareEditProfile(profile)
        SettingsNavigationCoordinator.shared.navigate(to: .profiles)
    }

    func createRule(for action: PromptAction) {
        pendingRuleAssignmentPromptId = nil
        ProfilesViewModel.shared.prepareNewProfile(prefilledPromptActionId: action.id.uuidString)
        SettingsNavigationCoordinator.shared.navigate(to: .profiles)
    }

    func dismissRuleAssignmentCallout() {
        pendingRuleAssignmentPromptId = nil
    }

    func setWizardGoal(_ goal: PromptWizardGoal) {
        let previousIcon = wizardDraft.goal.defaultIcon
        wizardDraft.goal = goal
        if editIcon == previousIcon || editIcon.isEmpty {
            wizardDraft.icon = goal.defaultIcon
        } else {
            wizardDraft.icon = editIcon
        }

        switch goal {
        case .translate:
            if wizardDraft.translationMode == nil {
                wizardDraft.translationMode = .alternatingPair(primaryLanguage: "en", secondaryLanguage: "de")
            }
        case .extract:
            wizardDraft.extractFormat = .checklist
        case .replyEmail:
            wizardDraft.replyMode = .reply
        case .structure:
            wizardDraft.structureFormat = .bulletList
        case .rewrite, .custom:
            break
        }

        syncEditorFieldsFromWizardDraft(resetName: false)
        if !manualPromptOverride {
            regeneratePromptFromWizardSelections()
        }
    }

    func starterPresets(for goal: PromptWizardGoal) -> [PromptAction] {
        PromptAction.presets.filter { preset in
            PromptWizardInferenceService.infer(from: preset).goal == goal
        }
    }

    func applyPresetStarter(_ preset: PromptAction) {
        manualPromptOverride = false
        editNameManuallyEdited = false
        wizardDraft = PromptWizardInferenceService.infer(from: preset)
        if wizardDraft.temperatureValue == nil {
            wizardDraft.temperatureValue = defaultTemperatureValue(for: wizardDraft.providerId ?? promptProcessingService.selectedProviderId)
        }
        syncEditorFieldsFromWizardDraft(resetName: true)
        editPrompt = preset.prompt
    }

    func updateWizardDraft(_ mutate: (inout PromptWizardDraft) -> Void) {
        mutate(&wizardDraft)
        syncEditorFieldsFromWizardDraft(resetName: false)
        if !manualPromptOverride {
            regeneratePromptFromWizardSelections()
        }
    }

    func updateWizardName(_ name: String) {
        editName = name
        editNameManuallyEdited = true
    }

    func setWizardIcon(_ icon: String) {
        wizardDraft.icon = icon
        editIcon = icon
    }

    func setWizardEnabled(_ isEnabled: Bool) {
        wizardDraft.isEnabled = isEnabled
        editIsEnabled = isEnabled
    }

    func setWizardProviderOverride(_ providerId: String?) {
        updateWizardDraft { draft in
            draft.providerId = providerId

            if let providerId {
                let models = promptProcessingService.modelsForProvider(providerId)
                if !draft.cloudModel.isEmpty, models.contains(where: { $0.id == draft.cloudModel }) {
                    draft.cloudModel = draft.cloudModel
                } else {
                    draft.cloudModel = models.first?.id ?? ""
                }
            } else {
                draft.cloudModel = ""
            }

            let effectiveProviderId = providerId ?? promptProcessingService.selectedProviderId
            let defaultValue = defaultTemperatureValue(for: effectiveProviderId)
            let range = supportedTemperatureRange(for: effectiveProviderId)
            let currentValue = draft.temperatureValue ?? defaultValue
            draft.temperatureValue = min(max(currentValue, range.lowerBound), range.upperBound)
        }
    }

    func setWizardCloudModel(_ cloudModel: String) {
        updateWizardDraft { draft in
            draft.cloudModel = cloudModel
        }
    }

    func setWizardTemperatureMode(_ mode: PluginLLMTemperatureMode) {
        updateWizardDraft { draft in
            draft.temperatureMode = mode

            let effectiveProviderId = draft.providerId ?? promptProcessingService.selectedProviderId
            let defaultValue = defaultTemperatureValue(for: effectiveProviderId)
            let range = supportedTemperatureRange(for: effectiveProviderId)
            let currentValue = draft.temperatureValue ?? defaultValue
            draft.temperatureValue = min(max(currentValue, range.lowerBound), range.upperBound)
        }
    }

    func setWizardTemperatureValue(_ value: Double) {
        updateWizardDraft { draft in
            let effectiveProviderId = draft.providerId ?? promptProcessingService.selectedProviderId
            let range = supportedTemperatureRange(for: effectiveProviderId)
            draft.temperatureValue = min(max(value, range.lowerBound), range.upperBound)
        }
    }

    func setWizardTargetActionPluginId(_ pluginId: String?) {
        wizardDraft.targetActionPluginId = pluginId
        editTargetActionPluginId = pluginId
    }

    func updateManualPrompt(_ prompt: String) {
        manualPromptOverride = true
        editPrompt = prompt
    }

    func regeneratePromptFromWizardSelections() {
        manualPromptOverride = false
        editPrompt = PromptWizardComposer.compose(from: wizardDraft)
    }

    func goToNextWizardStep() {
        guard let next = PromptWizardStep(rawValue: wizardStep.rawValue + 1) else { return }
        wizardStep = next
    }

    func goToPreviousWizardStep() {
        guard let previous = PromptWizardStep(rawValue: wizardStep.rawValue - 1) else { return }
        wizardStep = previous
    }

    var canAdvanceFromCurrentWizardStep: Bool {
        switch wizardStep {
        case .goal:
            return true
        case .response:
            if wizardDraft.goal == .custom {
                return !wizardDraft.customGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        case .review:
            return !currentPromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !editPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func clampTemperatureValueForEffectiveProvider() {
        let range = supportedTemperatureRange(
            for: editProviderId ?? promptProcessingService.selectedProviderId
        )
        editTemperatureValue = min(max(editTemperatureValue, range.lowerBound), range.upperBound)
    }

    func supportedTemperatureRange(for providerId: String?) -> ClosedRange<Double> {
        guard providerId == "Gemma 4 (MLX)" else {
            return 0.0...2.0
        }
        return 0.0...1.0
    }

    func defaultTemperatureValue(for providerId: String?) -> Double {
        providerId == "Gemma 4 (MLX)" ? 0.1 : 0.3
    }

    private var profilesForAssignmentStatus: [Profile] {
        profileService?.profiles ?? ProfilesViewModel._shared?.profiles ?? []
    }

    private func ruleCount(forPromptActionId promptActionId: String) -> Int {
        profilesForAssignmentStatus.filter { $0.promptActionId == promptActionId }.count
    }

    private func updatePendingRuleAssignment(for action: PromptAction?) {
        guard let action else {
            pendingRuleAssignmentPromptId = nil
            return
        }

        pendingRuleAssignmentPromptId = assignmentStatus(for: action).isAssigned
            ? nil
            : action.id.uuidString
    }

    private func refreshPendingRuleAssignmentCalloutState() {
        guard let pendingRuleAssignmentPromptId else { return }
        guard let action = promptActionService.action(byId: pendingRuleAssignmentPromptId) else {
            self.pendingRuleAssignmentPromptId = nil
            return
        }

        if assignmentStatus(for: action).isAssigned {
            self.pendingRuleAssignmentPromptId = nil
        }
    }

    private func syncEditorFieldsFromWizardDraft(resetName: Bool) {
        if resetName || editName.isEmpty {
            editName = wizardDraft.name
        }
        editIcon = wizardDraft.icon
        editIsEnabled = wizardDraft.isEnabled
        editProviderId = wizardDraft.providerId
        editCloudModel = wizardDraft.cloudModel
        editTemperatureMode = wizardDraft.temperatureMode
        editTemperatureValue = wizardDraft.temperatureValue ?? defaultTemperatureValue(for: wizardDraft.providerId ?? promptProcessingService.selectedProviderId)
        editTargetActionPluginId = wizardDraft.targetActionPluginId
    }
}
