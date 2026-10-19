import Foundation
import ServiceManagement

/// `UpdateMode`: who installs app updates.
enum ManagedUpdateMode: Int, Sendable {
    /// No update checks, downloads or installations; the organization's deployment updates the app.
    case external = 0
    /// Checks and announces new versions but never installs them.
    case checkOnly = 1
    /// Installs only when the user starts it; nothing installs unattended.
    case userInitiated = 2
}

/// The update policy derived from one managed policy snapshot. Pure, so Sparkle callbacks, Settings
/// and tests evaluate the same rules.
struct ManagedUpdatePolicy: Equatable, Sendable {
    typealias Channel = AppConstants.ReleaseChannel

    var mode: ManagedUpdateMode?
    var enforcedChannel: Channel?
    var recommendedChannel: Channel?
    /// nil leaves every channel available; an empty set turns app updates off.
    var allowedChannels: Set<Channel>?
    /// The policy source is unreadable or an update key is invalid: updates wait until it is fixed.
    var isBlocked = false

    static let unmanaged = ManagedUpdatePolicy()

    init(
        mode: ManagedUpdateMode? = nil,
        enforcedChannel: Channel? = nil,
        recommendedChannel: Channel? = nil,
        allowedChannels: Set<Channel>? = nil,
        isBlocked: Bool = false
    ) {
        self.mode = mode
        self.enforcedChannel = enforcedChannel
        self.recommendedChannel = recommendedChannel
        self.allowedChannels = allowedChannels
        self.isBlocked = isBlocked
    }

    init(snapshot: ManagedPolicySnapshot) {
        mode = snapshot.enforced(ManagedPolicyKeys.updateMode)?.enumerationValue.flatMap(ManagedUpdateMode.init(rawValue:))
        enforcedChannel = snapshot.enforced(ManagedPolicyKeys.updateChannel)?.enumerationValue.flatMap(Self.channel(policyValue:))
        recommendedChannel = snapshot.recommended(ManagedPolicyKeys.updateChannel)?.enumerationValue.flatMap(Self.channel(policyValue:))
        allowedChannels = snapshot.enforced(ManagedPolicyKeys.allowedUpdateChannels)?.listItems
            .map { Set($0.compactMap(Self.channel(listEntry:))) }
        isBlocked = [ManagedPolicyKeys.updateMode, ManagedPolicyKeys.updateChannel, ManagedPolicyKeys.allowedUpdateChannels]
            .contains(where: snapshot.isBlocked)
    }

    /// `UpdateChannel` values shared with Windows: 0 = Stable, 1 = Daily, 2 = Release Candidate.
    static func channel(policyValue: Int) -> Channel? {
        switch policyValue {
        case 0: .stable
        case 1: .daily
        case 2: .releaseCandidate
        default: nil
        }
    }

    /// `AllowedUpdateChannels` entries: `stable`, `daily`, `release-candidate`. Anything else,
    /// such as `none`, matches no channel.
    static func channel(listEntry: String) -> Channel? {
        Channel(rawValue: listEntry.lowercased())
    }

    var isManaged: Bool {
        mode != nil || enforcedChannel != nil || recommendedChannel != nil || allowedChannels != nil || isBlocked
    }

    var isChannelLocked: Bool {
        enforcedChannel != nil || isBlocked
    }

    /// Enforced channel, then the user's explicit choice, then the recommendation, then the
    /// channel the app was built for.
    func effectiveChannel(explicitChoice: Channel?, bundled: Channel) -> ResolvedManagedSetting<Channel> {
        ManagedSettingResolver.resolve(
            applicationDefault: bundled,
            explicitUserPreference: explicitChoice,
            recommendedPolicy: recommendedChannel,
            enforcedPolicy: enforcedChannel
        )
    }

    /// The channels the picker offers. The current channel stays listed so the picker never shows
    /// an empty selection; checks on it are refused when it is not allowed.
    func selectableChannels(current: Channel) -> [Channel] {
        guard let allowedChannels else { return Channel.allCases }
        return Channel.allCases.filter { allowedChannels.contains($0) || $0 == current }
    }

    /// Why update checks on `channel` are refused, or nil when they may run.
    func checkRefusal(on channel: Channel) -> String? {
        if isBlocked {
            return String(localized: "App updates are paused until your organization's update settings can be applied.")
        }
        if mode == .external {
            return String(localized: "App updates are managed by your organization.")
        }
        if let allowedChannels {
            if allowedChannels.isEmpty {
                return String(localized: "Your organization has turned off app updates.")
            }
            if !allowedChannels.contains(channel) {
                return enforcedChannel == channel
                    ? String(localized: "Your organization's update channel is not one of its allowed channels, so app updates are off.")
                    : String(localized: "Your organization does not allow updates on this channel. Choose an allowed channel.")
            }
        }
        return nil
    }

    /// Why a found update must not be downloaded or installed, or nil when it may proceed.
    /// - Parameters:
    ///   - userInitiated: The user started this check.
    ///   - downloadsAutomatically: Sparkle would download and install the update unattended.
    func installRefusal(on channel: Channel, userInitiated: Bool, downloadsAutomatically: Bool) -> String? {
        if let refusal = checkRefusal(on: channel) {
            return refusal
        }
        switch mode {
        case .checkOnly:
            return String(localized: "A newer version is available. Your organization installs updates on this Mac.")
        case .userInitiated where !userInitiated && downloadsAutomatically:
            return String(localized: "A newer version is available. Choose Check for Updates to install it.")
        default:
            return nil
        }
    }

    /// Sparkle's question about automatic checks is the organization's decision once a mode applies.
    var suppressesAutomaticCheckPrompt: Bool {
        mode != nil || isBlocked || allowedChannels?.isEmpty == true
    }

    /// A conflict between enforced values, for the managed settings page. Technical English.
    var conflict: String? {
        guard let enforcedChannel, let allowedChannels, !allowedChannels.contains(enforcedChannel) else {
            return nil
        }
        return "UpdateChannel is not one of the AllowedUpdateChannels; app updates are off."
    }
}

/// Whether the organization keeps optional welcome and promotional prompts hidden.
enum ManagedPromptPolicy {
    /// Enforced and recommended values both apply; there is no user setting to compete with. While
    /// the source is unreadable the retained values keep applying.
    static func suppressesOptionalPrompts(_ snapshot: ManagedPolicySnapshot) -> Bool {
        snapshot.resolveBoolean(ManagedPolicyKeys.suppressOptionalPrompts, applicationDefault: false).value
    }
}

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
