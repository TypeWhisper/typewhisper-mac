import AVFoundation
import Foundation
import SwiftUI
import TypeWhisperPluginSDK
import os

private enum XAIPluginDefaultsKey {
    static let selectedModel = "selectedModel"
    static let selectedLLMModel = "selectedLLMModel"
    static let fetchedLLMModels = "fetchedLLMModels"
    static let selectedVoice = "selectedVoice"
    static let fetchedVoices = "fetchedVoices"
    static let customVoiceId = "customVoiceId"
    static let ttsLowLatency = "ttsLowLatency"
    static let ttsTextNormalization = "ttsTextNormalization"
}

private enum XAIPluginError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case apiError(String)
    case playbackUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            "Invalid URL: \(url)"
        case .invalidResponse:
            "Invalid API response."
        case .apiError(let message):
            "API error: \(message)"
        case .playbackUnavailable(let message):
            "Playback unavailable: \(message)"
        }
    }
}

// MARK: - Shared API Types

struct XAIFetchedModel: Codable, Sendable, Hashable {
    let id: String
}

struct XAIFetchedVoice: Codable, Sendable, Hashable {
    let voiceID: String
    let name: String?
    let language: String?

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name
        case language
    }

    var displayName: String {
        let trimmedName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? voiceID : trimmedName
    }
}

// MARK: - Responses API

struct XAIResponsesClient: Sendable {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func process(systemPrompt: String, userText: String, model: String) async throws -> String {
        guard let url = URL(string: "https://api.x.ai/v1/responses") else {
            throw XAIPluginError.invalidURL("https://api.x.ai/v1/responses")
        }

        let body: [String: Any] = [
            "model": model,
            "store": false,
            "input": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await PluginHTTPClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginChatError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseResponse(data)
        case 401:
            throw PluginChatError.invalidApiKey
        case 429:
            throw PluginChatError.rateLimited
        default:
            throw PluginChatError.apiError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
        }
    }

    static func parseResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginChatError.apiError("Failed to parse response")
        }

        if let outputText = json["output_text"] as? String {
            let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let output = json["output"] as? [[String: Any]] {
            let textParts = output.flatMap { item -> [String] in
                guard let content = item["content"] as? [[String: Any]] else { return [] }
                return content.compactMap { contentItem in
                    let type = contentItem["type"] as? String
                    guard type == nil || type == "output_text" || type == "text" else { return nil }
                    return contentItem["text"] as? String
                }
            }

            let text = textParts
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }

        throw PluginChatError.apiError("Failed to parse response text")
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let body = String(data: data, encoding: .utf8), !body.isEmpty {
            return "HTTP \(statusCode): \(body)"
        }
        return "HTTP \(statusCode)"
    }
}

// MARK: - STT Transcript Collector

actor XAITranscriptCollector {
    private var finals: [String] = []
    private var interim = ""
    private var doneText: String?
    private var detectedLanguage: String?
    private var serverError: String?

    @discardableResult
    func applyEvent(_ data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid xAI STT event")
        }

        switch type {
        case "transcript.created":
            return nil
        case "transcript.partial":
            return applyPartialEvent(json)
        case "transcript.done":
            let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                doneText = text
                interim = ""
            }
            rememberLanguage(json)
            return currentText()
        case "error":
            let message = json["message"] as? String ?? "Unknown xAI STT error"
            serverError = message
            throw PluginTranscriptionError.apiError(message)
        default:
            return nil
        }
    }

    func currentText() -> String {
        if let doneText, !doneText.isEmpty {
            return doneText
        }

        var parts = finals
        if !interim.isEmpty {
            parts.append(interim)
        }
        return parts.joined(separator: " ")
    }

    func finalResult(fallbackLanguage: String?) -> PluginTranscriptionResult {
        let text: String
        if let doneText, !doneText.isEmpty {
            text = doneText
        } else {
            text = finals.joined(separator: " ")
        }
        return PluginTranscriptionResult(text: text, detectedLanguage: detectedLanguage ?? fallbackLanguage)
    }

    var error: String? {
        serverError
    }

    private func applyPartialEvent(_ json: [String: Any]) -> String {
        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isFinal = json["is_final"] as? Bool ?? false
        let speechFinal = json["speech_final"] as? Bool ?? false

        rememberLanguage(json)

        if isFinal {
            if !text.isEmpty {
                if speechFinal, !finals.isEmpty, text.hasPrefix(finals.joined(separator: " ")) {
                    finals = [text]
                } else if finals.last != text {
                    finals.append(text)
                }
            }
            interim = ""
        } else {
            interim = text
        }

        return currentText()
    }

    private func rememberLanguage(_ json: [String: Any]) {
        if let language = json["language"] as? String, !language.isEmpty {
            detectedLanguage = language
        }
    }
}

