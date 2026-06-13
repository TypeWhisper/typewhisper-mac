import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

@objc(SaluteSpeechPlugin)
final class SaluteSpeechPlugin: NSObject, TranscriptionEnginePlugin, PluginAuthRoleStatusProviding, TranscriptPreviewFallbackPolicyProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.sber-salutespeech"
    static let pluginName = "Sber SaluteSpeech"

    static let personalScope = "SALUTE_SPEECH_PERS"
    static let corporateScope = "SALUTE_SPEECH_CORP"

    private static let authorizationKeySecret = "authorization-key"
    private static let selectedModelDefault = "selectedModel"
    private static let scopeDefault = "scope"
    private static let defaultModelId = "general"
    private static let defaultRecognitionLanguage = "ru-RU"

    private let state = SaluteSpeechPluginState()
    private let tokenCache = SaluteSpeechTokenCache()
    private let usageStore = SaluteSpeechUsageStore()
    private let logger = Logger(subsystem: "com.typewhisper.sber-salutespeech", category: "Plugin")

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        usageStore.configure(dataDirectory: host.pluginDataDirectory)
        state.activate(
            host: host,
            authorizationKey: Self.normalizedAuthorizationKey(
                host.loadSecret(key: Self.authorizationKeySecret) ?? ""
            ).nilIfEmpty,
            scope: Self.resolvedScope(host.userDefault(forKey: Self.scopeDefault) as? String),
            selectedModelId: host.userDefault(forKey: Self.selectedModelDefault) as? String
                ?? Self.defaultModelId
        )
    }

    func deactivate() {
        state.deactivate()
        Task { await tokenCache.clear() }
    }

    var providerId: String { "sber-salutespeech" }
    var providerDisplayName: String { "Sber SaluteSpeech" }

    var isConfigured: Bool {
        guard let key = state.snapshot().authorizationKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: Self.defaultModelId, displayName: "General"),
        ]
    }

    var selectedModelId: String? {
        state.snapshot().selectedModelId ?? Self.defaultModelId
    }

    func selectModel(_ modelId: String) {
        state.currentHost()?.setUserDefault(modelId, forKey: Self.selectedModelDefault)
        state.updateSelectedModelId(modelId)
    }

    var supportsTranslation: Bool { false }

    var supportedLanguages: [String] {
        ["ru", "ru-RU", "en", "en-US"]
    }

    var allowsTranscriptPreviewFallback: Bool { false }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard !translate else {
            throw PluginTranscriptionError.apiError("Sber SaluteSpeech does not support translation.")
        }

        let snapshot = state.snapshot()
        guard let authorizationKey = snapshot.authorizationKey, !authorizationKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }

        let pcmData = Self.makePCM16LEData(samples: audio.samples)
        guard !pcmData.isEmpty else {
            throw PluginTranscriptionError.apiError("Sber SaluteSpeech requires non-empty PCM audio samples.")
        }

        let token = try await accessToken(
            authorizationKey: authorizationKey,
            scope: snapshot.scope
        )
        let modelId = snapshot.selectedModelId ?? Self.defaultModelId
        let recognitionLanguage = Self.resolvedRecognitionLanguage(language)

        let result: PluginTranscriptionResult
        if pcmData.count <= Self.syncMaxBytes, audio.duration <= Self.syncMaxDuration {
            result = try await recognizeSync(
                pcmData: pcmData,
                token: token,
                modelId: modelId,
                language: recognitionLanguage
            )
        } else {
            result = try await recognizeAsync(
                pcmData: pcmData,
                token: token,
                modelId: modelId,
                language: recognitionLanguage,
                duration: audio.duration
            )
        }

        usageStore.recordSuccessfulRecognition(duration: audio.duration)
        return result
    }

    @MainActor
    var settingsView: AnyView? {
        AnyView(SaluteSpeechSettingsView(plugin: self))
    }

    func authStatus(for role: PluginAuthRole) -> PluginAuthRoleStatus {
        guard role == .transcription else { return .available }
        return PluginAuthRoleStatus.legacyFallback(
            isConfigured: isConfigured,
            unavailableReason: "Sber SaluteSpeech Authorization Key is missing.",
            requiredCredentialLabel: "Authorization Key"
        )
    }

    var authorizationKeyForSettings: String? {
        state.snapshot().authorizationKey
    }

    var scopeForSettings: String {
        state.snapshot().scope
    }

    func setAuthorizationKey(_ key: String) throws {
        guard let host = state.currentHost() else {
            throw SaluteSpeechPluginConfigurationError.missingHost
        }

        let normalized = Self.normalizedAuthorizationKey(key)
        guard !normalized.isEmpty else {
            throw SaluteSpeechPluginConfigurationError.emptyAuthorizationKey
        }

        do {
            try host.storeSecret(key: Self.authorizationKeySecret, value: normalized)
            state.updateAuthorizationKey(normalized)
            Task { await tokenCache.clear() }
            host.notifyCapabilitiesChanged()
        } catch {
            logger.error("Failed to store Sber SaluteSpeech Authorization Key: \(error.localizedDescription)")
            throw error
        }
    }

    func removeAuthorizationKey() throws {
        guard let host = state.currentHost() else {
            throw SaluteSpeechPluginConfigurationError.missingHost
        }

        do {
            try host.storeSecret(key: Self.authorizationKeySecret, value: "")
            state.updateAuthorizationKey(nil)
            Task { await tokenCache.clear() }
            host.notifyCapabilitiesChanged()
        } catch {
            logger.error("Failed to delete Sber SaluteSpeech Authorization Key: \(error.localizedDescription)")
            throw error
        }
    }

    func setScope(_ scope: String) {
        let resolvedScope = Self.resolvedScope(scope)
        state.currentHost()?.setUserDefault(resolvedScope, forKey: Self.scopeDefault)
        state.updateScope(resolvedScope)
        Task { await tokenCache.clear() }
    }

    func validateAuthorizationKey(_ key: String, scope: String) async -> AuthorizationKeyValidationResult {
        let normalized = Self.normalizedAuthorizationKey(key)
        guard !normalized.isEmpty else { return .invalidKey }

        do {
            _ = try await requestAccessToken(
                authorizationKey: normalized,
                scope: Self.resolvedScope(scope)
            )
            return .valid
        } catch let error as PluginTranscriptionError {
            switch error {
            case .invalidApiKey:
                return .invalidKey
            default:
                return .transientError
            }
        } catch {
            return .transientError
        }
    }

    var usageSnapshotForSettings: SaluteSpeechUsageSnapshot {
        usageStore.snapshot()
    }

    func setUsageBalanceCorrection(remainingMinutes: Double?, validUntil: Date?) throws {
        try usageStore.setBalanceCorrection(remainingMinutes: remainingMinutes, validUntil: validUntil)
    }

    func clearUsageBalanceCorrection() throws {
        try usageStore.clearBalanceCorrection()
    }

    func resetRecognitionUsage() throws {
        try usageStore.resetTrackedUsage()
    }

    enum AuthorizationKeyValidationResult: Equatable {
        case valid
        case invalidKey
        case transientError
    }
}

