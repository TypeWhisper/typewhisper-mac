import AppKit
import Combine
import Foundation
import os
#if APPSTORE
import StoreKit
#endif

private let apiKeySyncLogger = Logger(subsystem: AppConstants.loggerSubsystem, category: "APIKeySync")

/// A plugin whose `api-key` syncs, and the shared account it syncs under.
struct SyncablePluginKey: Equatable, Sendable {
    let pluginId: String
    let account: String
    let displayName: String

    /// nil for plugins of other publishers and for keys that never sync.
    init?(pluginId: String, pluginName: String?) {
        guard let account = SharedAPIKeyItemFormat.account(forPluginId: pluginId) else { return nil }
        self.pluginId = pluginId
        self.account = account
        displayName = SharedAPIKeyItemFormat.displayName(forAccount: account, pluginName: pluginName)
    }
}

/// Asks before a plugin deletes a synced key, as TypeWhisper for iOS does: the key disappears on
/// every device that syncs API keys. Plugins delete keys from their own settings through the SDK,
/// so the host asks while the plugin's call waits.
enum SharedAPIKeyDeletionPrompt {
    /// Asks on the main thread, where keys are removed from settings. Elsewhere no one clicked,
    /// so the deletion goes ahead.
    static func confirm(providerName: String) -> Bool {
        guard Thread.isMainThread else { return true }
        return MainActor.assumeIsolated {
            makeAlert(providerName: providerName).runModal() == .alertFirstButtonReturn
        }
    }

    @MainActor
    static func makeAlert(providerName: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete the \(providerName) API Key?")
        alert.informativeText = String(localized: "API key sync is on, so this also deletes the key on your devices that sync API keys.")
        let delete = alert.addButton(withTitle: String(localized: "Delete"))
        delete.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        return alert
    }

    /// The plugin already forgot the key before it asked the host to delete it, so it is
    /// activated again and reads the kept key.
    static func restoreKey(ofPluginId pluginId: String) {
        Task { @MainActor in
            PluginManager.shared?.reloadCredentials(ofPluginIds: [pluginId])
        }
    }
}

/// Moves plugin keys between this Mac's Keychain and iCloud Keychain, with the same rules as
/// TypeWhisper for iOS. Every call blocks; `APIKeySyncService` runs them off the main actor.
struct APIKeySyncMigrator: Sendable {
    struct TurnOnResult: Equatable, Sendable {
        /// The shared keys after the upload: what plugins read from now on.
        var keys: [String: String]
        var uploaded: Set<String> = []
        /// Accounts whose key on this Mac differed from the one plugins read from now on.
        var changed: Set<String> = []
        /// What this switch has uploaded so far, for a repeated copy step.
        var ownUploads: [String: OwnUpload] = [:]
    }

    /// A key this switch uploaded, and the shared key it replaced (nil when there was none).
    struct OwnUpload: Equatable, Sendable {
        let value: String
        let previous: String?
    }

    /// Thrown when uploads must stop, such as when a managed setting forbids sync mid-copy.
    struct Stopped: Error {}

    let shared: any SharedAPIKeyStoring
    let local: any LocalPluginSecretStoring

    func loadSharedKeys() throws -> [String: String] {
        try shared.readAll().compactMapValues { SharedAPIKeyItemFormat.decode($0.value) }
    }

