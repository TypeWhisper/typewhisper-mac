import Foundation
import OSLog
import Security

final class PremiumICloudBridgeService: NSObject, PremiumICloudBridgeXPCProtocol {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-icloud-bridge",
        category: "ICloudBridge"
    )
    private let operationLock = NSLock()
    /// Separate from `operationLock`: a long mirror pass must not hold up the app, which
    /// waits for key changes synchronously.
    private let apiKeyLock = NSLock()
    private let apiKeyKeychain = SystemSharedAPIKeyKeychain()

    func sharedAPIKeys(reply: @escaping (Data) -> Void) {
        reply(performAPIKeyRequest("sharedAPIKeys") {
            try apiKeyKeychain.readAll()
        })
    }

    func setSharedAPIKey(
        _ account: String,
        value: Data,
        displayName: String,
        reply: @escaping (Data) -> Void
    ) {
        reply(performAPIKeyRequest("setSharedAPIKey") {
            try apiKeyKeychain.write(value, account: account, displayName: displayName)
            return [:]
        })
    }

    func deleteSharedAPIKey(_ account: String, reply: @escaping (Data) -> Void) {
        reply(performAPIKeyRequest("deleteSharedAPIKey") {
            try apiKeyKeychain.delete(account: account)
            return [:]
        })
    }

    /// Logs the request name and a status code, never an account's value.
    private func performAPIKeyRequest(
        _ request: String,
        _ body: () throws -> [String: SharedAPIKeyStoredItem]
    ) -> Data {
        apiKeyLock.withLock {
            do {
                return SharedAPIKeyBridgeReply(items: try body()).encoded()
            } catch {
                let failure = (error as? SharedAPIKeyStoreError) ?? .keychain(errSecInternalError)
                Self.logger.error(
                    "\(request, privacy: .public) failed: \(failure.technicalSummary, privacy: .public)"
                )
                return SharedAPIKeyBridgeReply(failure: failure).encoded()
            }
        }
    }

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
    private let clientRequirement = PremiumICloudBridgeClientRequirement.make()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Defense in depth on top of the bundle-private service: only the TypeWhisper app
        // that embeds this bridge, signed by the same team, may call it.
        if let clientRequirement {
            newConnection.setCodeSigningRequirement(clientRequirement)
        }
        newConnection.exportedInterface = NSXPCInterface(
            with: PremiumICloudBridgeXPCProtocol.self
        )
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

/// The code signing requirement a caller of the bridge must meet: the bundle identifier of the
/// app that embeds the bridge and the bridge's own team.
enum PremiumICloudBridgeClientRequirement {
    /// nil when the bridge is not signed by a team, as in local builds of contributors; such a
    /// bridge cannot use the shared keychain group either.
    static func make(bridgeBundle: Bundle = .main) -> String? {
        guard let hostIdentifier = hostAppIdentifier(bridgeBundleURL: bridgeBundle.bundleURL),
              let teamIdentifier = ownTeamIdentifier() else {
            return nil
        }
        return requirement(hostIdentifier: hostIdentifier, teamIdentifier: teamIdentifier)
    }

    static func requirement(hostIdentifier: String, teamIdentifier: String) -> String? {
        guard isPlainIdentifier(hostIdentifier), isPlainIdentifier(teamIdentifier) else { return nil }
        return "anchor apple generic and identifier \"\(hostIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// `TypeWhisper.app/Contents/XPCServices/TypeWhisperICloudBridge.xpc` → the app's identifier.
    static func hostAppIdentifier(bridgeBundleURL: URL) -> String? {
        let hostURL = bridgeBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return Bundle(url: hostURL)?.bundleIdentifier
    }

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let information = information as? [String: Any] else {
            return nil
        }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func isPlainIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }
}
