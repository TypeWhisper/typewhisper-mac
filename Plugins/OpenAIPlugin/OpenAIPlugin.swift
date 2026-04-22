import AppKit
import CryptoKit
import Foundation
import Network
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - OAuth Helpers

private enum OpenAIAuthMode: String, Codable, CaseIterable, Hashable, Sendable {
    case apiKey = "api-key"
    case chatGPT = "chatgpt"
}

private enum OpenAIReasoningEffort: String, Codable, CaseIterable, Hashable, Sendable {
    case low
    case medium
    case high

    var localizedKey: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        }
    }
}

private enum OpenAIOAuthConfig {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = "https://auth.openai.com"
    static let codexAPIEndpoint = "https://chatgpt.com/backend-api/codex/responses"
    static let callbackHost = "localhost"
    static let callbackPort: UInt16 = 1455
    static let callbackPath = "/auth/callback"
    static let authorizeOriginator = "opencode"

    static var redirectURI: String {
        "http://\(callbackHost):\(callbackPort)\(callbackPath)"
    }
}

private enum OpenAIOAuthError: LocalizedError {
    case callbackPortUnavailable
    case invalidCallback
    case missingAuthorizationCode
    case invalidState
    case exchangeFailed(Int)
    case refreshFailed(Int)
    case missingCredentials
    case codexAuthMissing
    case responseParsingFailed

    var errorDescription: String? {
        switch self {
        case .callbackPortUnavailable:
            "Could not start the local OAuth callback server."
        case .invalidCallback:
            "The OAuth callback was invalid."
        case .missingAuthorizationCode:
            "The OAuth callback did not include an authorization code."
        case .invalidState:
            "The OAuth callback state did not match."
        case .exchangeFailed(let status):
            "OpenAI token exchange failed with status \(status)."
        case .refreshFailed(let status):
            "OpenAI token refresh failed with status \(status)."
        case .missingCredentials:
            "ChatGPT login is not configured."
        case .codexAuthMissing:
            "No Codex login was found on this Mac."
        case .responseParsingFailed:
            "The ChatGPT response could not be parsed."
        }
    }
}

private struct OpenAIPKCECodes: Sendable {
    let verifier: String
    let challenge: String
}

private struct OpenAIOAuthTokenResponse: Decodable, Sendable {
    let id_token: String?
    let access_token: String
    let refresh_token: String
    let expires_in: Int?
}

private struct OpenAIDeviceClaims: Decodable, Sendable {
    struct AuthInfo: Decodable, Sendable {
        let chatgpt_account_id: String?
        let chatgpt_plan_type: String?
    }

    let chatgpt_account_id: String?
    let chatgpt_plan_type: String?
    let organizations: [Organization]?
    let exp: TimeInterval?
    let authInfo: AuthInfo?

    struct Organization: Decodable, Sendable {
        let id: String
    }

    enum CodingKeys: String, CodingKey {
        case chatgpt_account_id
        case chatgpt_plan_type
        case organizations
        case exp
        case authInfo = "https://api.openai.com/auth"
    }
}

private struct OpenAIOAuthMetadata: Sendable {
    let accountID: String?
    let planType: String?
    let expiresAt: Date?
}

private final class OpenAILoopbackOAuthServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.typewhisper.openai.oauth")
    private let expectedState: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    func start() throws {
        let params = NWParameters.tcp
        let listener = try NWListener(
            using: params,
            on: NWEndpoint.Port(rawValue: OpenAIOAuthConfig.callbackPort)!
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pendingResult = self.pendingResult {
                    continuation.resume(with: pendingResult)
                    self.pendingResult = nil
                    return
                }
                self.continuation = continuation
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let content {
                accumulated.append(content)
            }

            if let requestLine = Self.requestLine(from: accumulated) {
                let result = self.parseRequestLine(requestLine)
                let html = Self.responseHTML(for: result)
                self.sendHTML(html, on: connection)
                self.finish(result)
                return
            }

            if isComplete || error != nil {
                self.sendHTML(Self.errorHTML("Incomplete callback request."), on: connection)
                self.finish(.failure(OpenAIOAuthError.invalidCallback))
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func parseRequestLine(_ requestLine: String) -> Result<String, Error> {
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return .failure(OpenAIOAuthError.invalidCallback) }

        let rawTarget = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(rawTarget)"),
              components.path == OpenAIOAuthConfig.callbackPath else {
            return .failure(OpenAIOAuthError.invalidCallback)
        }

        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let error = query["error"], !error.isEmpty {
            return .failure(OpenAIOAuthError.invalidCallback)
        }

        guard query["state"] == expectedState else {
            return .failure(OpenAIOAuthError.invalidState)
        }

        guard let code = query["code"], !code.isEmpty else {
            return .failure(OpenAIOAuthError.missingAuthorizationCode)
        }

        return .success(code)
    }

    private func sendHTML(_ html: String, on connection: NWConnection) {
        let body = Data(html.utf8)
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r
        """

        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<String, Error>) {
        queue.async {
            self.listener?.cancel()
            self.listener = nil

            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(with: result)
            } else {
                self.pendingResult = result
            }
        }
    }

    private static func requestLine(from data: Data) -> String? {
        guard let request = String(data: data, encoding: .utf8),
              let line = request.components(separatedBy: "\r\n").first,
              line.contains("HTTP/1.1") else {
            return nil
        }
        return line
    }

    private static func responseHTML(for result: Result<String, Error>) -> String {
        switch result {
        case .success:
            return successHTML
        case .failure(let error):
            return errorHTML(error.localizedDescription)
        }
    }

    private static let successHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <title>TypeWhisper Login</title>
        <style>
          body {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            margin: 0;
            min-height: 100vh;
            display: grid;
            place-items: center;
            background: #121212;
            color: #f5f5f5;
          }
          .card {
            max-width: 420px;
            padding: 28px;
            border-radius: 18px;
            background: #1d1d1d;
            box-shadow: 0 18px 50px rgba(0, 0, 0, 0.35);
          }
          h1 { margin: 0 0 12px; font-size: 24px; }
          p { margin: 0; color: #c7c7c7; line-height: 1.5; }
        </style>
      </head>
      <body>
        <div class="card">
          <h1>Login abgeschlossen</h1>
          <p>Sie können dieses Fenster schließen und zu TypeWhisper zurückkehren.</p>
        </div>
        <script>setTimeout(() => window.close(), 1800)</script>
      </body>
    </html>
    """

    private static func errorHTML(_ message: String) -> String {
        """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <title>TypeWhisper Login</title>
            <style>
              body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                margin: 0;
                min-height: 100vh;
                display: grid;
                place-items: center;
                background: #121212;
                color: #f5f5f5;
              }
              .card {
                max-width: 460px;
                padding: 28px;
                border-radius: 18px;
                background: #1d1d1d;
                box-shadow: 0 18px 50px rgba(0, 0, 0, 0.35);
              }
              h1 { margin: 0 0 12px; font-size: 24px; color: #ff8a72; }
              p { margin: 0; color: #c7c7c7; line-height: 1.5; }
            </style>
          </head>
          <body>
            <div class="card">
              <h1>Login fehlgeschlagen</h1>
              <p>\(message)</p>
            </div>
          </body>
        </html>
        """
    }
}

private func generatePKCECodes() -> OpenAIPKCECodes {
    let verifier = randomOAuthString(length: 64)
    let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
    return OpenAIPKCECodes(verifier: verifier, challenge: challengeData.base64URLEncodedString())
}

private func randomOAuthString(length: Int) -> String {
    let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return String((0..<length).map { _ in charset.randomElement()! })
}

private func randomState() -> String {
    Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString()
}

private func buildOAuthAuthorizeURL(state: String, pkce: OpenAIPKCECodes) -> URL {
    var components = URLComponents(string: "\(OpenAIOAuthConfig.issuer)/oauth/authorize")!
    components.queryItems = [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "client_id", value: OpenAIOAuthConfig.clientID),
        URLQueryItem(name: "redirect_uri", value: OpenAIOAuthConfig.redirectURI),
        URLQueryItem(name: "scope", value: "openid profile email offline_access"),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "id_token_add_organizations", value: "true"),
        URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "originator", value: OpenAIOAuthConfig.authorizeOriginator),
    ]
    return components.url!
}

private func exchangeAuthorizationCode(_ code: String, pkce: OpenAIPKCECodes) async throws -> OpenAIOAuthTokenResponse {
    let url = URL(string: "\(OpenAIOAuthConfig.issuer)/oauth/token")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = URLSearchParams([
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": OpenAIOAuthConfig.redirectURI,
        "client_id": OpenAIOAuthConfig.clientID,
        "code_verifier": pkce.verifier,
    ]).data

    let (data, response) = try await PluginHTTPClient.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw PluginChatError.networkError("Invalid OAuth response")
    }
    guard httpResponse.statusCode == 200 else {
        throw OpenAIOAuthError.exchangeFailed(httpResponse.statusCode)
    }
    return try JSONDecoder().decode(OpenAIOAuthTokenResponse.self, from: data)
}

private func refreshOAuthToken(_ refreshToken: String) async throws -> OpenAIOAuthTokenResponse {
    let url = URL(string: "\(OpenAIOAuthConfig.issuer)/oauth/token")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = URLSearchParams([
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "client_id": OpenAIOAuthConfig.clientID,
    ]).data

    let (data, response) = try await PluginHTTPClient.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw PluginChatError.networkError("Invalid OAuth refresh response")
    }
    guard httpResponse.statusCode == 200 else {
        throw OpenAIOAuthError.refreshFailed(httpResponse.statusCode)
    }
    return try JSONDecoder().decode(OpenAIOAuthTokenResponse.self, from: data)
}

private func parseJWTClaims(token: String) -> OpenAIDeviceClaims? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    guard let data = Data(base64URLString: String(parts[1])) else { return nil }
    return try? JSONDecoder().decode(OpenAIDeviceClaims.self, from: data)
}

