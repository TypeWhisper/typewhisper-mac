import AppKit
import XCTest
@testable import TypeWhisper

@MainActor
final class WorkflowServiceTests: XCTestCase {
    func testWorkflowServicePersistsEncodedTriggerBehaviorAndOutput() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "WorkflowServiceTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let service = WorkflowService(appSupportDirectory: appSupportDirectory)
        let primaryHotkey = UnifiedHotkey(keyCode: 15, modifierFlags: 0, isFn: false)
        let secondaryHotkey = UnifiedHotkey(keyCode: 17, modifierFlags: NSEvent.ModifierFlags.command.rawValue, isFn: false)

        service.addWorkflow(
            name: "Meeting Notes",
            template: .meetingNotes,
            trigger: .hotkeys([primaryHotkey, secondaryHotkey]),
            behavior: WorkflowBehavior(
                settings: ["tone": "professional", "sections": "decisions,actions"],
                fineTuning: "Keep it concise.",
                providerId: "Groq",
                cloudModel: "llama-3.3",
                temperatureModeRaw: "custom",
                temperatureValue: 0.2
            ),
            output: WorkflowOutput(
                format: "markdown",
                autoEnter: true,
                targetActionPluginId: "plugin.action"
            )
        )

        let reloaded = WorkflowService(appSupportDirectory: appSupportDirectory)
        let workflow = try XCTUnwrap(reloaded.workflows.first)

