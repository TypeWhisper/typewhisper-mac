#if DEBUG
import AppKit
import Foundation
import os

@MainActor final class DictumDebugDictation {
    static let shared = DictumDebugDictation()
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "DebugDictation")

    func handle(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "file" })?.value,
              let output = components.queryItems?.first(where: { $0.name == "result" })?.value else { return }
        let resultURL = URL(fileURLWithPath: output).standardizedFileURL
        guard ["/tmp", "/private/tmp"].contains(resultURL.deletingLastPathComponent().path),
              resultURL.lastPathComponent.hasPrefix("dictum-dictate-") else { return }
        guard task == nil, DictationViewModel.shared.canStartAPIRecording else {
            try? writeResult(status: "failed", text: nil, error: "busy", to: resultURL)
            return
        }
        guard DictumDebugAudioConfiguration.launchFileURL != nil else {
            try? writeResult(status: "failed", text: nil, error: "Launch with --audio-file before dictating a clip.", to: resultURL)
            return
        }
        task = Task { @MainActor in
            defer {
                DictumDebugAudioConfiguration.select(nil)
                task = nil
            }
            do {
                let audioURL = URL(fileURLWithPath: path)
                guard FileManager.default.isReadableFile(atPath: path) else { throw CocoaError(.fileReadNoSuchFile) }
                let dictation = DictationViewModel.shared
                guard dictation.canStartAPIRecording else { throw CocoaError(.userCancelled) }
                DictumDebugAudioConfiguration.select(audioURL)
                let sessionID = await dictation.apiStartRecordingAwaitingReadiness()
                logger.notice("Debug dictation started session=\(sessionID.uuidString, privacy: .public)")
                let deadline = ContinuousClock.now.advanced(by: .seconds(180))
                while ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                    guard let session = dictation.apiDictationSession(id: sessionID) else { continue }
                    switch session.status {
                    case .completed:
                        let trace = dictation.apiDictationLatency(id: sessionID)
                        if trace?.isComplete == false { continue }
                        try writeResult(status: "completed", text: session.transcription?.text, error: nil,
                                        trace: trace, appBundleIdentifier: session.transcription?.appBundleIdentifier, to: resultURL)
                        logger.notice("Debug dictation completed session=\(sessionID.uuidString, privacy: .public)")
                        return
                    case .failed:
                        try writeResult(status: "failed", text: session.transcription?.text, error: session.error, to: resultURL)
                        return
                    default: continue
                    }
                }
                if dictation.state == .recording { _ = dictation.apiStopRecording() }
                throw CocoaError(.coderValueNotFound)
            } catch {
                try? writeResult(status: "failed", text: nil, error: error.localizedDescription, to: resultURL)
                logger.error("Debug dictation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func writeResult(status: String, text: String?, error: String?, trace: DictationLatencyTrace? = nil,
                             appBundleIdentifier: String? = nil, to url: URL) throws {
        struct Result: Encodable {
            let status: String
            let text: String?
            let error: String?
            let insertion: String?
            let pasteVerification: String?
            let inserted: Bool
            let accessibilityGranted: Bool
            let appBundleIdentifier: String?
        }
        let inserted = trace?.insertion == .accessibility || trace?.insertion == .liveField
            || (trace?.insertion == .paste && trace?.pasteVerification == .verified)
        let data = try JSONEncoder().encode(Result(
            status: status, text: text, error: error,
            insertion: trace?.insertion?.rawValue, pasteVerification: trace?.pasteVerification?.name,
            inserted: inserted, accessibilityGranted: ServiceContainer.shared.textInsertionService.isAccessibilityGranted,
            appBundleIdentifier: appBundleIdentifier
        ))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
#endif
