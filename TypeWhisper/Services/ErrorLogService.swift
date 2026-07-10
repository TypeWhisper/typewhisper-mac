import AVFoundation
import CryptoKit
import Darwin
import Foundation
import os.log
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "ErrorLogService")

enum DiagnosticBundlePathKind: String, Encodable, Equatable {
    case systemApplications
    case userApplications
    case development
    case temporary
    case other
}

enum DiagnosticPluginSourceKind: String, Encodable, Equatable {
    case bundled
    case managedExternal
    case externalOther
}

struct DiagnosticExecutableInfo: Encodable, Equatable {
    let sizeBytes: Int64?
    let sha256: String?
}

struct DiagnosticPluginSourceInfo: Encodable, Equatable {
    let sourceKind: DiagnosticPluginSourceKind
    let pathHint: String
    let bundleIdentifier: String?
    let bundleShortVersion: String?
    let bundleVersion: String?
    let executableSizeBytes: Int64?
    let executableSHA256: String?
}

struct DiagnosticPluginActivityInfo: Encodable, Equatable {
    let message: String
    let progress: Double?
    let isError: Bool

    init(_ activity: PluginSettingsActivity) {
        self.message = activity.message
        self.progress = activity.progress
        self.isError = activity.isError
    }
}

struct DiagnosticWorkflowSnapshot: Encodable, Equatable {
    let totalCount: Int
    let enabledCount: Int
    let defaultLLMProviderId: String?
    let defaultLLMCloudModel: String?
    let enabledWorkflows: [DiagnosticWorkflowInfo]
}

struct DiagnosticWorkflowInfo: Encodable, Equatable {
    let name: String
    let template: String
    let triggerKind: String
    let triggerAppBundleIdentifierCount: Int
    let triggerWebsitePatternCount: Int
    let triggerHotkeyCount: Int
    let hotkeyBehavior: String?
    let outputFormat: String?
    let outputAutoEnter: Bool
    let targetActionPluginId: String?
    let llmProviderId: String?
    let llmCloudModel: String?
    let transcriptionEngineId: String?
    let transcriptionModelId: String?
    let hasCustomInstruction: Bool
    let hasFineTuning: Bool
    let usesAppleTranslate: Bool
}

