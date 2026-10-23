import Foundation
import TypeWhisperPluginSDK

enum DictationModelNotice: Equatable {
    case downloading(progress: Double?)
    case loading
    case notDownloaded
    case failed(message: String)

    var errorMessage: String {
        switch self {
        case .downloading: String(localized: "The speech model is downloading.", table: "DictumSpeech")
        case .loading: String(localized: "The speech model is loading.", table: "DictumSpeech")
        case .notDownloaded: String(localized: "The speech model is not downloaded.", table: "DictumSpeech")
        case .failed(let message): message
        }
    }

    static func resolve(isLocal: Bool, isReady: Bool, hasDownloadedModel: Bool,
                        activity: PluginSettingsActivity?) -> Self? {
        guard isLocal, !isReady else { return nil }
        if let activity {
            if activity.isError { return .failed(message: activity.message) }
            if let progress = activity.progress {
                return .downloading(progress: progress.isFinite ? min(1, max(0, progress)) : nil)
            }
            return hasDownloadedModel ? .loading : .downloading(progress: nil)
        }
        return hasDownloadedModel ? nil : .notDownloaded
    }

    /// 侧栏状态与听写拦截共用：只看所选模型是否已下载，另一个精度已下载不算。
    static func hasDownloadedSelectedModel(_ engine: any TranscriptionEnginePlugin) -> Bool {
        guard let manager = engine as? any PluginDownloadedModelManaging else { return true }
        return manager.downloadedModels.contains { $0.id == engine.selectedModelId }
    }

    @MainActor
    static func current(providerId: String?) -> Self? {
        guard let providerId,
              let engine = PluginManager.shared.transcriptionEngine(for: providerId),
              engine is any PluginDownloadedModelManaging else { return nil }
        return resolve(isLocal: true, isReady: engine.isConfigured,
                       hasDownloadedModel: hasDownloadedSelectedModel(engine),
                       activity: (engine as? any PluginSettingsActivityReporting)?.currentSettingsActivity)
    }
}
