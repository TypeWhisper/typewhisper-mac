import Foundation
import Combine

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

    // Editor state
    @Published var isEditing = false
    @Published var isCreatingNew = false
    @Published var editName = ""
    @Published var editPrompt = ""
    @Published var editIcon = "sparkles"
    @Published var editProviderId: String?
    @Published var editCloudModel = ""
    @Published var editTargetActionPluginId: String?

    private let promptActionService: PromptActionService
    var promptProcessingService: PromptProcessingService
    private var cancellables = Set<AnyCancellable>()
    private var selectedAction: PromptAction?

    var enabledCount: Int { promptActionService.getEnabledActions().count }
    var totalCount: Int { promptActions.count }

    init(promptActionService: PromptActionService, promptProcessingService: PromptProcessingService) {
        self.promptActionService = promptActionService
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
    }

    // MARK: - Editor Actions

    func startCreating() {
        selectedAction = nil
        isCreatingNew = true
        isEditing = true
        editName = ""
        editPrompt = ""
        editIcon = "sparkles"
        editProviderId = nil
        editCloudModel = ""
        editTargetActionPluginId = nil
    }

    func startEditing(_ action: PromptAction) {
        selectedAction = action
        isCreatingNew = false
        isEditing = true
        editName = action.name
        editPrompt = action.prompt
        editIcon = action.icon
        editProviderId = action.providerType
        editCloudModel = action.cloudModel ?? ""
        editTargetActionPluginId = action.targetActionPluginId
    }

    func cancelEditing() {
        isEditing = false
        isCreatingNew = false
        selectedAction = nil
        editName = ""
        editPrompt = ""
        editIcon = "sparkles"
        editProviderId = nil
        editCloudModel = ""
        editTargetActionPluginId = nil
    }

    func saveEditing() {
        guard !editName.isEmpty, !editPrompt.isEmpty else {
            error = String(localized: "Name and prompt cannot be empty")
            return
        }

        if isCreatingNew {
            promptActionService.addAction(
                name: editName,
                prompt: editPrompt,
                icon: editIcon,
                providerType: editProviderId,
                cloudModel: editCloudModel.isEmpty ? nil : editCloudModel,
                targetActionPluginId: editTargetActionPluginId
            )
        } else if let action = selectedAction {
            promptActionService.updateAction(
                action,
                name: editName,
                prompt: editPrompt,
                icon: editIcon,
                providerType: editProviderId,
                cloudModel: editCloudModel.isEmpty ? nil : editCloudModel,
                targetActionPluginId: editTargetActionPluginId
            )
        }

        cancelEditing()
    }

    func deleteAction(_ action: PromptAction) {
        promptActionService.deleteAction(action)
    }

    func toggleAction(_ action: PromptAction) {
        promptActionService.toggleAction(action)
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
}