// MARK: - Live STT Session

private final class XAILiveTranscriptionSession: LiveTranscriptionSession, @unchecked Sendable {
    private let webSocketTask: URLSessionWebSocketTask
    private let receiveTask: Task<Void, Error>
    private let collector: XAITranscriptCollector
    private let onProgress: @Sendable (String) -> Bool
    private let language: String?
    private let state = OSAllocatedUnfairLock(initialState: false)

    init(
        webSocketTask: URLSessionWebSocketTask,
        collector: XAITranscriptCollector,
        language: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) {
        self.webSocketTask = webSocketTask
        self.collector = collector
        self.language = language
        self.onProgress = onProgress
        self.receiveTask = Task { [webSocketTask, collector, onProgress] in
            while !Task.isCancelled {
                let message = try await webSocketTask.receive()
                guard let data = Self.data(from: message) else { continue }
                if let text = try await collector.applyEvent(data), !text.isEmpty {
                    _ = onProgress(text)
                }

                if Self.isDoneEvent(data) {
                    break
                }
            }
        }
    }

    func appendAudio(samples: [Float]) async throws {
        guard !state.withLock({ $0 }) else { return }
        let data = XAIPlugin.floatToPCM16(samples)
        guard !data.isEmpty else { return }
        try await webSocketTask.send(.data(data))
    }

    func finish() async throws -> PluginTranscriptionResult {
        let shouldFinish = state.withLock { state in
            guard !state else { return false }
            state = true
            return true
        }

        if shouldFinish {
            try await webSocketTask.send(.string(#"{"type":"audio.done"}"#))
        }

        do {
            try await receiveTask.value
        } catch is CancellationError {
        }
        webSocketTask.cancel(with: .normalClosure, reason: nil)

        if let error = await collector.error {
            throw PluginTranscriptionError.apiError(error)
        }
        return await collector.finalResult(fallbackLanguage: language)
    }

    func cancel() async {
        state.withLock { state in
            state = true
        }
        receiveTask.cancel()
        webSocketTask.cancel(with: .goingAway, reason: nil)
    }

    private static func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .string(let text):
            return text.data(using: .utf8)
        case .data(let data):
            return data
        @unknown default:
            return nil
        }
    }

    private static func isDoneEvent(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["type"] as? String == "transcript.done"
    }
}

// MARK: - TTS Playback

protocol XAITTSAudioPlayback: AnyObject, Sendable {
    var onDrained: (@Sendable () -> Void)? { get set }
    func start(sampleRate: Int) throws
    func appendPCM16(_ data: Data) throws
    func finishInput()
    func stop()
}

final class XAITTSPlaybackSession: TTSPlaybackSession, @unchecked Sendable {
    private struct State {
        var isActive = true
        var onFinish: (@Sendable () -> Void)?
        var receiveTask: Task<Void, Never>?
    }

