import Foundation
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

private func snapshot(_ forced: [String: ManagedPolicyRawValue]) -> ManagedPolicySnapshot {
    ManagedPolicyValidator.validate(ManagedPolicyReading(forcedValues: forced), revision: 1, readAt: Date())
}

final class ManagedProviderPolicyTests: XCTestCase {
    func testSnapshotMapsEveryRestriction() {
        let policy = ManagedProviderPolicy(snapshot: snapshot([
            "AllowCloudTranscription": .boolean(false),
            "AllowCloudTextProcessing": .boolean(true),
            "AllowModelDownloads": .boolean(false),
            "AllowedPlugins": .array([.string("com.typewhisper.parakeet")]),
            "AllowedTranscriptionProviders": .array([]),
            "AllowedLlmProviders": .array([.string("com.typewhisper.claude")]),
        ]))

        XCTAssertFalse(policy.allowsCloudTranscription)
        XCTAssertTrue(policy.allowsCloudTextProcessing)
        XCTAssertFalse(policy.allowsModelDownloads)
        XCTAssertEqual(policy.allowedPlugins, ["com.typewhisper.parakeet"])
        XCTAssertEqual(policy.allowedTranscriptionProviders, [])
        XCTAssertEqual(policy.allowedLlmProviders, ["com.typewhisper.claude"])
        XCTAssertTrue(policy.blockedKeys.isEmpty)
        XCTAssertEqual(ManagedProviderPolicy(snapshot: snapshot([:])), .unmanaged)
        XCTAssertFalse(ManagedProviderPolicy.unmanaged.isRestricting)
    }

    func testUnmanagedPolicyRefusesNothing() {
        let policy = ManagedProviderPolicy.unmanaged
        for locality: PluginLocality? in [.local, .cloud, .configurable, nil] {
            XCTAssertNil(policy.transcriptionRefusal(pluginId: "a", providerId: "a", locality: locality))
            XCTAssertNil(policy.llmRefusal(pluginId: "a", providerId: "a", locality: locality))
            XCTAssertNil(policy.textRefusal(pluginId: "a", locality: locality))
            XCTAssertNil(policy.packageRefusal(pluginId: "a", locality: locality, categories: ["transcription"]))
            XCTAssertTrue(policy.allowsPromptText(toTranscriptionLocality: locality))
        }
        XCTAssertNil(policy.modelDownloadRefusal)
    }

    func testCloudTranscriptionOffLetsOnlyLocalEnginesReceiveAudio() {
        let policy = ManagedProviderPolicy(allowsCloudTranscription: false)

        XCTAssertNil(policy.transcriptionRefusal(pluginId: "local", providerId: "local", locality: .local))
        for locality: PluginLocality? in [.cloud, .configurable, nil] {
            XCTAssertNotNil(policy.transcriptionRefusal(pluginId: "remote", providerId: "remote", locality: locality), "\(String(describing: locality))")
            XCTAssertNil(policy.llmRefusal(pluginId: "remote", providerId: "remote", locality: locality), "Text stays allowed")
            XCTAssertTrue(policy.allowsPromptText(toTranscriptionLocality: locality))
        }
    }

    func testCloudTextOffKeepsTextAndDictionaryTermsOnTheMac() {
        let policy = ManagedProviderPolicy(allowsCloudTextProcessing: false)

        XCTAssertNil(policy.llmRefusal(pluginId: "local", providerId: "local", locality: .local))
        XCTAssertNil(policy.textRefusal(pluginId: "local", locality: .local))
        XCTAssertTrue(policy.allowsPromptText(toTranscriptionLocality: .local))
        for locality: PluginLocality? in [.cloud, .configurable, nil] {
            XCTAssertNotNil(policy.llmRefusal(pluginId: "remote", providerId: "remote", locality: locality))
            XCTAssertNotNil(policy.textRefusal(pluginId: "remote", locality: locality))
            XCTAssertFalse(policy.allowsPromptText(toTranscriptionLocality: locality))
            XCTAssertNil(policy.transcriptionRefusal(pluginId: "remote", providerId: "remote", locality: locality), "Audio stays allowed")
        }
    }

