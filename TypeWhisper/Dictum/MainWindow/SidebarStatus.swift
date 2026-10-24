import SwiftUI
import TypeWhisperPluginSDK

enum SidebarStatus: Equatable {
    enum Speech: Equatable {
        case ready(engine: String)
        case downloading(progress: Double?)
        case loading(engine: String)
        case missing
        case downloadFailed
        case loadFailed

        static func current(activity: PluginSettingsActivity?, readinessError: TranscriptionEngineError?,
                            hasMissingModel: Bool, engine: String) -> Self {
            if activity?.isError == true {
                return hasMissingModel ? .downloadFailed : .loadFailed
            }
            if let progress = activity?.progress { return .downloading(progress: progress) }
            if activity != nil {
                return hasMissingModel ? .downloading(progress: nil) : .loading(engine: engine)
            }
            if let readinessError {
                switch readinessError {
                case .modelDownloadFailed: return .downloadFailed
                case .modelLoadFailed: return .loadFailed
                default: return .missing
                }
            }
            if hasMissingModel { return .missing }
            return .ready(engine: engine)
        }
    }
    enum AI: Equatable {
        case unconfigured, ready, usingBackup
    }

    case ready(engine: String)
    case downloading(progress: Double?)
    case loading(engine: String)
    case noModel
    case downloadFailed
    case loadFailed
    case noAIProvider
    case usingBackup

    static func derive(speech: Speech, ai: AI) -> Self {
        switch speech {
        case .downloading(let progress): return .downloading(progress: progress.map { min(1, max(0, $0)) })
        case .missing: return .noModel
        case .downloadFailed: return .downloadFailed
        case .loadFailed: return .loadFailed
        case .loading(let engine): return .loading(engine: engine)
        case .ready(let engine):
            switch ai {
            case .unconfigured: return .noAIProvider
            case .usingBackup: return .usingBackup
            case .ready: return .ready(engine: engine)
            }
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .ready: "Ready"
        case .downloading: "Downloading"
        case .loading: "Loading model"
        case .noModel: "Speech model needed"
        case .downloadFailed: "Download failed"
        case .loadFailed: "Model load failed"
        case .noAIProvider: "No AI model"
        case .usingBackup: "Using backup model"
        }
    }
    var caption: String? {
        switch self {
        case .ready(let engine), .loading(let engine): engine
        case .downloading(let progress): progress?.formatted(.percent.precision(.fractionLength(0)))
        default: nil
        }
    }
    var color: Color {
        switch self {
        case .ready: DictumTheme.success
        case .downloading, .loading, .noAIProvider, .usingBackup: DictumTheme.warning
        case .noModel, .downloadFailed, .loadFailed: DictumTheme.danger
        }
    }

    @MainActor static func current() -> Self {
        let modelManager = ServiceContainer.shared.modelManagerService
        let plugins = PluginManager.shared!
        let speech: Speech
        if let id = modelManager.selectedProviderId, let engine = plugins.transcriptionEngine(for: id) {
            let activity = (engine as? any PluginSettingsActivityReporting)?.currentSettingsActivity
            speech = Speech.current(activity: activity,
                                    readinessError: modelManager.transcriptionReadinessError(providerId: id),
                                    hasMissingModel: !engine.isConfigured && !DictationModelNotice.hasDownloadedSelectedModel(engine),
                                    engine: engine.providerDisplayName)
        } else {
            speech = .missing
        }
        let processing = ServiceContainer.shared.promptProcessingService
        let configured = processing.fallbackPriorityList.filter { processing.isProviderReady($0.providerId) }
        let ai: AI = configured.isEmpty ? .unconfigured : (processing.isCurrentProviderReady ? .ready : .usingBackup)
        return derive(speech: speech, ai: ai)
    }
}
