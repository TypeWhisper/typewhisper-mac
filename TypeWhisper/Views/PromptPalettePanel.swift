import AppKit
import SwiftUI

@MainActor
enum PromptPaletteEntry {
    case workflow(Workflow)
    case recentTranscription(RecentTranscriptionStore.Entry)
}

private extension PromptPaletteEntry {
    var workflow: Workflow? {
        guard case .workflow(let workflow) = self else { return nil }
        return workflow
    }

    var recentEntry: RecentTranscriptionStore.Entry? {
        guard case .recentTranscription(let entry) = self else { return nil }
        return entry
    }
}

@MainActor
protocol PromptPaletteControlling: AnyObject {
    var isVisible: Bool { get }
    func show(entries: [PromptPaletteEntry], sourceText: String?, onSelect: @escaping (PromptPaletteEntry) -> Void)
    func hide()
}

@MainActor
final class PromptPaletteController: PromptPaletteControlling {
    private let paletteController: any SelectionPaletteControlling
    private let relativeDateFormatter = RelativeDateTimeFormatter()

    init(paletteController: any SelectionPaletteControlling = SelectionPaletteController()) {
        self.paletteController = paletteController
        relativeDateFormatter.unitsStyle = .short
    }

    var isVisible: Bool { paletteController.isVisible }

    func show(entries: [PromptPaletteEntry], sourceText _: String?, onSelect: @escaping (PromptPaletteEntry) -> Void) {
        let visibleEntries = entries.filter { entry in
            switch entry {
            case .workflow(let workflow):
                return workflow.isEnabled
            case .recentTranscription:
                return true
            }
        }
        guard !visibleEntries.isEmpty else { return }

        let recentEntries = visibleEntries.compactMap(\.recentEntry)
        guard !recentEntries.isEmpty else {
            showFlat(entries: visibleEntries, onSelect: onSelect)
            return
        }

        // Top level: workflows stay prominent, recent transcriptions collapse
        // behind a single group item.
        let groupItem = recentTranscriptionsGroupItem(count: recentEntries.count)
        let workflowPairs = visibleEntries.compactMap(\.workflow).map { workflow in
            (paletteItem(for: .workflow(workflow)), PromptPaletteEntry.workflow(workflow))
        }
        let entriesByID = Dictionary(uniqueKeysWithValues: workflowPairs.map { ($0.0.id, $0.1) })
        showWorkflowLevel(
            workflowItems: workflowPairs.map(\.0),
            groupItem: groupItem,
            entriesByID: entriesByID,
            recentEntries: recentEntries,
            onSelect: onSelect
        )
    }

    /// The workflow list. Also the landing place when backing out of the
    /// recent-transcriptions level with Escape.
    private func showWorkflowLevel(
        workflowItems: [SelectionPaletteItem],
        groupItem: SelectionPaletteItem,
        entriesByID: [UUID: PromptPaletteEntry],
        recentEntries: [RecentTranscriptionStore.Entry],
        onSelect: @escaping (PromptPaletteEntry) -> Void
    ) {
        paletteController.show(
            configuration: workflowLevelConfiguration,
            items: workflowItems + [groupItem],
            onSelect: { [weak self] item in
                guard let self else { return }
                if item.id == groupItem.id {
                    self.showRecentTranscriptions(
                        recentEntries,
                        onSelect: onSelect,
                        onBack: { [weak self] in
                            self?.showWorkflowLevel(
                                workflowItems: workflowItems,
                                groupItem: groupItem,
                                entriesByID: entriesByID,
                                recentEntries: recentEntries,
                                onSelect: onSelect
                            )
                        }
                    )
                } else if let entry = entriesByID[item.id] {
                    onSelect(entry)
                }
            }
        )
    }

    func hide() {
        paletteController.hide()
    }

