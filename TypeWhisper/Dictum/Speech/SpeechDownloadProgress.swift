import Foundation
import TypeWhisperPluginSDK

struct SpeechDownloadProgress {
    let completedBytes: Int64
    let totalBytes: Int64
    let remainingSeconds: Double?

    init?(engine: any TranscriptionEnginePlugin) {
        let selector = NSSelectorFromString("speechDownloadDetails")
        guard let object = engine as? NSObject, object.responds(to: selector),
              let values = object.perform(selector)?.takeUnretainedValue() as? NSDictionary,
              let completed = values["completedBytes"] as? NSNumber,
              let total = values["totalBytes"] as? NSNumber, total.int64Value > 1 else { return nil }
        completedBytes = completed.int64Value
        totalBytes = total.int64Value
        remainingSeconds = (values["remainingSeconds"] as? NSNumber)?.doubleValue
    }

    /// 下载失败后按设计显示已下载的大小；失败后插件仍保留字节计数。
    static func interruptedCopy(engine: any TranscriptionEnginePlugin, locale: Locale = .current) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Self(engine: engine)?.completedBytes ?? 0, countStyle: .file)
        return String(localized: LocalizedStringResource("Connection lost, \(size) downloaded", table: "DictumSpeech", locale: locale))
    }

    var byteCounts: String {
        let completed = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(completed) / \(total)"
    }
}
