import AVFoundation
import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

private enum SonioxDefaultsKey {
    static let apiKey = "api-key"
    static let selectedModel = "selectedModel"
    static let selectedRegion = "selectedRegion"
    static let selectedVoice = "selectedVoice"
    static let selectedTTSModel = "selectedTTSModel"
    static let fetchedModels = "fetchedModels"
    static let fetchedTTSModels = "fetchedTTSModels"
}

private enum SonioxModelSelection {
    static let automatic = "automatic"
}

private enum SonioxPluginError: LocalizedError {
    case invalidURL(String)
    case apiError(String)
    case playbackUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            "Invalid URL: \(url)"
        case .apiError(let message):
            "API error: \(message)"
        case .playbackUnavailable(let message):
            "Playback unavailable: \(message)"
        }
    }
}

// MARK: - Supported Languages

private let sonioxSupportedLanguages = [
    "af", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs",
    "cy", "da", "de", "el", "en", "es", "et", "fa", "fi", "fr",
    "gl", "gu", "ha", "he", "hi", "hr", "hu", "hy", "id", "is",
    "it", "ja", "ka", "kk", "km", "kn", "ko", "lo", "lt", "lv",
    "mk", "ml", "mn", "mr", "ms", "my", "ne", "nl", "no", "pa",
    "pl", "pt", "ro", "ru", "sk", "sl", "so", "sq", "sr", "sv",
    "sw", "ta", "te", "th", "tr", "uk", "ur", "uz", "vi", "zh",
]

private let sonioxTTSSupportedLanguages = [
    "af", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs", "cy",
    "da", "de", "el", "en", "es", "et", "eu", "fa", "fi", "fr",
    "gl", "gu", "he", "hi", "hr", "hu", "id", "is", "it", "ja",
    "kk", "kn", "ko", "lt", "lv", "mk", "ml", "mr", "ms", "nl",
    "no", "pa", "pl", "pt", "ro", "ru", "sk", "sl", "sq", "sr",
    "su", "sv", "sw", "ta", "te", "th", "tl", "tr", "uk", "ur",
    "vi", "zh",
]

struct SonioxRegion: Sendable, Hashable, Identifiable {
    let id: String
    let displayNameKey: String
    let apiHost: String
    let sttRealtimeHost: String
    let ttsHost: String

    static let unitedStates = SonioxRegion(
        id: "us",
        displayNameKey: "United States",
        apiHost: "api.soniox.com",
        sttRealtimeHost: "stt-rt.soniox.com",
        ttsHost: "tts-rt.soniox.com"
    )
    static let europeanUnion = SonioxRegion(
        id: "eu",
        displayNameKey: "European Union",
        apiHost: "api.eu.soniox.com",
        sttRealtimeHost: "stt-rt.eu.soniox.com",
        ttsHost: "tts-rt.eu.soniox.com"
    )
    static let japan = SonioxRegion(
        id: "jp",
        displayNameKey: "Japan",
        apiHost: "api.jp.soniox.com",
        sttRealtimeHost: "stt-rt.jp.soniox.com",
        ttsHost: "tts-rt.jp.soniox.com"
    )

    static let all = [unitedStates, europeanUnion, japan]

    static func resolved(_ storedRegionId: String?, host: HostServices?) -> SonioxRegion {
        let trimmed = storedRegionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = trimmed.flatMap { id in all.first { $0.id == id } } ?? .unitedStates
        if region.id != storedRegionId {
            host?.setUserDefault(region.id, forKey: SonioxDefaultsKey.selectedRegion)
        }
        return region
    }

    var apiBaseURL: String {
        "https://\(apiHost)"
    }

    var sttRealtimeWebSocketURL: String {
        "wss://\(sttRealtimeHost)/transcribe-websocket"
    }

    var ttsURL: String {
        "https://\(ttsHost)/tts"
    }
}

struct SonioxFetchedLanguage: Codable, Equatable, Sendable {
    let code: String
    let name: String?
}

struct SonioxFetchedVoice: Codable, Equatable, Sendable {
    let id: String
    let description: String?
    let gender: String?
}

struct SonioxFetchedModel: Codable, Equatable, Sendable {
    let id: String
    let aliasedModelId: String?
    let name: String?
    let transcriptionMode: String?
    let languages: [SonioxFetchedLanguage]

    enum CodingKeys: String, CodingKey {
        case id
        case aliasedModelId = "aliased_model_id"
        case name
        case transcriptionMode = "transcription_mode"
        case languages
    }
}

struct SonioxFetchedTTSModel: Codable, Equatable, Sendable {
    let id: String
    let aliasedModelId: String?
    let name: String?
    let languages: [SonioxFetchedLanguage]
    let voices: [SonioxFetchedVoice]

    enum CodingKeys: String, CodingKey {
        case id
        case aliasedModelId = "aliased_model_id"
        case name
        case languages
        case voices
    }
}

protocol SonioxTTSAudioPlayback: AnyObject, Sendable {
    var onDrained: (@Sendable () -> Void)? { get set }
    func start(sampleRate: Int) throws
    func appendPCM16(_ data: Data) throws
    func finishInput()
    func stop()
}

final class SonioxTTSPlaybackSession: TTSPlaybackSession, @unchecked Sendable {
    private struct State {
        var isActive = true
        var onFinish: (@Sendable () -> Void)?
    }

    private let audioPlayback: SonioxTTSAudioPlayback
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(audioPlayback: SonioxTTSAudioPlayback) {
        self.audioPlayback = audioPlayback
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

    func stop() {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.isActive else { return nil }
            state.isActive = false
            return state.onFinish
        }
        audioPlayback.stop()
        callback?()
    }

    func finish() {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.isActive else { return nil }
            state.isActive = false
            return state.onFinish
        }
        callback?()
    }
}