private func extractOAuthMetadata(from tokens: OpenAIOAuthTokenResponse) -> OpenAIOAuthMetadata {
    let idClaims = tokens.id_token.flatMap(parseJWTClaims(token:))
    let accessClaims = parseJWTClaims(token: tokens.access_token)
    let chosenClaims = idClaims ?? accessClaims

    let accountID = chosenClaims?.chatgpt_account_id
        ?? chosenClaims?.authInfo?.chatgpt_account_id
        ?? chosenClaims?.organizations?.first?.id
    let planType = chosenClaims?.chatgpt_plan_type ?? chosenClaims?.authInfo?.chatgpt_plan_type
    let expiresAt = accessClaims?.exp.map(Date.init(timeIntervalSince1970:))

    return OpenAIOAuthMetadata(accountID: accountID, planType: planType, expiresAt: expiresAt)
}

// MARK: - Plugin Entry Point

@objc(OpenAIPlugin)
final class OpenAIPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, LLMProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.openai"
    static let pluginName = "OpenAI"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _fetchedLLMModels: [OpenAIFetchedModel] = []
    fileprivate var _authMode: OpenAIAuthMode = .apiKey
    fileprivate var _reasoningEffort: OpenAIReasoningEffort = .medium
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
    fileprivate var _llmTemperatureValue: Double = 0.3
    fileprivate var _oauthAccessToken: String?
    fileprivate var _oauthRefreshToken: String?
    fileprivate var _oauthIDToken: String?
    fileprivate var _oauthAccountID: String?
    fileprivate var _oauthPlanType: String?
    fileprivate var _oauthExpiresAt: Date?

    private let transcriptionHelper = PluginOpenAITranscriptionHelper(
        baseURL: "https://api.openai.com",
        responseFormat: "verbose_json"
    )

    private let chatHelper = PluginOpenAIChatHelper(baseURL: "https://api.openai.com")

    private static let storageKeys = (
        apiKey: "api-key",
        oauthAccessToken: "oauth-access-token",
        oauthRefreshToken: "oauth-refresh-token",
        oauthIDToken: "oauth-id-token",
        authMode: "authMode",
        reasoningEffort: "reasoningEffort",
        selectedModel: "selectedModel",
        selectedLLMModel: "selectedLLMModel",
        llmTemperatureMode: "llmTemperatureMode",
        llmTemperatureValue: "llmTemperatureValue",
        fetchedLLMModels: "fetchedLLMModels",
        oauthAccountID: "oauthAccountID",
        oauthPlanType: "oauthPlanType",
        oauthExpiresAt: "oauthExpiresAt"
    )

    private static let chatGPTOAuthModels: [PluginModelInfo] = [
        PluginModelInfo(id: "gpt-5.4", displayName: "GPT-5.4"),
        PluginModelInfo(id: "gpt-5.4-mini", displayName: "GPT-5.4 Mini"),
        PluginModelInfo(id: "gpt-5.3-codex", displayName: "GPT-5.3 Codex"),
        PluginModelInfo(id: "gpt-5.3-codex-spark", displayName: "GPT-5.3 Codex Spark"),
        PluginModelInfo(id: "gpt-5.2", displayName: "GPT-5.2"),
        PluginModelInfo(id: "gpt-5.2-codex", displayName: "GPT-5.2 Codex"),
        PluginModelInfo(id: "gpt-5.1-codex", displayName: "GPT-5.1 Codex"),
        PluginModelInfo(id: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max"),
        PluginModelInfo(id: "gpt-5.1-codex-mini", displayName: "GPT-5.1 Codex Mini"),
    ]

    private static let fallbackLLMModels: [PluginModelInfo] = [
        PluginModelInfo(id: "gpt-4.1-nano", displayName: "GPT-4.1 Nano"),
        PluginModelInfo(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini"),
        PluginModelInfo(id: "gpt-4.1", displayName: "GPT-4.1"),
        PluginModelInfo(id: "gpt-4o", displayName: "GPT-4o"),
        PluginModelInfo(id: "gpt-4o-mini", displayName: "GPT-4o Mini"),
        PluginModelInfo(id: "o4-mini", displayName: "o4-mini"),
    ]

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: Self.storageKeys.apiKey)
        _oauthAccessToken = host.loadSecret(key: Self.storageKeys.oauthAccessToken)
        _oauthRefreshToken = host.loadSecret(key: Self.storageKeys.oauthRefreshToken)
        _oauthIDToken = host.loadSecret(key: Self.storageKeys.oauthIDToken)

        if let rawMode = host.userDefault(forKey: Self.storageKeys.authMode) as? String,
           let authMode = OpenAIAuthMode(rawValue: rawMode) {
            _authMode = authMode
        }
        if let rawReasoningEffort = host.userDefault(forKey: Self.storageKeys.reasoningEffort) as? String,
           let reasoningEffort = OpenAIReasoningEffort(rawValue: rawReasoningEffort) {
            _reasoningEffort = reasoningEffort
        }

        if let data = host.userDefault(forKey: Self.storageKeys.fetchedLLMModels) as? Data,
           let models = try? JSONDecoder().decode([OpenAIFetchedModel].self, from: data) {
            _fetchedLLMModels = models
        }

        _selectedModelId = host.userDefault(forKey: Self.storageKeys.selectedModel) as? String
            ?? transcriptionModels.first?.id
        _selectedLLMModelId = host.userDefault(forKey: Self.storageKeys.selectedLLMModel) as? String
            ?? supportedModels.first?.id
        _llmTemperatureModeRaw = host.userDefault(forKey: Self.storageKeys.llmTemperatureMode) as? String
            ?? PluginLLMTemperatureMode.providerDefault.rawValue
        _llmTemperatureValue = host.userDefault(forKey: Self.storageKeys.llmTemperatureValue) as? Double
            ?? 0.3
        _oauthAccountID = host.userDefault(forKey: Self.storageKeys.oauthAccountID) as? String
        _oauthPlanType = host.userDefault(forKey: Self.storageKeys.oauthPlanType) as? String
        _oauthExpiresAt = host.userDefault(forKey: Self.storageKeys.oauthExpiresAt) as? Date

        normalizeSelectedLLMModel()
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "openai" }
    var providerDisplayName: String { "OpenAI / ChatGPT" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "whisper-1", displayName: "Whisper 1"),
            PluginModelInfo(id: "gpt-4o-transcribe", displayName: "GPT-4o Transcribe"),
            PluginModelInfo(id: "gpt-4o-mini-transcribe", displayName: "GPT-4o Mini Transcribe"),
        ]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: Self.storageKeys.selectedModel)
    }

    var supportsTranslation: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }

    var supportedLanguages: [String] {
        [
            "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
            "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
            "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
            "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
            "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
            "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
            "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
            "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
            "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
            "tr", "tt", "uk", "ur", "uz", "vi", "vo", "yi", "yo", "yue",
            "zh",
        ]
    }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        let responseFormat = modelId.hasPrefix("gpt-4o") ? "json" : "verbose_json"

        return try await transcriptionHelper.transcribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelId,
            language: language,
            translate: translate && !modelId.hasPrefix("gpt-4o"),
            prompt: prompt,
            responseFormat: responseFormat
        )
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "OpenAI" }

    var isAvailable: Bool {
        switch _authMode {
        case .apiKey:
            return isConfigured
        case .chatGPT:
            return hasChatGPTCredentials
        }
    }

    var supportedModels: [PluginModelInfo] {
        if _authMode == .chatGPT {
            return Self.chatGPTOAuthModels
        }
        if !_fetchedLLMModels.isEmpty {
            return _fetchedLLMModels.map { PluginModelInfo(id: $0.id, displayName: $0.id) }
        }
        return Self.fallbackLLMModels
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: .inheritProviderSetting
        )
    }

    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String {
        let modelId = model ?? _selectedLLMModelId ?? supportedModels.first!.id
        let reasoningEffort = Self.supportsReasoningEffort(for: modelId) ? _reasoningEffort.rawValue : nil

        switch _authMode {
        case .apiKey:
            guard let apiKey = _apiKey, !apiKey.isEmpty else {
                throw PluginChatError.notConfigured
            }
            return try await chatHelper.process(
                apiKey: apiKey,
                model: modelId,
                systemPrompt: systemPrompt,
                userText: userText,
                maxOutputTokenParameter: Self.outputTokenParameter(for: modelId),
                reasoningEffort: reasoningEffort,
                temperature: resolvedTemperature(
                    for: modelId,
                    reasoningEffort: reasoningEffort,
                    temperatureDirective: temperatureDirective
                )
            )
        case .chatGPT:
            return try await processWithChatGPT(systemPrompt: systemPrompt, userText: userText, model: modelId)
        }
    }

    func selectLLMModel(_ modelId: String) {
        _selectedLLMModelId = modelId
        host?.setUserDefault(modelId, forKey: Self.storageKeys.selectedLLMModel)
    }

    var selectedLLMModelId: String? { _selectedLLMModelId }
    fileprivate var reasoningEffort: OpenAIReasoningEffort { _reasoningEffort }
    fileprivate var llmTemperatureMode: PluginLLMTemperatureMode {
        PluginLLMTemperatureMode(rawValue: _llmTemperatureModeRaw) ?? .providerDefault
    }
    fileprivate var llmTemperatureValue: Double { _llmTemperatureValue }

    fileprivate func setReasoningEffort(_ effort: OpenAIReasoningEffort) {
        _reasoningEffort = effort
        host?.setUserDefault(effort.rawValue, forKey: Self.storageKeys.reasoningEffort)
    }

    fileprivate func setLLMTemperatureMode(_ mode: PluginLLMTemperatureMode) {
        _llmTemperatureModeRaw = mode.rawValue
        host?.setUserDefault(mode.rawValue, forKey: Self.storageKeys.llmTemperatureMode)
    }

    fileprivate func setLLMTemperatureValue(_ value: Double) {
        let clamped = min(max(value, 0.0), 2.0)
        _llmTemperatureValue = clamped
        host?.setUserDefault(clamped, forKey: Self.storageKeys.llmTemperatureValue)
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(OpenAISettingsView(plugin: self))
    }

    // MARK: - Internal State

    fileprivate var authMode: OpenAIAuthMode { _authMode }
    fileprivate var hasChatGPTCredentials: Bool {
        guard let refreshToken = _oauthRefreshToken, !refreshToken.isEmpty else {
            return (_oauthAccessToken?.isEmpty == false)
        }
        return !refreshToken.isEmpty
    }

    fileprivate var chatGPTPlanType: String? { _oauthPlanType }
    fileprivate func supportsReasoningEffort(for modelID: String) -> Bool {
        Self.supportsReasoningEffort(for: modelID)
    }

    fileprivate func supportsCustomTemperature(for modelID: String) -> Bool {
        let reasoningEffort = Self.supportsReasoningEffort(for: modelID) ? _reasoningEffort.rawValue : nil
        return Self.supportsCustomTemperature(for: modelID, reasoningEffort: reasoningEffort)
    }

    fileprivate func resolvedTemperature(
        for modelID: String,
        reasoningEffort: String?,
        temperatureDirective: PluginLLMTemperatureDirective
    ) -> Double? {
        switch temperatureDirective {
        case .providerDefault:
            return Self.chatCompletionTemperature(for: modelID, reasoningEffort: reasoningEffort)
        case .custom(let value):
            return Self.supportsCustomTemperature(for: modelID, reasoningEffort: reasoningEffort) ? value : nil
        case .inheritProviderSetting:
            switch llmTemperatureMode {
            case .providerDefault, .inheritProviderSetting:
                return Self.chatCompletionTemperature(for: modelID, reasoningEffort: reasoningEffort)
            case .custom:
                return Self.supportsCustomTemperature(for: modelID, reasoningEffort: reasoningEffort) ? _llmTemperatureValue : nil
            }
        }
    }

    fileprivate func setAuthMode(_ mode: OpenAIAuthMode) {
        _authMode = mode
        host?.setUserDefault(mode.rawValue, forKey: Self.storageKeys.authMode)
        normalizeSelectedLLMModel()
        host?.notifyCapabilitiesChanged()
    }

    func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: Self.storageKeys.apiKey, value: key)
            } catch {
                print("[OpenAIPlugin] Failed to store API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func removeApiKey() {
        _apiKey = nil
        if let host {
            do {
                try host.storeSecret(key: Self.storageKeys.apiKey, value: "")
            } catch {
                print("[OpenAIPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func validateApiKey(_ key: String) async -> Bool {
        await transcriptionHelper.validateApiKey(key)
    }

    fileprivate func setFetchedLLMModels(_ models: [OpenAIFetchedModel]) {
        _fetchedLLMModels = models
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: Self.storageKeys.fetchedLLMModels)
        }
        normalizeSelectedLLMModel()
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func fetchLLMModels() async -> [OpenAIFetchedModel] {
        guard let apiKey = _apiKey, !apiKey.isEmpty,
              let url = URL(string: "https://api.openai.com/v1/models") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }

            struct ModelsResponse: Decodable {
                let data: [OpenAIFetchedModel]
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data
                .filter { Self.isChatModel($0.id) }
                .sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }

    fileprivate func loginWithChatGPTInBrowser() async throws {
        let state = randomState()
        let pkce = generatePKCECodes()
        let server = OpenAILoopbackOAuthServer(expectedState: state)

        do {
            try server.start()
        } catch {
            throw OpenAIOAuthError.callbackPortUnavailable
        }

        let authURL = buildOAuthAuthorizeURL(state: state, pkce: pkce)
        NSWorkspace.shared.open(authURL)

        do {
            let code = try await server.waitForCode()
            let tokens = try await exchangeAuthorizationCode(code, pkce: pkce)
            storeOAuthTokens(tokens)
        } catch {
            server.stop()
            throw error
        }
    }

    fileprivate func importCodexLogin() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else {
            throw OpenAIOAuthError.codexAuthMissing
        }

        struct CodexAuthStore: Decodable {
            struct Tokens: Decodable {
                let access_token: String
                let refresh_token: String
                let id_token: String?
                let account_id: String?
            }

            let tokens: Tokens
        }

        let store = try JSONDecoder().decode(CodexAuthStore.self, from: data)
        let imported = OpenAIOAuthTokenResponse(
            id_token: store.tokens.id_token,
            access_token: store.tokens.access_token,
            refresh_token: store.tokens.refresh_token,
            expires_in: nil
        )
        storeOAuthTokens(imported, preferredAccountID: store.tokens.account_id)
    }

    fileprivate func clearChatGPTLogin() {
        _oauthAccessToken = nil
        _oauthRefreshToken = nil
        _oauthIDToken = nil
        _oauthAccountID = nil
        _oauthPlanType = nil
        _oauthExpiresAt = nil

        if let host {
            do {
                try host.storeSecret(key: Self.storageKeys.oauthAccessToken, value: "")
                try host.storeSecret(key: Self.storageKeys.oauthRefreshToken, value: "")
                try host.storeSecret(key: Self.storageKeys.oauthIDToken, value: "")
            } catch {
                print("[OpenAIPlugin] Failed to clear OAuth tokens: \(error)")
            }

            host.setUserDefault(nil, forKey: Self.storageKeys.oauthAccountID)
            host.setUserDefault(nil, forKey: Self.storageKeys.oauthPlanType)
            host.setUserDefault(nil, forKey: Self.storageKeys.oauthExpiresAt)
            host.notifyCapabilitiesChanged()
        }
    }

    private func normalizeSelectedLLMModel() {
        let availableIDs = Set(supportedModels.map(\.id))
        guard let selected = _selectedLLMModelId, availableIDs.contains(selected) else {
            let fallback = supportedModels.first?.id
            _selectedLLMModelId = fallback
            host?.setUserDefault(fallback, forKey: Self.storageKeys.selectedLLMModel)
            return
        }
    }

    private func storeOAuthTokens(_ tokens: OpenAIOAuthTokenResponse, preferredAccountID: String? = nil) {
        let metadata = extractOAuthMetadata(from: tokens)
        _oauthAccessToken = tokens.access_token
        _oauthRefreshToken = tokens.refresh_token
        _oauthIDToken = tokens.id_token
        _oauthAccountID = preferredAccountID ?? metadata.accountID
        _oauthPlanType = metadata.planType
        _oauthExpiresAt = metadata.expiresAt ?? Date().addingTimeInterval(Double(tokens.expires_in ?? 3600))

        if let host {
            do {
                try host.storeSecret(key: Self.storageKeys.oauthAccessToken, value: tokens.access_token)
                try host.storeSecret(key: Self.storageKeys.oauthRefreshToken, value: tokens.refresh_token)
                try host.storeSecret(key: Self.storageKeys.oauthIDToken, value: tokens.id_token ?? "")
            } catch {
                print("[OpenAIPlugin] Failed to store OAuth tokens: \(error)")
            }
            host.setUserDefault(_oauthAccountID, forKey: Self.storageKeys.oauthAccountID)
            host.setUserDefault(_oauthPlanType, forKey: Self.storageKeys.oauthPlanType)
            host.setUserDefault(_oauthExpiresAt, forKey: Self.storageKeys.oauthExpiresAt)
            normalizeSelectedLLMModel()
            host.notifyCapabilitiesChanged()
        }
    }

    private func validOAuthAccessToken() async throws -> String {
        if let accessToken = _oauthAccessToken,
           let expiresAt = _oauthExpiresAt,
           expiresAt.timeIntervalSinceNow > 60 {
            return accessToken
        }

        guard let refreshToken = _oauthRefreshToken, !refreshToken.isEmpty else {
            throw OpenAIOAuthError.missingCredentials
        }

        let refreshed = try await refreshOAuthToken(refreshToken)
        storeOAuthTokens(refreshed, preferredAccountID: _oauthAccountID)
        return refreshed.access_token
    }

    private func processWithChatGPT(systemPrompt: String, userText: String, model: String) async throws -> String {
        let accessToken = try await validOAuthAccessToken()
        let endpoint = URL(string: OpenAIOAuthConfig.codexAPIEndpoint)!

        let instructions = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "You are a helpful assistant."
            : systemPrompt

        let requestBody: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": userText,
                        ],
                    ],
                ],
            ],
            "store": false,
            "stream": true,
        ]

        var mutableRequestBody = requestBody
        if Self.supportsReasoningEffort(for: model) {
            mutableRequestBody["reasoning"] = ["effort": _reasoningEffort.rawValue]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let accountID = _oauthAccountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: mutableRequestBody)

        let (data, response) = try await PluginHTTPClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginChatError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw PluginChatError.invalidApiKey
        case 429:
            throw PluginChatError.rateLimited
        default:
            throw PluginChatError.apiError(parseChatGPTErrorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        if let text = parseChatGPTResponseText(from: data) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw OpenAIOAuthError.responseParsingFailed
    }

    private func parseChatGPTErrorMessage(from data: Data, statusCode: Int) -> String {
        let fallback = "HTTP \(statusCode)"

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback
        }

        if let detail = json["detail"] as? String, !detail.isEmpty {
            return detail
        }

        if let error = json["error"] as? [String: Any],
           let apiMessage = error["message"] as? String,
           !apiMessage.isEmpty {
            return apiMessage
        }

        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }

        return fallback
    }

    private func parseChatGPTResponseText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return parseChatGPTEventStreamText(from: data)
        }

        if let outputText = json["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }

        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any] {
            if let content = message["content"] as? String, !content.isEmpty {
                return content
            }
            if let blocks = message["content"] as? [[String: Any]] {
                let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !text.isEmpty { return text }
            }
        }

        if let output = json["output"] as? [[String: Any]] {
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    let text = content.compactMap { block in
                        (block["text"] as? String) ?? ((block["content"] as? [String: Any])?["text"] as? String)
                    }.joined(separator: "\n")
                    if !text.isEmpty { return text }
                }
            }
        }

        return nil
    }

    private func parseChatGPTEventStreamText(from data: Data) -> String? {
        guard let stream = String(data: data, encoding: .utf8) else {
            return nil
        }

        var deltaBuffer = ""
        var completedParts: [String] = []

        for rawLine in stream.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.hasPrefix("data: ") else { continue }

            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]",
                  let payloadData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            switch type {
            case "response.output_text.delta":
                if let delta = json["delta"] as? String {
                    deltaBuffer.append(delta)
                }
            case "response.output_text.done":
                if let text = json["text"] as? String, !text.isEmpty {
                    completedParts.append(text)
                }
            case "response.content_part.done":
                if let part = json["part"] as? [String: Any],
                   let text = part["text"] as? String,
                   !text.isEmpty {
                    completedParts.append(text)
                }
            default:
                continue
            }
        }

        if !deltaBuffer.isEmpty {
            return deltaBuffer
        }

        let completedText = completedParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return completedText.isEmpty ? nil : completedText
    }

    private static let chatPrefixes = ["gpt-", "o1-", "o3-", "o4-", "chatgpt-"]
    private static let excludeSuffixes = ["-transcribe", "-tts", "-embedding", "-realtime", "-search"]
    private static let excludeContains = ["dall-e", "whisper", "tts-", "text-embedding", "audio-preview", "gpt-image"]

    nonisolated static func isChatModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        guard chatPrefixes.contains(where: { lowered.hasPrefix($0) }) else { return false }
        if excludeSuffixes.contains(where: { lowered.hasSuffix($0) }) { return false }
        if excludeContains.contains(where: { lowered.contains($0) }) { return false }
        return true
    }

    nonisolated static func outputTokenParameter(for modelID: String) -> String {
        let lowered = modelID.lowercased()
        if lowered.hasPrefix("gpt-5")
            || lowered.hasPrefix("o1")
            || lowered.hasPrefix("o3")
            || lowered.hasPrefix("o4") {
            return "max_completion_tokens"
        }
        return "max_tokens"
    }

    nonisolated static func supportsReasoningEffort(for modelID: String) -> Bool {
        let lowered = modelID.lowercased()
        return lowered.hasPrefix("gpt-5")
            || lowered.hasPrefix("o1")
            || lowered.hasPrefix("o3")
            || lowered.hasPrefix("o4")
            || lowered.contains("codex")
    }

    nonisolated static func supportsCustomTemperature(for modelID: String, reasoningEffort: String?) -> Bool {
        chatCompletionTemperature(for: modelID, reasoningEffort: reasoningEffort) != nil
    }

    nonisolated static func chatCompletionTemperature(for modelID: String, reasoningEffort: String?) -> Double? {
        let lowered = modelID.lowercased()
        if lowered.hasPrefix("gpt-5"), reasoningEffort?.isEmpty == false {
            return nil
        }
        return 0.3
    }
}

