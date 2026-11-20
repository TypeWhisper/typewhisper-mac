import Combine

/// Reports whether Premium features are available and when that changes.
///
/// This is what the host shows. A module that gates a feature can also check
/// the signed account entitlement itself.
@MainActor
public protocol PremiumAccessReading: AnyObject {
    /// True with a commercial license or a Premium account.
    var hasPremiumAccess: Bool { get }

    /// Whether the current access meets `requirement`. Since ModuleKit 2.3.
    func meets(_ requirement: ModulePremiumRequirement) -> Bool

    /// The Premium account entitlement the host verified, exactly as the
    /// server signed it: the claims as JSON and their P-256 signature (SHA-256,
    /// raw 64 bytes), both base64url without padding, joined by a dot. Nil while
    /// no account is signed in or it holds no entitlement. Since ModuleKit 2.3.
    ///
    /// The claims include `status`, `tier`, `source`, `isLifetime`,
    /// `expiresAt`, `deviceLimit` and `verifiedAt`; newer servers add more. A
    /// module verifies the signature with the key it trusts and reads the
    /// claims from the signed bytes. A commercial license has no such
    /// envelope; `meets(.commercial)` reports it.
    var signedAccountEntitlement: String? { get }

    /// Calls `handler` on the main actor with `hasPremiumAccess` whenever the
    /// access, the kind of access or `signedAccountEntitlement` changes, until
    /// the returned value is cancelled or released.
    func observeChanges(_ handler: @escaping @MainActor (Bool) -> Void) -> AnyCancellable

    /// Opens the settings where the user gets or manages Premium access.
    func showPremiumAccess()
}

public extension PremiumAccessReading {
    /// Hosts before ModuleKit 2.3 only know the combined access.
    func meets(_ requirement: ModulePremiumRequirement) -> Bool {
        requirement == .commercialOrPremium && hasPremiumAccess
    }

    /// Hosts before ModuleKit 2.3 pass no envelope.
    var signedAccountEntitlement: String? { nil }
}

/// The kind of Premium access a module feature needs.
public enum ModulePremiumRequirement: Hashable, Sendable {
    /// A commercial license or a Premium account.
    case commercialOrPremium
    /// A commercial license.
    case commercial
    /// A Premium account.
    case premiumAccount
}