        XCTAssertEqual(workflow.name, "Meeting Notes")
        XCTAssertEqual(workflow.template, .meetingNotes)
        XCTAssertEqual(workflow.trigger, .hotkeys([primaryHotkey, secondaryHotkey]))
        XCTAssertEqual(
            workflow.behavior,
            WorkflowBehavior(
                settings: ["tone": "professional", "sections": "decisions,actions"],
                fineTuning: "Keep it concise.",
                providerId: "Groq",
                cloudModel: "llama-3.3",
                temperatureModeRaw: "custom",
                temperatureValue: 0.2
            )
        )
        XCTAssertEqual(
            workflow.output,
            WorkflowOutput(
                format: "markdown",
                autoEnter: true,
                targetActionPluginId: "plugin.action"
            )
        )
    }

    func testReorderWorkflowsUsesProvidedOrder() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "WorkflowServiceTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let service = WorkflowService(appSupportDirectory: appSupportDirectory)
        let first = try XCTUnwrap(service.addWorkflow(
            name: "First",
            template: .cleanedText,
            trigger: .app("com.apple.mail")
        ))
        let second = try XCTUnwrap(service.addWorkflow(
            name: "Second",
            template: .translation,
            trigger: .website("docs.github.com")
        ))
        let third = try XCTUnwrap(service.addWorkflow(
            name: "Third",
            template: .summary,
            trigger: .hotkey(UnifiedHotkey(keyCode: 3, modifierFlags: 0, isFn: false))
        ))

        service.reorderWorkflows([third, first, second])

        XCTAssertEqual(service.workflows.map(\.name), ["Third", "First", "Second"])
        XCTAssertEqual(service.workflows.map(\.sortOrder), [0, 1, 2])
        XCTAssertEqual(service.nextSortOrder(), 3)
    }

    func testToggleAndDeleteWorkflowUpdatePublishedState() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "WorkflowServiceTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let service = WorkflowService(appSupportDirectory: appSupportDirectory)
        let workflow = try XCTUnwrap(service.addWorkflow(
            name: "Checklist",
            template: .checklist,
            trigger: .website("linear.app")
        ))

        XCTAssertTrue(workflow.isEnabled)

        service.toggleWorkflow(workflow)

        XCTAssertFalse(service.workflows[0].isEnabled)

        service.deleteWorkflow(workflow)

        XCTAssertTrue(service.workflows.isEmpty)
    }

    func testTemplateCatalogMatchesApprovedInitialOrder() {
        XCTAssertEqual(
            WorkflowTemplate.catalog.map(\.template),
            [.cleanedText, .translation, .emailReply, .meetingNotes, .checklist, .json, .summary, .custom]
        )
    }

    func testMatchWorkflowSupportsMultipleAppsAndWebsitesPerWorkflow() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "WorkflowServiceTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let service = WorkflowService(appSupportDirectory: appSupportDirectory)
        _ = service.addWorkflow(
            name: "Browsers Summary",
            template: .summary,
            trigger: .apps(["com.apple.Safari", "com.google.Chrome"])
        )
        _ = service.addWorkflow(
            name: "Docs Translation",
            template: .translation,
            trigger: .websites(["docs.github.com", "developer.apple.com"]),
            sortOrder: 0
        )

        let websiteMatch = try XCTUnwrap(service.matchWorkflow(
            bundleIdentifier: "com.google.Chrome",
            url: "https://developer.apple.com/documentation/swiftui"
        ))
        XCTAssertEqual(websiteMatch.workflow.name, "Docs Translation")
        XCTAssertEqual(websiteMatch.kind, .website)

        let appMatch = try XCTUnwrap(service.matchWorkflow(
            bundleIdentifier: "com.google.Chrome",
            url: "https://example.com"
        ))
        XCTAssertEqual(appMatch.workflow.name, "Browsers Summary")
        XCTAssertEqual(appMatch.kind, .app)
    }

    func testMatchWorkflowPrefersWebsiteBeforeAppAndUsesSortOrder() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "WorkflowServiceTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let service = WorkflowService(appSupportDirectory: appSupportDirectory)
        _ = service.addWorkflow(
            name: "Mail Cleanup",
            template: .cleanedText,
            trigger: .app("com.apple.mail"),
            sortOrder: 2
        )
        _ = service.addWorkflow(
            name: "Docs Summary",
            template: .summary,
            trigger: .website("docs.github.com"),
            sortOrder: 1
        )
        _ = service.addWorkflow(
            name: "Fallback Summary",
            template: .summary,
            trigger: .website("github.com"),
            sortOrder: 3
        )

        let match = try XCTUnwrap(service.matchWorkflow(
            bundleIdentifier: "com.apple.mail",
            url: "https://docs.github.com/en/actions"
        ))

        XCTAssertEqual(match.workflow.name, "Docs Summary")
        XCTAssertEqual(match.kind, .website)
        XCTAssertEqual(match.matchedDomain, "docs.github.com")
        XCTAssertEqual(match.competingWorkflowCount, 1)
        XCTAssertTrue(match.wonBySortOrder)
    }

    func testMatchWorkflowIgnoresDisabledAndHotkeyOnlyEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "WorkflowServiceTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let service = WorkflowService(appSupportDirectory: appSupportDirectory)
        _ = service.addWorkflow(
            name: "Disabled App Workflow",
            template: .cleanedText,
            trigger: .app("com.apple.mail"),
            isEnabled: false
        )
        _ = service.addWorkflow(
            name: "Manual Checklist",
            template: .checklist,
            trigger: .hotkey(UnifiedHotkey(keyCode: 3, modifierFlags: 0, isFn: false))
        )

        XCTAssertNil(service.matchWorkflow(bundleIdentifier: "com.apple.mail", url: "https://mail.google.com"))
    }

    func testForcedWorkflowMatchUsesManualOverrideKind() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "WorkflowServiceTests")
        defer { TestSupport.remove(appSupportDirectory) }

        let service = WorkflowService(appSupportDirectory: appSupportDirectory)
        let workflow = try XCTUnwrap(service.addWorkflow(
            name: "Manual Meeting Notes",
            template: .meetingNotes,
            trigger: .hotkey(UnifiedHotkey(keyCode: 14, modifierFlags: 0, isFn: false))
        ))

        let match = service.forcedWorkflowMatch(for: workflow)

        XCTAssertEqual(match.workflow.id, workflow.id)
        XCTAssertEqual(match.kind, .manualOverride)
        XCTAssertNil(match.matchedDomain)
        XCTAssertEqual(match.competingWorkflowCount, 0)
        XCTAssertFalse(match.wonBySortOrder)
    }
}