    /// Step 1 of turning sync on. A key only this Mac has is uploaded, one only iCloud Keychain
    /// has is received. Two different keys: the newer modification date wins, and without both
    /// dates iCloud Keychain wins. Throws at the first failed read or write.
    ///
    /// `earlierUploads` are this switch's uploads from an earlier attempt. They are not another
    /// device's keys, so for them this Mac's key as it is now decides: a key saved meanwhile is
    /// uploaded, and a key deleted meanwhile puts back what iCloud Keychain held before.
    /// `mayUpload` is asked before every write to iCloud Keychain.
    /// `keepsKeyLocal` is asked for each plugin when it is reached, so a plugin set to a custom
    /// server while the copy runs is left alone.
    func copyLocalKeysToShared(
        plugins: [SyncablePluginKey],
        earlierUploads: [String: OwnUpload] = [:],
        mayUpload: () -> Bool = { true },
        keepsKeyLocal: (_ pluginId: String) -> Bool = { _ in false }
    ) throws -> TurnOnResult {
        let sharedItems = try shared.readAll()
        var result = TurnOnResult(
            keys: sharedItems.compactMapValues { SharedAPIKeyItemFormat.decode($0.value) },
            ownUploads: earlierUploads
        )
        for plugin in plugins where !keepsKeyLocal(plugin.pluginId) {
            let sharedValue = result.keys[plugin.account]
            let localItem = try local.read(pluginId: plugin.pluginId)
            let localValue = localItem.flatMap {
                SharedAPIKeyItemFormat.encode($0.value).flatMap(SharedAPIKeyItemFormat.decode)
            }

            if let earlier = earlierUploads[plugin.account], sharedValue == earlier.value {
                if let localValue {
                    if localValue != earlier.value {
                        try upload(localValue, replacing: earlier.previous, for: plugin, into: &result, mayUpload: mayUpload)
                    }
                } else {
                    try restore(earlier.previous, for: plugin, into: &result, mayUpload: mayUpload)
                }
                continue
            }

            guard let localItem, let localValue else {
                if sharedValue != nil { result.changed.insert(plugin.account) }
                continue
            }
            guard let sharedValue else {
                try upload(localValue, replacing: nil, for: plugin, into: &result, mayUpload: mayUpload)
                continue
            }
            guard sharedValue != localValue else { continue }
            if let localDate = localItem.modificationDate,
               let sharedDate = sharedItems[plugin.account]?.modificationDate,
               localDate > sharedDate {
                try upload(localValue, replacing: sharedValue, for: plugin, into: &result, mayUpload: mayUpload)
            } else {
                result.changed.insert(plugin.account)
            }
        }
        return result
    }