private final class SonioxAVAudioPlayback: SonioxTTSAudioPlayback, @unchecked Sendable {
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
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw SonioxPluginError.playbackUnavailable("Could not create audio format")
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
            throw SonioxPluginError.playbackUnavailable("Audio playback was not started")
        }
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw SonioxPluginError.playbackUnavailable("PCM16 audio data must contain whole samples.")
        }

        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
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

// MARK: - Transcript Collector

private actor TranscriptCollector {
    private var finals: [String] = []
    private var interim: String = ""
    private var _detectedLanguage: String?
    private var _error: String?

    func addFinal(_ text: String, language: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            finals.append(trimmed)
        }
        interim = ""
        if let language, !language.isEmpty {
            _detectedLanguage = language
        }
    }

    func setInterim(_ text: String, language: String? = nil) {
        interim = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let language, !language.isEmpty {
            _detectedLanguage = language
        }
    }

    func setError(_ message: String) {
        _error = message
    }

    var error: String? { _error }

    func currentText() -> String {
        var parts = finals
        if !interim.isEmpty {
            parts.append(interim)
        }
        return parts.joined(separator: " ")
    }

    func finalResult() -> String {
        finals.joined(separator: " ")
    }

    func detectedLanguage(fallback: String?) -> String? {
        _detectedLanguage ?? fallback
    }
}

// MARK: - Plugin Entry Point

