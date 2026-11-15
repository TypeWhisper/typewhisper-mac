/// What the app offers a module.
///
/// A capability is nil when the app does not provide it, for example because
/// the build or a managed policy leaves it out. Modules check before use.
@MainActor
public protocol ModuleHost: AnyObject {
    var historyReading: (any HistoryReading)? { get }
    var historySearching: (any HistorySearching)? { get }
    var languageModelAnswering: (any LanguageModelAnswering)? { get }
    var managedPolicyReading: (any ManagedPolicyReading)? { get }
    var premiumAccessReading: (any PremiumAccessReading)? { get }
    var userDataLifecycle: (any UserDataLifecycle)? { get }
}

// The requirements of each capability are added together with the app's
// implementation of it.

/// Reads history records and their changes.
@MainActor
public protocol HistoryReading: AnyObject {}

/// Searches the app's full-text index of history records.
@MainActor
public protocol HistorySearching: AnyObject {}

/// Sends a prompt to one of the app's language model providers.
@MainActor
public protocol LanguageModelAnswering: AnyObject {}

/// Reads the managed settings keys a module declares.
@MainActor
public protocol ManagedPolicyReading: AnyObject {}

/// Reports whether Premium features are available and when that changes.
@MainActor
public protocol PremiumAccessReading: AnyObject {}

/// Lets a module erase and export its own data with the user's data.
@MainActor
public protocol UserDataLifecycle: AnyObject {}