    func testRemotePackageIsRefusedOnlyWhenEveryCapabilityIsRefused() {
        let noCloudAudio = ManagedProviderPolicy(allowsCloudTranscription: false)
        XCTAssertNotNil(noCloudAudio.packageRefusal(pluginId: "groq", locality: .cloud, categories: ["transcription"]))
        XCTAssertNil(noCloudAudio.packageRefusal(pluginId: "groq", locality: .cloud, categories: ["transcription", "llm"]))
        XCTAssertNil(noCloudAudio.packageRefusal(pluginId: "parakeet", locality: .local, categories: ["transcription"]))
        XCTAssertNil(noCloudAudio.packageRefusal(pluginId: "unknown", locality: nil, categories: []), "Without categories only the allowlist applies")

        let noCloud = ManagedProviderPolicy(allowsCloudTranscription: false, allowsCloudTextProcessing: false)
        XCTAssertNotNil(noCloud.packageRefusal(pluginId: "groq", locality: .cloud, categories: ["transcription", "llm"]))
        XCTAssertNotNil(noCloud.packageRefusal(pluginId: "webhook", locality: .configurable, categories: ["post-processor"]))
        XCTAssertNil(noCloud.packageRefusal(pluginId: "whisperkit", locality: .local, categories: ["transcription"]))
    }

    func testAllowedPluginsRefusesOtherPackagesButNotAppleIntelligence() {
        let policy = ManagedProviderPolicy(allowedPlugins: ["COM.TYPEWHISPER.PARAKEET"])

        XCTAssertNil(policy.packageRefusal(pluginId: "com.typewhisper.parakeet", locality: .local, categories: ["transcription"]))
        XCTAssertNotNil(policy.packageRefusal(pluginId: "com.typewhisper.whisperkit", locality: .local, categories: ["transcription"]))
        XCTAssertNotNil(policy.transcriptionRefusal(pluginId: "com.typewhisper.whisperkit", providerId: "whisper", locality: .local))
        XCTAssertNotNil(policy.textRefusal(pluginId: "com.typewhisper.webhook", locality: .configurable))
        XCTAssertNil(policy.llmRefusal(
            pluginId: ManagedProviderPolicy.appleIntelligenceId,
            providerId: "appleIntelligence",
            locality: .local
        ))
        XCTAssertNotNil(ManagedProviderPolicy(allowedPlugins: []).packageRefusal(pluginId: "a", locality: .local, categories: []))
    }

    func testProviderAllowlistsMatchPluginOrQualifiedProviderIds() {
        let policy = ManagedProviderPolicy(
            allowedTranscriptionProviders: ["com.typewhisper.parakeet", "com.typewhisper.openai-compatible:office"],
            allowedLlmProviders: ["com.typewhisper.apple-intelligence"]
        )

        XCTAssertNil(policy.transcriptionRefusal(pluginId: "com.typewhisper.parakeet", providerId: "parakeet", locality: .local))
        XCTAssertNil(policy.transcriptionRefusal(pluginId: "com.typewhisper.openai-compatible", providerId: "OFFICE", locality: .configurable))
        XCTAssertNotNil(policy.transcriptionRefusal(pluginId: "com.typewhisper.openai-compatible", providerId: "home", locality: .configurable))
        XCTAssertNotNil(policy.transcriptionRefusal(pluginId: "com.typewhisper.whisperkit", providerId: "whisper", locality: .local))
        XCTAssertNil(policy.llmRefusal(pluginId: ManagedProviderPolicy.appleIntelligenceId, providerId: "appleIntelligence", locality: .local))
        XCTAssertNotNil(policy.llmRefusal(pluginId: "com.typewhisper.local-llm-mlx", providerId: "Local LLM", locality: .local))
        XCTAssertNotNil(ManagedProviderPolicy(allowedTranscriptionProviders: []).transcriptionRefusal(pluginId: "a", providerId: "a", locality: .local))
    }

