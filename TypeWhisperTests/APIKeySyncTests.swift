import Foundation
import Security
import XCTest
@testable import TypeWhisper

// MARK: - Test doubles

private final class InMemorySharedAPIKeyStore: SharedAPIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: SharedAPIKeyStoredItem]
    private var labels: [String: String] = [:]
    private var failsReads = false
    private var failsWrites = false
    let isAvailable: Bool
    var modificationDate = Date(timeIntervalSince1970: 2_000)

    init(_ items: [String: SharedAPIKeyStoredItem] = [:], isAvailable: Bool = true) {
        storage = items
        self.isAvailable = isAvailable
    }

    var items: [String: SharedAPIKeyStoredItem] { lock.withLock { storage } }
    var values: [String: String] {
        items.compactMapValues { String(data: $0.value, encoding: .utf8) }
    }

    func label(of account: String) -> String? { lock.withLock { labels[account] } }

    func set(_ value: String?, account: String, date: Date? = nil) {
        lock.withLock {
            storage[account] = value.map { SharedAPIKeyStoredItem(value: Data($0.utf8), modificationDate: date) }
        }
    }

    func failReads(_ fails: Bool) { lock.withLock { failsReads = fails } }
    func failWrites(_ fails: Bool) { lock.withLock { failsWrites = fails } }

    func readAll() throws -> [String: SharedAPIKeyStoredItem] {
        try lock.withLock {
            if failsReads { throw SharedAPIKeyStoreError.keychain(errSecInteractionNotAllowed) }
            return storage
        }
    }

    func write(_ value: String, account: String, displayName: String) throws {
        try lock.withLock {
            if failsWrites { throw SharedAPIKeyStoreError.keychain(errSecInteractionNotAllowed) }
            storage[account] = SharedAPIKeyStoredItem(value: Data(value.utf8), modificationDate: modificationDate)
            labels[account] = SharedAPIKeyItemFormat.label(displayName: displayName)
        }
    }

    func delete(account: String) throws {
        try lock.withLock {
            if failsWrites { throw SharedAPIKeyStoreError.keychain(errSecInteractionNotAllowed) }
            storage[account] = nil
        }
    }
}

/// Blocks every read until `release()`, like a bridge that does not answer.
private final class BlockingSharedAPIKeyStore: SharedAPIKeyStoring, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    let isAvailable = true

    func release() { gate.signal() }

    func readAll() throws -> [String: SharedAPIKeyStoredItem] {
        gate.wait()
        gate.signal()
        return ["groq": SharedAPIKeyStoredItem(value: Data("gsk-late".utf8), modificationDate: nil)]
    }

    func write(_ value: String, account: String, displayName: String) throws {}
    func delete(account: String) throws {}
}

private final class InMemoryLocalSecretStore: LocalPluginSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: LocalPluginSecret]
    private var failsReads = false

    init(_ secrets: [String: LocalPluginSecret] = [:]) {
        storage = secrets
    }

    var secrets: [String: LocalPluginSecret] { lock.withLock { storage } }
    var values: [String: String] { secrets.mapValues(\.value) }

    func failReads(_ fails: Bool) { lock.withLock { failsReads = fails } }

    func read(pluginId: String) throws -> LocalPluginSecret? {
        try lock.withLock {
            if failsReads { throw KeychainError.readFailed(errSecAuthFailed) }
            return storage[pluginId]
        }
    }

    func write(_ value: String, pluginId: String) {
        lock.withLock { storage[pluginId] = LocalPluginSecret(value: value, modificationDate: nil) }
    }

    func delete(pluginId: String) {
        lock.withLock { storage[pluginId] = nil }
    }
}

private final class Decision: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var confirms: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var events: [String] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private func plugin(_ name: String, displayName: String? = nil) -> SyncablePluginKey {
    SyncablePluginKey(pluginId: "com.typewhisper.\(name)", pluginName: displayName ?? name.capitalized)!
}

private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func item(_ value: String, _ seconds: TimeInterval?) -> SharedAPIKeyStoredItem {
    SharedAPIKeyStoredItem(value: Data(value.utf8), modificationDate: seconds.map(date))
}

