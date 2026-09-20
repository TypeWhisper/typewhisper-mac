import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

// MARK: - Server Protocol

/// Wire protocol of the Confucius4-R2T2 reference `ws_server.py`.
///
/// 1. Client opens `ws://host:8272/asr_stream_api_v1` and sends a JSON header.
/// 2. Client streams 16 kHz mono PCM16LE binary frames, then the text frame `YOUDAO_ONETIME_ASR_STREAM_EOS`.
/// 3. Server answers with JSON text frames: `{"status":"connected"}`, `{}` (keep-alive while buffering),
///    `{"status":"success","msg":{"text":"<append-only delta>","reset":Bool}}`, `{"status":"error","msg":"..."}`.
///    After EOS the server sends the final delta and closes the socket.
enum R2T2Protocol {
    static let defaultServerURL = "ws://localhost:8272/asr_stream_api_v1"
    static let defaultSecretKey = "test0102"
    static let endOfStreamMarker = "YOUDAO_ONETIME_ASR_STREAM_EOS"
    static let sampleRate = 16_000
    static let autoLanguage = "zhen"
    /// The reference client pads 0.5 s of silence so the server flushes trailing speech before EOS.
    static let trailingSilenceSeconds = 0.5

    enum ServerMessage: Equatable {
        case connected
        case keepAlive
        case text(delta: String, reset: Bool)
        case error(String)
    }

    /// ISO 639-1 code → canonical language name understood by the Qwen3-ASR / R2T2 prompt.
    static let languageNames: [String: String] = [
        "zh": "Chinese", "en": "English", "yue": "Cantonese", "ar": "Arabic", "de": "German",
        "fr": "French", "es": "Spanish", "pt": "Portuguese", "id": "Indonesian", "it": "Italian",
        "ko": "Korean", "ru": "Russian", "th": "Thai", "vi": "Vietnamese", "ja": "Japanese",
        "tr": "Turkish", "hi": "Hindi", "ms": "Malay", "nl": "Dutch", "sv": "Swedish",
        "da": "Danish", "fi": "Finnish", "pl": "Polish", "cs": "Czech", "fil": "Filipino",
        "tl": "Filipino", "fa": "Persian", "el": "Greek", "ro": "Romanian", "hu": "Hungarian",
        "mk": "Macedonian", "no": "Norwegian", "nb": "Norwegian", "uk": "Ukrainian",
    ]

    static func languageName(for code: String?) -> String {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !code.isEmpty else {
            return autoLanguage
        }
        if let name = languageNames[code] { return name }
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return languageNames[base] ?? autoLanguage
    }

    static func makeHeader(requestId: String, language: String?, secretKey: String, useVAD: Bool) -> [String: Any] {
        [
            "channels": 1,
            "sample_rate": sampleRate,
            "requestId": requestId,
            "language": languageName(for: language),
            "use_vad": useVAD,
            "secret_key": secretKey,
            "mode": "slow",
        ]
    }

    static func parseServerMessage(_ text: String) -> ServerMessage? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let status = json["status"] as? String else { return .keepAlive }
        switch status {
        case "connected":
            return .connected
        case "success":
            let msg = json["msg"] as? [String: Any]
            return .text(delta: msg?["text"] as? String ?? "", reset: msg?["reset"] as? Bool ?? false)
        case "error":
            if let message = json["msg"] as? String { return .error(message) }
            if let message = json["message"] as? String { return .error(message) }
            return .error("Unknown server error")
        default:
            return .keepAlive
        }
    }

    static func makePCM16LEData(samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func normalizedServerURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") { trimmed = "ws://" + trimmed.dropFirst("http://".count) }
        if trimmed.hasPrefix("https://") { trimmed = "wss://" + trimmed.dropFirst("https://".count) }
        if !trimmed.hasPrefix("ws://") && !trimmed.hasPrefix("wss://") { trimmed = "ws://" + trimmed }
        guard var components = URLComponents(string: trimmed), components.host != nil else { return nil }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/asr_stream_api_v1"
        }
        return components.url
    }
}