    func testDownloadsAreRefusedWithTheirOwnReasons() {
        let policy = ManagedProviderPolicy(allowsModelDownloads: false)

        XCTAssertNotNil(policy.modelDownloadRefusal)
    }

    func testInvalidOrUnreadablePolicyRefusesWhatItGoverns() {
        let invalid = ManagedProviderPolicy(snapshot: snapshot([
            "AllowCloudTranscription": .integer(0),
            "AllowedLlmProviders": .string("com.typewhisper.claude"),
        ]))
        XCTAssertEqual(invalid.blockedKeys, ["AllowCloudTranscription", "AllowedLlmProviders"])
        XCTAssertEqual(invalid.transcriptionRefusal(pluginId: "p", providerId: "p", locality: .local), ManagedProviderPolicy.blockedMessage)
        XCTAssertEqual(invalid.llmRefusal(pluginId: "p", providerId: "p", locality: .local), ManagedProviderPolicy.blockedMessage)
        XCTAssertNil(invalid.textRefusal(pluginId: "p", locality: .cloud))

        let unreadable = ManagedProviderPolicy(snapshot: ManagedPolicyValidator.validate(.unreadable("test"), revision: 1, readAt: Date()))
        XCTAssertNotNil(unreadable.packageRefusal(pluginId: "p", locality: .local, categories: []))
        XCTAssertNotNil(unreadable.modelDownloadRefusal)
    }

}

@MainActor
final class ManagedProviderPolicyPluginManagerTests: XCTestCase {
    private var directory: URL!
    private var previousManager: PluginManager?

    override func setUp() async throws {
        try await super.setUp()
        directory = try TestSupport.makeTemporaryDirectory(prefix: "ManagedProviderPolicy")
        previousManager = PluginManager.shared
    }

    override func tearDown() async throws {
        PluginManager.shared = previousManager
        for id in [PolicyTestEngine.localId, PolicyTestEngine.cloudId, PolicyTestLLM.cloudId] {
            UserDefaults.standard.removeObject(forKey: "plugin.\(id).enabled")
            UserDefaults.standard.removeObject(forKey: PluginManager.knownProviderIdsKey(id))
        }
        TestSupport.remove(directory)
        try await super.tearDown()
    }

    func testRefusedEnginesLeaveTheListsAndNameTheirReason() {
        let manager = makeManager()

        XCTAssertEqual(Set(manager.transcriptionEngines.map(\.providerId)), ["local-engine", "cloud-engine"])

        manager.applyProviderPolicy(ManagedProviderPolicy(allowsCloudTranscription: false))

        XCTAssertEqual(manager.transcriptionEngines.map(\.providerId), ["local-engine"])
        XCTAssertNil(manager.transcriptionEngine(for: "cloud-engine"))
        XCTAssertNotNil(manager.transcriptionPolicyRefusal(forProviderId: "cloud-engine"))
        XCTAssertNil(manager.transcriptionPolicyRefusal(forProviderId: "local-engine"))
        XCTAssertEqual(manager.llmProviders.map(\.providerName), ["Cloud LLM"], "Text stays allowed")
        // A remote package whose only capability is refused stops; one with an allowed capability keeps running.
        XCTAssertEqual(manager.loadedPlugins.first { $0.id == PolicyTestEngine.cloudId }?.isEnabled, false)
        XCTAssertEqual(manager.loadedPlugins.first { $0.id == PolicyTestLLM.cloudId }?.isEnabled, true)
    }

    func testCloudCapabilityOfAMixedPackageIsRefusedWhereItIsUsed() {
        let manager = makeManager(cloudEngineCategories: ["transcription", "llm"])

        manager.applyProviderPolicy(ManagedProviderPolicy(allowsCloudTranscription: false))

        XCTAssertEqual(manager.loadedPlugins.first { $0.id == PolicyTestEngine.cloudId }?.isEnabled, true)
        XCTAssertEqual(manager.transcriptionEngines.map(\.providerId), ["local-engine"])
        XCTAssertNotNil(manager.transcriptionPolicyRefusal(forProviderId: "cloud-engine"))
    }

