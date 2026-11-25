#if APPSTORE
import Foundation

/// Automatic iCloud sync for the Mac App Store edition.
///
/// The direct-distribution app mirrors its sync package into iCloud through the
/// TypeWhisperICloudBridge XPC service, because only that helper carries the
/// iCloud entitlements. The App Store app holds the iCloud container itself, so
/// it runs the same mirror in process.
final class AppStoreICloudMirror: PremiumICloudBridging, @unchecked Sendable {
    /// Re-evaluated on every access: the user can sign in to iCloud or turn on
    /// iCloud Drive while TypeWhisper runs.
    var isAvailable: Bool {
        localFolderURL != nil && fileManager.ubiquityIdentityToken != nil
    }
    let localFolderURL: URL?

    private let containerIdentifier: String
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.typewhisper.appstore.icloud-mirror", qos: .utility)

    init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        containerIdentifier = PremiumICloudBridgeConstants.containerIdentifier(
            infoDictionary: bundle.infoDictionary
        )
        localFolderURL = PremiumICloudBridgeConstants.localRootURL(
            bundle: bundle,
            fileManager: fileManager
        )
    }

    @discardableResult
    func synchronize() async throws -> PremiumICloudBridgeReport {
        try await perform { local, remote in
            try PremiumICloudBridgeFileMirror.synchronize(localRoot: local, remoteRoot: remote)
        }
    }

    func deleteRemotePackage() async throws {
        try await perform { local, remote in
            try PremiumICloudBridgeFileMirror.deletePackages(localRoot: local, remoteRoot: remote)
            return PremiumICloudBridgeReport()
        }
    }

    /// Removes the record from the mirror and from iCloud; the mirror would
    /// otherwise copy it back on the next pass.
    func removeDevice(_ deviceID: String) async throws {
        try await perform { local, remote in
            try PremiumSyncDeviceRemoval.removeRecords(
                of: deviceID,
                inPackages: [local, remote].map {
                    $0.appendingPathComponent(
                        PremiumICloudBridgeConstants.packageDirectoryName,
                        isDirectory: true
                    )
                }
            )
            return PremiumICloudBridgeReport()
        }
    }

    /// Runs `operation` on a serial background queue: resolving the ubiquity
    /// container can block, and mirror passes must not overlap. Failures are
    /// reported as the cause the user can act on, as the helper does.
    @discardableResult
    private func perform(
        _ operation: @escaping @Sendable (URL, URL) throws -> PremiumICloudBridgeReport
    ) async throws -> PremiumICloudBridgeReport {
        guard let local = localFolderURL else {
            throw PremiumICloudBridgeError.appGroupUnavailable
        }
        guard isAvailable else {
            throw PremiumICloudBridgeError.iCloudUnavailable
        }
        let containerIdentifier = containerIdentifier
        let fileManager = fileManager
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<PremiumICloudBridgeReport, Error>) in
            queue.async {
                do {
                    guard let container = fileManager.url(
                        forUbiquityContainerIdentifier: containerIdentifier
                    ) else {
                        throw PremiumICloudBridgeError.iCloudUnavailable
                    }
                    continuation.resume(returning: try operation(
                        local,
                        container.appendingPathComponent("Documents", isDirectory: true)
                    ))
                } catch {
                    continuation.resume(throwing: PremiumICloudBridgeError.classify(error))
                }
            }
        }
    }
}
#endif
