import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

// Screenshot automation blocks provider requests, so an automatic key check could only fail.
enum ElevenLabsAutomaticValidationPolicy {
    static func allowsValidationOnAppear(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        !arguments.contains("--store-screenshots")
    }
}

/// Scribe's documented languages and the further codes its API accepts. It
/// rejects "jw", "haw" and "vo"; Javanese is "jv".
private let elevenLabsSupportedLanguages = [
    "af", "am", "ar", "as", "ast", "az", "ba", "be", "bg", "bn",
    "bo", "br", "bs", "ca", "ceb", "cs", "cy", "da", "de", "el",
    "en", "es", "et", "eu", "fa", "fi", "fo", "fr", "ga", "gl",
    "gu", "ha", "he", "hi", "hr", "ht", "hu", "hy", "id", "ig",
    "is", "it", "ja", "jv", "ka", "kea", "kk", "km", "kn", "ko",
    "ku", "ky", "la", "lb", "lg", "ln", "lo", "lt", "luo", "lv",
    "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my", "ne",
    "nl", "nn", "no", "nso", "oc", "or", "pa", "pl", "ps", "pt",
    "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
    "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
    "tr", "tt", "uk", "umb", "ur", "uz", "vi", "wo", "xh", "yi",
    "yo", "yue", "zh", "zu",
]

private actor ElevenLabsTranscriptCollector {
    private var finals: [String] = []
    private var interim = ""
    private var detectedLanguage: String?
    private var timedWords: [PluginWordTiming] = []

    func addWords(_ words: [PluginWordTiming]) {
        timedWords += words
    }

    func words() -> [PluginWordTiming] {
        timedWords
    }

    func addFinal(_ text: String, language: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, finals.last != trimmed {
            finals.append(trimmed)
        }
        if let language, !language.isEmpty {
            detectedLanguage = language
        }
        interim = ""
    }

    func setInterim(_ text: String, language: String? = nil) {
        interim = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let language, !language.isEmpty {
            detectedLanguage = language
        }
    }

    func currentText() -> String {
        var parts = finals
        if !interim.isEmpty {
            parts.append(interim)
        }
        return parts.joined(separator: " ")
    }

    func finalizedText() -> String {
        let final = finals.joined(separator: " ")
        if !final.isEmpty {
            return final
        }
        return currentText()
    }

    func finalLanguage(fallback: String?) -> String? {
        detectedLanguage ?? fallback
    }
}

private enum ElevenLabsReceivePayload: Sendable {
    case text(String)
    case data(Data)
    case timedOut
}

enum ElevenLabsTranscriptionMode: String, CaseIterable, Sendable {
    case automatic
    case restOnly
}

enum ElevenLabsTranscriptionTransport: Equatable, Sendable {
    case rest
    case realtime
}

enum ElevenLabsSettingsAccessibility {
    static let cleanTranscript = "ElevenLabsCleanTranscript"
    static let audioEvents = "ElevenLabsAudioEvents"
    static let speakerCount = "ElevenLabsSpeakerCount"
    static let useDictionaryTerms = "ElevenLabsUseDictionaryTerms"
}

enum ElevenLabsAPIKeyValidationResult: Equatable, Sendable {
    case valid
    case invalid(message: String?)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var errorMessage: String? {
        guard case .invalid(let message) = self else { return nil }
        return message
    }
}

private struct ElevenLabsAPIErrorResponse: Decodable {
    struct Detail: Decodable {
        let message: String?
        let status: String?
    }

    let detail: Detail?
}