    private let webSocketTask: URLSessionWebSocketTask?
    private let audioPlayback: XAITTSAudioPlayback
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        webSocketTask: URLSessionWebSocketTask?,
        receiveTask: Task<Void, Never>?,
        audioPlayback: XAITTSAudioPlayback
    ) {
        self.webSocketTask = webSocketTask
        self.audioPlayback = audioPlayback
        state.withLock { $0.receiveTask = receiveTask }
        audioPlayback.onDrained = { [weak self] in
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

    func attachReceiveTask(_ receiveTask: Task<Void, Never>) {
        state.withLock { $0.receiveTask = receiveTask }
    }

    func stop() {
        let callbackAndTask = state.withLock { state -> ((@Sendable () -> Void)?, Task<Void, Never>?, Bool) in
            guard state.isActive else { return (nil, nil, false) }
            state.isActive = false
            return (state.onFinish, state.receiveTask, true)
        }

        guard callbackAndTask.2 else { return }
        callbackAndTask.1?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        audioPlayback.stop()
        callbackAndTask.0?()
    }

    func finish() {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.isActive else { return nil }
            state.isActive = false
            return state.onFinish
        }
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        callback?()
    }
}

private final class XAIAVAudioPlayback: XAITTSAudioPlayback, @unchecked Sendable {
    private struct State {
        var onDrained: (@Sendable () -> Void)?
        var pendingBuffers = 0
        var inputFinished = false
        var stopped = false
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var format: AVAudioFormat?

    var onDrained: (@Sendable () -> Void)? {
        get { state.withLock { $0.onDrained } }
        set { state.withLock { $0.onDrained = newValue } }
    }

    func start(sampleRate: Int) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false) else {
            throw XAIPluginError.playbackUnavailable("Could not create audio format")
        }
        self.format = format

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.play()
    }

    func appendPCM16(_ data: Data) throws {
        guard !state.withLock({ $0.stopped }) else { return }
        guard let format else {
            throw XAIPluginError.playbackUnavailable("Audio playback was not started")
        }

        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0] else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<frameCount {
                channel[index] = Float(Int16(littleEndian: int16Buffer[index])) / Float(Int16.max)
            }
        }

        state.withLock { $0.pendingBuffers += 1 }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.markBufferPlayed()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    func finishInput() {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            state.inputFinished = true
            return state.pendingBuffers == 0 && !state.stopped ? state.onDrained : nil
        }
        callback?()
    }

    func stop() {
        state.withLock { $0.stopped = true }
        player.stop()
        engine.stop()
        engine.detach(player)
    }

    private func markBufferPlayed() {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            state.pendingBuffers = max(0, state.pendingBuffers - 1)
            guard state.inputFinished, state.pendingBuffers == 0, !state.stopped else { return nil }
            return state.onDrained
        }
        callback?()
    }
}

// MARK: - Plugin Entry Point

