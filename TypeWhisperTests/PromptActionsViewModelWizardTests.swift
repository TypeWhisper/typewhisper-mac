import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class PromptActionsViewModelWizardTests: XCTestCase {
    func testStartCreatingResetsWizardState() throws {
        let viewModel = try makeViewModel()

        viewModel.startCreating()

        XCTAssertEqual(viewModel.wizardStep, .goal)
        XCTAssertEqual(viewModel.wizardDraft.goal, .custom)
        XCTAssertFalse(viewModel.manualPromptOverride)
        XCTAssertFalse(viewModel.isEditingExistingPrompt)
        XCTAssertTrue(viewModel.isCreatingNew)
        XCTAssertEqual(viewModel.editIcon, "sparkles")
    }

    func testCurrentPromptNameFallsBackToSuggestedName() throws {
        let viewModel = try makeViewModel()

        viewModel.startCreating()
        XCTAssertEqual(viewModel.currentPromptName, localizedAppText("Custom Prompt", de: "Benutzerdefinierter Prompt"))

        viewModel.setWizardGoal(.extract)
        viewModel.updateWizardDraft { draft in
            draft.extractFormat = .json
        }
        XCTAssertEqual(viewModel.currentPromptName, localizedAppText("Extract JSON", de: "JSON extrahieren"))

        viewModel.updateWizardName("My Extractor")
        XCTAssertEqual(viewModel.currentPromptName, "My Extractor")

        viewModel.updateWizardName("")
        XCTAssertEqual(viewModel.currentPromptName, localizedAppText("Extract JSON", de: "JSON extrahieren"))
    }

    func testManualPromptOverridePreventsAutomaticRegeneration() throws {
        let viewModel = try makeViewModel()
        viewModel.startCreating()
        viewModel.setWizardGoal(.translate)
        viewModel.updateWizardDraft { draft in
            draft.translationMode = .alternatingPair(primaryLanguage: "en", secondaryLanguage: "de")
        }

        let generatedPrompt = viewModel.editPrompt
        XCTAssertFalse(generatedPrompt.isEmpty)

        viewModel.updateManualPrompt("My custom prompt.")
        viewModel.setWizardGoal(.extract)

        XCTAssertTrue(viewModel.manualPromptOverride)
        XCTAssertEqual(viewModel.editPrompt, "My custom prompt.")
    }

    func testStartEditingInfersWizardStateFromExistingPrompt() throws {
        let viewModel = try makeViewModel()
        let action = PromptAction(
            name: "Reply",
            prompt: "Write a concise, friendly reply to the following message. Respond in the same language as the input text. Only return the reply.",
            icon: "arrowshape.turn.up.left",
            providerType: "Groq",
            cloudModel: "llama-3.3",
            temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
            temperatureValue: 0.4
        )

        viewModel.startEditing(action)

        XCTAssertFalse(viewModel.isCreatingNew)
        XCTAssertTrue(viewModel.isEditingExistingPrompt)
        XCTAssertEqual(viewModel.wizardStep, .goal)
        XCTAssertEqual(viewModel.wizardDraft.goal, .replyEmail)
        XCTAssertEqual(viewModel.wizardDraft.replyMode, .reply)
        XCTAssertEqual(viewModel.wizardDraft.tone, .friendly)
        XCTAssertEqual(viewModel.wizardDraft.languageMode, .sameAsInput)
        XCTAssertEqual(viewModel.editPrompt, action.prompt)
        XCTAssertFalse(viewModel.manualPromptOverride)
    }

    func testSaveEditingPersistsPromptAndAdvancedFields() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PromptActionsViewModelWizardTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let service = PromptActionService(appSupportDirectory: appSupportDirectory)
        let processingService = PromptProcessingService()
        let viewModel = PromptActionsViewModel(
            promptActionService: service,
            promptProcessingService: processingService
        )

        viewModel.startCreating()
        viewModel.setWizardGoal(.extract)
        viewModel.updateWizardDraft { draft in
            draft.extractFormat = .json
        }
        viewModel.editName = "JSON Extractor"
        viewModel.setWizardEnabled(false)
        viewModel.editProviderId = "Groq"
        viewModel.editCloudModel = "llama-3.3"
        viewModel.editTemperatureMode = .custom
        viewModel.editTemperatureValue = 0.2
        viewModel.editTargetActionPluginId = "plugin.action"

        viewModel.saveEditing()

        let action = try XCTUnwrap(service.promptActions.first)
        XCTAssertEqual(action.name, "JSON Extractor")
        XCTAssertFalse(action.isEnabled)
        XCTAssertEqual(action.prompt, "Extract structured data from the following text and format it as valid, well-indented JSON. Use descriptive keys and appropriate data types. Only return the JSON, nothing else.")
        XCTAssertEqual(action.providerType, "Groq")
        XCTAssertEqual(action.cloudModel, "llama-3.3")
        XCTAssertEqual(action.temperatureModeRaw, PluginLLMTemperatureMode.custom.rawValue)
        XCTAssertEqual(action.temperatureValue, 0.2)
        XCTAssertEqual(action.targetActionPluginId, "plugin.action")
    }

    func testSaveEditingUsesSuggestedNameWhenNameWasNotEdited() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PromptActionsViewModelWizardTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let service = PromptActionService(appSupportDirectory: appSupportDirectory)
        let processingService = PromptProcessingService()
        let viewModel = PromptActionsViewModel(
            promptActionService: service,
            promptProcessingService: processingService
        )

        viewModel.startCreating()
        viewModel.setWizardGoal(.extract)
        viewModel.updateWizardDraft { draft in
            draft.extractFormat = .json
        }

        viewModel.saveEditing()

        let action = try XCTUnwrap(service.promptActions.first)
        XCTAssertEqual(action.name, localizedAppText("Extract JSON", de: "JSON extrahieren"))
    }

    func testAssignmentStatusTracksRuleUsageCounts() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PromptActionsViewModelWizardTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let viewModel = PromptActionsViewModel(
            promptActionService: promptActionService,
            promptProcessingService: PromptProcessingService(),
            profileService: profileService
        )

        let unusedAction = try XCTUnwrap(promptActionService.addAction(
            name: "Unused",
            prompt: "Do nothing."
        ))
        let assignedAction = try XCTUnwrap(promptActionService.addAction(
            name: "Assigned",
            prompt: "Translate this."
        ))

        XCTAssertEqual(viewModel.assignmentStatus(for: unusedAction), PromptRuleAssignmentStatus(ruleCount: 0))
        XCTAssertEqual(viewModel.assignmentSummary(for: unusedAction), localizedAppText("Not used in any rules", de: "Nicht in Regeln verwendet"))

        profileService.addProfile(name: "Global 1", promptActionId: assignedAction.id.uuidString)

        XCTAssertEqual(viewModel.assignmentStatus(for: assignedAction), PromptRuleAssignmentStatus(ruleCount: 1))
        XCTAssertEqual(viewModel.assignmentSummary(for: assignedAction), localizedAppText("Used in 1 rule", de: "In 1 Regel verwendet"))

        profileService.addProfile(name: "Global 2", promptActionId: assignedAction.id.uuidString)

        XCTAssertEqual(viewModel.assignmentStatus(for: assignedAction), PromptRuleAssignmentStatus(ruleCount: 2))
        XCTAssertEqual(viewModel.assignmentSummary(for: assignedAction), localizedAppText("Used in 2 rules", de: "In 2 Regeln verwendet"))
    }

    func testSaveEditingFlagsUnassignedPromptForRuleAssignmentCallout() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PromptActionsViewModelWizardTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let service = PromptActionService(appSupportDirectory: appSupportDirectory)
        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let viewModel = PromptActionsViewModel(
            promptActionService: service,
            promptProcessingService: PromptProcessingService(),
            profileService: profileService
        )

        viewModel.startCreating()
        viewModel.setWizardGoal(.extract)
        viewModel.updateWizardDraft { draft in
            draft.extractFormat = .json
        }

        viewModel.saveEditing()

        let action = try XCTUnwrap(service.promptActions.first)
        XCTAssertEqual(viewModel.pendingRuleAssignmentPromptId, action.id.uuidString)
        XCTAssertTrue(viewModel.shouldShowRuleAssignmentCallout)
    }

    func testRulesUsingReturnsMatchingProfiles() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PromptActionsViewModelWizardTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let viewModel = PromptActionsViewModel(
            promptActionService: promptActionService,
            promptProcessingService: PromptProcessingService(),
            profileService: profileService
        )

        let linkedAction = try XCTUnwrap(promptActionService.addAction(
            name: "Linked",
            prompt: "Refine this text."
        ))
        let otherAction = try XCTUnwrap(promptActionService.addAction(
            name: "Other",
            prompt: "Translate this."
        ))

        profileService.addProfile(name: "Rule A", promptActionId: linkedAction.id.uuidString)
        profileService.addProfile(name: "Rule B", promptActionId: linkedAction.id.uuidString)
        profileService.addProfile(name: "Rule C", promptActionId: otherAction.id.uuidString)

        XCTAssertEqual(
            Set(viewModel.rulesUsing(linkedAction).map(\.name)),
            Set(["Rule A", "Rule B"])
        )
    }

    private func makeViewModel() throws -> PromptActionsViewModel {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PromptActionsViewModelWizardTests")
        addTeardownBlock {
            TestSupport.remove(appSupportDirectory)
        }

        return PromptActionsViewModel(
            promptActionService: PromptActionService(appSupportDirectory: appSupportDirectory),
            promptProcessingService: PromptProcessingService()
        )
    }
}
