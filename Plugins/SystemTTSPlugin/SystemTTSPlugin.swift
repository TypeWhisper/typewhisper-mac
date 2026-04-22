import AppKit
import Foundation
import SwiftUI
import TypeWhisperPluginSDK
import os

private enum SystemTTSPluginDefaultsKey {
    static let voiceId = "voiceId"
    static let rateWPM = "rateWPM"
}

private enum SystemTTSPluginError: LocalizedError {
    case unavailable
    case processLaunchFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "System voice is unavailable."
        case .processLaunchFailed:
            return "System voice playback could not be started."
        }
    }
}

private final class SystemTTSPlaybackSession: TTSPlaybackSession, @unchecked Sendable {
    private struct State {
        var isActive = true
        var onFinish: (@Sendable () -> Void)?
    }

    private let process: Process
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }
    }

    var isActive: Bool {
        state.withLock { $0.isActive }
    }

    var onFinish: (@Sendable () -> Void)? {
        get { state.withLock { $0.onFinish } }
        set {
            let shouldNotify = state.withLock { state in
                state.onFinish = newValue
                return !state.isActive
            }
            if shouldNotify {
                newValue?()
            }
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
        finish()
    }

    private func finish() {
        let callback: (@Sendable () -> Void)? = state.withLock { state in
            guard state.isActive else { return nil }
            state.isActive = false
            return state.onFinish
        }
        callback?()
    }
}

@objc(SystemTTSPlugin)
final class SystemTTSPlugin: NSObject, TTSProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tts.system"
    static let pluginName = "System Voice"

    private let logger = Logger(subsystem: "com.typewhisper.tts.system", category: "Plugin")
    private var host: HostServices?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
    }

    func deactivate() {
        host = nil
    }

    var providerId: String { "systemTTS" }
    var providerDisplayName: String { String(localized: "System Voice") }
    var isConfigured: Bool { host != nil }

    var availableVoices: [PluginVoiceInfo] {
        NSSpeechSynthesizer.availableVoices.compactMap { voiceIdentifier in
            let attributes = NSSpeechSynthesizer.attributes(forVoice: voiceIdentifier)
            let voiceID = voiceIdentifier.rawValue
            let displayName = attributes[.name] as? String ?? voiceID
            let localeIdentifier = attributes[.localeIdentifier] as? String
            return PluginVoiceInfo(id: voiceID, displayName: displayName, localeIdentifier: localeIdentifier)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var selectedVoiceId: String? {
        host?.userDefault(forKey: SystemTTSPluginDefaultsKey.voiceId) as? String
    }

    var selectedRateWPM: Int? {
        if let value = host?.userDefault(forKey: SystemTTSPluginDefaultsKey.rateWPM) as? Int {
            return value
        }
        if let value = host?.userDefault(forKey: SystemTTSPluginDefaultsKey.rateWPM) as? Double {
            return Int(value)
        }
        return nil
    }

    var settingsSummary: String? {
        let voiceLabel = if let voice = selectedVoice {
            voice.displayName
        } else {
            String(localized: "System Default")
        }

        let rateLabel = if let rate = selectedRateWPM {
            String(localized: "\(rate) WPM")
        } else {
            String(localized: "System Default")
        }

        return String(localized: "Voice: \(voiceLabel) • Speed: \(rateLabel)")
    }

    nonisolated var settingsView: AnyView? {
        AnyView(SystemTTSSettingsView(plugin: self))
    }

    func selectVoice(_ voiceId: String?) {
        host?.setUserDefault(voiceId, forKey: SystemTTSPluginDefaultsKey.voiceId)
    }

    func selectRate(_ rateWPM: Int?) {
        host?.setUserDefault(rateWPM, forKey: SystemTTSPluginDefaultsKey.rateWPM)
    }

    func speak(_ request: TTSSpeakRequest) async throws -> any TTSPlaybackSession {
        guard host != nil else {
            throw SystemTTSPluginError.unavailable
        }

        let process = Process()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = sayArguments()
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let session = SystemTTSPlaybackSession(process: process)

        do {
            try process.run()
            if let data = request.text.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()
            return session
        } catch {
            logger.error("Failed to launch say: \(error.localizedDescription)")
            inputPipe.fileHandleForWriting.closeFile()
            throw SystemTTSPluginError.processLaunchFailed
        }
    }

    private var selectedVoice: PluginVoiceInfo? {
        guard let selectedVoiceId else { return nil }
        return availableVoices.first { $0.id == selectedVoiceId }
    }

    private func sayArguments() -> [String] {
        var arguments: [String] = []
        if let selectedVoiceId, !selectedVoiceId.isEmpty {
            arguments.append(contentsOf: ["-v", selectedVoiceId])
        }
        if let selectedRateWPM {
            arguments.append(contentsOf: ["-r", String(selectedRateWPM)])
        }
        arguments.append(contentsOf: ["-f", "-"])
        return arguments
    }
}

private struct SystemTTSSettingsView: View {
    let plugin: SystemTTSPlugin

    @State private var selectedVoiceId: String?
    @State private var rateWPM: Double

    init(plugin: SystemTTSPlugin) {
        self.plugin = plugin
        _selectedVoiceId = State(initialValue: plugin.selectedVoiceId)
        _rateWPM = State(initialValue: Double(plugin.selectedRateWPM ?? 175))
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Voice"), selection: Binding(
                    get: { selectedVoiceId },
                    set: { newValue in
                        selectedVoiceId = newValue
                        plugin.selectVoice(newValue)
                    }
                )) {
                    Text(String(localized: "System Default")).tag(Optional<String>.none)
                    ForEach(plugin.availableVoices, id: \.id) { voice in
                        Text(voice.displayName).tag(Optional(voice.id))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(localized: "Speed"))
                        Spacer()
                        if plugin.selectedRateWPM == nil {
                            Text(String(localized: "System Default"))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(Int(rateWPM)) WPM")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Slider(
                        value: Binding(
                            get: { rateWPM },
                            set: { newValue in
                                let rounded = round(newValue / 5) * 5
                                rateWPM = rounded
                                plugin.selectRate(Int(rounded))
                            }
                        ),
                        in: 100...300,
                        step: 5
                    )

                    Button(String(localized: "Use System Default Speed")) {
                        rateWPM = 175
                        plugin.selectRate(nil)
                    }
                    .font(.caption)
                }
            } footer: {
                Text(String(localized: "Uses macOS text-to-speech via the built-in system voice."))
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 420, minHeight: 220)
    }
}
