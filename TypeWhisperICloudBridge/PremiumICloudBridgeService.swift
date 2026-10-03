import Foundation

final class PremiumICloudBridgeService: NSObject, PremiumICloudBridgeXPCProtocol {
    private let operationLock = NSLock()

    func synchronize(reply: @escaping (String?) -> Void) {
        reply(operationLock.withLock {
            do {
                let roots = try bridgeRoots()
                try PremiumICloudBridgeFileMirror.synchronize(
                    localRoot: roots.local,
                    remoteRoot: roots.remote
                )
                return nil
            } catch {
                return error.localizedDescription
            }
        })
    }

    func deleteRemotePackage(reply: @escaping (String?) -> Void) {
        reply(operationLock.withLock {
            do {
                let roots = try bridgeRoots()
                try PremiumICloudBridgeFileMirror.deletePackages(
                    localRoot: roots.local,
                    remoteRoot: roots.remote
                )
                return nil
            } catch {
                return error.localizedDescription
            }
        })
    }

    /// Removes the record from the mirror and from iCloud; the mirror would
    /// otherwise copy it back on the next pass.
    func removeDevice(_ deviceID: String, reply: @escaping (String?) -> Void) {
        reply(operationLock.withLock {
            do {
                let roots = try bridgeRoots()
                try PremiumSyncDeviceRemoval.removeRecords(
                    of: deviceID,
                    inPackages: [roots.local, roots.remote].map {
                        $0.appendingPathComponent(
                            PremiumICloudBridgeConstants.packageDirectoryName,
                            isDirectory: true
                        )
                    }
                )
                return nil
            } catch {
                return error.localizedDescription
            }
        })
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