    /// Step 3 of turning sync on, retried at launch after a failure. Nothing reads these copies
    /// while sync is on.
    func removeLocalCopies(
        plugins: [SyncablePluginKey],
        keepsKeyLocal: (_ pluginId: String) -> Bool = { _ in false }
    ) throws {
        var firstError: Error?
        for plugin in plugins where !keepsKeyLocal(plugin.pluginId) {
            do {
                try local.delete(pluginId: plugin.pluginId)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Step 1 of turning sync off: every shared key becomes this Mac's key again, also for a
    /// plugin that is not installed or did not load, so no key is lost. A key missing from iCloud
    /// Keychain was deleted on another device, so an installed plugin's copy is deleted too.
    /// The iCloud Keychain items stay, so the user's other devices keep their keys.
    /// `keepsKeyLocal` names plugins whose key is left alone, such as one set to a custom server:
    /// the host already kept its key on this Mac when the server was set.
    func copySharedKeysToLocal(
        plugins: [SyncablePluginKey],
        keys: [String: String],
        keepsKeyLocal: (_ pluginId: String) -> Bool = { _ in false }
    ) throws {
        for (account, value) in keys.sorted(by: { $0.key < $1.key }) {
            let pluginId = SharedAPIKeyItemFormat.pluginId(forAccount: account)
            guard !keepsKeyLocal(pluginId) else { continue }
            try local.write(value, pluginId: pluginId)
        }
        for plugin in plugins where keys[plugin.account] == nil {
            try local.delete(pluginId: plugin.pluginId)
        }
    }

    private func upload(
        _ value: String,
        replacing previous: String?,
        for plugin: SyncablePluginKey,
        into result: inout TurnOnResult,
        mayUpload: () -> Bool
    ) throws {
        guard mayUpload() else { throw Stopped() }
        try shared.write(value, account: plugin.account, displayName: plugin.displayName)
        result.keys[plugin.account] = value
        result.uploaded.insert(plugin.account)
        // Keeps the key from before the switch when an earlier attempt already replaced it.
        let original = result.ownUploads[plugin.account].map(\.previous) ?? previous
        result.ownUploads[plugin.account] = OwnUpload(value: value, previous: original)
    }

    /// Undoes this switch's upload of a key that was deleted on this Mac meanwhile.
    private func restore(
        _ previous: String?,
        for plugin: SyncablePluginKey,
        into result: inout TurnOnResult,
        mayUpload: () -> Bool
    ) throws {
        guard mayUpload() else { throw Stopped() }
        if let previous {
            try shared.write(previous, account: plugin.account, displayName: plugin.displayName)
        } else {
            try shared.delete(account: plugin.account)
        }
        result.keys[plugin.account] = previous
        result.uploaded.remove(plugin.account)
        result.ownUploads[plugin.account] = nil
        if previous != nil { result.changed.insert(plugin.account) }
    }
}

/// The API key sync setting, off by default. On, the `api-key` of every first-party plugin lives
/// in iCloud Keychain in the format TypeWhisper for iOS reads, so a key entered on one device
/// reaches the others. Off, or forbidden by policy, the keys are copied back to this Mac and the
/// iCloud Keychain copies stay for the other devices.
///
/// Logs carry counts and status codes, never keys.
@MainActor
final class APIKeySyncService: ObservableObject {
    enum Restriction: Equatable, Sendable {
        case storefront
        case managedConfiguration
        /// This build cannot reach the shared access group.
        case unavailable
    }

    /// Same key and values as on iOS (`APIKeyStorageLocation`).
    static let storageLocationKey = "apiKeySync.storageLocation.v1"
    static let iCloudKeychainLocation = "iCloudKeychain"
    static let thisDeviceLocation = "thisDevice"
    /// Set when removing this Mac's copies failed after sync came on; retried at launch.
    static let pendingLocalCleanupKey = "apiKeySync.pendingLocalCleanup.v1"
    /// How long launch waits for iCloud Keychain before plugins activate without shared keys.
    static let defaultLaunchWait: Duration = .seconds(2)
    static let activationRefreshInterval: TimeInterval = 5

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isUpdating = false
    /// A message after a failed change. Never contains a key.
    @Published var errorMessage: String?
    @Published private(set) var managedConfigurationForbids = false {
        didSet { updateUploadGate() }
    }
    @Published private(set) var storefrontForbids = false {
        didSet { updateUploadGate() }
    }
    /// Read by the copy step off the main actor before each upload.
    private let uploadsAllowed = OSAllocatedUnfairLock(initialState: true)

    /// The first-party plugins that are installed, enabled or not. Set by the container.
    var pluginKeys: @MainActor () -> [SyncablePluginKey] = { [] }
    /// Activates plugins again whose key changed, because they read it in `activate(host:)`.
    var reloadPlugins: @MainActor (Set<String>) -> Void = { _ in }

    let vault: SharedAPIKeyVault
    private let defaults: UserDefaults
    private let migrator: APIKeySyncMigrator
    private let storefrontCountryCode: @Sendable () async -> String?
    private let now: () -> Date
    private let launchWait: Duration
    private let retryDelay: Duration
    private var pendingOperation: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var lastActivationRefresh: Date?

    init(
        defaults: UserDefaults = .standard,
        vault: SharedAPIKeyVault = .shared,
        local: any LocalPluginSecretStoring = KeychainPluginSecretStore(),
        storefrontCountryCode: @escaping @Sendable () async -> String? = APIKeySyncService.currentStorefrontCountryCode,
        now: @escaping () -> Date = Date.init,
        launchWait: Duration = APIKeySyncService.defaultLaunchWait,
        retryDelay: Duration = .seconds(30)
    ) {
        self.defaults = defaults
        self.launchWait = launchWait
        self.retryDelay = retryDelay
        self.vault = vault
        migrator = APIKeySyncMigrator(shared: vault.store, local: local)
        self.storefrontCountryCode = storefrontCountryCode
        self.now = now
        isEnabled = defaults.string(forKey: Self.storageLocationKey) == Self.iCloudKeychainLocation
    }

    /// Why sync cannot be turned on, or nil.
    var restriction: Restriction? {
        if storefrontForbids { return .storefront }
        if managedConfigurationForbids { return .managedConfiguration }
        if !vault.store.isAvailable { return .unavailable }
        return nil
    }

    // MARK: - Launch and refresh

    /// Runs before plugins activate. Waits at most `launchWait` for iCloud Keychain so plugins
    /// find their keys at once; a slower answer still reaches them by activating them again.
    /// Only records the managed policy: enforcing it needs the installed plugins, see
    /// `pluginsDidLoad()`. Until then plugins read the shared keys.
    func prepareForPluginActivation(policy: ManagedPolicySnapshot) async {
        applyManagedPolicy(policy, enforcing: false)
        startObservingActivation()
        guard isEnabled else { return }

        vault.activate(keys: nil)
        let load = Task { await self.reloadSharedKeys(retryingAfterFailure: true) }
        await Self.waitForFirst(load, orAtMost: launchWait)
    }

    /// Runs after the plugin scan at launch, when `pluginKeys()` lists the installed plugins.
    func pluginsDidLoad() {
        enforceManagedPolicy()
        guard isEnabled else { return }
        if defaults.bool(forKey: Self.pendingLocalCleanupKey) {
            enqueue { [weak self] in await self?.removeLocalCopies() }
        }
        #if APPSTORE
        enqueue { [weak self] in await self?.applyStorefront() }
        #endif
    }

    private func updateUploadGate() {
        let allowed = !managedConfigurationForbids && !storefrontForbids
        uploadsAllowed.withLock { $0 = allowed }
    }

    /// Follows the managed settings: `AllowAPIKeySync` and both cloud keys.
    func applyManagedPolicy(_ snapshot: ManagedPolicySnapshot, enforcing: Bool = true) {
        managedConfigurationForbids = !ManagedAPIKeySyncPolicy.allowsAPIKeySync(snapshot)
        if enforcing { enforceManagedPolicy() }
    }

    private func enforceManagedPolicy() {
        guard managedConfigurationForbids, isEnabled else { return }
        apiKeySyncLogger.info("The managed settings turn API key sync off")
        enqueue { [weak self] in await self?.turnOff() }
    }

    /// Returns when `task` finishes or `limit` has passed, whichever comes first. The task keeps
    /// running either way.
    private static func waitForFirst(_ task: Task<Void, Never>, orAtMost limit: Duration) async {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeOnce: @Sendable () -> Void = {
                let isFirst = resumed.withLock { wasResumed in
                    defer { wasResumed = true }
                    return !wasResumed
                }
                if isFirst { continuation.resume() }
            }
            Task {
                await task.value
                resumeOnce()
            }
            Task {
                try? await Task.sleep(for: limit)
                resumeOnce()
            }
        }
    }

    /// iCloud Keychain may have changed keys while the app was in the background.
    func applicationDidBecomeActive() {
        guard isEnabled, !isUpdating else { return }
        let current = now()
        if let lastActivationRefresh,
           current.timeIntervalSince(lastActivationRefresh) < Self.activationRefreshInterval {
            return
        }
        lastActivationRefresh = current
        enqueue { [weak self] in await self?.reloadSharedKeys(retryingAfterFailure: false) }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            guard restriction == nil else { return }
            enqueue { [weak self] in await self?.turnOn() }
        } else {
            enqueue { [weak self] in await self?.turnOff() }
        }
    }

    /// Waits for the change that is running, for tests.
    func waitForPendingOperation() async {
        await pendingOperation?.value
    }

    // MARK: - Moving keys

    /// A copy step runs again when a plugin key changed while it ran, at most this often.
    static let copyAttempts = 3

    private func turnOn() async {
        #if APPSTORE
        await applyStorefront()
        #endif
        guard !isEnabled, restriction == nil else { return }
        isUpdating = true
        defer { isUpdating = false }
        let plugins = pluginKeys()
        let migrator = migrator
        do {
            var activated: APIKeySyncMigrator.TurnOnResult?
            var ownUploads: [String: APIKeySyncMigrator.OwnUpload] = [:]
            let vault = vault
            let gate = uploadsAllowed
            for _ in 0..<Self.copyAttempts {
                // A key saved while the copy runs goes to this Mac's Keychain and would be removed
                // with the copies, so the copy runs again until no plugin wrote in between.
                let localWrites = vault.current.localWriteGeneration
                let earlier = ownUploads
                let result = try await Self.run {
                    try migrator.copyLocalKeysToShared(
                        plugins: plugins,
                        earlierUploads: earlier,
                        mayUpload: { gate.withLock { $0 } },
                        keepsKeyLocal: vault.keepsKeyLocal
                    )
                }
                ownUploads = result.ownUploads
                // The managed settings may have changed while the keys moved.
                guard restriction == nil else { throw APIKeySyncMigrator.Stopped() }
                // Off the main actor: the switch waits for a plugin write that is under way.
                let keys = result.keys
                if try await Self.run({ vault.activate(keys: keys, ifLocalWriteGeneration: localWrites) }) {
                    activated = result
                    break
                }
            }
            guard let result = activated else { throw SharedAPIKeyStoreError.keysChangedDuringSwitch }
            save(enabled: true)
            notifyChanged(result.changed)
            apiKeySyncLogger.info(
                "API key sync on. Shared: \(Self.names(result.keys.keys), privacy: .public). Uploaded: \(Self.names(result.uploaded), privacy: .public). Received: \(Self.names(result.changed), privacy: .public)"
            )
            await removeLocalCopies()
        } catch is APIKeySyncMigrator.Stopped {
            apiKeySyncLogger.info("API key sync stays off: the managed settings or the region changed while turning it on")
        } catch {
            apiKeySyncLogger.error("Turning API key sync on failed: \(Self.technicalSummary(error), privacy: .public)")
            errorMessage = Self.userMessage(for: error)
        }
    }

    private func turnOff() async {
        guard isEnabled else { return }
        isUpdating = true
        defer { isUpdating = false }
        let plugins = pluginKeys()
        let migrator = migrator
        let keepsKeyLocal = vault.keepsKeyLocal
        do {
            var copiedKeys: [String: String]?
            var inUse: [String: String] = [:]
            for _ in 0..<Self.copyAttempts {
                // A key saved while the copy runs goes to iCloud Keychain; copy again so this Mac
                // does not keep the older one.
                let snapshot = vault.current
                let keys: [String: String]
                do {
                    keys = try await Self.run { try migrator.loadSharedKeys() }
                } catch let error where snapshot.isLoaded {
                    // The copy plugins use now is the best source while iCloud Keychain is unreachable.
                    apiKeySyncLogger.notice("Turning API key sync off from the copy in memory: \(Self.technicalSummary(error), privacy: .public)")
                    keys = snapshot.keys
                }
                let copied = keys
                try await Self.run {
                    try migrator.copySharedKeysToLocal(plugins: plugins, keys: copied, keepsKeyLocal: keepsKeyLocal)
                }
                inUse = vault.current.keys
                // Off the main actor: the switch waits for a plugin write that is under way.
                let vault = vault
                let generation = snapshot.generation
                if try await Self.run({ vault.deactivate(ifGeneration: generation) }) {
                    copiedKeys = keys
                    break
                }
            }
            // Sync stays on: plugins keep using the shared keys, nothing is lost.
            guard let keys = copiedKeys else { throw SharedAPIKeyStoreError.keysChangedDuringSwitch }
            save(enabled: false)
            defaults.removeObject(forKey: Self.pendingLocalCleanupKey)
            let installed = Set(plugins.map(\.account))
            notifyChanged(SharedAPIKeyVault.changedAccounts(inUse, keys).intersection(installed))
            apiKeySyncLogger.info("API key sync off: \(keys.count, privacy: .public) shared keys kept in iCloud Keychain")
        } catch {
            apiKeySyncLogger.error("Turning API key sync off failed: \(Self.technicalSummary(error), privacy: .public)")
            errorMessage = Self.userMessage(for: error)
        }
    }

    private func removeLocalCopies() async {
        guard isEnabled else { return }
        let plugins = pluginKeys()
        let migrator = migrator
        let keepsKeyLocal = vault.keepsKeyLocal
        do {
            try await Self.run { try migrator.removeLocalCopies(plugins: plugins, keepsKeyLocal: keepsKeyLocal) }
            defaults.removeObject(forKey: Self.pendingLocalCleanupKey)
        } catch {
            defaults.set(true, forKey: Self.pendingLocalCleanupKey)
            apiKeySyncLogger.error("Keys on this Mac stay until the next launch: \(Self.technicalSummary(error), privacy: .public)")
        }
    }

    private func reloadSharedKeys(retryingAfterFailure: Bool) async {
        guard isEnabled else { return }
        let migrator = migrator
        do {
            // A save while reading makes the read stale; read again so the other keys arrive too.
            for _ in 0..<Self.copyAttempts {
                let generation = vault.current.generation
                let keys = try await Self.run { try migrator.loadSharedKeys() }
                guard isEnabled else { return }
                guard let changed = vault.apply(keys, ifGeneration: generation) else { continue }
                apiKeySyncLogger.info(
                    "Read shared API keys: \(Self.names(keys.keys), privacy: .public). Changed: \(Self.names(changed), privacy: .public)"
                )
                notifyChanged(changed)
                return
            }
            apiKeySyncLogger.notice("Shared API keys kept changing while reading them")
            scheduleRetryWhileUnloaded()
        } catch {
            apiKeySyncLogger.error("Reading shared API keys failed: \(Self.technicalSummary(error), privacy: .public)")
            guard retryingAfterFailure else { return }
            scheduleRetryWhileUnloaded()
        }
    }

    /// Reads once more later while plugins have no shared keys yet; a refresh on activation
    /// covers the loaded case.
    private func scheduleRetryWhileUnloaded() {
        guard !vault.current.isLoaded else { return }
        let delay = retryDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.isEnabled, !self.vault.current.isLoaded else { return }
            self.enqueue { [weak self] in await self?.reloadSharedKeys(retryingAfterFailure: false) }
        }
    }

