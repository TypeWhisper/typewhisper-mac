#if !APPSTORE
import Sparkle
#endif

@MainActor
struct UpdateChecker {
    let canCheckForUpdates: () -> Bool
    let checkForUpdates: () -> Void
    let resetUpdateCycleAfterSettingsChange: () -> Void

    #if !APPSTORE
    static func sparkle(_ updater: SPUUpdater) -> UpdateChecker {
        return UpdateChecker(
            canCheckForUpdates: { updater.canCheckForUpdates },
            checkForUpdates: { updater.checkForUpdates() },
            resetUpdateCycleAfterSettingsChange: { updater.resetUpdateCycleAfterShortDelay() }
        )
    }
    #endif

    static var shared: UpdateChecker?
}