    func testCloudTextRestrictionRefusesLanguageModelsAndDictionaryTerms() {
        let manager = makeManager()

        manager.applyProviderPolicy(ManagedProviderPolicy(allowsCloudTextProcessing: false))

        XCTAssertTrue(manager.llmProviders.isEmpty)
        XCTAssertNotNil(manager.llmPolicyRefusal(forProviderId: "Cloud LLM"))
        XCTAssertFalse(manager.allowsPromptText(forTranscriptionProviderId: "cloud-engine"))
        XCTAssertTrue(manager.allowsPromptText(forTranscriptionProviderId: "local-engine"))
    }

    func testRefusedPackageStopsWithoutChangingTheUsersChoice() {
        let manager = makeManager()
        UserDefaults.standard.set(true, forKey: "plugin.\(PolicyTestEngine.cloudId).enabled")

        manager.applyProviderPolicy(ManagedProviderPolicy(allowedPlugins: [PolicyTestEngine.localId, PolicyTestLLM.cloudId]))

        let refused = try? XCTUnwrap(manager.loadedPlugins.first { $0.id == PolicyTestEngine.cloudId })
        XCTAssertEqual(refused?.isEnabled, false)
        XCTAssertEqual(refused?.isRuntimeLoaded, false)
        XCTAssertNotNil(manager.policyRefusals[PolicyTestEngine.cloudId])
        XCTAssertEqual(UserDefaults.standard.object(forKey: "plugin.\(PolicyTestEngine.cloudId).enabled") as? Bool, true)

        manager.setPluginEnabled(PolicyTestEngine.cloudId, enabled: true)
        XCTAssertEqual(manager.loadedPlugins.first { $0.id == PolicyTestEngine.cloudId }?.isEnabled, false, "Enabling stays refused")

        manager.applyProviderPolicy(.unmanaged)
        XCTAssertNil(manager.policyRefusals[PolicyTestEngine.cloudId])
    }

    func testReadinessErrorNamesThePolicyInsteadOfAMissingEngine() {
        let manager = makeManager()
        PluginManager.shared = manager
        manager.applyProviderPolicy(ManagedProviderPolicy(allowsCloudTranscription: false))
        let modelManager = ModelManagerService()

        guard case .managedPolicyRefused(_, let reason)? = modelManager.transcriptionReadinessError(providerId: "cloud-engine") else {
            return XCTFail("Expected a policy refusal")
        }
        XCTAssertEqual(reason, ManagedProviderPolicy(allowsCloudTranscription: false).cloudRefusal(.audio, locality: .cloud))
        XCTAssertNil(modelManager.transcriptionReadinessError(providerId: "local-engine"))
    }

    func testExplicitLanguageModelOverrideReportsThePolicy() async throws {
        let manager = makeManager()
        PluginManager.shared = manager
        manager.applyProviderPolicy(ManagedProviderPolicy(allowsCloudTextProcessing: false))
        let suite = "TypeWhisperTests.ManagedLLM.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PromptProcessingService(userDefaults: defaults)

        do {
            _ = try await service.process(prompt: "Fix", text: "hello", providerOverride: "Cloud LLM")
            XCTFail("A refused provider must not run")
        } catch {
            XCTAssertEqual(error as? ManagedPolicyRefusal, ManagedPolicyRefusal(
                reason: ManagedProviderPolicy(allowsCloudTextProcessing: false).cloudRefusal(.text, locality: .cloud)!
            ))
        }
        XCTAssertEqual(PolicyTestLLM.calls, 0)
    }

