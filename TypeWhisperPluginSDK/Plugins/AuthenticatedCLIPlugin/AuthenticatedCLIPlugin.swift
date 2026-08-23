import Foundation
import os
import SwiftUI
import TypeWhisperPluginSDK

@objc(AuthenticatedCLIPlugin)
final class AuthenticatedCLIPlugin: NSObject,
    AdditionalLLMProvidersProviding,
    PluginSettingsWindowLayoutProviding,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.authenticated-cli"
    static let pluginName = "Authenticated Provider CLIs"

    private static let refreshInterval: TimeInterval = 5 * 60
    private static let maximumStaleAge: TimeInterval = 6 * 60
    private static let maximumInputBytes = 512 * 1024
    private static let selectedExecutableKeyPrefix = "selectedExecutable."
    private static let codexModelCatalogKey = "codexModelCatalog.v1"
    private static let antigravityModelCatalogKey = "antigravityModelCatalog.v1"

    private struct State {
        var isActive = false
        var generation: UInt64 = 0
        var isRefreshing = false
        var host: HostServices?
        var selectedPaths: [CLIProviderKind: String] = [:]
        var codexModelCatalog: CodexModelCatalog?
        var codexModelRefreshError: String?
        var antigravityModelCatalog: AntigravityModelCatalog?
        var antigravityModelRefreshError: String?
        var statuses = Dictionary(
            uniqueKeysWithValues: CLIProviderKind.allCases.map { ($0, CLIProviderStatus.checking($0)) }
        )
    }

    private enum CodexModelRefreshOutcome: Sendable {
        case notAttempted
        case success(CodexModelCatalog)
        case failure(String)
    }

    private enum AntigravityModelRefreshOutcome: Sendable {
        case notAttempted
        case success(AntigravityModelCatalog)
        case failure(String)
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let runner: any CLIProcessRunning
    private let codexModelCatalogLoader: any CodexModelCatalogLoading
    private let antigravityModelCatalogLoader: any AntigravityModelCatalogLoading
    private let baseEnvironment: [String: String]
    private let homeDirectory: URL
    private let isScreenshotAutomation: Bool

    required override convenience init() {
        self.init(
            runner: CLIProcessRunner(),
            codexModelCatalogLoader: CodexAppServerModelCatalogLoader(),
            antigravityModelCatalogLoader: AntigravityCLIModelCatalogLoader(),
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            isScreenshotAutomation: ProcessInfo.processInfo.arguments.contains("--store-screenshots")
        )
    }

    init(
        runner: any CLIProcessRunning,
        codexModelCatalogLoader: any CodexModelCatalogLoading = CodexAppServerModelCatalogLoader(),
        antigravityModelCatalogLoader: (any AntigravityModelCatalogLoading)? = nil,
        environment: [String: String],
        homeDirectory: URL,
        isScreenshotAutomation: Bool = false
    ) {
        self.runner = runner
        self.codexModelCatalogLoader = codexModelCatalogLoader
        self.antigravityModelCatalogLoader = antigravityModelCatalogLoader
            ?? AntigravityCLIModelCatalogLoader(runner: runner)
        self.baseEnvironment = environment
        self.homeDirectory = homeDirectory
        self.isScreenshotAutomation = isScreenshotAutomation
        super.init()
    }

    func activate(host: HostServices) {
        let cachedCatalog: CodexModelCatalog?
        let cachedAntigravityCatalog: AntigravityModelCatalog?
        if isScreenshotAutomation {
            cachedCatalog = Self.screenshotCodexModelCatalog
            cachedAntigravityCatalog = nil
        } else {
            cachedCatalog = Self.decodeCachedCatalog(
                CodexModelCatalog.self,
                forKey: Self.codexModelCatalogKey,
                host: host
            )
            cachedAntigravityCatalog = Self.decodeCachedCatalog(
                AntigravityModelCatalog.self,
                forKey: Self.antigravityModelCatalogKey,
                host: host
            )
        }
        let selectedPaths: [CLIProviderKind: String] = Dictionary(
            uniqueKeysWithValues: CLIProviderKind.allCases.compactMap { kind in
                let key = Self.selectedExecutableKeyPrefix + kind.rawValue
                guard let path = host.userDefault(forKey: key) as? String,
                      !path.isEmpty
                else { return nil }
                return (kind, path)
            }
        )

        state.withLock { state in
            state.isActive = true
            state.generation &+= 1
            state.isRefreshing = false
            state.host = host
            if isScreenshotAutomation {
                state.statuses = Self.screenshotStatuses
            }
            state.codexModelCatalog = cachedCatalog
            state.codexModelRefreshError = nil
            state.antigravityModelCatalog = cachedAntigravityCatalog
            state.antigravityModelRefreshError = nil
            state.selectedPaths = selectedPaths
        }

        if isScreenshotAutomation {
            host.notifyCapabilitiesChanged()
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            await self?.refreshAvailability(force: true)
        }
    }

    func deactivate() {
        state.withLock { state in
            state.isActive = false
            state.generation &+= 1
            state.isRefreshing = false
            state.host = nil
            state.codexModelRefreshError = nil
            state.antigravityModelRefreshError = nil
        }
    }

    var additionalLLMProviders: [any LLMProviderPlugin] {
        CLIProviderKind.allCases.map { AuthenticatedCLIProviderRole(plugin: self, kind: $0) }
    }

    @MainActor
    var settingsView: AnyView? {
        AnyView(AuthenticatedCLISettingsView(plugin: self))
    }

    var settingsViewManagesScrolling: Bool { true }
    var preferredSettingsWindowSize: CGSize? { CGSize(width: 760, height: 650) }
    var minimumSettingsWindowSize: CGSize? { CGSize(width: 620, height: 520) }

    func statusesSnapshot() -> [CLIProviderStatus] {
        state.withLock { state in
            CLIProviderKind.allCases.map { state.statuses[$0] ?? .checking($0) }
        }
    }

    var isRefreshingAvailability: Bool {
        state.withLock { $0.isRefreshing }
    }

    func status(for kind: CLIProviderKind) -> CLIProviderStatus {
        state.withLock { $0.statuses[kind] ?? .checking(kind) }
    }

    func selectedPath(for kind: CLIProviderKind) -> String? {
        state.withLock { $0.selectedPaths[kind] }
    }

    func supportedModels(for kind: CLIProviderKind) -> [PluginModelInfo] {
        return state.withLock { state in
            switch kind {
            case .codex:
                state.codexModelCatalog?.models.map {
                    PluginModelInfo(id: $0.id, displayName: $0.displayName)
                } ?? []
            case .claude:
                []
            case .antigravity:
                state.antigravityModelCatalog?.models.map {
                    PluginModelInfo(id: $0.id, displayName: $0.displayName)
                } ?? []
            }
        }
    }

    func defaultModelID(for kind: CLIProviderKind) -> String? {
        guard kind == .codex else { return nil }
        return state.withLock { $0.codexModelCatalog?.defaultModelID }
    }

    func supportedEfforts(for kind: CLIProviderKind, model: String?) -> [PluginLLMEffortInfo] {
        switch kind {
        case .codex:
            return state.withLock { state in
                let resolvedModel = Self.trimmedOrNil(model)
                    ?? state.codexModelCatalog?.defaultModelID
                guard let resolvedModel,
                      let catalogModel = state.codexModelCatalog?.models.first(where: {
                          $0.id == resolvedModel
                      })
                else { return [] }
                return catalogModel.supportedReasoningEfforts.map {
                    PluginLLMEffortInfo(
                        id: $0.id,
                        displayName: Self.effortDisplayName($0.id),
                        detail: $0.description
                    )
                }
            }
        case .claude:
            return ["low", "medium", "high", "xhigh", "max", "ultracode"].map {
                PluginLLMEffortInfo(id: $0, displayName: Self.effortDisplayName($0))
            }
        case .antigravity:
            return ["low", "medium", "high"].map {
                PluginLLMEffortInfo(id: $0, displayName: Self.effortDisplayName($0))
            }
        }
    }

    func defaultEffortID(for kind: CLIProviderKind, model: String?) -> String? {
        guard kind == .codex else { return nil }
        return state.withLock { state in
            let resolvedModel = Self.trimmedOrNil(model)
                ?? state.codexModelCatalog?.defaultModelID
            return state.codexModelCatalog?.models.first(where: {
                $0.id == resolvedModel
            })?.defaultReasoningEffort
        }
    }

    func codexModelCatalogSnapshot() -> (
        catalog: CodexModelCatalog?,
        refreshError: String?
    ) {
        state.withLock { ($0.codexModelCatalog, $0.codexModelRefreshError) }
    }

    func antigravityModelCatalogSnapshot() -> (
        catalog: AntigravityModelCatalog?,
        refreshError: String?
    ) {
        state.withLock { ($0.antigravityModelCatalog, $0.antigravityModelRefreshError) }
    }

    func setSelectedExecutable(_ url: URL?, for kind: CLIProviderKind) async {
        let value = url?.path
        let host = state.withLock { state -> HostServices? in
            state.selectedPaths[kind] = value
            state.statuses[kind] = .checking(kind)
            return state.host
        }
        host?.setUserDefault(value, forKey: Self.selectedExecutableKeyPrefix + kind.rawValue)
        await refreshProvider(kind)
    }

    func refreshAvailability(force: Bool) async {
        if isScreenshotAutomation {
            let host = state.withLock { state -> HostServices? in
                guard state.isActive else { return nil }
                state.statuses = Self.screenshotStatuses
                state.isRefreshing = false
                return state.host
            }
            host?.notifyCapabilitiesChanged()
            return
        }

        let snapshot = state.withLock { state -> (UInt64, [CLIProviderKind: String])? in
            guard state.isActive, !state.isRefreshing else { return nil }
            if !force {
                let now = Date()
                let isFresh = CLIProviderKind.allCases.allSatisfy { kind in
                    guard let checkedAt = state.statuses[kind]?.checkedAt else { return false }
                    return now.timeIntervalSince(checkedAt) < Self.refreshInterval
                }
                if isFresh { return nil }
            }
            state.isRefreshing = true
            return (state.generation, state.selectedPaths)
        }
        guard let (generation, selectedPaths) = snapshot else { return }

        let probe = makeProbe()
        let results = await withTaskGroup(
            of: (CLIProviderKind, CLIProviderStatus).self,
            returning: [CLIProviderKind: CLIProviderStatus].self
        ) { group in
            for kind in CLIProviderKind.allCases {
                group.addTask {
                    (kind, await probe.probe(kind, selectedPath: selectedPaths[kind]))
                }
            }
            var statuses: [CLIProviderKind: CLIProviderStatus] = [:]
            for await (kind, status) in group {
                statuses[kind] = status
            }
            return statuses
        }

        async let codexModelOutcome = loadCodexModelCatalog(using: results[.codex])
        async let antigravityModelOutcome = loadAntigravityModelCatalog(
            using: results[.antigravity]
        )
        let catalogOutcomes = await (codexModelOutcome, antigravityModelOutcome)

        let committed = state.withLock {
            state -> (HostServices?, CodexModelCatalog?, AntigravityModelCatalog?) in
            guard state.isActive, state.generation == generation else {
                return (nil, nil, nil)
            }
            for kind in CLIProviderKind.allCases
            where state.selectedPaths[kind] == selectedPaths[kind] {
                state.statuses[kind] = results[kind]
            }
            let codexSelectionIsCurrent = state.selectedPaths[.codex] == selectedPaths[.codex]
            let antigravitySelectionIsCurrent = state.selectedPaths[.antigravity]
                == selectedPaths[.antigravity]
            let codexCatalogToPersist: CodexModelCatalog?
            if codexSelectionIsCurrent {
                switch catalogOutcomes.0 {
                case .notAttempted:
                    state.codexModelRefreshError = nil
                    codexCatalogToPersist = nil
                case .success(let catalog):
                    state.codexModelCatalog = catalog
                    state.codexModelRefreshError = nil
                    codexCatalogToPersist = catalog
                case .failure(let message):
                    state.codexModelRefreshError = message
                    codexCatalogToPersist = nil
                }
            } else {
                codexCatalogToPersist = nil
            }
            let antigravityCatalogToPersist: AntigravityModelCatalog?
            if antigravitySelectionIsCurrent {
                switch catalogOutcomes.1 {
                case .notAttempted:
                    state.antigravityModelRefreshError = nil
                    antigravityCatalogToPersist = nil
                case .success(let catalog):
                    state.antigravityModelCatalog = catalog
                    state.antigravityModelRefreshError = nil
                    antigravityCatalogToPersist = catalog
                case .failure(let message):
                    state.antigravityModelRefreshError = message
                    antigravityCatalogToPersist = nil
                }
            } else {
                antigravityCatalogToPersist = nil
            }
            state.isRefreshing = false
            return (state.host, codexCatalogToPersist, antigravityCatalogToPersist)
        }
        if let catalog = committed.1,
           let data = try? JSONEncoder().encode(catalog) {
            committed.0?.setUserDefault(data, forKey: Self.codexModelCatalogKey)
        }
        if let catalog = committed.2,
           let data = try? JSONEncoder().encode(catalog) {
            committed.0?.setUserDefault(data, forKey: Self.antigravityModelCatalogKey)
        }
        committed.0?.notifyCapabilitiesChanged()
    }

    func process(
        kind: CLIProviderKind,
        instruction: String,
        input: String,
        model: String? = nil,
        effort: String? = nil
    ) async throws -> String {
        let executableURL = try await readyExecutable(for: kind)
        let envelope = try CLIRequestEnvelope.encode(instruction: instruction, input: input)
        guard envelope.count <= Self.maximumInputBytes else {
            throw CLIPluginError.inputTooLarge
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeWhisper-CLI-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CLIPluginError.fileSystem(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        let schemaURL = workspace.appendingPathComponent("result.schema.json")
        do {
            try CLIResultSchema.data.write(to: schemaURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: schemaURL.path
            )
        } catch {
            throw CLIPluginError.fileSystem(error.localizedDescription)
        }

        let result = try await runner.run(CLIProcessRequest(
            executableURL: executableURL,
            arguments: CLIInvocation.arguments(
                for: kind,
                workingDirectory: workspace,
                schemaURL: schemaURL,
                model: model,
                reasoningEffort: effort
            ),
            environment: CLIEnvironment.sanitized(
                base: baseEnvironment,
                kind: kind,
                executableURL: executableURL,
                temporaryDirectory: workspace
            ),
            workingDirectory: workspace,
            standardInput: envelope,
            timeout: 90,
            standardOutputLimit: 1024 * 1024,
            standardErrorLimit: 64 * 1024
        ))

        guard result.exitCode == 0 else {
            throw CLIPluginError.commandFailed(CLIOutputParser.failureMessage(
                kind,
                stdout: result.standardOutput,
                stderr: result.standardError,
                exitCode: result.exitCode
            ))
        }
        return try CLIOutputParser.parse(kind, stdout: result.standardOutput)
    }

    private func readyExecutable(for kind: CLIProviderKind) async throws -> URL {
        let current = status(for: kind)
        if current.isReady,
           let executableURL = current.executableURL,
           let checkedAt = current.checkedAt,
           Date().timeIntervalSince(checkedAt) < Self.maximumStaleAge {
            return executableURL
        }

        await refreshProvider(kind)
        let refreshed = status(for: kind)
        guard refreshed.isReady, let executableURL = refreshed.executableURL else {
            throw CLIPluginError.providerUnavailable(
                refreshed.detail ?? "\(kind.displayName) is not available."
            )
        }
        return executableURL
    }

    private func refreshProvider(_ kind: CLIProviderKind) async {
        let snapshot = state.withLock { state in
            (state.generation, state.isActive, state.selectedPaths[kind])
        }
        guard snapshot.1 else { return }
        let status = await makeProbe().probe(kind, selectedPath: snapshot.2)
        let codexModelOutcome = kind == .codex
            ? await loadCodexModelCatalog(using: status)
            : .notAttempted
        let antigravityModelOutcome = kind == .antigravity
            ? await loadAntigravityModelCatalog(using: status)
            : .notAttempted
        let committed = state.withLock {
            state -> (HostServices?, CodexModelCatalog?, AntigravityModelCatalog?) in
            guard state.isActive,
                  state.generation == snapshot.0,
                  state.selectedPaths[kind] == snapshot.2
            else { return (nil, nil, nil) }
            state.statuses[kind] = status
            let codexCatalogToPersist: CodexModelCatalog?
            switch codexModelOutcome {
            case .notAttempted:
                codexCatalogToPersist = nil
            case .success(let catalog):
                state.codexModelCatalog = catalog
                state.codexModelRefreshError = nil
                codexCatalogToPersist = catalog
            case .failure(let message):
                state.codexModelRefreshError = message
                codexCatalogToPersist = nil
            }
            let antigravityCatalogToPersist: AntigravityModelCatalog?
            switch antigravityModelOutcome {
            case .notAttempted:
                antigravityCatalogToPersist = nil
            case .success(let catalog):
                state.antigravityModelCatalog = catalog
                state.antigravityModelRefreshError = nil
                antigravityCatalogToPersist = catalog
            case .failure(let message):
                state.antigravityModelRefreshError = message
                antigravityCatalogToPersist = nil
            }
            return (state.host, codexCatalogToPersist, antigravityCatalogToPersist)
        }
        if let catalog = committed.1,
           let data = try? JSONEncoder().encode(catalog) {
            committed.0?.setUserDefault(data, forKey: Self.codexModelCatalogKey)
        }
        if let catalog = committed.2,
           let data = try? JSONEncoder().encode(catalog) {
            committed.0?.setUserDefault(data, forKey: Self.antigravityModelCatalogKey)
        }
        committed.0?.notifyCapabilitiesChanged()
    }

    private func loadCodexModelCatalog(
        using status: CLIProviderStatus?
    ) async -> CodexModelRefreshOutcome {
        guard let status, status.isReady, let executableURL = status.executableURL else {
            return .notAttempted
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeWhisper-Codex-Models-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failure(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        do {
            let catalog = try await codexModelCatalogLoader.loadModels(
                executableURL: executableURL,
                environment: CLIEnvironment.sanitized(
                    base: baseEnvironment,
                    kind: .codex,
                    executableURL: executableURL,
                    temporaryDirectory: workspace
                ),
                workingDirectory: workspace
            )
            return .success(catalog)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func loadAntigravityModelCatalog(
        using status: CLIProviderStatus?
    ) async -> AntigravityModelRefreshOutcome {
        guard let status, status.isReady, let executableURL = status.executableURL else {
            return .notAttempted
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeWhisper-Antigravity-Models-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failure(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        do {
            let catalog = try await antigravityModelCatalogLoader.loadModels(
                executableURL: executableURL,
                environment: CLIEnvironment.sanitized(
                    base: baseEnvironment,
                    kind: .antigravity,
                    executableURL: executableURL,
                    temporaryDirectory: workspace
                ),
                workingDirectory: workspace
            )
            return .success(catalog)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func makeProbe() -> CLIAvailabilityProbe {
        CLIAvailabilityProbe(
            runner: runner,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory
        )
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeCachedCatalog<Catalog: Decodable>(
        _ type: Catalog.Type,
        forKey key: String,
        host: HostServices
    ) -> Catalog? {
        guard let data = host.userDefault(forKey: key) as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func effortDisplayName(_ id: String) -> String {
        switch id.lowercased() {
        case "minimal": String(localized: "Minimal", bundle: .module)
        case "low": String(localized: "Low", bundle: .module)
        case "medium": String(localized: "Medium", bundle: .module)
        case "high": String(localized: "High", bundle: .module)
        case "xhigh": String(localized: "XHigh", bundle: .module)
        case "max": String(localized: "Max", bundle: .module)
        case "ultracode": String(localized: "Ultracode", bundle: .module)
        default: id.capitalized
        }
    }

    private static var screenshotStatuses: [CLIProviderKind: CLIProviderStatus] {
        let checkedAt = Date()
        return [
            .codex: CLIProviderStatus(
                kind: .codex,
                state: .ready,
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                version: "codex-cli 0.149.0",
                detail: "Installed and authenticated.",
                checkedAt: checkedAt
            ),
            .claude: CLIProviderStatus(
                kind: .claude,
                state: .missing,
                executableURL: nil,
                version: nil,
                detail: "No claude executable was found.",
                checkedAt: checkedAt
            ),
            .antigravity: CLIProviderStatus(
                kind: .antigravity,
                state: .unavailable,
                executableURL: nil,
                version: nil,
                detail: "Support follows the documented Antigravity headless CLI contract. No signed-in installation was available for a live test.",
                checkedAt: checkedAt
            ),
        ]
    }

    private static var screenshotCodexModelCatalog: CodexModelCatalog {
        CodexModelCatalog(
            models: [
                CodexCLIModel(
                    id: "gpt-5.6-sol",
                    displayName: "GPT-5.6 Sol",
                    isDefault: true,
                    supportedReasoningEfforts: [
                        CodexReasoningEffort(id: "low", description: "Fast responses"),
                        CodexReasoningEffort(id: "medium", description: "Balanced reasoning"),
                        CodexReasoningEffort(id: "high", description: "Deeper reasoning"),
                        CodexReasoningEffort(id: "xhigh", description: "Maximum reasoning depth"),
                    ],
                    defaultReasoningEffort: "low"
                ),
                CodexCLIModel(
                    id: "gpt-5.6-terra",
                    displayName: "GPT-5.6 Terra",
                    isDefault: false,
                    supportedReasoningEfforts: [
                        CodexReasoningEffort(id: "low"),
                        CodexReasoningEffort(id: "medium"),
                        CodexReasoningEffort(id: "high"),
                    ],
                    defaultReasoningEffort: "medium"
                ),
                CodexCLIModel(
                    id: "gpt-5.6-luna",
                    displayName: "GPT-5.6 Luna",
                    isDefault: false,
                    supportedReasoningEfforts: [
                        CodexReasoningEffort(id: "low"),
                        CodexReasoningEffort(id: "medium"),
                    ],
                    defaultReasoningEffort: "medium"
                ),
            ],
            defaultModelID: "gpt-5.6-sol",
            fetchedAt: Date(timeIntervalSince1970: 1_787_486_400)
        )
    }
}

private final class AuthenticatedCLIProviderRole: NSObject,
    LLMProviderPlugin,
    LLMProviderIdentityProviding,
    LLMProviderSetupStatusProviding,
    LLMModelSelectable,
    LLMEffortControllableProvider,
    @unchecked Sendable
{
    static let pluginId = AuthenticatedCLIPlugin.pluginId
    static let pluginName = AuthenticatedCLIPlugin.pluginName

    private let plugin: AuthenticatedCLIPlugin
    private let kind: CLIProviderKind

    required override init() {
        fatalError("Use init(plugin:kind:)")
    }

    init(plugin: AuthenticatedCLIPlugin, kind: CLIProviderKind) {
        self.plugin = plugin
        self.kind = kind
        super.init()
    }

    func activate(host: HostServices) {}
    func deactivate() {}
    @MainActor var settingsView: AnyView? { nil }

    var providerId: String { kind.providerID }
    var providerDisplayName: String { kind.displayName }
    var providerName: String { kind.displayName }
    var isAvailable: Bool { plugin.status(for: kind).isReady }
    var supportedModels: [PluginModelInfo] { plugin.supportedModels(for: kind) }
    @objc var defaultModelId: String? { plugin.defaultModelID(for: kind) }

    func supportedEfforts(for model: String?) -> [PluginLLMEffortInfo] {
        plugin.supportedEfforts(for: kind, model: model)
    }

    func defaultEffortId(for model: String?) -> String? {
        plugin.defaultEffortID(for: kind, model: model)
    }

    var requiresExternalCredentials: Bool { true }
    var unavailableReason: String? {
        let status = plugin.status(for: kind)
        return status.isReady ? nil : status.detail ?? "Checking CLI availability."
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        try await plugin.process(
            kind: kind,
            instruction: systemPrompt,
            input: userText,
            model: model
        )
    }

    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        effort: String?
    ) async throws -> String {
        try await plugin.process(
            kind: kind,
            instruction: systemPrompt,
            input: userText,
            model: model,
            effort: effort
        )
    }
}
