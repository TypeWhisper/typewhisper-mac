import Combine

/// Reports whether Premium features are available and when that changes.
@MainActor
public protocol PremiumAccessReading: AnyObject {
    /// True with a commercial license or a Premium account.
    var hasPremiumAccess: Bool { get }

    /// Calls `handler` on the main actor with the new state whenever it
    /// changes, until the returned value is cancelled or released.
    func observeChanges(_ handler: @escaping @MainActor (Bool) -> Void) -> AnyCancellable

    /// Opens the settings where the user gets or manages Premium access.
    func showPremiumAccess()
}