    func testFallbackListWhoseEveryProviderIsRefusedReportsThePolicy() async throws {
        let manager = makeManager()
        PluginManager.shared = manager
        let suite = "TypeWhisperTests.ManagedLLMFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PromptProcessingService(userDefaults: defaults)
        service.addLLMFallback(providerId: "Cloud LLM")
        for item in service.fallbackPriorityList where item.providerId != service.normalizeProviderId("Cloud LLM") {
            service.removeLLMFallback(item)
        }
        XCTAssertEqual(service.fallbackPriorityList.count, 1)
        manager.applyProviderPolicy(ManagedProviderPolicy(allowsCloudTextProcessing: false))

        do {
            _ = try await service.process(prompt: "Fix", text: "hello")
            XCTFail("A refused provider must not run")
        } catch {
            XCTAssertEqual(error as? ManagedPolicyRefusal, ManagedPolicyRefusal(
                reason: ManagedProviderPolicy(allowsCloudTextProcessing: false).cloudRefusal(.text, locality: .cloud)!
            ), "Not an exhausted fallback list, which the API reports as 503")
        }
        XCTAssertEqual(PolicyTestLLM.calls, 0)
    }

    func testCopyThatLosesTheReplacementLeavesTheRefusalAlone() throws {
        let manager = makeManager()
        let pluginId = PolicyTestEngine.localId
        manager.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: pluginId, name: pluginId, version: "2.0.0", principalClass: "Test",
                    categories: ["transcription"], locality: "local"
                ),
                instance: PolicyTestEngine(providerID: "local-engine"),
                bundle: Bundle.main,
                sourceURL: directory,
                isEnabled: true
            ),
        ]
        manager.applyProviderPolicy(ManagedProviderPolicy(allowsCloudTranscription: false))
        XCTAssertNil(manager.policyRefusals[pluginId])

        // An older copy without a locality would be refused, but it loses to the loaded version.
        let olderURL = directory.appendingPathComponent("Older.bundle", isDirectory: true)
        try writeBundle(at: olderURL, manifest: PluginManifest(
            id: pluginId, name: pluginId, version: "1.0.0",
            sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
            principalClass: "Test", categories: ["transcription"]
        ))
        try manager.loadPlugin(at: olderURL)

        XCTAssertNil(manager.policyRefusals[pluginId])
        XCTAssertEqual(manager.loadedPlugins.first { $0.id == pluginId }?.manifest.version, "2.0.0")
        XCTAssertNil(manager.transcriptionPolicyRefusal(forProviderId: "local-engine"))
    }

    func testLegacyLlmAliasReportsTheRefusal() {
        let manager = makeManager()
        manager.loadedPlugins.append(loaded(AliasPolicyLLM(), id: AliasPolicyLLM.pluginId, locality: "cloud", categories: ["llm", "transcription"]))

        manager.applyProviderPolicy(ManagedProviderPolicy(allowsCloudTextProcessing: false))

        let expected = manager.llmPolicyRefusal(forProviderId: AliasPolicyLLM.providerIdentifier)
        XCTAssertNotNil(expected)
        XCTAssertEqual(manager.llmPolicyRefusal(forProviderId: "Legacy Alias LLM"), expected)
        XCTAssertEqual(manager.llmPolicyRefusal(forProviderId: " alias llm "), expected)
    }

    func testUninstalledRefusedPluginNoLongerReportsARefusal() {
        let manager = makeManager()
        manager.applyProviderPolicy(ManagedProviderPolicy(allowedPlugins: [PolicyTestEngine.localId, PolicyTestLLM.cloudId]))
        XCTAssertNotNil(manager.transcriptionPolicyRefusal(forProviderId: "cloud-engine"))

        manager.unloadPlugin(PolicyTestEngine.cloudId)

        XCTAssertNil(manager.policyRefusals[PolicyTestEngine.cloudId])
        XCTAssertNil(manager.transcriptionPolicyRefusal(forProviderId: "cloud-engine"))
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: PluginManager.knownProviderIdsKey(PolicyTestEngine.cloudId)))
    }


    private func writeBundle(at bundleURL: URL, manifest: PluginManifest) throws {
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": manifest.id, "CFBundleName": manifest.name,
            "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": manifest.version, "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        try JSONEncoder().encode(manifest).write(to: resources.appendingPathComponent("manifest.json"))
    }

    private func makeManager(cloudEngineCategories: [String] = ["transcription"]) -> PluginManager {
        PolicyTestLLM.calls = 0
        let manager = PluginManager(appSupportDirectory: directory)
        manager.loadedPlugins = [
            loaded(PolicyTestEngine(providerID: "local-engine"), id: PolicyTestEngine.localId, locality: "local", categories: ["transcription"]),
            loaded(PolicyTestEngine(providerID: "cloud-engine"), id: PolicyTestEngine.cloudId, locality: "cloud", categories: cloudEngineCategories),
            loaded(PolicyTestLLM(), id: PolicyTestLLM.cloudId, locality: "cloud", categories: ["llm"]),
        ]
        return manager
    }

    private func loaded(_ instance: TypeWhisperPlugin, id: String, locality: String, categories: [String]) -> LoadedPlugin {
        LoadedPlugin(
            manifest: PluginManifest(
                id: id, name: id, version: "1.0.0", principalClass: "Test",
                categories: categories, locality: locality
            ),
            instance: instance,
            bundle: Bundle.main,
            sourceURL: directory,
            isEnabled: true
        )
    }
}

