import Foundation
import Security
import SwiftUI
import TypeWhisperPluginSDK

private let googleCloudSupportedLanguages = [
    "ar-SA", "bn-BD", "bn-IN", "de-DE", "en-AU", "en-GB",
    "en-IN", "en-US", "es-ES", "es-US", "fr-FR", "gu-IN", "hi-IN",
    "it-IT", "ja-JP", "kn-IN", "ko-KR", "ml-IN", "mr-IN", "nl-NL",
    "pa-Guru-IN", "pt-BR", "pt-PT", "ru-RU", "ta-IN", "te-IN",
    "tr-TR", "uk-UA", "ur-IN", "ur-PK", "vi-VN", "zh-CN", "zh-TW",
]

private actor GoogleAccessTokenCache {
    private var token: String?
    private var expiresAt: Date?

    func cachedToken() -> String? {
        guard let token, let expiresAt, expiresAt.timeIntervalSinceNow > 60 else {
            return nil
        }
        return token
    }

    func store(token: String, expiresIn seconds: Int) {
        self.token = token
        self.expiresAt = Date().addingTimeInterval(TimeInterval(max(seconds - 60, 60)))
    }

    func clear() {
        token = nil
        expiresAt = nil
    }
}

private struct GoogleServiceAccount: Decodable, Sendable {
    let privateKeyID: String?
    let privateKey: String
    let clientEmail: String
    let tokenURI: String?

    enum CodingKeys: String, CodingKey {
        case privateKeyID = "private_key_id"
        case privateKey = "private_key"
        case clientEmail = "client_email"
        case tokenURI = "token_uri"
    }

    var resolvedTokenURI: String {
        let trimmed = tokenURI?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "https://oauth2.googleapis.com/token" : trimmed
    }
}

private struct GoogleOAuthTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

private struct GoogleRecognizeRequest: Encodable {
    let config: GoogleRecognitionConfig
    let audio: GoogleRecognitionAudio
}

private struct GoogleRecognitionConfig: Encodable {
    let languageCode: String
    let maxAlternatives: Int
    let enableAutomaticPunctuation: Bool
    let enableWordTimeOffsets: Bool
    let model: String
    let speechContexts: [GoogleSpeechContext]?
}

private struct GoogleSpeechContext: Encodable {
    let phrases: [String]
    let boost: Double
}

private struct GoogleRecognitionAudio: Encodable {
    let content: String
}

private struct GoogleRecognizeResponse: Decodable {
    let results: [GoogleSpeechRecognitionResult]?
}

private struct GoogleSpeechRecognitionResult: Decodable {
    let alternatives: [GoogleSpeechRecognitionAlternative]?
    let resultEndTime: String?
    let languageCode: String?
}

private struct GoogleSpeechRecognitionAlternative: Decodable {
    let transcript: String
    let words: [GoogleWordInfo]?
}

private struct GoogleWordInfo: Decodable {
    let startTime: String?
    let endTime: String?
    let word: String
}

private struct GoogleCredentialValidationResult {
    let isValid: Bool
    let message: String
}

