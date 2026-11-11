import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

// MARK: - Transcription Mode

/// How finished recordings are transcribed and whether dictations stream, with
/// AssemblyAI's list price for Universal-3.5 Pro.
enum AssemblyAITranscriptionMode: String, CaseIterable, Sendable {
    /// Dictations stream to the realtime API ($0.45/h of connection time);
    /// recordings and files go to the Sync API.
    case live
    /// Recordings go to the Sync API ($0.30/h); no live preview from AssemblyAI.
    case sync
    /// Recordings go to the Dictation API ($0.62/h), which returns the text
    /// cleaned up; no live preview from AssemblyAI.
    case dictation
    /// Recordings go to the async API ($0.21/h); no live preview from AssemblyAI.
    case async
}

// MARK: - Plugin Entry Point

@objc(AssemblyAIPlugin)
final class AssemblyAIPlugin: NSObject,
    StructuredTranscriptionEnginePlugin,
    DictionaryTermsCapabilityProviding,
    DictionaryTermsBudgetProviding,
    LiveTranscriptionModelSupportProviding,
    LiveTranscriptionProgressModeProviding,
    TranscriptPreviewFallbackPolicyProviding,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.assemblyai"
    static let pluginName = "AssemblyAI"
    static let speakerDiarizationEnabledKey = "speakerDiarizationEnabled"
    static let transcriptionModeKey = "transcriptionMode"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _speakerDiarizationEnabled = false
    fileprivate var _transcriptionMode = AssemblyAITranscriptionMode.live

    private let logger = Logger(subsystem: "com.typewhisper.assemblyai", category: "Plugin")

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        let storedModelId = host.userDefault(forKey: "selectedModel") as? String
        let resolvedModel = AssemblyAIModelCatalog.resolve(storedModelId)
        _selectedModelId = resolvedModel.id
        if storedModelId != resolvedModel.id {
            host.setUserDefault(resolvedModel.id, forKey: "selectedModel")
        }
        _speakerDiarizationEnabled = host.userDefault(forKey: Self.speakerDiarizationEnabledKey) as? Bool ?? false
        _transcriptionMode = (host.userDefault(forKey: Self.transcriptionModeKey) as? String)
            .flatMap(AssemblyAITranscriptionMode.init(rawValue:)) ?? .live
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "assemblyai" }
    var providerDisplayName: String { "AssemblyAI" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        AssemblyAIModelCatalog.all.map(\.modelInfo)
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        let resolvedModel = AssemblyAIModelCatalog.resolve(modelId)
        let changed = _selectedModelId != resolvedModel.id
        _selectedModelId = resolvedModel.id
        host?.setUserDefault(resolvedModel.id, forKey: "selectedModel")
        if changed {
            // Live sessions, streaming and the preview depend on the model.
            host?.notifyCapabilitiesChanged()
        }
    }

    var supportsTranslation: Bool { false }
    /// Dictations stream through live sessions; finished audio always goes to the Sync or
    /// async API, which are faster than replaying it at the realtime API's 1.25x limit.
    var supportsStreaming: Bool { supportsLiveTranscriptionSession(forModelId: nil) }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }
    var dictionaryTermsBudget: DictionaryTermsBudget {
        AssemblyAIModelCatalog.resolve(_selectedModelId).dictionaryTermsBudget
    }
    var isSpeakerDiarizationEnabled: Bool { _speakerDiarizationEnabled }
    /// Dictations leave speaker labels out, since AssemblyAI bills them and the host drops them.
    private var diarizesRequest: Bool { _speakerDiarizationEnabled && PluginSpeakerLabels.areRequested }
    var transcriptionMode: AssemblyAITranscriptionMode { _transcriptionMode }

    var supportedLanguages: [String] {
        AssemblyAIModelCatalog.resolve(_selectedModelId).supportedLanguages
    }

    // MARK: - Live Sessions

    /// Universal-3.5 Pro streams while the dictation is recorded in the Live mode.
    /// Universal-2 and recordings with speaker labels transcribe after the recording.
    func supportsLiveTranscriptionSession(forModelId modelId: String?) -> Bool {
        guard _transcriptionMode == .live, !_speakerDiarizationEnabled else { return false }
        if case .universal35Pro = AssemblyAIModelCatalog.resolve(modelId ?? _selectedModelId).streamingConfiguration {
            return true
        }
        return false
    }

    /// Finished turns plus the current partial turn cover the whole recording.
    var liveTranscriptionProgressMode: LiveTranscriptionProgressMode { .completeSnapshot }

    /// A live session that cannot start leaves the recording without preview instead of
    /// sending the last seconds again every few seconds. The Sync and async modes show no
    /// preview for any model, so they cost what their price says. The rule depends on the
    /// mode alone because TypeWhisper reads it for the saved model when a profile's model
    /// override has no live session.
    var allowsTranscriptPreviewFallback: Bool {
        _transcriptionMode == .live && !supportsLiveTranscriptionSession(forModelId: nil)
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }
        guard supportsLiveTranscriptionSession(forModelId: modelId) else {
            throw PluginTranscriptionError.apiError("\(modelId) does not stream with these settings")
        }
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()

        let keyterms = Self.streamingKeyterms(fromPrompt: prompt, modelId: modelId)
        if keyterms.droppedCount > 0 {
            logger.info(
                "AssemblyAI live session streams \(keyterms.terms.count, privacy: .public) dictionary terms; the final text comes from the recording, which keeps all of them"
            )
        }
        guard let url = Self.makeStreamingURL(
            modelId: modelId,
            language: language,
            keytermsPromptJSON: Self.jsonString(from: keyterms.terms)
        ) else {
            throw PluginTranscriptionError.apiError("Invalid streaming URL")
        }

        // The realtime API takes at most 100 terms of up to 50 characters. With more, the
        // session streams the ones that fit for the preview, and the recording is
        // transcribed with all of them for the final text.
        var finalTranscriber: AssemblyAILiveTranscriptionSession.FinalTranscriber?
        if keyterms.droppedCount > 0 {
            let speakerDiarizationEnabled = diarizesRequest
            finalTranscriber = { @Sendable [self] audio in
                Self.legacyResult(from: try await self.transcribeRecording(
                    audio: audio,
                    language: language,
                    modelId: modelId,
                    apiKey: apiKey,
                    prompt: prompt,
                    speakerDiarizationEnabled: speakerDiarizationEnabled
                ))
            }
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        return try await AssemblyAILiveTranscriptionSession.connect(
            socket: URLSessionAssemblyAIRealtimeSocket(request: request),
            language: Self.streamingLanguage(language, modelId: modelId),
            finalTranscriber: finalTranscriber,
            onProgress: onProgress
        )
    }

    /// The dictionary terms the realtime API takes: at most 100, each up to 50 characters.
    static func streamingKeyterms(fromPrompt prompt: String?, modelId: String) -> (terms: [String], droppedCount: Int) {
        let rawTerms = PluginDictionaryTerms.clippedTerms(
            from: PluginDictionaryTerms.terms(fromPrompt: prompt),
            budget: AssemblyAIModelCatalog.resolve(modelId).dictionaryTermsBudget
        )
        let terms = Array(rawTerms.filter { $0.count <= 50 }.prefix(100))
        return (terms, rawTerms.count - terms.count)
    }

    /// The language the realtime session is steered to, as the transcript reports it.
    static func streamingLanguage(_ language: String?, modelId: String) -> String? {
        guard case .universal35Pro(_, let supportedLanguageCodes) = AssemblyAIModelCatalog.resolve(modelId).streamingConfiguration,
              let code = languageCode(language),
              supportedLanguageCodes.contains(code) else {
            return nil
        }
        return code
    }

    /// A requested language as AssemblyAI's language codes write it, or nil for automatic.
    static func languageCode(_ language: String?) -> String? {
        guard let code = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !code.isEmpty else {
            return nil
        }
        return code
    }

    // MARK: - Transcription (REST Fallback)

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        try await Self.legacyResult(from: transcribeStructured(
            audio: audio,
            language: language,
            translate: translate,
            prompt: prompt
        ))
    }

    func transcribeStructured(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginStructuredTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        return try await transcribeRecording(
            audio: audio,
            language: language,
            modelId: modelId,
            apiKey: apiKey,
            prompt: prompt,
            speakerDiarizationEnabled: diarizesRequest
        )
    }

    // MARK: - Transcription With Progress

    /// Finished audio, such as a file or a preview window: the Sync or async API, then the
    /// text as progress. Dictations stream through live sessions instead.
    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        let result = try await transcribe(audio: audio, language: language, translate: translate, prompt: prompt)
        _ = onProgress(result.text)
        return result
    }

    // MARK: - Finished Recordings

    /// Tries the Sync API first and falls back to the async API, which handles
    /// every model, speaker labels and recordings of any length.
    private func transcribeRecording(
        audio: AudioData,
        language: String?,
        modelId: String,
        apiKey: String,
        prompt: String?,
        speakerDiarizationEnabled: Bool
    ) async throws -> PluginStructuredTranscriptionResult {
        if _transcriptionMode != .async, let syncRequest = Self.makeSyncRequest(
            modelId: modelId,
            language: language,
            prompt: prompt,
            speakerDiarizationEnabled: speakerDiarizationEnabled,
            audioDuration: audio.duration
        ) {
            do {
                return try await transcribeSync(
                    audio: audio,
                    request: syncRequest,
                    apiKey: apiKey,
                    cleanedUp: _transcriptionMode == .dictation
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw error
                }
                if case PluginTranscriptionError.invalidApiKey = error {
                    throw error
                }
                logger.warning(
                    "AssemblyAI sync transcription failed, falling back to the async API: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return try await transcribeREST(
            audio: audio,
            language: language,
            modelId: modelId,
            apiKey: apiKey,
            prompt: prompt,
            speakerDiarizationEnabled: speakerDiarizationEnabled
        )
    }

    // MARK: - Sync Implementation

    struct SyncRequest: Equatable {
        let modelId: String
        let language: String?
        let keyterms: [String]

        var config: [String: Any] {
            var config: [String: Any] = [:]
            if let language {
                config["language_codes"] = [language]
            }
            if !keyterms.isEmpty {
                config["keyterms_prompt"] = keyterms
            }
            return config
        }
    }

    /// Returns nil when the recording needs the async API: a model without a
    /// sync endpoint, speaker labels, a language or dictionary the sync
    /// endpoint would reject or cut, or audio over its length limit.
    static func makeSyncRequest(
        modelId: String,
        language: String?,
        prompt: String?,
        speakerDiarizationEnabled: Bool,
        audioDuration: TimeInterval
    ) -> SyncRequest? {
        let model = AssemblyAIModelCatalog.resolve(modelId)
        guard let sync = model.syncConfiguration,
              !speakerDiarizationEnabled,
              audioDuration <= sync.maximumAudioDuration else {
            return nil
        }

        let syncLanguage = languageCode(language)
        if let syncLanguage, !sync.supportedLanguageCodes.contains(syncLanguage) {
            return nil
        }

        let keyterms = PluginDictionaryTerms.clippedTerms(
            from: PluginDictionaryTerms.terms(fromPrompt: prompt),
            budget: model.dictionaryTermsBudget
        )
        guard keyterms.count <= sync.maximumKeyterms,
              keyterms.reduce(0, { $0 + $1.count }) <= sync.maximumKeytermCharacters else {
            return nil
        }

        return SyncRequest(modelId: sync.modelId, language: syncLanguage, keyterms: keyterms)
    }

    /// With `cleanedUp`, the recording goes to the Dictation API instead, which takes the
    /// same request, always runs Universal-3.6 Pro and returns the text cleaned up. When
    /// `makeSyncRequest` returns nil or this throws, the async fallback has no cleanup.
    private func transcribeSync(
        audio: AudioData,
        request syncRequest: SyncRequest,
        apiKey: String,
        cleanedUp: Bool
    ) async throws -> PluginStructuredTranscriptionResult {
        let text = try await PluginAudioUploadEncoder.withCompressedM4AUploadWavFallback(from: audio) { uploadFile in
            try await sendSyncRequest(syncRequest, uploadFile: uploadFile, apiKey: apiKey, cleanedUp: cleanedUp)
        }
        // The sync response carries no detected language.
        return PluginStructuredTranscriptionResult(text: text, detectedLanguage: syncRequest.language)
    }

    private func sendSyncRequest(
        _ syncRequest: SyncRequest,
        uploadFile: PluginAudioUploadFile,
        apiKey: String,
        cleanedUp: Bool
    ) async throws -> String {
        let endpoint = cleanedUp
            ? "https://dictation.assemblyai.com/v1/transcribe"
            : "https://sync.assemblyai.com/v1/transcribe"
        guard let url = URL(string: endpoint) else {
            throw PluginTranscriptionError.apiError("Invalid sync URL")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        // The Dictation API always runs Universal-3.6 Pro and takes no model header.
        if !cleanedUp {
            request.setValue(syncRequest.modelId, forHTTPHeaderField: "X-AAI-Model")
        }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeSyncRequestBody(
            config: syncRequest.config,
            uploadFile: uploadFile,
            boundary: boundary
        )
        // The server gives up after 30 s; the rest covers the upload.
        request.timeoutInterval = 45

        // A failed Sync request falls back to the async API instead of being sent again:
        // even a Cloudflare 522 can follow a request AssemblyAI received, and a second one
        // would be billed. Only uploads too large for the shared session's resource
        // timeout take the resource-timeout path, which keeps the default policy.
        let resourceTimeout = PluginHTTPClient.resourceTimeout(forUploadOf: uploadFile.data.count)
        let (data, response) = resourceTimeout > Self.sharedSessionResourceTimeout
            ? try await PluginHTTPClient.data(for: request, resourceTimeout: resourceTimeout)
            : try await PluginHTTPClient.data(for: request, retry: .disabled)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw PluginTranscriptionError.invalidApiKey
        case 429: throw PluginTranscriptionError.rateLimited
        default:
            let body = PluginHTTPErrorBodyFormatter.summary(from: data, response: httpResponse)
            throw PluginAudioUploadHTTPFailure(
                statusCode: httpResponse.statusCode,
                responseData: data,
                underlyingError: PluginTranscriptionError.apiError(
                    "Sync transcription failed HTTP \(httpResponse.statusCode): \(body)"
                )
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid sync transcription response")
        }
        // The Dictation API returns the verbatim transcript in `text` and the cleaned-up
        // text in `llm_response`; without a rewrite, the transcript is still usable.
        if cleanedUp, let cleanedText = json["llm_response"] as? String,
           !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleanedText
        }
        return text
    }

    /// `PluginHTTPClient`'s shared session allows 600 s; longer uploads need their own session.
    private static let sharedSessionResourceTimeout: TimeInterval = 600

    static func makeSyncRequestBody(
        config: [String: Any],
        uploadFile: PluginAudioUploadFile,
        boundary: String
    ) throws -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"audio\"; filename=\"\(uploadFile.filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(uploadFile.contentType)\r\n\r\n".utf8))
        body.append(uploadFile.data)
        body.append(Data("\r\n".utf8))
        if !config.isEmpty {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"config\"\r\n".utf8))
            body.append(Data("Content-Type: application/json\r\n\r\n".utf8))
            body.append(try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    // MARK: - REST Implementation (3-Step Async)

    private func transcribeREST(
        audio: AudioData,
        language: String?,
        modelId: String,
        apiKey: String,
        prompt: String?,
        speakerDiarizationEnabled: Bool
    ) async throws -> PluginStructuredTranscriptionResult {
        let uploadURL = try await PluginAudioUploadEncoder.withCompressedM4AUploadWavFallback(from: audio) { uploadFile in
            try await uploadAudio(uploadFile: uploadFile, apiKey: apiKey)
        }
        let transcriptId = try await submitTranscription(
            audioURL: uploadURL,
            modelId: modelId,
            language: language,
            apiKey: apiKey,
            prompt: prompt,
            speakerDiarizationEnabled: speakerDiarizationEnabled
        )
        return try await pollTranscription(
            transcriptId: transcriptId,
            apiKey: apiKey,
            attempts: Self.pollAttempts(forAudioDuration: audio.duration)
        )
    }


    /// Most files finish in under a minute (a 3 h 15 min podcast took 133 s),
    /// but a long recording can wait in a queue. One poll per second for a
    /// quarter of the audio duration, at least five minutes and at most an hour.
    static func pollAttempts(forAudioDuration duration: TimeInterval) -> Int {
        Int(min(max(duration / 4, 300), 3_600))
    }

    private func uploadAudio(uploadFile: PluginAudioUploadFile, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.assemblyai.com/v2/upload") else {
            throw PluginTranscriptionError.apiError("Invalid upload URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = uploadFile.data
        request.timeoutInterval = 120

        let (data, response) = try await PluginHTTPClient.data(
            for: request,
            resourceTimeout: PluginHTTPClient.resourceTimeout(forUploadOf: uploadFile.data.count)
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw PluginTranscriptionError.invalidApiKey
        default:
            let body = PluginHTTPErrorBodyFormatter.summary(from: data, response: httpResponse)
            throw PluginAudioUploadHTTPFailure(
                statusCode: httpResponse.statusCode,
                responseData: data,
                underlyingError: PluginTranscriptionError.apiError(
                    "Upload failed HTTP \(httpResponse.statusCode): \(body)"
                )
            )
        }

        if let htmlPageSummary = PluginHTTPErrorBodyFormatter.htmlPageSummary(
            from: data,
            response: httpResponse
        ) {
            throw PluginTranscriptionError.apiError(
                "Invalid upload response: \(htmlPageSummary)"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uploadUrl = json["upload_url"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid upload response")
        }

        return uploadUrl
    }

    private func submitTranscription(
        audioURL: String,
        modelId: String,
        language: String?,
        apiKey: String,
        prompt: String?,
        speakerDiarizationEnabled: Bool
    ) async throws -> String {
        guard let url = URL(string: "https://api.assemblyai.com/v2/transcript") else {
            throw PluginTranscriptionError.apiError("Invalid transcript URL")
        }

        let body = Self.makeSubmitTranscriptionBody(
            audioURL: audioURL,
            modelId: modelId,
            language: language,
            prompt: prompt,
            speakerDiarizationEnabled: speakerDiarizationEnabled
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw PluginTranscriptionError.invalidApiKey
        case 429: throw PluginTranscriptionError.rateLimited
        default:
            let body = PluginHTTPErrorBodyFormatter.summary(from: data, response: httpResponse)
            throw PluginTranscriptionError.apiError("Submit failed HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcriptId = json["id"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid submit response")
        }

        return transcriptId
    }

    static func makeSubmitTranscriptionBody(
        audioURL: String,
        modelId: String,
        language: String?,
        prompt: String?,
        speakerDiarizationEnabled: Bool
    ) -> [String: Any] {
        let model = AssemblyAIModelCatalog.resolve(modelId)
        var body: [String: Any] = [
            "audio_url": audioURL,
            "speech_models": [model.restModelId],
        ]

        if let lang = language, !lang.isEmpty {
            body["language_code"] = lang
        } else {
            body["language_detection"] = true
        }

        if speakerDiarizationEnabled {
            body["speaker_labels"] = true
        }

        applyDictionaryTerms(prompt: prompt, modelId: model.id, to: &body)
        return body
    }

    static func applyDictionaryTerms(prompt: String?, modelId: String, to body: inout [String: Any]) {
        let model = AssemblyAIModelCatalog.resolve(modelId)
        let terms = PluginDictionaryTerms.clippedTerms(
            from: PluginDictionaryTerms.terms(fromPrompt: prompt),
            budget: model.dictionaryTermsBudget
        )
        guard !terms.isEmpty else { return }

        switch model.dictionaryPayload {
        case .keytermsPrompt:
            body["keyterms_prompt"] = terms
        case .wordBoost(let boostParam):
            body["word_boost"] = terms
            body["boost_param"] = boostParam
        }
    }

    private func pollTranscription(
        transcriptId: String,
        apiKey: String,
        attempts: Int
    ) async throws -> PluginStructuredTranscriptionResult {
        guard let url = URL(string: "https://api.assemblyai.com/v2/transcript/\(transcriptId)") else {
            throw PluginTranscriptionError.apiError("Invalid poll URL")
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        for _ in 0..<attempts {
            try await Task.sleep(for: .seconds(1))

            // Same shape as the other pollers: the loop IS the retry, so it opts out.
            let (data, response) = try await PluginHTTPClient.data(for: request, retry: .disabled)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                continue
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else {
                continue
            }

            switch status {
            case "completed":
                return Self.parseCompletedTranscriptionResponse(json)
            case "error":
                let errorMsg = json["error"] as? String ?? "Unknown transcription error"
                throw PluginTranscriptionError.apiError(errorMsg)
            default:
                continue
            }
        }

        throw PluginTranscriptionError.apiError("Transcription timed out after \(attempts / 60) minutes")
    }

    static func parseCompletedTranscriptionResponse(_ json: [String: Any]) -> PluginStructuredTranscriptionResult {
        let detectedLanguage = json["language_code"] as? String
        let utterances = json["utterances"] as? [[String: Any]] ?? []

        let segments = utterances.compactMap { utterance -> PluginStructuredTranscriptionSegment? in
            let text = (utterance["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let start = milliseconds(from: utterance["start"]) ?? 0
            let end = milliseconds(from: utterance["end"]) ?? start
            let speakerLabel = normalizedSpeakerLabel(from: utterance["speaker"])
            let confidence = double(from: utterance["confidence"])

            return PluginStructuredTranscriptionSegment(
                text: text,
                start: start,
                end: end,
                speakerLabel: speakerLabel,
                speakerConfidence: confidence
            )
        }

        guard !segments.isEmpty else {
            return PluginStructuredTranscriptionResult(
                text: json["text"] as? String ?? "",
                detectedLanguage: detectedLanguage
            )
        }

        let text = segments
            .map { segment in
                if let speakerLabel = segment.speakerLabel {
                    return "\(speakerLabel): \(segment.text)"
                }
                return segment.text
            }
            .joined(separator: "\n")

        return PluginStructuredTranscriptionResult(
            text: text,
            detectedLanguage: detectedLanguage,
            segments: segments
        )
    }

    static func legacyResult(
        from structuredResult: PluginStructuredTranscriptionResult
    ) -> PluginTranscriptionResult {
        PluginTranscriptionResult(
            text: structuredResult.text,
            detectedLanguage: structuredResult.detectedLanguage,
            segments: structuredResult.segments.map {
                PluginTranscriptionSegment(text: $0.text, start: $0.start, end: $0.end)
            }
        )
    }

    private static func normalizedSpeakerLabel(from rawValue: Any?) -> String? {
        let raw: String?
        if let value = rawValue as? String {
            raw = value
        } else if let value = rawValue as? Int {
            raw = "\(value)"
        } else {
            raw = nil
        }

        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.localizedCaseInsensitiveCompare("unknown") == .orderedSame {
            return nil
        }
        if trimmed.localizedCaseInsensitiveContains("speaker") {
            return trimmed
        }
        return "Speaker \(trimmed)"
    }

    private static func milliseconds(from value: Any?) -> Double? {
        double(from: value).map { $0 / 1000.0 }
    }

    private static func double(from value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    // MARK: - Realtime URL

    static func makeStreamingURL(
        modelId: String,
        language: String?,
        keytermsPromptJSON: String?
    ) -> URL? {
        let model = AssemblyAIModelCatalog.resolve(modelId)
        let normalizedLanguage = languageCode(language)
        var queryItems = [URLQueryItem(name: "sample_rate", value: "16000")]

        switch model.streamingConfiguration {
        case .universal2(let englishSpeechModelId, let multilingualSpeechModelId):
            let streamingModel = normalizedLanguage == nil || normalizedLanguage == "en"
                ? englishSpeechModelId
                : multilingualSpeechModelId
            queryItems.append(URLQueryItem(name: "speech_model", value: streamingModel))
            queryItems.append(URLQueryItem(name: "format_turns", value: "true"))
        case .universal35Pro(let speechModelId, let supportedLanguageCodes):
            queryItems.append(URLQueryItem(name: "speech_model", value: speechModelId))
            if let normalizedLanguage,
               supportedLanguageCodes.contains(normalizedLanguage),
               let languageCodesJSON = jsonString(from: [normalizedLanguage]) {
                queryItems.append(URLQueryItem(name: "language_codes", value: languageCodesJSON))
            }
        }

        if let keytermsPromptJSON {
            queryItems.append(URLQueryItem(name: "keyterms_prompt", value: keytermsPromptJSON))
        }

        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")
        components?.queryItems = queryItems
        return components?.url
    }

    private static func jsonString(from values: [String]) -> String? {
        guard !values.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: values) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Audio Conversion

    static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - API Key Validation

    fileprivate func validateApiKey(_ key: String) async -> Bool {
        guard let url = URL(string: "https://api.assemblyai.com/v2/transcript?limit=1") else { return false }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(AssemblyAISettingsView(plugin: self))
    }

    // MARK: - Internal Methods for Settings

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[AssemblyAIPlugin] Failed to store API key: \(error)")
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
                print("[AssemblyAIPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func setTranscriptionMode(_ mode: AssemblyAITranscriptionMode) {
        guard _transcriptionMode != mode else { return }
        _transcriptionMode = mode
        host?.setUserDefault(mode.rawValue, forKey: Self.transcriptionModeKey)
        host?.notifyCapabilitiesChanged()
    }

    func setSpeakerDiarizationEnabled(_ enabled: Bool) {
        guard _speakerDiarizationEnabled != enabled else { return }
        _speakerDiarizationEnabled = enabled
        host?.setUserDefault(enabled, forKey: Self.speakerDiarizationEnabledKey)
        host?.notifyCapabilitiesChanged()
    }
}

// MARK: - Live Session

/// The loudness of the audio a live session sent, in 50 ms windows, to tell whether the
/// audio after the last transcribed word could hold another word.
struct AssemblyAISentAudioLevels: Sendable {
    static let windowSampleCount = AssemblyAILiveTranscriptionSession.sampleRate / 20
    static let windowDuration: TimeInterval = 0.05
    /// A window is quiet below this share of the loudest window (26 dB down), and always
    /// below the absolute level. Speech that soft is unlikely to be transcribed at all,
    /// while room noise in a pause stays below it; anything louder waits for Termination.
    static let relativeQuietLevel: Float = 0.05
    static let absoluteQuietLevel: Float = 0.001
    /// Word end times can come a little early; the audio this soon after does not count.
    static let wordEndTolerance: TimeInterval = 0.1

    private var levels: [Float] = []
    private var partialWindow: [Float] = []

    mutating func append(_ samples: [Float]) {
        partialWindow.append(contentsOf: samples)
        var start = 0
        while partialWindow.count - start >= Self.windowSampleCount {
            levels.append(Self.level(partialWindow[start..<(start + Self.windowSampleCount)]))
            start += Self.windowSampleCount
        }
        partialWindow.removeFirst(start)
    }

    /// Whether every window that ends after `time` (seconds from the first sample) plus
    /// the tolerance is quiet. Audio after the end of the sent audio counts as quiet.
    func isQuiet(after time: TimeInterval) -> Bool {
        var windows = levels
        if !partialWindow.isEmpty {
            windows.append(Self.level(partialWindow[...]))
        }
        let quietLevel = max(Self.absoluteQuietLevel, (windows.max() ?? 0) * Self.relativeQuietLevel)
        let first = max(0, Int(((time + Self.wordEndTolerance) / Self.windowDuration).rounded(.down)))
        guard first < windows.count else { return true }
        return windows[first...].allSatisfy { $0 < quietLevel }
    }

    private static func level(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}

/// The WebSocket a live session talks to, so tests can play the server.
protocol AssemblyAIRealtimeSocket: Sendable {
    func send(text: String) async throws
    func send(audio: Data) async throws
    /// The next text message; throws once the socket is closed.
    func receive() async throws -> String
    func close()
}

final class URLSessionAssemblyAIRealtimeSocket: AssemblyAIRealtimeSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func send(audio: Data) async throws {
        try await task.send(.data(audio))
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

/// Streams a dictation to AssemblyAI's realtime API (v3) while it is recorded, for the
/// live preview and the final text.
///
/// Audio goes out as binary PCM frames of 50 ms to 1 s, the lengths the API accepts.
/// AssemblyAI ends each turn with a formatted `Turn` message. When the recording stops,
/// the session sends `Terminate`; the server answers with the turns for the remaining
/// audio and then `Termination`. The transcript is complete once that arrives, or earlier
/// once no turn is open and the audio after the last word is quiet (see
/// `transcriptCoversSentAudio`). With dictionary terms beyond what the realtime API
/// takes, the final text comes from
/// `finalTranscriber`, which transcribes the recording with all of them, and the
/// realtime transcript is only the preview and the fallback.
/// https://www.assemblyai.com/docs/streaming/message-sequence
actor AssemblyAILiveTranscriptionSession: LiveTranscriptionSession {
    typealias FinalTranscriber = @Sendable (AudioData) async throws -> PluginTranscriptionResult

    static let sampleRate = 16_000
    /// The realtime API rejects frames shorter than 50 ms or longer than 1 s.
    static let minimumFrameSampleCount = sampleRate / 20
    static let maximumFrameSampleCount = sampleRate
    static let startTimeout: Duration = .seconds(10)
    /// `Termination` arrived 0.7 to 1.1 s after `Terminate` in our tests; this also
    /// covers audio the server has not transcribed yet after a slow connection.
    static let finishTimeout: Duration = .seconds(8)

    private static let logger = Logger(subsystem: "com.typewhisper.assemblyai", category: "LiveSession")

    private struct FinishedTurn {
        let text: String
        let words: [PluginWordTiming]
    }

    private let socket: any AssemblyAIRealtimeSocket
    private let language: String?
    private let finalTranscriber: FinalTranscriber?
    private let onProgress: @Sendable (String) -> Bool
    private var receiveTask: Task<Void, Never>?

    private var hasStarted = false
    private var hasSentTerminate = false
    private var isTerminated = false
    private var isClosed = false
    private var isCancelled = false
    private var failure: Error?
    private var pendingSamples: [Float] = []
    private var sentAudioLevels = AssemblyAISentAudioLevels()
    private var recordedSamples: [Float] = []
    private var finishedTurns: [Int: FinishedTurn] = [:]
    private var partialTurnOrder: Int?
    private var partialText = ""
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init(
        socket: any AssemblyAIRealtimeSocket,
        language: String?,
        finalTranscriber: FinalTranscriber?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) {
        self.socket = socket
        self.language = language
        self.finalTranscriber = finalTranscriber
        self.onProgress = onProgress
    }

    /// Opens the session and waits until AssemblyAI began it, so a wrong key or an
    /// exhausted balance fails here instead of during the recording.
    static func connect(
        socket: any AssemblyAIRealtimeSocket,
        language: String?,
        finalTranscriber: FinalTranscriber?,
        startTimeout: Duration = startTimeout,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> AssemblyAILiveTranscriptionSession {
        let session = AssemblyAILiveTranscriptionSession(
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

    /// Finished turns plus the turn in progress.
    var currentText: String {
        var parts = orderedTurns.map(\.text)
        if let partialTurnOrder, finishedTurns[partialTurnOrder] == nil {
            parts.append(partialText)
        }
        return Self.joinedText(parts)
    }

    func appendAudio(samples: [Float]) async throws {
        try throwIfEnded()
        guard !samples.isEmpty else { return }
        if finalTranscriber != nil {
            recordedSamples.append(contentsOf: samples)
        }
        pendingSamples.append(contentsOf: samples)
        try await sendPendingAudio(flush: false)
    }

    func finish() async throws -> PluginTranscriptionResult {
        do {
            try throwIfEnded()
        } catch {
            close()
            throw error
        }

        var terminateError: Error?
        do {
            try await sendPendingAudio(flush: true)
            try await send { try await $0.send(text: #"{"type":"Terminate"}"#) }
            hasSentTerminate = true
        } catch {
            terminateError = error
        }

        if let finalTranscriber {
            let samples = recordedSamples
            recordedSamples = []
            do {
                let result = try await finalTranscriber(AudioData(
                    samples: samples,
                    wavData: PluginWavEncoder.encode(samples),
                    duration: Double(samples.count) / Double(Self.sampleRate)
                ))
                close()
                Self.logger.info("Live session finished with the recording's transcript for dictionary terms")
                return result
            } catch {
                if Task.isCancelled {
                    close()
                    throw CancellationError()
                }
                Self.logger.warning("Transcribing the recording with dictionary terms failed, using the realtime transcript: \(error.localizedDescription, privacy: .public)")
            }
        }

        if let terminateError {
            close()
            throw terminateError
        }

        let isComplete = await wait(timeout: Self.finishTimeout) {
            $0.isTerminated || $0.transcriptCoversSentAudio
        }
        let endedBeforeTermination = !isTerminated
        close()
        guard isComplete else {
            // Without `Termination` the end of the speech may be missing; TypeWhisper then
            // transcribes the whole recording instead.
            throw failure ?? PluginTranscriptionError.apiError("Realtime API did not end the session")
        }

        let text = currentText
        guard !text.isEmpty else {
            throw PluginTranscriptionError.apiError("Realtime API returned no transcript")
        }
        if let partialTurnOrder, finishedTurns[partialTurnOrder] == nil {
            Self.logger.warning("Realtime session ended without the final text of turn \(partialTurnOrder, privacy: .public); using its partial text")
        }

        let turns = orderedTurns
        let segments = turns.compactMap { turn -> PluginTranscriptionSegment? in
            guard let start = turn.words.first?.start, let end = turn.words.last?.end else { return nil }
            return PluginTranscriptionSegment(text: turn.text, start: start, end: end)
        }
        PluginWordTimings.report(turns.flatMap(\.words))
        Self.logger.info(
            "Live session finished with \(turns.count, privacy: .public) turns \(endedBeforeTermination ? "once they covered the audio" : "at Termination", privacy: .public)"
        )
        return PluginTranscriptionResult(text: text, detectedLanguage: language, segments: segments)
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        pendingSamples = []
        recordedSamples = []
        // AssemblyAI bills the session until it is terminated.
        if !hasSentTerminate, !isClosed {
            try? await socket.send(text: #"{"type":"Terminate"}"#)
        }
        close()
        Self.logger.info("Live session cancelled")
    }

    // MARK: Sending

    /// Sends whole frames of buffered audio; `flush` also sends the rest, padded with
    /// silence to the shortest frame the API accepts.
    private func sendPendingAudio(flush: Bool) async throws {
        while pendingSamples.count >= Self.minimumFrameSampleCount || (flush && !pendingSamples.isEmpty) {
            let frameCount = min(pendingSamples.count, Self.maximumFrameSampleCount)
            var frame = Array(pendingSamples.prefix(frameCount))
            pendingSamples.removeFirst(frameCount)
            if frame.count < Self.minimumFrameSampleCount {
                frame += [Float](repeating: 0, count: Self.minimumFrameSampleCount - frame.count)
            }
            let audio = AssemblyAIPlugin.floatToPCM16(frame)
            try await send { try await $0.send(audio: audio) }
            sentAudioLevels.append(frame)
        }
    }

    private func send(_ operation: (any AssemblyAIRealtimeSocket) async throws -> Void) async throws {
        do {
            try await operation(socket)
        } catch {
            let failure = self.failure ?? PluginTranscriptionError.networkError(error.localizedDescription)
            fail(failure)
            throw failure
        }
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
              let messageType = json["type"] as? String else {
            return
        }

        switch messageType {
        case "Begin":
            hasStarted = true
            resumeWaiters()
        case "Turn":
            handleTurn(json)
            reportProgress()
            resumeWaiters()
        case "Termination":
            isTerminated = true
            resumeWaiters()
        case "Error":
            let detail = json["error"] as? String ?? "Unknown realtime error"
            let code = (json["error_code"] as? Int).map { " (\($0))" } ?? ""
            Self.logger.warning("Realtime session failed\(code, privacy: .public): \(detail, privacy: .public)")
            fail(PluginTranscriptionError.apiError(detail + code))
            close()
        default:
            break
        }
    }

    private func handleTurn(_ json: [String: Any]) {
        let order = json["turn_order"] as? Int ?? ((finishedTurns.keys.max() ?? -1) + 1)
        let text = (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard json["end_of_turn"] as? Bool == true else {
            if finishedTurns[order] == nil {
                partialTurnOrder = order
                partialText = text
            }
            return
        }

        // Universal Streaming can send an unformatted final before the formatted one.
        let isFormatted = json["turn_is_formatted"] as? Bool ?? true
        if isFormatted || finishedTurns[order] == nil {
            let words = (json["words"] as? [[String: Any]] ?? []).compactMap(Self.wordTiming)
            finishedTurns[order] = FinishedTurn(text: text, words: words)
        }
        if partialTurnOrder == order {
            partialTurnOrder = nil
            partialText = ""
        }
    }

    private static func wordTiming(_ word: [String: Any]) -> PluginWordTiming? {
        guard let text = word["text"] as? String,
              let start = (word["start"] as? NSNumber)?.doubleValue,
              let end = (word["end"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return PluginWordTiming(text: text, start: start / 1000, end: end / 1000)
    }

    /// After `Terminate`: no turn is open and the audio sent after the last finished word
    /// is quiet, so it holds no word whose turn could still be on its way. Otherwise only
    /// `Termination` completes the transcript; it arrives about half a second after the
    /// last turn.
    var transcriptCoversSentAudio: Bool {
        guard hasSentTerminate,
              partialTurnOrder == nil,
              let lastWordEnd = orderedTurns.last?.words.last?.end else {
            return false
        }
        return sentAudioLevels.isQuiet(after: lastWordEnd)
    }

    private var orderedTurns: [FinishedTurn] {
        finishedTurns.sorted { $0.key < $1.key }.map(\.value).filter { !$0.text.isEmpty }
    }

    private func reportProgress() {
        let text = currentText
        guard !text.isEmpty, !isCancelled else { return }
        _ = onProgress(text)
    }

    private func receiveEnded(_ error: Error) {
        isClosed = true
        if failure == nil, !isCancelled, !isTerminated {
            fail(PluginTranscriptionError.networkError("Realtime session closed: \(error.localizedDescription)"))
        }
        resumeWaiters()
    }

    /// Joins turns with a space, except between Chinese or Japanese characters,
    /// which are written without spaces.
    static func joinedText(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            let part = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let last = result.unicodeScalars.last, let first = part.unicodeScalars.first,
               !(writesWithoutSpaces(last) && writesWithoutSpaces(first)) {
                result += " "
            }
            result += part
        }
        return result
    }

    private static func writesWithoutSpaces(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, // CJK punctuation, Hiragana, Katakana
             0x31F0...0x31FF, // Katakana extensions
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0xFF00...0xFFEF, // Halfwidth and fullwidth forms
             0x20000...0x3FFFF: // CJK Extensions B and later
            return true
        default:
            return false
        }
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
            close()
            if Task.isCancelled { throw CancellationError() }
            throw failure ?? PluginTranscriptionError.networkError("Realtime session did not start")
        }
    }

    /// Waits until `condition` holds, the session fails or closes, or `timeout` passes.
    private func wait(
        timeout: Duration,
        until condition: (isolated AssemblyAILiveTranscriptionSession) -> Bool
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

// MARK: - Settings View

private struct AssemblyAISettingsView: View {
    let plugin: AssemblyAIPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var speakerDiarizationEnabled = false
    @State private var transcriptionMode = AssemblyAITranscriptionMode.live
    private let bundle = Bundle(for: AssemblyAIPlugin.self)

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

                    if plugin.isConfigured {
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
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result ? .green : .red)
                            .accessibilityHidden(true)
                        Text(result ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle))
                            .font(.caption)
                            .foregroundStyle(result ? .green : .red)
                    }
                }
            }

            if plugin.isConfigured {
                Divider()

                // Model Selection
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
                }

                transcriptionModeSection

                Toggle(String(localized: "Speaker diarization", bundle: bundle), isOn: $speakerDiarizationEnabled)
                    .onChange(of: speakerDiarizationEnabled) {
                        plugin.setSpeakerDiarizationEnabled(speakerDiarizationEnabled)
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
            }
            selectedModel = plugin.selectedModelId ?? plugin.transcriptionModels.first?.id ?? ""
            speakerDiarizationEnabled = plugin.isSpeakerDiarizationEnabled
            transcriptionMode = plugin.transcriptionMode
        }
    }

    /// Universal-2 has only the async API, so the modes apply to Universal-3.5 Pro.
    private var selectedModelHasModes: Bool {
        AssemblyAIModelCatalog.resolve(selectedModel).syncConfiguration != nil
    }

    private var transcriptionModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcription", bundle: bundle)
                .font(.headline)

            Picker(String(localized: "Transcription", bundle: bundle), selection: $transcriptionMode) {
                Text("Live – $0.45/h", bundle: bundle)
                    .tag(AssemblyAITranscriptionMode.live)
                Text("Sync – $0.30/h", bundle: bundle)
                    .tag(AssemblyAITranscriptionMode.sync)
                Text("Dictation – $0.62/h", bundle: bundle)
                    .tag(AssemblyAITranscriptionMode.dictation)
                Text("Async – $0.21/h", bundle: bundle)
                    .tag(AssemblyAITranscriptionMode.async)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(!selectedModelHasModes)
            .onChange(of: transcriptionMode) {
                plugin.setTranscriptionMode(transcriptionMode)
            }

            Group {
                if !selectedModelHasModes {
                    Text("Universal-2 always uses the async API, at $0.15/h.", bundle: bundle)
                } else {
                    switch transcriptionMode {
                    case .live:
                        Text("Streams dictations that show a live preview: the preview shows AssemblyAI's text, and the final text is ready right after you stop. Billed for the time the connection is open. Recordings, files and dictations without a preview use the Sync API. With more than 100 dictionary terms or a term longer than 50 characters, the recording is also transcribed with all of them, which is billed in addition.", bundle: bundle)
                    case .sync:
                        Text("Uploads the recording when you stop; the text is usually ready in under half a second. No live preview from AssemblyAI.", bundle: bundle)
                    case .dictation:
                        Text("Uploads the recording when you stop and returns it cleaned up by Universal-3.6 Pro: filler words removed, punctuation and capitalization fixed. No live preview from AssemblyAI. Recordings over 20 minutes, more than 100 dictionary terms, speaker diarization, a language it doesn't support, or a failed request use the async API with the selected model instead, without cleanup.", bundle: bundle)
                    case .async:
                        Text("Lowest price; the text takes a few seconds after you stop. No live preview from AssemblyAI.", bundle: bundle)
                    }
                    if speakerDiarizationEnabled {
                        Text("Speaker diarization always uses the async API.", bundle: bundle)
                    }
                }
                Text("AssemblyAI list prices in November 2026; add-ons such as dictionary terms can cost extra.", bundle: bundle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveApiKey() {
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        plugin.setApiKey(trimmedKey)

        isValidating = true
        validationResult = nil
        Task {
            let isValid = await plugin.validateApiKey(trimmedKey)
            await MainActor.run {
                isValidating = false
                validationResult = isValid
            }
        }
    }
}