final class ManagedPolicyEventBusTests: XCTestCase {
    private final class RecordingBus: EventBusProtocol, @unchecked Sendable {
        var handlers: [@Sendable (TypeWhisperEvent) async -> Void] = []
        func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID {
            handlers.append(handler)
            return UUID()
        }
        func unsubscribe(id: UUID) {}
    }

    private final class Received: @unchecked Sendable {
        var events: [String] = []
    }

    func testContentStaysOffPluginsThatMayNotReceiveText() async {
        let store = ManagedPolicySnapshotStore(snapshot(["AllowCloudTextProcessing": .boolean(false)]))
        let base = RecordingBus()
        let received = Received()
        let bus = ManagedPolicyEventBus(base: base, pluginId: "com.typewhisper.webhook", locality: .configurable, store: store)
        bus.subscribe { event in
            switch event {
            case .recordingStarted: received.events.append("started")
            case .transcriptionCompleted: received.events.append("completed")
            default: break
            }
        }
        let handler = base.handlers[0]

        await handler(.recordingStarted(RecordingStartedPayload()))
        await handler(.transcriptionCompleted(TranscriptionCompletedPayload(rawText: "a", finalText: "a", engineUsed: "e", durationSeconds: 1, ruleName: nil)))
        XCTAssertEqual(received.events, ["started"])

        store.update(snapshot([:]))
        await handler(.transcriptionCompleted(TranscriptionCompletedPayload(rawText: "a", finalText: "a", engineUsed: "e", durationSeconds: 1, ruleName: nil)))
        XCTAssertEqual(received.events, ["started", "completed"])
    }

    func testLifecycleEventsReachPluginsThatMayNotReceiveTextWithoutTheActiveApp() async {
        let store = ManagedPolicySnapshotStore(snapshot(["AllowCloudTextProcessing": .boolean(false)]))
        let base = RecordingBus()
        let received = Received()
        let bus = ManagedPolicyEventBus(base: base, pluginId: "com.typewhisper.webhook", locality: .configurable, store: store)
        bus.subscribe { event in
            switch event {
            case .recordingStarted(let payload):
                received.events.append("started \(payload.appName ?? "-") \(payload.bundleIdentifier ?? "-")")
            case .transcriptionFailed(let payload):
                received.events.append("failed \(payload.error) \(payload.appName ?? "-") \(payload.bundleIdentifier ?? "-")")
            case .recordingStopped:
                received.events.append("stopped")
            default:
                break
            }
        }
        let handler = base.handlers[0]

        await handler(.recordingStarted(RecordingStartedPayload(appName: "Mail", bundleIdentifier: "com.apple.mail")))
        await handler(.recordingStopped(RecordingStoppedPayload(durationSeconds: 1)))
        await handler(.transcriptionFailed(TranscriptionFailedPayload(error: "offline", appName: "Mail", bundleIdentifier: "com.apple.mail")))
        XCTAssertEqual(received.events, ["started - -", "stopped", "failed offline - -"])

        store.update(snapshot([:]))
        await handler(.recordingStarted(RecordingStartedPayload(appName: "Mail", bundleIdentifier: "com.apple.mail")))
        XCTAssertEqual(received.events.last, "started Mail com.apple.mail")
    }

