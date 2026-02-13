@preconcurrency import Sparkle

struct UpdateChecker: Sendable {
    let canCheckForUpdates: @Sendable () -> Bool
    let checkForUpdates: @Sendable () -> Void

    static func sparkle(_ updater: SPUUpdater) -> UpdateChecker {
        nonisolated(unsafe) let updater = updater
        return UpdateChecker(
            canCheckForUpdates: { updater.canCheckForUpdates },
            checkForUpdates: { updater.checkForUpdates() }
        )
    }

    nonisolated(unsafe) static var shared: UpdateChecker?
}