// MARK: - Transcript Collector

private actor R2T2TranscriptCollector {
    private(set) var text = ""
    private(set) var error: String?
    private(set) var isConnected = false

    func append(_ delta: String) {
        text += delta
    }

    func markConnected() {
        isConnected = true
    }

    func setError(_ message: String) {
        if error == nil { error = message }
    }
}

// MARK: - WebSocket Stream

/// One WebSocket conversation with the R2T2 server. Shared by batch and live transcription.
private final class R2T2Stream: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.typewhisper.r2t2", category: "Stream")
    private static let finishTimeout: Duration = .seconds(20)

    private let task: URLSessionWebSocketTask
    private let collector = R2T2TranscriptCollector()
    private let receiveTask: Task<Void, Never>
    private let onProgress: @Sendable (String) -> Bool
    private var sentEOS = false

    init(url: URL, header: [String: Any], onProgress: @Sendable @escaping (String) -> Bool) async throws {
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        self.task = task
        self.onProgress = onProgress

        let headerData = try JSONSerialization.data(withJSONObject: header)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw PluginTranscriptionError.apiError("Failed to encode session header")
        }
        do {
            try await task.send(.string(headerString))
        } catch {
            task.cancel(with: .abnormalClosure, reason: nil)
            throw PluginTranscriptionError.networkError(Self.describe(error, url: url))
        }

        let collector = self.collector
        receiveTask = Task { [task, collector, onProgress] in
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard case .string(let text) = message,
                          let parsed = R2T2Protocol.parseServerMessage(text) else { continue }
                    switch parsed {
                    case .connected:
                        await collector.markConnected()
                    case .keepAlive:
                        continue
                    case .text(let delta, _):
                        guard !delta.isEmpty else { continue }
                        await collector.append(delta)
                        _ = onProgress(await collector.text)
                    case .error(let message):
                        await collector.setError(message)
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                // The server closes the socket itself after the final EOS result; that is a normal end.
                if task.closeCode == .normalClosure || task.closeCode == .goingAway { return }
                if task.closeCode.rawValue == 4401 {
                    await collector.setError("Unauthorized: the R2T2 server rejected the secret key")
                    return
                }
                if task.closeCode != .invalid {
                    let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    await collector.setError("Server closed connection (code \(task.closeCode.rawValue)) \(reason)")
                    return
                }
                await collector.setError(error.localizedDescription)
            }
        }
    }

    func send(samples: [Float]) async throws {
        try await throwIfFailed()
        let pcm = R2T2Protocol.makePCM16LEData(samples: samples)
        guard !pcm.isEmpty else { return }
        do {
            try await task.send(.data(pcm))
        } catch {
            await collector.setError(error.localizedDescription)
            throw PluginTranscriptionError.networkError(error.localizedDescription)
        }
    }

    /// Sends trailing silence and the EOS marker, then waits for the server to deliver the final text and close.
    func finish() async throws -> String {
        if !sentEOS {
            sentEOS = true
            let silence = [Float](repeating: 0, count: Int(R2T2Protocol.trailingSilenceSeconds * Double(R2T2Protocol.sampleRate)))
            do {
                try await task.send(.data(R2T2Protocol.makePCM16LEData(samples: silence)))
                try await task.send(.string(R2T2Protocol.endOfStreamMarker))
            } catch {
                // If sending EOS fails we still want whatever text was already committed.
                Self.logger.warning("Failed to send EOS: \(error.localizedDescription)")
            }
        }

        let receiveTask = self.receiveTask
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await receiveTask.result; return true }
            group.addTask { try? await Task.sleep(for: Self.finishTimeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !completed {
            Self.logger.warning("Timed out waiting for the final R2T2 result")
            receiveTask.cancel()
        }
        task.cancel(with: .normalClosure, reason: nil)

        try await throwIfFailed()
        return await collector.text
    }

    func cancel() {
        receiveTask.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }

    private func throwIfFailed() async throws {
        if let error = await collector.error {
            throw PluginTranscriptionError.apiError(error)
        }
    }

    private static func describe(_ error: Error, url: URL) -> String {
        "\(error.localizedDescription) (\(url.absoluteString))"
    }
}