@objc(GoogleCloudSTTPlugin)
final class GoogleCloudSTTPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.google-cloud-stt"
    static let pluginName = "Google Cloud Speech-to-Text"

    fileprivate var host: HostServices?
    fileprivate var _serviceAccountJSON: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _defaultLanguageCode: String?

    private let tokenCache = GoogleAccessTokenCache()

    fileprivate static let defaultLanguageCode = "en-US"
    private static let recognizeEndpoint = "https://speech.googleapis.com/v1/speech:recognize"
    private static let oauthScope = "https://www.googleapis.com/auth/cloud-platform"
    private static let sampleRate = 16_000
    private static let maxChunkSeconds = 50
    private static let overlapSeconds = 1

    private static let availableModels = [
        PluginModelInfo(id: "default", displayName: "Default"),
        PluginModelInfo(id: "command_and_search", displayName: "Command and Search"),
        PluginModelInfo(id: "latest_short", displayName: "Latest Short"),
        PluginModelInfo(id: "latest_long", displayName: "Latest Long"),
        PluginModelInfo(id: "phone_call", displayName: "Phone Call"),
        PluginModelInfo(id: "video", displayName: "Video"),
    ]

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _serviceAccountJSON = host.loadSecret(key: "service-account-json")
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? Self.availableModels.first?.id
        _defaultLanguageCode = host.userDefault(forKey: "defaultLanguageCode") as? String
            ?? Self.defaultLanguageCode
    }

    func deactivate() {
        host = nil
    }

    var providerId: String { "google-cloud-stt" }
    var providerDisplayName: String { "Google Cloud Speech-to-Text" }

    var isConfigured: Bool {
        currentServiceAccount != nil
    }

    var transcriptionModels: [PluginModelInfo] {
        Self.availableModels
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { false }
    var supportedLanguages: [String] { googleCloudSupportedLanguages }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let serviceAccount = currentServiceAccount else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId, !modelId.isEmpty else {
            throw PluginTranscriptionError.noModelSelected
        }

        let languageCode = Self.normalizeLanguageCode(
            language ?? _defaultLanguageCode ?? Self.defaultLanguageCode
        )
        let accessToken = try await accessToken(for: serviceAccount)
        let promptPhrases = Self.promptPhrases(from: prompt)

        return try await transcribeChunked(
            audio: audio,
            accessToken: accessToken,
            languageCode: languageCode,
            modelId: modelId,
            promptPhrases: promptPhrases
        )
    }

    var settingsView: AnyView? {
        AnyView(GoogleCloudSTTSettingsView(plugin: self))
    }

    fileprivate func setServiceAccountJSON(_ json: String) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        _serviceAccountJSON = trimmed.isEmpty ? nil : trimmed
        if let host {
            do {
                try host.storeSecret(key: "service-account-json", value: trimmed)
            } catch {
                print("[GoogleCloudSTTPlugin] Failed to store service account JSON: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
        Task {
            await tokenCache.clear()
        }
    }

    fileprivate func removeServiceAccountJSON() {
        _serviceAccountJSON = nil
        if let host {
            do {
                try host.storeSecret(key: "service-account-json", value: "")
            } catch {
                print("[GoogleCloudSTTPlugin] Failed to clear service account JSON: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
        Task {
            await tokenCache.clear()
        }
    }

    fileprivate func setDefaultLanguageCode(_ code: String) {
        let normalized = Self.normalizeLanguageCode(code)
        _defaultLanguageCode = normalized
        host?.setUserDefault(normalized, forKey: "defaultLanguageCode")
    }

    fileprivate func validateCredentials(jsonOverride: String? = nil) async -> GoogleCredentialValidationResult {
        let candidate = jsonOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawJSON = (candidate?.isEmpty == false ? candidate : _serviceAccountJSON) ?? ""
        guard let serviceAccount = Self.parseServiceAccount(from: rawJSON) else {
            return GoogleCredentialValidationResult(
                isValid: false,
                message: "The JSON could not be parsed. Paste the full Google service-account JSON file."
            )
        }

        do {
            let accessToken = try await accessToken(for: serviceAccount, forceRefresh: true)
            _ = try await recognizeChunk(
                samples: Array(repeating: 0, count: Self.sampleRate / 10),
                accessToken: accessToken,
                languageCode: Self.defaultLanguageCode,
                modelId: "default",
                promptPhrases: []
            )
            return GoogleCredentialValidationResult(
                isValid: true,
                message: "Credentials look valid and Speech-to-Text is reachable."
            )
        } catch {
            return GoogleCredentialValidationResult(
                isValid: false,
                message: Self.validationMessage(for: error)
            )
        }
    }

    private var currentServiceAccount: GoogleServiceAccount? {
        Self.parseServiceAccount(from: _serviceAccountJSON)
    }

    private func accessToken(for serviceAccount: GoogleServiceAccount, forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cached = await tokenCache.cachedToken() {
            return cached
        }

        let assertion = try Self.makeJWT(for: serviceAccount)
        guard let url = URL(string: serviceAccount.resolvedTokenURI) else {
            throw PluginTranscriptionError.apiError("Invalid token URL")
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(
                name: "grant_type",
                value: "urn:ietf:params:oauth:grant-type:jwt-bearer"
            ),
            URLQueryItem(name: "assertion", value: assertion),
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.timeoutInterval = 30

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid OAuth response")
        }

        guard httpResponse.statusCode == 200 else {
            let message = Self.formattedGoogleErrorMessage(from: data, statusCode: httpResponse.statusCode)
                ?? "HTTP \(httpResponse.statusCode)"
            throw PluginTranscriptionError.apiError(message)
        }

        let decoded = try JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data)
        await tokenCache.store(token: decoded.accessToken, expiresIn: decoded.expiresIn)
        return decoded.accessToken
    }

    private func transcribeChunked(
        audio: AudioData,
        accessToken: String,
        languageCode: String,
        modelId: String,
        promptPhrases: [String]
    ) async throws -> PluginTranscriptionResult {
        let maxChunkSamples = Self.maxChunkSeconds * Self.sampleRate
        let overlapSamples = Self.overlapSeconds * Self.sampleRate

        if audio.samples.count <= maxChunkSamples {
            return try await recognizeChunk(
                samples: audio.samples,
                accessToken: accessToken,
                languageCode: languageCode,
                modelId: modelId,
                promptPhrases: promptPhrases
            )
        }

        var start = 0
        var combinedText = ""
        var detectedLanguage: String?
        var combinedSegments: [PluginTranscriptionSegment] = []
        var lastAcceptedSegmentEnd = -1.0

        while start < audio.samples.count {
            let end = min(start + maxChunkSamples, audio.samples.count)
            let chunkSamples = Array(audio.samples[start..<end])

            let chunkResult = try await recognizeChunk(
                samples: chunkSamples,
                accessToken: accessToken,
                languageCode: languageCode,
                modelId: modelId,
                promptPhrases: promptPhrases
            )

            combinedText = Self.mergeTranscripts(combinedText, chunkResult.text)
            detectedLanguage = detectedLanguage ?? chunkResult.detectedLanguage

            let chunkOffset = Double(start) / Double(Self.sampleRate)
            for segment in chunkResult.segments {
                let shifted = PluginTranscriptionSegment(
                    text: segment.text,
                    start: segment.start + chunkOffset,
                    end: segment.end + chunkOffset
                )

                if shifted.end <= lastAcceptedSegmentEnd + 0.15 {
                    continue
                }

                combinedSegments.append(shifted)
                lastAcceptedSegmentEnd = max(lastAcceptedSegmentEnd, shifted.end)
            }

            if end == audio.samples.count {
                break
            }

            start = max(end - overlapSamples, start + 1)
        }

        return PluginTranscriptionResult(
            text: combinedText,
            detectedLanguage: detectedLanguage ?? languageCode,
            segments: combinedSegments
        )
    }

    private func recognizeChunk(
        samples: [Float],
        accessToken: String,
        languageCode: String,
        modelId: String,
        promptPhrases: [String]
    ) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: Self.recognizeEndpoint) else {
            throw PluginTranscriptionError.apiError("Invalid recognize URL")
        }

        let wavData = PluginWavEncoder.encode(samples, sampleRate: Self.sampleRate)
        let speechContexts: [GoogleSpeechContext]? = promptPhrases.isEmpty
            ? nil
            : [GoogleSpeechContext(phrases: promptPhrases, boost: 15)]

        let requestBody = GoogleRecognizeRequest(
            config: GoogleRecognitionConfig(
                languageCode: languageCode,
                maxAlternatives: 1,
                enableAutomaticPunctuation: true,
                enableWordTimeOffsets: true,
                model: modelId,
                speechContexts: speechContexts
            ),
            audio: GoogleRecognitionAudio(content: wavData.base64EncodedString())
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.timeoutInterval = 90

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseRecognizeResponse(data)
        case 401:
            throw PluginTranscriptionError.apiError(
                Self.formatGoogleErrorMessage(
                    "Google rejected the service-account credentials.",
                    statusCode: httpResponse.statusCode
                )
            )
        case 403:
            let message = Self.formattedGoogleErrorMessage(from: data, statusCode: httpResponse.statusCode)
                ?? "Google Cloud denied access. Check IAM permissions and whether Speech-to-Text is enabled."
            throw PluginTranscriptionError.apiError(message)
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            let message = Self.formattedGoogleErrorMessage(from: data, statusCode: httpResponse.statusCode)
                ?? "HTTP \(httpResponse.statusCode)"
            throw PluginTranscriptionError.apiError(message)
        }
    }

    private static func parseRecognizeResponse(_ data: Data) throws -> PluginTranscriptionResult {
        let decoded = try JSONDecoder().decode(GoogleRecognizeResponse.self, from: data)

        var text = ""
        var segments: [PluginTranscriptionSegment] = []
        var detectedLanguage: String?
        var previousEnd = 0.0

        for result in decoded.results ?? [] {
            guard let alternative = result.alternatives?.first else {
                continue
            }

            text += alternative.transcript
            if detectedLanguage == nil, let languageCode = result.languageCode, !languageCode.isEmpty {
                detectedLanguage = languageCode
            }

            let trimmedTranscript = alternative.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTranscript.isEmpty else {
                continue
            }

            if let words = alternative.words,
               let firstWord = words.first,
               let lastWord = words.last,
               let start = parseDuration(firstWord.startTime),
               let end = parseDuration(lastWord.endTime) {
                segments.append(
                    PluginTranscriptionSegment(text: trimmedTranscript, start: start, end: end)
                )
                previousEnd = max(previousEnd, end)
            } else if let end = parseDuration(result.resultEndTime) {
                segments.append(
                    PluginTranscriptionSegment(text: trimmedTranscript, start: previousEnd, end: end)
                )
                previousEnd = max(previousEnd, end)
            }
        }

        return PluginTranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: detectedLanguage,
            segments: segments
        )
    }

    private static func parseServiceAccount(from rawJSON: String?) -> GoogleServiceAccount? {
        guard let rawJSON else { return nil }
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GoogleServiceAccount.self, from: data)
    }

    private static func makeJWT(for serviceAccount: GoogleServiceAccount) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        var header: [String: String] = [
            "alg": "RS256",
            "typ": "JWT",
        ]
        if let keyID = serviceAccount.privateKeyID, !keyID.isEmpty {
            header["kid"] = keyID
        }

        let claims: [String: Any] = [
            "iss": serviceAccount.clientEmail,
            "scope": Self.oauthScope,
            "aud": serviceAccount.resolvedTokenURI,
            "iat": now,
            "exp": now + 3600,
        ]

        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let claimsData = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let unsignedToken = "\(base64URLEncode(headerData)).\(base64URLEncode(claimsData))"

        let key = try rsaPrivateKey(fromPEM: serviceAccount.privateKey)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(unsignedToken.utf8) as CFData,
            &error
        ) as Data? else {
            let message = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "RSA signing failed"
            throw PluginTranscriptionError.apiError(message)
        }

        return "\(unsignedToken).\(base64URLEncode(signature))"
    }

    private static func rsaPrivateKey(fromPEM pem: String) throws -> SecKey {
        guard let pemData = pem.data(using: .utf8) else {
            throw PluginTranscriptionError.apiError("Invalid private key in service-account JSON")
        }

        var format = SecExternalFormat.formatUnknown
        var itemType = SecExternalItemType.itemTypeUnknown
        var importedItems: CFArray?
        let status = SecItemImport(
            pemData as CFData,
            nil,
            &format,
            &itemType,
            [],
            nil,
            nil,
            &importedItems
        )

        guard status == errSecSuccess,
              let items = importedItems as? [Any],
              let key = items.first as! SecKey? else {
            throw PluginTranscriptionError.apiError("Unable to load RSA private key")
        }

        return key
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func promptPhrases(from prompt: String?) -> [String] {
        guard let prompt, !prompt.isEmpty else { return [] }

        let parts = prompt
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var uniquePhrases: [String] = []
        var seen = Set<String>()

        for part in parts {
            let capped = String(part.prefix(100))
            let normalized = capped.lowercased()
            if seen.insert(normalized).inserted {
                uniquePhrases.append(capped)
            }
            if uniquePhrases.count == 100 {
                break
            }
        }

        return uniquePhrases
    }

    private static func normalizeLanguageCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultLanguageCode }
        guard !trimmed.contains("-") else { return trimmed }

        let mappings = [
            "ar": "ar-SA",
            "bn": "bn-IN",
            "de": "de-DE",
            "en": "en-US",
            "es": "es-ES",
            "fr": "fr-FR",
            "gu": "gu-IN",
            "hi": "hi-IN",
            "it": "it-IT",
            "ja": "ja-JP",
            "kn": "kn-IN",
            "ko": "ko-KR",
            "ml": "ml-IN",
            "mr": "mr-IN",
            "nl": "nl-NL",
            "pa": "pa-Guru-IN",
            "pt": "pt-BR",
            "ru": "ru-RU",
            "ta": "ta-IN",
            "te": "te-IN",
            "tr": "tr-TR",
            "uk": "uk-UA",
            "ur": "ur-IN",
            "vi": "vi-VN",
            "zh": "zh-CN",
        ]

        return mappings[trimmed.lowercased()] ?? trimmed
    }

    private static func parseDuration(_ duration: String?) -> Double? {
        guard let duration, duration.hasSuffix("s") else { return nil }
        return Double(duration.dropLast())
    }

    private static func extractGoogleErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let description = json["error_description"] as? String, !description.isEmpty {
                return description
            }
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.isEmpty {
                return message
            }
            if let error = json["error"] as? String, !error.isEmpty {
                return error
            }
        }

        if let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !body.isEmpty {
            return body
        }

        return nil
    }

    private static func formattedGoogleErrorMessage(from data: Data, statusCode: Int? = nil) -> String? {
        guard let rawMessage = extractGoogleErrorMessage(from: data) else {
            return nil
        }
        return formatGoogleErrorMessage(rawMessage, statusCode: statusCode)
    }

    private static func formatGoogleErrorMessage(_ message: String, statusCode: Int? = nil) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercase = trimmed
            .lowercased()
            .replacingOccurrences(of: "‑", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")

        let speechAPIUnused = lowercase.contains("has not been used in project")
            && (lowercase.contains("speech") || lowercase.contains("speech.googleapis.com"))
        let speechAPIDisabled = lowercase.contains("speech.googleapis.com") && lowercase.contains("disabled")

        if speechAPIUnused || speechAPIDisabled {
            if let projectId = extractProjectIdentifier(from: trimmed) {
                return "Cloud Speech-to-Text API is not enabled for Google Cloud project \(projectId). Open https://console.developers.google.com/apis/api/speech.googleapis.com/overview?project=\(projectId), click Enable, wait a few minutes, and retry."
            }
            return "Cloud Speech-to-Text API is not enabled for this Google Cloud project. Enable speech.googleapis.com in Google Cloud, wait a few minutes, and retry."
        }

        if lowercase.contains("billing")
            && (lowercase.contains("disabled") || lowercase.contains("not enabled") || lowercase.contains("required")) {
            return "Google Cloud billing is not enabled for this project. Enable billing for the project and retry."
        }

        if lowercase.contains("permission denied") || (statusCode == 403 && lowercase.contains("permission")) {
            return "Google denied access to Speech-to-Text. Make sure the API is enabled and the service account has the Cloud Speech Client role."
        }

        if statusCode == 401 || lowercase.contains("invalid_grant") || lowercase.contains("unauthorized") {
            return "Google rejected the service-account credentials. Check that you pasted the full JSON key file for the correct project."
        }

        return trimmed
    }

    private static func extractProjectIdentifier(from message: String) -> String? {
        let pattern = #"project\s+([A-Za-z0-9:-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, options: [], range: range),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: message) else {
            return nil
        }
        return String(message[matchRange])
    }

    private static func validationMessage(for error: Error) -> String {
        guard let pluginError = error as? PluginTranscriptionError else {
            return error.localizedDescription
        }

        switch pluginError {
        case .notConfigured:
            return "No service-account JSON is configured yet."
        case .noModelSelected:
            return "No Google recognition model is selected."
        case .invalidApiKey:
            return "Google rejected the service-account credentials."
        case .rateLimited:
            return "Google Cloud rate-limited the request. Please wait a moment and retry."
        case .fileTooLarge:
            return "The verification audio was rejected as too large."
        case .apiError(let message):
            return message
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }

    private static func mergeTranscripts(_ existing: String, _ incoming: String) -> String {
        let lhs = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }

        let lhsWords = lhs.split(whereSeparator: \.isWhitespace)
        let rhsWords = rhs.split(whereSeparator: \.isWhitespace)
        let maxOverlap = min(12, lhsWords.count, rhsWords.count)

        if maxOverlap > 0 {
            for overlap in stride(from: maxOverlap, through: 1, by: -1) {
                let lhsSlice = lhsWords.suffix(overlap).map(comparableWord)
                let rhsSlice = rhsWords.prefix(overlap).map(comparableWord)
                if lhsSlice == rhsSlice {
                    let remaining = rhsWords.dropFirst(overlap).joined(separator: " ")
                    return remaining.isEmpty ? lhs : "\(lhs) \(remaining)"
                }
            }
        }

        return "\(lhs) \(rhs)"
    }

    private static func comparableWord(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }
}

