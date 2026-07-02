import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import IOKit

struct SecureInputDiagnostics: Encodable, Equatable, Sendable {
    let isActive: Bool
    let carbonSecureInputEnabled: Bool
    let primarySource: String?
    let primaryPID: Int32?
    let primaryAppName: String?
    let primaryBundleIdentifier: String?
    let primaryExecutablePath: String?
    let ioRegistryPID: Int32?
    let currentSessionPID: Int32?

    var logDescription: String {
        guard isActive else {
            let stalePID = ioRegistryPID.map(String.init) ?? "none"
            return "inactive(carbon=\(carbonSecureInputEnabled), ioRegistryPID=\(stalePID))"
        }

        let pid = primaryPID.map(String.init) ?? "unknown"
        let app = primaryAppName ?? "unknown"
        let source = primarySource ?? "unknown"
        return "active(source=\(source), pid=\(pid), app=\(app), carbon=\(carbonSecureInputEnabled), ioRegistryPID=\(ioRegistryPID.map(String.init) ?? "none"), currentSessionPID=\(currentSessionPID.map(String.init) ?? "none"))"
    }

    var userFacingOwner: String {
        if let primaryAppName, let primaryPID {
            return "\(primaryAppName) (pid \(primaryPID))"
        }
        if let primaryAppName {
            return primaryAppName
        }
        if let primaryPID {
            return "pid \(primaryPID)"
        }
        return "another app"
    }
}

struct SecureInputProcessInfo: Equatable, Sendable {
    let pid: Int32
    let appName: String?
    let bundleIdentifier: String?
    let executablePath: String?
}

enum SecureInputDiagnosticsProvider {
    static func snapshot() -> SecureInputDiagnostics {
        snapshot(
            consoleUsers: copyConsoleUsers(),
            currentSessionPID: currentSessionSecureInputPID(),
            carbonSecureInputEnabled: IsSecureEventInputEnabled(),
            processResolver: resolveProcess
        )
    }

    static func snapshot(
        consoleUsers: NSArray?,
        currentSessionPID: Int32?,
        carbonSecureInputEnabled: Bool,
        processResolver: (Int32) -> SecureInputProcessInfo?
    ) -> SecureInputDiagnostics {
        let ioRegistryPID = secureInputPID(from: consoleUsers)
        var resolvedCandidate: (String, SecureInputProcessInfo)?
        if let ioRegistryPID, ioRegistryPID > 0 {
            if let process = processResolver(ioRegistryPID) {
                resolvedCandidate = ("ioRegistry", process)
            }
        } else if let currentSessionPID, currentSessionPID > 0,
                  let process = processResolver(currentSessionPID) {
            resolvedCandidate = ("currentSession", process)
        }

        let unresolvedPID = ioRegistryPID ?? currentSessionPID
        let isActive = carbonSecureInputEnabled

        return SecureInputDiagnostics(
            isActive: isActive,
            carbonSecureInputEnabled: carbonSecureInputEnabled,
            primarySource: resolvedCandidate?.0 ?? (isActive ? "unknown" : nil),
            primaryPID: resolvedCandidate?.1.pid ?? (isActive ? unresolvedPID : nil),
            primaryAppName: resolvedCandidate?.1.appName,
            primaryBundleIdentifier: resolvedCandidate?.1.bundleIdentifier,
            primaryExecutablePath: resolvedCandidate?.1.executablePath,
            ioRegistryPID: ioRegistryPID,
            currentSessionPID: currentSessionPID
        )
    }

    private static func copyConsoleUsers() -> NSArray? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }

        let value = IORegistryEntryCreateCFProperty(
            root,
            "IOConsoleUsers" as CFString,
            kCFAllocatorDefault,
            0
        )
        return value?.takeRetainedValue() as? NSArray
    }

    private static func secureInputPID(from consoleUsers: NSArray?) -> Int32? {
        guard let consoleUsers else { return nil }

        var fallbackPID: Int32?
        for case let session as NSDictionary in consoleUsers {
            guard let pid = int32Value(session["kCGSSessionSecureInputPID"]), pid > 0 else {
                continue
            }

            if fallbackPID == nil {
                fallbackPID = pid
            }

            if boolValue(session["kCGSessionOnConsoleKey"]) == true
                || boolValue(session["kCGSSessionOnConsoleKey"]) == true {
                return pid
            }
        }
        return fallbackPID
    }

    private static func currentSessionSecureInputPID() -> Int32? {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return nil }
        guard let pid = int32Value(session["kCGSSessionSecureInputPID"]), pid > 0 else { return nil }
        return pid
    }

    private static func resolveProcess(pid: Int32) -> SecureInputProcessInfo? {
        let processID = pid_t(pid)
        let app = NSRunningApplication(processIdentifier: processID)
        let executablePath = app?.executableURL?.path ?? executablePath(for: processID)
        guard app != nil || executablePath != nil else { return nil }

        return SecureInputProcessInfo(
            pid: pid,
            appName: app?.localizedName ?? executablePath.map { URL(fileURLWithPath: $0).lastPathComponent },
            bundleIdentifier: app?.bundleIdentifier,
            executablePath: executablePath
        )
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer.prefix(end).map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func int32Value(_ value: Any?) -> Int32? {
        switch value {
        case let number as NSNumber:
            number.int32Value
        case let value as Int:
            Int32(value)
        case let value as Int32:
            value
        default:
            nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber:
            number.boolValue
        case let value as Bool:
            value
        default:
            nil
        }
    }
}