private struct SaluteSpeechPluginStateSnapshot: Sendable {
    let authorizationKey: String?
    let scope: String
    let selectedModelId: String?
}

private final class SaluteSpeechPluginState: @unchecked Sendable {
    private let lock = NSLock()
    private var host: HostServices?
    private var authorizationKey: String?
    private var scope = SaluteSpeechPlugin.personalScope
    private var selectedModelId: String?

    func activate(
        host: HostServices,
        authorizationKey: String?,
        scope: String,
        selectedModelId: String?
    ) {
        lock.withLock {
            self.host = host
            self.authorizationKey = authorizationKey
            self.scope = scope
            self.selectedModelId = selectedModelId
        }
    }

    func deactivate() {
        lock.withLock {
            host = nil
            authorizationKey = nil
            scope = SaluteSpeechPlugin.personalScope
            selectedModelId = nil
        }
    }

    func currentHost() -> HostServices? {
        lock.withLock { host }
    }

    func snapshot() -> SaluteSpeechPluginStateSnapshot {
        lock.withLock {
            SaluteSpeechPluginStateSnapshot(
                authorizationKey: authorizationKey,
                scope: scope,
                selectedModelId: selectedModelId
            )
        }
    }

    func updateAuthorizationKey(_ authorizationKey: String?) {
        lock.withLock {
            self.authorizationKey = authorizationKey
        }
    }

    func updateScope(_ scope: String) {
        lock.withLock {
            self.scope = scope
        }
    }

    func updateSelectedModelId(_ selectedModelId: String) {
        lock.withLock {
            self.selectedModelId = selectedModelId
        }
    }
}

private actor SaluteSpeechTokenCache {
    private var token: String?
    private var expiresAt: Date?
    private var authorizationKey: String?
    private var scope: String?

    func cachedToken(authorizationKey: String, scope: String, now: Date = Date()) -> String? {
        guard let token, let expiresAt else { return nil }
        guard self.authorizationKey == authorizationKey, self.scope == scope else { return nil }
        guard expiresAt.timeIntervalSince(now) > 60 else { return nil }
        return token
    }

    func store(
        token: String,
        authorizationKey: String,
        scope: String,
        expiresAtMilliseconds: Int64?
    ) {
        self.token = token
        self.authorizationKey = authorizationKey
        self.scope = scope

        guard let expiresAtMilliseconds else {
            expiresAt = Date().addingTimeInterval(29 * 60)
            return
        }

        let rawTimestamp = Double(expiresAtMilliseconds)
        let seconds = rawTimestamp > 20_000_000_000 ? rawTimestamp / 1_000 : rawTimestamp
        expiresAt = Date(timeIntervalSince1970: seconds)
    }

    func clear() {
        token = nil
        expiresAt = nil
        authorizationKey = nil
        scope = nil
    }
}