    /// The pre-submenu behavior: a flat list, used when there are no recent
    /// transcriptions to group.
    private func showFlat(entries: [PromptPaletteEntry], onSelect: @escaping (PromptPaletteEntry) -> Void) {
        let itemPairs = entries.map { entry in
            (paletteItem(for: entry), entry)
        }
        let entriesByID = Dictionary(uniqueKeysWithValues: itemPairs.map { ($0.0.id, $0.1) })
        paletteController.show(
            configuration: workflowLevelConfiguration,
            items: itemPairs.map(\.0),
            onSelect: { item in
                guard let entry = entriesByID[item.id] else { return }
                onSelect(entry)
            }
        )
    }

    /// Second level behind the group item: the recent transcriptions list.
    /// Selecting one forwards the original entry, so insertion behavior is
    /// unchanged. Escape backs out to the workflow list via `onBack` instead
    /// of dismissing the palette.
    private func showRecentTranscriptions(
        _ recentEntries: [RecentTranscriptionStore.Entry],
        onSelect: @escaping (PromptPaletteEntry) -> Void,
        onBack: @escaping () -> Void
    ) {
        let itemPairs = recentEntries.map { entry in
            (paletteItem(for: .recentTranscription(entry)), entry)
        }
        let entriesByID = Dictionary(uniqueKeysWithValues: itemPairs.map { ($0.0.id, $0.1) })
        paletteController.show(
            configuration: recentTranscriptionsConfiguration,
            items: itemPairs.map(\.0),
            onSelect: { item in
                guard let entry = entriesByID[item.id] else { return }
                onSelect(.recentTranscription(entry))
            },
            onEscape: onBack
        )
    }

    private var workflowLevelConfiguration: SelectionPaletteConfiguration {
        SelectionPaletteConfiguration(
            panelWidth: 380,
            panelHeight: 344,
            previewText: nil,
            previewLineLimit: 3,
            titleLineLimit: 1,
            searchPrompt: localizedAppText("Search workflows...", de: "Workflows suchen..."),
            emptyStateTitle: localizedAppText("No matching workflows", de: "Keine passenden Workflows")
        )
    }

    private var recentTranscriptionsConfiguration: SelectionPaletteConfiguration {
        SelectionPaletteConfiguration(
            panelWidth: 520,
            panelHeight: 380,
            previewText: nil,
            previewLineLimit: 3,
            titleLineLimit: 2,
            searchPrompt: localizedAppText(
                "Search recent transcriptions...",
                de: "Letzte Transkriptionen suchen..."
            ),
            emptyStateTitle: localizedAppText("No matching results", de: "Keine passenden Ergebnisse")
        )
    }

    private func recentTranscriptionsGroupItem(count: Int) -> SelectionPaletteItem {
        SelectionPaletteItem(
            id: UUID(),
            title: localizedAppText("Recent Transcriptions", de: "Letzte Transkriptionen"),
            subtitle: recentTranscriptionsGroupSubtitle(count: count),
            iconSystemName: "clock.arrow.circlepath",
            searchTokens: [
                localizedAppText("Recent Transcription", de: "Letzte Transkription"),
                localizedAppText("Recent Transcriptions", de: "Letzte Transkriptionen"),
            ]
        )
    }

    private func recentTranscriptionsGroupSubtitle(count: Int) -> String {
        if count == 1 {
            return localizedAppText("1 recent transcription", de: "1 letzte Transkription")
        }
        return localizedAppText("\(count) recent transcriptions", de: "\(count) letzte Transkriptionen")
    }

    private func paletteItem(for entry: PromptPaletteEntry) -> SelectionPaletteItem {
        switch entry {
        case .workflow(let workflow):
            SelectionPaletteItem(
                id: UUID(),
                title: workflow.name,
                subtitle: workflowPaletteSubtitle(for: workflow),
                iconSystemName: workflow.definition.systemImage,
                searchTokens: workflowPaletteSearchTokens(for: workflow)
            )
        case .recentTranscription(let recentEntry):
            SelectionPaletteItem(
                id: UUID(),
                title: recentEntry.finalText,
                subtitle: recentTranscriptionSubtitle(for: recentEntry),
                iconSystemName: "clock.arrow.circlepath",
                searchTokens: recentTranscriptionSearchTokens(for: recentEntry)
            )
        }
    }

