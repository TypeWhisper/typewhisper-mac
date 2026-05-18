import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

enum SeedASRError: Error, LocalizedError {
    case encodeFailed(String)
    case serverError(code: UInt32?, message: String)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .encodeFailed(let what): return "Encode failed: \(what)"
        case .serverError(let code, let msg): return "Volc ASR \(code.map { "code \($0): " } ?? "")\(msg)"
        case .noAudio: return "No audio captured"
        }
    }
}

private let kDefaultEndpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"
private let kDefaultResourceID = "volc.seedasr.sauc.duration"
private let kDefaultModelName = "bigmodel"
private let kSampleRate = 16000

// MARK: - Plugin Entry Point

@objc(SeedASRPlugin)
final class SeedASRPlugin: NSObject, TranscriptionEnginePlugin, LiveTranscriptionCapablePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.seed-asr"
    static let pluginName = "Seed ASR 2.0"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _resourceId: String?
    fileprivate var _boostingTableId: String?

    private let logger = Logger(subsystem: "com.typewhisper.seed-asr", category: "Plugin")

    required override init() { super.init() }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _resourceId = host.userDefault(forKey: "resourceId") as? String ?? kDefaultResourceID
        _boostingTableId = host.userDefault(forKey: "boostingTableId") as? String
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "seed-asr" }
    var providerDisplayName: String { "Seed ASR 2.0" }

    var isConfigured: Bool {
        guard let key = _apiKey, !key.isEmpty else { return false }
        guard let rid = _resourceId, !rid.isEmpty else { return false }
        return true
    }

    var transcriptionModels: [PluginModelInfo] {
        [PluginModelInfo(id: kDefaultModelName, displayName: "Seed bigmodel")]
    }

    var selectedModelId: String? { kDefaultModelName }

    func selectModel(_ modelId: String) {
        // Single-model engine; nothing to switch.
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }

    var supportedLanguages: [String] { ["zh", "zh-CN", "en"] }

    // MARK: - Transcription (one-shot: internally runs a live session)

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        try await transcribe(audio: audio, language: language, translate: translate, prompt: prompt) { _ in true }
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else { throw PluginTranscriptionError.notConfigured }
        guard let resourceId = _resourceId, !resourceId.isEmpty else { throw PluginTranscriptionError.notConfigured }
        guard !audio.samples.isEmpty else { throw SeedASRError.noAudio }

        let session = SeedASRLiveSession(apiKey: apiKey, resourceId: resourceId, boostingTableId: _boostingTableId, onProgress: onProgress)
        try await session.start()
        try await session.appendAudio(samples: audio.samples)
        return try await session.finish()
    }

    // MARK: - LiveTranscriptionCapablePlugin

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        guard let apiKey = _apiKey, !apiKey.isEmpty else { throw PluginTranscriptionError.notConfigured }
        guard let resourceId = _resourceId, !resourceId.isEmpty else { throw PluginTranscriptionError.notConfigured }

        let session = SeedASRLiveSession(apiKey: apiKey, resourceId: resourceId, boostingTableId: _boostingTableId, onProgress: onProgress)
        try await session.start()
        return session
    }

    // MARK: - Settings

    var settingsView: AnyView? {
        AnyView(SeedASRSettingsView(plugin: self))
    }

    // MARK: - Internal setters

    fileprivate func setApiKey(_ value: String) {
        _apiKey = value.isEmpty ? nil : value
        if let host {
            try? host.storeSecret(key: "api-key", value: value)
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func setResourceId(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        _resourceId = trimmed.isEmpty ? kDefaultResourceID : trimmed
        host?.setUserDefault(_resourceId, forKey: "resourceId")
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setBoostingTableId(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        _boostingTableId = trimmed.isEmpty ? nil : trimmed
        host?.setUserDefault(_boostingTableId, forKey: "boostingTableId")
    }

    fileprivate func validateConnection() async -> Bool {
        guard let apiKey = _apiKey, !apiKey.isEmpty else { return false }
        guard let resourceId = _resourceId, !resourceId.isEmpty else { return false }
        // 1 second of silence as a minimal connection ping.
        let silence = [Float](repeating: 0, count: kSampleRate)
        let session = SeedASRLiveSession(apiKey: apiKey, resourceId: resourceId, boostingTableId: nil, onProgress: { _ in true })
        do {
            try await session.start()
            try await session.appendAudio(samples: silence)
            _ = try await session.finish()
            return true
        } catch {
            logger.warning("validateConnection failed: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Live Session

private actor SeedASRLiveSession: LiveTranscriptionSession {
    private let apiKey: String
    private let resourceId: String
    private let boostingTableId: String?
    private let onProgress: @Sendable (String) -> Bool
    private let endpoint: URL

    private var wsTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sequence: Int32 = 1
    private var pendingAudio: Data = Data()
    private var didFinish = false
    private var didCancel = false
    private var finalText: String = ""
    private var lastError: Error?
    private var serverFinished = false
    private let logger = Logger(subsystem: "com.typewhisper.seed-asr", category: "Session")

    private static let chunkBytes = 6400  // 200ms at 16kHz × 2 bytes per sample

    init(apiKey: String, resourceId: String, boostingTableId: String?, onProgress: @escaping @Sendable (String) -> Bool) {
        self.apiKey = apiKey
        self.resourceId = resourceId
        self.boostingTableId = boostingTableId?.isEmpty == false ? boostingTableId : nil
        self.onProgress = onProgress
        self.endpoint = URL(string: kDefaultEndpoint)!
    }

    func start() async throws {
        let requestId = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestId, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        let task = URLSession.shared.webSocketTask(with: request)
        self.wsTask = task
        task.resume()

        var requestField: [String: Any] = [
            "model_name": kDefaultModelName,
            "enable_punc": true,
            "show_utterances": true,
        ]
        if let btid = boostingTableId {
            requestField["corpus"] = ["boosting_table_id": btid]
        }
        let initPayload: [String: Any] = [
            "user": ["uid": "typewhisper"],
            "audio": [
                "format": "pcm",
                "rate": kSampleRate,
                "bits": 16,
                "channel": 1,
                "codec": "raw",
            ],
            "request": requestField,
        ]
        let initFrame = try SeedWSProtocol.buildFullClientRequest(payload: initPayload, sequence: sequence)
        sequence += 1
        try await task.send(.data(initFrame))

        startReceiveLoop()
    }

    private func startReceiveLoop() {
        guard let task = wsTask else { return }
        let onProgress = self.onProgress
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard case .data(let data) = message else { continue }
                    let parsed = SeedWSProtocol.parseResponse(data)
                    if parsed.messageType == .serverErrorResponse {
                        let msg = (parsed.payload?["message"] as? String) ?? "server error"
                        await self?.markError(SeedASRError.serverError(code: parsed.errorCode, message: msg))
                        return
                    }
                    if let payload = parsed.payload {
                        let text = Self.extractText(from: payload)
                        if !text.isEmpty {
                            await self?.updateFinal(text)
                            _ = onProgress(text)
                        }
                    }
                    if parsed.isLast {
                        await self?.markServerFinished()
                        return
                    }
                } catch {
                    await self?.markError(error)
                    return
                }
            }
        }
    }

    func appendAudio(samples: [Float]) async throws {
        guard !didFinish, !didCancel else { return }
        guard !samples.isEmpty else { return }
        if let err = lastError { throw err }

        let pcm = SeedAudio.floatToPCM16(samples)
        pendingAudio.append(pcm)
        try await flushIfReady(forceAll: false)
    }

    private func flushIfReady(forceAll: Bool) async throws {
        guard let task = wsTask else { return }
        while pendingAudio.count >= Self.chunkBytes || (forceAll && !pendingAudio.isEmpty) {
            let take = min(Self.chunkBytes, pendingAudio.count)
            let chunk = pendingAudio.prefix(take)
            pendingAudio.removeFirst(take)
            let frame = try SeedWSProtocol.buildAudioRequest(audio: Data(chunk), sequence: sequence, isLast: false)
            sequence += 1
            try await task.send(.data(frame))
        }
    }

    func finish() async throws -> PluginTranscriptionResult {
        if didFinish {
            return PluginTranscriptionResult(text: finalText, detectedLanguage: "zh")
        }
        didFinish = true

        guard let task = wsTask else {
            throw SeedASRError.encodeFailed("ws not started")
        }
        if let err = lastError { throw err }

        // Drain pending audio, then send the empty last frame.
        try? await flushIfReady(forceAll: true)
        let lastFrame = try SeedWSProtocol.buildAudioRequest(audio: Data(), sequence: sequence, isLast: true)
        sequence += 1
        try await task.send(.data(lastFrame))

        // Wait for server final result.
        let deadline = Date().addingTimeInterval(60)
        while !serverFinished, lastError == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        receiveTask?.cancel()
        task.cancel(with: .normalClosure, reason: nil)

        if let err = lastError { throw err }
        return PluginTranscriptionResult(
            text: finalText.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: "zh"
        )
    }

    func cancel() async {
        didCancel = true
        didFinish = true
        receiveTask?.cancel()
        wsTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Internal

    private func updateFinal(_ text: String) {
        finalText = text
    }

    private func markError(_ error: Error) {
        if lastError == nil { lastError = error }
        serverFinished = true
    }

    private func markServerFinished() {
        serverFinished = true
    }

    private static func extractText(from payload: [String: Any]) -> String {
        if let result = payload["result"] as? [String: Any], let text = result["text"] as? String {
            return text
        }
        if let text = payload["text"] as? String {
            return text
        }
        return ""
    }
}

// MARK: - Settings View

private struct SeedASRSettingsView: View {
    let plugin: SeedASRPlugin
    @State private var apiKeyInput = ""
    @State private var resourceIdInput = ""
    @State private var boostingTableIdInput = ""
    @State private var showApiKey = false
    @State private var isTesting = false
    @State private var connectionResult: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key (X-Api-Key)")
                    .font(.headline)

                HStack(spacing: 8) {
                    if showApiKey {
                        TextField("X-Api-Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("X-Api-Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text("Get from console.volcengine.com → Speech Tech → Apps. Stored in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Resource ID")
                    .font(.headline)

                TextField("volc.seedasr.sauc.duration", text: $resourceIdInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Text("Default volc.seedasr.sauc.duration (2.0).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Boosting Table ID")
                    .font(.headline)

                TextField("e.g. 77c51cbd-6a0e-4570-be14-…", text: $boostingTableIdInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Text("Optional. Create a table at console.volcengine.com → Speech Tech → Hotword Management, then paste its ID here. Leave blank to disable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    test()
                } label: {
                    Text("Test Connection")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                if isTesting {
                    ProgressView().controlSize(.small)
                    Text("Testing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let result = connectionResult {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result ? .green : .red)
                    Text(result ? "Connected" : "Connection Failed")
                        .font(.caption)
                        .foregroundStyle(result ? .green : .red)
                }
            }

            Text("All credentials are stored securely in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            apiKeyInput = plugin._apiKey ?? ""
            resourceIdInput = plugin._resourceId ?? kDefaultResourceID
            boostingTableIdInput = plugin._boostingTableId ?? ""
        }
    }

    private func test() {
        plugin.setApiKey(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
        plugin.setResourceId(resourceIdInput)
        plugin.setBoostingTableId(boostingTableIdInput)
        isTesting = true
        connectionResult = nil
        Task {
            let ok = await plugin.validateConnection()
            await MainActor.run {
                isTesting = false
                connectionResult = ok
            }
        }
    }
}