@objc(SonioxPlugin)
final class SonioxPlugin: NSObject,
    SourceProgressLanguageHintTranscriptionEnginePlugin,
    DictionaryTermsCapabilityProviding,
    DictionaryTermsBudgetProviding,
    TTSProviderPlugin,
    PluginAuthRoleStatusProviding,
    @unchecked Sendable {
    static let pluginId = "com.typewhisper.soniox"
    static let pluginName = "Soniox"
    static let defaultAsyncModelId = "stt-async-v5"
    static let defaultRealtimeModelId = "stt-rt-v5"
    static let defaultTTSModelId = "tts-rt-v1"
    static let ttsSampleRate = 24_000
    static let defaultVoiceId = "Maya"
    static let fallbackVoices: [PluginVoiceInfo] = [
        PluginVoiceInfo(id: "Maya", displayName: "Maya"),
        PluginVoiceInfo(id: "Daniel", displayName: "Daniel"),
        PluginVoiceInfo(id: "Noah", displayName: "Noah"),
        PluginVoiceInfo(id: "Nina", displayName: "Nina"),
        PluginVoiceInfo(id: "Emma", displayName: "Emma"),
        PluginVoiceInfo(id: "Jack", displayName: "Jack"),
        PluginVoiceInfo(id: "Adrian", displayName: "Adrian"),
        PluginVoiceInfo(id: "Claire", displayName: "Claire"),
        PluginVoiceInfo(id: "Grace", displayName: "Grace"),
        PluginVoiceInfo(id: "Owen", displayName: "Owen"),
        PluginVoiceInfo(id: "Mina", displayName: "Mina"),
        PluginVoiceInfo(id: "Kenji", displayName: "Kenji"),
        PluginVoiceInfo(id: "Rafael", displayName: "Rafael"),
        PluginVoiceInfo(id: "Mateo", displayName: "Mateo"),
        PluginVoiceInfo(id: "Lucia", displayName: "Lucia"),
        PluginVoiceInfo(id: "Sofia", displayName: "Sofia"),
        PluginVoiceInfo(id: "Oliver", displayName: "Oliver"),
        PluginVoiceInfo(id: "Arthur", displayName: "Arthur"),
        PluginVoiceInfo(id: "Isla", displayName: "Isla"),
        PluginVoiceInfo(id: "Victoria", displayName: "Victoria"),
        PluginVoiceInfo(id: "Cooper", displayName: "Cooper"),
        PluginVoiceInfo(id: "Mason", displayName: "Mason"),
        PluginVoiceInfo(id: "Ruby", displayName: "Ruby"),
        PluginVoiceInfo(id: "Elise", displayName: "Elise"),
        PluginVoiceInfo(id: "Arjun", displayName: "Arjun"),
        PluginVoiceInfo(id: "Rohan", displayName: "Rohan"),
        PluginVoiceInfo(id: "Priya", displayName: "Priya"),
        PluginVoiceInfo(id: "Meera", displayName: "Meera"),
    ]

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _selectedRegion = SonioxRegion.unitedStates
    fileprivate var _selectedTTSModelId: String?
    fileprivate var _selectedVoiceId: String?
    fileprivate var _fetchedModels: [SonioxFetchedModel] = []
    fileprivate var _fetchedTTSModels: [SonioxFetchedTTSModel] = []

    private let logger = Logger(subsystem: "com.typewhisper.soniox", category: "Plugin")

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: SonioxDefaultsKey.apiKey)
        _selectedModelId = Self.resolvedRealtimeModelId(
            host.userDefault(forKey: SonioxDefaultsKey.selectedModel) as? String,
            host: host
        )
        _selectedRegion = SonioxRegion.resolved(
            host.userDefault(forKey: SonioxDefaultsKey.selectedRegion) as? String,
            host: host
        )
        _selectedTTSModelId = Self.resolvedTTSModelId(
            host.userDefault(forKey: SonioxDefaultsKey.selectedTTSModel) as? String,
            host: host
        )
        _selectedVoiceId = Self.resolvedVoiceId(
            host.userDefault(forKey: SonioxDefaultsKey.selectedVoice) as? String,
            host: host
        )
        if let data = host.userDefault(forKey: SonioxDefaultsKey.fetchedModels) as? Data {
            _fetchedModels = (try? JSONDecoder().decode([SonioxFetchedModel].self, from: data)) ?? []
        }
        if let data = host.userDefault(forKey: SonioxDefaultsKey.fetchedTTSModels) as? Data {
            _fetchedTTSModels = (try? JSONDecoder().decode([SonioxFetchedTTSModel].self, from: data)) ?? []
        }
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "soniox" }
    var providerDisplayName: String { "Soniox" }

    var isConfigured: Bool {
        guard let key = normalizedAPIKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        let models = Self.realtimeModels(from: _fetchedModels)
        guard !models.isEmpty else {
            return [PluginModelInfo(id: Self.defaultRealtimeModelId, displayName: "STT RT v5")]
        }
        return models.map { model in
            PluginModelInfo(id: model.id, displayName: model.name ?? model.id)
        }
    }

    var selectedModelId: String? { effectiveRealtimeModelId }

    func selectModel(_ modelId: String) {
        let resolvedModelId = Self.resolvedRealtimeModelId(modelId, host: host)
        _selectedModelId = resolvedModelId
        host?.setUserDefault(resolvedModelId, forKey: SonioxDefaultsKey.selectedModel)
    }

    var supportsTranslation: Bool { true }
    var supportsStreaming: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }
    var dictionaryTermsBudget: DictionaryTermsBudget { DictionaryTermsBudget(maxTotalChars: 10_000) }

    var supportedLanguages: [String] { sonioxSupportedLanguages }

    private var normalizedAPIKey: String? {
        guard let apiKey = _apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            return nil
        }
        return apiKey
    }

    // MARK: - PluginAuthRoleStatusProviding

    func authStatus(for role: PluginAuthRole) -> PluginAuthRoleStatus {
        switch role {
        case .transcription, .tts:
            return PluginAuthRoleStatus.legacyFallback(
                isConfigured: isConfigured,
                unavailableReason: "Soniox API key is required.",
                requiredCredentialLabel: "Soniox API key"
            )
        case .llm:
            return .unavailable(reason: "Soniox does not provide LLM capabilities.")
        }
    }

    // MARK: - TTSProviderPlugin

    var availableVoices: [PluginVoiceInfo] {
        if let model = _fetchedTTSModels.first(where: { $0.id == effectiveTTSModelId }),
           !model.voices.isEmpty {
            return model.voices.map { PluginVoiceInfo(id: $0.id, displayName: $0.id) }
        }
        return Self.fallbackVoices
    }

    var ttsModels: [PluginModelInfo] {
        guard !_fetchedTTSModels.isEmpty else {
            return [PluginModelInfo(id: Self.defaultTTSModelId, displayName: "TTS v1")]
        }
        return _fetchedTTSModels.map { model in
            PluginModelInfo(id: model.id, displayName: model.name ?? model.id)
        }
    }

    private var effectiveRealtimeModelId: String {
        guard _selectedModelId == SonioxModelSelection.automatic else {
            return _selectedModelId ?? Self.defaultRealtimeModelId
        }
        return Self.preferredSTTModelId(
            from: _fetchedModels,
            transcriptionMode: "real_time",
            fallback: Self.defaultRealtimeModelId
        )
    }

    private var effectiveAsyncModelId: String {
        Self.preferredSTTModelId(
            from: _fetchedModels,
            transcriptionMode: "async",
            fallback: Self.defaultAsyncModelId
        )
    }

    private var effectiveTTSModelId: String {
        guard _selectedTTSModelId == SonioxModelSelection.automatic else {
            return _selectedTTSModelId ?? Self.defaultTTSModelId
        }
        return Self.preferredTTSModelId(from: _fetchedTTSModels, fallback: Self.defaultTTSModelId)
    }

    var selectedVoiceId: String? {
        let voices = availableVoices
        if let selected = _selectedVoiceId, voices.contains(where: { $0.id == selected }) {
            return selected
        }
        if voices.contains(where: { $0.id == Self.defaultVoiceId }) {
            return Self.defaultVoiceId
        }
        return voices.first?.id ?? Self.defaultVoiceId
    }

    var settingsSummary: String? {
        let region = String(localized: String.LocalizationValue(_selectedRegion.displayNameKey), bundle: Bundle(for: SonioxPlugin.self))
        let voice = availableVoices.first { $0.id == selectedVoiceId }?.displayName ?? selectedVoiceId ?? Self.defaultVoiceId
        let format = String(localized: "Region: %@; Voice: %@; Soniox", bundle: Bundle(for: SonioxPlugin.self))
        return String(format: format, region, voice)
    }

    func selectVoice(_ voiceId: String?) {
        _selectedVoiceId = Self.resolvedVoiceId(voiceId, host: host)
        host?.notifyCapabilitiesChanged()
    }

    func speak(_ request: TTSSpeakRequest) async throws -> any TTSPlaybackSession {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SonioxPluginError.apiError("TTS text is empty.")
        }

        let urlRequest = try Self.makeTTSRequest(
            apiKey: apiKey,
            text: text,
            voiceId: selectedVoiceId ?? Self.defaultVoiceId,
            language: Self.resolvedTTSLanguage(request.language),
            modelID: effectiveTTSModelId,
            regionID: _selectedRegion.id
        )

        let (data, response) = try await PluginHTTPClient.data(for: urlRequest)
        try Self.validateHTTPResponse(data: data, response: response)

        let playback = SonioxAVAudioPlayback()
        do {
            try playback.start(sampleRate: Self.ttsSampleRate)
            let session = SonioxTTSPlaybackSession(audioPlayback: playback)
            try playback.appendPCM16(data)
            playback.finishInput()
            return session
        } catch {
            playback.stop()
            throw error
        }
    }

    // MARK: - Transcription (REST Fallback)

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }

        return try await transcribeREST(
            audio: audio,
            language: language,
            translate: translate,
            apiKey: apiKey,
            prompt: prompt
        )
    }

    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }

        let effectiveHints = Self.resolvedLanguageHints(
            requestedLanguage: languageSelection.requestedLanguage,
            languageHints: languageSelection.languageHints
        )

        return try await transcribeREST(
            audio: audio,
            language: languageSelection.requestedLanguage,
            languageHints: effectiveHints,
            translate: translate,
            apiKey: apiKey,
            prompt: prompt
        )
    }

    // MARK: - Transcription (WebSocket Streaming)

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
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        do {
            return try await transcribeWebSocket(
                audio: audio, language: language, translate: translate,
                modelId: modelId, prompt: prompt, apiKey: apiKey,
                onProgress: onProgress,
                onSourceProgress: { _ in true }
            )
        } catch {
            logger.warning("WebSocket streaming failed, falling back to REST: \(error.localizedDescription)")
            return try await transcribeREST(
                audio: audio,
                language: language,
                translate: translate,
                apiKey: apiKey,
                prompt: prompt
            )
        }
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }

        let result = try await transcribeREST(
            audio: audio,
            language: language,
            translate: translate,
            apiKey: apiKey,
            prompt: prompt
        )
        Self.emitFinalProgress(result, onProgress: onProgress)
        return result
    }

    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        let effectiveHints = Self.resolvedLanguageHints(
            requestedLanguage: languageSelection.requestedLanguage,
            languageHints: languageSelection.languageHints
        )

        do {
            return try await transcribeWebSocket(
                audio: audio,
                language: languageSelection.requestedLanguage,
                languageHints: effectiveHints,
                translate: translate,
                modelId: modelId,
                prompt: prompt,
                apiKey: apiKey,
                onProgress: onProgress,
                onSourceProgress: { _ in true }
            )
        } catch {
            logger.warning("WebSocket streaming failed, falling back to REST: \(error.localizedDescription)")
            return try await transcribeREST(
                audio: audio,
                language: languageSelection.requestedLanguage,
                languageHints: effectiveHints,
                translate: translate,
                apiKey: apiKey,
                prompt: prompt
            )
        }
    }

    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }

        let effectiveHints = Self.resolvedLanguageHints(
            requestedLanguage: languageSelection.requestedLanguage,
            languageHints: languageSelection.languageHints
        )

        let result = try await transcribeREST(
            audio: audio,
            language: languageSelection.requestedLanguage,
            languageHints: effectiveHints,
            translate: translate,
            apiKey: apiKey,
            prompt: prompt
        )
        Self.emitFinalProgress(result, onProgress: onProgress)
        return result
    }

    // MARK: - WebSocket Implementation

    private func transcribeWebSocket(
        audio: AudioData,
        language: String?,
        languageHints: [String] = [],
        translate: Bool,
        modelId: String,
        prompt: String?,
        apiKey: String,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: _selectedRegion.sttRealtimeWebSocketURL) else {
            throw PluginTranscriptionError.apiError("Invalid Soniox WebSocket URL")
        }

        let wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask.resume()

        // Send config message with API key (Soniox auth is in the first message)
        var config: [String: Any] = [
            "api_key": apiKey,
            "model": modelId,
            "audio_format": "s16le",
            "sample_rate": 16000,
            "num_channels": 1,
            "enable_endpoint_detection": true,
        ]

        let effectiveHints = Self.resolvedLanguageHints(requestedLanguage: language, languageHints: languageHints)
        if !effectiveHints.isEmpty {
            config["language_hints"] = effectiveHints
        }

        if translate {
            config["translation"] = [
                "type": "one_way",
                "target_language": "en",
            ]
        }
        if let context = Self.contextPayload(prompt: prompt) {
            config["context"] = context
        }

        let configData = try JSONSerialization.data(withJSONObject: config)
        guard let configString = String(data: configData, encoding: .utf8) else {
            throw PluginTranscriptionError.apiError("Failed to encode config")
        }
        try await wsTask.send(.string(configString))

        // Receive loop
        let collector = TranscriptCollector()
        let loggerRef = self.logger
        let isTranslating = translate

        let receiveTask = Task {
            var shouldEmitSourceProgress = true
            do {
                while !Task.isCancelled {
                    let message = try await wsTask.receive()

                    guard case .string(let text) = message else { continue }

                    guard let data = text.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }

                    // Check for finished signal
                    if json["finished"] as? Bool == true { break }

                    // Check for error
                    if let errorObj = json["error"] as? [String: Any] {
                        let msg = errorObj["message"] as? String ?? "Unknown Soniox error"
                        loggerRef.error("Soniox error: \(msg)")
                        await collector.setError(msg)
                        break
                    }

                    // Parse tokens
                    guard let tokens = json["tokens"] as? [[String: Any]] else { continue }

                    if shouldEmitSourceProgress,
                       let sourceProgress = Self.sourceProgress(
                           fromTokens: tokens,
                           totalDuration: audio.duration
                       ) {
                        shouldEmitSourceProgress = onSourceProgress(sourceProgress)
                    }

                    var finalText: [String] = []
                    var interimText: [String] = []
                    var tokenLanguage: String?

                    for token in tokens {
                        guard let tokenStr = token["text"] as? String else { continue }

                        // When translating, skip original tokens
                        if isTranslating {
                            let status = token["translation_status"] as? String
                            if status == "original" { continue }
                        }

                        let isFinal = token["is_final"] as? Bool ?? false
                        if let lang = token["language"] as? String, !lang.isEmpty {
                            tokenLanguage = lang
                        }

                        if isFinal {
                            finalText.append(tokenStr)
                        } else {
                            interimText.append(tokenStr)
                        }
                    }

                    let joinedFinal = finalText.joined()
                    let joinedInterim = interimText.joined()

                    if !joinedFinal.isEmpty {
                        await collector.addFinal(joinedFinal, language: tokenLanguage)
                    }
                    if !joinedInterim.isEmpty {
                        await collector.setInterim(joinedInterim, language: tokenLanguage)
                    }

                    let currentText = await collector.currentText()
                    if !currentText.isEmpty {
                        _ = onProgress(currentText)
                    }
                }
            } catch {
                loggerRef.error("WebSocket receive error: \(error.localizedDescription)")
            }
        }

        // Send audio as binary frames
        let pcmData = Self.floatToPCM16(audio.samples)
        let chunkSize = 8192
        var offset = 0

        defer { receiveTask.cancel() }

        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            try await wsTask.send(.data(chunk))
            offset = end
        }

        // Finalize pending tokens and signal end of audio
        try await wsTask.send(.string("{\"type\":\"finalize\"}"))
        try await wsTask.send(.data(Data()))

        // Wait for server to finish
        _ = await receiveTask.result

        wsTask.cancel(with: .normalClosure, reason: nil)

        // Check for server-side errors (e.g. invalid API key)
        if let error = await collector.error {
            throw PluginTranscriptionError.apiError(error)
        }

        let finalText = await collector.finalResult()
        let detectedLanguage = await collector.detectedLanguage(fallback: language)
        return PluginTranscriptionResult(text: finalText, detectedLanguage: detectedLanguage)
    }

    static func sourceProgress(
        fromTokens tokens: [[String: Any]],
        totalDuration: TimeInterval
    ) -> PluginTranscriptionSourceProgress? {
        guard totalDuration.isFinite, totalDuration > 0 else { return nil }
        let latestFinalEndMs = tokens.compactMap { token -> Double? in
            guard token["is_final"] as? Bool == true else { return nil }
            if (token["translation_status"] as? String) == "translation" {
                return nil
            }
            return doubleValue(token["end_ms"])
        }.max()

        guard let latestFinalEndMs, latestFinalEndMs > 0 else { return nil }
        return PluginTranscriptionSourceProgress(
            processedDuration: min(latestFinalEndMs / 1000.0, totalDuration),
            totalDuration: totalDuration
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    // MARK: - REST Implementation (4-Step Async)

    private func transcribeREST(
        audio: AudioData,
        language: String?,
        languageHints: [String] = [],
        translate: Bool,
        apiKey: String,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        let fileId = try await PluginAudioUploadEncoder.withCompressedM4AUploadWavFallback(from: audio) { upload in
            try await uploadFile(uploadFile: upload, apiKey: apiKey)
        }
        let transcriptionId = try await createTranscription(
            fileId: fileId,
            language: language,
            languageHints: languageHints,
            translate: translate,
            apiKey: apiKey,
            prompt: prompt
        )
        try await pollUntilCompleted(id: transcriptionId, apiKey: apiKey)
        return try await fetchTranscript(id: transcriptionId, apiKey: apiKey, language: language)
    }

    private func uploadFile(uploadFile: PluginAudioUploadFile, apiKey: String) async throws -> String {
        guard let url = URL(string: "\(_selectedRegion.apiBaseURL)/v1/files") else {
            throw PluginTranscriptionError.apiError("Invalid upload URL")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(uploadFile.filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(uploadFile.contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(uploadFile.data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200, 201: break
        case 401: throw PluginTranscriptionError.invalidApiKey
        case 413: throw PluginTranscriptionError.fileTooLarge
        case 429: throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Upload failed HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileId = json["id"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid upload response")
        }

        return fileId
    }

    private func createTranscription(
        fileId: String,
        language: String?,
        languageHints: [String] = [],
        translate: Bool,
        apiKey: String,
        prompt: String?
    ) async throws -> String {
        let request = try Self.makeCreateTranscriptionRequest(
            fileId: fileId,
            language: language,
            languageHints: languageHints,
            translate: translate,
            apiKey: apiKey,
            prompt: prompt,
            modelID: effectiveAsyncModelId,
            regionID: _selectedRegion.id
        )

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200, 201: break
        case 401: throw PluginTranscriptionError.invalidApiKey
        case 429: throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Create transcription failed HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid transcription creation response")
        }

        return id
    }

    static func makeCreateTranscriptionRequest(
        fileId: String,
        language: String?,
        languageHints: [String] = [],
        translate: Bool,
        apiKey: String,
        prompt: String?,
        modelID: String = SonioxPlugin.defaultAsyncModelId,
        regionID: String? = nil
    ) throws -> URLRequest {
        let region = SonioxRegion.resolved(regionID, host: nil)
        guard let url = URL(string: "\(region.apiBaseURL)/v1/transcriptions") else {
            throw PluginTranscriptionError.apiError("Invalid transcriptions URL")
        }

        var body: [String: Any] = [
            "file_id": fileId,
            "model": modelID,
        ]

        let effectiveHints = Self.resolvedLanguageHints(requestedLanguage: language, languageHints: languageHints)
        if !effectiveHints.isEmpty {
            body["language_hints"] = effectiveHints
        }

        if translate {
            body["translation"] = [
                "type": "one_way",
                "target_language": "en",
            ]
        }
        if let context = Self.contextPayload(prompt: prompt) {
            body["context"] = context
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        return request
    }

    static func makeTTSRequest(
        apiKey: String,
        text: String,
        voiceId: String,
        language: String?,
        modelID: String = SonioxPlugin.defaultTTSModelId,
        regionID: String? = nil
    ) throws -> URLRequest {
        let region = SonioxRegion.resolved(regionID, host: nil)
        guard let url = URL(string: region.ttsURL) else {
            throw SonioxPluginError.invalidURL(region.ttsURL)
        }

        let body: [String: Any] = [
            "model": modelID,
            "language": Self.resolvedTTSLanguage(language),
            "voice": voiceId,
            "audio_format": "pcm_s16le",
            "text": text,
            "sample_rate": Self.ttsSampleRate,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func validateHTTPResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200, 201:
            return
        case 401, 403:
            throw PluginTranscriptionError.invalidApiKey
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            throw PluginTranscriptionError.apiError(errorMessage(from: data, statusCode: httpResponse.statusCode))
        }
    }

    // MARK: - Model Catalog

    fileprivate func refreshModels(apiKey: String? = nil) async -> Bool {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? normalizedAPIKey else {
            return false
        }

        let fetchedSTTModels = await fetchSTTModels(apiKey: key)
        let fetchedTTSModels = await fetchTTSModels(apiKey: key)

        var didFetch = false
        if !fetchedSTTModels.isEmpty {
            setFetchedModels(fetchedSTTModels)
            didFetch = true
        }
        if !fetchedTTSModels.isEmpty {
            setFetchedTTSModels(fetchedTTSModels)
            didFetch = true
        }
        return didFetch
    }

    fileprivate func fetchSTTModels(apiKey: String) async -> [SonioxFetchedModel] {
        do {
            let request = try Self.makeSTTModelsRequest(apiKey: apiKey, regionID: _selectedRegion.id)
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }
            return try Self.parseSTTModelsResponse(data)
        } catch {
            return []
        }
    }

    fileprivate func fetchTTSModels(apiKey: String) async -> [SonioxFetchedTTSModel] {
        do {
            let request = try Self.makeTTSModelsRequest(apiKey: apiKey, regionID: _selectedRegion.id)
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }
            return try Self.parseTTSModelsResponse(data)
        } catch {
            return []
        }
    }

    fileprivate func setFetchedModels(_ models: [SonioxFetchedModel]) {
        _fetchedModels = Self.sortedModels(models)
        if let data = try? JSONEncoder().encode(_fetchedModels) {
            host?.setUserDefault(data, forKey: SonioxDefaultsKey.fetchedModels)
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func setFetchedTTSModels(_ models: [SonioxFetchedTTSModel]) {
        _fetchedTTSModels = models.sorted { Self.compareModelIDs($0.id, $1.id) }
        if let data = try? JSONEncoder().encode(_fetchedTTSModels) {
            host?.setUserDefault(data, forKey: SonioxDefaultsKey.fetchedTTSModels)
        }
        host?.notifyCapabilitiesChanged()
    }

    static func makeSTTModelsRequest(apiKey: String, regionID: String? = nil) throws -> URLRequest {
        let region = SonioxRegion.resolved(regionID, host: nil)
        guard let url = URL(string: "\(region.apiBaseURL)/v1/models") else {
            throw SonioxPluginError.invalidURL("\(region.apiBaseURL)/v1/models")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        return request
    }

    static func makeTTSModelsRequest(apiKey: String, regionID: String? = nil) throws -> URLRequest {
        let region = SonioxRegion.resolved(regionID, host: nil)
        guard let url = URL(string: "\(region.apiBaseURL)/v1/tts-models") else {
            throw SonioxPluginError.invalidURL("\(region.apiBaseURL)/v1/tts-models")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        return request
    }

    static func parseSTTModelsResponse(_ data: Data) throws -> [SonioxFetchedModel] {
        struct ModelsResponse: Decodable {
            let models: [SonioxFetchedModel]
        }
        return sortedModels(try JSONDecoder().decode(ModelsResponse.self, from: data).models)
    }

    static func parseTTSModelsResponse(_ data: Data) throws -> [SonioxFetchedTTSModel] {
        struct ModelsResponse: Decodable {
            let models: [SonioxFetchedTTSModel]
        }
        return try JSONDecoder().decode(ModelsResponse.self, from: data).models
            .sorted { compareModelIDs($0.id, $1.id) }
    }

    private static func contextPayload(prompt: String?) -> [String: Any]? {
        let terms = PluginDictionaryTerms.terms(fromPrompt: prompt)
        guard !terms.isEmpty else { return nil }
        return ["terms": terms]
    }

    private static func resolvedLanguageHints(requestedLanguage: String?, languageHints: [String]) -> [String] {
        if !languageHints.isEmpty {
            return languageHints
        }
        if let requestedLanguage, !requestedLanguage.isEmpty {
            return [requestedLanguage]
        }
        return []
    }

    private static func emitFinalProgress(
        _ result: PluginTranscriptionResult,
        onProgress: @Sendable (String) -> Bool
    ) {
        _ = onProgress(result.text)
    }

    private static func resolvedRealtimeModelId(_ storedModelId: String?, host: HostServices?) -> String {
        let trimmedModelId = storedModelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelId: String
        switch trimmedModelId {
        case nil, "", "stt-rt-v3", "stt-rt-v4", Self.defaultRealtimeModelId:
            modelId = SonioxModelSelection.automatic
        case let value?:
            modelId = value
        }

        if modelId != storedModelId {
            host?.setUserDefault(modelId, forKey: SonioxDefaultsKey.selectedModel)
        }

        return modelId
    }

    private static func resolvedTTSModelId(_ storedModelId: String?, host: HostServices?) -> String {
        let trimmedModelId = storedModelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelId: String
        switch trimmedModelId {
        case nil, "", Self.defaultTTSModelId:
            modelId = SonioxModelSelection.automatic
        case let value?:
            modelId = value
        }

        if modelId != storedModelId {
            host?.setUserDefault(modelId, forKey: SonioxDefaultsKey.selectedTTSModel)
        }

        return modelId
    }

    private static func resolvedVoiceId(_ storedVoiceId: String?, host: HostServices?) -> String {
        let trimmedVoiceId = storedVoiceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportedIds = Set(fallbackVoices.map(\.id))
        let voiceId = trimmedVoiceId.flatMap { supportedIds.contains($0) ? $0 : nil }
            ?? Self.defaultVoiceId

        if voiceId != storedVoiceId {
            host?.setUserDefault(voiceId, forKey: SonioxDefaultsKey.selectedVoice)
        }

        return voiceId
    }

    private static func realtimeModels(from models: [SonioxFetchedModel]) -> [SonioxFetchedModel] {
        sortedModels(models.filter { $0.transcriptionMode == "real_time" })
    }

    private static func asyncModels(from models: [SonioxFetchedModel]) -> [SonioxFetchedModel] {
        sortedModels(models.filter { $0.transcriptionMode == "async" })
    }

    private static func preferredSTTModelId(
        from models: [SonioxFetchedModel],
        transcriptionMode: String,
        fallback: String
    ) -> String {
        let scoped = transcriptionMode == "async" ? asyncModels(from: models) : realtimeModels(from: models)
        return preferredModelId(
            from: scoped.map { (id: $0.id, aliasedModelId: $0.aliasedModelId) },
            fallback: fallback
        )
    }

    private static func preferredTTSModelId(from models: [SonioxFetchedTTSModel], fallback: String) -> String {
        preferredModelId(
            from: models.map { (id: $0.id, aliasedModelId: $0.aliasedModelId) },
            fallback: fallback
        )
    }

    private static func preferredModelId(
        from models: [(id: String, aliasedModelId: String?)],
        fallback: String
    ) -> String {
        let aliases = models.filter { $0.aliasedModelId != nil }
        if let preferredAlias = aliases.first(where: { model in
            let lowercased = model.id.lowercased()
            return lowercased.contains("latest") || lowercased.contains("default") || lowercased.contains("recommended")
        }) {
            return preferredAlias.id
        }
        return models.max { lhs, rhs in
            compareModelIDs(lhs.id, rhs.id)
        }?.id ?? fallback
    }

    private static func sortedModels(_ models: [SonioxFetchedModel]) -> [SonioxFetchedModel] {
        models.sorted { lhs, rhs in
            compareModelIDs(lhs.id, rhs.id)
        }
    }

    private static func compareModelIDs(_ lhs: String, _ rhs: String) -> Bool {
        let lhsNumbers = versionNumbers(in: lhs)
        let rhsNumbers = versionNumbers(in: rhs)
        if lhsNumbers != rhsNumbers {
            return lhsNumbers.lexicographicallyPrecedes(rhsNumbers)
        }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func versionNumbers(in id: String) -> [Int] {
        id.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    private static func resolvedTTSLanguage(_ language: String?) -> String {
        let supported = Set(sonioxTTSSupportedLanguages)
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, supported.contains(trimmed) {
            return trimmed
        }
        if let prefix = trimmed?.split(separator: "-").first.map(String.init),
           supported.contains(prefix) {
            return prefix
        }
        return "en"
    }

    private func pollUntilCompleted(id: String, apiKey: String) async throws {
        guard let url = URL(string: "\(_selectedRegion.apiBaseURL)/v1/transcriptions/\(id)") else {
            throw PluginTranscriptionError.apiError("Invalid poll URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        for _ in 0..<300 {
            try await Task.sleep(for: .seconds(1))

            let (data, response) = try await PluginHTTPClient.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                continue
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else {
                continue
            }

            switch status {
            case "completed":
                return
            case "error", "failed":
                // Try multiple error field formats
                let errorMsg: String
                if let errStr = json["error"] as? String {
                    errorMsg = errStr
                } else if let errObj = json["error"] as? [String: Any], let msg = errObj["message"] as? String {
                    errorMsg = msg
                } else if let errMsg = json["error_message"] as? String {
                    errorMsg = errMsg
                } else {
                    // Log full response for debugging
                    let responseStr = String(data: data, encoding: .utf8) ?? ""
                    logger.error("Soniox transcription failed, full response: \(responseStr)")
                    errorMsg = "Transcription failed (status: \(status))"
                }
                throw PluginTranscriptionError.apiError(errorMsg)
            default:
                continue
            }
        }

        throw PluginTranscriptionError.apiError("Transcription timed out after 5 minutes")
    }

    private func fetchTranscript(id: String, apiKey: String, language: String?) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: "\(_selectedRegion.apiBaseURL)/v1/transcriptions/\(id)/transcript") else {
            throw PluginTranscriptionError.apiError("Invalid transcript URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Fetch transcript failed HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginTranscriptionError.apiError("Invalid transcript response")
        }

        // Extract full text from tokens or top-level text field
        let text: String
        if let tokens = json["tokens"] as? [[String: Any]] {
            text = tokens.compactMap { $0["text"] as? String }.joined()
        } else {
            text = json["text"] as? String ?? ""
        }

        return PluginTranscriptionResult(text: text, detectedLanguage: language)
    }

    // MARK: - Audio Conversion

    private static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - API Key Validation

    func validateApiKey(_ key: String) async -> Bool {
        let request: URLRequest
        do {
            request = try Self.makeAPIKeyValidationRequest(apiKey: key, regionID: _selectedRegion.id)
        } catch {
            return false
        }

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    static func makeAPIKeyValidationRequest(apiKey: String, regionID: String? = nil) throws -> URLRequest {
        let region = SonioxRegion.resolved(regionID, host: nil)
        guard let url = URL(string: "\(region.apiBaseURL)/v1/files") else {
            throw SonioxPluginError.invalidURL("\(region.apiBaseURL)/v1/files")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        return request
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["error_message"] as? String {
                return message
            }
            if let message = json["message"] as? String {
                return message
            }
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
        }
        if let body = String(data: data, encoding: .utf8), !body.isEmpty {
            return "HTTP \(statusCode): \(body)"
        }
        return "HTTP \(statusCode)"
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(SonioxSettingsView(plugin: self))
    }

    // MARK: - Internal Methods for Settings

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: SonioxDefaultsKey.apiKey, value: key)
            } catch {
                print("[SonioxPlugin] Failed to store API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func removeApiKey() {
        _apiKey = nil
        if let host {
            do {
                try host.storeSecret(key: SonioxDefaultsKey.apiKey, value: "")
            } catch {
                print("[SonioxPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate var selectedRegionIdForSettings: String { _selectedRegion.id }
    fileprivate var selectedModelIdForSettings: String { _selectedModelId ?? SonioxModelSelection.automatic }
    fileprivate var selectedTTSModelIdForSettings: String { _selectedTTSModelId ?? SonioxModelSelection.automatic }
    fileprivate var selectedVoiceIdForSettings: String { selectedVoiceId ?? Self.defaultVoiceId }

    func selectRegion(_ regionId: String) {
        let region = SonioxRegion.resolved(regionId, host: nil)
        _selectedRegion = region
        host?.setUserDefault(region.id, forKey: SonioxDefaultsKey.selectedRegion)
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func selectTTSModel(_ modelId: String) {
        _selectedTTSModelId = Self.resolvedTTSModelId(modelId, host: host)
        host?.setUserDefault(_selectedTTSModelId, forKey: SonioxDefaultsKey.selectedTTSModel)
        host?.notifyCapabilitiesChanged()
    }
}

// MARK: - Settings View

private struct SonioxSettingsView: View {
    let plugin: SonioxPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var originalApiKeyInput = ""
    @State private var selectedModel: String = ""
    @State private var selectedTTSModel: String = ""
    @State private var selectedRegion: String = ""
    @State private var selectedVoice: String = ""
    @State private var isRefreshingModels = false
    private let bundle = Bundle(for: SonioxPlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // API Key Section
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 8) {
                    if showApiKey {
                        TextField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    if plugin.isConfigured, !hasPendingApiKeyChange {
                        Button(String(localized: "Check", bundle: bundle)) {
                            checkApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(trimmedApiKeyInput.isEmpty || isValidating)

                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            originalApiKeyInput = ""
                            validationResult = nil
                            plugin.removeApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    } else {
                        Button(String(localized: "Save", bundle: bundle)) {
                            saveApiKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(trimmedApiKeyInput.isEmpty || isValidating)

                        if plugin.isConfigured {
                            Button(String(localized: "Remove", bundle: bundle)) {
                                apiKeyInput = ""
                                originalApiKeyInput = ""
                                validationResult = nil
                                plugin.removeApiKey()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundStyle(.red)
                        }
                    }
                }

                if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating...", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let result = validationResult {
                    HStack(spacing: 4) {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result ? .green : .red)
                        Text(result ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle))
                            .font(.caption)
                            .foregroundStyle(result ? .green : .red)
                    }
                }

                Picker(String(localized: "Region", bundle: bundle), selection: $selectedRegion) {
                    ForEach(SonioxRegion.all) { region in
                        Text(String(localized: String.LocalizationValue(region.displayNameKey), bundle: bundle))
                            .tag(region.id)
                    }
                }
                .onChange(of: selectedRegion) {
                    plugin.selectRegion(selectedRegion)
                    validationResult = nil
                    if plugin.isConfigured {
                        refreshModels()
                    }
                }
            }

            if plugin.isConfigured {
                Divider()

                // Model Selection
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Realtime model", bundle: bundle)
                            .font(.headline)

                        Spacer()

                        Button {
                            refreshModels()
                        } label: {
                            Label(String(localized: "Refresh", bundle: bundle), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRefreshingModels)
                    }

                    Picker("Realtime model", selection: $selectedModel) {
                        Text("Automatic (Latest)", bundle: bundle).tag(SonioxModelSelection.automatic)
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectModel(selectedModel)
                    }

                    Text("File transcription uses the latest async STT model automatically.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isRefreshingModels {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Refreshing models...", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Text-to-Speech Model", bundle: bundle)
                        .font(.headline)

                    Picker(String(localized: "Text-to-Speech Model", bundle: bundle), selection: $selectedTTSModel) {
                        Text("Automatic (Latest)", bundle: bundle).tag(SonioxModelSelection.automatic)
                        ForEach(plugin.ttsModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .onChange(of: selectedTTSModel) {
                        plugin.selectTTSModel(selectedTTSModel)
                        selectedVoice = plugin.selectedVoiceIdForSettings
                    }

                    Text("Text-to-Speech Voice", bundle: bundle)
                        .font(.headline)

                    Picker(String(localized: "Text-to-Speech Voice", bundle: bundle), selection: $selectedVoice) {
                        ForEach(plugin.availableVoices, id: \.id) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                    }
                    .onChange(of: selectedVoice) {
                        plugin.selectVoice(selectedVoice)
                    }
                }
            }

            Text("API keys are stored securely in the Keychain", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            if let key = plugin._apiKey, !key.isEmpty {
                apiKeyInput = key
                originalApiKeyInput = key
            }
            selectedModel = plugin.selectedModelIdForSettings
            selectedTTSModel = plugin.selectedTTSModelIdForSettings
            selectedRegion = plugin.selectedRegionIdForSettings
            selectedVoice = plugin.selectedVoiceIdForSettings
        }
    }

    private var trimmedApiKeyInput: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasPendingApiKeyChange: Bool {
        trimmedApiKeyInput != originalApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveApiKey() {
        let trimmedKey = trimmedApiKeyInput
        guard !trimmedKey.isEmpty else { return }

        isValidating = true
        validationResult = nil
        Task {
            let isValid = await plugin.validateApiKey(trimmedKey)
            await MainActor.run {
                isValidating = false
                validationResult = isValid
                guard isValid else { return }

                plugin.setApiKey(trimmedKey)
                originalApiKeyInput = trimmedKey
                refreshModels()
            }
        }
    }

    private func checkApiKey() {
        let trimmedKey = trimmedApiKeyInput
        guard !trimmedKey.isEmpty else { return }

        isValidating = true
        validationResult = nil
        Task {
            let isValid = await plugin.validateApiKey(trimmedKey)
            await MainActor.run {
                isValidating = false
                validationResult = isValid
                if isValid {
                    refreshModels()
                }
            }
        }
    }

    private func refreshModels() {
        isRefreshingModels = true
        Task {
            _ = await plugin.refreshModels(apiKey: trimmedApiKeyInput)
            await MainActor.run {
                isRefreshingModels = false
                selectedModel = plugin.selectedModelIdForSettings
                selectedTTSModel = plugin.selectedTTSModelIdForSettings
                selectedVoice = plugin.selectedVoiceIdForSettings
            }
        }
    }
}
