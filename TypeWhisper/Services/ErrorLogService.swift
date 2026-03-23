import AVFoundation
import Foundation
import os.log

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
        let supportsTranslation: Bool
    }

    struct APIInfo: Encodable {
        let enabled: Bool
        let running: Bool
        let port: UInt16
        let loopbackOnly: Bool
        let remoteAccessAllowed: Bool
    }

    struct PluginInfo: Encodable {
        let id: String
        let name: String
        let version: String
        let enabled: Bool
        let bundled: Bool
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
        let appFormattingEnabled: Bool
        let soundFeedbackEnabled: Bool
        let spokenFeedbackEnabled: Bool
        let showMenuBarIcon: Bool
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

    let exportedAt: Date
    let app: AppInfo
    let system: SystemInfo
    let permissions: PermissionsInfo
    let model: ModelInfo
    let api: APIInfo
    let plugins: [PluginInfo]
    let settings: SettingsSnapshot
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

        return DiagnosticsReport(
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
                timeZoneIdentifier: TimeZone.current.identifier
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
                supportsTranslation: container.modelManagerService.supportsTranslation
            ),
            api: .init(
                enabled: container.apiServerViewModel.isEnabled,
                running: container.apiServerViewModel.isRunning,
                port: container.apiServerViewModel.port,
                loopbackOnly: true,
                remoteAccessAllowed: false
            ),
            plugins: pluginManager.loadedPlugins.map {
                .init(
                    id: $0.manifest.id,
                    name: $0.manifest.name,
                    version: $0.manifest.version,
                    enabled: $0.isEnabled,
                    bundled: $0.isBundled
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
                appFormattingEnabled: defaults.bool(forKey: UserDefaultsKeys.appFormattingEnabled),
                soundFeedbackEnabled: defaults.object(forKey: UserDefaultsKeys.soundFeedbackEnabled) as? Bool ?? true,
                spokenFeedbackEnabled: defaults.bool(forKey: UserDefaultsKeys.spokenFeedbackEnabled),
                showMenuBarIcon: defaults.object(forKey: UserDefaultsKeys.showMenuBarIcon) as? Bool ?? true,
                watchFolderAutoStart: defaults.bool(forKey: UserDefaultsKeys.watchFolderAutoStart),
                setupWizardCompleted: defaults.bool(forKey: UserDefaultsKeys.setupWizardCompleted),
                preferredAppLanguage: defaults.string(forKey: UserDefaultsKeys.preferredAppLanguage)
            ),
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