private func secret(_ value: String, _ seconds: TimeInterval?) -> LocalPluginSecret {
    LocalPluginSecret(value: value, modificationDate: seconds.map(date))
}

private func policySnapshot(_ forced: [String: ManagedPolicyRawValue]) -> ManagedPolicySnapshot {
    ManagedPolicyValidator.validate(ManagedPolicyRawReading(forcedValues: forced), revision: 1, readAt: Date())
}

// MARK: - Shared format

final class SharedAPIKeyItemFormatTests: XCTestCase {
    func testItemNamesMatchTypeWhisperForIOS() {
        XCTAssertEqual(SharedAPIKeyItemFormat.service, "com.typewhisper.api-keys.v1")
        XCTAssertEqual(SharedAPIKeyItemFormat.accessGroup, "2D8ALY3LCL.com.typewhisper.writing-services")
        XCTAssertEqual(SharedAPIKeyItemFormat.itemDescription, "TypeWhisper API key")
        XCTAssertEqual(String(data: SharedAPIKeyItemFormat.versionMarker, encoding: .utf8), #"{"format":1}"#)
        XCTAssertEqual(SharedAPIKeyItemFormat.label(displayName: "Groq"), "TypeWhisper Groq API Key")
        XCTAssertEqual(SharedAPIKeyItemFormat.pluginSecretKey, "api-key")
    }

    func testEveryFirstPartyPluginMapsToItsName() {
        let expected: [String: String] = [
            "com.typewhisper.groq": "groq",
            "com.typewhisper.soniox": "soniox",
            "com.typewhisper.reson8": "reson8",
            "com.typewhisper.elevenlabs": "elevenlabs",
            "com.typewhisper.openai": "openai",
            "com.typewhisper.meta": "meta",
            "com.typewhisper.gemini": "gemini",
            "com.typewhisper.assemblyai": "assemblyai",
            "com.typewhisper.openrouter": "openrouter",
            "com.typewhisper.deepgram": "deepgram",
            "com.typewhisper.claude": "claude",
            "com.typewhisper.google-cloud-stt": "google-cloud-stt",
            "com.typewhisper.memory.openai-vector": "memory.openai-vector",
        ]
        for (pluginId, account) in expected {
            XCTAssertEqual(SharedAPIKeyItemFormat.account(forPluginId: pluginId), account, pluginId)
            XCTAssertEqual(SharedAPIKeyItemFormat.pluginId(forAccount: account), pluginId)
        }
    }

    func testOtherPublishersCustomServersAndOddNamesNeverSync() {
        for pluginId in [
            "com.minerale.mistralai",
            "com.typewhisper.openai-compatible",
            "com.typewhisper.microsoft-ai",
            "com.typewhisper.cloudflare-asr",
            "com.typewhisper.",
            "com.typewhisper.Groq",
            "com.typewhisper.a..b",
            "com.typewhisper.-groq",
            "com.typewhisper.groq-",
            "com.typewhisper.gro q",
            "com.typewhisper." + String(repeating: "a", count: 65),
        ] {
            XCTAssertNil(SharedAPIKeyItemFormat.account(forPluginId: pluginId), pluginId)
        }
    }

    func testLabelsUseTheIOSNamesThenThePluginName() {
        XCTAssertEqual(plugin("openai", displayName: "OpenAI / ChatGPT").displayName, "OpenAI")
        XCTAssertEqual(plugin("elevenlabs", displayName: "Eleven Labs").displayName, "ElevenLabs")
        XCTAssertEqual(plugin("claude", displayName: "Claude").displayName, "Claude")
        XCTAssertEqual(plugin("xai", displayName: "Line\nBreak").displayName, "xai")
    }

    func testValuesAreTrimmedAndEmptyValuesAreRefused() {
        XCTAssertEqual(SharedAPIKeyItemFormat.encode("  gsk_123\n"), Data("gsk_123".utf8))
        XCTAssertNil(SharedAPIKeyItemFormat.encode(" \n "))
        XCTAssertEqual(SharedAPIKeyItemFormat.decode(Data(" gsk_123 ".utf8)), "gsk_123")
        XCTAssertNil(SharedAPIKeyItemFormat.decode(Data()))
        XCTAssertNil(SharedAPIKeyItemFormat.decode(Data([0xFF, 0xFE])))
    }

    func testBridgeReplyRoundTripsAndCarriesNoKeyInErrors() {
        let reply = SharedAPIKeyBridgeReply(items: ["groq": item("gsk_secret", 10)])
        XCTAssertEqual(SharedAPIKeyBridgeReply.decoded(from: reply.encoded()), reply)
        XCTAssertEqual(SharedAPIKeyBridgeReply.decoded(from: Data("garbage".utf8)).failure, .unavailable)

        let errors: [SharedAPIKeyStoreError] = [.unavailable, .invalidAccount, .emptyValue, .keychain(-25_293), .timedOut]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").contains("gsk_secret"))
            XCTAssertFalse(error.technicalSummary.contains("gsk_secret"))
            let failure = SharedAPIKeyBridgeReply(failure: error)
            XCTAssertEqual(SharedAPIKeyBridgeReply.decoded(from: failure.encoded()).failure, error)
        }
    }
}

