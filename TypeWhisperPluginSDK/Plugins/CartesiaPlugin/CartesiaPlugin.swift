import AVFoundation
import Foundation
import SwiftUI
import TypeWhisperPluginSDK
import os

private enum CartesiaDefaultsKey {
    static let apiKey = "api-key"
    static let transcriptionLanguage = "transcriptionLanguage"
    static let selectedVoice = "selectedVoice"
    static let customVoiceId = "customVoiceId"
    static let fetchedVoices = "fetchedVoices"
}

private enum CartesiaPluginError: LocalizedError {
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

enum CartesiaAPIKeyValidationResult: Equatable {
    case valid
    case invalidKey
    case transientError
}

struct CartesiaFetchedVoice: Codable, Sendable, Hashable {
    let id: String
    let name: String?
    let language: String?
    let country: String?

    var displayName: String {
        let trimmedName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? id : trimmedName
    }

    var localeIdentifier: String? {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty else {
            return nil
        }
        let country = country?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let country, !country.isEmpty else { return language }
        return "\(language)-\(country)"
    }
}

struct CartesiaLanguageOption: Sendable, Hashable, Identifiable {
    let code: String
    let displayName: String

    var id: String { code }
}

protocol CartesiaTTSAudioPlayback: AnyObject, Sendable {
    var onDrained: (@Sendable () -> Void)? { get set }
    func start(sampleRate: Int) throws
    func appendPCM16(_ data: Data) throws
    func finishInput()
    func stop()
}

final class CartesiaTTSPlaybackSession: TTSPlaybackSession, @unchecked Sendable {
    private struct State {
        var isActive = true
        var onFinish: (@Sendable () -> Void)?
    }

    private let audioPlayback: CartesiaTTSAudioPlayback
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(audioPlayback: CartesiaTTSAudioPlayback) {
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

private final class CartesiaAVAudioPlayback: CartesiaTTSAudioPlayback, @unchecked Sendable {
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
            throw CartesiaPluginError.playbackUnavailable("Could not create audio format")
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
            throw CartesiaPluginError.playbackUnavailable("Audio playback was not started")
        }
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw CartesiaPluginError.playbackUnavailable("PCM16 audio data must contain whole samples.")
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

@objc(CartesiaPlugin)
final class CartesiaPlugin: NSObject,
    TranscriptionEnginePlugin,
    LanguageHintTranscriptionEnginePlugin,
    TTSProviderPlugin,
    PluginAuthRoleStatusProviding,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.cartesia"
    static let pluginName = "Cartesia"

    static let apiBaseURL = "https://api.cartesia.ai"
    static let apiVersion = "2026-03-01"
    static let sttModelId = "ink-whisper"
    static let defaultTranscriptionLanguage = "en"
    static let ttsModelId = "sonic-3.5"
    static let ttsSampleRate = 44_100
    static let defaultVoiceId = "6ccbfb76-1fc6-48f7-b71d-91ac6298247b"
    static var fallbackVoices: [PluginVoiceInfo] {
        [
            PluginVoiceInfo(
                id: defaultVoiceId,
                displayName: String(localized: "Default Voice", bundle: pluginModuleBundle),
                localeIdentifier: "en"
            )
        ]
    }

    static let sttSupportedLanguages = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
        "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
        "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
        "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
        "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "lo", "lt",
        "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my",
        "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt", "ro",
        "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq", "sr",
        "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl", "tr",
        "tt", "uk", "ur", "uz", "vi", "yi", "yo", "yue", "zh",
    ]

    static let ttsSupportedLanguages = [
        "ar", "bg", "bn", "cs", "da", "de", "el", "en", "es", "fi",
        "fr", "gu", "he", "hi", "hr", "hu", "id", "it", "ja", "ka",
        "kn", "ko", "ml", "mr", "ms", "nl", "no", "pa", "pl", "pt",
        "ro", "ru", "sk", "sv", "ta", "te", "th", "tl", "tr", "uk",
        "vi", "zh",
    ]