enum PluginDiagnosticsSupport {
    static func appBundlePathKind(
        for bundleURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isDevelopment: Bool = AppConstants.isDevelopment
    ) -> DiagnosticBundlePathKind {
        let path = bundleURL.standardizedFileURL.path
        let homePath = homeDirectory.standardizedFileURL.path

        if isDevelopment || path.contains("/DerivedData/") {
            return .development
        }
        if path.hasPrefix(homePath + "/Applications/") {
            return .userApplications
        }
        if path.hasPrefix("/Applications/") {
            return .systemApplications
        }
        if path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/private/var/folders/") {
            return .temporary
        }
        return .other
    }

    static func pluginSourceKind(
        sourceURL: URL,
        builtInPluginsURL: URL?,
        pluginsDirectory: URL
    ) -> DiagnosticPluginSourceKind {
        let sourcePath = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
        if let builtInPath = builtInPluginsURL?.resolvingSymlinksInPath().standardizedFileURL.path,
           sourcePath.hasPrefix(builtInPath + "/") || sourcePath == builtInPath {
            return .bundled
        }

        let pluginsPath = pluginsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        if sourcePath.hasPrefix(pluginsPath + "/") || sourcePath == pluginsPath {
            return .managedExternal
        }

        return .externalOther
    }

    static func pathHint(
        for url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let homePath = homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~" + String(path.dropFirst(homePath.count))
        }
        return path
    }

    static func sourceInfo(
        bundle: Bundle?,
        sourceURL: URL,
        builtInPluginsURL: URL?,
        pluginsDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> DiagnosticPluginSourceInfo {
        let executableInfo = await executableInfo(bundle: bundle, sourceURL: sourceURL)
        let infoDictionary = bundle?.infoDictionary ?? bundleInfoDictionary(sourceURL: sourceURL)
        return DiagnosticPluginSourceInfo(
            sourceKind: pluginSourceKind(
                sourceURL: sourceURL,
                builtInPluginsURL: builtInPluginsURL,
                pluginsDirectory: pluginsDirectory
            ),
            pathHint: pathHint(for: sourceURL, homeDirectory: homeDirectory),
            bundleIdentifier: bundle?.bundleIdentifier ?? infoDictionary["CFBundleIdentifier"] as? String,
            bundleShortVersion: infoDictionary["CFBundleShortVersionString"] as? String,
            bundleVersion: infoDictionary["CFBundleVersion"] as? String,
            executableSizeBytes: executableInfo.sizeBytes,
            executableSHA256: executableInfo.sha256
        )
    }

    static func executableInfo(bundle: Bundle?, sourceURL: URL) async -> DiagnosticExecutableInfo {
        guard let executableURL = executableURL(bundle: bundle, sourceURL: sourceURL) else {
            return DiagnosticExecutableInfo(sizeBytes: nil, sha256: nil)
        }

        let size = (try? executableURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return DiagnosticExecutableInfo(sizeBytes: size, sha256: await sha256HexDigest(for: executableURL))
    }

    private static func executableURL(bundle: Bundle?, sourceURL: URL) -> URL? {
        if let executableURL = bundle?.executableURL {
            return executableURL
        }

        let executableName = (bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String)
            ?? bundleInfoDictionary(sourceURL: sourceURL)["CFBundleExecutable"] as? String
        if let executableName {
            return sourceURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent(executableName)
        }

        return nil
    }

    private static func bundleInfoDictionary(sourceURL: URL) -> [String: Any] {
        let infoPlistURL = sourceURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    private static func sha256HexDigest(for url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }

            var hasher = SHA256()
            while true {
                do {
                    guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
                    hasher.update(data: chunk)
                } catch {
                    return nil
                }
            }

            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

private enum DiagnosticProcessMemorySupport {
    static func snapshot() -> DiagnosticsReport.ProcessMemoryInfo {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return DiagnosticsReport.ProcessMemoryInfo(
                residentSizeBytes: nil,
                physicalFootprintBytes: nil
            )
        }

        return DiagnosticsReport.ProcessMemoryInfo(
            residentSizeBytes: UInt64(info.resident_size),
            physicalFootprintBytes: UInt64(info.phys_footprint)
        )
    }
}

private struct DiagnosticsReport: Encodable {
    struct AppInfo: Encodable {
        let version: String
        let build: String
        let bundleIdentifier: String
        let isDevelopment: Bool
        let bundlePathKind: DiagnosticBundlePathKind
        let launchTimestamp: Date
        let uptimeSeconds: Double
    }

    struct SystemInfo: Encodable {
        let macOSVersion: String
        let localeIdentifier: String
        let timeZoneIdentifier: String
        let cpuArchitecture: String
    }

    struct PermissionsInfo: Encodable {
        let microphoneGranted: Bool
        let accessibilityGranted: Bool
    }

    struct ModelInfo: Encodable {
        let selectedProviderId: String?
        let selectedModelId: String?
        let isModelReady: Bool
        let supportsStreaming: Bool
        let supportsLiveTranscriptionSession: Bool
        let allowsTranscriptPreviewFallback: Bool
        let supportsTranslation: Bool
    }

    struct APIInfo: Encodable {
        let enabled: Bool
        let running: Bool
        let port: UInt16
        let loopbackOnly: Bool
        let remoteAccessAllowed: Bool
    }

    struct ProcessMemoryInfo: Encodable, Equatable {
        let residentSizeBytes: UInt64?
        let physicalFootprintBytes: UInt64?
    }

    struct PluginRuntimeMemoryInfo: Encodable, Equatable {
        let runtimeIdentifier: String
        let activeMemoryBytes: Int
        let cacheMemoryBytes: Int
        let peakMemoryBytes: Int

        init(_ snapshot: PluginRuntimeMemorySnapshot) {
            self.runtimeIdentifier = snapshot.runtimeIdentifier
            self.activeMemoryBytes = snapshot.activeMemoryBytes
            self.cacheMemoryBytes = snapshot.cacheMemoryBytes
            self.peakMemoryBytes = snapshot.peakMemoryBytes
        }
    }

    struct AudioOutputInfo: Encodable {
        let deviceID: UInt32
        let uid: String?
        let name: String?
        let volume: Float
        let transportType: String?
    }

    struct AudioInfo: Encodable {
        let selectedInputDeviceUID: String?
        let selectedInputDeviceName: String?
        let audioDuckingEnabled: Bool
        let audioDuckingLevel: Double
        let mediaPauseEnabled: Bool
        let defaultOutput: AudioOutputInfo?
        let inputDiagnostics: AudioInputDiagnosticsReport
    }

    struct PluginInfo: Encodable {
        let id: String
        let name: String
        let version: String
        let enabled: Bool
        let bundled: Bool
        let runtimeLoaded: Bool
        let providerId: String?
        let selectedModelId: String?
        let isConfigured: Bool?
        let supportsStreaming: Bool?
        let supportsLiveTranscriptionSession: Bool?
        let allowsTranscriptPreviewFallback: Bool?
        let storedSelectedModelId: String?
        let storedLoadedModelId: String?
        let storedSelectedVersion: String?
        let source: DiagnosticPluginSourceInfo
        let currentSettingsActivity: DiagnosticPluginActivityInfo?
        let runtimeMemory: PluginRuntimeMemoryInfo?
        let registryVersion: String?
        let registrySource: String?
        let externalBundleNotice: String?
    }

    struct SkippedExternalBundleInfo: Encodable {
        let id: String
        let name: String
        let version: String
        let reason: String
        let source: DiagnosticPluginSourceInfo
        let registryVersion: String?
        let registrySource: String?
        let externalBundleNotice: String?
    }

    struct SettingsSnapshot: Encodable {
        let bundledReleaseChannel: String
        let selectedUpdateChannel: String
        let selectedLanguage: String?
        let selectedTask: String?
        let translationEnabled: Bool
        let translationTargetLanguage: String?
        let historyRetentionDays: Int
        let saveAudioWithHistory: Bool
        let memoryEnabled: Bool
        let memoryCaptureScope: String
        let appFormattingEnabled: Bool
        let modelAutoUnloadSeconds: Int
        let modelAutoUnloadPolicy: String
        let indicatorStyle: String
        let indicatorSupportsTranscriptPreview: Bool
        let indicatorTranscriptPreviewEnabled: Bool
        let indicatorTranscriptPreviewAvailable: Bool
        let indicatorTranscriptPreviewFontSizeOffset: Int
        let notchIndicatorVisibility: String
        let notchIndicatorDisplay: String
        let overlayPosition: String
        let externalStreamingDisplayCount: Int?
        let soundFeedbackEnabled: Bool
        let spokenFeedbackEnabled: Bool
        let showMenuBarIcon: Bool
        let dockIconBehaviorWhenMenuBarHidden: String
        let watchFolderAutoStart: Bool
        let setupWizardCompleted: Bool
        let preferredAppLanguage: String?
    }

    struct Counts: Encodable {
        let historyRecords: Int
        let profiles: Int
        let enabledProfiles: Int
        let dictionaryTerms: Int
        let dictionaryCorrections: Int
        let snippets: Int
        let enabledSnippets: Int
        let errorEntries: Int
    }

    struct ErrorEntrySnapshot: Encodable {
        let timestamp: Date
        let category: String
        let message: String
    }

    let schemaVersion: Int
    let exportedAt: Date
    let app: AppInfo
    let system: SystemInfo
    let permissions: PermissionsInfo
    let secureInput: SecureInputDiagnostics
    let model: ModelInfo
    let api: APIInfo
    let processMemory: ProcessMemoryInfo
    let modelAutoUnload: ModelAutoUnloadDiagnosticsSnapshot
    let memoryExtraction: MemoryExtractionDiagnosticsSnapshot
    let audio: AudioInfo
    let plugins: [PluginInfo]
    let skippedExternalBundles: [SkippedExternalBundleInfo]
    let workflows: DiagnosticWorkflowSnapshot
    let settings: SettingsSnapshot
    let lastIndicatorFullscreenSuppression: IndicatorFullscreenSuppressionDiagnostics?
    let counts: Counts
    let errors: [ErrorEntrySnapshot]
}

@MainActor
final class ErrorLogService: ObservableObject {
    @Published private(set) var entries: [ErrorLogEntry] = []

    private static let maxEntries = 200
    private let fileURL: URL
    private let launchTimestamp = Date()

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        let dir = appSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("error-log.json")
        loadEntries()
    }

    func addEntry(message: String, category: String = "general") {
        let entry = ErrorLogEntry(message: message, category: category)
        entries.insert(entry, at: 0)

        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }

        saveEntries()
        logger.info("Error logged: [\(category)] \(message)")
    }

    func clearAll() {
        entries.removeAll()
        saveEntries()
    }

    func exportDiagnostics(to url: URL) async throws {
        let report = await diagnosticsReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try await Task.detached(priority: .utility) {
            try data.write(to: url, options: .atomic)
        }.value
    }

    private func diagnosticsReport() async -> DiagnosticsReport {
        let container = ServiceContainer.shared
        let defaults = UserDefaults.standard
        let pluginManager = PluginManager.shared ?? container.pluginManager
        let outputSnapshot = CoreAudioOutputVolumeController().defaultOutputSnapshot()
        let modelAutoUnloadSeconds = ModelAutoUnloadPolicy.effectiveSeconds(defaults: defaults)
        let indicatorStyle = DictationViewModel.loadIndicatorStyle(defaults: defaults)
        let indicatorPreviewEnabled = DictationViewModel.loadIndicatorTranscriptPreviewEnabled(defaults: defaults)
        let indicatorPreviewOffset = DictationViewModel.loadIndicatorTranscriptPreviewFontSizeOffset(defaults: defaults)

        var pluginDiagnostics: [DiagnosticsReport.PluginInfo] = []
        for loadedPlugin in pluginManager.loadedPlugins {
            let engine = loadedPlugin.instance as? TranscriptionEnginePlugin
            let fallbackPolicy = engine as? TranscriptPreviewFallbackPolicyProviding
            let allowsTranscriptPreviewFallback: Bool? = if engine != nil {
                fallbackPolicy?.allowsTranscriptPreviewFallback ?? true
            } else {
                nil
            }
            let activity = (loadedPlugin.instance as? any PluginSettingsActivityReporting)?.currentSettingsActivity
            let runtimeMemory = (loadedPlugin.instance as? any PluginRuntimeMemoryDiagnosticsReporting)?.runtimeMemorySnapshot
            let registryEntry = container.pluginRegistryService.registry.first { $0.id == loadedPlugin.manifest.id }
            let externalNotice = pluginManager.externalBundleNotice(
                for: loadedPlugin.manifest.id,
                registryPlugin: registryEntry
            )
            let pluginSource = await PluginDiagnosticsSupport.sourceInfo(
                bundle: loadedPlugin.bundle,
                sourceURL: loadedPlugin.sourceURL,
                builtInPluginsURL: Bundle.main.builtInPlugInsURL,
                pluginsDirectory: pluginManager.pluginsDirectory
            )

            pluginDiagnostics.append(DiagnosticsReport.PluginInfo(
                id: loadedPlugin.manifest.id,
                name: loadedPlugin.manifest.name,
                version: loadedPlugin.manifest.version,
                enabled: loadedPlugin.isEnabled,
                bundled: loadedPlugin.isBundled,
                runtimeLoaded: loadedPlugin.isRuntimeLoaded,
                providerId: engine?.providerId,
                selectedModelId: engine?.selectedModelId,
                isConfigured: engine?.isConfigured,
                supportsStreaming: engine?.supportsStreaming,
                supportsLiveTranscriptionSession: engine.map { $0 is LiveTranscriptionCapablePlugin },
                allowsTranscriptPreviewFallback: allowsTranscriptPreviewFallback,
                storedSelectedModelId: defaults.string(forKey: Self.pluginDefaultKey(pluginId: loadedPlugin.manifest.id, key: "selectedModel")),
                storedLoadedModelId: defaults.string(forKey: Self.pluginDefaultKey(pluginId: loadedPlugin.manifest.id, key: "loadedModel")),
                storedSelectedVersion: defaults.string(forKey: Self.pluginDefaultKey(pluginId: loadedPlugin.manifest.id, key: "selectedVersion")),
                source: pluginSource,
                currentSettingsActivity: activity.map(DiagnosticPluginActivityInfo.init),
                runtimeMemory: runtimeMemory.map(DiagnosticsReport.PluginRuntimeMemoryInfo.init),
                registryVersion: registryEntry?.version,
                registrySource: registryEntry?.source.rawValue,
                externalBundleNotice: externalNotice?.diagnosticsValue
            ))
        }

        var skippedExternalBundleDiagnostics: [DiagnosticsReport.SkippedExternalBundleInfo] = []
        for bundle in pluginManager.incompatibleExternalBundles.values.sorted(by: { $0.pluginName < $1.pluginName }) {
            let registryEntry = container.pluginRegistryService.registry.first(where: { $0.id == bundle.pluginId })
            let pluginSource = await PluginDiagnosticsSupport.sourceInfo(
                bundle: Bundle(url: bundle.bundleURL),
                sourceURL: bundle.bundleURL,
                builtInPluginsURL: Bundle.main.builtInPlugInsURL,
                pluginsDirectory: pluginManager.pluginsDirectory
            )
            skippedExternalBundleDiagnostics.append(DiagnosticsReport.SkippedExternalBundleInfo(
                id: bundle.pluginId,
                name: bundle.pluginName,
                version: bundle.version,
                reason: bundle.reason.diagnosticsValue,
                source: pluginSource,
                registryVersion: registryEntry?.version,
                registrySource: registryEntry?.source.rawValue,
                externalBundleNotice: PluginManager.externalBundleNotice(
                    loadedPlugin: pluginManager.loadedPlugins.first(where: { $0.manifest.id == bundle.pluginId }),
                    registryPlugin: registryEntry,
                    incompatibleExternalBundle: bundle
                )?.diagnosticsValue
            ))
        }

        return DiagnosticsReport(
            schemaVersion: 8,
            exportedAt: Date(),
            app: .init(
                version: AppConstants.appVersion,
                build: AppConstants.buildVersion,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.typewhisper.mac",
                isDevelopment: AppConstants.isDevelopment,
                bundlePathKind: PluginDiagnosticsSupport.appBundlePathKind(
                    for: Bundle.main.bundleURL
                ),
                launchTimestamp: launchTimestamp,
                uptimeSeconds: Date().timeIntervalSince(launchTimestamp)
            ),
            system: .init(
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                localeIdentifier: Locale.current.identifier,
                timeZoneIdentifier: TimeZone.current.identifier,
                cpuArchitecture: RuntimeArchitecture.current
            ),
            permissions: .init(
                microphoneGranted: AVAudioApplication.shared.recordPermission == .granted,
                accessibilityGranted: container.textInsertionService.isAccessibilityGranted
            ),
            secureInput: SecureInputDiagnosticsProvider.snapshot(),
            model: .init(
                selectedProviderId: container.modelManagerService.selectedProviderId,
                selectedModelId: container.modelManagerService.selectedModelId,
                isModelReady: container.modelManagerService.isModelReady,
                supportsStreaming: container.modelManagerService.supportsStreaming,
                supportsLiveTranscriptionSession: container.modelManagerService.supportsLiveTranscriptionSession(),
                allowsTranscriptPreviewFallback: container.modelManagerService.allowsTranscriptPreviewFallback(),
                supportsTranslation: container.modelManagerService.supportsTranslation
            ),
            api: .init(
                enabled: container.apiServerViewModel.isEnabled,
                running: container.apiServerViewModel.isRunning,
                port: container.apiServerViewModel.port,
                loopbackOnly: true,
                remoteAccessAllowed: false
            ),
            processMemory: DiagnosticProcessMemorySupport.snapshot(),
            modelAutoUnload: container.modelManagerService.autoUnloadDiagnosticsSnapshot(),
            memoryExtraction: container.memoryService.extractionDiagnosticsSnapshot(),
            audio: .init(
                selectedInputDeviceUID: defaults.string(forKey: UserDefaultsKeys.selectedInputDeviceUID),
                selectedInputDeviceName: container.audioDeviceService.selectedDevice?.name,
                audioDuckingEnabled: defaults.bool(forKey: UserDefaultsKeys.audioDuckingEnabled),
                audioDuckingLevel: defaults.object(forKey: UserDefaultsKeys.audioDuckingLevel) as? Double ?? 0.2,
                mediaPauseEnabled: defaults.bool(forKey: UserDefaultsKeys.mediaPauseEnabled),
                defaultOutput: outputSnapshot.map {
                    .init(
                        deviceID: $0.deviceID,
                        uid: $0.deviceUID,
                        name: $0.deviceName,
                        volume: $0.volume,
                        transportType: $0.transportType
                    )
                },
                inputDiagnostics: container.audioDeviceService.diagnosticsReport()
            ),
            plugins: pluginDiagnostics,
            skippedExternalBundles: skippedExternalBundleDiagnostics,
            workflows: Self.workflowDiagnosticsSnapshot(
                from: container.workflowService,
                promptProcessingService: container.promptProcessingService
            ),
            settings: .init(
                bundledReleaseChannel: AppConstants.releaseChannel.rawValue,
                selectedUpdateChannel: AppConstants.effectiveUpdateChannel.rawValue,
                selectedLanguage: defaults.string(forKey: UserDefaultsKeys.selectedLanguage),
                selectedTask: defaults.string(forKey: UserDefaultsKeys.selectedTask),
                translationEnabled: defaults.bool(forKey: UserDefaultsKeys.translationEnabled),
                translationTargetLanguage: defaults.string(forKey: UserDefaultsKeys.translationTargetLanguage),
                historyRetentionDays: defaults.integer(forKey: UserDefaultsKeys.historyRetentionDays),
                saveAudioWithHistory: defaults.bool(forKey: UserDefaultsKeys.saveAudioWithHistory),
                memoryEnabled: defaults.bool(forKey: UserDefaultsKeys.memoryEnabled),
                memoryCaptureScope: MemoryCaptureScope.load(from: defaults).rawValue,
                appFormattingEnabled: defaults.bool(forKey: UserDefaultsKeys.appFormattingEnabled),
                modelAutoUnloadSeconds: modelAutoUnloadSeconds,
                modelAutoUnloadPolicy: ModelAutoUnloadPolicy.policyName(seconds: modelAutoUnloadSeconds),
                indicatorStyle: indicatorStyle.rawValue,
                indicatorSupportsTranscriptPreview: indicatorStyle.supportsTranscriptPreview,
                indicatorTranscriptPreviewEnabled: indicatorPreviewEnabled,
                indicatorTranscriptPreviewAvailable: indicatorStyle.supportsTranscriptPreview && indicatorPreviewEnabled,
                indicatorTranscriptPreviewFontSizeOffset: indicatorPreviewOffset,
                notchIndicatorVisibility: defaults.string(forKey: UserDefaultsKeys.notchIndicatorVisibility) ?? NotchIndicatorVisibility.duringActivity.rawValue,
                notchIndicatorDisplay: defaults.string(forKey: UserDefaultsKeys.notchIndicatorDisplay) ?? NotchIndicatorDisplay.activeScreen.rawValue,
                overlayPosition: defaults.string(forKey: UserDefaultsKeys.overlayPosition) ?? OverlayPosition.top.rawValue,
                externalStreamingDisplayCount: DictationViewModel._shared?.externalStreamingDisplayCount,
                soundFeedbackEnabled: defaults.object(forKey: UserDefaultsKeys.soundFeedbackEnabled) as? Bool ?? true,
                spokenFeedbackEnabled: defaults.bool(forKey: UserDefaultsKeys.spokenFeedbackEnabled),
                showMenuBarIcon: defaults.object(forKey: UserDefaultsKeys.showMenuBarIcon) as? Bool ?? true,
                dockIconBehaviorWhenMenuBarHidden: defaults.string(forKey: UserDefaultsKeys.dockIconBehaviorWhenMenuBarHidden) ?? DockIconBehavior.keepVisible.rawValue,
                watchFolderAutoStart: defaults.bool(forKey: UserDefaultsKeys.watchFolderAutoStart),
                setupWizardCompleted: defaults.bool(forKey: UserDefaultsKeys.setupWizardCompleted),
                preferredAppLanguage: defaults.string(forKey: UserDefaultsKeys.preferredAppLanguage)
            ),
            lastIndicatorFullscreenSuppression: IndicatorFullscreenSuppressionPolicy.lastSuppressionDiagnostics(),
            counts: .init(
                historyRecords: container.historyService.records.count,
                profiles: container.profileService.profiles.count,
                enabledProfiles: container.profileService.profiles.filter(\.isEnabled).count,
                dictionaryTerms: container.dictionaryService.termsCount,
                dictionaryCorrections: container.dictionaryService.correctionsCount,
                snippets: container.snippetService.snippets.count,
                enabledSnippets: container.snippetService.enabledSnippetsCount,
                errorEntries: entries.count
            ),
            errors: entries.map {
                .init(timestamp: $0.timestamp, category: $0.category, message: $0.message)
            }
        )
    }

    static func workflowDiagnosticsSnapshot(
        from workflowService: WorkflowService,
        promptProcessingService: PromptProcessingService
    ) -> DiagnosticWorkflowSnapshot {
        let workflows = workflowService.workflows
        let enabledWorkflows = workflows.filter(\.isEnabled)
        let primaryFallbackItem = promptProcessingService.primaryFallbackItem
        return DiagnosticWorkflowSnapshot(
            totalCount: workflows.count,
            enabledCount: enabledWorkflows.count,
            defaultLLMProviderId: trimmedOrNil(primaryFallbackItem?.providerId),
            defaultLLMCloudModel: trimmedOrNil(primaryFallbackItem?.modelId),
            enabledWorkflows: enabledWorkflows.map { workflow in
                let behavior = workflow.behavior
                let output = workflow.output
                let trigger = workflow.trigger
                let explicitProviderId = trimmedOrNil(behavior.providerId)
                let inheritedFallbackItem = explicitProviderId == nil ? primaryFallbackItem : nil

                return DiagnosticWorkflowInfo(
                    name: workflow.name,
                    template: workflow.template.rawValue,
                    triggerKind: trigger?.kind.rawValue ?? workflow.triggerKindRaw,
                    triggerAppBundleIdentifierCount: trigger?.appBundleIdentifiers.count ?? 0,
                    triggerWebsitePatternCount: trigger?.websitePatterns.count ?? 0,
                    triggerHotkeyCount: trigger?.hotkeys.count ?? 0,
                    hotkeyBehavior: trigger?.hotkeyBehavior.rawValue,
                    outputFormat: trimmedOrNil(output.format),
                    outputAutoEnter: output.autoEnter,
                    targetActionPluginId: trimmedOrNil(output.targetActionPluginId),
                    llmProviderId: explicitProviderId ?? trimmedOrNil(inheritedFallbackItem?.providerId),
                    llmCloudModel: explicitProviderId == nil
                        ? trimmedOrNil(inheritedFallbackItem?.modelId)
                        : trimmedOrNil(behavior.cloudModel),
                    transcriptionEngineId: trimmedOrNil(behavior.transcriptionEngineId),
                    transcriptionModelId: trimmedOrNil(behavior.transcriptionModelId),
                    hasCustomInstruction: hasCustomWorkflowInstruction(behavior.settings),
                    hasFineTuning: trimmedOrNil(behavior.fineTuning) != nil,
                    usesAppleTranslate: workflow.usesAppleTranslate
                )
            }
        )
    }

    private static func pluginDefaultKey(pluginId: String, key: String) -> String {
        "plugin.\(pluginId).\(key)"
    }

    private static func hasCustomWorkflowInstruction(_ settings: [String: String]) -> Bool {
        ["instruction", "goal", "prompt"].contains { key in
            trimmedOrNil(settings[key]) != nil
        }
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func loadEntries() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ErrorLogEntry].self, from: data) else { return }
        entries = decoded
    }

    private func saveEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
