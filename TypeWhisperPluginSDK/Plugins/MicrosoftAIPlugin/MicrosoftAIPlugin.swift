import Foundation
import SwiftUI
import TypeWhisperPluginSDK

private enum MicrosoftAIStorageKey {
    static let apiKey = "api-key"
    static let endpoint = "endpoint"
    static let selectedModel = "selectedModel"
    static let cachedModels = "cachedModels"
    static let transcriptStyle = "transcriptStyle"
    static let speakerDiarizationEnabled = "speakerDiarizationEnabled"
}

enum MicrosoftAITranscriptStyle: String, CaseIterable, Sendable {
    case clean
    case verbatim

    var apiValue: String? {
        switch self {
        case .clean: nil
        case .verbatim: "verbatim"
        }
    }
}

enum MicrosoftAIEndpoint {
    static let apiVersion = "2025-10-15"
    static let supportedMAIRegions = ["eastus", "northeurope", "southeastasia", "westus"]

    private static let allowedHostSuffixes = [
        ".cognitiveservices.azure.com",
        ".api.cognitive.microsoft.com",
        ".services.ai.azure.com",
        ".openai.azure.com",
        ".cognitiveservices.azure.us",
        ".api.cognitive.microsoft.us",
        ".services.ai.azure.us",
        ".openai.azure.us",
        ".cognitiveservices.azure.cn",
        ".api.cognitive.azure.cn",
        ".services.ai.azure.cn",
        ".openai.azure.cn",
    ]

    static func normalize(_ rawValue: String?) -> URL? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if !value.contains("://") {
            let validResourceName = value.range(
                of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?$"#,
                options: .regularExpression
            ) != nil
            guard validResourceName else { return nil }
            value = "https://\(value).cognitiveservices.azure.com"
        }

        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              allowedHostSuffixes.contains(where: host.hasSuffix) else {
            return nil
        }

        let path = components.percentEncodedPath
        guard path.isEmpty || path == "/" else { return nil }
        components.path = ""
        return components.url
    }

    static func transcriptionURL(baseURL: URL) -> URL? {
        var components = URLComponents(
            url: baseURL.appending(path: "speechtotext/transcriptions:transcribe"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
        return components?.url
    }

    static func modelCatalogURL(baseURL: URL) -> URL {
        baseURL.appending(path: "openai/v1/models")
    }

    static func regionalEndpointRegion(from baseURL: URL) -> String? {
        guard let host = baseURL.host?.lowercased() else { return nil }
        let suffixes = [
            ".api.cognitive.microsoft.com",
            ".api.cognitive.microsoft.us",
            ".api.cognitive.azure.cn",
        ]
        guard let suffix = suffixes.first(where: host.hasSuffix) else { return nil }

        let region = String(host.dropLast(suffix.count))
        guard !region.isEmpty, !region.contains(".") else { return nil }
        return region
    }

    static func unsupportedMAIRegion(from baseURL: URL) -> String? {
        guard let region = regionalEndpointRegion(from: baseURL),
              !supportedMAIRegions.contains(region) else {
            return nil
        }
        return region
    }
}

struct MicrosoftAIModelCatalogResponse: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        let id: String
    }

    let data: [Model]
}

struct MicrosoftAITranscriptionClient: Sendable {
    private struct ErrorResponseBody: Decodable {
        struct ErrorDetail: Decodable {
            let message: String?
        }

        let message: String?
        let error: ErrorDetail?
    }

    struct Definition: Encodable, Sendable {
        struct EnhancedMode: Encodable, Sendable {
            struct ModelOptions: Encodable, Sendable {
                let timestamps: String
                let transcribeStyle: String
            }

            let enabled = true
            let model: String
            let transcribeStyle: String?
            let modelOptions: ModelOptions?
        }

        struct Diarization: Encodable, Sendable {
            let enabled = true
        }

        struct PhraseList: Encodable, Sendable {
            let phrases: [String]
        }

        let locales: [String]?
        let enhancedMode: EnhancedMode
        let diarization: Diarization?
        let phraseList: PhraseList?
        let profanityFilterMode = "None"
    }

    private struct ResponseBody: Decodable {
        struct CombinedPhrase: Decodable {
            let text: String
        }

