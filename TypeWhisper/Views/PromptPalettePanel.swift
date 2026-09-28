import AppKit
import SwiftUI

@MainActor
enum PromptPaletteEntry {
    case workflow(Workflow)
    case recentTranscription(RecentTranscriptionStore.Entry)
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

        let itemPairs = visibleEntries.map { entry in
            (paletteItem(for: entry), entry)
        }
        let entriesByID = Dictionary(uniqueKeysWithValues: itemPairs.map { ($0.0.id, $0.1) })
        let containsRecentTranscriptions = visibleEntries.contains { entry in
            if case .recentTranscription = entry {
                return true
            }
            return false
        }

        paletteController.show(
            configuration: SelectionPaletteConfiguration(
                panelWidth: containsRecentTranscriptions ? 520 : 380,
                panelHeight: containsRecentTranscriptions ? 380 : 344,
                previewText: nil,
                previewLineLimit: 3,
                titleLineLimit: containsRecentTranscriptions ? 2 : 1,
                searchPrompt: searchPrompt(containsRecentTranscriptions: containsRecentTranscriptions),
                emptyStateTitle: emptyStateTitle(containsRecentTranscriptions: containsRecentTranscriptions)
            ),
            items: itemPairs.map { $0.0 }
        ) { item in
            guard let entry = entriesByID[item.id] else { return }
            onSelect(entry)
        }
    }

    func hide() {
        paletteController.hide()
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

    private func searchPrompt(containsRecentTranscriptions: Bool) -> String {
        containsRecentTranscriptions
            ? localizedAppText(
                "Search workflows and recent transcriptions...",
                de: "Workflows und letzte Transkriptionen suchen..."
            )
            : localizedAppText("Search workflows...", de: "Workflows suchen...")
    }

    private func emptyStateTitle(containsRecentTranscriptions: Bool) -> String {
        containsRecentTranscriptions
            ? localizedAppText("No matching results", de: "Keine passenden Ergebnisse")
            : localizedAppText("No matching workflows", de: "Keine passenden Workflows")
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
