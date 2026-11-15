import SwiftUI
import TypeWhisperModuleKit

/// A module's action on History records, as a button.
struct ModuleRecordActionButton: View {
    enum Style {
        /// The title, for context menus and the selection's actions.
        case title
        /// The symbol, for the record's header.
        case icon
    }

    let action: ModuleRecordAction
    let recordIDs: [UUID]
    let style: Style

    private var title: String {
        recordIDs.count > 1 ? action.selectionTitle ?? action.title : action.title
    }

    private var exceedsLimit: Bool {
        recordIDs.count > action.maximumRecordCount
    }

    var body: some View {
        switch style {
        case .title:
            button.help(exceedsLimit ? action.selectionLimitHelp ?? "" : "")
        case .icon:
            button
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(title)
        }
    }

    private var button: some View {
        Button {
            action.perform(recordIDs)
        } label: {
            Label(title, systemImage: action.systemImage)
        }
        .disabled(recordIDs.isEmpty || exceedsLimit)
    }
}

/// Says at the end of the Premium page that this build lacks features that
/// official builds include, without naming them.
struct PremiumModulesMissingNote: View {
    var body: some View {
        Label(String(localized: "premium.hub.modulesMissing"), systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("premium.modulesMissing")
    }
}