struct SaluteSpeechUsageSnapshot: Equatable, Sendable {
    let trackedSeconds: TimeInterval
    let lastTranscriptionAt: Date?
    let balanceRemainingSeconds: TimeInterval?
    let balanceRecordedTrackedSeconds: TimeInterval?
    let balanceUpdatedAt: Date?
    let balanceValidUntil: Date?

    static let empty = SaluteSpeechUsageSnapshot(
        trackedSeconds: 0,
        lastTranscriptionAt: nil,
        balanceRemainingSeconds: nil,
        balanceRecordedTrackedSeconds: nil,
        balanceUpdatedAt: nil,
        balanceValidUntil: nil
    )

    var spentSinceBalanceCorrectionSeconds: TimeInterval {
        guard let balanceRecordedTrackedSeconds else { return 0 }
        return max(0, trackedSeconds - balanceRecordedTrackedSeconds)
    }

    var estimatedRemainingSeconds: TimeInterval? {
        guard let balanceRemainingSeconds else { return nil }
        return max(0, balanceRemainingSeconds - spentSinceBalanceCorrectionSeconds)
    }
}

private struct SaluteSpeechUsageState: Codable, Sendable {
    var trackedSeconds: TimeInterval = 0
    var lastTranscriptionAt: Date?
    var balanceRemainingSeconds: TimeInterval?
    var balanceRecordedTrackedSeconds: TimeInterval?
    var balanceUpdatedAt: Date?
    var balanceValidUntil: Date?

    var snapshot: SaluteSpeechUsageSnapshot {
        SaluteSpeechUsageSnapshot(
            trackedSeconds: trackedSeconds,
            lastTranscriptionAt: lastTranscriptionAt,
            balanceRemainingSeconds: balanceRemainingSeconds,
            balanceRecordedTrackedSeconds: balanceRecordedTrackedSeconds,
            balanceUpdatedAt: balanceUpdatedAt,
            balanceValidUntil: balanceValidUntil
        )
    }
}

private final class SaluteSpeechUsageStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileName = "recognition-usage.json"
    private let logger = Logger(subsystem: "com.typewhisper.sber-salutespeech", category: "Usage")
    private var fileURL: URL?
    private var state = SaluteSpeechUsageState()

    func configure(dataDirectory: URL) {
        lock.withLock {
            fileURL = dataDirectory.appendingPathComponent(fileName)
            state = Self.loadState(from: fileURL) ?? SaluteSpeechUsageState()
        }
    }

    func snapshot() -> SaluteSpeechUsageSnapshot {
        lock.withLock { state.snapshot }
    }

    func recordSuccessfulRecognition(duration: TimeInterval) {
        let seconds = max(0, duration)
        guard seconds > 0 else { return }

        lock.withLock {
            state.trackedSeconds += seconds
            state.lastTranscriptionAt = Date()
            do {
                try persistLocked()
            } catch {
                logger.error("Failed to persist Sber SaluteSpeech recognition usage: \(error.localizedDescription)")
            }
        }
    }

    func setBalanceCorrection(remainingMinutes: Double?, validUntil: Date?) throws {
        try lock.withLock {
            if let remainingMinutes {
                state.balanceRemainingSeconds = max(0, remainingMinutes) * 60
                state.balanceRecordedTrackedSeconds = state.trackedSeconds
                state.balanceUpdatedAt = Date()
            } else {
                state.balanceRemainingSeconds = nil
                state.balanceRecordedTrackedSeconds = nil
                state.balanceUpdatedAt = nil
            }
            state.balanceValidUntil = validUntil
            try persistLocked()
        }
    }

    func clearBalanceCorrection() throws {
        try lock.withLock {
            state.balanceRemainingSeconds = nil
            state.balanceRecordedTrackedSeconds = nil
            state.balanceUpdatedAt = nil
            state.balanceValidUntil = nil
            try persistLocked()
        }
    }

    func resetTrackedUsage() throws {
        try lock.withLock {
            state.trackedSeconds = 0
            state.lastTranscriptionAt = nil
            if state.balanceRemainingSeconds != nil {
                state.balanceRecordedTrackedSeconds = 0
            }
            try persistLocked()
        }
    }

    private static func loadState(from url: URL?) -> SaluteSpeechUsageState? {
        guard let url,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(SaluteSpeechUsageState.self, from: data)
    }

    private func persistLocked() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}

