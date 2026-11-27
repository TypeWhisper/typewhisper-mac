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

/// Moves plugin keys between this Mac's Keychain and iCloud Keychain, with the same rules as
/// TypeWhisper for iOS. Every call blocks; `APIKeySyncService` runs them off the main actor.
struct APIKeySyncMigrator: Sendable {
    struct TurnOnResult: Equatable, Sendable {
        /// The shared keys after the upload: what plugins read from now on.
        var keys: [String: String]
        var uploaded: Set<String> = []
        /// Accounts whose key on this Mac differed from the one plugins read from now on.
        var changed: Set<String> = []
    }

    let shared: any SharedAPIKeyStoring
    let local: any LocalPluginSecretStoring

    func loadSharedKeys() throws -> [String: String] {
        try shared.readAll().compactMapValues { SharedAPIKeyItemFormat.decode($0.value) }
    }

    /// Step 1 of turning sync on. A key only this Mac has is uploaded, one only iCloud Keychain
    /// has is received. Two different keys: the newer modification date wins, and without both
    /// dates iCloud Keychain wins. Throws at the first failed read or write.
    func copyLocalKeysToShared(plugins: [SyncablePluginKey]) throws -> TurnOnResult {
        let sharedItems = try shared.readAll()
        var result = TurnOnResult(
            keys: sharedItems.compactMapValues { SharedAPIKeyItemFormat.decode($0.value) }
        )
        for plugin in plugins {
            let sharedValue = result.keys[plugin.account]
            guard let localItem = try local.read(pluginId: plugin.pluginId),
                  let localValue = SharedAPIKeyItemFormat.encode(localItem.value)
                    .flatMap(SharedAPIKeyItemFormat.decode) else {
                if sharedValue != nil { result.changed.insert(plugin.account) }
                continue
            }
            guard let sharedValue else {
                try upload(localValue, for: plugin, into: &result)
                continue
            }
            guard sharedValue != localValue else { continue }
            if let localDate = localItem.modificationDate,
               let sharedDate = sharedItems[plugin.account]?.modificationDate,
               localDate > sharedDate {
                try upload(localValue, for: plugin, into: &result)
            } else {
                result.changed.insert(plugin.account)
            }
        }
        return result
    }

