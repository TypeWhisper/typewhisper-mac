import SwiftUI
import TypeWhisperPluginSDK

enum SidebarStatus: Equatable {
    enum Speech: Equatable {
        case ready(engine: String)
        case downloading(progress: Double?)
        case missing
        case failed
    }
    enum AI: Equatable {
        case unconfigured, ready, usingBackup
    }

    case ready(engine: String)
    case downloading(progress: Double?)
    case noModel
    case downloadFailed
    case noAIProvider
    case usingBackup

    static func derive(speech: Speech, ai: AI) -> Self {
        switch speech {
        case .downloading(let progress): return .downloading(progress: progress.map { min(1, max(0, $0)) })
        case .missing: return .noModel
        case .failed: return .downloadFailed
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
        case .noModel: "Speech model needed"
        case .downloadFailed: "Download failed"
        case .noAIProvider: "No AI model"
        case .usingBackup: "Using backup model"
        }
    }
    var caption: String? {
        switch self {
        case .ready(let engine): engine
        case .downloading(let progress): progress?.formatted(.percent.precision(.fractionLength(0)))
        default: nil
        }
    }
    var color: Color {
        switch self {
        case .ready: DictumTheme.success
        case .downloading, .noAIProvider, .usingBackup: DictumTheme.warning
        case .noModel, .downloadFailed: DictumTheme.danger
        }
    }

    @MainActor static func current() -> Self {
        let modelManager = ServiceContainer.shared.modelManagerService
        let plugins = PluginManager.shared!
        let speech: Speech
        if let id = modelManager.selectedProviderId, let engine = plugins.transcriptionEngine(for: id) {
            let activity = (engine as? any PluginSettingsActivityReporting)?.currentSettingsActivity
            if activity?.isError == true {
                speech = .failed
            } else if let activity {
                speech = .downloading(progress: activity.progress)
            } else if modelManager.transcriptionReadinessError(providerId: id) == nil {
                speech = .ready(engine: engine.providerDisplayName)
            } else {
                speech = .missing
            }
        } else {
            speech = .missing
        }
        let processing = ServiceContainer.shared.promptProcessingService
        let configured = processing.fallbackPriorityList.filter { processing.isProviderReady($0.providerId) }
        let ai: AI = configured.isEmpty ? .unconfigured : (processing.isCurrentProviderReady ? .ready : .usingBackup)
        return derive(speech: speech, ai: ai)
    }
}
