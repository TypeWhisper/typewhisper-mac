import Foundation
import os
import Security

/// The shared API key items in iCloud Keychain (`SharedAPIKeyItemFormat`). Calls block, so
/// callers outside a user action run them off the main actor. Implementations never log values.
protocol SharedAPIKeyStoring: Sendable {
    /// Whether this build can reach the shared access group at all.
    var isAvailable: Bool { get }
    /// Every present item with a valid account.
    func readAll() throws -> [String: SharedAPIKeyStoredItem]
    /// Adds or replaces the item. `value` must not be empty.
    func write(_ value: String, account: String, displayName: String) throws
    /// Deletes the item on every device that syncs it. A missing item is not an error.
    func delete(account: String) throws
}

enum SharedAPIKeyStoreFactory {
    static func makeDefault() -> any SharedAPIKeyStoring {
        #if APPSTORE
        SharedAPIKeyDirectStore()
        #else
        SharedAPIKeyBridgeStore()
        #endif
    }
}

/// The App Store edition is sandboxed with a provisioning profile and uses the access group
/// itself. Builds signed without the profile lack the entitlement and report unavailable.
struct SharedAPIKeyDirectStore: SharedAPIKeyStoring {
    let isAvailable: Bool
    private let keychain: SystemSharedAPIKeyKeychain

    init(keychain: SystemSharedAPIKeyKeychain = SystemSharedAPIKeyKeychain()) {
        self.keychain = keychain
        isAvailable = Self.holdsAccessGroupEntitlement(keychain.accessGroup)
    }

    func readAll() throws -> [String: SharedAPIKeyStoredItem] {
        guard isAvailable else { throw SharedAPIKeyStoreError.unavailable }
        return try keychain.readAll()
    }

    func write(_ value: String, account: String, displayName: String) throws {
        guard isAvailable else { throw SharedAPIKeyStoreError.unavailable }
        guard let data = SharedAPIKeyItemFormat.encode(value) else {
            throw SharedAPIKeyStoreError.emptyValue
        }
        try keychain.write(data, account: account, displayName: displayName)
    }

    func delete(account: String) throws {
        guard isAvailable else { throw SharedAPIKeyStoreError.unavailable }
        try keychain.delete(account: account)
    }

    static func holdsAccessGroupEntitlement(_ accessGroup: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                task,
                "keychain-access-groups" as CFString,
                nil
              ) as? [String] else {
            return false
        }
        return groups.contains(accessGroup)
    }
}

/// The direct download has no provisioning profile, so its iCloud bridge XPC service, which has
/// one, reads and writes the items.
final class SharedAPIKeyBridgeStore: SharedAPIKeyStoring, @unchecked Sendable {
    /// Saving a key waits for the bridge on the calling thread.
    static let replyTimeout: TimeInterval = 10

    let isAvailable: Bool
    private let serviceName: String

    init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        serviceName = PremiumICloudBridgeConstants.serviceBundleIdentifier(
            infoDictionary: bundle.infoDictionary
        )
        isAvailable = fileManager.fileExists(
            atPath: PremiumICloudBridgeConstants.embeddedServiceURL(bundle: bundle).path
        )
    }

    func readAll() throws -> [String: SharedAPIKeyStoredItem] {
        try call { proxy, reply in proxy.sharedAPIKeys(reply: reply) }.items
    }

    func write(_ value: String, account: String, displayName: String) throws {
        guard SharedAPIKeyItemFormat.isValidAccount(account) else {
            throw SharedAPIKeyStoreError.invalidAccount
        }
        guard let data = SharedAPIKeyItemFormat.encode(value) else {
            throw SharedAPIKeyStoreError.emptyValue
        }
        _ = try call { proxy, reply in
            proxy.setSharedAPIKey(account, value: data, displayName: displayName, reply: reply)
        }
    }

    func delete(account: String) throws {
        guard SharedAPIKeyItemFormat.isValidAccount(account) else {
            throw SharedAPIKeyStoreError.invalidAccount
        }
        _ = try call { proxy, reply in proxy.deleteSharedAPIKey(account, reply: reply) }
    }

    /// One connection per request, like `PremiumICloudBridgeClient`. Replies arrive on the
    /// connection's own queue, so waiting here never blocks them.
    private func call(
        _ operation: (PremiumICloudBridgeXPCProtocol, @escaping (Data) -> Void) -> Void
    ) throws -> SharedAPIKeyBridgeReply {
        guard isAvailable else { throw SharedAPIKeyStoreError.unavailable }
        let gate = SharedAPIKeyReplyGate()
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(
            with: PremiumICloudBridgeXPCProtocol.self
        )
        connection.interruptionHandler = { gate.finish(nil) }
        connection.invalidationHandler = { gate.finish(nil) }
        connection.resume()
        defer { connection.invalidate() }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.finish(nil)
        }) as? PremiumICloudBridgeXPCProtocol else {
            throw SharedAPIKeyStoreError.unavailable
        }
        operation(proxy) { data in gate.finish(data) }

        switch gate.wait(timeout: Self.replyTimeout) {
        case .none:
            throw SharedAPIKeyStoreError.timedOut
        case .some(.none):
            throw SharedAPIKeyStoreError.unavailable
        case let .some(.some(data)):
            let reply = SharedAPIKeyBridgeReply.decoded(from: data)
            if let failure = reply.failure { throw failure }
            return reply
        }
    }
}

