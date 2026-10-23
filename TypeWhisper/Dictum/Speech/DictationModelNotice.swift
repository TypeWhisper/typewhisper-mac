import Foundation
import TypeWhisperPluginSDK

enum DictationModelNotice: Equatable {
    case downloading(progress: Double?)
    case loading
    case notDownloaded
    case failed(message: String)

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
        return hasDownloadedModel ? .loading : .notDownloaded
    }

    @MainActor
    static func current(providerId: String?) -> Self? {
        guard let providerId,
              let engine = PluginManager.shared.transcriptionEngine(for: providerId),
              let manager = engine as? any PluginDownloadedModelManaging else { return nil }
        return resolve(isLocal: true, isReady: engine.isConfigured,
                       hasDownloadedModel: manager.downloadedModels.contains { $0.id == engine.selectedModelId },
                       activity: (engine as? any PluginSettingsActivityReporting)?.currentSettingsActivity)
    }
}
