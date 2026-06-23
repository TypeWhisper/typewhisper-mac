import Foundation
import XCTest
@testable import TypeWhisper

@MainActor
final class PromptProcessingModelResolutionTests: XCTestCase {
    private let models = ["gemini-2.0-flash", "gemini-2.5-flash", "gemini-flash-latest"]

    func testValidRequestedModelIsReturnedAndNotPersisted() {
        let resolution = PromptProcessingService.resolveModel(
            requestedModel: "gemini-2.5-flash",
            preferredModelId: nil,
            selectedCloudModel: "",
            availableModelIds: models
        )

        XCTAssertEqual(resolution.modelId, "gemini-2.5-flash")
        XCTAssertFalse(resolution.persistGlobally)
    }

    func testPreferredModelIsResolvedAndPersistedWhenNothingSelected() {
        let resolution = PromptProcessingService.resolveModel(
            requestedModel: nil,
            preferredModelId: "gemini-flash-latest",
            selectedCloudModel: "",
            availableModelIds: models
        )

        XCTAssertEqual(resolution.modelId, "gemini-flash-latest")
        XCTAssertTrue(resolution.persistGlobally)
    }

    func testAlphabeticalFallbackIsUsedButNeverPersisted() {
        // Core of the bug: when nothing is selected and the provider plugin
        // exposes no preference, the alphabetically-first (oldest) model must
        // be used for this run but must NOT be written into the legacy global,
        // or a retired model silently poisons every future run.
        let resolution = PromptProcessingService.resolveModel(
            requestedModel: nil,
            preferredModelId: nil,
            selectedCloudModel: "",
            availableModelIds: models
        )

        XCTAssertEqual(resolution.modelId, "gemini-2.0-flash")
        XCTAssertFalse(resolution.persistGlobally)
    }

    func testProviderDefaultIsPreferredOverAlphabeticalFallback() {
        // When nothing is selected, the provider's recommended default beats
        // first-available — for Gemini the alphabetically-first model is the
        // retired gemini-2.0-flash, which would 404 even transiently.
        let resolution = PromptProcessingService.resolveModel(
            requestedModel: nil,
            preferredModelId: nil,
            selectedCloudModel: "",
            availableModelIds: models,
            providerDefaultModelId: "gemini-flash-latest"
        )

        XCTAssertEqual(resolution.modelId, "gemini-flash-latest")
        XCTAssertFalse(resolution.persistGlobally)
    }

    func testProviderDefaultNotInAvailableModelsIsIgnored() {
        let resolution = PromptProcessingService.resolveModel(
            requestedModel: nil,
            preferredModelId: nil,
            selectedCloudModel: "",
            availableModelIds: models,
            providerDefaultModelId: "not-a-listed-model"
        )

        XCTAssertEqual(resolution.modelId, "gemini-2.0-flash")
        XCTAssertFalse(resolution.persistGlobally)
    }

    func testInvalidNonEmptyGlobalIsRepairedToFallbackAndPersisted() {
        // A non-empty global that is no longer valid is self-healed to a valid
        // model and persisted, so the stale value is not retried forever.
        let resolution = PromptProcessingService.resolveModel(
            requestedModel: "retired-model",
            preferredModelId: nil,
            selectedCloudModel: "retired-model",
            availableModelIds: models
        )

        XCTAssertEqual(resolution.modelId, "gemini-2.0-flash")
        XCTAssertTrue(resolution.persistGlobally)
    }

    func testInvalidNonEmptyGlobalIsRepairedToProviderDefault() {
        // Self-healing must repair to the provider's recommended default when
        // one exists, not adopt (and persist) the retired oldest model.
        let resolution = PromptProcessingService.resolveModel(
            requestedModel: "retired-model",
            preferredModelId: nil,
            selectedCloudModel: "retired-model",
            availableModelIds: models,
            providerDefaultModelId: "gemini-flash-latest"
        )

        XCTAssertEqual(resolution.modelId, "gemini-flash-latest")
        XCTAssertTrue(resolution.persistGlobally)
    }

    func testValidSelectedCloudModelIsKeptWithoutRepersisting() {
        let resolution = PromptProcessingService.resolveModel(
            requestedModel: nil,
            preferredModelId: nil,
            selectedCloudModel: "gemini-2.5-flash",
            availableModelIds: models
        )

        XCTAssertEqual(resolution.modelId, "gemini-2.5-flash")
        XCTAssertFalse(resolution.persistGlobally)
    }

    func testNoAvailableModelsReturnsRequestedModelWithoutPersisting() {
        let resolution = PromptProcessingService.resolveModel(
            requestedModel: "anything",
            preferredModelId: "preferred",
            selectedCloudModel: "global",
            availableModelIds: []
        )

        XCTAssertEqual(resolution.modelId, "anything")
        XCTAssertFalse(resolution.persistGlobally)
    }
}
