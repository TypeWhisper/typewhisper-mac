import AppKit
import Foundation
import os
import Security
import ServiceManagement
import UserNotifications

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

    /// Frees the license and supporter activation slots on Polar so they can
    /// be used on another Mac. Failures are ignored; the local wipe proceeds.
    static func releaseLicenseActivations(_ licenseService: LicenseService) async {
        await licenseService.deactivateLicense()
        await licenseService.deactivateSupporterLicense()
    }

    /// Deletes all data, then terminates the process immediately.
    static func eraseAllAndQuit() -> Never {
        let failures = eraseAll(locations: .current())
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = localizedAppText(
                "Some data could not be deleted",
                de: "Einige Daten konnten nicht gelöscht werden"
            )
            alert.informativeText = failures
                .map { "\($0.item): \($0.message)" }
                .joined(separator: "\n")
            alert.runModal()
        }
        exit(0)
    }

    @discardableResult
    static func eraseAll(
        locations: UserDataLocations,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        deleteKeychainItems: () throws -> Void = UserDataEraser.deleteAppKeychainItems,
        resetSystemRegistrations: () -> Void = UserDataEraser.resetSystemRegistrations
    ) -> [Failure] {
        var failures: [Failure] = []

        do {
            try deleteKeychainItems()
        } catch {
            failures.append(Failure(item: "Keychain", message: error.localizedDescription))
        }

        resetSystemRegistrations()

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
        userDefaults.synchronize()

        for failure in failures {
            logger.error("Failed to delete \(failure.item, privacy: .public): \(failure.message, privacy: .public)")
        }
        return failures
    }

    nonisolated static func deleteAppKeychainItems() throws {
        // An empty prefix matches every item under `AppConstants.keychainServicePrefix`:
        // plugin secrets, the local API token and both license items.
        try KeychainService.deleteAll(withServicePrefix: "")

        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.premiumAccountKeychainService,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    nonisolated static func resetSystemRegistrations() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
    }
}