    static var sttLanguageOptions: [CartesiaLanguageOption] {
        sttSupportedLanguages
            .map { CartesiaLanguageOption(code: $0, displayName: displayName(forLanguageCode: $0)) }
            .sorted { lhs, rhs in
                if lhs.code == defaultTranscriptionLanguage { return true }
                if rhs.code == defaultTranscriptionLanguage { return false }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private let logger = Logger(subsystem: "com.typewhisper.cartesia", category: "Plugin")
    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _transcriptionLanguage = CartesiaPlugin.defaultTranscriptionLanguage
    fileprivate var _selectedVoiceId: String?
    fileprivate var _customVoiceId = ""
    fileprivate var _fetchedVoices: [CartesiaFetchedVoice] = []

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: CartesiaDefaultsKey.apiKey)
        _transcriptionLanguage = Self.resolvedLanguage(
            host.userDefault(forKey: CartesiaDefaultsKey.transcriptionLanguage) as? String,
            supportedLanguages: Self.sttSupportedLanguages
        ) ?? Self.defaultTranscriptionLanguage
        _selectedVoiceId = host.userDefault(forKey: CartesiaDefaultsKey.selectedVoice) as? String
            ?? Self.defaultVoiceId
        _customVoiceId = host.userDefault(forKey: CartesiaDefaultsKey.customVoiceId) as? String ?? ""
        if let data = host.userDefault(forKey: CartesiaDefaultsKey.fetchedVoices) as? Data,
           let voices = try? JSONDecoder().decode([CartesiaFetchedVoice].self, from: data) {
            _fetchedVoices = voices
        }
    }

    func deactivate() {
        host = nil
        _apiKey = nil
        _transcriptionLanguage = Self.defaultTranscriptionLanguage
        _selectedVoiceId = Self.defaultVoiceId
        _customVoiceId = ""
        _fetchedVoices = []
    }

    func authStatus(for role: PluginAuthRole) -> PluginAuthRoleStatus {
        switch role {
        case .transcription, .tts:
            guard normalizedAPIKey != nil else {
                return .unavailable(
                    reason: "Cartesia requires a Cartesia API key.",
                    requiredCredentialLabel: "Cartesia API key"
                )
            }
            return .available
        case .llm:
            return .unavailable(
                reason: "Cartesia does not provide a TypeWhisper prompt processor.",
                requiredCredentialLabel: nil
            )
        }
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "cartesia" }
    var providerDisplayName: String { "Cartesia" }

