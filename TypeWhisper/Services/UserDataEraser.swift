import Foundation
import os
import Security
import ServiceManagement
import UserNotifications
import WidgetKit

/// Removes everything TypeWhisper stores on this Mac: Keychain items (API
/// keys, license, local API token, premium account token), the Application
/// Support folder including plugins and downloaded models, App Group files,
/// caches, and all preferences. Afterwards the app must quit without running
/// `applicationWillTerminate`, which would flush pending history and usage
/// writes into the freshly emptied folders.
///
/// Remote copies are left alone: the iCloud Drive package, a user-chosen cloud
/// folder, and other devices keep their data.
@MainActor
enum UserDataEraser {
    struct Failure: Equatable, Sendable {
        let item: String
        let message: String
    }

    private static let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "UserDataEraser")

    /// Stops everything that could write user data while it is being deleted,
    /// then frees remote activation slots. Returns failures to report together
    /// with those of `eraseAll`.
    static func prepareForErase(
        apiServer: APIServerViewModel,
        container: ServiceContainer
    ) async -> [Failure] {
        apiServer.stopServerAndCancelActiveRequests()
        let failures = await discardActiveRecording(container.audioRecorderService)

        // The iCloud bridge copies the remote package into the local mirror
        // from its own XPC process; let a running sync finish first.
        await waitUntil { !container.cloudFolderSyncController.isSyncing }
        container.cloudFolderSyncController.deactivate()

        await releaseRemoteActivations(
            licenseService: container.licenseService,
            premiumAccountService: container.premiumAccountService
        )
        return failures
    }

    /// Frees the license and supporter activation slots on Polar and detaches
    /// this Mac from the premium account, so the slots can be used on another
    /// Mac. Failures are ignored; the local wipe proceeds.
    static func releaseRemoteActivations(
        licenseService: LicenseService,
        premiumAccountService: PremiumAccountService
    ) async {
        await licenseService.deactivateLicense()
        await licenseService.deactivateSupporterLicense()
        // `signOutFromAccount()` is a no-op while another account operation runs.
        await waitUntil { !premiumAccountService.isWorking }
        if premiumAccountService.isSignedIn {
            await premiumAccountService.signOutFromAccount()
        }
    }

    private static func waitUntil(
        timeout: Duration = .seconds(30),
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Stops a running recorder session without finalizing it and removes its
    /// temporary microphone and system audio tracks, which live outside the
    /// erased folders. The recorder's output folder is left alone.
    static func discardActiveRecording(_ recorderService: AudioRecorderService) async -> [Failure] {
        guard recorderService.isRecording else { return [] }
        let stoppedRecording = await recorderService.stopCapture()
        var failures: [Failure] = []
        for url in [stoppedRecording.micTempURL, stoppedRecording.systemTempURL].compactMap({ $0 }) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                failures.append(Failure(item: url.path, message: error.localizedDescription))
            }
        }
        return failures
    }

    /// Deletes all data, then terminates the process immediately.
    static func eraseAllAndQuit(earlierFailures: [Failure] = []) -> Never {
        let failures = earlierFailures + eraseAll(locations: .current())
        // Widget timelines cache recent transcript previews.
        WidgetCenter.shared.reloadAllTimelines()
        if !failures.isEmpty {
            presentFailuresAfterExit(failures)
        }
        exit(0)
    }

    /// Shows the failures from a separate `osascript` process. A modal alert
    /// in this process would keep the app's timers and services running after
    /// the wipe, and they could write the deleted data back.
    private static func presentFailuresAfterExit(_ failures: [Failure]) {
        let title = localizedAppText(
            "Some TypeWhisper data could not be deleted",
            de: "Einige TypeWhisper-Daten konnten nicht gelöscht werden"
        )
        let message = failures
            .map { "\($0.item): \($0.message)" }
            .joined(separator: "\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "display alert (item 1 of argv) message (item 2 of argv) as warning",
            "-e", "end run",
            title, message,
        ]
        try? process.run()
    }

    @discardableResult
    static func eraseAll(
        locations: UserDataLocations,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        deleteKeychainItems: () throws -> Void = UserDataEraser.deleteAppKeychainItems,
        resetSystemRegistrations: () -> [Failure] = UserDataEraser.resetSystemRegistrations
    ) -> [Failure] {
        var failures: [Failure] = []

        do {
            try deleteKeychainItems()
        } catch {
            failures.append(Failure(item: "Keychain", message: error.localizedDescription))
        }

        failures += resetSystemRegistrations()

        for url in [locations.appSupportDirectory] + locations.auxiliaryItems {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failures.append(Failure(item: url.path, message: error.localizedDescription))
            }
        }

        // Last, so nothing above can write a preference back.
        userDefaults.removePersistentDomain(forName: locations.preferencesDomain)
        if !userDefaults.synchronize() {
            failures.append(Failure(
                item: locations.preferencesDomain,
                message: localizedAppText(
                    "The preferences could not be saved after deleting them.",
                    de: "Die Einstellungen konnten nach dem Löschen nicht gespeichert werden."
                )
            ))
        }

        for failure in failures {
            logger.error("Failed to delete \(failure.item, privacy: .public): \(failure.message, privacy: .public)")
        }
        return failures
    }

    nonisolated static func deleteAppKeychainItems() throws {
        // An empty prefix matches every item under `AppConstants.keychainServicePrefix`:
        // plugin secrets, the local API token and both license items. A failure
        // there must not skip the premium token below.
        var firstError: Error?
        do {
            try KeychainService.deleteAll(withServicePrefix: "")
        } catch {
            firstError = error
        }

        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.premiumAccountKeychainService,
        ] as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound, firstError == nil {
            firstError = KeychainError.deleteFailed(status)
        }
        if let firstError { throw firstError }
    }

    nonisolated static func resetSystemRegistrations() -> [Failure] {
        var failures: [Failure] = []
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                failures.append(Failure(item: "Launch at Login", message: error.localizedDescription))
            }
        default:
            break
        }
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
        return failures
    }
}
