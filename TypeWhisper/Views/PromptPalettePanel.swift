import SwiftUI

@MainActor
final class PromptPaletteController {
    private let paletteController: any SelectionPaletteControlling

    init(paletteController: any SelectionPaletteControlling = SelectionPaletteController()) {
        self.paletteController = paletteController
    }

    var isVisible: Bool { paletteController.isVisible }

    func show(actions: [PromptAction], sourceText: String, onSelect: @escaping (PromptAction) -> Void) {
        let enabledActions = actions.filter(\.isEnabled)
        guard !enabledActions.isEmpty else { return }

        let items = enabledActions.map {
            SelectionPaletteItem(
                id: $0.id,
                title: $0.name,
                iconSystemName: $0.icon,
                searchTokens: [$0.name]
            )
        }
        let actionsByID = Dictionary(uniqueKeysWithValues: enabledActions.map { ($0.id, $0) })

        paletteController.show(
            configuration: SelectionPaletteConfiguration(
                panelWidth: 380,
                panelHeight: 400,
                previewText: sourceText,
                previewLineLimit: 3,
                searchPrompt: String(localized: "Search prompts..."),
                emptyStateTitle: String(localized: "No matching prompts")
            ),
            items: items
        ) { item in
            guard let action = actionsByID[item.id] else { return }
            onSelect(action)
        }
    }

    func hide() {
        paletteController.hide()
    }
}