    #if APPSTORE
    /// China mainland: like every restrictable feature, and cloud providers are off there too.
    private func applyStorefront() async {
        storefrontForbids = await storefrontCountryCode() == "CHN"
        if storefrontForbids && isEnabled {
            apiKeySyncLogger.info("The App Store region turns API key sync off")
            await turnOff()
        }
    }
    #endif

    private func notifyChanged(_ accounts: Set<String>) {
        guard !accounts.isEmpty else { return }
        reloadPlugins(Set(accounts.map(SharedAPIKeyItemFormat.pluginId(forAccount:))))
    }

    private func save(enabled: Bool) {
        defaults.set(
            enabled ? Self.iCloudKeychainLocation : Self.thisDeviceLocation,
            forKey: Self.storageLocationKey
        )
        isEnabled = enabled
    }

    private func startObservingActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
        }
    }

    /// Changes run one after another, so a policy change never overlaps the user's own.
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pendingOperation
        pendingOperation = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// Keychain and bridge calls block, so they run off the main actor.
    private nonisolated static func run<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private nonisolated static func technicalSummary(_ error: Error) -> String {
        if let error = error as? SharedAPIKeyStoreError { return error.technicalSummary }
        if let error = error as? KeychainError {
            switch error {
            case let .saveFailed(status), let .readFailed(status), let .deleteFailed(status):
                return "local OSStatus \(status)"
            }
        }
        return String(describing: type(of: error))
    }

    /// Account names for logs. They name providers, never keys.
    private nonisolated static func names<S: Sequence>(_ accounts: S) -> String where S.Element == String {
        let sorted = accounts.sorted()
        return sorted.isEmpty ? "none" : sorted.joined(separator: ", ")
    }

    private static func userMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    nonisolated static func currentStorefrontCountryCode() async -> String? {
        #if APPSTORE
        await Storefront.current?.countryCode
        #else
        nil
        #endif
    }
}
