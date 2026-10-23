#if DEBUG
import AppKit
import Foundation
import os
import TypeWhisperPluginSDK

@MainActor final class DictumDebugDictation {
    static let shared = DictumDebugDictation()
    private var task: Task<Void, Never>?
    private var eventMonitor: Any?
    private let pasteEventCounter = OSAllocatedUnfairLock(initialState: 0)
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "DebugDictation")

    func handle(_ url: URL) {
        if eventMonitor == nil, ProcessInfo.processInfo.arguments.contains("--audio-diagnostics") {
            let counter = pasteEventCounter
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                guard let cgEvent = event.cgEvent, event.keyCode == 9, event.modifierFlags.contains(.command) else { return }
                let sequence = counter.withLock { count in
                    if event.type == .keyDown { count += 1 }
                    return count
                }
                Logger(subsystem: AppConstants.loggerSubsystem, category: "DebugDictation").notice(
                    "Clipboard event received sequence=\(sequence, privacy: .public) source=NSEvent.globalMonitor type=\(cgEvent.type.rawValue, privacy: .public) key=\(event.keyCode, privacy: .public) pid=\(cgEvent.getIntegerValueField(.eventSourceUnixProcessID), privacy: .public) marker=\(cgEvent.getIntegerValueField(.eventSourceUserData), privacy: .public) timestamp=\(cgEvent.timestamp, privacy: .public) repeat=\(event.isARepeat, privacy: .public)"
                )
            }
        }
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
                if let mode = components.queryItems?.first(where: { $0.name == "mode" })?.value {
                    let services = ServiceContainer.shared
                    if mode == "paste" {
                        struct Receipt: Decodable { let text: String }
                        let text = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: audioURL)).text
                        let target = services.textInsertionService.captureActiveApp()
                        var trace = DictationLatencyTrace(requestUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
                        let result = try await services.textInsertionService.insertText(text, awaitPasteVerification: true)
                        if let timing = services.textInsertionService.lastInsertionTiming {
                            trace.recordInsertion(result, timing: timing)
                        }
                        try writeResult(status: "completed", text: text, error: nil, trace: trace,
                                        appBundleIdentifier: target.bundleId, to: resultURL)
                        return
                    }
                    if mode == "hotkey" {
                        guard ProcessInfo.processInfo.arguments.contains("--audio-file-manual-stop") else {
                            throw CocoaError(.featureUnsupported)
                        }
                        DictumDebugAudioConfiguration.select(audioURL)
                        let previous = services.historyService.recentRecords.first?.id
                        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
                        while ContinuousClock.now < deadline {
                            try await Task.sleep(for: .milliseconds(100))
                            guard let record = services.historyService.recentRecords.first,
                                  record.id != previous,
                                  let trace = dictation.apiDictationLatency(id: record.id), trace.isComplete,
                                  dictation.canStartAPIRecording else { continue }
                            try writeResult(status: "completed", text: record.finalText, error: nil,
                                            trace: trace, appBundleIdentifier: record.appBundleIdentifier, to: resultURL)
                            return
                        }
                        throw CocoaError(.coderValueNotFound)
                    }
                    let samples = try await services.audioFileService.loadAudioSamples(from: audioURL)
                    let text: String
                    switch mode {
                    case "file":
                        text = try await services.modelManagerService.transcribe(
                            audioSamples: samples, language: nil, task: .transcribe, engineOverrideId: "qwen3"
                        ).text
                    case "plugin":
                        guard let plugin = services.pluginManager.transcriptionEngine(for: "qwen3") else {
                            throw CocoaError(.featureUnsupported)
                        }
                        text = try await plugin.transcribe(
                            audio: AudioData(samples: samples, wavData: WavEncoder.encode(samples), duration: Double(samples.count) / 16_000),
                            language: nil, translate: false, prompt: nil
                        ).text
                    default: throw CocoaError(.featureUnsupported)
                    }
                    try writeResult(status: "completed", text: text, error: nil, to: resultURL)
                    return
                }
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
                        if !dictation.canStartAPIRecording { continue }
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
            let engine: String?
            let model: String?
            let usedLiveResult: Bool?
        }
        let inserted = trace?.insertion == .accessibility || trace?.insertion == .liveField
            || (trace?.insertion == .paste && trace?.pasteVerification == .verified)
        let data = try JSONEncoder().encode(Result(
            status: status, text: text, error: error,
            insertion: trace?.insertion?.rawValue, pasteVerification: trace?.pasteVerification?.name,
            inserted: inserted, accessibilityGranted: ServiceContainer.shared.textInsertionService.isAccessibilityGranted,
            appBundleIdentifier: appBundleIdentifier,
            engine: trace?.engine, model: trace?.model, usedLiveResult: trace?.usedLiveResult
        ))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
#endif