    var isConfigured: Bool {
        normalizedAPIKey != nil
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: Self.sttModelId, displayName: "Ink Whisper"),
        ]
    }

    var selectedModelId: String? { Self.sttModelId }

    func selectModel(_ modelId: String) {}

    var supportsTranslation: Bool { false }
    var supportedLanguages: [String] { Self.sttSupportedLanguages }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        try await transcribe(
            audio: audio,
            language: language,
            languageHints: [],
            prompt: prompt
        )
    }

    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        try await transcribe(
            audio: audio,
            language: languageSelection.requestedLanguage,
            languageHints: languageSelection.languageHints,
            prompt: prompt
        )
    }

    private func transcribe(
        audio: AudioData,
        language: String?,
        languageHints: [String],
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }

        let resolvedLanguage = Self.resolvedTranscriptionLanguage(
            requestedLanguage: language,
            languageHints: languageHints,
            configuredLanguage: _transcriptionLanguage
        )
        let request = try Self.makeTranscriptionRequest(
            wavData: audio.wavData,
            apiKey: apiKey,
            modelId: Self.sttModelId,
            language: resolvedLanguage
        )

        let (data, response) = try await PluginHTTPClient.data(for: request)
        try Self.validateHTTPResponse(data: data, response: response)
        return try Self.parseTranscriptionResponse(
            data,
            fallbackLanguage: resolvedLanguage
        )
    }

    // MARK: - TTSProviderPlugin

    var availableVoices: [PluginVoiceInfo] {
        if !_fetchedVoices.isEmpty {
            return _fetchedVoices.map {
                PluginVoiceInfo(id: $0.id, displayName: $0.displayName, localeIdentifier: $0.localeIdentifier)
            }
        }
        return Self.fallbackVoices
    }

    var selectedVoiceId: String? {
        let custom = _customVoiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return custom
        }
        return _selectedVoiceId ?? Self.defaultVoiceId
    }

    var settingsSummary: String? {
        let speechLanguage = Self.displayName(forLanguageCode: _transcriptionLanguage)
        let voice = availableVoices.first { $0.id == selectedVoiceId }?.displayName
            ?? selectedVoiceId
            ?? String(localized: "Default Voice", bundle: pluginModuleBundle)
        let format = String(localized: "Speech: %@; Voice: %@; Cartesia", bundle: pluginModuleBundle)
        return String(format: format, speechLanguage, voice)
    }

    func selectVoice(_ voiceId: String?) {
        _selectedVoiceId = voiceId ?? Self.defaultVoiceId
        _customVoiceId = ""
        host?.setUserDefault(_selectedVoiceId, forKey: CartesiaDefaultsKey.selectedVoice)
        host?.setUserDefault("", forKey: CartesiaDefaultsKey.customVoiceId)
        host?.notifyCapabilitiesChanged()
    }

    func speak(_ request: TTSSpeakRequest) async throws -> any TTSPlaybackSession {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw CartesiaPluginError.apiError("TTS text is empty.")
        }

        let language = Self.resolvedLanguage(
            request.language,
            supportedLanguages: Self.ttsSupportedLanguages
        ) ?? Self.resolvedLanguage(
            availableVoices.first { $0.id == selectedVoiceId }?.localeIdentifier,
            supportedLanguages: Self.ttsSupportedLanguages
        )

        let urlRequest = try Self.makeTTSRequest(
            apiKey: apiKey,
            text: text,
            voiceId: selectedVoiceId ?? Self.defaultVoiceId,
            language: language,
            modelId: Self.ttsModelId
        )

        let (data, response) = try await PluginHTTPClient.data(for: urlRequest)
        try Self.validateHTTPResponse(data: data, response: response)

        let playback = CartesiaAVAudioPlayback()
        do {
            try playback.start(sampleRate: Self.ttsSampleRate)
            let session = CartesiaTTSPlaybackSession(audioPlayback: playback)
            try playback.appendPCM16(data)
            playback.finishInput()
            return session
        } catch {
            playback.stop()
            throw error
        }
    }

    var settingsView: AnyView? {
        AnyView(CartesiaSettingsView(plugin: self))
    }

    // MARK: - Settings Support

    fileprivate var apiKeyForSettings: String? { _apiKey }
    fileprivate var transcriptionLanguageForSettings: String { _transcriptionLanguage }

    fileprivate func setApiKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host else {
            throw CartesiaPluginError.apiError("Cartesia is not connected to TypeWhisper.")
        }
        try host.storeSecret(key: CartesiaDefaultsKey.apiKey, value: trimmed)
        _apiKey = trimmed
        host.notifyCapabilitiesChanged()
    }

    fileprivate func removeApiKey() throws {
        guard let host else {
            throw CartesiaPluginError.apiError("Cartesia is not connected to TypeWhisper.")
        }
        try host.storeSecret(key: CartesiaDefaultsKey.apiKey, value: "")
        _apiKey = nil
        host.notifyCapabilitiesChanged()
    }

    fileprivate func setCustomVoiceId(_ voiceId: String) {
        _customVoiceId = voiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        host?.setUserDefault(_customVoiceId, forKey: CartesiaDefaultsKey.customVoiceId)
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func selectTranscriptionLanguage(_ language: String) {
        let resolved = Self.resolvedLanguage(
            language,
            supportedLanguages: Self.sttSupportedLanguages
        ) ?? Self.defaultTranscriptionLanguage
        guard resolved != _transcriptionLanguage else { return }
        _transcriptionLanguage = resolved
        host?.setUserDefault(resolved, forKey: CartesiaDefaultsKey.transcriptionLanguage)
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func validateApiKey(_ key: String) async -> CartesiaAPIKeyValidationResult {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalidKey
        }

        do {
            let request = try Self.makeListVoicesRequest(apiKey: key, limit: 1)
            let (data, response) = try await PluginHTTPClient.data(for: request)
            return Self.apiKeyValidationResult(data: data, response: response)
        } catch {
            return .transientError
        }
    }

    fileprivate func refreshVoices() async -> [CartesiaFetchedVoice] {
        guard let apiKey = normalizedAPIKey else { return [] }
        do {
            let request = try Self.makeListVoicesRequest(apiKey: apiKey, limit: 100)
            let (data, response) = try await PluginHTTPClient.data(for: request)
            try Self.validateHTTPResponse(data: data, response: response)
            let voices = try Self.parseVoicesResponse(data)
            setFetchedVoices(voices)
            return voices
        } catch {
            logger.error("Failed to fetch Cartesia voices: \(error.localizedDescription)")
            return []
        }
    }

    fileprivate func setFetchedVoices(_ voices: [CartesiaFetchedVoice]) {
        _fetchedVoices = voices
        if let data = try? JSONEncoder().encode(voices) {
            host?.setUserDefault(data, forKey: CartesiaDefaultsKey.fetchedVoices)
        }
        if selectedVoiceId == nil, let firstVoice = voices.first {
            _selectedVoiceId = firstVoice.id
            host?.setUserDefault(firstVoice.id, forKey: CartesiaDefaultsKey.selectedVoice)
        }
        host?.notifyCapabilitiesChanged()
    }

    private var normalizedAPIKey: String? {
        let trimmed = (_apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension CartesiaPlugin {
    static func resolvedTranscriptionLanguage(
        requestedLanguage: String?,
        languageHints: [String],
        configuredLanguage: String?,
    ) -> String? {
        if let requested = resolvedLanguage(requestedLanguage, supportedLanguages: sttSupportedLanguages) {
            return requested
        }
        for hint in languageHints {
            if let resolved = resolvedLanguage(hint, supportedLanguages: sttSupportedLanguages) {
                return resolved
            }
        }

        return resolvedLanguage(configuredLanguage, supportedLanguages: sttSupportedLanguages)
            ?? Self.defaultTranscriptionLanguage
    }

    static func resolvedLanguage(_ language: String?, supportedLanguages: [String]) -> String? {
        guard let language else { return nil }
        let normalized = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        let primary = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return supportedLanguages.contains(primary) ? primary : nil
    }

    static func displayName(forLanguageCode code: String) -> String {
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
        return "\(name) (\(code))"
    }

    static func makeTranscriptionRequest(
        wavData: Data,
        apiKey: String,
        modelId: String,
        language: String?
    ) throws -> URLRequest {
        guard let url = URL(string: "\(apiBaseURL)/stt") else {
            throw CartesiaPluginError.invalidURL("\(apiBaseURL)/stt")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "Cartesia-Version")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        var body = Data()
        body.appendMultipartFile(
            boundary: boundary,
            name: "file",
            filename: "audio.wav",
            contentType: "audio/wav",
            data: wavData
        )
        body.appendMultipartField(boundary: boundary, name: "model", value: modelId)
        if let language, !language.isEmpty {
            body.appendMultipartField(boundary: boundary, name: "language", value: language)
        }
        body.appendMultipartField(boundary: boundary, name: "timestamp_granularities[]", value: "word")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        return request
    }

    static func makeTTSRequest(
        apiKey: String,
        text: String,
        voiceId: String,
        language: String?,
        modelId: String
    ) throws -> URLRequest {
        guard let url = URL(string: "\(apiBaseURL)/tts/bytes") else {
            throw CartesiaPluginError.invalidURL("\(apiBaseURL)/tts/bytes")
        }

        var body: [String: Any] = [
            "model_id": modelId,
            "transcript": text,
            "voice": [
                "mode": "id",
                "id": voiceId,
            ],
            "output_format": [
                "container": "raw",
                "encoding": "pcm_s16le",
                "sample_rate": ttsSampleRate,
            ],
        ]
        if let language, !language.isEmpty {
            body["language"] = language
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "Cartesia-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func makeListVoicesRequest(apiKey: String, limit: Int) throws -> URLRequest {
        var components = URLComponents(string: "\(apiBaseURL)/voices")
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else {
            throw CartesiaPluginError.invalidURL("\(apiBaseURL)/voices")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "Cartesia-Version")
        request.timeoutInterval = 15
        return request
    }

    static func validateHTTPResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
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

    static func apiKeyValidationResult(data: Data, response: URLResponse) -> CartesiaAPIKeyValidationResult {
        guard let httpResponse = response as? HTTPURLResponse else {
            return .transientError
        }
        switch httpResponse.statusCode {
        case 200:
            return .valid
        case 401, 403:
            return .invalidKey
        default:
            return .transientError
        }
    }

    static func parseTranscriptionResponse(_ data: Data, fallbackLanguage: String?) throws -> PluginTranscriptionResult {
        let response: TranscriptionResponse
        do {
            response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        } catch {
            throw PluginTranscriptionError.apiError("Failed to parse Cartesia transcription response: \(error.localizedDescription)")
        }

        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw PluginTranscriptionError.apiError("Cartesia response did not include transcription text.")
        }

        let segments = (response.words ?? []).map {
            PluginTranscriptionSegment(text: $0.word, start: $0.start, end: $0.end)
        }
        return PluginTranscriptionResult(
            text: text,
            detectedLanguage: response.language ?? fallbackLanguage,
            segments: segments
        )
    }

    static func parseVoicesResponse(_ data: Data) throws -> [CartesiaFetchedVoice] {
        do {
            let response = try JSONDecoder().decode(VoicesResponse.self, from: data)
            return response.data.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        } catch {
            throw CartesiaPluginError.apiError("Failed to parse Cartesia voices response: \(error.localizedDescription)")
        }
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
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

    struct TranscriptionResponse: Decodable {
        let text: String
        let language: String?
        let words: [TranscriptionWord]?
    }

    struct TranscriptionWord: Decodable {
        let word: String
        let start: Double
        let end: Double
    }

    struct VoicesResponse: Decodable {
        let data: [CartesiaFetchedVoice]
    }
}

private struct CartesiaSettingsView: View {
    let plugin: CartesiaPlugin

    @State private var apiKeyInput = ""
    @State private var showApiKey = false
    @State private var isValidating = false
    @State private var isRefreshingVoices = false
    @State private var validationResult: CartesiaAPIKeyValidationResult?
    @State private var settingsErrorMessage: String?
    @State private var transcriptionLanguage = CartesiaPlugin.defaultTranscriptionLanguage
    @State private var voiceOptions: [PluginVoiceInfo] = []
    @State private var selectedVoiceId = ""
    @State private var customVoiceId = ""
    private let bundle = pluginModuleBundle

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 8) {
                    if showApiKey {
                        TextField(String(localized: "API Key", bundle: bundle), text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField(String(localized: "API Key", bundle: bundle), text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    if plugin.isConfigured {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            removeApiKey()
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
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                validationFeedbackView
            }

            if plugin.isConfigured {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Speech Recognition", bundle: bundle)
                        .font(.headline)

                    Picker(String(localized: "Spoken Language", bundle: bundle), selection: $transcriptionLanguage) {
                        ForEach(CartesiaPlugin.sttLanguageOptions) { language in
                            Text(language.displayName).tag(language.code)
                        }
                    }
                    .onChange(of: transcriptionLanguage) {
                        plugin.selectTranscriptionLanguage(transcriptionLanguage)
                    }

                    Text("Spoken Language is the source audio language. Choose English only when the audio itself is English.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Text-to-Speech Voice", bundle: bundle)
                            .font(.headline)
                        Spacer()
                        Button(String(localized: "Refresh", bundle: bundle)) {
                            refreshVoices()
                        }
                        .controlSize(.small)
                        .disabled(isRefreshingVoices)
                    }

                    Picker(String(localized: "Text-to-Speech Voice", bundle: bundle), selection: $selectedVoiceId) {
                        ForEach(voiceOptions, id: \.id) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                    }
                    .onChange(of: selectedVoiceId) {
                        plugin.selectVoice(selectedVoiceId)
                        customVoiceId = ""
                    }

                    HStack(spacing: 8) {
                        TextField(String(localized: "Custom Voice ID", bundle: bundle), text: $customVoiceId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button(String(localized: "Use", bundle: bundle)) {
                            plugin.setCustomVoiceId(customVoiceId)
                            selectedVoiceId = plugin.selectedVoiceId ?? CartesiaPlugin.defaultVoiceId
                        }
                        .controlSize(.small)
                        .disabled(customVoiceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            Text("API keys are stored securely in the Keychain", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            apiKeyInput = plugin.apiKeyForSettings ?? ""
            refreshLocalVoiceState()
        }
    }

    @ViewBuilder
    private var validationFeedbackView: some View {
        if isValidating {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Validating...", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let settingsErrorMessage {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(settingsErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } else if let validationResult {
            let feedback = validationFeedback(for: validationResult)
            HStack(spacing: 4) {
                Image(systemName: feedback.systemName)
                    .foregroundStyle(feedback.color)
                Text(feedback.message)
                    .font(.caption)
                    .foregroundStyle(feedback.color)
            }
        }
    }

    private func saveApiKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isValidating = true
        validationResult = nil
        settingsErrorMessage = nil

        Task {
            let result = await plugin.validateApiKey(trimmed)
            await MainActor.run {
                isValidating = false
                validationResult = result
                guard result == .valid else { return }
                do {
                    try plugin.setApiKey(trimmed)
                    refreshLocalVoiceState()
                } catch {
                    validationResult = nil
                    settingsErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func removeApiKey() {
        do {
            try plugin.removeApiKey()
            apiKeyInput = ""
            validationResult = nil
            settingsErrorMessage = nil
            refreshLocalVoiceState()
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    private func refreshVoices() {
        isRefreshingVoices = true
        Task {
            _ = await plugin.refreshVoices()
            await MainActor.run {
                isRefreshingVoices = false
                refreshLocalVoiceState()
            }
        }
    }

    private func refreshLocalVoiceState() {
        transcriptionLanguage = plugin.transcriptionLanguageForSettings
        voiceOptions = plugin.availableVoices
        selectedVoiceId = plugin.selectedVoiceId ?? CartesiaPlugin.defaultVoiceId
        customVoiceId = plugin._customVoiceId
    }

    private func validationFeedback(
        for result: CartesiaAPIKeyValidationResult
    ) -> (systemName: String, message: String, color: Color) {
        switch result {
        case .valid:
            return (
                "checkmark.circle.fill",
                String(localized: "Valid API Key", bundle: bundle),
                .green
            )
        case .invalidKey:
            return (
                "xmark.circle.fill",
                String(localized: "Invalid API Key", bundle: bundle),
                .red
            )
        case .transientError:
            return (
                "exclamationmark.triangle.fill",
                String(localized: "Could not validate API Key. Check your connection and try again.", bundle: bundle),
                .orange
            )
        }
    }
}

private let pluginModuleBundle: Bundle = {
#if SWIFT_PACKAGE
    Bundle.module
#else
    Bundle(for: CartesiaPlugin.self)
#endif
}()

private extension Data {
    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append(value.data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(
        boundary: String,
        name: String,
        filename: String,
        contentType: String,
        data: Data
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