// MARK: - Migration

final class APIKeySyncMigratorTests: XCTestCase {
    private let groq = plugin("groq")
    private let openAI = plugin("openai", displayName: "OpenAI / ChatGPT")
    private let deepgram = plugin("deepgram")

    func testTurningOnUploadsReceivesAndLeavesEqualKeys() throws {
        let shared = InMemorySharedAPIKeyStore([
            "openai": item("sk-shared", 100),
            "deepgram": item("dg-same", 100),
            "assemblyai": item("aai-ios-only", 100),
        ])
        let local = InMemoryLocalSecretStore([
            groq.pluginId: secret("gsk-local", 50),
            deepgram.pluginId: secret(" dg-same ", 500),
        ])

        let result = try APIKeySyncMigrator(shared: shared, local: local)
            .copyLocalKeysToShared(plugins: [groq, openAI, deepgram])

        XCTAssertEqual(result.keys, [
            "groq": "gsk-local", "openai": "sk-shared", "deepgram": "dg-same", "assemblyai": "aai-ios-only",
        ])
        XCTAssertEqual(result.uploaded, ["groq"])
        XCTAssertEqual(result.changed, ["openai"])
        XCTAssertEqual(shared.values["groq"], "gsk-local")
        XCTAssertEqual(shared.label(of: "groq"), "TypeWhisper Groq API Key")
        XCTAssertEqual(shared.items["deepgram"]?.modificationDate, date(100), "equal keys stay untouched")
    }

    func testTurningOnLetsTheNewerKeyWin() throws {
        let shared = InMemorySharedAPIKeyStore([
            "groq": item("gsk-old-shared", 100),
            "openai": item("sk-new-shared", 900),
        ])
        let local = InMemoryLocalSecretStore([
            groq.pluginId: secret("gsk-new-local", 500),
            openAI.pluginId: secret("sk-old-local", 400),
        ])

        let result = try APIKeySyncMigrator(shared: shared, local: local)
            .copyLocalKeysToShared(plugins: [groq, openAI])

        XCTAssertEqual(shared.values["groq"], "gsk-new-local")
        XCTAssertEqual(shared.label(of: "groq"), "TypeWhisper Groq API Key")
        XCTAssertEqual(shared.values["openai"], "sk-new-shared")
        XCTAssertEqual(result.uploaded, ["groq"])
        XCTAssertEqual(result.changed, ["openai"])
    }

    func testTurningOnWithoutBothDatesKeepsTheICloudKey() throws {
        let shared = InMemorySharedAPIKeyStore([
            "groq": item("gsk-shared", nil),
            "openai": item("sk-shared", 100),
        ])
        let local = InMemoryLocalSecretStore([
            groq.pluginId: secret("gsk-local", 900),
            openAI.pluginId: secret("sk-local", nil),
        ])

        let result = try APIKeySyncMigrator(shared: shared, local: local)
            .copyLocalKeysToShared(plugins: [groq, openAI])

        XCTAssertEqual(shared.values, ["groq": "gsk-shared", "openai": "sk-shared"])
        XCTAssertEqual(result.changed, ["groq", "openai"])
        XCTAssertTrue(result.uploaded.isEmpty)
    }