        struct Phrase: Decodable {
            let offsetMilliseconds: Double?
            let durationMilliseconds: Double?
            let text: String
            let locale: String?
            let speaker: FlexibleSpeaker?
        }

        let combinedPhrases: [CombinedPhrase]?
        let phrases: [Phrase]?
    }

    private enum FlexibleSpeaker: Decodable {
        case string(String)
        case integer(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let integer = try? container.decode(Int.self) {
                self = .integer(integer)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        var label: String? {
            let rawValue: String
            switch self {
            case .string(let value): rawValue = value
            case .integer(let value): rawValue = String(value)
            }

            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.localizedCaseInsensitiveCompare("unknown") != .orderedSame else {
                return nil
            }
            if trimmed.localizedCaseInsensitiveContains("speaker") {
                return trimmed
            }
            return "Speaker \(trimmed)"
        }
    }

    static let maximumAudioDuration: TimeInterval = 2 * 60 * 60
    static let maximumAudioBytes = 300_000_000
    static let requestTimeout: TimeInterval = 180

    let endpoint: URL
    let apiKey: String

    func transcribe(
        audio: AudioData,
        model: String,
        languageSelection: PluginLanguageSelection,
        dictionaryTerms: [String],
        transcriptStyle: MicrosoftAITranscriptStyle,
        speakerDiarizationEnabled: Bool
    ) async throws -> PluginStructuredTranscriptionResult {
        guard audio.duration <= Self.maximumAudioDuration,
              audio.wavData.count <= Self.maximumAudioBytes else {
            throw PluginTranscriptionError.fileTooLarge
        }
        guard let url = MicrosoftAIEndpoint.transcriptionURL(baseURL: endpoint) else {
            throw PluginTranscriptionError.apiError("Invalid Azure Speech endpoint.")
        }

        let isLegacyModel = MicrosoftAIPlugin.isLegacyModel(model)
        let definition = Definition(
            locales: Self.locales(from: languageSelection),
            enhancedMode: Definition.EnhancedMode(
                model: model,
                transcribeStyle: isLegacyModel ? transcriptStyle.apiValue : nil,
                modelOptions: isLegacyModel
                    ? nil
                    : Definition.EnhancedMode.ModelOptions(
                        timestamps: "segment",
                        transcribeStyle: transcriptStyle.rawValue
                    )
            ),
            diarization: speakerDiarizationEnabled && !isLegacyModel
                ? Definition.Diarization()
                : nil,
            phraseList: dictionaryTerms.isEmpty ? nil : Definition.PhraseList(phrases: dictionaryTerms)
        )
        let definitionData = try JSONEncoder().encode(definition)
        let upload = PluginAudioUploadEncoder.wavUpload(
            from: PluginAudioUploadEncoder.normalizedAudioForUpload(audio)
        )
        let boundary = "TypeWhisper-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.requestTimeout
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            definition: definitionData,
            upload: upload
        )

        let (data, response) = try await PluginHTTPClient.data(
            for: request,
            resourceTimeout: Self.requestTimeout
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Azure Speech returned no HTTP response.")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseResponse(data)
        case 401, 403:
            throw PluginTranscriptionError.invalidApiKey
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            let errorText = Self.errorText(from: data)
            if httpResponse.statusCode == 400,
               errorText.localizedCaseInsensitiveContains("enhanced mode with model"),
               let region = MicrosoftAIEndpoint.unsupportedMAIRegion(from: endpoint) {
                let template = String(
                    localized: "MAI Transcribe is not available in the Azure region %@. Use a Speech resource in one of these regions: %@.",
                    bundle: Bundle(for: MicrosoftAIPlugin.self)
                )
                throw PluginTranscriptionError.apiError(
                    String(
                        format: template,
                        region,
                        MicrosoftAIEndpoint.supportedMAIRegions.joined(separator: ", ")
                    )
                )
            }
            let summary = Self.boundedErrorSummary(errorText)
            throw PluginTranscriptionError.apiError(
                "Microsoft AI transcription failed (HTTP \(httpResponse.statusCode)): \(summary)"
            )
        }
    }

    static func errorSummary(from data: Data) -> String {
        boundedErrorSummary(errorText(from: data))
    }

