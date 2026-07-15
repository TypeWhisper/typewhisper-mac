import Sparkle

@MainActor
struct UpdateChecker {
    let canCheckForUpdates: () -> Bool
    let checkForUpdates: () -> Void
    let resetUpdateCycleAfterSettingsChange: () -> Void

    static func sparkle(_ updater: SPUUpdater) -> UpdateChecker {
        return UpdateChecker(
            canCheckForUpdates: { updater.canCheckForUpdates },
            checkForUpdates: { updater.checkForUpdates() },
            resetUpdateCycleAfterSettingsChange: { updater.resetUpdateCycleAfterShortDelay() }
        )
    }

    static var shared: UpdateChecker?
}