// MARK: - Fetched Model

struct OpenAIFetchedModel: Codable, Sendable {
    let id: String
    let owned_by: String?

    enum CodingKeys: String, CodingKey {
        case id
        case owned_by
    }

    init(id: String, owned_by: String?) {
        self.id = id
        self.owned_by = owned_by
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        owned_by = try container.decodeIfPresent(String.self, forKey: .owned_by)
    }
}

// MARK: - Settings View

private struct OpenAISettingsView: View {
    let plugin: OpenAIPlugin
    @State private var authMode: OpenAIAuthMode = .apiKey
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var selectedLLMModel: String = ""
    @State private var selectedReasoningEffort: OpenAIReasoningEffort = .medium
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var fetchedLLMModels: [OpenAIFetchedModel] = []
    @State private var oauthBusy = false
    @State private var oauthStatusMessage: String?
    @State private var oauthErrorMessage: String?
    private let bundle = Bundle(for: OpenAIPlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connection Method", bundle: bundle)
                    .font(.headline)

                Picker("Connection Method", selection: $authMode) {
                    Text("API Key", bundle: bundle).tag(OpenAIAuthMode.apiKey)
                    Text("ChatGPT Login", bundle: bundle).tag(OpenAIAuthMode.chatGPT)
                }
                .pickerStyle(.segmented)
                .onChange(of: authMode) {
                    plugin.setAuthMode(authMode)
                    selectedLLMModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
                    oauthErrorMessage = nil
                    oauthStatusMessage = nil
                }
            }