    private static func errorText(from data: Data) -> String {
        if let response = try? JSONDecoder().decode(ErrorResponseBody.self, from: data),
           let message = response.error?.message ?? response.message {
            return normalizedErrorText(message)
        }

        return normalizedErrorText(String(decoding: data.prefix(4_096), as: UTF8.self))
    }

    private static func normalizedErrorText(_ value: String) -> String {
        let text = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return text.isEmpty ? "No response body." : text
    }

    private static func boundedErrorSummary(_ value: String) -> String {
        String(value.prefix(1_000))
    }

    static func parseResponse(_ data: Data) throws -> PluginStructuredTranscriptionResult {
        let response: ResponseBody
        do {
            response = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw PluginTranscriptionError.apiError(
                "Failed to parse Microsoft AI transcription response: \(error.localizedDescription)"
            )
        }

        let segments = (response.phrases ?? []).compactMap { phrase -> PluginStructuredTranscriptionSegment? in
            let text = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = max(phrase.offsetMilliseconds ?? 0, 0) / 1_000
            let duration = max(phrase.durationMilliseconds ?? 0, 0) / 1_000
            return PluginStructuredTranscriptionSegment(
                text: text,
                start: start,
                end: start + duration,
                speakerLabel: phrase.speaker?.label
            )
        }

        let combinedText = (response.combinedPhrases ?? [])
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let hasSpeakers = segments.contains { $0.speakerLabel != nil }
        let text: String
        if hasSpeakers {
            text = segments.map { segment in
                guard let speaker = segment.speakerLabel else { return segment.text }
                return "\(speaker): \(segment.text)"
            }.joined(separator: "\n")
        } else if !combinedText.isEmpty {
            text = combinedText
        } else {
            text = segments.map(\.text).joined(separator: " ")
        }

        let detectedLanguage = response.phrases?
            .compactMap(\.locale)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return PluginStructuredTranscriptionResult(
            text: text,
            detectedLanguage: detectedLanguage,
            segments: segments
        )
    }

    static func locales(from selection: PluginLanguageSelection) -> [String]? {
        let rawValue: String?
        if let requestedLanguage = selection.requestedLanguage {
            rawValue = requestedLanguage
        } else if selection.languageHints.count == 1 {
            rawValue = selection.languageHints[0]
        } else {
            rawValue = nil
        }

        guard let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-"),
            !normalized.isEmpty else {
            return nil
        }
        return [normalized]
    }

    static func multipartBody(
        boundary: String,
        definition: Data,
        upload: PluginAudioUploadFile
    ) -> Data {
        var body = Data()
        body.microsoftAIAppend("--\(boundary)\r\n")
        body.microsoftAIAppend("Content-Disposition: form-data; name=\"definition\"\r\n")
        body.microsoftAIAppend("Content-Type: application/json\r\n\r\n")
        body.append(definition)
        body.microsoftAIAppend("\r\n--\(boundary)\r\n")
        body.microsoftAIAppend(
            "Content-Disposition: form-data; name=\"audio\"; filename=\"\(upload.filename)\"\r\n"
        )
        body.microsoftAIAppend("Content-Type: \(upload.contentType)\r\n\r\n")
        body.append(upload.data)
        body.microsoftAIAppend("\r\n--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    mutating func microsoftAIAppend(_ value: String) {
        append(Data(value.utf8))
    }
}

@objc(MicrosoftAIPlugin)
final class MicrosoftAIPlugin: NSObject,
    StructuredLanguageHintDictionaryTermHintTranscriptionEnginePlugin,
    TranscriptionModelCatalogProviding,
    DictionaryTermsCapabilityProviding,
    DictionaryTermsBudgetProviding,
    PluginAuthRoleStatusProviding,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.microsoft-ai"
    static let pluginName = "Microsoft AI"
    static let defaultModelId = "MAI-Transcribe-2"
    static let legacyModelId = "MAI-Transcribe-1.5"

