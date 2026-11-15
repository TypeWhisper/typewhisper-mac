import Combine

/// Reads the managed settings keys the modules declare
/// (`ModuleContributions.managedPolicyKeys`).
///
/// The app validates and reports these keys like its own. Keys that no module
/// declared, and the app's own keys, have no value here.
@MainActor
public protocol ManagedPolicyReading: AnyObject {
    func state(ofKey name: String) -> ModuleManagedPolicyState

    /// Reads the managed preferences again, so a changed profile applies to
    /// the next request instead of after the app's next periodic read.
    func refresh()

    /// Calls `handler` on the main actor after the managed settings changed,
    /// until the returned value is cancelled or released.
    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> AnyCancellable
}

/// A validated managed value.
public enum ModuleManagedPolicyValue: Equatable, Sendable {
    case boolean(Bool)
    case enumeration(Int)
    case text(String)
    case list([String])
}

/// What the managed settings say about one key.
public struct ModuleManagedPolicyState: Equatable, Sendable {
    /// A value users cannot change.
    public var enforced: ModuleManagedPolicyValue?
    /// A default an administrator recommends. Users may change it.
    public var recommended: ModuleManagedPolicyValue?
    /// The managed settings could not be read, or the enforced value is
    /// invalid. What the key controls must then stay off.
    public var isBlocked: Bool

    public init(
        enforced: ModuleManagedPolicyValue? = nil,
        recommended: ModuleManagedPolicyValue? = nil,
        isBlocked: Bool = false
    ) {
        self.enforced = enforced
        self.recommended = recommended
        self.isBlocked = isBlocked
    }

    /// The enforced value, else the user's choice, else the recommendation,
    /// else `default`. Check `isBlocked` first.
    public func booleanValue(default defaultValue: Bool, userPreference: Bool? = nil) -> Bool {
        if case .boolean(let value) = enforced { return value }
        if let userPreference { return userPreference }
        if case .boolean(let value) = recommended { return value }
        return defaultValue
    }
}
