import Foundation
import SwiftUI

/// Everything a module adds to the app.
public struct ModuleContributions: Sendable {
    public var hotkeyActions: [ModuleHotkeyAction]
    public var menuItems: [ModuleMenuItem]
    public var panels: [ModulePanel]
    public var recordActions: [ModuleRecordAction]
    public var premiumCards: [ModulePremiumCard]
    public var managedPolicyKeys: [ModuleManagedPolicyKey]

    public init(
        hotkeyActions: [ModuleHotkeyAction] = [],
        menuItems: [ModuleMenuItem] = [],
        panels: [ModulePanel] = [],
        recordActions: [ModuleRecordAction] = [],
        premiumCards: [ModulePremiumCard] = [],
        managedPolicyKeys: [ModuleManagedPolicyKey] = []
    ) {
        self.hotkeyActions = hotkeyActions
        self.menuItems = menuItems
        self.panels = panels
        self.recordActions = recordActions
        self.premiumCards = premiumCards
        self.managedPolicyKeys = managedPolicyKeys
    }

    public var isEmpty: Bool {
        hotkeyActions.isEmpty && menuItems.isEmpty && panels.isEmpty
            && recordActions.isEmpty && premiumCards.isEmpty && managedPolicyKeys.isEmpty
    }

    /// Adds the contributions of another module after these.
    public mutating func append(_ other: ModuleContributions) {
        hotkeyActions += other.hotkeyActions
        menuItems += other.menuItems
        panels += other.panels
        recordActions += other.recordActions
        premiumCards += other.premiumCards
        managedPolicyKeys += other.managedPolicyKeys
    }
}

// Identifiers are stable across launches, because the app stores settings
// under them, such as the shortcut assigned to a hotkey action.

/// An action the user can assign keyboard shortcuts to in the Hotkeys settings.
public struct ModuleHotkeyAction: Identifiable, Sendable {
    /// Letters, digits, dots, hyphens and underscores, at most 128 characters.
    /// The app leaves out an action with another identifier.
    public let id: String
    /// The row title in the settings, such as "Open panel shortcut".
    public let title: String
    public let subtitle: String?
    /// The section the row appears in. Actions with the same group share one.
    public let group: String?
    public let perform: @MainActor @Sendable () -> Void

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        group: String? = nil,
        perform: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.group = group
        self.perform = perform
    }
}

/// An entry in the menu bar menu, after History.
public struct ModuleMenuItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String?
    /// The hotkey action whose first shortcut the menu shows next to the entry.
    public let hotkeyActionID: String?
    /// Runs after the menu has closed, so it can show a panel.
    public let perform: @MainActor @Sendable () -> Void

    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        hotkeyActionID: String? = nil,
        perform: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.hotkeyActionID = hotkeyActionID
        self.perform = perform
    }
}

/// A floating panel the app shows on request (`ModuleHost.showPanel(withID:)`).
///
/// The panel floats above other apps, can be moved by its background and
/// closes with Escape. It takes the size of its content.
public struct ModulePanel: Identifiable, Sendable {
    public let id: String
    /// Names the panel for VoiceOver; the panel shows no title bar.
    public let title: String
    /// Called once, when the panel shows for the first time.
    public let makeContent: @MainActor @Sendable () -> AnyView
    public let didShow: (@MainActor @Sendable () -> Void)?
    public let didHide: (@MainActor @Sendable () -> Void)?

    public init(
        id: String,
        title: String,
        makeContent: @escaping @MainActor @Sendable () -> AnyView,
        didShow: (@MainActor @Sendable () -> Void)? = nil,
        didHide: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.makeContent = makeContent
        self.didShow = didShow
        self.didHide = didHide
    }
}

/// An action on History records, in a record's detail and in the context
/// menu of the record list.
public struct ModuleRecordAction: Identifiable, Sendable {
    public let id: String
    /// The title for one record.
    public let title: String
    /// The title for several selected records. Nil offers the action for one record only.
    public let selectionTitle: String?
    public let systemImage: String
    /// The most records the action takes at once. Beyond that it is disabled.
    public let maximumRecordCount: Int
    /// The help text of the disabled action when more records are selected.
    public let selectionLimitHelp: String?
    /// Receives the identifiers of the records, in the order of the list.
    public let perform: @MainActor @Sendable ([UUID]) -> Void

    public init(
        id: String,
        title: String,
        selectionTitle: String? = nil,
        systemImage: String,
        maximumRecordCount: Int = 1,
        selectionLimitHelp: String? = nil,
        perform: @escaping @MainActor @Sendable ([UUID]) -> Void
    ) {
        self.id = id
        self.title = title
        self.selectionTitle = selectionTitle
        self.systemImage = systemImage
        self.maximumRecordCount = maximumRecordCount
        self.selectionLimitHelp = selectionLimitHelp
        self.perform = perform
    }
}

/// A card in the Premium overview.
public struct ModulePremiumCard: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let systemImage: String
    /// A short line under the title while Premium is locked, such as an example.
    public let preview: String?
    /// The state shown while Premium is active, such as "On". Nil shows none.
    public let status: (@MainActor @Sendable () -> String?)?
    /// Opens the feature or its settings while Premium is active.
    public let perform: (@MainActor @Sendable () -> Void)?

    public init(
        id: String,
        title: String,
        summary: String,
        systemImage: String,
        preview: String? = nil,
        status: (@MainActor @Sendable () -> String?)? = nil,
        perform: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.preview = preview
        self.status = status
        self.perform = perform
    }
}

/// A managed settings key a module reads through `ManagedPolicyReading`.
///
/// The app reads it from the managed preferences, validates it and reports it
/// in its diagnostics like its own keys. A name the app or an earlier module
/// already uses is skipped.
public struct ModuleManagedPolicyKey: Hashable, Sendable {
    /// The value shapes of the app's own keys.
    public enum Kind: String, Sendable {
        /// A property list Boolean.
        case boolean
        /// A property list integer from 0 to `enumerationMaximum`.
        case enumeration
        /// A trimmed, nonempty string without control characters.
        case text
        /// An array of such strings.
        case list
    }

    /// The exact, case-sensitive preference key.
    public let name: String
    public let kind: Kind
    /// Whether the key may also appear in the managed `Recommended` dictionary.
    public let allowsRecommendation: Bool
    /// The largest valid value of an enumeration.
    public let enumerationMaximum: Int
    /// Whether the value must never appear in diagnostics, logs or exports.
    public let sensitive: Bool

    public init(
        name: String,
        kind: Kind,
        allowsRecommendation: Bool = false,
        enumerationMaximum: Int = 0,
        sensitive: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.allowsRecommendation = allowsRecommendation
        self.enumerationMaximum = enumerationMaximum
        self.sensitive = sensitive
    }
}