/// Takes the first answer of a bridge request: its reply, or nil after an error.
private final class SharedAPIKeyReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outcome: Data??

    func finish(_ data: Data?) {
        let isFirst = lock.withLock {
            guard outcome == nil else { return false }
            outcome = .some(data)
            return true
        }
        if isFirst { semaphore.signal() }
    }

    /// nil when no answer arrived in time.
    func wait(timeout: TimeInterval) -> Data?? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { outcome }
    }
}

// MARK: - This Mac's own copies

/// A plugin's `api-key` in this Mac's Keychain.
struct LocalPluginSecret: Equatable, Sendable {
    var value: String
    var modificationDate: Date?
}

/// The `api-key` items plugins keep on this Mac while API key sync is off, under today's names
/// (`AppConstants.keychainServicePrefix + "<plugin ID>.api-key"`).
protocol LocalPluginSecretStoring: Sendable {
    func read(pluginId: String) throws -> LocalPluginSecret?
    func write(_ value: String, pluginId: String) throws
    func delete(pluginId: String) throws
}

struct KeychainPluginSecretStore: LocalPluginSecretStoring {
    func read(pluginId: String) throws -> LocalPluginSecret? {
        try KeychainService.loadItem(service: Self.service(pluginId)).map {
            LocalPluginSecret(value: $0.value, modificationDate: $0.modificationDate)
        }
    }

    func write(_ value: String, pluginId: String) throws {
        try KeychainService.save(key: value, service: Self.service(pluginId))
    }

    func delete(pluginId: String) throws {
        try KeychainService.delete(service: Self.service(pluginId))
    }

    static func service(_ pluginId: String) -> String {
        "\(pluginId).\(SharedAPIKeyItemFormat.pluginSecretKey)"
    }
}

// MARK: - Keys bound to a custom endpoint

/// A plugin key that belongs to a server address the user entered stays on this Mac, like the
/// keys in `SharedAPIKeyItemFormat.neverSyncedAccounts`, but only while such an address is set.
enum SharedAPIKeyEndpointPolicy {
    /// The plugin default that holds a custom server address, by account. Region choices such as
    /// Soniox's stay out: they select the provider's own servers, as on iOS, which syncs those keys.
    static let customEndpointDefaults: [String: String] = [
        "reson8": "customBaseURL",
        "deepgram": "customBaseURL",
    ]

