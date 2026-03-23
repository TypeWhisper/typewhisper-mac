#if !APPSTORE
@preconcurrency import Sparkle
#endif

struct UpdateChecker: Sendable {
    let canCheckForUpdates: @Sendable () -> Bool
    let checkForUpdates: @Sendable () -> Void
    let resetUpdateCycleAfterSettingsChange: @Sendable () -> Void

    #if !APPSTORE
    static func sparkle(_ updater: SPUUpdater) -> UpdateChecker {
        nonisolated(unsafe) let updater = updater
        return UpdateChecker(
            canCheckForUpdates: { updater.canCheckForUpdates },
            checkForUpdates: { updater.checkForUpdates() },
            resetUpdateCycleAfterSettingsChange: { updater.resetUpdateCycleAfterShortDelay() }
        )
    }
    #endif

    nonisolated(unsafe) static var shared: UpdateChecker?
}