    func testFailedReadsStopBeforeAnyChange() {
        let shared = InMemorySharedAPIKeyStore()
        shared.failReads(true)
        let local = InMemoryLocalSecretStore([groq.pluginId: secret("gsk-local", 1)])
        XCTAssertThrowsError(try APIKeySyncMigrator(shared: shared, local: local).copyLocalKeysToShared(plugins: [groq]))

        shared.failReads(false)
        local.failReads(true)
        XCTAssertThrowsError(try APIKeySyncMigrator(shared: shared, local: local).copyLocalKeysToShared(plugins: [groq]))
        XCTAssertTrue(shared.items.isEmpty)
    }

    func testTurningOffCopiesKeysBackAndKeepsTheICloudCopies() throws {
        let shared = InMemorySharedAPIKeyStore(["groq": item("gsk-shared", 1), "assemblyai": item("aai", 1)])
        let local = InMemoryLocalSecretStore([openAI.pluginId: secret("sk-deleted-elsewhere", 1)])
        let migrator = APIKeySyncMigrator(shared: shared, local: local)

        try migrator.copySharedKeysToLocal(plugins: [groq, openAI], keys: migrator.loadSharedKeys())

        XCTAssertEqual(local.values, [
            groq.pluginId: "gsk-shared",
            "com.typewhisper.assemblyai": "aai",
        ], "keys of plugins that are not installed or did not load come back as well")
        XCTAssertEqual(shared.values, ["groq": "gsk-shared", "assemblyai": "aai"])
    }
}

// MARK: - Routing

@MainActor
final class SharedAPIKeyRoutingTests: XCTestCase {
    private func makeHost(_ pluginId: String, vault: SharedAPIKeyVault) -> HostServicesImpl {
        HostServicesImpl(
            pluginId: pluginId,
            eventBus: EventBus(),
            ruleNamesProvider: { [] },
            pluginName: "OpenAI / ChatGPT",
            apiKeyVault: vault,
            confirmSharedKeyDeletion: { _ in true },
            sharedKeyDeletionCancelled: { _ in }
        )
    }

    func testPluginKeysGoToICloudKeychainOnlyWhileSyncIsOn() throws {
        let shared = InMemorySharedAPIKeyStore()
        let vault = SharedAPIKeyVault(store: shared)
        XCTAssertNil(vault.routedAccount(pluginId: "com.typewhisper.openai", key: "api-key"))

        vault.activate(keys: ["openai": "sk-from-iphone"])
        let host = makeHost("com.typewhisper.openai", vault: vault)
        XCTAssertEqual(host.loadSecret(key: "api-key"), "sk-from-iphone")

        try host.storeSecret(key: "api-key", value: " sk-new ")
        XCTAssertEqual(shared.values["openai"], "sk-new")
        XCTAssertEqual(shared.label(of: "openai"), "TypeWhisper OpenAI API Key")
        XCTAssertEqual(host.loadSecret(key: "api-key"), "sk-new")

        try host.storeSecret(key: "api-key", value: "")
        XCTAssertNil(shared.items["openai"], "deleting a key deletes it on every device that syncs")
        XCTAssertNil(host.loadSecret(key: "api-key"))
    }

    func testDeletingASyncedKeyAsksFirstAndKeepsTheKeyOnCancel() throws {
        let shared = InMemorySharedAPIKeyStore()
        let vault = SharedAPIKeyVault(store: shared)
        vault.activate(keys: [:])
        try vault.save("gsk-key", account: "groq", displayName: "Groq")
        let answers = Received()
        let cancelled = Received()
        let decision = Decision()
        let host = HostServicesImpl(
            pluginId: "com.typewhisper.groq",
            eventBus: EventBus(),
            ruleNamesProvider: { [] },
            pluginName: "Groq",
            apiKeyVault: vault,
            confirmSharedKeyDeletion: { [answers, decision] name in
                answers.events.append(name)
                return decision.confirms
            },
            sharedKeyDeletionCancelled: { [cancelled] pluginId in cancelled.events.append(pluginId) }
        )

        XCTAssertThrowsError(try host.storeSecret(key: "api-key", value: "")) { error in
            XCTAssertEqual(error as? SharedAPIKeyStoreError, .deletionCancelled)
        }
        XCTAssertEqual(answers.events, ["Groq"])
        XCTAssertEqual(cancelled.events, ["com.typewhisper.groq"])
        XCTAssertEqual(shared.values["groq"], "gsk-key")
        XCTAssertEqual(host.loadSecret(key: "api-key"), "gsk-key")

        decision.confirms = true
        try host.storeSecret(key: "api-key", value: "")
        XCTAssertNil(shared.items["groq"])

        try host.storeSecret(key: "api-key", value: "")
        XCTAssertEqual(answers.events.count, 2, "no question when there is nothing to delete")
    }