    func testHostContextStaysOffPluginsThatMayNotReceiveText() {
        let store = ManagedPolicySnapshotStore(snapshot(["AllowCloudTextProcessing": .boolean(false)]))
        let workflowReads = Received()
        let host = HostServicesImpl(
            pluginId: "com.typewhisper.tests.context",
            locality: .cloud,
            policyStore: store,
            eventBus: RecordingBus(),
            ruleNamesProvider: { ["Polish"] },
            workflowProvider: {
                workflowReads.events.append("read")
                return []
            }
        )

        XCTAssertNil(host.activeAppName)
        XCTAssertNil(host.activeAppBundleId)
        XCTAssertEqual(host.availableRuleNames, [])
        XCTAssertTrue(host.availableWorkflows.isEmpty)
        XCTAssertEqual(workflowReads.events, [])

        store.update(snapshot([:]))
        XCTAssertEqual(host.availableRuleNames, ["Polish"])
        _ = host.availableWorkflows
        XCTAssertEqual(workflowReads.events, ["read"])
    }

    func testHostServicesReportTheModelDownloadRefusal() {
        let store = ManagedPolicySnapshotStore(snapshot(["AllowModelDownloads": .boolean(false)]))
        let host = HostServicesImpl(
            pluginId: "com.typewhisper.tests.download",
            policyStore: store,
            eventBus: RecordingBus(),
            ruleNamesProvider: { [] }
        )

        XCTAssertEqual(host.modelDownloadRefusal, ManagedProviderPolicy(allowsModelDownloads: false).modelDownloadRefusal)
        XCTAssertThrowsError(try host.requireModelDownloadAllowed())
        store.update(snapshot([:]))
        XCTAssertNil(host.modelDownloadRefusal)
    }
}

private final class PolicyTestEngine: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.policy-engine"
    static let pluginName = "Policy Engine"
    static let localId = "com.typewhisper.tests.policy.local"
    static let cloudId = "com.typewhisper.tests.policy.cloud"

    private let providerID: String

    init(providerID: String) {
        self.providerID = providerID
    }

    required override init() {
        providerID = "engine"
    }

    var providerId: String { providerID }
    var providerDisplayName: String { providerID }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [] }
    var selectedModelId: String? { nil }
    var supportsTranslation: Bool { false }
    func activate(host: HostServices) {}
    func deactivate() {}
    func selectModel(_ modelId: String) {}
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok", detectedLanguage: language)
    }
}

private final class AliasPolicyLLM: NSObject, LLMProviderIdentityProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.alias-llm"
    static let pluginName = "Alias LLM"
    static let providerIdentifier = "com.typewhisper.tests.alias-llm.provider"

    required override init() {}

    var providerName: String { "Alias LLM" }
    var providerId: String { Self.providerIdentifier }
    var providerDisplayName: String { "Alias LLM" }
    var providerLegacyAliases: [String] { ["Legacy Alias LLM"] }
    var isAvailable: Bool { true }
    var supportedModels: [PluginModelInfo] { [] }
    func activate(host: HostServices) {}
    func deactivate() {}
    func process(systemPrompt: String, userText: String, model: String?) async throws -> String { userText }
}

private final class PolicyTestLLM: NSObject, LLMProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.policy-llm"
    static let pluginName = "Policy LLM"
    static let cloudId = "com.typewhisper.tests.policy.llm"
    nonisolated(unsafe) static var calls = 0

    required override init() {}

    var providerName: String { "Cloud LLM" }
    var isAvailable: Bool { true }
    var supportedModels: [PluginModelInfo] { [] }
    func activate(host: HostServices) {}
    func deactivate() {}
    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        Self.calls += 1
        return userText
    }
}
