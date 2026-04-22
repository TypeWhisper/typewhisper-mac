import XCTest
@testable import TypeWhisper

final class ProfileServiceTests: XCTestCase {
    @MainActor
    func testProfileMatchingPrefersBundleAndURLSpecificity() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = ProfileService(appSupportDirectory: appSupportDirectory)

        service.addProfile(
            name: "Bundle Only",
            bundleIdentifiers: ["com.apple.Safari"],
            priority: 5
        )
        service.addProfile(
            name: "URL Only",
            urlPatterns: ["docs.github.com"],
            priority: 10
        )
        service.addProfile(
            name: "Bundle + URL",
            bundleIdentifiers: ["com.apple.Safari"],
            urlPatterns: ["github.com"],
            priority: 1
        )

        let firstMatch = service.matchProfile(
            bundleIdentifier: "com.apple.Safari",
            url: "https://docs.github.com/en/get-started"
        )
        XCTAssertEqual(firstMatch?.name, "Bundle + URL")

        service.toggleProfile(try XCTUnwrap(firstMatch))

        let fallbackMatch = service.matchProfile(
            bundleIdentifier: "com.apple.Safari",
            url: "https://docs.github.com/en/get-started"
        )
        XCTAssertEqual(fallbackMatch?.name, "URL Only")
    }

    @MainActor
    func testRuleMatchDetailsExplainPriorityWinsWithinSameTier() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = ProfileService(appSupportDirectory: appSupportDirectory)

        service.addProfile(
            name: "Docs Low",
            urlPatterns: ["docs.github.com"],
            priority: 1
        )
        service.addProfile(
            name: "Docs High",
            urlPatterns: ["docs.github.com"],
            priority: 9
        )

        let match = service.matchRule(
            bundleIdentifier: "com.apple.Safari",
            url: "https://docs.github.com/en/get-started"
        )

        XCTAssertEqual(match?.profile.name, "Docs High")
        XCTAssertEqual(match?.kind, .websiteOnly)
        XCTAssertTrue(match?.wonByPriority == true)
        XCTAssertEqual(match?.matchedDomain, "docs.github.com")
        XCTAssertEqual(match?.competingProfileCount, 1)
    }

    @MainActor
    func testRuleMatchingFallsBackToGlobalProfileWhenNothingSpecificMatches() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = ProfileService(appSupportDirectory: appSupportDirectory)

        service.addProfile(
            name: "Fallback Low",
            priority: 1
        )
        service.addProfile(
            name: "Fallback High",
            priority: 8
        )
        service.addProfile(
            name: "Safari Only",
            bundleIdentifiers: ["com.apple.Safari"],
            priority: 20
        )

        let fallbackMatch = service.matchRule(
            bundleIdentifier: "com.example.OtherApp",
            url: "https://example.com"
        )

        XCTAssertEqual(fallbackMatch?.profile.name, "Fallback High")
        XCTAssertEqual(fallbackMatch?.kind, .globalFallback)
        XCTAssertTrue(fallbackMatch?.wonByPriority == true)
        XCTAssertEqual(fallbackMatch?.competingProfileCount, 1)

        let specificMatch = service.matchRule(
            bundleIdentifier: "com.apple.Safari",
            url: "https://example.com"
        )

        XCTAssertEqual(specificMatch?.profile.name, "Safari Only")
        XCTAssertEqual(specificMatch?.kind, .appOnly)
    }

    @MainActor
    func testPrepareNewProfilePrefillsPromptActionAndKeepsEmptyScope() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let settingsViewModel = SettingsViewModel(modelManager: ModelManagerService())
        let viewModel = ProfilesViewModel(
            profileService: profileService,
            historyService: historyService,
            settingsViewModel: settingsViewModel
        )

        viewModel.prepareNewProfile(prefilledPromptActionId: "prompt-123")

        XCTAssertTrue(viewModel.showingEditor)
        XCTAssertEqual(viewModel.editorStep, .scope)
        XCTAssertEqual(viewModel.editorPromptActionId, "prompt-123")
        XCTAssertTrue(viewModel.editorPromptActionWasPrefilled)
        XCTAssertTrue(viewModel.editorBundleIdentifiers.isEmpty)
        XCTAssertTrue(viewModel.editorUrlPatterns.isEmpty)
        XCTAssertTrue(viewModel.shouldShowPrefilledPromptFallbackNotice)
    }

    @MainActor
    func testPrepareNewProfileWithoutPrefillKeepsPromptUnset() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let settingsViewModel = SettingsViewModel(modelManager: ModelManagerService())
        let viewModel = ProfilesViewModel(
            profileService: profileService,
            historyService: historyService,
            settingsViewModel: settingsViewModel
        )

        viewModel.prepareNewProfile()

        XCTAssertNil(viewModel.editorPromptActionId)
        XCTAssertFalse(viewModel.editorPromptActionWasPrefilled)
        XCTAssertFalse(viewModel.shouldShowPrefilledPromptFallbackNotice)
    }

    @MainActor
    func testFocusRulesByPromptFiltersVisibleProfiles() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let settingsViewModel = SettingsViewModel(modelManager: ModelManagerService())
        let viewModel = ProfilesViewModel(
            profileService: profileService,
            historyService: historyService,
            settingsViewModel: settingsViewModel
        )

        profileService.addProfile(name: "Prompt A 1", promptActionId: "prompt-a")
        profileService.addProfile(name: "Prompt B", promptActionId: "prompt-b")
        profileService.addProfile(name: "Prompt A 2", promptActionId: "prompt-a")
        viewModel.profiles = profileService.profiles

        XCTAssertEqual(viewModel.visibleProfiles.count, 3)

        viewModel.focusRules(usingPromptActionId: "prompt-a")

        XCTAssertTrue(viewModel.isFilteringRulesByPrompt)
        XCTAssertEqual(
            Set(viewModel.visibleProfiles.map(\.name)),
            Set(["Prompt A 1", "Prompt A 2"])
        )

        viewModel.clearPromptRuleFocus()

        XCTAssertFalse(viewModel.isFilteringRulesByPrompt)
        XCTAssertEqual(viewModel.visibleProfiles.count, 3)
    }
}