    private func workflowPaletteSubtitle(for workflow: Workflow) -> String? {
        guard let trigger = workflow.trigger else {
            return workflow.definition.name
        }

        let triggerSummary: String
        switch trigger.kind {
        case .global, .manual:
            triggerSummary = trigger.kind.paletteLabel
        case .app, .website, .hotkey:
            triggerSummary = workflowPaletteTriggerComponents(for: trigger).joined(separator: " + ")
        }

        if workflow.name.localizedCaseInsensitiveCompare(workflow.definition.name) == .orderedSame {
            return triggerSummary
        }
        return "\(workflow.definition.name) · \(triggerSummary)"
    }

    private func workflowPaletteSearchTokens(for workflow: Workflow) -> [String] {
        var tokens = [workflow.name, workflow.definition.name]
        if let trigger = workflow.trigger {
            tokens.append(trigger.kind.paletteLabel)
            tokens.append(contentsOf: workflowPaletteTriggerLabels(for: trigger))
            tokens.append(contentsOf: trigger.appBundleIdentifiers.map(resolveAppDisplayName(for:)))
            tokens.append(contentsOf: trigger.appBundleIdentifiers)
            tokens.append(contentsOf: trigger.websitePatterns)
            tokens.append(contentsOf: trigger.hotkeys.map(HotkeyService.displayName(for:)))
            tokens.append(trigger.hotkeyBehavior.shortcutSubtitle)
        }
        return tokens
    }

    private func workflowPaletteTriggerComponents(for trigger: WorkflowTrigger) -> [String] {
        var components: [String] = []
        if !trigger.appBundleIdentifiers.isEmpty {
            let appNames = trigger.appBundleIdentifiers.map(resolveAppDisplayName(for:))
            components.append("\(WorkflowTriggerKind.app.paletteLabel): \(appNames.joined(separator: ", "))")
        }
        if !trigger.websitePatterns.isEmpty {
            components.append("\(WorkflowTriggerKind.website.paletteLabel): \(trigger.websitePatterns.joined(separator: ", "))")
        }
        if !trigger.hotkeys.isEmpty {
            components.append("\(WorkflowTriggerKind.hotkey.paletteLabel): \(trigger.hotkeys.map(HotkeyService.displayName(for:)).joined(separator: ", ")) · \(trigger.hotkeyBehavior.shortcutSubtitle)")
        }
        return components.isEmpty ? [trigger.kind.paletteLabel] : components
    }

    private func workflowPaletteTriggerLabels(for trigger: WorkflowTrigger) -> [String] {
        var labels: [String] = []
        if !trigger.appBundleIdentifiers.isEmpty {
            labels.append(WorkflowTriggerKind.app.paletteLabel)
        }
        if !trigger.websitePatterns.isEmpty {
            labels.append(WorkflowTriggerKind.website.paletteLabel)
        }
        if !trigger.hotkeys.isEmpty {
            labels.append(WorkflowTriggerKind.hotkey.paletteLabel)
        }
        return labels
    }

    private func resolveAppDisplayName(for bundleIdentifier: String) -> String {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let bundle = Bundle(url: appURL) else {
            return bundleIdentifier
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
            ?? bundleIdentifier
    }

    private func recentTranscriptionSubtitle(for entry: RecentTranscriptionStore.Entry) -> String {
        let relativeTimestamp = relativeDateFormatter.localizedString(for: entry.timestamp, relativeTo: Date())
        let appName = entry.appName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let appName, !appName.isEmpty {
            return "\(appName) • \(relativeTimestamp)"
        }
        return relativeTimestamp
    }

    private func recentTranscriptionSearchTokens(for entry: RecentTranscriptionStore.Entry) -> [String] {
        [
            localizedAppText("Recent Transcription", de: "Letzte Transkription"),
            localizedAppText("Recent Transcriptions", de: "Letzte Transkriptionen"),
            entry.appName,
            entry.appBundleIdentifier,
        ].compactMap { $0 }
    }
}
