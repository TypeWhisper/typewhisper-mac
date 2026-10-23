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

    var byteCounts: String {
        let completed = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(completed) / \(total)"
    }
}
