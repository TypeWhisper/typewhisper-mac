import Foundation
import TypeWhisperPluginSDK

/// 本机下载型引擎的测试替身：已下载模型、所选模型和下载字节数都可以指定。
final class DownloadedModelsTestEngine: NSObject, TranscriptionEnginePlugin,
    PluginDownloadedModelManaging, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.speech-state"
    static let pluginName = "Speech State Test Plugin"

    var downloadedModels: [PluginModelInfo]
    var selectedModelId: String?
    let completedBytes: Int64

    required override init() {
        downloadedModels = []
        completedBytes = 0
        super.init()
    }

    init(downloaded: [String], selected: String?, completedBytes: Int64 = 0) {
        downloadedModels = downloaded.map { PluginModelInfo(id: $0, displayName: $0) }
        selectedModelId = selected
        self.completedBytes = completedBytes
    }

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerId: String { "mock-speech-state" }
    var providerDisplayName: String { "Mock Speech State" }
    var isConfigured: Bool { false }
    var supportsTranslation: Bool { false }
    var supportedLanguages: [String] { ["en"] }
    var transcriptionModels: [PluginModelInfo] {
        [PluginModelInfo(id: "8bit", displayName: "8bit"), PluginModelInfo(id: "6bit", displayName: "6bit")]
    }
    func selectModel(_ modelId: String) { selectedModelId = modelId }

    @objc var speechDownloadDetails: NSDictionary {
        ["completedBytes": NSNumber(value: completedBytes), "totalBytes": NSNumber(value: Int64(2_463_307_541))]
    }

    func download(_ modelId: String) {}
    func deleteDownloadedModel(_ modelId: String) async throws {}
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws
        -> PluginTranscriptionResult { PluginTranscriptionResult(text: "") }
}
