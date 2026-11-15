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

/// An action the user can assign a keyboard shortcut to.
public struct ModuleHotkeyAction: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let perform: @MainActor @Sendable () -> Void

    public init(id: String, title: String, perform: @escaping @MainActor @Sendable () -> Void) {
        self.id = id
        self.title = title
        self.perform = perform
    }
}

/// An entry in the menu bar menu.
public struct ModuleMenuItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let perform: @MainActor @Sendable () -> Void

    public init(id: String, title: String, perform: @escaping @MainActor @Sendable () -> Void) {
        self.id = id
        self.title = title
        self.perform = perform
    }
}

/// A floating panel the app shows on request.
public struct ModulePanel: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let makeContent: @MainActor @Sendable () -> AnyView

    public init(id: String, title: String, makeContent: @escaping @MainActor @Sendable () -> AnyView) {
        self.id = id
        self.title = title
        self.makeContent = makeContent
    }
}

/// An action on a single history record.
public struct ModuleRecordAction: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    /// Receives the identifier of the record.
    public let perform: @MainActor @Sendable (UUID) -> Void

    public init(
        id: String,
        title: String,
        systemImage: String,
        perform: @escaping @MainActor @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.perform = perform
    }
}

/// A card in the Premium overview.
public struct ModulePremiumCard: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let systemImage: String

    public init(id: String, title: String, summary: String, systemImage: String) {
        self.id = id
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
    }
}

/// A managed settings key a module reads. The app reads its value from the
/// managed preferences and reports it like its own keys.
public struct ModuleManagedPolicyKey: Hashable, Sendable {
    public enum ValueType: String, Sendable {
        case boolean
        case integer
        case string
    }

    public let name: String
    public let valueType: ValueType

    public init(name: String, valueType: ValueType) {
        self.name = name
        self.valueType = valueType
    }
}
