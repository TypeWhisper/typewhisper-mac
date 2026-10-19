import AppKit
import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "ManagedPolicy")

/// Reads raw managed preferences without validating them. Implementations never write preferences.
protocol ManagedPolicySource: Sendable {
    /// Reads all managed values. Failures are reported in the result, not thrown.
    func read() -> ManagedPolicyReading
}

/// A source without managed values, used by test hosts so a profile installed for the development
/// app cannot change test results.
struct EmptyManagedPolicySource: ManagedPolicySource {
    func read() -> ManagedPolicyReading { .absent }
}

/// Reads the managed preferences of the app's own domain (`com.typewhisper.mac`,
/// `com.typewhisper.typewhisper-app` or their `.dev` variants).
///
/// Only values forced by a configuration profile count. A value written with `defaults write` is
/// user-writable and therefore reported as unmanaged instead of being applied.
struct ManagedPreferencesPolicySource: ManagedPolicySource {
    let applicationID: String

    init(applicationID: String = Bundle.main.bundleIdentifier ?? "com.typewhisper.mac") {
        self.applicationID = applicationID
    }

    func read() -> ManagedPolicyReading {
        let domain = applicationID as CFString
        CFPreferencesAppSynchronize(domain)

        let supportedKeys = Set(ManagedPolicyKeys.all.map(\.name) + [ManagedPolicyKeys.recommendedDictionary])
        var forcedValues: [String: ManagedPolicyRawValue] = [:]
        var unmanagedKeys: Set<String> = []

        for key in supportedKeys {
            guard let value = CFPreferencesCopyAppValue(key as CFString, domain) else { continue }
            if CFPreferencesAppValueIsForced(key as CFString, domain) {
                forcedValues[key] = ManagedPolicyRawValue(propertyList: value)
            } else {
                unmanagedKeys.insert(key)
            }
        }

        // Forced keys outside the catalog are reported so misspelled keys do not fail silently.
        // There is no API that lists forced keys, so check every key visible to the app and skip
        // keys an administrator forced for all applications.
        for key in Self.visibleKeys(applicationID: applicationID) where !supportedKeys.contains(key) {
            guard CFPreferencesAppValueIsForced(key as CFString, domain),
                  !CFPreferencesAppValueIsForced(key as CFString, kCFPreferencesAnyApplication),
                  let value = CFPreferencesCopyAppValue(key as CFString, domain) else { continue }
            forcedValues[key] = ManagedPolicyRawValue(propertyList: value)
        }

        return ManagedPolicyReading(forcedValues: forcedValues, unmanagedKeys: unmanagedKeys)
    }

    private static func visibleKeys(applicationID: String) -> Dictionary<String, Any>.Keys {
        if applicationID == Bundle.main.bundleIdentifier {
            return UserDefaults.standard.dictionaryRepresentation().keys
        }
        return (UserDefaults(suiteName: applicationID)?.dictionaryRepresentation() ?? [:]).keys
    }
}

/// Publishes validated policy snapshots from one source and keeps them fresh.
///
/// macOS has no documented notification for configuration profile changes, so the service re-reads
/// when the app becomes active, after wake, after a fast user switch back to this session, every
/// 30 seconds, and on explicit `refresh()`. A snapshot is published only when its content differs.
/// An unreadable source keeps the last values but marks them unreadable, which blocks managed
/// capabilities until the source can be read again.
@MainActor
final class ManagedPolicyService: ObservableObject {
    static let defaultFallbackRefreshInterval: Duration = .seconds(30)

    /// The latest published snapshot; `ManagedPolicySnapshot.empty` before the first read.
    @Published private(set) var current: ManagedPolicySnapshot = .empty

