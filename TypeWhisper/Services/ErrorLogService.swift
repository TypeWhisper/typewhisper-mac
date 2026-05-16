import AVFoundation
import Foundation
import os.log
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "ErrorLogService")

private struct DiagnosticsReport: Encodable {
    struct AppInfo: Encodable {
        let version: String
        let build: String
        let bundleIdentifier: String
        let isDevelopment: Bool
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
    let model: ModelInfo
    let api: APIInfo
    let audio: AudioInfo
    let plugins: [PluginInfo]
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

    func exportDiagnostics(to url: URL) throws {
        let report = diagnosticsReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    private func diagnosticsReport() -> DiagnosticsReport {
        let container = ServiceContainer.shared
        let defaults = UserDefaults.standard
        let pluginManager = PluginManager.shared ?? container.pluginManager
        let outputSnapshot = CoreAudioOutputVolumeController().defaultOutputSnapshot()
        let modelAutoUnloadSeconds = defaults.integer(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        let indicatorStyle = DictationViewModel.loadIndicatorStyle(defaults: defaults)
        let indicatorPreviewEnabled = DictationViewModel.loadIndicatorTranscriptPreviewEnabled(defaults: defaults)
        let indicatorPreviewOffset = DictationViewModel.loadIndicatorTranscriptPreviewFontSizeOffset(defaults: defaults)

        return DiagnosticsReport(
            schemaVersion: 4,
            exportedAt: Date(),
            app: .init(
                version: AppConstants.appVersion,
                build: AppConstants.buildVersion,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.typewhisper.mac",
                isDevelopment: AppConstants.isDevelopment
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
            plugins: pluginManager.loadedPlugins.map {
                let engine = $0.instance as? TranscriptionEnginePlugin
                let fallbackPolicy = engine as? TranscriptPreviewFallbackPolicyProviding
                let allowsTranscriptPreviewFallback: Bool? = if engine != nil {
                    fallbackPolicy?.allowsTranscriptPreviewFallback ?? true
                } else {
                    nil
                }
                return DiagnosticsReport.PluginInfo(
                    id: $0.manifest.id,
                    name: $0.manifest.name,
                    version: $0.manifest.version,
                    enabled: $0.isEnabled,
                    bundled: $0.isBundled,
                    runtimeLoaded: $0.isRuntimeLoaded,
                    providerId: engine?.providerId,
                    selectedModelId: engine?.selectedModelId,
                    isConfigured: engine?.isConfigured,
                    supportsStreaming: engine?.supportsStreaming,
                    supportsLiveTranscriptionSession: engine.map { $0 is LiveTranscriptionCapablePlugin },
                    allowsTranscriptPreviewFallback: allowsTranscriptPreviewFallback,
                    storedSelectedModelId: defaults.string(forKey: Self.pluginDefaultKey(pluginId: $0.manifest.id, key: "selectedModel")),
                    storedLoadedModelId: defaults.string(forKey: Self.pluginDefaultKey(pluginId: $0.manifest.id, key: "loadedModel")),
                    storedSelectedVersion: defaults.string(forKey: Self.pluginDefaultKey(pluginId: $0.manifest.id, key: "selectedVersion"))
                )
            },
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
                modelAutoUnloadPolicy: Self.modelAutoUnloadPolicy(seconds: modelAutoUnloadSeconds),
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

    private static func pluginDefaultKey(pluginId: String, key: String) -> String {
        "plugin.\(pluginId).\(key)"
    }

    private static func modelAutoUnloadPolicy(seconds: Int) -> String {
        switch seconds {
        case 0:
            return "never"
        case -1:
            return "immediate"
        default:
            return "afterSeconds"
        }
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