    static let fallbackModelIds = [defaultModelId, legacyModelId]
    static let supportedLanguageCodes = [
        "af", "ar", "as", "az", "bg", "bn", "bs", "ca", "cs", "da", "de", "el", "en", "es", "et",
        "fa", "fi", "fil", "fr", "gl", "gu", "he", "hi", "hu", "hy", "id", "is", "it", "ja", "kk",
        "kn", "ko", "lt", "lv", "mk", "ml", "mr", "ms", "nb", "ne", "nl", "or", "pa", "pl", "pt",
        "ro", "ru", "sk", "sl", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur", "vi", "yue", "zh",
    ]

    fileprivate var host: HostServices?
    fileprivate var apiKey: String?
    fileprivate var endpointValue = ""
    fileprivate var selectedModel = defaultModelId
    fileprivate var fetchedModelIds: [String] = []
    fileprivate var transcriptStyle = MicrosoftAITranscriptStyle.clean
    fileprivate var speakerDiarizationEnabled = false

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        apiKey = Self.normalizedSecret(host.loadSecret(key: MicrosoftAIStorageKey.apiKey))
        endpointValue = host.userDefault(forKey: MicrosoftAIStorageKey.endpoint) as? String ?? ""
        fetchedModelIds = Self.normalizedModelIds(
            host.userDefault(forKey: MicrosoftAIStorageKey.cachedModels) as? [String] ?? []
        )
        selectedModel = host.userDefault(forKey: MicrosoftAIStorageKey.selectedModel) as? String
            ?? Self.defaultModelId
        transcriptStyle = MicrosoftAITranscriptStyle(
            rawValue: host.userDefault(forKey: MicrosoftAIStorageKey.transcriptStyle) as? String ?? ""
        ) ?? .clean
        speakerDiarizationEnabled = host.userDefault(
            forKey: MicrosoftAIStorageKey.speakerDiarizationEnabled
        ) as? Bool ?? false

        if !allModelIds.contains(selectedModel) {
            selectedModel = Self.defaultModelId
            host.setUserDefault(selectedModel, forKey: MicrosoftAIStorageKey.selectedModel)
        }
    }

    func deactivate() {
        host = nil
    }