    func testOtherSecretsAndOtherPublishersStayOnThisMac() {
        let vault = SharedAPIKeyVault(store: InMemorySharedAPIKeyStore())
        vault.activate(keys: [:])
        XCTAssertNil(vault.routedAccount(pluginId: "com.typewhisper.openai", key: "oauth-refresh-token"))
        XCTAssertNil(vault.routedAccount(pluginId: "com.typewhisper.openai-compatible", key: "api-key"))
        XCTAssertNil(vault.routedAccount(pluginId: "com.minerale.mistralai", key: "api-key"))
        XCTAssertEqual(vault.routedAccount(pluginId: "com.typewhisper.groq", key: "api-key"), "groq")

        vault.deactivate()
        XCTAssertNil(vault.routedAccount(pluginId: "com.typewhisper.groq", key: "api-key"))
    }

    func testAFailedWriteKeepsTheOldKey() {
        let shared = InMemorySharedAPIKeyStore()
        let vault = SharedAPIKeyVault(store: shared)
        vault.activate(keys: ["groq": "gsk-old"])
        shared.failWrites(true)

        XCTAssertThrowsError(try vault.save("gsk-new", account: "groq", displayName: "Groq"))
        XCTAssertEqual(vault.value(forAccount: "groq"), "gsk-old")
    }

    func testAReadThatStartedBeforeAWriteIsDropped() throws {
        let vault = SharedAPIKeyVault(store: InMemorySharedAPIKeyStore())
        vault.activate(keys: ["groq": "gsk-old"])
        let generation = vault.current.generation

        try vault.save("gsk-new", account: "groq", displayName: "Groq")

        XCTAssertNil(vault.apply(["groq": "gsk-old"], ifGeneration: generation))
        XCTAssertEqual(vault.value(forAccount: "groq"), "gsk-new")
        let fresh = vault.current.generation
        XCTAssertEqual(vault.apply(["groq": "gsk-new", "openai": "sk"], ifGeneration: fresh), ["openai"])
    }
}

// MARK: - Policy

final class ManagedAPIKeySyncPolicyTests: XCTestCase {
    func testOrganizationsCanKeepKeysOnTheMac() {
        XCTAssertTrue(ManagedAPIKeySyncPolicy.allowsAPIKeySync(policySnapshot([:])))
        XCTAssertTrue(ManagedAPIKeySyncPolicy.allowsAPIKeySync(policySnapshot(["AllowAPIKeySync": .boolean(true)])))
        XCTAssertFalse(ManagedAPIKeySyncPolicy.allowsAPIKeySync(policySnapshot(["AllowAPIKeySync": .boolean(false)])))
        XCTAssertFalse(ManagedAPIKeySyncPolicy.allowsAPIKeySync(policySnapshot(["AllowAPIKeySync": .string("no")])))
    }

    func testBothCloudKeysOffForbidSync() {
        XCTAssertFalse(ManagedAPIKeySyncPolicy.allowsAPIKeySync(policySnapshot([
            "AllowCloudTranscription": .boolean(false),
            "AllowCloudTextProcessing": .boolean(false),
        ])))
        XCTAssertTrue(ManagedAPIKeySyncPolicy.allowsAPIKeySync(policySnapshot([
            "AllowCloudTranscription": .boolean(false),
        ])))
        XCTAssertTrue(ManagedAPIKeySyncPolicy.allowsAPIKeySync(policySnapshot([
            "AllowCloudTextProcessing": .boolean(false),
        ])))
    }
}

// MARK: - Service