    static func keepsKeyLocal(pluginId: String, defaults: UserDefaults = .standard) -> Bool {
        guard let account = SharedAPIKeyItemFormat.account(forPluginId: pluginId),
              let key = customEndpointDefaults[account],
              let value = defaults.string(forKey: "plugin.\(pluginId).\(key)") else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - What plugins read while sync is on

/// The keys `HostServicesImpl` hands to plugins while API key sync is on: a copy of the shared
/// items in memory, filled from iCloud Keychain at launch and when the app becomes active, and
/// changed by the app's own writes. Plugins read their key synchronously in `activate(host:)`,
/// which is why a copy is needed. It is never written to disk.
final class SharedAPIKeyVault: @unchecked Sendable {
    static let shared = SharedAPIKeyVault(store: SharedAPIKeyStoreFactory.makeDefault())

    struct State: Equatable, Sendable {
        /// Sync is on: the `api-key` of first-party plugins comes from here.
        var isActive = false
        /// The copy reflects iCloud Keychain at least once since sync came on or the app launched.
        var isLoaded = false
        var keys: [String: String] = [:]
        /// Advances with every write, so a read that started before it is not applied.
        var generation = 0
        /// Advances when a plugin writes its key to this Mac's Keychain, so turning sync on
        /// notices an edit made while it copied the keys.
        var localWriteGeneration = 0
        var sharedWritesAllowed = true
        /// Plugins set to a custom server before the shared keys were read; they get the shared
        /// key on this Mac once it is read, unless they got a key of their own meanwhile.
        var pendingHandOffs: Set<String> = []
    }

    let store: any SharedAPIKeyStoring
    /// Whether a plugin's key stays on this Mac even while sync is on.
    let keepsKeyLocal: @Sendable (_ pluginId: String) -> Bool
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Orders plugin writes with each other and with turning sync on or off, so a write lands
    /// either before the switch (and the switch sees it) or after it (and goes where the switch
    /// sent it). Separate from `state`, so reads never wait for a blocked write. Never held while
    /// asking the user.
    private let saveLock = NSLock()

    init(
        store: any SharedAPIKeyStoring,
        keepsKeyLocal: @escaping @Sendable (_ pluginId: String) -> Bool = {
            SharedAPIKeyEndpointPolicy.keepsKeyLocal(pluginId: $0)
        }
    ) {
        self.store = store
        self.keepsKeyLocal = keepsKeyLocal
    }

    var current: State { state.withLock { $0 } }

    /// The shared account of a plugin secret while sync is on, otherwise nil.
    func routedAccount(pluginId: String, key: String) -> String? {
        guard key == SharedAPIKeyItemFormat.pluginSecretKey,
              let account = SharedAPIKeyItemFormat.account(forPluginId: pluginId),
              state.withLock({ $0.isActive }),
              !keepsKeyLocal(pluginId) else {
            return nil
        }
        return account
    }

    /// Stores a plugin's `api-key` where it belongs at this moment: in iCloud Keychain while sync
    /// is on, otherwise through `writeLocally`. Turning sync on or off waits for it.
    func storePluginKey(
        _ value: String,
        account: String,
        displayName: String,
        writeLocally: () throws -> Void
    ) throws {
        saveLock.lock()
        defer { saveLock.unlock() }
        let (isActive, allowed) = state.withLock { ($0.isActive, $0.sharedWritesAllowed) }
        if isActive {
            // Sync is about to turn off; the user saves again once it has.
            guard allowed else { throw SharedAPIKeyStoreError.keysChangedDuringSwitch }
            try saveLocked(value, account: account, displayName: displayName)
        } else {
            try writeLocally()
            state.withLock { $0.localWriteGeneration += 1 }
        }
    }

    func value(forAccount account: String) -> String? {
        state.withLock { $0.keys[account] }
    }

    /// Runs a change that turning sync on must see before it switches, ordered with the switch and
    /// with the copy steps: a custom server's key written to this Mac, or a plugin set to or away
    /// from a custom server.
    func withLocalChange<T>(_ body: () throws -> T) rethrows -> T {
        saveLock.lock()
        defer {
            state.withLock { $0.localWriteGeneration += 1 }
            saveLock.unlock()
        }
        return try body()
    }

    /// Notes, inside `withLocalChange`, that a plugin set to a custom server waits for the shared
    /// key, or that it no longer does.
    func setPendingHandOff(_ pending: Bool, pluginId: String) {
        state.withLock {
            if pending { $0.pendingHandOffs.insert(pluginId) } else { $0.pendingHandOffs.remove(pluginId) }
        }
    }

    /// Takes a plugin's pending hand-off; false when it was cancelled. Called inside
    /// `withLocalLock`, so it is ordered with the host's changes.
    func claimPendingHandOff(pluginId: String) -> Bool {
        state.withLock { $0.pendingHandOffs.remove(pluginId) != nil }
    }

    /// Records a local change without the lock, for tests that act like a plugin from inside a
    /// store call the vault's lock already covers; a real plugin would wait for the lock instead.
    func recordLocalChangeForTesting() {
        state.withLock { $0.localWriteGeneration += 1 }
    }

    /// Runs a copy step's look at one plugin, ordered with `withLocalChange`.
    func withLocalLock(_ body: () throws -> Void) throws {
        saveLock.lock()
        defer { saveLock.unlock() }
        try body()
    }

    /// Off while a managed setting or the region forbids sync: plugin saves and the uploads of
    /// turning sync on then do not reach iCloud Keychain, also in the moment before sync is turned
    /// off. Taken under the same lock as every admitted write, so a write either starts before the
    /// change or is refused after it.
    func setSharedWritesAllowed(_ allowed: Bool) {
        saveLock.lock()
        defer { saveLock.unlock() }
        state.withLock { $0.sharedWritesAllowed = allowed }
    }

    /// Runs an upload of turning sync on while shared writes are allowed, as one step with that
    /// check. - Returns: false, without running `write`, when they are not.
    func admitSharedWrite(_ write: () throws -> Void) throws -> Bool {
        saveLock.lock()
        defer { saveLock.unlock() }
        guard state.withLock({ $0.sharedWritesAllowed }) else { return false }
        try write()
        return true
    }

    /// The shared key of a plugin that was just set to a custom server, while sync is on, so the
    /// host can keep it on this Mac before the plugin reads its key from there.
    func sharedKeyToKeepLocally(pluginId: String) -> String? {
        guard let account = SharedAPIKeyItemFormat.account(forPluginId: pluginId),
              keepsKeyLocal(pluginId) else {
            return nil
        }
        return state.withLock { $0.isActive ? $0.keys[account] : nil }
    }

    /// Writes through to iCloud Keychain, then updates the copy. An empty value deletes the key
    /// on every device that syncs it.
    func save(_ value: String, account: String, displayName: String) throws {
        saveLock.lock()
        defer { saveLock.unlock() }
        try saveLocked(value, account: account, displayName: displayName)
    }

    private func saveLocked(_ value: String, account: String, displayName: String) throws {
        if let data = SharedAPIKeyItemFormat.encode(value),
           let trimmed = SharedAPIKeyItemFormat.decode(data) {
            try store.write(trimmed, account: account, displayName: displayName)
            state.withLock {
                $0.keys[account] = trimmed
                $0.generation += 1
            }
        } else {
            try store.delete(account: account)
            state.withLock {
                $0.keys[account] = nil
                $0.generation += 1
            }
        }
    }

    /// Turns routing on. `keys` nil means not read yet: plugins see no shared key until
    /// `apply(_:ifGeneration:)` succeeds.
    /// - Returns: The accounts whose value changed.
    @discardableResult
    func activate(keys: [String: String]?) -> Set<String> {
        state.withLock { state in
            let previous = state.isActive ? state.keys : [:]
            state.isActive = true
            state.isLoaded = keys != nil
            state.keys = keys ?? [:]
            state.generation += 1
            return Self.changedAccounts(previous, state.keys)
        }
    }

    /// Turns routing on with the keys of turning sync on, unless a plugin wrote its key to this
    /// Mac since `localWriteGeneration`.
    /// - Returns: false when the keys must be copied again.
    func activate(keys: [String: String], ifLocalWriteGeneration localWriteGeneration: Int) -> Bool {
        saveLock.lock()
        defer { saveLock.unlock() }
        return state.withLock { state in
            guard state.localWriteGeneration == localWriteGeneration else { return false }
            state.isActive = true
            state.isLoaded = true
            state.keys = keys
            state.generation += 1
            return true
        }
    }

    /// Replaces the copy with a fresh read unless a write happened since `generation`.
    /// - Returns: The accounts whose value changed, or nil when the read was dropped.
    func apply(_ keys: [String: String], ifGeneration generation: Int) -> Set<String>? {
        state.withLock { state in
            guard state.isActive, state.generation == generation else { return nil }
            let previous = state.keys
            state.keys = keys
            state.isLoaded = true
            state.generation += 1
            return Self.changedAccounts(previous, keys)
        }
    }

    func deactivate() {
        state.withLock { state in
            state = State(
                generation: state.generation + 1,
                localWriteGeneration: state.localWriteGeneration,
                sharedWritesAllowed: state.sharedWritesAllowed
                // Pending hand-offs end here; turning sync off completes them first.
            )
        }
    }

    /// Turns routing off unless a key changed since `generation`; later plugin writes go to this
    /// Mac's Keychain.
    /// - Returns: false when the keys must be copied again.
    func deactivate(ifGeneration generation: Int) -> Bool {
        saveLock.lock()
        defer { saveLock.unlock() }
        return state.withLock { state in
            guard state.generation == generation else { return false }
            state = State(
                generation: state.generation + 1,
                localWriteGeneration: state.localWriteGeneration,
                sharedWritesAllowed: state.sharedWritesAllowed
                // Pending hand-offs end here; turning sync off completes them first.
            )
            return true
        }
    }

    static func changedAccounts(_ old: [String: String], _ new: [String: String]) -> Set<String> {
        Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
    }
}