    var providerId: String { "microsoft-ai" }
    var providerDisplayName: String { "Microsoft AI (MAI Transcribe)" }
    var hasStoredAPIKey: Bool { normalizedAPIKey != nil }
    var isConfigured: Bool { hasStoredAPIKey && endpointURL != nil }
    var selectedModelId: String? { selectedModel }
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { false }
    var supportedLanguages: [String] { Self.supportedLanguageCodes }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }
    var dictionaryTermsBudget: DictionaryTermsBudget {
        DictionaryTermsBudget(maxTerms: 500, maxTotalChars: 20_000)
    }

    var transcriptionModels: [PluginModelInfo] {
        allModelIds.map(Self.modelInfo)
    }

    var availableModels: [PluginModelInfo] { transcriptionModels }

    func selectModel(_ modelId: String) {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, allModelIds.contains(normalized) else { return }
        selectedModel = normalized
        host?.setUserDefault(normalized, forKey: MicrosoftAIStorageKey.selectedModel)
        host?.notifyCapabilitiesChanged()
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        Self.legacyResult(from: try await transcribeStructured(
            audio: audio,
            languageSelection: PluginLanguageSelection(requestedLanguage: language),
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: []
        ))
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint]
    ) async throws -> PluginTranscriptionResult {
        Self.legacyResult(from: try await transcribeStructured(
            audio: audio,
            languageSelection: PluginLanguageSelection(requestedLanguage: language),
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints
        ))
    }

    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        Self.legacyResult(from: try await transcribeStructured(
            audio: audio,
            languageSelection: languageSelection,
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: []
        ))
    }

    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint]
    ) async throws -> PluginTranscriptionResult {
        Self.legacyResult(from: try await transcribeStructured(
            audio: audio,
            languageSelection: languageSelection,
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints
        ))
    }

    func transcribeStructured(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginStructuredTranscriptionResult {
        try await transcribeStructured(
            audio: audio,
            languageSelection: PluginLanguageSelection(requestedLanguage: language),
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: []
        )
    }

    func transcribeStructured(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint]
    ) async throws -> PluginStructuredTranscriptionResult {
        try await transcribeStructured(
            audio: audio,
            languageSelection: PluginLanguageSelection(requestedLanguage: language),
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints
        )
    }

    func transcribeStructured(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginStructuredTranscriptionResult {
        try await transcribeStructured(
            audio: audio,
            languageSelection: languageSelection,
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: []
        )
    }

    func transcribeStructured(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint]
    ) async throws -> PluginStructuredTranscriptionResult {
        guard let apiKey = normalizedAPIKey, let endpoint = endpointURL else {
            throw PluginTranscriptionError.notConfigured
        }
        guard !translate else {
            throw PluginTranscriptionError.apiError("MAI Transcribe does not support translation.")
        }

        let promptHints = PluginDictionaryTerms.termHints(fromPrompt: prompt)
        let terms = PluginDictionaryTerms.clippedTermHints(
            from: dictionaryTermHints + promptHints,
            budget: dictionaryTermsBudget
        ).map(\.text)

        return try await MicrosoftAITranscriptionClient(endpoint: endpoint, apiKey: apiKey).transcribe(
            audio: audio,
            model: selectedModel,
            languageSelection: languageSelection,
            dictionaryTerms: terms,
            transcriptStyle: transcriptStyle,
            speakerDiarizationEnabled: speakerDiarizationEnabled
        )
    }

    func authStatus(for role: PluginAuthRole) -> PluginAuthRoleStatus {
        switch role {
        case .transcription:
            return isConfigured
                ? .available
                : .unavailable(
                    reason: "Microsoft AI transcription requires an Azure Speech endpoint and API key.",
                    requiredCredentialLabel: "Azure Speech endpoint and API key"
                )
        case .llm:
            return .unavailable(reason: "This plugin provides transcription only.")
        case .tts:
            return .unavailable(reason: "This plugin does not provide text-to-speech.")
        }
    }

    @MainActor
    var settingsView: AnyView? {
        AnyView(MicrosoftAISettingsView(plugin: self))
    }

    func setEndpoint(_ value: String) {
        let normalized = MicrosoftAIEndpoint.normalize(value)?.absoluteString ?? value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        endpointValue = normalized
        host?.setUserDefault(normalized, forKey: MicrosoftAIStorageKey.endpoint)
        host?.notifyCapabilitiesChanged()
    }

    func setAPIKey(_ value: String) {
        let normalized = Self.normalizedSecret(value)
        apiKey = normalized
        if let host {
            try? host.storeSecret(key: MicrosoftAIStorageKey.apiKey, value: normalized ?? "")
            host.notifyCapabilitiesChanged()
        }
    }

    func setTranscriptStyle(_ value: MicrosoftAITranscriptStyle) {
        guard transcriptStyle != value else { return }
        transcriptStyle = value
        host?.setUserDefault(value.rawValue, forKey: MicrosoftAIStorageKey.transcriptStyle)
    }

    func setSpeakerDiarizationEnabled(_ enabled: Bool) {
        guard speakerDiarizationEnabled != enabled else { return }
        speakerDiarizationEnabled = enabled
        host?.setUserDefault(enabled, forKey: MicrosoftAIStorageKey.speakerDiarizationEnabled)
    }

    @discardableResult
    func refreshModelCatalog() async -> Bool {
        guard let endpoint = endpointURL, let apiKey = normalizedAPIKey else { return false }

        var request = URLRequest(url: MicrosoftAIEndpoint.modelCatalogURL(baseURL: endpoint))
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }
            let catalog = try JSONDecoder().decode(MicrosoftAIModelCatalogResponse.self, from: data)
            let modelIds = Self.normalizedModelIds(catalog.data.map(\.id))
            guard !modelIds.isEmpty else { return false }

            fetchedModelIds = modelIds
            host?.setUserDefault(modelIds, forKey: MicrosoftAIStorageKey.cachedModels)
            if !allModelIds.contains(selectedModel) {
                selectedModel = Self.defaultModelId
                host?.setUserDefault(selectedModel, forKey: MicrosoftAIStorageKey.selectedModel)
            }
            host?.notifyCapabilitiesChanged()
            return true
        } catch {
            return false
        }
    }

    var selectedModelSupportsDiarization: Bool {
        !Self.isLegacyModel(selectedModel)
    }

    private var normalizedAPIKey: String? {
        Self.normalizedSecret(apiKey)
    }

    private var endpointURL: URL? {
        MicrosoftAIEndpoint.normalize(endpointValue)
    }

    private var allModelIds: [String] {
        Self.normalizedModelIds(Self.fallbackModelIds + fetchedModelIds)
    }

    private static func normalizedSecret(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedModelIds(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { value in
                guard value.lowercased().contains("mai-transcribe") else { return false }
                return seen.insert(value.lowercased()).inserted
            }
            .sorted { lhs, rhs in
                let lhsIsDefault = lhs.caseInsensitiveCompare(defaultModelId) == .orderedSame
                let rhsIsDefault = rhs.caseInsensitiveCompare(defaultModelId) == .orderedSame
                if lhsIsDefault != rhsIsDefault { return lhsIsDefault }
                let lhsIsLegacy = isLegacyModel(lhs)
                let rhsIsLegacy = isLegacyModel(rhs)
                if lhsIsLegacy != rhsIsLegacy { return !lhsIsLegacy }
                return lhs.localizedStandardCompare(rhs) == .orderedDescending
            }
    }

    fileprivate static func isLegacyModel(_ modelId: String) -> Bool {
        modelId.caseInsensitiveCompare(legacyModelId) == .orderedSame
    }

    private static func modelInfo(for modelId: String) -> PluginModelInfo {
        let displayName: String
        if modelId.caseInsensitiveCompare(defaultModelId) == .orderedSame {
            displayName = "MAI Transcribe 2"
        } else if isLegacyModel(modelId) {
            displayName = "MAI Transcribe 1.5"
        } else {
            displayName = modelId
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
        let languageCount = isLegacyModel(modelId) ? 43 : 60
        return PluginModelInfo(id: modelId, displayName: displayName, languageCount: languageCount)
    }

    private static func legacyResult(
        from result: PluginStructuredTranscriptionResult
    ) -> PluginTranscriptionResult {
        PluginTranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            segments: result.segments.map {
                PluginTranscriptionSegment(text: $0.text, start: $0.start, end: $0.end)
            }
        )
    }
}