@MainActor
final class APIKeySyncServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var shared: InMemorySharedAPIKeyStore!
    private var local: InMemoryLocalSecretStore!
    private var reloaded: [Set<String>] = []
    private var clock = Date(timeIntervalSince1970: 10_000)

    private let groq = plugin("groq")
    private let openAI = plugin("openai")

    override func setUp() async throws {
        suiteName = "APIKeySyncServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        shared = InMemorySharedAPIKeyStore()
        local = InMemoryLocalSecretStore()
        reloaded = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeService(available: Bool = true) -> APIKeySyncService {
        if !available { shared = InMemorySharedAPIKeyStore(isAvailable: false) }
        let service = APIKeySyncService(
            defaults: defaults,
            vault: SharedAPIKeyVault(store: shared),
            local: local,
            storefrontCountryCode: { nil },
            now: { [unowned self] in clock }
        )
        service.pluginKeys = { [groq, openAI] in [groq, openAI] }
        service.reloadPlugins = { [unowned self] in reloaded.append($0) }
        return service
    }

    func testSyncIsOffByDefault() {
        let service = makeService()
        XCTAssertFalse(service.isEnabled)
        XCTAssertNil(service.restriction)
        XCTAssertFalse(service.vault.current.isActive)
    }

    func testTurningOnMovesKeysToICloudKeychainAndReloadsChangedPlugins() async {
        local.write("gsk-mac", pluginId: groq.pluginId)
        shared.set("sk-iphone", account: "openai", date: date(1))
        let service = makeService()

        service.setEnabled(true)
        await service.waitForPendingOperation()

        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(defaults.string(forKey: APIKeySyncService.storageLocationKey), "iCloudKeychain")
        XCTAssertEqual(shared.values, ["groq": "gsk-mac", "openai": "sk-iphone"])
        XCTAssertTrue(local.secrets.isEmpty, "this Mac's copies are removed")
        XCTAssertEqual(service.vault.current.keys, ["groq": "gsk-mac", "openai": "sk-iphone"])
        XCTAssertEqual(reloaded, [["com.typewhisper.openai"]])
        XCTAssertNil(service.errorMessage)
    }

    func testAFailedTurnOnChangesNothing() async {
        local.write("gsk-mac", pluginId: groq.pluginId)
        shared.failReads(true)
        let service = makeService()

        service.setEnabled(true)
        await service.waitForPendingOperation()

        XCTAssertFalse(service.isEnabled)
        XCTAssertNil(defaults.string(forKey: APIKeySyncService.storageLocationKey))
        XCTAssertEqual(local.values, [groq.pluginId: "gsk-mac"])
        XCTAssertFalse(service.vault.current.isActive)
        XCTAssertNotNil(service.errorMessage)
    }

    func testTurningOffCopiesKeysBackAndKeepsThemInICloud() async {
        local.write("gsk-mac", pluginId: groq.pluginId)
        let service = makeService()
        service.setEnabled(true)
        await service.waitForPendingOperation()
        shared.set("sk-iphone", account: "openai")

        service.setEnabled(false)
        await service.waitForPendingOperation()

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(defaults.string(forKey: APIKeySyncService.storageLocationKey), "thisDevice")
        XCTAssertEqual(local.values, [groq.pluginId: "gsk-mac", openAI.pluginId: "sk-iphone"])
        XCTAssertEqual(shared.values, ["groq": "gsk-mac", "openai": "sk-iphone"])
        XCTAssertFalse(service.vault.current.isActive)
        XCTAssertEqual(reloaded.last, ["com.typewhisper.openai"])
    }

    func testBecomingActivePicksUpKeysChangedOnOtherDevices() async {
        let service = makeService()
        service.setEnabled(true)
        await service.waitForPendingOperation()
        reloaded = []

        shared.set("gsk-from-ipad", account: "groq")
        service.applicationDidBecomeActive()
        await service.waitForPendingOperation()
        XCTAssertEqual(service.vault.value(forAccount: "groq"), "gsk-from-ipad")
        XCTAssertEqual(reloaded, [["com.typewhisper.groq"]])

        shared.set(nil, account: "groq")
        service.applicationDidBecomeActive()
        await service.waitForPendingOperation()
        XCTAssertEqual(service.vault.value(forAccount: "groq"), "gsk-from-ipad", "refreshes are throttled")

        clock.addTimeInterval(APIKeySyncService.activationRefreshInterval + 1)
        service.applicationDidBecomeActive()
        await service.waitForPendingOperation()
        XCTAssertNil(service.vault.value(forAccount: "groq"), "a key deleted elsewhere disappears here")
    }

    func testLaunchLoadsTheSharedKeysBeforePluginsActivate() async {
        defaults.set("iCloudKeychain", forKey: APIKeySyncService.storageLocationKey)
        shared.set("gsk-shared", account: "groq")
        let service = makeService()

        await service.prepareForPluginActivation(policy: policySnapshot([:]))

        XCTAssertTrue(service.vault.current.isActive)
        XCTAssertTrue(service.vault.current.isLoaded)
        XCTAssertEqual(service.vault.value(forAccount: "groq"), "gsk-shared")
    }

    func testAPolicyAtLaunchCopiesTheKeysBackOncePluginsHaveLoaded() async {
        defaults.set("iCloudKeychain", forKey: APIKeySyncService.storageLocationKey)
        shared.set("gsk-shared", account: "groq")
        let service = makeService()
        var pluginsLoaded = false
        service.pluginKeys = { [groq, openAI] in pluginsLoaded ? [groq, openAI] : [] }

        await service.prepareForPluginActivation(policy: policySnapshot(["AllowAPIKeySync": .boolean(false)]))
        await service.waitForPendingOperation()
        XCTAssertTrue(service.isEnabled, "nothing changes before the plugins are known")
        XCTAssertEqual(service.vault.value(forAccount: "groq"), "gsk-shared")

        pluginsLoaded = true
        service.pluginsDidLoad()
        await service.waitForPendingOperation()

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(local.values, [groq.pluginId: "gsk-shared"])
        XCTAssertFalse(service.vault.current.isActive)
    }

    func testLaunchWaitsForIcloudKeychainAtMostTheLaunchWait() async {
        defaults.set("iCloudKeychain", forKey: APIKeySyncService.storageLocationKey)
        let blocking = BlockingSharedAPIKeyStore()
        let service = APIKeySyncService(
            defaults: defaults,
            vault: SharedAPIKeyVault(store: blocking),
            local: local,
            storefrontCountryCode: { nil },
            launchWait: .milliseconds(200)
        )
        service.reloadPlugins = { [unowned self] in reloaded.append($0) }

        let started = Date()
        await service.prepareForPluginActivation(policy: policySnapshot([:]))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(service.vault.current.isLoaded)

        blocking.release()
        for _ in 0..<100 where !service.vault.current.isLoaded {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(service.vault.value(forAccount: "groq"), "gsk-late")
        XCTAssertEqual(reloaded, [["com.typewhisper.groq"]], "a late answer reaches the plugins")
    }

    func testThePolicyTurnsSyncOffAndItStaysOff() async {
        local.write("gsk-mac", pluginId: groq.pluginId)
        let service = makeService()
        service.setEnabled(true)
        await service.waitForPendingOperation()

        service.applyManagedPolicy(policySnapshot(["AllowAPIKeySync": .boolean(false)]))
        await service.waitForPendingOperation()

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.restriction, .managedConfiguration)
        XCTAssertEqual(local.values, [groq.pluginId: "gsk-mac"])
        XCTAssertEqual(shared.values, ["groq": "gsk-mac"])

        service.setEnabled(true)
        await service.waitForPendingOperation()
        XCTAssertFalse(service.isEnabled, "the switch is locked")

        service.applyManagedPolicy(policySnapshot([:]))
        await service.waitForPendingOperation()
        XCTAssertNil(service.restriction)
        XCTAssertFalse(service.isEnabled, "lifting the policy does not turn sync on again")
    }

    func testABuildWithoutTheAccessGroupCannotTurnSyncOn() async {
        let service = makeService(available: false)
        XCTAssertEqual(service.restriction, .unavailable)

        service.setEnabled(true)
        await service.waitForPendingOperation()
        XCTAssertFalse(service.isEnabled)
    }
}