// MARK: - Live Session

private final class R2T2LiveTranscriptionSession: LiveTranscriptionSession, @unchecked Sendable {
    private let stream: R2T2Stream
    private let language: String?

    init(stream: R2T2Stream, language: String?) {
        self.stream = stream
        self.language = language
    }

    func appendAudio(samples: [Float]) async throws {
        try await stream.send(samples: samples)
    }

    func finish() async throws -> PluginTranscriptionResult {
        let text = try await stream.finish()
        return PluginTranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), detectedLanguage: language)
    }

    func cancel() async {
        stream.cancel()
    }
}

// MARK: - Plugin Entry Point

@objc(R2T2Plugin)
final class R2T2Plugin: NSObject, TranscriptionEnginePlugin, LiveTranscriptionCapablePlugin,
    LiveTranscriptionProgressModeProviding, @unchecked Sendable
{
    static let pluginId = "com.typewhisper.r2t2"
    static let pluginName = "Confucius4-R2T2"
    static let modelId = "confucius4-r2t2"
    static let serverURLKey = "serverURL"
    static let useVADKey = "useVAD"
    static let secretKeyKey = "secret-key"

    private let logger = Logger(subsystem: "com.typewhisper.r2t2", category: "Plugin")
    fileprivate var host: HostServices?
    fileprivate var _serverURL = R2T2Protocol.defaultServerURL
    fileprivate var _secretKey: String?
    fileprivate var _useVAD = false

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        if let stored = host.userDefault(forKey: Self.serverURLKey) as? String, !stored.isEmpty {
            _serverURL = stored
        }
        _secretKey = host.loadSecret(key: Self.secretKeyKey)
        _useVAD = host.userDefault(forKey: Self.useVADKey) as? Bool ?? false
    }

    func deactivate() {
        host = nil
    }

    // MARK: TranscriptionEnginePlugin

    var providerId: String { "r2t2" }
    var providerDisplayName: String { "Confucius4-R2T2" }
    var isConfigured: Bool { R2T2Protocol.normalizedServerURL(_serverURL) != nil }
    var transcriptionModels: [PluginModelInfo] {
        [PluginModelInfo(id: Self.modelId, displayName: "Confucius4-R2T2 (streaming)")]
    }
    var selectedModelId: String? { Self.modelId }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }
    var liveTranscriptionProgressMode: LiveTranscriptionProgressMode { .completeSnapshot }
    var supportedLanguages: [String] { Array(R2T2Protocol.languageNames.keys).sorted() }

    var serverURLString: String { _serverURL }
    var secretKey: String { _secretKey?.isEmpty == false ? _secretKey! : R2T2Protocol.defaultSecretKey }
    var isVADEnabled: Bool { _useVAD }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        try await transcribe(audio: audio, language: language, translate: translate, prompt: prompt, onProgress: { _ in true })
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        let stream = try await openStream(language: language, onProgress: onProgress)
        do {
            // 8192 bytes = 4096 samples = 256 ms; large enough to keep the server's decode loop busy.
            let chunk = 4096
            var offset = 0
            while offset < audio.samples.count {
                let end = min(offset + chunk, audio.samples.count)
                try await stream.send(samples: Array(audio.samples[offset..<end]))
                offset = end
            }
            let text = try await stream.finish()
            return PluginTranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), detectedLanguage: language)
        } catch {
            stream.cancel()
            throw error
        }
    }

    // MARK: LiveTranscriptionCapablePlugin

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        let stream = try await openStream(language: language, onProgress: onProgress)
        return R2T2LiveTranscriptionSession(stream: stream, language: language)
    }

    private func openStream(language: String?, onProgress: @Sendable @escaping (String) -> Bool) async throws -> R2T2Stream {
        guard let url = R2T2Protocol.normalizedServerURL(_serverURL) else {
            throw PluginTranscriptionError.notConfigured
        }
        let header = R2T2Protocol.makeHeader(
            requestId: UUID().uuidString,
            language: language,
            secretKey: secretKey,
            useVAD: _useVAD
        )
        return try await R2T2Stream(url: url, header: header, onProgress: onProgress)
    }

    // MARK: Settings

    var settingsView: AnyView? {
        AnyView(R2T2SettingsView(plugin: self))
    }

    fileprivate func setServerURL(_ value: String) {
        _serverURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        host?.setUserDefault(_serverURL, forKey: Self.serverURLKey)
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setSecretKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        _secretKey = trimmed.isEmpty ? nil : trimmed
        do {
            try host?.storeSecret(key: Self.secretKeyKey, value: trimmed)
        } catch {
            logger.error("Failed to store secret key: \(error.localizedDescription)")
        }
    }

    fileprivate func setVADEnabled(_ enabled: Bool) {
        guard _useVAD != enabled else { return }
        _useVAD = enabled
        host?.setUserDefault(enabled, forKey: Self.useVADKey)
    }

    /// Opens a session, sends a short silence and EOS, and reports whether the server accepted the header.
    fileprivate func testConnection() async -> String? {
        do {
            let stream = try await openStream(language: nil, onProgress: { _ in true })
            _ = try await stream.finish()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Settings View

private struct R2T2SettingsView: View {
    let plugin: R2T2Plugin
    @State private var serverURL = ""
    @State private var secretKey = ""
    @State private var showSecret = false
    @State private var vadEnabled = false
    @State private var isTesting = false
    @State private var testError: String?
    @State private var testSucceeded = false
    private let bundle = Bundle(for: R2T2Plugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Server URL", bundle: bundle)
                    .font(.headline)
                TextField(R2T2Protocol.defaultServerURL, text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { plugin.setServerURL(serverURL) }
                Text("WebSocket endpoint of the Confucius4-R2T2 ws_server.py (path /asr_stream_api_v1).", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Secret Key", bundle: bundle)
                    .font(.headline)
                HStack(spacing: 8) {
                    if showSecret {
                        TextField(R2T2Protocol.defaultSecretKey, text: $secretKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField(R2T2Protocol.defaultSecretKey, text: $secretKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        showSecret.toggle()
                    } label: {
                        Image(systemName: showSecret ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                Text("Must match secret_key_list in ws_server.py. Leave empty for the server default.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(String(localized: "Server-side VAD", bundle: bundle), isOn: $vadEnabled)
                .onChange(of: vadEnabled) { plugin.setVADEnabled(vadEnabled) }

            HStack(spacing: 8) {
                Button(String(localized: "Save", bundle: bundle)) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(String(localized: "Test Connection", bundle: bundle)) {
                    save()
                    runTest()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTesting)

                if isTesting {
                    ProgressView().controlSize(.small)
                } else if let testError {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(testError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if testSucceeded {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Connected", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Text("Audio is streamed as 16 kHz PCM to your own R2T2 server. Nothing is sent anywhere else.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            serverURL = plugin.serverURLString
            secretKey = plugin._secretKey ?? ""
            vadEnabled = plugin.isVADEnabled
        }
    }

    private func save() {
        plugin.setServerURL(serverURL.isEmpty ? R2T2Protocol.defaultServerURL : serverURL)
        plugin.setSecretKey(secretKey)
        serverURL = plugin.serverURLString
    }

    private func runTest() {
        isTesting = true
        testError = nil
        testSucceeded = false
        Task {
            let error = await plugin.testConnection()
            await MainActor.run {
                isTesting = false
                testError = error
                testSucceeded = error == nil
            }
        }
    }
}
