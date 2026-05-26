import AppKit
import SwiftUI

@MainActor
protocol PromptPaletteControlling: AnyObject {
    var isVisible: Bool { get }
    func show(workflows: [Workflow], sourceText: String, onSelect: @escaping (Workflow) -> Void)
    func hide()
}

@MainActor
final class PromptPaletteController: PromptPaletteControlling {
    private let paletteController: any SelectionPaletteControlling

    init(paletteController: any SelectionPaletteControlling = SelectionPaletteController()) {
        self.paletteController = paletteController
    }

    var isVisible: Bool { paletteController.isVisible }

    func show(workflows: [Workflow], sourceText: String, onSelect: @escaping (Workflow) -> Void) {
        let enabledWorkflows = workflows.filter(\.isEnabled)
        guard !enabledWorkflows.isEmpty else { return }

        let items = enabledWorkflows.map {
            SelectionPaletteItem(
                id: $0.id,
                title: $0.name,
                subtitle: workflowPaletteSubtitle(for: $0),
                iconSystemName: $0.definition.systemImage,
                searchTokens: workflowPaletteSearchTokens(for: $0)
            )
        }
        let workflowsByID = Dictionary(uniqueKeysWithValues: enabledWorkflows.map { ($0.id, $0) })

        paletteController.show(
            configuration: SelectionPaletteConfiguration(
                panelWidth: 380,
                panelHeight: 344,
                previewText: nil,
                previewLineLimit: 3,
                searchPrompt: String(localized: "Search workflows..."),
                emptyStateTitle: String(localized: "No matching workflows")
            ),
            items: items
        ) { item in
            guard let workflow = workflowsByID[item.id] else { return }
            onSelect(workflow)
        }
    }

    func hide() {
        paletteController.hide()
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
}