            if authMode == .apiKey {
                apiKeySection
            } else {
                chatGPTSection
            }

            if plugin.isConfigured {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcription Model", bundle: bundle)
                        .font(.headline)

                    Picker("Transcription Model", selection: $selectedModel) {
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectModel(selectedModel)
                    }

                    if selectedModel.hasPrefix("gpt-4o") {
                        Text("GPT-4o models do not support Whisper Translate (translation to English).", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if plugin.isAvailable {
                Divider()
                llmSection
            }
        }
        .padding()
        .onAppear {
            authMode = plugin.authMode
            if let key = plugin._apiKey, !key.isEmpty {
                apiKeyInput = key
            }
            selectedModel = plugin.selectedModelId ?? plugin.transcriptionModels.first?.id ?? ""
            selectedLLMModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
            selectedReasoningEffort = plugin.reasoningEffort
            llmTemperatureMode = plugin.llmTemperatureMode
            llmTemperatureValue = plugin.llmTemperatureValue
            fetchedLLMModels = plugin._fetchedLLMModels
        }
    }

    private var apiKeySection: some View {
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

                if plugin._apiKey?.isEmpty == false {
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
                        saveApiKey()
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
            } else if let result = validationResult {
                HStack(spacing: 4) {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result ? .green : .red)
                    Text(result ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle))
                        .font(.caption)
                        .foregroundStyle(result ? .green : .red)
                }
            }

