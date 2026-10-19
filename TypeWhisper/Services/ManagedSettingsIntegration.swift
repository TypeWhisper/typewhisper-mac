import Combine
import Foundation

/// Applies the update policy to Sparkle and to the update controls in Settings.
///
/// The coordinator never writes the effective channel into preferences: the user's own channel stays
/// in `updateChannel` and applies again once the policy is removed.
@MainActor
final class ManagedUpdateCoordinator: ObservableObject {
    typealias Channel = AppConstants.ReleaseChannel

    @Published private(set) var policy: ManagedUpdatePolicy
    /// A version Sparkle found that the policy keeps from installing.
    @Published private(set) var announcedVersion: String?
    /// Called on the main actor with the previous and the new policy.
    var onPolicyChange: ((ManagedUpdatePolicy, ManagedUpdatePolicy) -> Void)?

    private let defaults: UserDefaults
    private let bundledChannel: Channel
    private var subscription: AnyCancellable?

    init(
        policyService: ManagedPolicyService,
        defaults: UserDefaults = .standard,
        bundledChannel: Channel = AppConstants.releaseChannel
    ) {
        self.defaults = defaults
        self.bundledChannel = bundledChannel
        policy = ManagedUpdatePolicy(snapshot: policyService.current)
        subscription = policyService.$current
            .dropFirst()
            .sink { [weak self] snapshot in
                self?.update(ManagedUpdatePolicy(snapshot: snapshot))
            }
    }

    /// The channel the user chose in Settings, or nil when they never chose one.
    var explicitChannel: Channel? {
        defaults.string(forKey: UserDefaultsKeys.updateChannel).flatMap(Channel.init(rawValue:))
    }

    var effectiveChannel: ResolvedManagedSetting<Channel> {
        policy.effectiveChannel(explicitChoice: explicitChannel, bundled: bundledChannel)
    }

    var checkRefusal: String? {
        policy.checkRefusal(on: effectiveChannel.value)
    }

    /// Throws the refusal when the policy does not allow an update check.
    func authorizeCheck() throws {
        if let refusal = checkRefusal {
            throw Self.refusalError(refusal)
        }
    }

    /// Throws the refusal when the policy does not allow downloading or installing `version`. Re-evaluates
    /// the current policy, so a policy that changed during the check still applies.
    func authorizeUpdate(version: String, userInitiated: Bool, downloadsAutomatically: Bool) throws {
        let channel = effectiveChannel.value
        guard let refusal = policy.installRefusal(
            on: channel,
            userInitiated: userInitiated,
            downloadsAutomatically: downloadsAutomatically
        ) else { return }
        if policy.checkRefusal(on: channel) == nil {
            announcedVersion = version
        }
        throw Self.refusalError(refusal)
    }

    private func update(_ newPolicy: ManagedUpdatePolicy) {
        guard newPolicy != policy else { return }
        let previous = policy
        policy = newPolicy
        // A version found under the previous policy may no longer apply.
        announcedVersion = nil
        onPolicyChange?(previous, newPolicy)
    }

    static func refusalError(_ message: String) -> NSError {
        NSError(
            domain: "com.typewhisper.managed-updates",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

extension ManagedSetupReadiness {
    /// The prerequisites the setup wizard checks, read from the running app.
    @MainActor
    static func current(container: ServiceContainer = .shared) -> ManagedSetupReadiness {
        let modelManager = container.modelManagerService
        let engineReady = modelManager.selectedProviderId
            .flatMap { PluginManager.shared?.transcriptionEngine(for: $0) }
            .map { modelManager.canPrepareForTranscription($0) } ?? false
        let hotkeyConfigured = [HotkeySlotType.hybrid, .pushToTalk, .toggle]
            .contains { !DictationSettingsHandler.loadHotkeys(for: $0).isEmpty }
        #if APPSTORE
        // The App Store edition falls back to the clipboard without PostEvent access.
        let accessibilityGranted = true
        #else
        let accessibilityGranted = !container.dictationViewModel.needsAccessibilityPermission
        #endif
        return ManagedSetupReadiness(
            engineReady: engineReady,
            microphoneGranted: !container.dictationViewModel.needsMicPermission,
            accessibilityGranted: accessibilityGranted,
            hotkeyConfigured: hotkeyConfigured
        )
    }
}

/// The launch-time decisions that depend on managed settings.
@MainActor
enum ManagedLaunchGate {
    /// Setup that has not been completed opens unless `SkipOnboardingWhenReady` keeps it closed.
    static var isSetupWizardRequired: Bool {
        guard HomeViewModel.shared.showSetupWizard else { return false }
        return !ManagedOnboardingPolicy.skipsSetup(
            ServiceContainer.shared.managedPolicyService.current,
            readiness: .current()
        )
    }

    static var suppressesOptionalPrompts: Bool {
        ManagedPromptPolicy.suppressesOptionalPrompts(ServiceContainer.shared.managedPolicyService.current)
    }
}
