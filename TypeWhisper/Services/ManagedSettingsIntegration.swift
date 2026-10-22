import Foundation

extension ManagedSetupReadiness {
    @MainActor
    static func current(container: ServiceContainer = .shared) -> ManagedSetupReadiness {
        let modelManager = container.modelManagerService
        let engineReady = modelManager.selectedProviderId
            .flatMap { PluginManager.shared?.transcriptionEngine(for: $0) }
            .map { modelManager.canPrepareForTranscription($0) } ?? false
        let hotkeyConfigured = [HotkeySlotType.hybrid, .pushToTalk, .toggle]
            .contains { !DictationSettingsHandler.loadHotkeys(for: $0).isEmpty }
        #if APPSTORE
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

@MainActor
enum ManagedLaunchGate {
    static var isSetupWizardRequired: Bool {
        guard HomeViewModel.shared.showSetupWizard else { return false }
        return !ManagedOnboardingPolicy.skipsSetup(
            ServiceContainer.shared.managedPolicyService.current,
            readiness: .current()
        )
    }
}