@objc(XAIPlugin)
final class XAIPlugin: NSObject,
    TranscriptionEnginePlugin,
    DictionaryTermsCapabilityProviding,
    LiveTranscriptionCapablePlugin,
    LLMProviderPlugin,
    LLMProviderSetupStatusProviding,
    LLMModelSelectable,
    TTSProviderPlugin,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.xai"
    static let pluginName = "xAI / Grok"

    private static let defaultLLMModelId = "grok-4.3"
    private static let defaultSTTModelId = "grok-stt"
    private static let ttsSampleRate = 24_000
    private static let fallbackVoices: [PluginVoiceInfo] = [
        PluginVoiceInfo(id: "eve", displayName: "Eve"),
        PluginVoiceInfo(id: "ara", displayName: "Ara"),
        PluginVoiceInfo(id: "leo", displayName: "Leo"),
        PluginVoiceInfo(id: "rex", displayName: "Rex"),
        PluginVoiceInfo(id: "sal", displayName: "Sal"),
    ]

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _fetchedLLMModels: [XAIFetchedModel] = []
    fileprivate var _selectedVoiceId: String?
    fileprivate var _fetchedVoices: [XAIFetchedVoice] = []
    fileprivate var _customVoiceId: String = ""
    fileprivate var _ttsLowLatency = false
    fileprivate var _ttsTextNormalization = false

    private let logger = Logger(subsystem: "com.typewhisper.xai", category: "Plugin")

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _selectedModelId = host.userDefault(forKey: XAIPluginDefaultsKey.selectedModel) as? String
            ?? Self.defaultSTTModelId
        _selectedLLMModelId = host.userDefault(forKey: XAIPluginDefaultsKey.selectedLLMModel) as? String
            ?? Self.defaultLLMModelId
        _selectedVoiceId = host.userDefault(forKey: XAIPluginDefaultsKey.selectedVoice) as? String
            ?? Self.fallbackVoices.first?.id
        _customVoiceId = host.userDefault(forKey: XAIPluginDefaultsKey.customVoiceId) as? String ?? ""
        _ttsLowLatency = host.userDefault(forKey: XAIPluginDefaultsKey.ttsLowLatency) as? Bool ?? false
        _ttsTextNormalization = host.userDefault(forKey: XAIPluginDefaultsKey.ttsTextNormalization) as? Bool ?? false

        if let data = host.userDefault(forKey: XAIPluginDefaultsKey.fetchedLLMModels) as? Data,
           let models = try? JSONDecoder().decode([XAIFetchedModel].self, from: data) {
            _fetchedLLMModels = models
        }

        if let data = host.userDefault(forKey: XAIPluginDefaultsKey.fetchedVoices) as? Data,
           let voices = try? JSONDecoder().decode([XAIFetchedVoice].self, from: data) {
            _fetchedVoices = voices
        }
    }

    func deactivate() {
        host = nil
    }

    var settingsView: AnyView? {
        AnyView(XAISettingsView(plugin: self))
    }

    // MARK: - Shared Provider State

    var providerId: String { "xai" }
    var providerDisplayName: String { "xAI / Grok" }

    var isConfigured: Bool {
        guard let apiKey = _apiKey else { return false }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var requiresExternalCredentials: Bool { true }

    var unavailableReason: String? {
        isConfigured ? nil : "Set an xAI API key in plugin settings."
    }

    // MARK: - TranscriptionEnginePlugin

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: Self.defaultSTTModelId, displayName: "Grok Speech to Text"),
        ]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: XAIPluginDefaultsKey.selectedModel)
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { .unsupported }

    var supportedLanguages: [String] {
        [
            "ar", "cs", "da", "de", "en", "es", "fa", "fil", "fr", "hi",
            "id", "it", "ja", "ko", "mk", "ms", "nl", "pl", "pt", "ro",
            "ru", "sv", "th", "tr", "vi",
        ]
    }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }
        guard !translate else {
            throw PluginTranscriptionError.apiError("xAI STT does not support translation.")
        }

        return try await transcribeREST(audio: audio, language: language, apiKey: apiKey)
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }
        guard !translate else {
            throw PluginTranscriptionError.apiError("xAI STT does not support translation.")
        }

        do {
            let session = try await createStreamingSession(apiKey: apiKey, language: language, onProgress: onProgress)
            let chunkSize = 1_600
            var offset = 0
            while offset < audio.samples.count {
                let end = min(offset + chunkSize, audio.samples.count)
                try await session.appendAudio(samples: Array(audio.samples[offset..<end]))
                offset = end
                if offset < audio.samples.count {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            return try await session.finish()
        } catch {
            logger.warning("xAI STT streaming failed, falling back to REST: \(error.localizedDescription)")
            return try await transcribeREST(audio: audio, language: language, apiKey: apiKey)
        }
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }
        guard !translate else {
            throw PluginTranscriptionError.apiError("xAI STT does not support translation.")
        }

        let session = try await createStreamingSession(apiKey: apiKey, language: language, onProgress: onProgress)
        return session
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "xAI / Grok" }
    var isAvailable: Bool { isConfigured }

    var supportedModels: [PluginModelInfo] {
        if !_fetchedLLMModels.isEmpty {
            return _fetchedLLMModels.map { PluginModelInfo(id: $0.id, displayName: $0.id) }
        }
        return [
            PluginModelInfo(id: Self.defaultLLMModelId, displayName: "Grok 4.3"),
        ]
    }

    var preferredModelId: String? { _selectedLLMModelId }
    var selectedLLMModelId: String? { _selectedLLMModelId }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        guard let apiKey = normalizedAPIKey else {
            throw PluginChatError.notConfigured
        }

        let modelId = model ?? _selectedLLMModelId ?? supportedModels.first?.id ?? Self.defaultLLMModelId
        return try await XAIResponsesClient(apiKey: apiKey).process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: modelId
        )
    }

    func selectLLMModel(_ modelId: String) {
        _selectedLLMModelId = modelId
        host?.setUserDefault(modelId, forKey: XAIPluginDefaultsKey.selectedLLMModel)
        host?.notifyCapabilitiesChanged()
    }

    // MARK: - TTSProviderPlugin

    var availableVoices: [PluginVoiceInfo] {
        if !_fetchedVoices.isEmpty {
            return _fetchedVoices.map {
                PluginVoiceInfo(id: $0.voiceID, displayName: $0.displayName, localeIdentifier: $0.language)
            }
        }
        return Self.fallbackVoices
    }

    var selectedVoiceId: String? {
        if !_customVoiceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return _customVoiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return _selectedVoiceId
    }

    var settingsSummary: String? {
        let voice = availableVoices.first { $0.id == selectedVoiceId }?.displayName ?? selectedVoiceId ?? "Eve"
        let latency = _ttsLowLatency ? "low latency" : "quality"
        return "Voice: \(voice); \(latency)"
    }

    func selectVoice(_ voiceId: String?) {
        _selectedVoiceId = voiceId
        host?.setUserDefault(voiceId, forKey: XAIPluginDefaultsKey.selectedVoice)
        host?.notifyCapabilitiesChanged()
    }

    func speak(_ request: TTSSpeakRequest) async throws -> any TTSPlaybackSession {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }

        let webSocketRequest = try Self.makeTTSStreamingRequest(
            apiKey: apiKey,
            voice: selectedVoiceId,
            language: request.language,
            lowLatency: _ttsLowLatency,
            textNormalization: _ttsTextNormalization
        )

        let task = URLSession.shared.webSocketTask(with: webSocketRequest)
        let playback = XAIAVAudioPlayback()
        try playback.start(sampleRate: Self.ttsSampleRate)

        let session = XAITTSPlaybackSession(webSocketTask: task, receiveTask: nil, audioPlayback: playback)
        let receiveTask = Task { [task, playback, session, logger] in
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard let data = Self.webSocketData(from: message),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let type = json["type"] as? String else {
                        continue
                    }

                    switch type {
                    case "audio.delta":
                        if let delta = json["delta"] as? String,
                           let audioData = Data(base64Encoded: delta) {
                            try playback.appendPCM16(audioData)
                        }
                    case "audio.done":
                        playback.finishInput()
                        session.finish()
                        return
                    case "error":
                        let message = json["message"] as? String ?? "Unknown xAI TTS error"
                        logger.error("xAI TTS error: \(message)")
                        playback.stop()
                        session.finish()
                        return
                    default:
                        continue
                    }
                }
            } catch {
                logger.error("xAI TTS receive error: \(error.localizedDescription)")
                playback.stop()
                session.finish()
            }
        }
        session.attachReceiveTask(receiveTask)

        task.resume()
        try await task.send(.string(Self.ttsTextDeltaMessage(text: request.text)))
        try await task.send(.string(#"{"type":"text.done"}"#))
        return session
    }

    // MARK: - Settings Support

    fileprivate func setApiKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        _apiKey = trimmed
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: trimmed)
            } catch {
                logger.error("Failed to store xAI API key: \(error.localizedDescription)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func removeApiKey() {
        _apiKey = nil
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: "")
            } catch {
                logger.error("Failed to delete xAI API key: \(error.localizedDescription)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func validateApiKey(_ key: String) async -> Bool {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: "https://api.x.ai/v1/models") else {
            return false
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    fileprivate func fetchLLMModels() async -> [XAIFetchedModel] {
        guard let apiKey = normalizedAPIKey,
              let url = URL(string: "https://api.x.ai/v1/models") else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            struct Response: Decodable { let data: [XAIFetchedModel] }
            return try JSONDecoder().decode(Response.self, from: data).data
                .filter { Self.isLLMModel($0.id) }
                .sorted { $0.id < $1.id }
        } catch {
            logger.error("Failed to fetch xAI models: \(error.localizedDescription)")
            return []
        }
    }

    fileprivate func setFetchedLLMModels(_ models: [XAIFetchedModel]) {
        _fetchedLLMModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: XAIPluginDefaultsKey.fetchedLLMModels)
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func fetchVoices() async -> [XAIFetchedVoice] {
        guard let apiKey = normalizedAPIKey,
              let url = URL(string: "https://api.x.ai/v1/tts/voices") else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            struct Response: Decodable { let voices: [XAIFetchedVoice] }
            return try JSONDecoder().decode(Response.self, from: data).voices
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            logger.error("Failed to fetch xAI voices: \(error.localizedDescription)")
            return []
        }
    }

    fileprivate func setFetchedVoices(_ voices: [XAIFetchedVoice]) {
        _fetchedVoices = voices
        if let data = try? JSONEncoder().encode(voices) {
            host?.setUserDefault(data, forKey: XAIPluginDefaultsKey.fetchedVoices)
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setCustomVoiceId(_ voiceId: String) {
        _customVoiceId = voiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        host?.setUserDefault(_customVoiceId, forKey: XAIPluginDefaultsKey.customVoiceId)
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setTTSLowLatency(_ enabled: Bool) {
        _ttsLowLatency = enabled
        host?.setUserDefault(enabled, forKey: XAIPluginDefaultsKey.ttsLowLatency)
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setTTSTextNormalization(_ enabled: Bool) {
        _ttsTextNormalization = enabled
        host?.setUserDefault(enabled, forKey: XAIPluginDefaultsKey.ttsTextNormalization)
        host?.notifyCapabilitiesChanged()
    }

    // MARK: - Request Builders

    static func makeSTTStreamingRequest(
        apiKey: String,
        language: String?,
        interimResults: Bool
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.x.ai"
        components.path = "/v1/stt"

        var queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: interimResults ? "true" : "false"),
        ]
        if let language, !language.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw XAIPluginError.invalidURL("wss://api.x.ai/v1/stt")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    static func makeTTSStreamingRequest(
        apiKey: String,
        voice: String?,
        language: String?,
        lowLatency: Bool,
        textNormalization: Bool
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.x.ai"
        components.path = "/v1/tts"
        components.queryItems = [
            URLQueryItem(name: "language", value: language?.isEmpty == false ? language : "auto"),
            URLQueryItem(name: "voice", value: voice?.isEmpty == false ? voice : "eve"),
            URLQueryItem(name: "codec", value: "pcm"),
            URLQueryItem(name: "sample_rate", value: String(ttsSampleRate)),
            URLQueryItem(name: "optimize_streaming_latency", value: lowLatency ? "1" : "0"),
            URLQueryItem(name: "text_normalization", value: textNormalization ? "true" : "false"),
        ]

        guard let url = components.url else {
            throw XAIPluginError.invalidURL("wss://api.x.ai/v1/tts")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    private var normalizedAPIKey: String? {
        let trimmed = (_apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func createStreamingSession(
        apiKey: String,
        language: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> XAILiveTranscriptionSession {
        let request = try Self.makeSTTStreamingRequest(apiKey: apiKey, language: language, interimResults: true)
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        try await Self.waitForSTTCreated(task)

        let collector = XAITranscriptCollector()
        return XAILiveTranscriptionSession(
            webSocketTask: task,
            collector: collector,
            language: language,
            onProgress: onProgress
        )
    }

    private static func waitForSTTCreated(_ task: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message = try await task.receive()
            guard let data = webSocketData(from: message),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            switch type {
            case "transcript.created":
                return
            case "error":
                throw PluginTranscriptionError.apiError(json["message"] as? String ?? "Unknown xAI STT error")
            default:
                continue
            }
        }
        throw CancellationError()
    }

    private func transcribeREST(audio: AudioData, language: String?, apiKey: String) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: "https://api.x.ai/v1/stt") else {
            throw XAIPluginError.invalidURL("https://api.x.ai/v1/stt")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        if let language, !language.isEmpty {
            body.appendFormField(boundary: boundary, name: "format", value: "true")
            body.appendFormField(boundary: boundary, name: "language", value: language)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio.wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await PluginHTTPClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseSTTResponse(data, fallbackLanguage: language)
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    private static func parseSTTResponse(_ data: Data, fallbackLanguage: String?) throws -> PluginTranscriptionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginTranscriptionError.apiError("Invalid xAI STT response")
        }

        let text = json["text"] as? String ?? ""
        let language = json["language"] as? String
        let words = json["words"] as? [[String: Any]] ?? []
        let segments = words.compactMap { word -> PluginTranscriptionSegment? in
            guard let text = word["text"] as? String,
                  let start = word["start"] as? Double,
                  let end = word["end"] as? Double else {
                return nil
            }
            return PluginTranscriptionSegment(text: text, start: start, end: end)
        }
        return PluginTranscriptionResult(text: text, detectedLanguage: language ?? fallbackLanguage, segments: segments)
    }

    private static func webSocketData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .string(let text):
            return text.data(using: .utf8)
        case .data(let data):
            return data
        @unknown default:
            return nil
        }
    }

    private static func ttsTextDeltaMessage(text: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["type": "text.delta", "delta": text])
        guard let string = String(data: data, encoding: .utf8) else {
            throw XAIPluginError.apiError("Failed to encode TTS text")
        }
        return string
    }

    private static func isLLMModel(_ modelId: String) -> Bool {
        let lowered = modelId.lowercased()
        return !["stt", "tts", "voice", "image", "embedding"].contains { lowered.contains($0) }
    }
}

// MARK: - Settings View

private struct XAISettingsView: View {
    let plugin: XAIPlugin

    @State private var apiKeyInput = ""
    @State private var showAPIKey = false
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var selectedLLMModel = ""
    @State private var selectedVoiceId = ""
    @State private var customVoiceId = ""
    @State private var lowLatency = false
    @State private var textNormalization = false
    @State private var isRefreshingModels = false
    @State private var isRefreshingVoices = false

    private let bundle = Bundle(for: XAIPlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            apiKeySection

            if plugin.isConfigured {
                Divider()
                llmSection
                Divider()
                ttsSection
            }

            Text("API keys are stored securely in the Keychain", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear(perform: loadState)
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Key", bundle: bundle)
                .font(.headline)

            HStack(spacing: 8) {
                if showAPIKey {
                    TextField("API Key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    SecureField("API Key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                }

                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)

                if plugin.isConfigured {
                    Button(String(localized: "Remove", bundle: bundle)) {
                        apiKeyInput = ""
                        validationResult = nil
                        plugin.removeApiKey()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                } else {
                    Button(String(localized: "Save", bundle: bundle)) {
                        saveAPIKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if isValidating {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Validating...", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let validationResult {
                Label(
                    validationResult ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle),
                    systemImage: validationResult ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(validationResult ? .green : .red)
            }
        }
    }

    private var llmSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LLM Model", bundle: bundle)
                    .font(.headline)
                Spacer()
                Button {
                    refreshLLMModels()
                } label: {
                    Label(String(localized: "Refresh", bundle: bundle), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshingModels)
            }

            Picker("LLM Model", selection: $selectedLLMModel) {
                ForEach(plugin.supportedModels, id: \.id) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .labelsHidden()
            .onChange(of: selectedLLMModel) {
                plugin.selectLLMModel(selectedLLMModel)
            }
        }
    }

    private var ttsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TTS Voice", bundle: bundle)
                    .font(.headline)
                Spacer()
                Button {
                    refreshVoices()
                } label: {
                    Label(String(localized: "Refresh", bundle: bundle), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshingVoices)
            }

            Picker("TTS Voice", selection: $selectedVoiceId) {
                ForEach(plugin.availableVoices, id: \.id) { voice in
                    Text(voice.displayName).tag(voice.id)
                }
            }
            .labelsHidden()
            .onChange(of: selectedVoiceId) {
                plugin.selectVoice(selectedVoiceId)
            }

            TextField("Custom Voice ID", text: $customVoiceId)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit {
                    plugin.setCustomVoiceId(customVoiceId)
                }
                .onChange(of: customVoiceId) {
                    plugin.setCustomVoiceId(customVoiceId)
                }

            Toggle(String(localized: "Low Latency", bundle: bundle), isOn: Binding(
                get: { lowLatency },
                set: { newValue in
                    lowLatency = newValue
                    plugin.setTTSLowLatency(newValue)
                }
            ))

            Toggle(String(localized: "Text Normalization", bundle: bundle), isOn: Binding(
                get: { textNormalization },
                set: { newValue in
                    textNormalization = newValue
                    plugin.setTTSTextNormalization(newValue)
                }
            ))
        }
    }

    private func loadState() {
        apiKeyInput = plugin._apiKey ?? ""
        selectedLLMModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
        selectedVoiceId = plugin._selectedVoiceId ?? plugin.availableVoices.first?.id ?? "eve"
        customVoiceId = plugin._customVoiceId
        lowLatency = plugin._ttsLowLatency
        textNormalization = plugin._ttsTextNormalization
    }

    private func saveAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        plugin.setApiKey(key)
        isValidating = true
        validationResult = nil

        Task {
            let isValid = await plugin.validateApiKey(key)
            let models = isValid ? await plugin.fetchLLMModels() : []
            let voices = isValid ? await plugin.fetchVoices() : []
            await MainActor.run {
                isValidating = false
                validationResult = isValid
                if !models.isEmpty {
                    plugin.setFetchedLLMModels(models)
                    selectedLLMModel = plugin.selectedLLMModelId ?? models.first?.id ?? selectedLLMModel
                }
                if !voices.isEmpty {
                    plugin.setFetchedVoices(voices)
                    selectedVoiceId = plugin._selectedVoiceId ?? voices.first?.voiceID ?? selectedVoiceId
                }
            }
        }
    }

    private func refreshLLMModels() {
        isRefreshingModels = true
        Task {
            let models = await plugin.fetchLLMModels()
            await MainActor.run {
                isRefreshingModels = false
                guard !models.isEmpty else { return }
                plugin.setFetchedLLMModels(models)
                if !models.contains(where: { $0.id == selectedLLMModel }), let first = models.first {
                    selectedLLMModel = first.id
                    plugin.selectLLMModel(first.id)
                }
            }
        }
    }

    private func refreshVoices() {
        isRefreshingVoices = true
        Task {
            let voices = await plugin.fetchVoices()
            await MainActor.run {
                isRefreshingVoices = false
                guard !voices.isEmpty else { return }
                plugin.setFetchedVoices(voices)
                if !voices.contains(where: { $0.voiceID == selectedVoiceId }), let first = voices.first {
                    selectedVoiceId = first.voiceID
                    plugin.selectVoice(first.voiceID)
                }
            }
        }
    }
}

private extension Data {
    mutating func appendFormField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