private enum SaluteSpeechPluginConfigurationError: LocalizedError {
    case missingHost
    case emptyAuthorizationKey

    var errorDescription: String? {
        switch self {
        case .missingHost:
            "Sber SaluteSpeech is not connected to TypeWhisper."
        case .emptyAuthorizationKey:
            "Sber SaluteSpeech Authorization Key is empty."
        }
    }
}

extension SaluteSpeechPlugin {
    static let tokenEndpoint = "https://ngw.devices.sberbank.ru:9443/api/v2/oauth"
    static let restBaseURL = "https://smartspeech.sber.ru/rest/v1"
    static let sampleRate = 16_000
    static let syncMaxBytes = 2 * 1024 * 1024
    static let syncMaxDuration: TimeInterval = 60
    static let pcmContentType = "audio/x-pcm;bit=16;rate=16000"

    static func normalizedAuthorizationKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("basic ") {
            return String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    static func resolvedScope(_ scope: String?) -> String {
        let trimmed = scope?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch trimmed {
        case personalScope, corporateScope:
            return trimmed
        default:
            return personalScope
        }
    }

    static func resolvedRecognitionLanguage(_ language: String?) -> String {
        let normalized = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        guard let normalized, !normalized.isEmpty else {
            return defaultRecognitionLanguage
        }

        if normalized == "en" || normalized.hasPrefix("en-") {
            return "en-US"
        }
        if normalized == "ru" || normalized.hasPrefix("ru-") {
            return "ru-RU"
        }

        return defaultRecognitionLanguage
    }

    static func makePCM16LEData(samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let intValue: Int16
            if clamped <= -1 {
                intValue = Int16.min
            } else {
                intValue = Int16(clamped * Float(Int16.max))
            }
            let raw = UInt16(bitPattern: intValue).littleEndian
            data.append(UInt8(raw & 0xff))
            data.append(UInt8((raw >> 8) & 0xff))
        }
        return data
    }

