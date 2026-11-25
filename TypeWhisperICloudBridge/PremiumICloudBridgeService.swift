import Foundation
import OSLog

final class PremiumICloudBridgeService: NSObject, PremiumICloudBridgeXPCProtocol {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-icloud-bridge",
        category: "ICloudBridge"
    )
    private let operationLock = NSLock()

    func synchronize(reply: @escaping (Data) -> Void) {
        reply(perform("synchronize") { roots in
            let report = try PremiumICloudBridgeFileMirror.synchronize(
                localRoot: roots.local,
                remoteRoot: roots.remote
            )
            if report.iCloudStorageFull {
                Self.logger.notice("iCloud refuses uploads because its storage is full")
            }
            return report
        })
    }

    func deleteRemotePackage(reply: @escaping (Data) -> Void) {
        reply(perform("deleteRemotePackage") { roots in
            try PremiumICloudBridgeFileMirror.deletePackages(
                localRoot: roots.local,
                remoteRoot: roots.remote
            )
            return PremiumICloudBridgeReport()
        })
    }

    /// Removes the record from the mirror and from iCloud; the mirror would
    /// otherwise copy it back on the next pass.
    func removeDevice(_ deviceID: String, reply: @escaping (Data) -> Void) {
        reply(perform("removeDevice") { roots in
            try PremiumSyncDeviceRemoval.removeRecords(
                of: deviceID,
                inPackages: [roots.local, roots.remote].map {
                    $0.appendingPathComponent(
                        PremiumICloudBridgeConstants.packageDirectoryName,
                        isDirectory: true
                    )
                }
            )
            return PremiumICloudBridgeReport()
        })
    }

    /// Runs one request at a time and answers with an encoded `PremiumICloudBridgeReply`.
    /// Failures are logged with their error codes, which the app does not show for every cause.
    private func perform(
        _ request: String,
        _ body: ((local: URL, remote: URL)) throws -> PremiumICloudBridgeReport
    ) -> Data {
        operationLock.withLock {
            do {
                return PremiumICloudBridgeReply(report: try body(bridgeRoots())).encoded()
            } catch {
                let failure = PremiumICloudBridgeError.classify(error)
                Self.logger.error(
                    "\(request, privacy: .public) failed: \(PremiumICloudBridgeError.technicalSummary(of: error), privacy: .public)"
                )
                return PremiumICloudBridgeReply(failure: failure).encoded()
            }
        }
    }

    private func bridgeRoots() throws -> (local: URL, remote: URL) {
        guard let local = PremiumICloudBridgeConstants.localRootURL() else {
            throw PremiumICloudBridgeError.appGroupUnavailable
        }
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier:
                PremiumICloudBridgeConstants.containerIdentifier()
        ) else {
            throw PremiumICloudBridgeError.iCloudUnavailable
        }
        return (
            local,
            container.appendingPathComponent("Documents", isDirectory: true)
        )
    }
}

final class PremiumICloudBridgeListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = PremiumICloudBridgeService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: PremiumICloudBridgeXPCProtocol.self
        )
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}
