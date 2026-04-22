import XCTest
@testable import TypeWhisper

@MainActor
final class LegacyWorkflowServiceTests: XCTestCase {
    func testProjectsLegacyRulesAndPromptsIntoReadOnlyItems() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "LegacyWorkflowServiceTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let promptAction = try XCTUnwrap(promptActionService.addAction(
            name: "Follow-up",
            prompt: "Turn the input into a concise follow-up message."
        ))

        profileService.addProfile(
            name: "Mail Follow-up",
            bundleIdentifiers: ["com.apple.mail"],
            translationEnabled: true,
            translationTargetLanguage: "de",
            promptActionId: promptAction.id.uuidString
        )

        let suiteName = "LegacyWorkflowServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LegacyWorkflowService(
            profileService: profileService,
            promptActionService: promptActionService,
            defaults: defaults
        )

        XCTAssertEqual(service.ruleItems.count, 1)
        XCTAssertEqual(service.promptItems.count, 1)

        let ruleItem = try XCTUnwrap(service.ruleItems.first)
        XCTAssertEqual(ruleItem.name, "Mail Follow-up")
        XCTAssertEqual(ruleItem.sourceKind, .rule)
        XCTAssertTrue(ruleItem.isEnabled)
        XCTAssertTrue(ruleItem.detail.contains("Follow-up"))

        let promptItem = try XCTUnwrap(service.promptItems.first)
        XCTAssertEqual(promptItem.name, "Follow-up")
        XCTAssertEqual(promptItem.sourceKind, .prompt)
        XCTAssertTrue(promptItem.isEnabled)
        XCTAssertTrue(promptItem.detail.contains("1"))
    }

    func testMarkImportedPersistsAcrossReload() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "LegacyWorkflowServiceTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let promptAction = try XCTUnwrap(promptActionService.addAction(
            name: "Checklist",
            prompt: "Return a checklist."
        ))

        let suiteName = "LegacyWorkflowServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var service = LegacyWorkflowService(
            profileService: profileService,
            promptActionService: promptActionService,
            defaults: defaults
        )

        let item = try XCTUnwrap(service.promptItems.first(where: { $0.sourceObjectId == promptAction.id }))
        service.markImported(item)

        service = LegacyWorkflowService(
            profileService: profileService,
            promptActionService: promptActionService,
            defaults: defaults
        )

        let reloadedItem = try XCTUnwrap(service.promptItems.first(where: { $0.sourceObjectId == promptAction.id }))
        XCTAssertTrue(reloadedItem.isImported)
    }

    func testDeleteLegacyRuleRemovesRuleItem() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "LegacyWorkflowServiceTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)

        profileService.addProfile(
            name: "Notes Rule",
            bundleIdentifiers: ["com.apple.Notes"]
        )

        let suiteName = "LegacyWorkflowServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LegacyWorkflowService(
            profileService: profileService,
            promptActionService: promptActionService,
            defaults: defaults
        )

        let ruleItem = try XCTUnwrap(service.ruleItems.first)
        service.deleteItem(ruleItem)

        XCTAssertTrue(service.ruleItems.isEmpty)
        XCTAssertTrue(profileService.profiles.isEmpty)
    }

    func testDeleteLegacyPromptRemovesPromptAndUnlinksProfiles() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "LegacyWorkflowServiceTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let promptAction = try XCTUnwrap(promptActionService.addAction(
            name: "Translate",
            prompt: "Translate the input."
        ))

        profileService.addProfile(
            name: "Mail Translate",
            bundleIdentifiers: ["com.apple.mail"],
            promptActionId: promptAction.id.uuidString
        )

        let suiteName = "LegacyWorkflowServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LegacyWorkflowService(
            profileService: profileService,
            promptActionService: promptActionService,
            defaults: defaults
        )

        let promptItem = try XCTUnwrap(service.promptItems.first(where: { $0.sourceObjectId == promptAction.id }))
        service.deleteItem(promptItem)

        XCTAssertTrue(service.promptItems.isEmpty)
        XCTAssertNil(profileService.profiles.first?.promptActionId)
        XCTAssertFalse(service.ruleItems.first?.detail.contains("Prompt:") ?? true)
    }
}