    static func makeTokenRequest(
        authorizationKey: String,
        scope: String
    ) throws -> URLRequest {
        guard let url = URL(string: tokenEndpoint) else {
            throw PluginTranscriptionError.apiError("Invalid Sber SaluteSpeech token URL")
        }

        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "scope", value: resolvedScope(scope))]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Basic \(normalizedAuthorizationKey(authorizationKey))", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "RqUID")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.timeoutInterval = 30
        return request
    }

    static func makeSyncRecognitionRequest(
        pcmData: Data,
        token: String,
        modelId: String,
        language: String
    ) throws -> URLRequest {
        var components = URLComponents(string: "\(restBaseURL)/speech:recognize")
        components?.queryItems = [
            URLQueryItem(name: "model", value: modelId),
            URLQueryItem(name: "language", value: language),
        ]
        guard let url = components?.url else {
            throw PluginTranscriptionError.apiError("Invalid Sber SaluteSpeech recognition URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(pcmContentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = pcmData
        request.timeoutInterval = 120
        return request
    }

    static func makeUploadRequest(
        pcmData: Data,
        token: String
    ) throws -> URLRequest {
        guard let url = URL(string: "\(restBaseURL)/data:upload") else {
            throw PluginTranscriptionError.apiError("Invalid Sber SaluteSpeech upload URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(pcmContentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = pcmData
        request.timeoutInterval = 120
        return request
    }

    static func makeStartAsyncRecognitionRequest(
        requestFileId: String,
        token: String,
        modelId: String,
        language: String
    ) throws -> URLRequest {
        guard let url = URL(string: "\(restBaseURL)/speech:async_recognize") else {
            throw PluginTranscriptionError.apiError("Invalid Sber SaluteSpeech async recognition URL")
        }

        let body = AsyncRecognitionRequest(
            options: AsyncRecognitionOptions(
                model: modelId,
                language: language,
                audioEncoding: "PCM_S16LE",
                sampleRate: sampleRate,
                channelsCount: 1
            ),
            requestFileId: requestFileId
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 30
        return request
    }

    static func makeTaskStatusRequest(taskId: String, token: String) throws -> URLRequest {
        var components = URLComponents(string: "\(restBaseURL)/task:get")
        components?.queryItems = [URLQueryItem(name: "id", value: taskId)]
        guard let url = components?.url else {
            throw PluginTranscriptionError.apiError("Invalid Sber SaluteSpeech task status URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    static func makeDownloadRequest(responseFileId: String, token: String) throws -> URLRequest {
        var components = URLComponents(string: "\(restBaseURL)/data:download")
        components?.queryItems = [URLQueryItem(name: "response_file_id", value: responseFileId)]
        guard let url = components?.url else {
            throw PluginTranscriptionError.apiError("Invalid Sber SaluteSpeech result download URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return request
    }

    static func validateHTTPResponse(
        data: Data,
        response: URLResponse,
        successStatusCodes: Range<Int> = 200..<300,
        mapBadRequestToInvalidKey: Bool = false
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        guard !successStatusCodes.contains(httpResponse.statusCode) else { return }

        switch httpResponse.statusCode {
        case 400 where mapBadRequestToInvalidKey:
            throw PluginTranscriptionError.invalidApiKey
        case 401, 403:
            throw PluginTranscriptionError.invalidApiKey
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            throw PluginTranscriptionError.apiError(
                "Sber SaluteSpeech HTTP \(httpResponse.statusCode): \(responseBodyMessage(data: data))"
            )
        }
    }

    static func responseBodyMessage(data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let message = firstStringValue(
                in: object,
                keys: ["message", "error_description", "error", "detail"]
            ) {
                return message
            }
        }

        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body?.nilIfEmpty ?? "Unknown error"
    }

    static func parseTokenResponse(_ data: Data) throws -> TokenResponse {
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw PluginTranscriptionError.apiError(
                "Failed to parse Sber SaluteSpeech token response: \(error.localizedDescription)"
            )
        }
    }

    static func parseRequestFileId(_ data: Data) throws -> String {
        let object = try jsonObject(from: data, context: "upload response")
        guard let id = firstStringValue(in: object, keys: ["request_file_id"]) else {
            throw PluginTranscriptionError.apiError("Sber SaluteSpeech upload response did not include request_file_id")
        }
        return id
    }

    static func parseTaskId(_ data: Data) throws -> String {
        let object = try jsonObject(from: data, context: "async recognition response")
        guard let id = firstStringValue(in: object, keys: ["id"]) else {
            throw PluginTranscriptionError.apiError("Sber SaluteSpeech async recognition response did not include task id")
        }
        return id
    }

    static func parseTaskStatus(_ data: Data) throws -> AsyncTaskStatus {
        let object = try jsonObject(from: data, context: "task status response")
        guard let status = firstStringValue(in: object, keys: ["status"]) else {
            throw PluginTranscriptionError.apiError("Sber SaluteSpeech task status response did not include status")
        }

        return AsyncTaskStatus(
            status: status,
            responseFileId: firstStringValue(in: object, keys: ["response_file_id"]),
            errorMessage: firstStringValue(
                in: object,
                keys: ["error_description", "error", "message", "detail"]
            )
        )
    }

    static func parseTranscriptionResult(_ data: Data) throws -> PluginTranscriptionResult {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            let text = collectTranscriptionTexts(from: object, allowBareString: true)
                .joined(separator: " ")
                .normalizedWhitespace
            if !text.isEmpty {
                return PluginTranscriptionResult(text: text)
            }
        }

        if let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !body.isEmpty,
           !body.hasPrefix("{"),
           !body.hasPrefix("[") {
            return PluginTranscriptionResult(text: body)
        }

        throw PluginTranscriptionError.apiError("Sber SaluteSpeech response did not include transcription text")
    }

    static func collectTranscriptionTexts(from value: Any, allowBareString: Bool = false) -> [String] {
        if let string = value as? String {
            guard allowBareString else { return [] }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        if let array = value as? [Any] {
            return array.flatMap { collectTranscriptionTexts(from: $0, allowBareString: allowBareString) }
        }

        guard let dictionary = value as? [String: Any] else {
            return []
        }

        if let text = directTranscriptionText(in: dictionary) {
            return [text]
        }

        let preferredKeys = ["results", "result", "response", "items", "chunks"]
        let preferred = preferredKeys.flatMap { key -> [String] in
            guard let nested = dictionary[key] else { return [] }
            return collectTranscriptionTexts(from: nested, allowBareString: true)
        }
        if !preferred.isEmpty || preferredKeys.contains(where: { dictionary[$0] != nil }) {
            return preferred
        }

        return []
    }

    static func directTranscriptionText(in dictionary: [String: Any]) -> String? {
        for key in ["normalized_text", "normalizedText", "text"] {
            if let text = dictionary[key] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    static func jsonObject(from data: Data, context: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PluginTranscriptionError.apiError(
                "Failed to parse Sber SaluteSpeech \(context): \(error.localizedDescription)"
            )
        }
    }

    static func firstStringValue(in value: Any, keys: [String]) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let string = dictionary[key] as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }

            for nested in dictionary.values {
                if let string = firstStringValue(in: nested, keys: keys) {
                    return string
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let string = firstStringValue(in: item, keys: keys) {
                    return string
                }
            }
        }

        return nil
    }

    struct TokenResponse: Decodable, Sendable {
        let accessToken: String
        let expiresAtMilliseconds: Int64?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresAt = "expires_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decode(String.self, forKey: .accessToken)

            if let intValue = try? container.decode(Int64.self, forKey: .expiresAt) {
                expiresAtMilliseconds = intValue
            } else if let doubleValue = try? container.decode(Double.self, forKey: .expiresAt) {
                expiresAtMilliseconds = Int64(doubleValue)
            } else if let stringValue = try? container.decode(String.self, forKey: .expiresAt),
                      let intValue = Int64(stringValue) {
                expiresAtMilliseconds = intValue
            } else {
                expiresAtMilliseconds = nil
            }
        }
    }

    struct AsyncTaskStatus: Sendable {
        let status: String
        let responseFileId: String?
        let errorMessage: String?

        var normalizedStatus: String {
            status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }

        var isFinished: Bool {
            ["DONE", "SUCCESS", "COMPLETED"].contains(normalizedStatus)
        }

        var isFailed: Bool {
            ["ERROR", "FAILED", "FAIL", "CANCELED", "CANCELLED"].contains(normalizedStatus)
        }
    }

    struct AsyncRecognitionOptions: Encodable {
        let model: String
        let language: String
        let audioEncoding: String
        let sampleRate: Int
        let channelsCount: Int

        enum CodingKeys: String, CodingKey {
            case model
            case language
            case audioEncoding = "audio_encoding"
            case sampleRate = "sample_rate"
            case channelsCount = "channels_count"
        }
    }

    struct AsyncRecognitionRequest: Encodable {
        let options: AsyncRecognitionOptions
        let requestFileId: String

        enum CodingKeys: String, CodingKey {
            case options
            case requestFileId = "request_file_id"
        }
    }
}

private extension SaluteSpeechPlugin {
    func accessToken(authorizationKey: String, scope: String) async throws -> String {
        if let cached = await tokenCache.cachedToken(
            authorizationKey: authorizationKey,
            scope: scope
        ) {
            return cached
        }

        let response = try await requestAccessToken(
            authorizationKey: authorizationKey,
            scope: scope
        )
        await tokenCache.store(
            token: response.accessToken,
            authorizationKey: authorizationKey,
            scope: scope,
            expiresAtMilliseconds: response.expiresAtMilliseconds
        )
        return response.accessToken
    }

    func requestAccessToken(
        authorizationKey: String,
        scope: String
    ) async throws -> TokenResponse {
        let request = try Self.makeTokenRequest(
            authorizationKey: authorizationKey,
            scope: scope
        )
        let (data, response) = try await PluginHTTPClient.data(for: request)
        try Self.validateHTTPResponse(
            data: data,
            response: response,
            mapBadRequestToInvalidKey: true
        )
        return try Self.parseTokenResponse(data)
    }

    func recognizeSync(
        pcmData: Data,
        token: String,
        modelId: String,
        language: String
    ) async throws -> PluginTranscriptionResult {
        let request = try Self.makeSyncRecognitionRequest(
            pcmData: pcmData,
            token: token,
            modelId: modelId,
            language: language
        )
        let (data, response) = try await PluginHTTPClient.data(for: request)
        try Self.validateHTTPResponse(data: data, response: response)
        return try Self.parseTranscriptionResult(data)
    }

    func recognizeAsync(
        pcmData: Data,
        token: String,
        modelId: String,
        language: String,
        duration: TimeInterval
    ) async throws -> PluginTranscriptionResult {
        let uploadRequest = try Self.makeUploadRequest(pcmData: pcmData, token: token)
        let (uploadData, uploadResponse) = try await PluginHTTPClient.data(for: uploadRequest)
        try Self.validateHTTPResponse(data: uploadData, response: uploadResponse)
        let requestFileId = try Self.parseRequestFileId(uploadData)

        let startRequest = try Self.makeStartAsyncRecognitionRequest(
            requestFileId: requestFileId,
            token: token,
            modelId: modelId,
            language: language
        )
        let (startData, startResponse) = try await PluginHTTPClient.data(for: startRequest)
        try Self.validateHTTPResponse(data: startData, response: startResponse)
        let taskId = try Self.parseTaskId(startData)

        let responseFileId = try await waitForAsyncResultFileId(
            taskId: taskId,
            token: token,
            duration: duration
        )
        let downloadRequest = try Self.makeDownloadRequest(
            responseFileId: responseFileId,
            token: token
        )
        let (downloadData, downloadResponse) = try await PluginHTTPClient.data(
            for: downloadRequest,
            resourceTimeout: 600
        )
        try Self.validateHTTPResponse(data: downloadData, response: downloadResponse)
        return try Self.parseTranscriptionResult(downloadData)
    }

    func waitForAsyncResultFileId(
        taskId: String,
        token: String,
        duration: TimeInterval
    ) async throws -> String {
        let maxWait = min(max(duration * 2 + 60, 120), 1_800)
        let deadline = Date().addingTimeInterval(maxWait)

        while Date() < deadline {
            let request = try Self.makeTaskStatusRequest(taskId: taskId, token: token)
            let (data, response) = try await PluginHTTPClient.data(for: request)
            try Self.validateHTTPResponse(data: data, response: response)
            let status = try Self.parseTaskStatus(data)

            if status.isFinished {
                guard let responseFileId = status.responseFileId else {
                    throw PluginTranscriptionError.apiError(
                        "Sber SaluteSpeech task finished without response_file_id."
                    )
                }
                return responseFileId
            }

            if status.isFailed {
                throw PluginTranscriptionError.apiError(
                    status.errorMessage ?? "Sber SaluteSpeech async recognition failed with status \(status.status)."
                )
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw PluginTranscriptionError.apiError("Sber SaluteSpeech async recognition timed out.")
    }
}

private struct SaluteSpeechSettingsView: View {
    let plugin: SaluteSpeechPlugin

    @State private var authorizationKeyInput = ""
    @State private var showAuthorizationKey = false
    @State private var selectedScope = SaluteSpeechPlugin.personalScope
    @State private var selectedModel = ""
    @State private var isValidating = false
    @State private var validationResult: SaluteSpeechPlugin.AuthorizationKeyValidationResult?
    @State private var settingsErrorMessage: String?
    @State private var usageSnapshot = SaluteSpeechUsageSnapshot.empty
    @State private var balanceRemainingInput = ""
    @State private var hasBalanceValidUntil = false
    @State private var balanceValidUntilDate = Date()
    @State private var showBalanceDatePicker = false
    @State private var usageErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Authorization Key")
                    .font(.headline)

                HStack(spacing: 8) {
                    if showAuthorizationKey {
                        TextField("Base64 ClientID:ClientSecret", text: $authorizationKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("Base64 ClientID:ClientSecret", text: $authorizationKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showAuthorizationKey.toggle()
                    } label: {
                        Image(systemName: showAuthorizationKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    if plugin.isConfigured {
                        Button("Remove") {
                            removeAuthorizationKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    } else {
                        Button("Save") {
                            saveAuthorizationKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(authorizationKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating...")
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

            VStack(alignment: .leading, spacing: 8) {
                Text("OAuth Scope")
                    .font(.headline)

                Picker("OAuth Scope", selection: $selectedScope) {
                    Text("Personal").tag(SaluteSpeechPlugin.personalScope)
                    Text("Corporate").tag(SaluteSpeechPlugin.corporateScope)
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedScope) {
                    plugin.setScope(selectedScope)
                    validationResult = nil
                    settingsErrorMessage = nil
                }
            }

            if plugin.isConfigured {
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
                }

                Divider()

                usageSection
            }

            Text("Authorization Key is stored securely in the Keychain. If validation fails with a certificate error, install the SaluteSpeech certificate trusted by macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            if let key = plugin.authorizationKeyForSettings, !key.isEmpty {
                authorizationKeyInput = key
            }
            selectedScope = plugin.scopeForSettings
            selectedModel = plugin.selectedModelId ?? plugin.transcriptionModels.first?.id ?? ""
            refreshUsage()
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Recognition Usage")
                    .font(.headline)

                Spacer()

                Button {
                    refreshUsage()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            VStack(alignment: .leading, spacing: 6) {
                usageMetricRow(
                    title: "Tracked spent",
                    value: Self.formatMinutes(seconds: usageSnapshot.trackedSeconds)
                )

                if let estimatedRemainingSeconds = usageSnapshot.estimatedRemainingSeconds {
                    usageMetricRow(
                        title: "Estimated remaining",
                        value: Self.formatMinutes(seconds: estimatedRemainingSeconds)
                    )
                    usageMetricRow(
                        title: "Spent since balance update",
                        value: Self.formatMinutes(seconds: usageSnapshot.spentSinceBalanceCorrectionSeconds)
                    )
                }

                if let balanceUpdatedAt = usageSnapshot.balanceUpdatedAt {
                    usageMetricRow(
                        title: "Balance updated",
                        value: Self.formatDisplayDate(balanceUpdatedAt)
                    )
                }

                if let balanceValidUntil = usageSnapshot.balanceValidUntil {
                    usageMetricRow(
                        title: "Valid until",
                        value: Self.formatDateInput(balanceValidUntil)
                    )
                }

                if let lastTranscriptionAt = usageSnapshot.lastTranscriptionAt {
                    usageMetricRow(
                        title: "Last recognition",
                        value: Self.formatDisplayDate(lastTranscriptionAt)
                    )
                }
            }

            usageCorrectionControls

            HStack(spacing: 8) {
                Button("Reset tracked usage") {
                    resetRecognitionUsage()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.red)

                Text("Local estimate. Update it from SaluteSpeech Studio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let usageErrorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(usageErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var usageCorrectionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Studio remaining")
                    .foregroundStyle(.secondary)
                    .frame(width: 126, alignment: .leading)

                TextField("Minutes", text: $balanceRemainingInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)

                Text("min")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle("Valid until", isOn: $hasBalanceValidUntil)
                    .toggleStyle(.checkbox)
                    .frame(width: 126, alignment: .leading)

                Button {
                    showBalanceDatePicker = true
                } label: {
                    Label(Self.formatDateInput(balanceValidUntilDate), systemImage: "calendar")
                        .frame(width: 132, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(!hasBalanceValidUntil)
                .opacity(hasBalanceValidUntil ? 1 : 0.55)
                .popover(isPresented: $showBalanceDatePicker, arrowEdge: .bottom) {
                    VStack(alignment: .trailing, spacing: 10) {
                        DatePicker(
                            "",
                            selection: $balanceValidUntilDate,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .labelsHidden()

                        Button("Done") {
                            showBalanceDatePicker = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                }
            }

            HStack(spacing: 8) {
                Button("Save balance") {
                    saveUsageBalanceCorrection()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(balanceRemainingInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if usageSnapshot.balanceRemainingSeconds != nil {
                    Button("Clear balance") {
                        clearUsageBalanceCorrection()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func usageMetricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .rounded))
                .monospacedDigit()
        }
    }

    private func saveAuthorizationKey() {
        let trimmedKey = SaluteSpeechPlugin.normalizedAuthorizationKey(authorizationKeyInput)
        guard !trimmedKey.isEmpty else { return }

        isValidating = true
        validationResult = nil
        settingsErrorMessage = nil

        Task {
            let result = await plugin.validateAuthorizationKey(trimmedKey, scope: selectedScope)
            await MainActor.run {
                isValidating = false
                validationResult = result
                guard result == .valid else { return }

                do {
                    try plugin.setAuthorizationKey(trimmedKey)
                } catch {
                    validationResult = nil
                    settingsErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func removeAuthorizationKey() {
        do {
            try plugin.removeAuthorizationKey()
            authorizationKeyInput = ""
            validationResult = nil
            settingsErrorMessage = nil
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    private func validationFeedback(
        for result: SaluteSpeechPlugin.AuthorizationKeyValidationResult
    ) -> (systemName: String, message: String, color: Color) {
        switch result {
        case .valid:
            return ("checkmark.circle.fill", "Valid Authorization Key", .green)
        case .invalidKey:
            return ("xmark.circle.fill", "Invalid Authorization Key", .red)
        case .transientError:
            return (
                "exclamationmark.triangle.fill",
                "Could not validate Authorization Key. Check the key, scope, certificate, and network connection.",
                .orange
            )
        }
    }

    private func refreshUsage() {
        usageSnapshot = plugin.usageSnapshotForSettings
        balanceRemainingInput = usageSnapshot.balanceRemainingSeconds
            .map { Self.formatEditableMinutes(seconds: $0) }
            ?? ""
        if let balanceValidUntil = usageSnapshot.balanceValidUntil {
            hasBalanceValidUntil = true
            balanceValidUntilDate = balanceValidUntil
        } else {
            hasBalanceValidUntil = false
            balanceValidUntilDate = Date()
        }
        usageErrorMessage = nil
    }

    private func saveUsageBalanceCorrection() {
        usageErrorMessage = nil
        let remainingText = balanceRemainingInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remainingMinutes = Self.parseMinutes(remainingText) else {
            usageErrorMessage = "Enter remaining minutes as a number."
            return
        }

        do {
            try plugin.setUsageBalanceCorrection(
                remainingMinutes: remainingMinutes,
                validUntil: hasBalanceValidUntil
                    ? Calendar.current.startOfDay(for: balanceValidUntilDate)
                    : nil
            )
            refreshUsage()
        } catch {
            usageErrorMessage = error.localizedDescription
        }
    }

    private func clearUsageBalanceCorrection() {
        do {
            try plugin.clearUsageBalanceCorrection()
            refreshUsage()
        } catch {
            usageErrorMessage = error.localizedDescription
        }
    }

    private func resetRecognitionUsage() {
        do {
            try plugin.resetRecognitionUsage()
            refreshUsage()
        } catch {
            usageErrorMessage = error.localizedDescription
        }
    }

    private static func parseMinutes(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value >= 0 else { return nil }
        return value
    }

    private static func formatDateInput(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func formatDisplayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func formatEditableMinutes(seconds: TimeInterval) -> String {
        let minutes = max(0, seconds / 60)
        if minutes.rounded() == minutes {
            return String(format: "%.0f", minutes)
        }
        return String(format: "%.1f", minutes)
    }

    private static func formatMinutes(seconds: TimeInterval) -> String {
        "\(formatEditableMinutes(seconds: seconds)) min"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var normalizedWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
