import AppKit
import Combine
import Foundation
import os
import Security
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

/// Where the uploads of a failed switch that could not be taken back wait for the next switch,
/// across launches. They hold key values, so they live in this Mac's Keychain.
protocol OwnUploadArchiving: Sendable {
    func load() throws -> [String: APIKeySyncMigrator.OwnUpload]
    /// Empty deletes the archive.
    func save(_ uploads: [String: APIKeySyncMigrator.OwnUpload]) throws
}

struct KeychainOwnUploadArchive: OwnUploadArchiving {
    static let service = "apiKeySync.unreconciledUploads.v1"

    func load() throws -> [String: APIKeySyncMigrator.OwnUpload] {
        guard let item = try KeychainService.loadItem(service: Self.service) else { return [:] }
        return (try? JSONDecoder().decode([String: APIKeySyncMigrator.OwnUpload].self, from: Data(item.value.utf8))) ?? [:]
    }

    /// Replaces the item in place, so a failed write keeps what was archived before.
    func save(_ uploads: [String: APIKeySyncMigrator.OwnUpload]) throws {
        guard !uploads.isEmpty else {
            try KeychainService.delete(service: Self.service)
            return
        }
        let data = try JSONEncoder().encode(uploads)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainServicePrefix + Self.service,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.saveFailed(status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.saveFailed(addStatus) }
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
    struct OwnUpload: Codable, Equatable, Sendable {
        let value: String
        let previous: String?
    }

    /// Thrown when uploads must stop, such as when a managed setting forbids sync mid-copy.
    struct Stopped: Error {}

    /// This switch's uploads, recorded as they happen, so they survive a copy step that fails
    /// partway and can be undone.
    final class OwnUploadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var uploads: [String: OwnUpload]

        init(_ uploads: [String: OwnUpload] = [:]) {
            self.uploads = uploads
        }

        var current: [String: OwnUpload] { lock.withLock { uploads } }

        func record(_ upload: OwnUpload?, for account: String) {
            lock.withLock { uploads[account] = upload }
        }
    }

    let shared: any SharedAPIKeyStoring
    let local: any LocalPluginSecretStoring
    /// Runs one plugin's look at its custom-server setting and its key on this Mac as a single
    /// step, ordered with the host's custom-server changes (`SharedAPIKeyVault.withLocalLock`).
    var serializeLocal: @Sendable (_ step: () throws -> Void) throws -> Void = { try $0() }

    func loadSharedKeys() throws -> [String: String] {
        try shared.readAll().compactMapValues { SharedAPIKeyItemFormat.decode($0.value) }
    }