@MainActor
private struct MicrosoftAISettingsView: View {
    let plugin: MicrosoftAIPlugin

    @State private var endpointInput = ""
    @State private var apiKeyInput = ""
    @State private var showAPIKey = false
    @State private var hasStoredAPIKey = false
    @State private var isConfigured = false
    @State private var models: [PluginModelInfo] = []
    @State private var selectedModel = MicrosoftAIPlugin.defaultModelId
    @State private var transcriptStyle = MicrosoftAITranscriptStyle.clean
    @State private var speakerDiarizationEnabled = false
    @State private var isRefreshingModels = false
    @State private var catalogStatus: String?

    private let bundle = Bundle(for: MicrosoftAIPlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Azure Speech connection", bundle: bundle)
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Endpoint or resource name", bundle: bundle)
                        .font(.subheadline)

                    TextField("https://eastus.api.cognitive.microsoft.com", text: $endpointInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel(String(localized: "Endpoint or resource name", bundle: bundle))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key", bundle: bundle)
                        .font(.subheadline)

                    HStack(spacing: 8) {
                        Group {
                            if showAPIKey {
                                TextField(String(localized: "API Key", bundle: bundle), text: $apiKeyInput)
                            } else {
                                SecureField(String(localized: "API Key", bundle: bundle), text: $apiKeyInput)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(String(localized: "API Key", bundle: bundle))

                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack(spacing: 8) {
                    Button(String(localized: isConfigured ? "Update connection" : "Save connection", bundle: bundle)) {
                        saveConnection()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSaveConnection)

                    if hasStoredAPIKey {
                        Button(String(localized: "Remove", bundle: bundle), role: .destructive) {
                            apiKeyInput = ""
                            plugin.setAPIKey("")
                            hasStoredAPIKey = false
                            isConfigured = false
                            catalogStatus = nil
                        }
                    }
                }

                Text("Enter the endpoint shown for your Azure Speech resource, or only its resource name.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let unsupportedRegion {
                    Label {
                        Text(regionAvailabilityWarning(for: unsupportedRegion))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Divider()

            if isConfigured {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcription", bundle: bundle)
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model", bundle: bundle)
                            .font(.subheadline)

                        HStack(spacing: 8) {
                            Picker(String(localized: "Model", bundle: bundle), selection: $selectedModel) {
                                ForEach(models, id: \.id) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: selectedModel) {
                                plugin.selectModel(selectedModel)
                                if !plugin.selectedModelSupportsDiarization {
                                    speakerDiarizationEnabled = false
                                    plugin.setSpeakerDiarizationEnabled(false)
                                }
                            }

                            Button {
                                refreshModels()
                            } label: {
                                if isRefreshingModels {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isRefreshingModels)
                            .help(String(localized: "Refresh models", bundle: bundle))
                        }
                    }

                    if let catalogStatus {
                        Text(catalogStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Transcript style", bundle: bundle)
                            .font(.subheadline)

                        Picker(String(localized: "Transcript style", bundle: bundle), selection: $transcriptStyle) {
                            Text("Clean", bundle: bundle).tag(MicrosoftAITranscriptStyle.clean)
                            Text("Verbatim", bundle: bundle).tag(MicrosoftAITranscriptStyle.verbatim)
                        }
                        .labelsHidden()
                        .onChange(of: transcriptStyle) {
                            plugin.setTranscriptStyle(transcriptStyle)
                        }
                    }

                    Toggle(
                        String(localized: "Speaker diarization", bundle: bundle),
                        isOn: $speakerDiarizationEnabled
                    )
                    .disabled(!plugin.selectedModelSupportsDiarization)
                    .onChange(of: speakerDiarizationEnabled) {
                        plugin.setSpeakerDiarizationEnabled(speakerDiarizationEnabled)
                    }
                }

                Divider()
            }

            Text("Audio is sent to Microsoft Azure for transcription. API keys are stored securely in the Keychain.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding()
        .frame(minWidth: 520, minHeight: 430, alignment: .topLeading)
        .onAppear {
            endpointInput = plugin.endpointValue
            apiKeyInput = plugin.apiKey ?? ""
            hasStoredAPIKey = plugin.hasStoredAPIKey
            isConfigured = plugin.isConfigured
            models = plugin.transcriptionModels
            selectedModel = plugin.selectedModelId ?? MicrosoftAIPlugin.defaultModelId
            transcriptStyle = plugin.transcriptStyle
            speakerDiarizationEnabled = plugin.speakerDiarizationEnabled
        }
    }

    private var canSaveConnection: Bool {
        MicrosoftAIEndpoint.normalize(endpointInput) != nil
            && (!apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasStoredAPIKey)
    }

    private var unsupportedRegion: String? {
        guard let endpoint = MicrosoftAIEndpoint.normalize(endpointInput) else { return nil }
        return MicrosoftAIEndpoint.unsupportedMAIRegion(from: endpoint)
    }

    private func regionAvailabilityWarning(for region: String) -> String {
        String(
            format: String(
                localized: "MAI Transcribe is not available in the Azure region %@. Use a Speech resource in one of these regions: %@.",
                bundle: bundle
            ),
            region,
            MicrosoftAIEndpoint.supportedMAIRegions.joined(separator: ", ")
        )
    }

    private func saveConnection() {
        plugin.setEndpoint(endpointInput)
        if !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plugin.setAPIKey(apiKeyInput)
        }
        endpointInput = plugin.endpointValue
        hasStoredAPIKey = plugin.hasStoredAPIKey
        isConfigured = plugin.isConfigured
        if isConfigured {
            refreshModels()
        }
    }

    private func refreshModels() {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true
        catalogStatus = nil
        Task {
            let refreshed = await plugin.refreshModelCatalog()
            models = plugin.transcriptionModels
            selectedModel = plugin.selectedModelId ?? MicrosoftAIPlugin.defaultModelId
            isRefreshingModels = false
            catalogStatus = refreshed
                ? String(localized: "Models refreshed from Microsoft Foundry.", bundle: bundle)
                : String(localized: "The Foundry model catalog is unavailable for this Speech resource. Built-in MAI models remain available.", bundle: bundle)
        }
    }
}