            Text("API keys are stored securely in the Keychain", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var chatGPTSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ChatGPT Login", bundle: bundle)
                .font(.headline)

            Text("Use your existing ChatGPT Plus/Pro or Codex login for prompt processing. Transcription still requires an API key.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(String(localized: "Sign In In Browser", bundle: bundle)) {
                    startBrowserLogin()
                }
                .buttonStyle(.borderedProminent)
                .disabled(oauthBusy)

                Button(String(localized: "Import Codex Login", bundle: bundle)) {
                    importCodexLogin()
                }
                .buttonStyle(.bordered)
                .disabled(oauthBusy)

                if plugin.hasChatGPTCredentials {
                    Button(String(localized: "Remove", bundle: bundle)) {
                        plugin.clearChatGPTLogin()
                        oauthStatusMessage = nil
                        oauthErrorMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                    .disabled(oauthBusy)
                }
            }

            if oauthBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for OpenAI login...", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if plugin.hasChatGPTCredentials {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("ChatGPT login connected", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if let plan = plugin.chatGPTPlanType, !plan.isEmpty {
                Text(String(localized: "Connected plan: \(plan)", bundle: bundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let oauthStatusMessage, !oauthStatusMessage.isEmpty {
                Text(oauthStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let oauthErrorMessage, !oauthErrorMessage.isEmpty {
                Text(oauthErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var llmSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LLM Model", bundle: bundle)
                    .font(.headline)

                Spacer()

                if authMode == .apiKey {
                    Button {
                        refreshLLMModels()
                    } label: {
                        Label(String(localized: "Refresh", bundle: bundle), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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

            if plugin.supportsReasoningEffort(for: selectedLLMModel) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reasoning Effort", bundle: bundle)
                        .font(.headline)

                    Picker("Reasoning Effort", selection: $selectedReasoningEffort) {
                        ForEach(OpenAIReasoningEffort.allCases, id: \.self) { effort in
                            Text(LocalizedStringKey(effort.localizedKey), bundle: bundle).tag(effort)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedReasoningEffort) {
                        plugin.setReasoningEffort(selectedReasoningEffort)
                    }

                    Text("Controls how much thinking time the model spends before answering.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if authMode == .chatGPT {
                Text("ChatGPT login exposes only the supported ChatGPT/Codex models.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if fetchedLLMModels.isEmpty {
                Text("Using default models. Press Refresh to fetch all available models.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if authMode == .apiKey {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperature", bundle: bundle)
                        .font(.headline)

                    Picker("Temperature Mode", selection: $llmTemperatureMode) {
                        Text("Provider Default", bundle: bundle).tag(PluginLLMTemperatureMode.providerDefault)
                        Text("Custom", bundle: bundle).tag(PluginLLMTemperatureMode.custom)
                    }
                    .onChange(of: llmTemperatureMode) {
                        plugin.setLLMTemperatureMode(llmTemperatureMode)
                    }

                    if llmTemperatureMode == .custom {
                        HStack {
                            Text("Temperature", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(llmTemperatureValue, format: .number.precision(.fractionLength(2)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(value: $llmTemperatureValue, in: 0...2, step: 0.1)
                            .onChange(of: llmTemperatureValue) {
                                plugin.setLLMTemperatureValue(llmTemperatureValue)
                            }
                    }

                    if llmTemperatureMode == .custom,
                       !plugin.supportsCustomTemperature(for: selectedLLMModel) {
                        Text("Custom temperature is ignored for the selected GPT-5 reasoning configuration.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
            if isValid {
                let models = await plugin.fetchLLMModels()
                await MainActor.run {
                    isValidating = false
                    validationResult = true
                    if !models.isEmpty {
                        fetchedLLMModels = models
                        plugin.setFetchedLLMModels(models)
                        selectedLLMModel = plugin.selectedLLMModelId ?? models.first?.id ?? selectedLLMModel
                    }
                }
            } else {
                await MainActor.run {
                    isValidating = false
                    validationResult = false
                }
            }
        }
    }

    private func refreshLLMModels() {
        Task {
            let models = await plugin.fetchLLMModels()
            await MainActor.run {
                if !models.isEmpty {
                    fetchedLLMModels = models
                    plugin.setFetchedLLMModels(models)
                    if !models.contains(where: { $0.id == selectedLLMModel }),
                       let first = models.first {
                        selectedLLMModel = first.id
                        plugin.selectLLMModel(first.id)
                    }
                }
            }
        }
    }

    private func startBrowserLogin() {
        oauthBusy = true
        oauthStatusMessage = String(localized: "Complete the OpenAI login in your browser. TypeWhisper will finish the connection automatically.", bundle: bundle)
        oauthErrorMessage = nil

        Task {
            do {
                try await plugin.loginWithChatGPTInBrowser()
                await MainActor.run {
                    oauthBusy = false
                    oauthStatusMessage = String(localized: "ChatGPT login connected.", bundle: bundle)
                    selectedLLMModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
                    selectedReasoningEffort = plugin.reasoningEffort
                }
            } catch {
                await MainActor.run {
                    oauthBusy = false
                    oauthErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func importCodexLogin() {
        oauthErrorMessage = nil
        oauthStatusMessage = nil

        do {
            try plugin.importCodexLogin()
            oauthStatusMessage = String(localized: "Imported your existing Codex login.", bundle: bundle)
            selectedLLMModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
            selectedReasoningEffort = plugin.reasoningEffort
        } catch {
            oauthErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Utilities

private struct URLSearchParams {
    let values: [String: String]

    init(_ values: [String: String]) {
        self.values = values
    }

    var data: Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

private extension Data {
    init?(base64URLString: String) {
        var normalized = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        self.init(base64Encoded: normalized)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
