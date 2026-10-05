#if APPSTORE
import AppKit

/// Keeps one running TypeWhisper per bundle identifier.
///
/// LSMultipleInstancesProhibited would also block ApplicationRelauncher, which
/// starts the new instance before the old one quits. The old instance therefore
/// marks the relaunch in its defaults (launch arguments do not reach the new
/// sandboxed instance), and the new one waits for it instead of handing over.
enum AppStoreSingleInstance {
    private static let relaunchRequestedKey = "appStore.relaunchRequestedAt"

    static func markRelaunch() {
        UserDefaults.standard.set(Date(), forKey: relaunchRequestedKey)
    }

    private static func consumeRelaunchMark() -> Bool {
        let defaults = UserDefaults.standard
        guard let requestedAt = defaults.object(forKey: relaunchRequestedKey) as? Date else { return false }
        defaults.removeObject(forKey: relaunchRequestedKey)
        return Date().timeIntervalSince(requestedAt) < 30
    }

    static func enforce() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        func otherInstances() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        }

        guard !otherInstances().isEmpty else { return }

        if consumeRelaunchMark() {
            let deadline = Date().addingTimeInterval(10)
            while !otherInstances().isEmpty, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            return
        }

        otherInstances().first?.activate()
        exit(0)
    }
}
#endif