private struct GoogleCloudSTTSettingsView: View {
    let plugin: GoogleCloudSTTPlugin

    @State private var serviceAccountInput = ""
    @State private var isValidating = false
    @State private var validationResult: GoogleCredentialValidationResult?
    @State private var selectedModel = ""
    @State private var defaultLanguageCode = GoogleCloudSTTPlugin.defaultLanguageCode

    private var trimmedServiceAccountInput: String {
        serviceAccountInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Service Account JSON")
                    .font(.headline)

                TextEditor(text: $serviceAccountInput)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary, lineWidth: 1)
                    }

                Text("Google Speech-to-Text does not accept simple API keys. Paste a Google Cloud service-account JSON key here. Credentials are stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if plugin.isConfigured && trimmedServiceAccountInput.isEmpty {
                    Text("Stored credentials are active. Paste a new JSON key above to replace them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button(plugin.isConfigured ? "Replace Credentials" : "Save Credentials") {
                        saveCredentials()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedServiceAccountInput.isEmpty)

                    Button("Test Stored Credentials") {
                        testStoredCredentials()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!plugin.isConfigured || isValidating)

                    if plugin.isConfigured {
                        Button("Remove") {
                            serviceAccountInput = ""
                            validationResult = nil
                            plugin.removeServiceAccountJSON()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    }
                }

                if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let validationResult {
                    HStack(spacing: 4) {
                        Image(systemName: validationResult.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(validationResult.isValid ? .green : .red)
                        Text(validationResult.message)
                            .font(.caption)
                            .foregroundStyle(validationResult.isValid ? .green : .red)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.headline)

                Picker("Model", selection: $selectedModel) {
                    ForEach(plugin.transcriptionModels, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .labelsHidden()
                .onChange(of: selectedModel) {
                    plugin.selectModel(selectedModel)
                }

                Text("Use `default` or `command_and_search` for the broadest language coverage. The newer `latest_*` models can be more restrictive depending on language support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Default Language")
                    .font(.headline)

                TextField("e.g. gu-IN, kn-IN, pa-Guru-IN, en-US", text: $defaultLanguageCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: defaultLanguageCode) {
                        plugin.setDefaultLanguageCode(defaultLanguageCode)
                    }

                Text("If TypeWhisper already passes a spoken language, that value wins. Otherwise this BCP-47 code is used for Google recognition requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear {
            selectedModel = plugin.selectedModelId ?? plugin.transcriptionModels.first?.id ?? ""
            defaultLanguageCode = plugin._defaultLanguageCode ?? GoogleCloudSTTPlugin.defaultLanguageCode
        }
    }

    private func saveCredentials() {
        guard !trimmedServiceAccountInput.isEmpty else { return }

        plugin.setServiceAccountJSON(trimmedServiceAccountInput)
        validationResult = nil
        isValidating = true

        Task {
            let isValid = await plugin.validateCredentials(jsonOverride: trimmedServiceAccountInput)
            await MainActor.run {
                isValidating = false
                validationResult = isValid
            }
        }
    }

    private func testStoredCredentials() {
        validationResult = nil
        isValidating = true

        Task {
            let isValid = await plugin.validateCredentials()
            await MainActor.run {
                isValidating = false
                validationResult = isValid
            }
        }
    }
}
