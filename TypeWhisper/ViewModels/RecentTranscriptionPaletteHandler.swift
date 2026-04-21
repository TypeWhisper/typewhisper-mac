import Foundation

@MainActor
final class RecentTranscriptionPaletteHandler {
    private let paletteController: any SelectionPaletteControlling
    private let textInsertionService: TextInsertionService
    private let historyService: HistoryService
    private let recentTranscriptionStore: RecentTranscriptionStore
    private let relativeDateFormatter = RelativeDateTimeFormatter()

    var onShowNotchFeedback: ((String, String, TimeInterval, Bool, String?) -> Void)?
    var getPreserveClipboard: (() -> Bool)?

    init(
        textInsertionService: TextInsertionService,
        historyService: HistoryService,
        recentTranscriptionStore: RecentTranscriptionStore,
        paletteController: any SelectionPaletteControlling = SelectionPaletteController()
    ) {
        self.textInsertionService = textInsertionService
        self.historyService = historyService
        self.recentTranscriptionStore = recentTranscriptionStore
        self.paletteController = paletteController
        relativeDateFormatter.unitsStyle = .short
    }

    func hide() {
        paletteController.hide()
    }

    func triggerSelection(currentState: DictationViewModel.State) {
        if paletteController.isVisible {
            paletteController.hide()
            return
        }

        guard currentState == .idle else { return }

        let entries = recentTranscriptionStore.mergedEntries(historyRecords: historyService.records)
        guard !entries.isEmpty else {
            onShowNotchFeedback?(
                String(localized: "No recent transcriptions"),
                "clock.arrow.circlepath",
                2.5,
                false,
                nil
            )
            return
        }

        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let items = entries.map { entry in
            SelectionPaletteItem(
                id: entry.id,
                title: entry.finalText,
                subtitle: subtitle(for: entry),
                iconSystemName: nil,
                searchTokens: [entry.appName, entry.appBundleIdentifier].compactMap { $0 }
            )
        }

        paletteController.show(
            configuration: SelectionPaletteConfiguration(
                panelWidth: 520,
                panelHeight: 360,
                titleLineLimit: 2,
                emptyStateTitle: String(localized: "No recent transcriptions")
            ),
            items: items
        ) { [weak self] item in
            guard let self, let entry = entriesByID[item.id] else { return }
            Task { @MainActor in
                await self.insert(entry)
            }
        }
    }

    private func insert(_ entry: RecentTranscriptionStore.Entry) async {
        do {
            _ = try await textInsertionService.insertText(
                entry.finalText,
                preserveClipboard: getPreserveClipboard?() ?? false,
                autoEnter: false
            )
            onShowNotchFeedback?(String(localized: "Text inserted"), "checkmark.circle.fill", 2.5, false, nil)
        } catch {
            onShowNotchFeedback?(error.localizedDescription, "xmark.circle.fill", 2.5, true, "recentTranscriptions")
        }
    }

    private func subtitle(for entry: RecentTranscriptionStore.Entry) -> String {
        let relativeTimestamp = relativeDateFormatter.localizedString(for: entry.timestamp, relativeTo: Date())
        let appName = entry.appName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let appName, !appName.isEmpty {
            return "\(appName) • \(relativeTimestamp)"
        }
        return relativeTimestamp
    }
}
