import Foundation
import os
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Models

/// A Scribe model as the plugin offers it.
struct ZoomScribeModel: Sendable, Equatable {
    let id: String
    let displayName: String
    /// Two-letter codes of the dictation languages it takes.
    let languages: [String]
    /// Whether it uses `vocabulary.phrases`. Zoom's multilingual model accepts the
    /// list but applies none of it (`session.updated` reports `phrase_count: 0`).
    let usesVocabulary: Bool
}

/// How dictations are transcribed.
enum ZoomTranscriptionMode: String, CaseIterable, Sendable {
    /// Dictations with a live preview stream to Scribe's Live mode, which also
    /// writes the final text. Recordings and files use the Fast mode.
    case live
    /// Every recording goes to the Fast mode after it stops.
    case batch
}

// MARK: - Plugin Entry Point

@objc(ZoomPlugin)
public final class ZoomPlugin: NSObject,
    TranscriptionEnginePlugin,
    DictionaryTermsCapabilityProviding,
    DictionaryTermsBudgetProviding,
    LiveTranscriptionModelSupportProviding,
    LiveTranscriptionProgressModeProviding,
    TranscriptPreviewFallbackPolicyProviding,
    @unchecked Sendable
{
    public static var pluginId: String { "com.typewhisper.zoom" }
    public static var pluginName: String { "Zoom Scribe" }

    static let transcriptionModeKey = "transcriptionMode"

    /// One model for ten languages, with language detection. It had the lowest
    /// error rate in Spanish, French and Italian of all models in TypeWhisper's
    /// benchmark (TypeWhisper/typewhisper-benchmark#29).
    static let multilingualModel = ZoomScribeModel(
        id: "zoom-scribe-multilingual",
        displayName: "Scribe Multilingual",
        languages: ["en", "de", "es", "fr", "it", "pt", "ja", "ko", "zh", "ar"],
        usesVocabulary: false
    )
    /// Zoom's model for the dictation language (`zoom-scribe-de` and so on), which
    /// applies dictionary terms. Without a dictation language the multilingual
    /// model detects it instead.
    static let languageModel = ZoomScribeModel(
        id: "zoom-scribe-language",
        displayName: "Scribe Single Language",
        languages: ["en", "de", "es", "fr", "it", "pt", "ja", "zh", "ar"],
        usesVocabulary: true
    )
    /// Zoom's premium English model.
    static let englishProModel = ZoomScribeModel(
        id: "zoom-scribe-en-pro",
        displayName: "Scribe English Pro",
        languages: ["en"],
        usesVocabulary: true
    )
    static let models = [multilingualModel, languageModel, englishProModel]
    static let defaultModel = multilingualModel

    /// Zoom takes at most 100 inline vocabulary phrases.
    static let maxVocabularyPhrases = 100

    typealias LiveSocketFactory = @Sendable (URLRequest) -> any ZoomLiveSocket

    private let lock = NSRecursiveLock()
    private var _host: HostServices?
    private var _selectedModelId: String?
    private var _transcriptionMode = ZoomTranscriptionMode.live
    private let liveSocketFactory: LiveSocketFactory
    private let logger = Logger(subsystem: "com.typewhisper.zoom", category: "Plugin")

    private var host: HostServices? {
        get { lock.withLock { _host } }
        set { lock.withLock { _host = newValue } }
    }

    public var apiKey: String {
        host?.loadSecret(key: "api-key") ?? ""
    }

    public override init() {
        liveSocketFactory = { request in URLSessionZoomLiveSocket(request: request) }
        super.init()
    }

    init(liveSocketFactory: @escaping LiveSocketFactory) {
        self.liveSocketFactory = liveSocketFactory
        super.init()
    }

    public func activate(host: HostServices) {
        lock.withLock {
            _host = host
            let stored = host.userDefault(forKey: "selectedModel") as? String
            _selectedModelId = stored.flatMap { id in Self.models.first { $0.id == id }?.id }
            _transcriptionMode = (host.userDefault(forKey: Self.transcriptionModeKey) as? String)
                .flatMap(ZoomTranscriptionMode.init(rawValue:)) ?? .live
        }
    }

    public func deactivate() {
        lock.withLock { _host = nil }
    }

    public var settingsView: AnyView? {
        AnyView(ZoomSettingsView(plugin: self))
    }

    public func setApiKey(_ key: String) {
        guard let host else {
            logger.error("Failed to save API key: host services not active")
            return
        }
        do {
            try host.storeSecret(key: "api-key", value: key)
            host.notifyCapabilitiesChanged()
        } catch {
            logger.error("Failed to store API key: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func clearApiKey() {
        guard let host else { return }
        do {
            try host.storeSecret(key: "api-key", value: "")
            host.notifyCapabilitiesChanged()
        } catch {
            logger.error("Failed to delete API key: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Checks a key without transcribing anything: Zoom answers a request for an
    /// unknown model with 400 for a valid key and 401 for an invalid one.
    func validateApiKey(_ key: String) async throws -> Bool {
        try await ZoomAPIClient(apiKey: key).validateKey()
    }

    // MARK: - Identity & TranscriptionEnginePlugin

    public var providerId: String { "zoom" }
    public var providerDisplayName: String { "Zoom Scribe" }
    public var isConfigured: Bool { !apiKey.isEmpty }

    public var transcriptionModels: [PluginModelInfo] {
        guard !apiKey.isEmpty else { return [] }
        return Self.models.map {
            PluginModelInfo(id: $0.id, displayName: $0.displayName, languageCount: $0.languages.count)
        }
    }

    public var selectedModelId: String? { lock.withLock { _selectedModelId } }

    public func selectModel(_ modelId: String) {
        let valueToSave = Self.models.first { $0.id == modelId }?.id
        let changed = lock.withLock {
            let changed = _selectedModelId != valueToSave
            _selectedModelId = valueToSave
            return changed
        }
        host?.setUserDefault(valueToSave, forKey: "selectedModel")
        if changed {
            // Languages and dictionary support depend on the model.
            host?.notifyCapabilitiesChanged()
        }
    }

    var selectedModel: ZoomScribeModel {
        let id = lock.withLock { _selectedModelId }
        return Self.models.first { $0.id == id } ?? Self.defaultModel
    }

    var transcriptionMode: ZoomTranscriptionMode { lock.withLock { _transcriptionMode } }

    func setTranscriptionMode(_ mode: ZoomTranscriptionMode) {
        let changed = lock.withLock {
            guard _transcriptionMode != mode else { return false }
            _transcriptionMode = mode
            return true
        }
        guard changed else { return }
        host?.setUserDefault(mode.rawValue, forKey: Self.transcriptionModeKey)
        host?.notifyCapabilitiesChanged()
    }

    public var supportsTranslation: Bool { false }

    /// Dictations stream through live sessions; finished audio goes to the Fast
    /// mode, which is faster than replaying it in real time.
    public var supportsStreaming: Bool { supportsLiveTranscriptionSession(forModelId: nil) }

    public var supportedLanguages: [String] { selectedModel.languages }

    public var dictionaryTermsSupport: DictionaryTermsSupport {
        selectedModel.usesVocabulary ? .supported : .unsupported
    }

    public var dictionaryTermsBudget: DictionaryTermsBudget {
        DictionaryTermsBudget(maxTerms: Self.maxVocabularyPhrases, maxCharsPerTerm: 100)
    }

    func vocabulary(fromPrompt prompt: String?) -> [String] {
        PluginDictionaryTerms.clippedTerms(
            from: PluginDictionaryTerms.terms(fromPrompt: prompt),
            budget: dictionaryTermsBudget
        )
    }

    /// The request for `language` with the selected model.
    func request(language: String?, prompt: String?) -> ZoomAPIClient.Request {
        ZoomAPIClient.Request.make(
            model: selectedModel,
            language: language,
            vocabulary: vocabulary(fromPrompt: prompt)
        )
    }

    // MARK: - Live Sessions

    public func supportsLiveTranscriptionSession(forModelId modelId: String?) -> Bool {
        transcriptionMode == .live
    }

    /// Finished items and the open one make up the whole transcript.
    public var liveTranscriptionProgressMode: LiveTranscriptionProgressMode { .completeSnapshot }

    /// The After recording mode shows no preview, so it costs what the recording
    /// costs instead of sending the last seconds again every few seconds.
    public var allowsTranscriptPreviewFallback: Bool { transcriptionMode == .live }

    public func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        let apiKey = self.apiKey
        guard !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard supportsLiveTranscriptionSession(forModelId: nil) else {
            throw PluginTranscriptionError.apiError("Live transcription is off in the Zoom Scribe settings")
        }
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()
        return try await ZoomLiveTranscriptionSession.connect(
            socket: liveSocketFactory(ZoomAPIClient.liveRequest(apiKey: apiKey)),
            request: request(language: language, prompt: prompt),
            onProgress: onProgress
        )
    }

    // MARK: - Transcription

    /// Recordings, files and dictations without a live session: the Fast mode,
    /// in pieces that keep each request under Zoom's 2 MB limit.
    public func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        let apiKey = self.apiKey
        guard !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        let client = ZoomAPIClient(apiKey: apiKey)
        let request = request(language: language, prompt: prompt)
        return try await PluginAudioChunking.transcribe(
            audio,
            maximumChunkDuration: ZoomAPIClient.maximumChunkDuration
        ) { chunk in
            try await client.transcribe(audio: chunk, request: request)
        }
    }

    public func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        try await transcribe(audio: audio, language: language, translate: translate, prompt: prompt)
    }
}

// MARK: - API Client

struct ZoomAPIClient: Sendable {
    static let fastURL = URL(string: "https://api.zoom.us/v2/aiservices/scribe/transcribe")!
    static let liveURL = URL(string: "wss://api.zoom.us/v2/aiservices/scribe/live")!

    /// Fast mode takes at most 2 MB of request body for audio sent inline. Three
    /// minutes of the 48 kbit/s M4A upload are about 1.4 MB in base64.
    static let maximumChunkDuration: TimeInterval = 180
    /// 16 kHz PCM16 WAV, the fallback when M4A encoding fails, is about 43 KB
    /// per second in base64, so 45 seconds stay under 2 MB.
    static let maximumWavChunkDuration: TimeInterval = 45
    static let maximumBodySize = 2 * 1024 * 1024

    /// The locale Scribe expects for a two-letter language code.
    static let locales: [String: String] = [
        "en": "en-US", "de": "de-DE", "es": "es-ES", "fr": "fr-FR", "it": "it-IT",
        "pt": "pt-BR", "ja": "ja-JP", "ko": "ko-KR", "zh": "zh-CN", "ar": "ar-SA",
    ]

    /// The settings of one Fast request or Live session.
    struct Request: Sendable, Equatable {
        /// `config.model`.
        let model: String
        /// `config.language`, or nil when Scribe detects the language.
        let locale: String?
        let vocabulary: [String]

        var languageCode: String? { locale.map(ZoomAPIClient.languageCode(fromLocale:)) }

        /// Scribe's `config` object.
        var config: [String: Any] {
            var config: [String: Any] = ["model": model]
            if let locale {
                config["language"] = locale
            } else {
                // Continuous detection works with the multilingual model in both
                // modes; "once" picked English for German speech in our tests.
                config["language_detection"] = ["mode": "continuous"]
            }
            if !vocabulary.isEmpty {
                config["vocabulary"] = ["phrases": vocabulary]
            }
            return config
        }

        /// The model and language for a dictation. A language the model does not
        /// take, or none, goes to the multilingual model with language detection.
        static func make(model: ZoomScribeModel, language: String?, vocabulary: [String]) -> Request {
            let code = language
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .map { String($0.split(separator: "-").first ?? Substring($0)) }
            if let code, model.languages.contains(code), let locale = locales[code] {
                let modelId = model.id == ZoomPlugin.languageModel.id ? "zoom-scribe-\(code)" : model.id
                return Request(model: modelId, locale: locale, vocabulary: model.usesVocabulary ? vocabulary : [])
            }
            let multilingual = ZoomPlugin.multilingualModel
            if let code, multilingual.languages.contains(code), let locale = locales[code] {
                return Request(model: multilingual.id, locale: locale, vocabulary: [])
            }
            return Request(model: multilingual.id, locale: nil, vocabulary: [])
        }
    }

    let apiKey: String

    static func languageCode(fromLocale locale: String) -> String {
        String(locale.split(separator: "-").first ?? Substring(locale)).lowercased()
    }

    static func liveRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: liveURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("live-asr", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    func transcribe(audio: AudioData, request transcription: Request) async throws -> PluginTranscriptionResult {
        if let upload = try? PluginAudioUploadEncoder.compressedM4AUpload(from: audio) {
            return try await transcribe(upload: upload, request: transcription)
        }
        // WAV takes about four times the space, so it goes in shorter pieces.
        return try await PluginAudioChunking.transcribe(
            audio,
            maximumChunkDuration: Self.maximumWavChunkDuration
        ) { piece in
            try await transcribe(upload: PluginAudioUploadEncoder.wavUpload(from: piece), request: transcription)
        }
    }

    private func transcribe(upload: PluginAudioUploadFile, request transcription: Request) async throws -> PluginTranscriptionResult {
        let body = try JSONSerialization.data(withJSONObject: [
            "file": "data:\(upload.contentType);base64,\(upload.data.base64EncodedString())",
            "config": transcription.config,
        ])
        guard body.count <= Self.maximumBodySize else {
            throw PluginTranscriptionError.fileTooLarge
        }

        var request = URLRequest(url: Self.fastURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = body

        let (data, response) = try await PluginHTTPClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No response from Zoom")
        }
        try Self.check(httpResponse, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            throw PluginTranscriptionError.apiError("Failed to parse the Zoom response")
        }
        let text: String
        if let display = result["text_display"] as? String {
            text = display
        } else {
            text = (result["segments"] as? [[String: Any]] ?? [])
                .compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        // `result.language` is missing with continuous detection.
        let detected = (result["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            .map(Self.languageCode(fromLocale:))
        return PluginTranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: detected ?? transcription.languageCode
        )
    }

    func validateKey() async throws -> Bool {
        var request = URLRequest(url: Self.fastURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = Data(#"{"file":"data:audio/wav;base64,","config":{"language":"en-US","model":"typewhisper-key-check"}}"#.utf8)

        let (data, response) = try await PluginHTTPClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No response from Zoom")
        }
        switch httpResponse.statusCode {
        case 400, 200:
            return true
        case 401, 403:
            return false
        default:
            try Self.check(httpResponse, data: data)
            return true
        }
    }

    static func check(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 402, 429:
            throw PluginTranscriptionError.rateLimitOrQuota(from: data)
        default:
            throw PluginTranscriptionError.apiError(errorMessage(from: data, response: response))
        }
    }

    /// Zoom's errors carry `message`, and for request errors a `reason` such as
    /// `UNSUPPORTED_MODEL`.
    static func errorMessage(from data: Data, response: HTTPURLResponse) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String, !message.isEmpty {
            return PluginHTTPErrorBodyFormatter.summary(from: message)
        }
        let body = PluginHTTPErrorBodyFormatter.summary(from: data, response: response)
        return "HTTP \(response.statusCode): \(body)"
    }
}

// MARK: - Settings View

struct ZoomSettingsView: View {
    let plugin: ZoomPlugin
    @State private var apiKeyInput = ""
    @State private var showApiKey = false
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var selectedModel = ""
    @State private var transcriptionMode = ZoomTranscriptionMode.live
    @State private var hasApiKey = false
    /// Changes with every Save and Remove, so a key check that finishes after
    /// either cannot save its key again.
    @State private var keyRequestId = UUID()
    private let bundle = Bundle(for: ZoomPlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Zoom Scribe", bundle: bundle)
                .font(.headline)
            Text("Cloud speech recognition with Zoom Scribe. Needs an API key from Zoom AI Services.", bundle: bundle)
                .font(.callout)
                .foregroundColor(.secondary)

            Divider()

            apiKeySection

            if hasApiKey {
                Divider()
                transcriptionSection
            }
        }
        .padding()
        .onAppear {
            apiKeyInput = plugin.apiKey
            hasApiKey = !plugin.apiKey.isEmpty
            selectedModel = plugin.selectedModelId ?? ""
            transcriptionMode = plugin.transcriptionMode
        }
    }

    // MARK: API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Key", bundle: bundle)
                .font(.subheadline)
                .fontWeight(.medium)

            HStack {
                if showApiKey {
                    TextField(String(localized: "API key from zoom.ai", bundle: bundle), text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text("API Key", bundle: bundle))
                } else {
                    SecureField(String(localized: "API key from zoom.ai", bundle: bundle), text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text("API Key", bundle: bundle))
                }

                Button(action: { showApiKey.toggle() }) {
                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showApiKey ? Text("Hide API key", bundle: bundle) : Text("Show API key", bundle: bundle))

                if hasApiKey {
                    Button(String(localized: "Remove", bundle: bundle)) {
                        keyRequestId = UUID()
                        apiKeyInput = ""
                        validationResult = nil
                        isValidating = false
                        plugin.clearApiKey()
                        hasApiKey = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Remove API key", bundle: bundle))
                }

                Button(String(localized: "Save", bundle: bundle)) {
                    validateAndSave()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
                .accessibilityLabel(Text("Save API key", bundle: bundle))
            }

            if isValidating {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Validating...", bundle: bundle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let result = validationResult {
                HStack(spacing: 4) {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(result ? .green : .red)
                        .accessibilityHidden(true)
                    Text(result ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle))
                        .font(.caption)
                        .foregroundColor(result ? .green : .red)
                }
            }

            Text("Create a key at zoom.ai under Configure > API Keys. Zoom bills usage in Build Credits.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Transcription

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Picker(selection: $selectedModel) {
                    Text("Default (Scribe Multilingual)", bundle: bundle).tag("")
                    ForEach(ZoomPlugin.models, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                } label: {
                    Text("Model", bundle: bundle)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: selectedModel) { _, newValue in
                    plugin.selectModel(newValue)
                }

                Group {
                    switch selectedModel {
                    case ZoomPlugin.languageModel.id:
                        Text("Zoom's model for the dictation language, with dictionary terms. English, German, Spanish, French, Italian, Portuguese, Japanese, Chinese and Arabic. Without a dictation language, Scribe Multilingual detects it.", bundle: bundle)
                    case ZoomPlugin.englishProModel.id:
                        Text("Zoom's most accurate English model, with dictionary terms. Other languages go to Scribe Multilingual.", bundle: bundle)
                    default:
                        Text("One model for English, German, Spanish, French, Italian, Portuguese, Japanese, Korean, Chinese and Arabic. Detects the language when none is set. Does not use dictionary terms.", bundle: bundle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Transcription", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Picker(String(localized: "Transcription", bundle: bundle), selection: $transcriptionMode) {
                    Text("Live", bundle: bundle)
                        .tag(ZoomTranscriptionMode.live)
                    Text("After recording", bundle: bundle)
                        .tag(ZoomTranscriptionMode.batch)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: transcriptionMode) { _, newValue in
                    plugin.setTranscriptionMode(newValue)
                }

                Group {
                    switch transcriptionMode {
                    case .live:
                        Text("Streams dictations that show a live preview to Zoom while you speak. The final text is usually ready half a second after you stop. Recordings, files and dictations without a preview are sent when they end.", bundle: bundle)
                    case .batch:
                        Text("Sends the recording to Zoom when you stop; the text is usually ready in about a second. No live preview from Zoom.", bundle: bundle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Actions

    private func validateAndSave() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isValidating = true
        validationResult = nil
        let requestId = UUID()
        keyRequestId = requestId

        Task {
            let isValid: Bool?
            do {
                isValid = try await plugin.validateApiKey(trimmed)
            } catch {
                // Offline or an outage: the key is saved but not shown as valid.
                isValid = nil
            }
            await MainActor.run {
                guard keyRequestId == requestId else { return }
                isValidating = false
                if isValid == false {
                    validationResult = false
                    return
                }
                validationResult = isValid
                plugin.setApiKey(trimmed)
                hasApiKey = true
            }
        }
    }
}
