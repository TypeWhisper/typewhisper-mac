import Foundation
import ServiceManagement

/// What first-time setup needs before `SkipOnboardingWhenReady` may keep it closed.
struct ManagedSetupReadiness: Equatable, Sendable {
    var engineReady: Bool
    var microphoneGranted: Bool
    var accessibilityGranted: Bool
    var hotkeyConfigured: Bool

    var isReady: Bool {
        engineReady && microphoneGranted && accessibilityGranted && hotkeyConfigured
    }
}

/// `SkipOnboardingWhenReady`: keeps setup closed when its prerequisites are met. Nothing is marked
/// as completed, so setup returns once a prerequisite goes missing or the policy is removed.
enum ManagedOnboardingPolicy {
    /// The setup steps that check a prerequisite, by `SetupWizardStep` raw value.
    enum Step: Int {
        case permissions = 1
        case hotkey = 2
        case engine = 3
    }

    static func isEnforced(_ snapshot: ManagedPolicySnapshot) -> Bool {
        !snapshot.isBlocked(ManagedPolicyKeys.skipOnboardingWhenReady)
            && snapshot.enforced(ManagedPolicyKeys.skipOnboardingWhenReady)?.booleanValue == true
    }

    static func skipsSetup(_ snapshot: ManagedPolicySnapshot, readiness: ManagedSetupReadiness) -> Bool {
        isEnforced(snapshot) && readiness.isReady
    }

    /// Microphone consent cannot be granted by a deployment, so a first launch is rarely ready. Under
    /// the policy, setup that has not started yet opens at the first missing prerequisite instead of
    /// the welcome step. Progress the user already made is kept.
    static func initialStep(
        _ snapshot: ManagedPolicySnapshot,
        savedStep: Int,
        readiness: ManagedSetupReadiness
    ) -> Int? {
        guard isEnforced(snapshot), savedStep == 0 else { return nil }
        if !readiness.microphoneGranted || !readiness.accessibilityGranted { return Step.permissions.rawValue }
        if !readiness.hotkeyConfigured { return Step.hotkey.rawValue }
        if !readiness.engineReady { return Step.engine.rawValue }
        return nil
    }
}

/// The app's own login item.
@MainActor
protocol LoginItemRegistering: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemRegistering {}

/// Applies `LaunchAtLogin` to the app's login item and owns the Launch at Login setting.
///
/// An enforced value changes the registration and locks the setting; the state before enforcement
/// is retained and restored once the value is removed. A recommendation applies once, to a profile
/// that has not completed setup and has no choice of its own. macOS can still disable the item in
/// System Settings unless the deployment manages login items.
@MainActor
final class LaunchAtLoginPolicyController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var requiresApproval: Bool
    /// The setting follows an enforced value or waits for a readable policy.
    @Published private(set) var isLocked = false
    @Published private(set) var lastErrorDescription: String?

    private let loginItem: any LoginItemRegistering
    private let defaults: UserDefaults

    /// - Parameter snapshot: The policy at creation. It sets the lock state without touching the login
    ///   item; `apply(_:setupCompleted:)` makes the changes.
    init(
        loginItem: any LoginItemRegistering = SMAppService.mainApp,
        defaults: UserDefaults = .standard,
        snapshot: ManagedPolicySnapshot = .empty
    ) {
        self.loginItem = loginItem
        self.defaults = defaults
        isEnabled = loginItem.status == .enabled
        requiresApproval = loginItem.status == .requiresApproval
        isLocked = Self.isLocked(snapshot)
    }

    /// Whether the policy decides the setting: an enforced value, or a policy that cannot be read.
    static func isLocked(_ snapshot: ManagedPolicySnapshot) -> Bool {
        let key = ManagedPolicyKeys.launchAtLogin
        return snapshot.isBlocked(key) || snapshot.isEnforced(key)
    }

    func apply(_ snapshot: ManagedPolicySnapshot, setupCompleted: Bool) {
        defer { refreshStatus() }
        let key = ManagedPolicyKeys.launchAtLogin
        isLocked = Self.isLocked(snapshot)
        if snapshot.isBlocked(key) {
            return
        }

        if let enforced = snapshot.enforced(key)?.booleanValue {
            if defaults.object(forKey: UserDefaultsKeys.managedLaunchAtLoginRetainedState) == nil {
                // Retain before changing anything, so a failed change can still be undone on removal.
                defaults.set(isRegistered, forKey: UserDefaultsKeys.managedLaunchAtLoginRetainedState)
            }
            setRegistration(enforced)
            return
        }

        if let retained = defaults.object(forKey: UserDefaultsKeys.managedLaunchAtLoginRetainedState) as? Bool {
            if setRegistration(retained) {
                defaults.removeObject(forKey: UserDefaultsKeys.managedLaunchAtLoginRetainedState)
            }
            return
        }

        if let recommended = snapshot.recommended(key)?.booleanValue,
           !setupCompleted,
           defaults.object(forKey: UserDefaultsKeys.launchAtLoginUserChoice) == nil,
           !defaults.bool(forKey: UserDefaultsKeys.managedLaunchAtLoginRecommendationApplied) {
            defaults.set(true, forKey: UserDefaultsKeys.managedLaunchAtLoginRecommendationApplied)
            setRegistration(recommended)
        }
    }

    /// The Launch at Login toggle. Refused while the setting is locked.
    func setUserChoice(_ enabled: Bool) {
        defer { refreshStatus() }
        guard !isLocked else { return }
        defaults.set(enabled, forKey: UserDefaultsKeys.launchAtLoginUserChoice)
        setRegistration(enabled)
    }

    func refreshStatus() {
        let status = loginItem.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    private var isRegistered: Bool {
        loginItem.status == .enabled || loginItem.status == .requiresApproval
    }

    @discardableResult
    private func setRegistration(_ enabled: Bool) -> Bool {
        guard enabled != isRegistered else {
            lastErrorDescription = nil
            return true
        }
        do {
            if enabled {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
            lastErrorDescription = nil
            return true
        } catch {
            lastErrorDescription = error.localizedDescription
            return false
        }
    }
}
