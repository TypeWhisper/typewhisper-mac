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

    /// Shows one of the module's panels (`ModuleContributions.panels`) and makes it key.
    func showPanel(withID id: String)
    /// Hides a panel. Its content stays as it was until the panel shows again.
    func hidePanel(withID id: String)
    /// Shows a hidden panel and hides a visible one.
    func togglePanel(withID id: String)
    func isPanelVisible(withID id: String) -> Bool
}
