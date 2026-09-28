import XCTest
@testable import TypeWhisper

@MainActor
final class PromptPaletteControllerTests: XCTestCase {
    func testTopLevelGroupsRecentTranscriptionsBehindSingleItem() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)

        controller.show(
            entries: [
                .workflow(makeWorkflow(name: "Summarize")),
                .recentTranscription(makeRecentEntry(text: "hello world")),
                .recentTranscription(makeRecentEntry(text: "second note")),
            ],
            sourceText: nil,
            onSelect: { _ in }
        )

        XCTAssertEqual(spy.shows.count, 1)
        let titles = spy.shows[0].items.map(\.title)
        XCTAssertEqual(
            titles,
            ["Summarize", localizedAppText("Recent Transcriptions", de: "Letzte Transkriptionen")]
        )
        XCTAssertEqual(
            spy.shows[0].items[1].subtitle,
            localizedAppText(
                "2 recent transcriptions",
                de: "2 letzte Transkriptionen",
                ja: "最近の文字起こし2件",
                zh: "2 条最近转录"
            )
        )
    }

    func testTopLevelSearchSurfacesMatchingRecentTranscriptions() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        var selected: [PromptPaletteEntry] = []
        controller.show(
            entries: [
                .workflow(makeWorkflow(name: "Summarize")),
                .recentTranscription(makeRecentEntry(text: "hello world")),
                .recentTranscription(makeRecentEntry(text: "second note")),
            ],
            sourceText: nil,
            onSelect: { selected.append($0) }
        )

        // Recent transcriptions ride along as secondary items: hidden until
        // the user types, then matched like top-level rows.
        let secondaryItems = spy.shows[0].configuration.secondaryItems
        XCTAssertEqual(secondaryItems.map(\.title), ["hello world", "second note"])

        spy.shows[0].onSelect(secondaryItems[0])
        guard case .recentTranscription(let forwarded) = selected.first else {
            return XCTFail("expected a recent transcription entry")
        }
        XCTAssertEqual(forwarded.finalText, "hello world")
    }

    func testSelectingGroupItemShowsRecentTranscriptionsList() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        controller.show(
            entries: [
                .workflow(makeWorkflow(name: "Summarize")),
                .recentTranscription(makeRecentEntry(text: "hello world")),
                .recentTranscription(makeRecentEntry(text: "second note")),
            ],
            sourceText: nil,
            onSelect: { _ in }
        )

        // The group item is the last top-level item.
        spy.selectItem(at: 1, inShow: 0)

        XCTAssertEqual(spy.shows.count, 2)
        let secondLevel = spy.shows[1]
        XCTAssertEqual(secondLevel.items.map(\.title), ["hello world", "second note"])
        XCTAssertEqual(secondLevel.configuration.panelWidth, 520)
        XCTAssertEqual(
            secondLevel.configuration.searchPrompt,
            localizedAppText("Search recent transcriptions...", de: "Letzte Transkriptionen suchen...")
        )
    }

    func testEscapeFromRecentsReselectsGroupItem() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        controller.show(
            entries: [
                .workflow(makeWorkflow(name: "Summarize")),
                .recentTranscription(makeRecentEntry(text: "hello world")),
            ],
            sourceText: nil,
            onSelect: { _ in }
        )

        spy.selectItem(at: 1, inShow: 0) // group item -> second level
        spy.pressEscape(inShow: 1) // back to the workflow level

        XCTAssertEqual(spy.shows.count, 3)
        // The group item is preselected, so a habitual Return re-enters the
        // recents instead of running the first workflow.
        XCTAssertEqual(spy.shows[2].configuration.initialSelectedIndex, 1)
    }

    func testSelectingRecentTranscriptionForwardsOriginalEntry() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        let entry = makeRecentEntry(text: "hello world")
        var selected: [PromptPaletteEntry] = []
        controller.show(
            entries: [.recentTranscription(entry)],
            sourceText: nil,
            onSelect: { selected.append($0) }
        )

        spy.selectItem(at: 0, inShow: 0) // the transcription, shown directly

        XCTAssertEqual(selected.count, 1)
        guard case .recentTranscription(let forwarded) = selected.first else {
            return XCTFail("expected a recent transcription entry")
        }
        XCTAssertEqual(forwarded.id, entry.id)
        XCTAssertEqual(forwarded.finalText, "hello world")
    }

    func testSelectingWorkflowAtTopLevelForwardsWorkflowEntry() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        var selected: [PromptPaletteEntry] = []
        controller.show(
            entries: [
                .workflow(makeWorkflow(name: "Summarize")),
                .recentTranscription(makeRecentEntry(text: "hello world")),
            ],
            sourceText: nil,
            onSelect: { selected.append($0) }
        )

        spy.selectItem(at: 0, inShow: 0)

        XCTAssertEqual(selected.count, 1)
        guard case .workflow(let workflow) = selected.first else {
            return XCTFail("expected a workflow entry")
        }
        XCTAssertEqual(workflow.name, "Summarize")
    }

    func testWorkflowsWithoutRecentsShowFlatList() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        var selected: [PromptPaletteEntry] = []
        controller.show(
            entries: [
                .workflow(makeWorkflow(name: "Summarize")),
                .workflow(makeWorkflow(name: "Translate")),
            ],
            sourceText: nil,
            onSelect: { selected.append($0) }
        )

        XCTAssertEqual(spy.shows.count, 1)
        XCTAssertEqual(spy.shows[0].items.map(\.title), ["Summarize", "Translate"])

        spy.selectItem(at: 1, inShow: 0)
        guard case .workflow(let workflow) = selected.first else {
            return XCTFail("expected a workflow entry")
        }
        XCTAssertEqual(workflow.name, "Translate")
    }

    func testRecentsWithoutWorkflowsShowDirectly() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        controller.show(
            entries: [.recentTranscription(makeRecentEntry(text: "hello world"))],
            sourceText: nil,
            onSelect: { _ in }
        )

        // No workflows to list: the recents skip the group item and show
        // directly, so a single Return inserts one.
        XCTAssertEqual(spy.shows.count, 1)
        XCTAssertEqual(spy.shows[0].items.map(\.title), ["hello world"])
        XCTAssertNil(spy.shows[0].onEscape)
    }

    func testDisabledWorkflowsAreFilteredBeforeGrouping() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        controller.show(
            entries: [
                .workflow(makeWorkflow(name: "Disabled", isEnabled: false)),
                .recentTranscription(makeRecentEntry(text: "hello world")),
            ],
            sourceText: nil,
            onSelect: { _ in }
        )

        XCTAssertEqual(spy.shows.count, 1)
        // The disabled workflow is filtered out, leaving no workflows — the
        // recents show directly instead of behind a group item.
        XCTAssertEqual(spy.shows[0].items.map(\.title), ["hello world"])
    }

    func testEmptyEntriesShowNothing() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        controller.show(entries: [], sourceText: nil, onSelect: { _ in })

        XCTAssertTrue(spy.shows.isEmpty)
        XCTAssertFalse(spy.isVisible)
    }

    func testEscapeOnRecentTranscriptionsReturnsToWorkflowList() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        controller.show(
            entries: [
                .workflow(makeWorkflow(name: "Summarize")),
                .recentTranscription(makeRecentEntry(text: "hello world")),
            ],
            sourceText: nil,
            onSelect: { _ in }
        )

        spy.selectItem(at: 1, inShow: 0) // group item -> second level
        XCTAssertEqual(spy.shows.count, 2)
        XCTAssertNotNil(spy.shows[1].onEscape)

        spy.pressEscape(inShow: 1)

        XCTAssertEqual(spy.shows.count, 3)
        XCTAssertEqual(spy.shows[2].items.map(\.title), ["Summarize", "Recent Transcriptions"])
    }

    func testEscapeOnTopLevelKeepsDefaultDismissBehavior() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        controller.show(
            entries: [
                .workflow(makeWorkflow(name: "Summarize")),
                .recentTranscription(makeRecentEntry(text: "hello world")),
            ],
            sourceText: nil,
            onSelect: { _ in }
        )

        // No custom Escape handler on the top level: the palette layer hides.
        XCTAssertNil(spy.shows[0].onEscape)
    }

    func testEscapeOnFlatListKeepsDefaultDismissBehavior() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        controller.show(
            entries: [.workflow(makeWorkflow(name: "Summarize"))],
            sourceText: nil,
            onSelect: { _ in }
        )

        XCTAssertEqual(spy.shows.count, 1)
        XCTAssertNil(spy.shows[0].onEscape)
    }

    // MARK: - Helpers

    private func makeWorkflow(name: String, isEnabled: Bool = true) -> Workflow {
        Workflow(name: name, isEnabled: isEnabled, template: .summary, trigger: .manual())
    }

    private func makeRecentEntry(text: String) -> RecentTranscriptionStore.Entry {
        RecentTranscriptionStore.Entry(
            id: UUID(),
            finalText: text,
            timestamp: Date(),
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            source: .session
        )
    }
}

@MainActor
private final class SelectionPaletteControllerSpy: SelectionPaletteControlling {
    struct ShownPalette {
        let configuration: SelectionPaletteConfiguration
        let items: [SelectionPaletteItem]
        let onSelect: (SelectionPaletteItem) -> Void
        let onEscape: (() -> Void)?
    }

    var isVisible = false
    private(set) var shows: [ShownPalette] = []

    func show(
        configuration: SelectionPaletteConfiguration,
        items: [SelectionPaletteItem],
        onSelect: @escaping (SelectionPaletteItem) -> Void,
        onEscape: (() -> Void)?
    ) {
        isVisible = true
        shows.append(ShownPalette(configuration: configuration, items: items, onSelect: onSelect, onEscape: onEscape))
    }

    func hide() {
        isVisible = false
    }

    func selectItem(at index: Int, inShow showIndex: Int) {
        let shown = shows[showIndex]
        shown.onSelect(shown.items[index])
    }

    func pressEscape(inShow showIndex: Int) {
        shows[showIndex].onEscape?()
    }
}