@objc(ElevenLabsPlugin)
final class ElevenLabsPlugin: NSObject,
    DictionaryTermHintTranscriptionEnginePlugin,
    LiveDictionaryTermHintTranscriptionCapablePlugin,
    LiveTranscriptionModelSupportProviding,
    LiveTranscriptionProgressModeProviding,
    TranscriptPreviewFallbackPolicyProviding,
    DictionaryTermsCapabilityProviding,
    DictionaryTermsBudgetProviding,
    @unchecked Sendable {
    static let pluginId = "com.typewhisper.elevenlabs"
    private static let missingUserReadPermissionMessage =
        "The API key you used is missing the permission user_read to execute this operation."
    private static let invalidKeytermCharacters = CharacterSet(charactersIn: "<>{}[]\\")
    static let pluginName = "ElevenLabs"
    static let transcriptionModeKey = "transcriptionMode"
    static let tagAudioEventsKey = "tagAudioEvents"
    static let noVerbatimKey = "noVerbatim"
    static let speakerCountKey = "numSpeakers"
    static let useDictionaryTermsKey = "useDictionaryTerms"
    static let automaticSpeakerCount = 0
    static let defaultSpeakerCount = 1
    static let maximumSpeakerCount = 32
    static let maximumKeytermCount = 1_000
    static let maximumKeytermCharacterCount = 49
    static let maximumKeytermWordCount = 5
    static let defaultModelId = "scribe_v2"
    static let medicalModelId = "scribe_v2_medical"
    /// The realtime API commits on its own after about 36 seconds of audio,
    /// and no message marks the transcript of the final commit. A recording
    /// sent as one stream ends one second after the first committed
    /// transcript, so a longer one could lose its end. Recordings that fit
    /// into one commit stream; longer ones go to the batch endpoint, which
    /// transcribes them many times faster than real time.
    static let maximumRealtimeAudioDuration: TimeInterval = 30

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _transcriptionMode = ElevenLabsTranscriptionMode.automatic
    fileprivate var _tagAudioEvents = false
    fileprivate var _noVerbatim = true
    fileprivate var _speakerCount = ElevenLabsPlugin.defaultSpeakerCount
    fileprivate var _useDictionaryTerms = true

    private let logger = Logger(subsystem: "com.typewhisper.elevenlabs", category: "Plugin")

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        // Selections of retired models, such as the deprecated Scribe v1, move to Scribe v2.
        _selectedModelId = (host.userDefault(forKey: "selectedModel") as? String)
            .flatMap { id in transcriptionModels.contains { $0.id == id } ? id : nil }
            ?? Self.defaultModelId
        _transcriptionMode = (host.userDefault(forKey: Self.transcriptionModeKey) as? String)
            .flatMap(ElevenLabsTranscriptionMode.init(rawValue:))
            ?? .automatic
        _tagAudioEvents = host.userDefault(forKey: Self.tagAudioEventsKey) as? Bool ?? false
        _noVerbatim = host.userDefault(forKey: Self.noVerbatimKey) as? Bool ?? true
        _speakerCount = Self.normalizedSpeakerCount(
            host.userDefault(forKey: Self.speakerCountKey) as? Int ?? Self.defaultSpeakerCount
        )
        _useDictionaryTerms = host.userDefault(forKey: Self.useDictionaryTermsKey) as? Bool ?? true
    }

    func deactivate() {
        host = nil
    }

    var providerId: String { "elevenlabs" }
    var providerDisplayName: String { "ElevenLabs" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: Self.defaultModelId, displayName: "Scribe v2"),
            PluginModelInfo(id: Self.medicalModelId, displayName: "Scribe v2 Medical"),
        ]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        let streamedBefore = supportsStreaming
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
        if supportsStreaming != streamedBefore {
            host?.notifyCapabilitiesChanged()
        }
    }

    /// Scribe v2 Medical is a batch model; only Scribe v2 has a realtime variant.
    static func modelStreams(_ modelId: String?) -> Bool {
        modelId != medicalModelId
    }

    var transcriptionMode: ElevenLabsTranscriptionMode { _transcriptionMode }
    var tagAudioEvents: Bool { _tagAudioEvents }
    var noVerbatim: Bool { _noVerbatim }
    var speakerCount: Int { _speakerCount }
    var useDictionaryTerms: Bool { _useDictionaryTerms }

    func setTranscriptionMode(_ mode: ElevenLabsTranscriptionMode) {
        guard _transcriptionMode != mode else { return }
        _transcriptionMode = mode
        host?.setUserDefault(mode.rawValue, forKey: Self.transcriptionModeKey)
        host?.notifyCapabilitiesChanged()
    }

    func setTagAudioEvents(_ enabled: Bool) {
        guard _tagAudioEvents != enabled else { return }
        _tagAudioEvents = enabled
        host?.setUserDefault(enabled, forKey: Self.tagAudioEventsKey)
    }

    func setNoVerbatim(_ enabled: Bool) {
        guard _noVerbatim != enabled else { return }
        _noVerbatim = enabled
        host?.setUserDefault(enabled, forKey: Self.noVerbatimKey)
    }

    func setSpeakerCount(_ speakerCount: Int) {
        let normalized = Self.normalizedSpeakerCount(speakerCount)
        guard _speakerCount != normalized else { return }
        _speakerCount = normalized
        host?.setUserDefault(normalized, forKey: Self.speakerCountKey)
    }

    func setUseDictionaryTerms(_ enabled: Bool) {
        guard _useDictionaryTerms != enabled else { return }
        _useDictionaryTerms = enabled
        host?.setUserDefault(enabled, forKey: Self.useDictionaryTermsKey)
        host?.notifyCapabilitiesChanged()
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { _transcriptionMode == .automatic && Self.modelStreams(_selectedModelId) }
    var dictionaryTermsSupport: DictionaryTermsSupport {
        _useDictionaryTerms ? .supported : .requiresPluginSetting
    }
    var dictionaryTermsBudget: DictionaryTermsBudget {
        DictionaryTermsBudget(
            maxTerms: Self.maximumKeytermCount,
            maxCharsPerTerm: Self.maximumKeytermCharacterCount,
            maxWordsPerTerm: Self.maximumKeytermWordCount
        )
    }
    var supportedLanguages: [String] { elevenLabsSupportedLanguages }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        return try await transcribeREST(
            audio: audio,
            language: language,
            modelId: modelId,
            apiKey: apiKey,
            keyterms: activeKeyterms(prompt: prompt, dictionaryTermHints: [])
        )
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint]
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        return try await transcribeREST(
            audio: audio,
            language: language,
            modelId: modelId,
            apiKey: apiKey,
            keyterms: activeKeyterms(prompt: prompt, dictionaryTermHints: dictionaryTermHints)
        )
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        try await transcribe(
            audio: audio,
            language: language,
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: [],
            onProgress: onProgress
        )
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        let keyterms = activeKeyterms(prompt: prompt, dictionaryTermHints: dictionaryTermHints)
        if transcriptionTransport(modelId: modelId, keyterms: keyterms, audioDuration: audio.duration) == .rest {
            let result = try await transcribeREST(
                audio: audio,
                language: language,
                modelId: modelId,
                apiKey: apiKey,
                keyterms: keyterms
            )
            _ = onProgress(result.text)
            return result
        }

        return try await Self.transcribeWithRESTFallback(
            realtime: {
                try await self.transcribeWebSocket(
                    audio: audio,
                    language: language,
                    apiKey: apiKey,
                    noVerbatim: self._noVerbatim,
                    onProgress: onProgress
                )
            },
            rest: {
                try await self.transcribeREST(
                    audio: audio,
                    language: language,
                    modelId: modelId,
                    apiKey: apiKey,
                    keyterms: keyterms
                )
            },
            onRealtimeFailure: { error in
                self.logger.warning("Realtime transcription failed, falling back to REST: \(error.localizedDescription)")
            }
        )
    }

    // MARK: Live Sessions

    /// Scribe v2 streams in Auto mode; Scribe v2 Medical and REST only transcribe after
    /// the recording, so TypeWhisper previews those on a local engine instead.
    func supportsLiveTranscriptionSession(forModelId modelId: String?) -> Bool {
        _transcriptionMode == .automatic && Self.modelStreams(modelId ?? _selectedModelId)
    }

    /// Committed segments plus the current partial transcript cover the whole recording.
    var liveTranscriptionProgressMode: LiveTranscriptionProgressMode { .completeSnapshot }

    /// A live session that cannot start, for example at the concurrency limit, leaves the
    /// recording without preview instead of sending the last seconds again every few seconds.
    var allowsTranscriptPreviewFallback: Bool {
        !supportsLiveTranscriptionSession(forModelId: nil)
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            language: language,
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: [],
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }
        guard supportsLiveTranscriptionSession(forModelId: modelId) else {
            throw PluginTranscriptionError.apiError("\(modelId) does not stream in this transcription mode")
        }
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()

        var request = URLRequest(url: try Self.realtimeURL(language: language, noVerbatim: _noVerbatim))
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        // The realtime API wraps transcripts in quotation marks with keyterms, so the
        // session streams without them for the preview, and the batch API transcribes
        // the recording with them for the final text.
        let keyterms = activeKeyterms(prompt: prompt, dictionaryTermHints: dictionaryTermHints)
        var finalTranscriber: ElevenLabsLiveTranscriptionSession.FinalTranscriber?
        if !keyterms.isEmpty {
            finalTranscriber = { @Sendable [self] audio in
                try await self.transcribeREST(
                    audio: audio,
                    language: language,
                    modelId: modelId,
                    apiKey: apiKey,
                    keyterms: keyterms
                )
            }
        }

        return try await ElevenLabsLiveTranscriptionSession.connect(
            socket: URLSessionElevenLabsRealtimeSocket(request: request),
            language: language,
            finalTranscriber: finalTranscriber,
            onProgress: onProgress
        )
    }

    static func transcribeWithRESTFallback(
        realtime: () async throws -> PluginTranscriptionResult,
        rest: () async throws -> PluginTranscriptionResult,
        onRealtimeFailure: (Error) -> Void = { _ in }
    ) async throws -> PluginTranscriptionResult {
        do {
            return try await realtime()
        } catch {
            onRealtimeFailure(error)
            return try await rest()
        }
    }

    private func transcribeREST(
        audio: AudioData,
        language: String?,
        modelId: String,
        apiKey: String,
        keyterms: [String]
    ) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text") else {
            throw PluginTranscriptionError.apiError("Invalid ElevenLabs REST URL")
        }
        let timeouts = Self.restTimeouts(forAudioDuration: audio.duration)

        let transcript = try await PluginAudioUploadEncoder.withCompressedM4AUploadWavFallback(from: audio) { uploadFile in
            let boundary = UUID().uuidString
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeouts.request

            var body = Data()
            body.appendMultipartFile(
                boundary: boundary,
                name: "file",
                filename: uploadFile.filename,
                contentType: uploadFile.contentType,
                data: uploadFile.data
            )
            body.appendMultipartField(boundary: boundary, name: "model_id", value: modelId)
            if let language, !language.isEmpty {
                body.appendMultipartField(boundary: boundary, name: "language_code", value: language)
            }
            body.appendMultipartField(boundary: boundary, name: "timestamps_granularity", value: "word")
            body.appendMultipartField(
                boundary: boundary,
                name: "tag_audio_events",
                value: Self.formattedBoolean(_tagAudioEvents)
            )
            body.appendMultipartField(
                boundary: boundary,
                name: "no_verbatim",
                value: Self.formattedBoolean(_noVerbatim)
            )
            if _speakerCount != Self.automaticSpeakerCount {
                body.appendMultipartField(
                    boundary: boundary,
                    name: "num_speakers",
                    value: String(_speakerCount)
                )
            }
            // Scribe v2 and Scribe v2 Medical both take keyterms.
            for term in keyterms {
                body.appendMultipartField(boundary: boundary, name: "keyterms", value: term)
            }
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body

            let (data, response) = try await PluginHTTPClient.data(for: request, resourceTimeout: timeouts.resource)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw PluginTranscriptionError.apiError("No HTTP response")
            }

            switch httpResponse.statusCode {
            case 200:
                if let htmlPageSummary = PluginHTTPErrorBodyFormatter.htmlPageSummary(
                    from: data,
                    response: httpResponse
                ) {
                    throw PluginTranscriptionError.apiError(
                        "Invalid ElevenLabs response: \(htmlPageSummary)"
                    )
                }
                return try ElevenLabsTimedTranscriptParser.parse(data, fallbackLanguage: language)
            case 401:
                throw Self.unauthorizedError(from: data)
            case 413:
                throw PluginTranscriptionError.fileTooLarge
            case 429:
                throw PluginTranscriptionError.rateLimited
            default:
                let body = PluginHTTPErrorBodyFormatter.summary(from: data, response: httpResponse)
                throw PluginAudioUploadHTTPFailure(
                    statusCode: httpResponse.statusCode,
                    responseData: data,
                    underlyingError: PluginTranscriptionError.apiError(
                        "HTTP \(httpResponse.statusCode): \(body)"
                    )
                )
            }
        }
        PluginWordTimings.report(transcript.words)
        return transcript.result
    }

    private func transcribeWebSocket(
        audio: AudioData,
        language: String?,
        apiKey: String,
        noVerbatim: Bool,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()
        let url = try Self.realtimeURL(language: language, noVerbatim: noVerbatim)

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let wsTask = URLSession.shared.webSocketTask(with: request)
        wsTask.resume()

        let collector = ElevenLabsTranscriptCollector()

        let receiveTask = Task {
            var receivedCommittedTranscript = false

            while !Task.isCancelled {
                let timeout: Duration = receivedCommittedTranscript ? .seconds(1) : .seconds(8)
                let payload = try await Self.receivePayload(from: wsTask, timeout: timeout)

                let rawText: String
                switch payload {
                case .text(let text):
                    rawText = text
                case .data(let data):
                    guard let text = String(data: data, encoding: .utf8) else { continue }
                    rawText = text
                case .timedOut:
                    // Without a committed transcript the partial text may miss
                    // the end of the speech; fail so the REST fallback
                    // transcribes the whole recording.
                    guard receivedCommittedTranscript else {
                        throw PluginTranscriptionError.apiError("Realtime API sent no committed transcript")
                    }
                    return
                }

                guard let data = rawText.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let messageType = json["message_type"] as? String else {
                    continue
                }

                switch messageType {
                case "session_started":
                    continue
                case "partial_transcript":
                    let text = json["text"] as? String ?? ""
                    await collector.setInterim(text)
                    let currentText = await collector.currentText()
                    if !currentText.isEmpty {
                        _ = onProgress(currentText)
                    }
                case "committed_transcript", "committed_transcript_with_timestamps":
                    // With `include_timestamps`, the one manual commit arrives
                    // as both messages with the same text, in either order; the
                    // collector keeps the text once. The one with timestamps
                    // also has the words and language, so the session ends there.
                    receivedCommittedTranscript = true
                    let text = json["text"] as? String ?? ""
                    let detectedLanguage = ElevenLabsLanguageCode.appCode(json["language_code"] as? String)
                    await collector.addFinal(text, language: detectedLanguage)
                    if let words = json["words"] as? [[String: Any]] {
                        await collector.addWords(ElevenLabsTimedTranscriptParser.wordTimings(from: words))
                    }
                    let currentText = await collector.currentText()
                    if !currentText.isEmpty {
                        _ = onProgress(currentText)
                    }
                    if messageType == "committed_transcript_with_timestamps" {
                        return
                    }
                default:
                    if Self.isRealtimeError(messageType) {
                        throw PluginTranscriptionError.apiError(Self.realtimeErrorMessage(from: json) ?? rawText)
                    }
                }
            }
        }

        let pcmData = Self.floatToPCM16(audio.samples)
        guard !pcmData.isEmpty else {
            wsTask.cancel(with: .normalClosure, reason: nil)
            throw PluginTranscriptionError.apiError("No audio available for realtime transcription")
        }

        let chunkSize = 8192
        var offset = 0

        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            let isFinalChunk = end == pcmData.count

            var payload: [String: Any] = [
                "message_type": "input_audio_chunk",
                "audio_base_64": chunk.base64EncodedString(),
                "sample_rate": 16000,
            ]
            if isFinalChunk {
                payload["commit"] = true
            }

            let jsonData = try JSONSerialization.data(withJSONObject: payload)
            guard let jsonText = String(data: jsonData, encoding: .utf8) else {
                throw PluginTranscriptionError.apiError("Failed to encode realtime payload")
            }

            try await wsTask.send(.string(jsonText))
            offset = end
        }

        do {
            try await receiveTask.value
        } catch {
            wsTask.cancel(with: .goingAway, reason: nil)
            throw error
        }

        wsTask.cancel(with: .normalClosure, reason: nil)

        let finalText = await collector.finalizedText()
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginTranscriptionError.apiError("Realtime API returned no transcript")
        }

        let detectedLanguage = await collector.finalLanguage(fallback: language)
        let words = await collector.words()
        if !words.isEmpty {
            PluginWordTimings.report(words)
        }
        return PluginTranscriptionResult(text: finalText, detectedLanguage: detectedLanguage)
    }

    static func transcriptionTransport(
        mode: ElevenLabsTranscriptionMode,
        modelId: String? = nil,
        keyterms: [String],
        audioDuration: TimeInterval
    ) -> ElevenLabsTranscriptionTransport {
        // The realtime API takes keyterms too, but with them it often wraps
        // the whole transcript in quotation marks; the batch API does not.
        mode == .restOnly
            || !modelStreams(modelId)
            || !keyterms.isEmpty
            || audioDuration > maximumRealtimeAudioDuration
            ? .rest
            : .realtime
    }

    func transcriptionTransport(
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        audioDuration: TimeInterval = 0
    ) -> ElevenLabsTranscriptionTransport {
        transcriptionTransport(
            modelId: _selectedModelId,
            keyterms: activeKeyterms(prompt: prompt, dictionaryTermHints: dictionaryTermHints),
            audioDuration: audioDuration
        )
    }

    /// The batch endpoint answers once the whole file is transcribed, about
    /// 78 times faster than real time with Scribe v2, and takes up to 10 hours.
    /// The answer gets 4 s per audio minute, the whole request 4 s per audio
    /// minute more for the upload.
    /// https://elevenlabs.io/docs/capabilities/speech-to-text
    /// https://artificialanalysis.ai/speech-to-text
    static func restTimeouts(forAudioDuration duration: TimeInterval) -> (request: TimeInterval, resource: TimeInterval) {
        let minutes = duration / 60
        return (
            request: min(max(120, minutes * 4), 2_400),
            resource: min(max(600, minutes * 8), 7_200)
        )
    }

    static func validKeyterms(from terms: [String]) -> [String] {
        var valid: [String] = []
        for term in PluginDictionaryTerms.normalizedTerms(from: terms) {
            guard term.count <= maximumKeytermCharacterCount,
                  term.split(whereSeparator: { $0.isWhitespace }).count <= maximumKeytermWordCount,
                  term.rangeOfCharacter(from: invalidKeytermCharacters) == nil else {
                continue
            }

            valid.append(term)
            if valid.count == maximumKeytermCount {
                break
            }
        }
        return valid
    }

    private func activeKeyterms(
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint]
    ) -> [String] {
        guard _useDictionaryTerms else { return [] }
        let terms = dictionaryTermHints.isEmpty
            ? PluginDictionaryTerms.terms(fromPrompt: prompt)
            : dictionaryTermHints.map(\.text)
        return Self.validKeyterms(from: terms)
    }

    private func transcriptionTransport(
        modelId: String?,
        keyterms: [String],
        audioDuration: TimeInterval
    ) -> ElevenLabsTranscriptionTransport {
        Self.transcriptionTransport(
            mode: _transcriptionMode,
            modelId: modelId,
            keyterms: keyterms,
            audioDuration: audioDuration
        )
    }

    static func realtimeURL(language: String?, noVerbatim: Bool) throws -> URL {
        guard var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime") else {
            throw PluginTranscriptionError.apiError("Invalid realtime URL")
        }

        var queryItems = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
            URLQueryItem(name: "no_verbatim", value: formattedBoolean(noVerbatim)),
            URLQueryItem(name: "include_timestamps", value: "true"),
        ]

        if let language, !language.isEmpty {
            queryItems.append(URLQueryItem(name: "language_code", value: language))
        } else {
            // Without it, committed transcripts carry no language code.
            queryItems.append(URLQueryItem(name: "include_language_detection", value: "true"))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PluginTranscriptionError.apiError("Invalid realtime query parameters")
        }

        return url
    }

    static func normalizedSpeakerCount(_ speakerCount: Int) -> Int {
        speakerCount == automaticSpeakerCount || (1...maximumSpeakerCount).contains(speakerCount)
            ? speakerCount
            : defaultSpeakerCount
    }

    private static func formattedBoolean(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func receivePayload(
        from task: URLSessionWebSocketTask,
        timeout: Duration
    ) async throws -> ElevenLabsReceivePayload {
        try await withThrowingTaskGroup(of: ElevenLabsReceivePayload.self) { group in
            group.addTask {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    return .text(text)
                case .data(let data):
                    return .data(data)
                @unknown default:
                    return .timedOut
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }

            let result = try await group.next() ?? .timedOut
            group.cancelAll()
            if case .timedOut = result {
                // `receive()` ignores task cancellation, and the group waits
                // for it, so only closing the socket ends the wait. Before,
                // every realtime transcription waited until ElevenLabs closed
                // the idle session, about 15 seconds. Close only after the
                // timeout was selected: closing earlier can fail the pending
                // `receive()` first, and `next()` would then throw instead.
                task.cancel(with: .normalClosure, reason: nil)
            }
            return result
        }
    }

    /// Realtime errors that end the session. Not all of them say "error",
    /// such as `invalid_request` for an unknown language code, so without this
    /// list the REST fallback would only start after the receive timeout.
    private static let realtimeErrorMessageTypes: Set<String> = [
        "auth_error", "quota_exceeded", "commit_throttled", "unaccepted_terms", "rate_limited",
        "queue_overflow", "resource_exhausted", "session_time_limit_exceeded", "input_error",
        "invalid_request", "chunk_size_exceeded", "insufficient_audio_activity", "transcriber_error",
    ]

    static func isRealtimeError(_ messageType: String) -> Bool {
        realtimeErrorMessageTypes.contains(messageType) || messageType.localizedCaseInsensitiveContains("error")
    }

    static func realtimeErrorMessage(from json: [String: Any]) -> String? {
        if let error = json["error"] as? String, !error.isEmpty {
            return error
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        if let details = json["details"] as? String, !details.isEmpty {
            return details
        }
        return nil
    }

    static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    fileprivate func validateApiKey(_ key: String) async -> ElevenLabsAPIKeyValidationResult {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/user") else {
            return .invalid(message: nil)
        }

        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .invalid(message: nil)
            }
            return Self.apiKeyValidationResult(statusCode: httpResponse.statusCode, data: data)
        } catch {
            return .invalid(message: error.localizedDescription)
        }
    }

    /// ElevenLabs answers HTTP 401 not only for a wrong key but also when a
    /// key's own credit quota is used up or it lacks a permission; those keep
    /// the provider's message instead of "Invalid API key".
    static func unauthorizedError(from data: Data) -> PluginTranscriptionError {
        let detail = try? JSONDecoder().decode(ElevenLabsAPIErrorResponse.self, from: data).detail
        guard let status = detail?.status, status != "invalid_api_key",
              let message = detail?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return .invalidApiKey
        }
        return .apiError(message)
    }

    static func apiKeyValidationResult(statusCode: Int, data: Data) -> ElevenLabsAPIKeyValidationResult {
        guard statusCode != 200 else { return .valid }

        let detail = try? JSONDecoder().decode(ElevenLabsAPIErrorResponse.self, from: data).detail
        let message = detail?.message?.trimmingCharacters(in: .whitespacesAndNewlines)

        // ElevenLabs scopes API keys per endpoint. A key restricted to Speech to Text is valid for
        // this plugin even though the optional user-profile validation endpoint returns HTTP 401.
        if statusCode == 401,
           detail?.status == "missing_permissions",
           message?.caseInsensitiveCompare(Self.missingUserReadPermissionMessage) == .orderedSame {
            return .valid
        }

        return .invalid(message: message?.isEmpty == false ? message : nil)
    }

    var settingsView: AnyView? {
        AnyView(ElevenLabsSettingsView(plugin: self))
    }

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[ElevenLabsPlugin] Failed to store API key: \(error)")
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
                print("[ElevenLabsPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }
}