    /// Step 3 of turning sync on, retried at launch after a failure. Nothing reads these copies
    /// while sync is on.
    func removeLocalCopies(plugins: [SyncablePluginKey]) throws {
        var firstError: Error?
        for plugin in plugins {
            do {
                try local.delete(pluginId: plugin.pluginId)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Step 1 of turning sync off: the shared keys become this Mac's keys again. A key missing
    /// from iCloud Keychain was deleted on another device, so it is deleted here too.
    /// The iCloud Keychain items stay, so the user's other devices keep their keys.
    func copySharedKeysToLocal(plugins: [SyncablePluginKey], keys: [String: String]) throws {
        for plugin in plugins {
            if let value = keys[plugin.account] {
                try local.write(value, pluginId: plugin.pluginId)
            } else {
                try local.delete(pluginId: plugin.pluginId)
            }
        }
    }

    private func upload(
        _ value: String,
        for plugin: SyncablePluginKey,
        into result: inout TurnOnResult
    ) throws {
        try shared.write(value, account: plugin.account, displayName: plugin.displayName)
        result.keys[plugin.account] = value
        result.uploaded.insert(plugin.account)
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
    static let launchWait: Duration = .seconds(2)
    static let activationRefreshInterval: TimeInterval = 5

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isUpdating = false
    /// A message after a failed change. Never contains a key.
    @Published var errorMessage: String?
    @Published private(set) var managedConfigurationForbids = false
    @Published private(set) var storefrontForbids = false

    /// The first-party plugins that are installed, enabled or not. Set by the container.
    var pluginKeys: @MainActor () -> [SyncablePluginKey] = { [] }
    /// Activates plugins again whose key changed, because they read it in `activate(host:)`.
    var reloadPlugins: @MainActor (Set<String>) -> Void = { _ in }

    let vault: SharedAPIKeyVault
    private let defaults: UserDefaults
    private let migrator: APIKeySyncMigrator
    private let storefrontCountryCode: @Sendable () async -> String?
    private let now: () -> Date
    private var pendingOperation: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var lastActivationRefresh: Date?

    init(
        defaults: UserDefaults = .standard,
        vault: SharedAPIKeyVault = .shared,
        local: any LocalPluginSecretStoring = KeychainPluginSecretStore(),
        storefrontCountryCode: @escaping @Sendable () async -> String? = APIKeySyncService.currentStorefrontCountryCode,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
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

    /// Runs before plugins activate. Waits briefly for iCloud Keychain so plugins find their
    /// keys at once; a slower answer still reaches them by activating them again.
    /// While a policy turns sync off, plugins keep reading the shared keys until they are copied
    /// back to this Mac.
    func prepareForPluginActivation(policy: ManagedPolicySnapshot) async {
        applyManagedPolicy(policy)
        startObservingActivation()
        guard isEnabled else { return }

        vault.activate(keys: nil)
        let load = Task { await self.reloadSharedKeys(retryingAfterFailure: true) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await load.value }
            group.addTask { try? await Task.sleep(for: Self.launchWait) }
            await group.next()
            group.cancelAll()
        }

        if defaults.bool(forKey: Self.pendingLocalCleanupKey) {
            enqueue { [weak self] in await self?.removeLocalCopies() }
        }
        #if APPSTORE
        enqueue { [weak self] in await self?.applyStorefront() }
        #endif
    }

    /// Follows the managed settings: `AllowAPIKeySync` and both cloud keys.
    func applyManagedPolicy(_ snapshot: ManagedPolicySnapshot) {
        managedConfigurationForbids = !ManagedAPIKeySyncPolicy.allowsAPIKeySync(snapshot)
        guard managedConfigurationForbids, isEnabled else { return }
        apiKeySyncLogger.info("The managed settings turn API key sync off")
        enqueue { [weak self] in await self?.turnOff() }
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
            let result = try await Self.run { try migrator.copyLocalKeysToShared(plugins: plugins) }
            save(enabled: true)
            vault.activate(keys: result.keys)
            notifyChanged(result.changed)
            apiKeySyncLogger.info(
                "API key sync on: \(result.keys.count, privacy: .public) shared keys, \(result.uploaded.count, privacy: .public) uploaded, \(result.changed.count, privacy: .public) received"
            )
            await removeLocalCopies()
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
        let before = vault.current
        do {
            let keys: [String: String]
            do {
                keys = try await Self.run { try migrator.loadSharedKeys() }
            } catch let error where before.isLoaded {
                // The copy plugins use now is the best source while iCloud Keychain is unreachable.
                apiKeySyncLogger.notice("Turning API key sync off from the copy in memory: \(Self.technicalSummary(error), privacy: .public)")
                keys = before.keys
            }
            try await Self.run { try migrator.copySharedKeysToLocal(plugins: plugins, keys: keys) }
            save(enabled: false)
            vault.deactivate()
            defaults.removeObject(forKey: Self.pendingLocalCleanupKey)
            let installed = Set(plugins.map(\.account))
            notifyChanged(SharedAPIKeyVault.changedAccounts(before.keys, keys).intersection(installed))
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
        do {
            try await Self.run { try migrator.removeLocalCopies(plugins: plugins) }
            defaults.removeObject(forKey: Self.pendingLocalCleanupKey)
        } catch {
            defaults.set(true, forKey: Self.pendingLocalCleanupKey)
            apiKeySyncLogger.error("Keys on this Mac stay until the next launch: \(Self.technicalSummary(error), privacy: .public)")
        }
    }

    private func reloadSharedKeys(retryingAfterFailure: Bool) async {
        guard isEnabled else { return }
        let generation = vault.current.generation
        let migrator = migrator
        do {
            let keys = try await Self.run { try migrator.loadSharedKeys() }
            guard isEnabled, let changed = vault.apply(keys, ifGeneration: generation) else { return }
            notifyChanged(changed)
        } catch {
            apiKeySyncLogger.error("Reading shared API keys failed: \(Self.technicalSummary(error), privacy: .public)")
            guard retryingAfterFailure else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.isEnabled, !self.vault.current.isLoaded else { return }
                self.enqueue { [weak self] in await self?.reloadSharedKeys(retryingAfterFailure: false) }
            }
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
