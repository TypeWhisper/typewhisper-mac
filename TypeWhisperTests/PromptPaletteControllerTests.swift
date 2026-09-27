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
        XCTAssertEqual(titles, ["Summarize", "Recent Transcriptions"])
        XCTAssertEqual(spy.shows[0].items[1].subtitle, "2 recent transcriptions")
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
        XCTAssertEqual(secondLevel.configuration.searchPrompt, "Search recent transcriptions...")
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

        spy.selectItem(at: 0, inShow: 0) // group item
        spy.selectItem(at: 0, inShow: 1) // the transcription

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

    func testRecentsWithoutWorkflowsShowOnlyGroupItem() {
        let spy = SelectionPaletteControllerSpy()
        let controller = PromptPaletteController(paletteController: spy)
        controller.show(
            entries: [.recentTranscription(makeRecentEntry(text: "hello world"))],
            sourceText: nil,
            onSelect: { _ in }
        )

        XCTAssertEqual(spy.shows.count, 1)
        XCTAssertEqual(spy.shows[0].items.map(\.title), ["Recent Transcriptions"])
        XCTAssertEqual(spy.shows[0].items[0].subtitle, "1 recent transcription")
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
        XCTAssertEqual(spy.shows[0].items.map(\.title), ["Recent Transcriptions"])
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
        onEscape: (@escaping () -> Void)? = nil
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
