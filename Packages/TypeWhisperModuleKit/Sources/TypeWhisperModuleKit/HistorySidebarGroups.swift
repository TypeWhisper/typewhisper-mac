import Combine
import Foundation
import SwiftUI

/// A section of its own in the sidebar of the History window, below the
/// app's mailboxes and devices.
///
/// The sidebar shows the group with the number of its entries while
/// `isVisible` is true. Selected, the list column shows its entries, newest
/// first, and the detail column the view of the selected entry. The search
/// field of the History window then filters the entries by title and subtitle.
public struct ModuleHistorySidebarGroup: Identifiable, Sendable {
    /// Creates an entry, from a button in the toolbar while the group is selected.
    public struct NewEntry: Sendable {
        /// The button's title, such as "New Item".
        public let title: String
        /// Creates an entry and returns its identifier, or nil when it created none.
        /// The app selects the entry and shows its view, even before it is
        /// part of `entries()`.
        public let perform: @MainActor @Sendable () -> String?

        public init(title: String, perform: @escaping @MainActor @Sendable () -> String?) {
            self.title = title
            self.perform = perform
        }
    }

    public let id: String
    /// The section header and the title of the sidebar row.
    public let title: String
    public let systemImage: String
    /// Nil offers no button to create entries.
    public let newEntry: NewEntry?

    private let visibility: @MainActor @Sendable () -> Bool
    private let entryList: @MainActor @Sendable () -> [ModuleHistorySidebarEntry]
    private let changes: @MainActor @Sendable (@escaping @MainActor () -> Void) -> AnyCancellable
    private let content: @MainActor @Sendable (String) -> AnyView
    private let deletion: (@MainActor @Sendable (String) -> Void)?

    /// - Parameters:
    ///   - isVisible: Whether the sidebar shows the group. The app asks again
    ///     after every change `observeChanges` reports.
    ///   - entries: The entries in any order.
    ///   - observeChanges: Calls the handler on the main actor whenever the
    ///     entries or the visibility change, until the returned value is
    ///     cancelled or released.
    ///   - makeContent: The view of one entry, for the detail column. Called
    ///     each time the user selects the entry.
    ///   - delete: Deletes an entry after the user confirmed it. Nil offers no
    ///     deletion. Report the change through `observeChanges`.
    public init(
        id: String,
        title: String,
        systemImage: String,
        isVisible: @escaping @MainActor @Sendable () -> Bool = { true },
        entries: @escaping @MainActor @Sendable () -> [ModuleHistorySidebarEntry],
        observeChanges: @escaping @MainActor @Sendable (@escaping @MainActor () -> Void) -> AnyCancellable,
        makeContent: @escaping @MainActor @Sendable (_ entryID: String) -> AnyView,
        newEntry: NewEntry? = nil,
        delete: (@MainActor @Sendable (_ entryID: String) -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.newEntry = newEntry
        visibility = isVisible
        entryList = entries
        changes = observeChanges
        content = makeContent
        deletion = delete
    }

    @MainActor public var isVisible: Bool { visibility() }

    @MainActor public func entries() -> [ModuleHistorySidebarEntry] { entryList() }

    @MainActor public func observeChanges(_ handler: @escaping @MainActor () -> Void) -> AnyCancellable {
        changes(handler)
    }

    @MainActor public func makeContent(forEntryID id: String) -> AnyView { content(id) }

    public var canDelete: Bool { deletion != nil }

    @MainActor public func delete(entryID: String) { deletion?(entryID) }
}

/// One entry of a `ModuleHistorySidebarGroup`.
public struct ModuleHistorySidebarEntry: Identifiable, Hashable, Sendable {
    /// Unique within the group.
    public let id: String
    public let title: String
    public let subtitle: String?
    /// Orders the list, newest first, and shows in the row.
    public let date: Date

    public init(id: String, title: String, subtitle: String? = nil, date: Date) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.date = date
    }
}
