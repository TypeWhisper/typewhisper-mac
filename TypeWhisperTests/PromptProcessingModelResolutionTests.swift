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

    func testFallbackListMigratesWorkflowDefaultBeforeDistinctPromptDefault() throws {
        let suiteName = "PromptProcessingModelResolutionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("Gemma 4 (MLX)", forKey: UserDefaultsKeys.workflowDefaultLLMProviderId)
        defaults.set("gemma-4-large", forKey: UserDefaultsKeys.workflowDefaultLLMCloudModel)
        defaults.set("Groq", forKey: "llmProviderType")
        defaults.set("llama-3.3", forKey: "llmCloudModel")

        let service = PromptProcessingService(userDefaults: defaults)

        XCTAssertEqual(
            service.fallbackPriorityList.map { ($0.providerId, $0.modelId) }.map { "\($0.0)|\($0.1 ?? "")" },
            ["Gemma 4 (MLX)|gemma-4-large", "Groq|llama-3.3"]
        )
        XCTAssertNotEqual(service.fallbackPriorityList[0].id, service.fallbackPriorityList[1].id)
        XCTAssertNotNil(defaults.data(forKey: UserDefaultsKeys.llmFallbackPriorityList))
        XCTAssertEqual(defaults.string(forKey: "llmProviderType"), "Groq")
    }

    func testExistingEmptyFallbackListDoesNotRemigrateLegacyDefaults() throws {
        let suiteName = "PromptProcessingModelResolutionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(try JSONEncoder().encode([LLMFallbackPriorityItem]()), forKey: UserDefaultsKeys.llmFallbackPriorityList)
        defaults.set("Groq", forKey: "llmProviderType")
        defaults.set("llama-3.3", forKey: "llmCloudModel")

        let service = PromptProcessingService(userDefaults: defaults)

        XCTAssertTrue(service.fallbackPriorityList.isEmpty)
    }

    func testCorruptFallbackListRemigratesLegacyDefaults() throws {
        let suiteName = "PromptProcessingModelResolutionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not valid fallback JSON".utf8), forKey: UserDefaultsKeys.llmFallbackPriorityList)
        defaults.set("Groq", forKey: "llmProviderType")
        defaults.set("llama-3.3", forKey: "llmCloudModel")

        let service = PromptProcessingService(userDefaults: defaults)

        XCTAssertEqual(
            service.fallbackPriorityList.map { "\($0.providerId)|\($0.modelId ?? "")" },
            ["Groq|llama-3.3"]
        )
    }

    func testFallbackListKeepsUUIDsAndOrderAcrossReorderAndReload() throws {
        let suiteName = "PromptProcessingModelResolutionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = LLMFallbackPriorityItem(providerId: "Groq", modelId: "llama-3.3")
        let second = LLMFallbackPriorityItem(providerId: "Mistral", modelId: nil)
        defaults.set(
            try JSONEncoder().encode([first, second]),
            forKey: UserDefaultsKeys.llmFallbackPriorityList
        )

        let service = PromptProcessingService(userDefaults: defaults)
        service.moveLLMFallbacks(from: IndexSet(integer: 1), to: 0)

        XCTAssertEqual(service.fallbackPriorityList.map(\.id), [second.id, first.id])

        let reloaded = PromptProcessingService(userDefaults: defaults)
        XCTAssertEqual(reloaded.fallbackPriorityList.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloaded.fallbackPriorityList.map(\.providerId), ["Mistral", "Groq"])
    }

    func testFallbackListRejectsDuplicatePairsAndPersistsRemoval() throws {
        let suiteName = "PromptProcessingModelResolutionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            try JSONEncoder().encode([LLMFallbackPriorityItem]()),
            forKey: UserDefaultsKeys.llmFallbackPriorityList
        )

        let service = PromptProcessingService(userDefaults: defaults)
        service.addLLMFallback(providerId: "Groq", modelId: "llama-3.3")
        service.addLLMFallback(providerId: "Groq", modelId: "llama-3.3")
        service.addLLMFallback(providerId: "Mistral")

        XCTAssertEqual(service.fallbackPriorityList.count, 2)
        let groq = try XCTUnwrap(service.fallbackPriorityList.first)
        let mistral = try XCTUnwrap(service.fallbackPriorityList.last)

        service.updateLLMFallback(mistral, providerId: "Groq", modelId: "llama-3.3")
        XCTAssertEqual(service.fallbackPriorityList.map(\.providerId), ["Groq", "Mistral"])

        service.removeLLMFallback(groq)
        let reloaded = PromptProcessingService(userDefaults: defaults)
        XCTAssertEqual(reloaded.fallbackPriorityList.map(\.id), [mistral.id])
        XCTAssertEqual(reloaded.fallbackPriorityList.map(\.providerId), ["Mistral"])
    }

    func testEmptyFallbackListThrowsAggregateErrorWithoutAttempts() async throws {
        let suiteName = "PromptProcessingModelResolutionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            try JSONEncoder().encode([LLMFallbackPriorityItem]()),
            forKey: UserDefaultsKeys.llmFallbackPriorityList
        )

        let service = PromptProcessingService(userDefaults: defaults)

        do {
            _ = try await service.process(prompt: "Fix grammar", text: "hello world")
            XCTFail("Expected an empty fallback list to fail")
        } catch let error as LLMFallbackExhaustedError {
            XCTAssertTrue(error.failures.isEmpty)
            XCTAssertEqual(error.localizedDescription, "No LLM fallbacks are configured.")
        } catch {
            XCTFail("Expected LLMFallbackExhaustedError, got \(error)")
        }
    }
}