    private let source: any ManagedPolicySource
    private let fallbackTicks: () -> AsyncStream<Void>
    private let now: () -> Date
    private var fallbackRefreshTask: Task<Void, Never>?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// - Parameter fallbackTicks: Creates the stream that triggers the periodic re-read. Tests pass a
    ///   stream they control; the default ticks every 30 seconds.
    init(
        source: any ManagedPolicySource,
        fallbackTicks: @escaping () -> AsyncStream<Void> = {
            ManagedPolicyService.ticks(every: ManagedPolicyService.defaultFallbackRefreshInterval)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.fallbackTicks = fallbackTicks
        self.now = now
    }

    /// Reads the source now and publishes the result when it differs from the current snapshot.
    @discardableResult
    func refresh() -> ManagedPolicySnapshot {
        let previous = current
        var candidate = ManagedPolicyValidator.validate(source.read(), revision: previous.revision + 1, readAt: now())
        if candidate.status == .unreadable {
            candidate = candidate.retainingValues(from: previous)
        }
        // The first read is always published so revision and read time show that policy was consulted.
        if previous.revision > 0 && candidate.contentEquals(previous) {
            return previous
        }
        current = candidate
        logger.info(
            "Managed policy revision \(candidate.revision, privacy: .public): \(candidate.status.rawValue, privacy: .public), \(candidate.enforcedValues.count, privacy: .public) enforced, \(candidate.recommendedValues.count, privacy: .public) recommended, \(candidate.invalidEnforcedKeys.count, privacy: .public) invalid, \(candidate.issues.count, privacy: .public) issues"
        )
        return candidate
    }

    /// Follows app activation, wake, session switches and the fallback interval. Idempotent.
    func startMonitoring(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        guard fallbackRefreshTask == nil else { return }
        let triggers: [(NotificationCenter, Notification.Name)] = [
            (notificationCenter, NSApplication.didBecomeActiveNotification),
            (workspaceNotificationCenter, NSWorkspace.didWakeNotification),
            (workspaceNotificationCenter, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        for (center, name) in triggers {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            observers.append((center, token))
        }

        let ticks = fallbackTicks()
        fallbackRefreshTask = Task { [weak self] in
            for await _ in ticks {
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    func stopMonitoring() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
        fallbackRefreshTask?.cancel()
        fallbackRefreshTask = nil
    }

    /// A stream that yields once per interval until its consumer stops iterating.
    nonisolated static func ticks(every interval: Duration) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let timer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in timer.cancel() }
        }
    }
}

/// The policy section of the support diagnostics: key names, safe values and findings.
/// Sensitive values are reported as set, never with content.
struct ManagedPolicyDiagnostics: Encodable, Equatable {
    struct Value: Encodable, Equatable {
        let name: String
        let value: String?
        let items: [String]?
    }

    struct Issue: Encodable, Equatable {
        let key: String?
        let scope: String?
        let message: String
    }

    let status: String
    let revision: Int
    let readAt: Date?
    let enforced: [Value]
    let recommended: [Value]
    let invalidEnforced: [String]
    let issues: [Issue]

    init(snapshot: ManagedPolicySnapshot) {
        status = snapshot.status.rawValue
        revision = snapshot.revision
        readAt = snapshot.revision > 0 ? snapshot.readAt : nil
        enforced = Self.values(snapshot.enforcedValues)
        recommended = Self.values(snapshot.recommendedValues)
        invalidEnforced = snapshot.invalidEnforcedKeys.sorted()
        issues = snapshot.issues.map(Self.issue)
    }

    private static func values(_ values: [String: ManagedPolicyValue]) -> [Value] {
        values.keys.sorted().compactMap { name in
            guard let value = values[name] else { return nil }
            let sensitive = ManagedPolicyKeys.definition(named: name)?.sensitive == true
            switch value {
            case .boolean(let flag):
                return Value(name: name, value: flag ? "true" : "false", items: nil)
            case .enumeration(let number):
                return Value(name: name, value: String(number), items: nil)
            case .text(let text):
                return Value(name: name, value: sensitive ? "[set]" : identifier(text), items: nil)
            case .list(let items):
                return Value(name: name, value: nil, items: sensitive ? ["[set]"] : items.map(identifier))
            }
        }
    }

    // Findings name keys, never values. A finding about an unknown key carries that key, which comes
    // from outside the catalog and may be private text: only a technical identifier survives.
    private static func issue(_ issue: ManagedPolicyIssue) -> Issue {
        guard let key = issue.key,
              ManagedPolicyKeys.definition(named: key) == nil,
              key != ManagedPolicyKeys.recommendedDictionary else {
            return Issue(key: issue.key, scope: issue.scope?.rawValue, message: issue.message)
        }
        let safeKey = identifier(key)
        return Issue(
            key: safeKey,
            scope: issue.scope?.rawValue,
            message: issue.message.replacingOccurrences(of: key, with: safeKey)
        )
    }

    /// Keeps technical identifiers such as provider and model IDs; omits paths, URLs and free text.
    static func identifier(_ value: String) -> String {
        guard (1...160).contains(value.count),
              let first = value.unicodeScalars.first,
              first.isASCII, CharacterSet.alphanumerics.contains(first),
              !value.contains(".."),
              !Self.hasDrivePrefix(value),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-+:".unicodeScalars.contains(scalar))
              }) else {
            return "[omitted]"
        }
        return value
    }

    private static func hasDrivePrefix(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars.prefix(2))
        return scalars.count == 2 && scalars[0].properties.isAlphabetic && scalars[1] == ":"
    }
}