private struct ElevenLabsSettingsView: View {
    let plugin: ElevenLabsPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: ElevenLabsAPIKeyValidationResult?
    @State private var showApiKey = false
    @State private var selectedModel = ""
    @State private var transcriptionMode = ElevenLabsTranscriptionMode.automatic
    @State private var tagAudioEvents = false
    @State private var noVerbatim = true
    @State private var speakerCount = ElevenLabsPlugin.defaultSpeakerCount
    @State private var useDictionaryTerms = true
    private let bundle = Bundle(for: ElevenLabsPlugin.self)
    private var trimmedInputKey: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var storedKey: String {
        plugin._apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private var hasStoredKey: Bool {
        !storedKey.isEmpty
    }
    private var isEditingStoredKey: Bool {
        hasStoredKey && trimmedInputKey == storedKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 8) {
                    if showApiKey {
                        TextField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel(Text("API Key", bundle: bundle))
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(Text("API Key", bundle: bundle))
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showApiKey ? Text("Hide API key", bundle: bundle) : Text("Show API key", bundle: bundle))

                    if hasStoredKey && isEditingStoredKey && validationResult?.isValid != false {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            validationResult = nil
                            plugin.removeApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                        .accessibilityLabel(Text("Remove API key", bundle: bundle))
                    } else {
                        Button(String(localized: "Save", bundle: bundle)) {
                            saveApiKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(trimmedInputKey.isEmpty || isValidating)
                        .accessibilityLabel(Text("Save API key", bundle: bundle))
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
                        Image(systemName: result.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.isValid ? .green : .red)
                            .accessibilityHidden(true)
                        Text(
                            result.isValid
                                ? String(localized: "Valid API Key", bundle: bundle)
                                : result.errorMessage ?? String(localized: "Invalid API Key", bundle: bundle)
                        )
                        .font(.caption)
                        .foregroundStyle(result.isValid ? .green : .red)
                    }
                }
            }

            if plugin.isConfigured {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Model", bundle: bundle)
                        .font(.headline)

                    Picker(String(localized: "Model", bundle: bundle), selection: $selectedModel) {
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectModel(selectedModel)
                    }

                    if selectedModel == ElevenLabsPlugin.medicalModelId {
                        Text("Tuned for clinical audio, at the Scribe v2 price. Batch only, without realtime streaming.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcription mode", bundle: bundle)
                        .font(.headline)

                    Picker(String(localized: "Transcription mode", bundle: bundle), selection: $transcriptionMode) {
                        Text("Auto (Realtime with REST fallback)", bundle: bundle)
                            .tag(ElevenLabsTranscriptionMode.automatic)
                        Text("REST only (Batch Scribe v2)", bundle: bundle)
                            .tag(ElevenLabsTranscriptionMode.restOnly)
                    }
                    .labelsHidden()
                    .onChange(of: transcriptionMode) {
                        plugin.setTranscriptionMode(transcriptionMode)
                    }

                    Text("Auto streams while you dictate, so the live preview and the final text come from one realtime session, and falls back to batch REST. With active dictionary terms, the final text comes from batch REST, so dictations with a live preview are billed for both. REST only avoids realtime concurrency limits and bills the batch rate.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcription options", bundle: bundle)
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $noVerbatim) {
                            Text("Clean transcript", bundle: bundle)
                        }
                        .accessibilityIdentifier(ElevenLabsSettingsAccessibility.cleanTranscript)
                        .onChange(of: noVerbatim) {
                            plugin.setNoVerbatim(noVerbatim)
                        }

                        Text("Removes filler words, false starts, and other speech disfluencies using ElevenLabs' native non-verbatim mode.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $tagAudioEvents) {
                            Text("Audio events", bundle: bundle)
                        }
                        .accessibilityIdentifier(ElevenLabsSettingsAccessibility.audioEvents)
                        .onChange(of: tagAudioEvents) {
                            plugin.setTagAudioEvents(tagAudioEvents)
                        }

                        Text("Include non-speech events such as [laughter] or [background music]. Applies to REST transcription only.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Audio events and Clean transcript can be enabled together.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Speaker count", bundle: bundle)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Picker(
                            String(localized: "Speaker count", bundle: bundle),
                            selection: $speakerCount
                        ) {
                            Text("Automatic", bundle: bundle)
                                .tag(ElevenLabsPlugin.automaticSpeakerCount)
                            ForEach(1...ElevenLabsPlugin.maximumSpeakerCount, id: \.self) { count in
                                Text(String(count)).tag(count)
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier(ElevenLabsSettingsAccessibility.speakerCount)
                        .onChange(of: speakerCount) {
                            plugin.setSpeakerCount(speakerCount)
                        }

                        Text("Choose Automatic or the maximum number of speakers (1–32). Applies to REST transcription only.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $useDictionaryTerms) {
                            Text("Use TypeWhisper dictionary terms", bundle: bundle)
                        }
                        .accessibilityIdentifier(ElevenLabsSettingsAccessibility.useDictionaryTerms)
                        .onChange(of: useDictionaryTerms) {
                            plugin.setUseDictionaryTerms(useDictionaryTerms)
                        }

                        Text("Sends active TypeWhisper dictionary terms to ElevenLabs as recognition keyterms. ElevenLabs adds a 20% keyterm surcharge.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                if ElevenLabsAutomaticValidationPolicy.allowsValidationOnAppear() {
                    isValidating = true
                    Task {
                        let result = await plugin.validateApiKey(key)
                        await MainActor.run {
                            isValidating = false
                            validationResult = result
                        }
                    }
                }
            }
            selectedModel = plugin.selectedModelId ?? plugin.transcriptionModels.first?.id ?? ""
            transcriptionMode = plugin.transcriptionMode
            tagAudioEvents = plugin.tagAudioEvents
            noVerbatim = plugin.noVerbatim
            speakerCount = plugin.speakerCount
            useDictionaryTerms = plugin.useDictionaryTerms
        }
    }

    private func saveApiKey() {
        let trimmedKey = trimmedInputKey
        guard !trimmedKey.isEmpty else { return }

        isValidating = true
        validationResult = nil

        Task {
            let result = await plugin.validateApiKey(trimmedKey)
            await MainActor.run {
                if result.isValid {
                    plugin.setApiKey(trimmedKey)
                }
                isValidating = false
                validationResult = result
            }
        }
    }
}

private extension Data {
    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
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

// MARK: - Live Session

/// The WebSocket a live session talks to, so tests can play the server.
protocol ElevenLabsRealtimeSocket: Sendable {
    func send(_ text: String) async throws
    /// The next text message; throws once the socket is closed.
    func receive() async throws -> String
    func close()
}

final class URLSessionElevenLabsRealtimeSocket: ElevenLabsRealtimeSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        while true {
            switch try await task.receive() {
            case .string(let text):
                return text
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) { return text }
            @unknown default:
                continue
            }
        }
    }

    func close() {
        // `receive()` ignores task cancellation; only closing the socket ends it.
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// When a live session commits: in a pause once the audio since the last commit
/// approaches the length ElevenLabs recommends, and before ElevenLabs would commit
/// on its own. Without such commits of its own, the session could not tell which
/// committed transcript answers the final commit.
/// https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies
struct ElevenLabsLiveCommitPolicy: Sendable {
    static let sampleRate = 16_000
    /// ElevenLabs recommends a commit every 20 to 30 seconds, ideally in a pause.
    static let pauseCommitAudioDuration: TimeInterval = 20
    /// ElevenLabs commits on its own after about 36 seconds of audio.
    static let maximumUncommittedAudioDuration: TimeInterval = 30
    /// ElevenLabs rejects a commit with less audio than 0.3 s and closes the session.
    static let minimumCommitAudioDuration: TimeInterval = 0.4
    static let pauseDuration: TimeInterval = 0.5
    /// A window counts as quiet below this share of the loudest window since the last commit.
    static let relativeQuietLevel: Float = 0.15
    static let absoluteQuietLevel: Float = 0.003
    private static let windowSampleCount = sampleRate / 10

    private(set) var uncommittedSampleCount = 0
    private var trailingQuietSampleCount = 0
    private var loudestWindowLevel: Float = 0
    private var partialWindow: [Float] = []

    var uncommittedAudioDuration: TimeInterval {
        Double(uncommittedSampleCount) / Double(Self.sampleRate)
    }

    mutating func append(_ samples: [Float]) {
        uncommittedSampleCount += samples.count
        partialWindow.append(contentsOf: samples)
        var start = 0
        while partialWindow.count - start >= Self.windowSampleCount {
            let window = partialWindow[start..<(start + Self.windowSampleCount)]
            start += Self.windowSampleCount
            let level = (window.reduce(Float.zero) { $0 + $1 * $1 } / Float(window.count)).squareRoot()
            loudestWindowLevel = max(loudestWindowLevel, level)
            let quietLevel = max(Self.absoluteQuietLevel, loudestWindowLevel * Self.relativeQuietLevel)
            trailingQuietSampleCount = level < quietLevel ? trailingQuietSampleCount + window.count : 0
        }
        partialWindow.removeFirst(start)
    }

    var shouldCommit: Bool {
        let duration = uncommittedAudioDuration
        if duration >= Self.maximumUncommittedAudioDuration { return true }
        let pause = Double(trailingQuietSampleCount) / Double(Self.sampleRate)
        return duration >= Self.pauseCommitAudioDuration && pause >= Self.pauseDuration
    }

    /// Silence to send before the final commit, so it has enough audio.
    var finalCommitPaddingSampleCount: Int {
        max(0, Int(Self.minimumCommitAudioDuration * Double(Self.sampleRate)) - uncommittedSampleCount)
    }

    mutating func didCommit() {
        uncommittedSampleCount = 0
        trailingQuietSampleCount = 0
        loudestWindowLevel = 0
        partialWindow.removeAll()
    }
}

/// Streams a dictation to the realtime API while it is recorded, for the live preview
/// and the final text.
///
/// The session commits on its own (`commit_strategy=manual`, see
/// `ElevenLabsLiveCommitPolicy`) and once more when the recording stops. Every commit
/// is answered by one `committed_transcript_with_timestamps`, also with empty text for
/// silence, so the transcript is complete once all commits are answered. With active
/// dictionary terms, the final text comes from `finalTranscriber`, the batch API, and the
/// realtime transcript is only the preview: with keyterms, the realtime API often wraps
/// the whole transcript in quotation marks.
actor ElevenLabsLiveTranscriptionSession: LiveTranscriptionSession {
    typealias FinalTranscriber = @Sendable (AudioData) async throws -> PluginTranscriptionResult

    static let startTimeout: Duration = .seconds(10)
    /// Commits are answered within about 0.2 s; this also covers audio the server has
    /// not transcribed yet after a slow connection.
    static let finishTimeout: Duration = .seconds(8)
    static let maximumChunkSampleCount = ElevenLabsLiveCommitPolicy.sampleRate / 2

    private static let logger = Logger(subsystem: "com.typewhisper.elevenlabs", category: "LiveSession")

    private let socket: any ElevenLabsRealtimeSocket
    private let language: String?
    private let onProgress: @Sendable (String) -> Bool
    private let finalTranscriber: FinalTranscriber?
    private var receiveTask: Task<Void, Never>?

    private var hasStarted = false
    private var isClosed = false
    private var isCancelled = false
    private var failure: Error?
    private var commitPolicy = ElevenLabsLiveCommitPolicy()
    private var sentCommitCount = 0
    private var answeredCommitCount = 0
    private var committedTexts: [String] = []
    private var partialText = ""
    private var detectedLanguage: String?
    private var entries: [ElevenLabsTimedTranscriptParser.Entry] = []
    private var recordedSamples: [Float] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init(
        socket: any ElevenLabsRealtimeSocket,
        language: String?,
        finalTranscriber: FinalTranscriber?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) {
        self.socket = socket
        self.language = language
        self.finalTranscriber = finalTranscriber
        self.onProgress = onProgress
    }

    /// Opens the session and waits until ElevenLabs started it, so a wrong key or an
    /// exhausted quota fails here instead of during the recording.
    static func connect(
        socket: any ElevenLabsRealtimeSocket,
        language: String?,
        finalTranscriber: FinalTranscriber?,
        startTimeout: Duration = startTimeout,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> ElevenLabsLiveTranscriptionSession {
        let session = ElevenLabsLiveTranscriptionSession(
            socket: socket,
            language: language,
            finalTranscriber: finalTranscriber,
            onProgress: onProgress
        )
        await session.startReceiving()
        try await withTaskCancellationHandler {
            try await session.waitUntilStarted(timeout: startTimeout)
        } onCancel: {
            socket.close()
        }
        return session
    }

    var currentText: String {
        (committedTexts + [partialText]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func appendAudio(samples: [Float]) async throws {
        try throwIfEnded()
        guard !samples.isEmpty else { return }
        if finalTranscriber != nil {
            recordedSamples.append(contentsOf: samples)
        }

        var start = 0
        while start < samples.count {
            let end = min(start + Self.maximumChunkSampleCount, samples.count)
            let chunk = Array(samples[start..<end])
            try await send(Self.audioMessage(chunk, commit: false))
            commitPolicy.append(chunk)
            start = end
            if commitPolicy.shouldCommit {
                try await commit()
            }
        }
    }

    func finish() async throws -> PluginTranscriptionResult {
        try throwIfEnded()

        var finalCommitError: Error?
        do {
            if commitPolicy.uncommittedSampleCount > 0 || sentCommitCount == 0 {
                let padding = commitPolicy.finalCommitPaddingSampleCount
                if padding > 0 {
                    try await send(Self.audioMessage([Float](repeating: 0, count: padding), commit: false))
                    commitPolicy.append([Float](repeating: 0, count: padding))
                }
                try await commit()
            }
        } catch {
            finalCommitError = error
        }

        if let finalTranscriber {
            let samples = recordedSamples
            recordedSamples = []
            do {
                let result = try await finalTranscriber(AudioData(
                    samples: samples,
                    wavData: PluginWavEncoder.encode(samples),
                    duration: Double(samples.count) / Double(ElevenLabsLiveCommitPolicy.sampleRate)
                ))
                close()
                Self.logger.info("Live session finished with the batch transcript for dictionary terms")
                return result
            } catch {
                if Task.isCancelled {
                    close()
                    throw CancellationError()
                }
                Self.logger.warning("Batch transcription with dictionary terms failed, using the realtime transcript: \(error.localizedDescription, privacy: .public)")
            }
        }

        if let finalCommitError {
            close()
            throw finalCommitError
        }

        let isComplete = await waitUntilAllCommitsAreAnswered(timeout: Self.finishTimeout)
        close()
        guard isComplete else {
            // Without the answer to the last commit, the end of the speech may be missing;
            // TypeWhisper then transcribes the whole recording instead.
            throw failure ?? PluginTranscriptionError.apiError("Realtime API did not answer the last commit")
        }

        let text = committedTexts.joined(separator: " ")
        guard !text.isEmpty else {
            throw PluginTranscriptionError.apiError("Realtime API returned no transcript")
        }
        let transcript = ElevenLabsTimedTranscriptParser.transcript(
            text: text,
            detectedLanguage: detectedLanguage ?? language,
            entries: entries
        )
        PluginWordTimings.report(transcript.words)
        Self.logger.info("Live session finished with \(self.answeredCommitCount, privacy: .public) committed transcripts")
        return transcript.result
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        recordedSamples = []
        close()
        Self.logger.info("Live session cancelled")
    }

    // MARK: Sending

    private func commit() async throws {
        let audioDuration = commitPolicy.uncommittedAudioDuration
        try await send(Self.audioMessage([], commit: true))
        sentCommitCount += 1
        commitPolicy.didCommit()
        Self.logger.info("Realtime commit \(self.sentCommitCount, privacy: .public) after \(String(format: "%.1f", audioDuration), privacy: .public)s of audio")
    }

    private func send(_ message: String) async throws {
        do {
            try await socket.send(message)
        } catch {
            let failure = self.failure ?? PluginTranscriptionError.networkError(error.localizedDescription)
            fail(failure)
            throw failure
        }
    }

    static func audioMessage(_ samples: [Float], commit: Bool) -> String {
        let audio = ElevenLabsPlugin.floatToPCM16(samples).base64EncodedString()
        return #"{"message_type":"input_audio_chunk","audio_base_64":"\#(audio)","sample_rate":16000,"commit":\#(commit)}"#
    }

    // MARK: Receiving

    private func startReceiving() {
        let socket = self.socket
        receiveTask = Task {
            do {
                while true {
                    let message = try await socket.receive()
                    self.handle(message)
                }
            } catch {
                self.receiveEnded(error)
            }
        }
    }

    func handle(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = json["message_type"] as? String else {
            return
        }

        switch messageType {
        case "session_started":
            hasStarted = true
            resumeWaiters()
        case "partial_transcript":
            partialText = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            reportProgress()
        case "committed_transcript_with_timestamps":
            // Each commit also sends `committed_transcript` with the same text, in either
            // order. Only this one counts, because it has the words and the language.
            answeredCommitCount += 1
            let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                committedTexts.append(text)
            }
            if let language = ElevenLabsLanguageCode.appCode(json["language_code"] as? String) {
                detectedLanguage = language
            }
            if let words = json["words"] as? [[String: Any]] {
                entries += ElevenLabsTimedTranscriptParser.entries(from: words)
            }
            partialText = ""
            reportProgress()
            resumeWaiters()
        case "warning":
            Self.logger.info("Realtime warning: \(json["warning"] as? String ?? "", privacy: .public)")
        default:
            if ElevenLabsPlugin.isRealtimeError(messageType) {
                let message = ElevenLabsPlugin.realtimeErrorMessage(from: json) ?? messageType
                Self.logger.warning("Realtime session failed (\(messageType, privacy: .public)): \(message, privacy: .public)")
                fail(PluginTranscriptionError.apiError(message))
                close()
            }
        }
    }

    private func reportProgress() {
        let text = currentText
        guard !text.isEmpty, !isCancelled else { return }
        _ = onProgress(text)
    }

    private func receiveEnded(_ error: Error) {
        isClosed = true
        if failure == nil, !isCancelled {
            fail(PluginTranscriptionError.networkError("Realtime session closed: \(error.localizedDescription)"))
        }
        resumeWaiters()
    }

    // MARK: State

    private func throwIfEnded() throws {
        if isCancelled { throw CancellationError() }
        if let failure { throw failure }
    }

    private func fail(_ error: Error) {
        if failure == nil {
            failure = error
        }
        resumeWaiters()
    }

    private func close() {
        isClosed = true
        socket.close()
        receiveTask?.cancel()
        resumeWaiters()
    }

    private func waitUntilStarted(timeout: Duration) async throws {
        guard await wait(timeout: timeout, until: { $0.hasStarted }) else {
            let error = failure ?? PluginTranscriptionError.networkError("Realtime session did not start")
            close()
            throw error
        }
    }

    private func waitUntilAllCommitsAreAnswered(timeout: Duration) async -> Bool {
        await wait(timeout: timeout) { $0.answeredCommitCount >= $0.sentCommitCount }
    }

    /// Waits until `condition` holds, the session fails or closes, or `timeout` passes.
    private func wait(
        timeout: Duration,
        until condition: (isolated ElevenLabsLiveTranscriptionSession) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            self.resumeWaiters()
        }
        defer { timer.cancel() }

        return await withTaskCancellationHandler {
            while !condition(self) {
                guard failure == nil, !isClosed, !isCancelled, !Task.isCancelled,
                      ContinuousClock.now < deadline else {
                    return false
                }
                await withCheckedContinuation { waiters.append($0) }
            }
            return true
        } onCancel: {
            Task { await self.resumeWaiters() }
        }
    }

    private func resumeWaiters() {
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

// MARK: - Language Codes

/// Scribe's batch endpoint names the detected language in ISO 639-3 ("deu"),
/// the realtime endpoint in ISO 639-1 ("de"). TypeWhisper uses the two-letter
/// code where one exists, so language-specific text formatting applies.
enum ElevenLabsLanguageCode {
    static func appCode(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !code.isEmpty else { return nil }
        guard code.count == 3 else { return code }
        // Mandarin appears as "cmn", which has no two-letter code of its own.
        if code == "cmn" { return "zh" }
        return Locale.LanguageCode(code).identifier(.alpha2) ?? code
    }
}

// MARK: - Timed Transcript

/// The text, word times and segments of one Scribe batch response.
struct ElevenLabsTimedTranscript: Sendable {
    let result: PluginTranscriptionResult
    let words: [PluginWordTiming]
}

/// Reads the `words` array of a Scribe batch response.
///
/// Scribe returns one entry per word, per space between words and per tagged
/// audio event, each with `start` and `end` in seconds. Words become word
/// timings; all entries together become segments, so the segment texts join
/// to the transcript text.
enum ElevenLabsTimedTranscriptParser {
    /// A silence longer than this starts a new segment.
    static let pauseThreshold: TimeInterval = 1.0
    /// A sentence end splits only after this many words, so short answers
    /// such as "Yes." join the next sentence instead of standing alone.
    static let minimumSentenceWordCount = 3
    /// A segment without sentence end or pause is split at the next word
    /// after this length, like the 30-second windows of Whisper.
    static let maximumSegmentDuration: TimeInterval = 30

    private static let sentenceEndCharacters: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "؟", "।"]
    private static let trailingClosers: Set<Character> = ["\"", "'", "”", "’", "»", "«", ")", "]", "」", "』"]

    /// One entry of a `words` array: a word, the spacing after it or an audio event.
    struct Entry: Sendable {
        enum Kind: String, Sendable {
            case word
            case spacing
            case audioEvent = "audio_event"
        }

        let kind: Kind
        let text: String
        let start: Double?
        let end: Double?
    }

    static func parse(_ data: Data, fallbackLanguage: String?) throws -> ElevenLabsTimedTranscript {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginTranscriptionError.apiError("Invalid ElevenLabs response")
        }

        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLanguage = ElevenLabsLanguageCode.appCode(json["language_code"] as? String) ?? fallbackLanguage
        let entries = (json["words"] as? [[String: Any]] ?? []).compactMap(entry(from:))

        return ElevenLabsTimedTranscript(
            result: PluginTranscriptionResult(
                text: text,
                detectedLanguage: detectedLanguage,
                segments: segments(from: entries)
            ),
            words: wordTimings(from: entries)
        )
    }

    /// The word entries of a batch response or realtime commit, without spacing and audio events.
    static func wordTimings(from json: [[String: Any]]) -> [PluginWordTiming] {
        wordTimings(from: entries(from: json))
    }

    /// The entries of a `words` array. Realtime commits time them from the session start,
    /// so the entries of all commits of a session join into one transcript.
    static func entries(from json: [[String: Any]]) -> [Entry] {
        json.compactMap(entry(from:))
    }

    /// The transcript of a realtime session from the text and word entries of its commits.
    static func transcript(text: String, detectedLanguage: String?, entries: [Entry]) -> ElevenLabsTimedTranscript {
        ElevenLabsTimedTranscript(
            result: PluginTranscriptionResult(
                text: text,
                detectedLanguage: detectedLanguage,
                segments: segments(from: entries)
            ),
            words: wordTimings(from: entries)
        )
    }

    static func wordTimings(from entries: [Entry]) -> [PluginWordTiming] {
        entries.compactMap { entry -> PluginWordTiming? in
            guard entry.kind == .word, let start = entry.start, let end = entry.end else { return nil }
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return PluginWordTiming(text: text, start: start, end: max(start, end))
        }
    }

    private static func entry(from json: [String: Any]) -> Entry? {
        guard let text = json["text"] as? String else { return nil }
        let kind = (json["type"] as? String).flatMap(Entry.Kind.init(rawValue:)) ?? .word
        return Entry(
            kind: kind,
            text: text,
            start: (json["start"] as? NSNumber)?.doubleValue,
            end: (json["end"] as? NSNumber)?.doubleValue
        )
    }

    private static func segments(from entries: [Entry]) -> [PluginTranscriptionSegment] {
        var segments: [PluginTranscriptionSegment] = []
        var text = ""
        var start: Double?
        var end: Double?
        var wordCount = 0
        var lastWordEndsSentence = false

        func close() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let start, let end {
                segments.append(PluginTranscriptionSegment(text: trimmed, start: start, end: max(start, end)))
            }
            text = ""
            start = nil
            end = nil
            wordCount = 0
            lastWordEndsSentence = false
        }

        for entry in entries {
            guard entry.kind != .spacing else {
                text += entry.text
                continue
            }

            if let entryStart = entry.start, let segmentStart = start, let segmentEnd = end {
                let pause = entryStart - segmentEnd
                let isLong = entryStart - segmentStart >= maximumSegmentDuration
                let isSentenceDone = lastWordEndsSentence && wordCount >= minimumSentenceWordCount
                if pause > pauseThreshold || isSentenceDone || isLong {
                    close()
                }
            }

            text += entry.text
            if start == nil { start = entry.start ?? end }
            if let entryEnd = entry.end ?? entry.start { end = max(end ?? entryEnd, entryEnd) }
            if entry.kind == .word {
                wordCount += 1
                lastWordEndsSentence = endsSentence(entry.text)
            }
        }
        close()
        return segments
    }

    private static func endsSentence(_ word: String) -> Bool {
        var characters = word.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        while let last = characters.last, trailingClosers.contains(last) {
            characters = characters.dropLast()
        }
        guard let last = characters.last else { return false }
        return sentenceEndCharacters.contains(last)
    }
}