    /// Step 1 of turning sync on. A key only this Mac has is uploaded, one only iCloud Keychain
    /// has is received. Two different keys: the newer modification date wins, and without both
    /// dates iCloud Keychain wins. Throws at the first failed read or write.
    ///
    /// `log` holds this switch's uploads from earlier attempts and receives this attempt's. They
    /// are not another device's keys, so for them this Mac's key as it is now decides: a key saved
    /// meanwhile is uploaded, and a key deleted meanwhile puts back what iCloud Keychain held
    /// before.
    /// `admitUpload` runs every write to iCloud Keychain, and refuses it once sync is forbidden.
    /// `keepsKeyLocal` is asked for each plugin when it is reached, so a plugin set to a custom
    /// server while the copy runs is left alone.
    func copyLocalKeysToShared(
        plugins: [SyncablePluginKey],
        log: OwnUploadLog = OwnUploadLog(),
        admitUpload: (_ write: () throws -> Void) throws -> Bool = { try $0(); return true },
        keepsKeyLocal: (_ pluginId: String) -> Bool = { _ in false }
    ) throws -> TurnOnResult {
        let earlierUploads = log.current
        let sharedItems = try shared.readAll()
        var result = TurnOnResult(
            keys: sharedItems.compactMapValues { SharedAPIKeyItemFormat.decode($0.value) },
            ownUploads: earlierUploads
        )
        for plugin in plugins {
            var keptLocal = false
            var localItem: LocalPluginSecret?
            try serializeLocal {
                keptLocal = keepsKeyLocal(plugin.pluginId)
                if !keptLocal { localItem = try local.read(pluginId: plugin.pluginId) }
            }
            guard !keptLocal else { continue }
            let sharedValue = result.keys[plugin.account]
            let localValue = localItem.flatMap {
                SharedAPIKeyItemFormat.encode($0.value).flatMap(SharedAPIKeyItemFormat.decode)
            }

            if let earlier = earlierUploads[plugin.account], sharedValue == earlier.value {
                if let localValue {
                    if localValue != earlier.value {
                        try upload(localValue, replacing: earlier.previous, for: plugin, into: &result, log: log, admitUpload: admitUpload)
                    }
                } else if earlier.previous == earlier.value {
                    // Put back by a rollback: the key from before the switch, which this Mac does
                    // not hold. It is received like any shared key.
                    result.changed.insert(plugin.account)
                    result.ownUploads[plugin.account] = nil
                    log.record(nil, for: plugin.account)
                } else {
                    try restore(earlier.previous, for: plugin, into: &result, log: log, admitUpload: admitUpload)
                }
                continue
            }

            guard let localItem, let localValue else {
                if sharedValue != nil { result.changed.insert(plugin.account) }
                continue
            }
            guard let sharedValue else {
                try upload(localValue, replacing: nil, for: plugin, into: &result, log: log, admitUpload: admitUpload)
                continue
            }
            guard sharedValue != localValue else { continue }
            if let localDate = localItem.modificationDate,
               let sharedDate = sharedItems[plugin.account]?.modificationDate,
               localDate > sharedDate {
                try upload(localValue, replacing: sharedValue, for: plugin, into: &result, log: log, admitUpload: admitUpload)
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
        for plugin in plugins {
            do {
                try serializeLocal {
                    guard !keepsKeyLocal(plugin.pluginId) else { return }
                    try local.delete(pluginId: plugin.pluginId)
                }
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
            try serializeLocal {
                guard !keepsKeyLocal(pluginId) else { return }
                try local.write(value, pluginId: pluginId)
            }
        }
        for plugin in plugins where keys[plugin.account] == nil {
            try serializeLocal {
                guard !keepsKeyLocal(plugin.pluginId) else { return }
                try local.delete(pluginId: plugin.pluginId)
            }
        }
    }

    private func upload(
        _ value: String,
        replacing previous: String?,
        for plugin: SyncablePluginKey,
        into result: inout TurnOnResult,
        log: OwnUploadLog,
        admitUpload: (_ write: () throws -> Void) throws -> Bool
    ) throws {
        guard try admitUpload({
            try shared.write(value, account: plugin.account, displayName: plugin.displayName)
        }) else { throw Stopped() }
        result.keys[plugin.account] = value
        result.uploaded.insert(plugin.account)
        // The caller passes the key this upload replaces: the one from before the switch when it
        // replaces this switch's own upload, otherwise the shared key it found.
        let upload = OwnUpload(value: value, previous: previous)
        result.ownUploads[plugin.account] = upload
        log.record(upload, for: plugin.account)
    }

    /// Undoes this switch's upload of a key that was deleted on this Mac meanwhile.
    private func restore(
        _ previous: String?,
        for plugin: SyncablePluginKey,
        into result: inout TurnOnResult,
        log: OwnUploadLog,
        admitUpload: (_ write: () throws -> Void) throws -> Bool
    ) throws {
        guard try admitUpload({
            if let previous {
                try shared.write(previous, account: plugin.account, displayName: plugin.displayName)
            } else {
                try shared.delete(account: plugin.account)
            }
        }) else { throw Stopped() }
        result.keys[plugin.account] = previous
        result.uploaded.remove(plugin.account)
        result.ownUploads[plugin.account] = nil
        log.record(nil, for: plugin.account)
        if previous != nil { result.changed.insert(plugin.account) }
    }

    /// Undoes this switch's uploads after it failed, so a failed switch leaves iCloud Keychain as
    /// it found it and a later switch cannot mistake an upload for another device's key. An item
    /// that changed since the upload belongs to another device and stays. Best effort.
    /// - Returns: The accounts that could not be put back.
    @discardableResult
    func undoOwnUploads(_ log: OwnUploadLog) -> Set<String> {
        let uploads = log.current
        guard !uploads.isEmpty, let current = try? loadSharedKeys() else { return Set(uploads.keys) }
        var failed = Set<String>()
        for (account, upload) in uploads {
            // Changed since: it belongs to another device now and is no longer this switch's.
            guard current[account] == upload.value else {
                log.record(nil, for: account)
                continue
            }
            do {
                if let previous = upload.previous {
                    let name = SharedAPIKeyItemFormat.displayName(forAccount: account, pluginName: nil)
                    try shared.write(previous, account: account, displayName: name)
                    // The restored key gets a new modification date. Recorded as this switch's
                    // own, so a retry lets this Mac's key decide again instead of the date.
                    log.record(OwnUpload(value: previous, previous: previous), for: account)
                } else {
                    try shared.delete(account: account)
                    log.record(nil, for: account)
                }
            } catch {
                failed.insert(account)
            }
        }
        return failed
    }

    struct HandOffResult: Equatable, Sendable {
        var handedOff: Set<String> = []
        /// Plugins whose hand-off failed in the Keychain; it stays pending for a later read.
        var failed: Set<String> = []
    }

    /// Gives plugins that were set to a custom server before the shared keys were read the shared
    /// key once, on this Mac, unless they got a key of their own meanwhile. `claim` takes a
    /// plugin's pending hand-off and returns false when it was cancelled; `unclaim` puts it back
    /// when the Keychain fails, so a later read can try again. A failure for one plugin does not
    /// stop the others.
    func completeHandOffs(
        _ pluginIds: Set<String>,
        keys: [String: String],
        claim: (_ pluginId: String) -> Bool,
        unclaim: (_ pluginId: String) -> Void = { _ in },
        keepsKeyLocal: (_ pluginId: String) -> Bool
    ) -> HandOffResult {
        var result = HandOffResult()
        for pluginId in pluginIds.sorted() {
            try? serializeLocal {
                guard claim(pluginId) else { return }
                do {
                    guard keepsKeyLocal(pluginId),
                          let account = SharedAPIKeyItemFormat.account(forPluginId: pluginId),
                          let value = keys[account],
                          try local.read(pluginId: pluginId) == nil else {
                        return
                    }
                    try local.write(value, pluginId: pluginId)
                    result.handedOff.insert(pluginId)
                } catch {
                    unclaim(pluginId)
                    result.failed.insert(pluginId)
                }
            }
        }
        return result
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
    /// The plugin IDs whose copies on this Mac could not be removed after sync came on; retried
    /// at launch. Only plugins whose keys that switch handled, so no other key is removed.
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

    /// The first-party plugins that are installed, enabled or not. Set by the container.
    var pluginKeys: @MainActor () -> [SyncablePluginKey] = { [] }
    /// Activates plugins again whose key changed, because they read it in `activate(host:)`.
    var reloadPlugins: @MainActor (Set<String>) -> Void = { _ in }
    /// Runs right before turning sync on switches the routing; tests change the policy there.
    var beforeSwitchForTesting: (@MainActor () -> Void)?

    let vault: SharedAPIKeyVault
    private let defaults: UserDefaults
    private let migrator: APIKeySyncMigrator
    private let storefrontCountryCode: @Sendable () async -> String?
    private let now: () -> Date
    private let launchWait: Duration
    private let retryDelay: Duration
    private var pendingOperation: Task<Void, Never>?
    /// Uploads of a failed switch that could not be taken back. The next switch treats them as
    /// its own, so a key deleted on this Mac meanwhile is not received as another device's.
    /// Kept in memory only, like every key value.
    private var leftoverUploads = APIKeySyncMigrator.OwnUploadLog()
    private let uploadArchive: any OwnUploadArchiving
    /// Read on the first switch only, so launch never touches it.
    private var archiveLoaded = false
    private var archiveHoldsUploads = false
    private var activationObserver: NSObjectProtocol?
    private var lastActivationRefresh: Date?

    init(
        defaults: UserDefaults = .standard,
        vault: SharedAPIKeyVault = .shared,
        local: any LocalPluginSecretStoring = KeychainPluginSecretStore(),
        storefrontCountryCode: @escaping @Sendable () async -> String? = APIKeySyncService.currentStorefrontCountryCode,
        now: @escaping () -> Date = Date.init,
        launchWait: Duration = APIKeySyncService.defaultLaunchWait,
        retryDelay: Duration = .seconds(30),
        uploadArchive: any OwnUploadArchiving = KeychainOwnUploadArchive()
    ) {
        self.uploadArchive = uploadArchive
        self.defaults = defaults
        self.launchWait = launchWait
        self.retryDelay = retryDelay
        self.vault = vault
        var migrator = APIKeySyncMigrator(shared: vault.store, local: local)
        migrator.serializeLocal = { [vault] step in try vault.withLocalLock(step) }
        self.migrator = migrator
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
        guard isEnabled else {
            if !vault.current.pendingHandOffs.isEmpty {
                enqueue { [weak self] in await self?.completeHandOffsWhileOff() }
            }
            return
        }
        if let pending = defaults.stringArray(forKey: Self.pendingLocalCleanupKey) {
            let plugins = pluginKeys().filter { pending.contains($0.pluginId) }
            enqueue { [weak self] in await self?.removeLocalCopies(of: plugins) }
        }
        #if APPSTORE
        enqueue { [weak self] in await self?.applyStorefront() }
        #endif
    }

    /// Takes effect at once without waiting for a write under way, so the main actor never waits.
    private func updateUploadGate() {
        vault.setSharedWritesAllowed(!managedConfigurationForbids && !storefrontForbids)
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
        guard !isUpdating else { return }
        guard isEnabled else {
            // A hand-off the Keychain refused while sync turned off: try again.
            if !vault.current.pendingHandOffs.isEmpty {
                enqueue { [weak self] in await self?.completeHandOffsWhileOff() }
            }
            // Uploads a failed switch could not take back, or not archive: try again, so they do
            // not stay in iCloud Keychain or depend on this launch.
            if !leftoverUploads.current.isEmpty {
                enqueue { [weak self] in
                    guard let self, !self.isEnabled else { return }
                    await self.undoUploads(self.leftoverUploads)
                }
            }
            return
        }
        // A policy turned sync off but the Keychain refused; try again now.
        if managedConfigurationForbids || storefrontForbids {
            enqueue { [weak self] in await self?.turnOff() }
            return
        }
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
        do {
            // Without the uploads an earlier switch could not take back, this switch could take a
            // key deleted meanwhile for another device's; it waits until they can be read.
            try await loadArchivedUploads()
        } catch {
            apiKeySyncLogger.error("Reading uploads to take back failed: \(Self.technicalSummary(error), privacy: .public)")
            errorMessage = Self.userMessage(for: error)
            return
        }
        let migrator = migrator
        let uploadLog = leftoverUploads
        do {
            var activated: (result: APIKeySyncMigrator.TurnOnResult, plugins: [SyncablePluginKey])?
            let vault = vault
            for _ in 0..<Self.copyAttempts {
                // A key saved while the copy runs goes to this Mac's Keychain and would be removed
                // with the copies, so the copy runs again until no plugin wrote in between.
                let localWrites = vault.current.localWriteGeneration
                // Taken again each time: a plugin set to or away from a custom server changes it.
                let plugins = pluginKeys()
                let result = try await Self.run {
                    try migrator.copyLocalKeysToShared(
                        plugins: plugins,
                        log: uploadLog,
                        admitUpload: { try vault.admitSharedWrite($0) },
                        keepsKeyLocal: vault.keepsKeyLocal
                    )
                }
                // The managed settings may have changed while the keys moved.
                guard restriction == nil else { throw APIKeySyncMigrator.Stopped() }
                beforeSwitchForTesting?()
                // Off the main actor: the switch waits for a plugin write that is under way.
                let keys = result.keys
                if try await Self.run({ vault.activate(keys: keys, ifLocalWriteGeneration: localWrites) }) {
                    activated = (result, plugins)
                    break
                }
            }
            guard let (result, plugins) = activated else { throw SharedAPIKeyStoreError.keysChangedDuringSwitch }
            save(enabled: true)
            leftoverUploads = APIKeySyncMigrator.OwnUploadLog()
            await archive([:])
            notifyChanged(result.changed)
            apiKeySyncLogger.info(
                "API key sync on. Shared: \(Self.names(result.keys.keys), privacy: .public). Uploaded: \(Self.names(result.uploaded), privacy: .public). Received: \(Self.names(result.changed), privacy: .public)"
            )
            // A policy that arrived during the switch found sync still off and queued nothing.
            // Turn off the regular way, which copies every key back, also one saved meanwhile;
            // this Mac's copies stay until then.
            guard restriction == nil else {
                apiKeySyncLogger.info("The managed settings changed while turning API key sync on; turning it off")
                enqueue { [weak self] in await self?.turnOff() }
                return
            }
            await removeLocalCopies(of: plugins)
        } catch is APIKeySyncMigrator.Stopped {
            apiKeySyncLogger.info("API key sync stays off: the managed settings or the region changed while turning it on")
            await undoUploads(uploadLog)
        } catch {
            apiKeySyncLogger.error("Turning API key sync on failed: \(Self.technicalSummary(error), privacy: .public)")
            await undoUploads(uploadLog)
            errorMessage = Self.userMessage(for: error)
        }
    }

    /// A failed switch takes back what it uploaded, so it changes nothing. What could not be taken
    /// back is kept for the next switch, also across launches.
    private func undoUploads(_ log: APIKeySyncMigrator.OwnUploadLog) async {
        let migrator = migrator
        let failed = (try? await Self.run { migrator.undoOwnUploads(log) }) ?? []
        if !failed.isEmpty {
            apiKeySyncLogger.error("Could not take back uploads of a failed switch: \(Self.names(failed), privacy: .public)")
        }
        await archive(log.current)
    }

    /// Picks up the uploads an earlier launch could not take back.
    private func loadArchivedUploads() async throws {
        guard !archiveLoaded else { return }
        let archive = uploadArchive
        let archived = try await Self.run { try archive.load() }
        archiveLoaded = true
        archiveHoldsUploads = !archived.isEmpty
        let current = leftoverUploads.current
        for (account, upload) in archived where current[account] == nil {
            leftoverUploads.record(upload, for: account)
        }
    }

    private func archive(_ uploads: [String: APIKeySyncMigrator.OwnUpload]) async {
        guard !uploads.isEmpty || archiveHoldsUploads else { return }
        let archive = uploadArchive
        do {
            try await Self.run { try archive.save(uploads) }
            archiveHoldsUploads = !uploads.isEmpty
        } catch {
            apiKeySyncLogger.error("Keeping uploads to take back failed: \(Self.technicalSummary(error), privacy: .public)")
        }
    }

    private func turnOff() async {
        guard isEnabled else { return }
        isUpdating = true
        defer { isUpdating = false }
        let plugins = pluginKeys()
        let migrator = migrator
        let keepsKeyLocal = vault.keepsKeyLocal
        var handedOff = Set<String>()
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
                let pendingHandOffs = snapshot.pendingHandOffs
                let vaultForClaims = vault
                let handOffs = try await Self.run {
                    try migrator.copySharedKeysToLocal(plugins: plugins, keys: copied, keepsKeyLocal: keepsKeyLocal)
                    // Plugins set to a custom server before the shared keys were read get them now;
                    // the copy above leaves custom servers alone.
                    return migrator.completeHandOffs(
                        pendingHandOffs,
                        keys: copied,
                        claim: { vaultForClaims.claimPendingHandOff(pluginId: $0) },
                        unclaim: { vaultForClaims.setPendingHandOff(true, pluginId: $0) },
                        keepsKeyLocal: keepsKeyLocal
                    )
                }
                handedOff.formUnion(handOffs.handedOff)
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
            // Plugins on a custom server are not in `installed`; those that just got a key reload too.
            if !handedOff.isEmpty { reloadPlugins(handedOff) }
            apiKeySyncLogger.info("API key sync off: \(keys.count, privacy: .public) shared keys kept in iCloud Keychain")
        } catch {
            apiKeySyncLogger.error("Turning API key sync off failed: \(Self.technicalSummary(error), privacy: .public)")
            errorMessage = Self.userMessage(for: error)
            // A hand-off that succeeded before the failure already wrote the plugin's key.
            if !handedOff.isEmpty { reloadPlugins(handedOff) }
        }
    }

    /// Removes this Mac's copies of the keys that turning sync on handled, and only those.
    private func removeLocalCopies(of plugins: [SyncablePluginKey]) async {
        guard isEnabled else { return }
        let migrator = migrator
        let keepsKeyLocal = vault.keepsKeyLocal
        do {
            try await Self.run { try migrator.removeLocalCopies(plugins: plugins, keepsKeyLocal: keepsKeyLocal) }
            defaults.removeObject(forKey: Self.pendingLocalCleanupKey)
        } catch {
            defaults.set(plugins.map(\.pluginId), forKey: Self.pendingLocalCleanupKey)
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
                await completeHandOffs(keys: keys)
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

    /// Pending hand-offs left after sync turned off: reads the shared keys once more for them.
    private func completeHandOffsWhileOff() async {
        guard !isEnabled, !vault.current.pendingHandOffs.isEmpty else { return }
        let migrator = migrator
        guard let keys = try? await Self.run({ try migrator.loadSharedKeys() }) else { return }
        await completeHandOffs(keys: keys)
    }

    /// Plugins set to a custom server before the shared keys were read get the shared key now.
    private func completeHandOffs(keys: [String: String]) async {
        let pending = vault.current.pendingHandOffs
        guard !pending.isEmpty else { return }
        let migrator = migrator
        let vault = vault
        let result = (try? await Self.run {
            migrator.completeHandOffs(
                pending,
                keys: keys,
                claim: { vault.claimPendingHandOff(pluginId: $0) },
                unclaim: { vault.setPendingHandOff(true, pluginId: $0) },
                keepsKeyLocal: vault.keepsKeyLocal
            )
        }) ?? APIKeySyncMigrator.HandOffResult()
        if !result.handedOff.isEmpty { reloadPlugins(result.handedOff) }
        if !result.failed.isEmpty {
            apiKeySyncLogger.error("Keeping shared keys for custom servers failed, retried later: \(result.failed.count, privacy: .public)")
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
