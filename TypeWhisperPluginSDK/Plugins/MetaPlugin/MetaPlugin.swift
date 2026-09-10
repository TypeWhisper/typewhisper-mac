import Foundation
import os
import SwiftUI
import TypeWhisperPluginSDK

private enum MetaStorageKey {
    static let apiKey = "api-key"
    static let selectedTranscriptionModel = "selectedTranscriptionModel"
    static let selectedLLMModel = "selectedLLMModel"
    static let fetchedTranscriptionModels = "fetchedTranscriptionModels"
    static let fetchedLLMModels = "fetchedLLMModels"
    static let speakerDiarizationEnabled = "speakerDiarizationEnabled"
}

private enum MetaPluginError: LocalizedError {
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            "Invalid URL: \(value)"
        }
    }
}

// Keep this policy plugin-local because the SDK network guard was added after TypeWhisper 1.6.0.
enum MetaNetworkAccessPolicy {
    static func ensureAccessIsAllowed(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws {
        guard !arguments.contains("--store-screenshots") else {
            throw URLError(.notConnectedToInternet)
        }
    }
}

struct MetaFetchedModel: Codable, Sendable, Hashable {
    let id: String
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
    }
}

enum MetaTranscriptionMode: String, Sendable {
    case pushToTalk = "PUSH_TO_TALK"
    case diarization = "DIARIZATION"
}

struct MetaModelCatalog: Sendable, Equatable {
    let transcriptionModels: [MetaFetchedModel]
    let llmModels: [MetaFetchedModel]

    static func categorize(_ models: [MetaFetchedModel]) -> MetaModelCatalog {
        MetaModelCatalog(
            transcriptionModels: models
                .filter { $0.id.hasPrefix("muse-voice-transcribe-") }
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedDescending },
            llmModels: models
                .filter { $0.id.hasPrefix("muse-spark-") }
                .sorted { lhs, rhs in
                    let lhsContributor = lhs.id.hasSuffix("-contributor")
                    let rhsContributor = rhs.id.hasSuffix("-contributor")
                    if lhsContributor != rhsContributor { return !lhsContributor }
                    return lhs.id.localizedStandardCompare(rhs.id) == .orderedDescending
                }
        )
    }
}

struct MetaResponsesClient: Sendable {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func process(systemPrompt: String, userText: String, model: String) async throws -> String {
        let endpoint = "https://api.meta.ai/v1/responses"
        guard let url = URL(string: endpoint) else {
            throw MetaPluginError.invalidURL(endpoint)
        }

        let instructions = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = [
            "model": model,
            "input": userText,
            "store": false,
        ]
        if !instructions.isEmpty {
            body["instructions"] = instructions
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await PluginHTTPClient.data(for: request, resourceTimeout: 120)
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
            if !trimmed.isEmpty { return trimmed }
        }

        if let output = json["output"] as? [[String: Any]] {
            let text = output.flatMap { item -> [String] in
                guard let content = item["content"] as? [[String: Any]] else { return [] }
                return content.compactMap { part in
                    let type = part["type"] as? String
                    guard type == nil || type == "output_text" || type == "text" else { return nil }
                    return part["text"] as? String
                }
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty { return text }
        }

        throw PluginChatError.apiError("Failed to parse response text")
    }

    static func errorMessage(from data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            return message
        }
        return "HTTP \(statusCode)"
    }
}

struct MetaTranscriptionClient: Sendable {
    private struct RequestBody: Encodable {
        let model: String
        let audioEncoding = "WAV"
        let mode: String
        let languageBias: [String]?
        let keywords: [String]?
    }

    private struct ResponseBody: Decodable {
        struct Turn: Decodable {
            let startMs: Int64
            let endMs: Int64
            let transcript: String
            let speaker: String?
        }

        let transcript: String
        let turns: [Turn]
    }

    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(
        audio: AudioData,
        model: String,
        mode: MetaTranscriptionMode,
        languageHints: [String],
        keywords: [String]
    ) async throws -> PluginStructuredTranscriptionResult {
        let endpoint = "https://api.meta.ai/v1/asr/transcribe"
        guard let url = URL(string: endpoint) else {
            throw MetaPluginError.invalidURL(endpoint)
        }

        let upload = PluginAudioUploadEncoder.wavUpload(
            from: PluginAudioUploadEncoder.normalizedAudioForUpload(audio)
        )
        let requestJSON = try JSONEncoder().encode(RequestBody(
            model: model,
            mode: mode.rawValue,
            languageBias: languageHints.isEmpty ? nil : languageHints,
            keywords: keywords.isEmpty ? nil : keywords
        ))
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            requestJSON: requestJSON,
            upload: upload
        )

        let (data, response) = try await PluginHTTPClient.data(for: request, resourceTimeout: 120)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseResponse(data)
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        case 429:
            throw PluginTranscriptionError.rateLimited
        default:
            throw PluginTranscriptionError.apiError(
                MetaResponsesClient.errorMessage(from: data, statusCode: httpResponse.statusCode)
            )
        }
    }

    static func parseResponse(_ data: Data) throws -> PluginStructuredTranscriptionResult {
        do {
            let response = try JSONDecoder().decode(ResponseBody.self, from: data)
            let segments = response.turns.map {
                PluginStructuredTranscriptionSegment(
                    text: $0.transcript,
                    start: Double($0.startMs) / 1_000,
                    end: Double($0.endMs) / 1_000,
                    speakerLabel: Self.normalizedSpeakerLabel($0.speaker)
                )
            }
            let text = segments.contains { $0.speakerLabel != nil }
                ? segments.map { segment in
                    if let speaker = segment.speakerLabel { return "\(speaker): \(segment.text)" }
                    return segment.text
                }.joined(separator: "\n")
                : response.transcript
            return PluginStructuredTranscriptionResult(text: text, segments: segments)
        } catch {
            throw PluginTranscriptionError.apiError("Failed to parse response: \(error.localizedDescription)")
        }
    }

    static func normalizedSpeakerLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.localizedCaseInsensitiveContains("speaker") { return trimmed }
        return "Speaker \(trimmed)"
    }

    private static func multipartBody(
        boundary: String,
        requestJSON: Data,
        upload: PluginAudioUploadFile
    ) -> Data {
        var body = Data()
        body.metaAppend("--\(boundary)\r\n")
        body.metaAppend("Content-Disposition: form-data; name=\"request\"\r\n")
        body.metaAppend("Content-Type: application/json\r\n\r\n")
        body.append(requestJSON)
        body.metaAppend("\r\n")
        body.metaAppend("--\(boundary)\r\n")
        body.metaAppend("Content-Disposition: form-data; name=\"audio\"; filename=\"\(upload.filename)\"\r\n")
        body.metaAppend("Content-Type: \(upload.contentType)\r\n\r\n")
        body.append(upload.data)
        body.metaAppend("\r\n--\(boundary)--\r\n")
        return body
    }
}

// MARK: - Realtime transcription

actor MetaRealtimeTranscriptCollector {
    private struct Turn: Sendable {
        let id: Int
        var startMs: Int64?
        var endMs: Int64?
        var transcript = ""
        var speaker: String?
    }

    private let mode: MetaTranscriptionMode
    private var turns: [Int: Turn] = [:]
    private var activeTurnID: Int?
    private var interim = ""
    private var finalSingleTurnText = ""
    private var finishRequested = false
    private var receivedFinalEventAfterFinish = false
    private(set) var error: String?

    init(mode: MetaTranscriptionMode) {
        self.mode = mode
    }

    func applyEvent(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "error":
            error = json["message"] as? String ?? "Meta realtime transcription failed."
            return nil
        case "speechStart":
            guard let turnID = Self.int(json["turnId"]) else { return nil }
            var turn = turns[turnID] ?? Turn(id: turnID)
            turn.startMs = Self.int64(json["audioProcessedMs"])
            turns[turnID] = turn
            activeTurnID = turnID
            interim = ""
        case "speaker":
            guard let activeTurnID else { return nil }
            var turn = turns[activeTurnID] ?? Turn(id: activeTurnID)
            turn.speaker = json["label"] as? String
            turns[activeTurnID] = turn
        case "speechEnd":
            guard let turnID = Self.int(json["turnId"]) else { return nil }
            var turn = turns[turnID] ?? Turn(id: turnID)
            turn.endMs = Self.int64(json["audioProcessedMs"])
            turns[turnID] = turn
        case "speechComplete":
            guard let turnID = Self.int(json["turnId"]) else { return nil }
            var turn = turns[turnID] ?? Turn(id: turnID)
            turn.transcript = (json["transcript"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            turn.endMs = turn.endMs ?? Self.int64(json["audioProcessedMs"])
            turns[turnID] = turn
            if activeTurnID == turnID {
                activeTurnID = nil
                interim = ""
            }
            if finishRequested {
                receivedFinalEventAfterFinish = true
            }
        case "transcript":
            let transcript = (json["transcript"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if json["final"] as? Bool == true, mode == .pushToTalk {
                finalSingleTurnText = transcript
                interim = ""
                if finishRequested {
                    receivedFinalEventAfterFinish = true
                }
            } else {
                interim = transcript
            }
        default:
            return nil
        }

        let snapshot = progressSnapshot()
        return snapshot.isEmpty ? nil : snapshot
    }

    func recordConnectionFailure(_ message: String) {
        guard error == nil else { return }
        error = message
    }

    func prepareForFinish() {
        finishRequested = true
    }

    var hasFinalizedAfterFinish: Bool {
        receivedFinalEventAfterFinish
    }

    func finalResult(fallbackLanguage: String?) -> PluginTranscriptionResult {
        let completedTurns = turns.values
            .filter { !$0.transcript.isEmpty }
            .sorted { $0.id < $1.id }

        if !completedTurns.isEmpty {
            let segments = completedTurns.map { turn in
                let speaker = MetaTranscriptionClient.normalizedSpeakerLabel(turn.speaker)
                let text: String
                if mode == .diarization, let speaker {
                    text = "\(speaker): \(turn.transcript)"
                } else {
                    text = turn.transcript
                }
                return PluginTranscriptionSegment(
                    text: text,
                    start: Double(turn.startMs ?? 0) / 1_000,
                    end: Double(turn.endMs ?? turn.startMs ?? 0) / 1_000
                )
            }
            let text = segments.map(\.text).joined(separator: mode == .diarization ? "\n" : " ")
            return PluginTranscriptionResult(
                text: text,
                detectedLanguage: fallbackLanguage,
                segments: segments
            )
        }

        let text = finalSingleTurnText.isEmpty ? interim : finalSingleTurnText
        return PluginTranscriptionResult(text: text, detectedLanguage: fallbackLanguage)
    }

    private func progressSnapshot() -> String {
        let completed = turns.values
            .filter { !$0.transcript.isEmpty }
            .sorted { $0.id < $1.id }
            .map { turn in
                guard mode == .diarization,
                      let speaker = MetaTranscriptionClient.normalizedSpeakerLabel(turn.speaker) else {
                    return turn.transcript
                }
                return "\(speaker): \(turn.transcript)"
            }

        if mode == .pushToTalk {
            return finalSingleTurnText.isEmpty ? interim : finalSingleTurnText
        }

        var parts = completed
        if !interim.isEmpty {
            if let activeTurnID,
               let speaker = MetaTranscriptionClient.normalizedSpeakerLabel(turns[activeTurnID]?.speaker) {
                parts.append("\(speaker): \(interim)")
            } else {
                parts.append(interim)
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}

final class MetaLiveTranscriptionSession: LiveTranscriptionSession, @unchecked Sendable {
    static let handshakeTimeoutNanoseconds: UInt64 = 10_000_000_000
    static let finishTimeoutNanoseconds: UInt64 = 15_000_000_000

    private struct State {
        var finished = false
        var cancelled = false
    }

    private enum ReceiveWaitResult: Sendable {
        case socketEnded
        case finalEventReceived
        case timedOut
    }

    private let webSocketTask: URLSessionWebSocketTask
    private let receiveTask: Task<Void, Never>
    private let collector: MetaRealtimeTranscriptCollector
    private let fallbackLanguage: String?
    private let state: OSAllocatedUnfairLock<State>

    private init(
        webSocketTask: URLSessionWebSocketTask,
        receiveTask: Task<Void, Never>,
        collector: MetaRealtimeTranscriptCollector,
        fallbackLanguage: String?,
        state: OSAllocatedUnfairLock<State>
    ) {
        self.webSocketTask = webSocketTask
        self.receiveTask = receiveTask
        self.collector = collector
        self.fallbackLanguage = fallbackLanguage
        self.state = state
    }

    static func connect(
        apiKey: String,
        model: String,
        mode: MetaTranscriptionMode,
        languageHints: [String],
        keywords: [String],
        fallbackLanguage: String?,
        onProgress: @Sendable @escaping (String) -> Bool,
        webSocketURLOverride: URL? = nil
    ) async throws -> MetaLiveTranscriptionSession {
        try MetaNetworkAccessPolicy.ensureAccessIsAllowed()
        guard let url = webSocketURLOverride ?? URL(string: "wss://api.meta.ai/v1/asr/realtime") else {
            throw PluginTranscriptionError.apiError("Invalid Meta realtime WebSocket URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let webSocketTask = URLSession.shared.webSocketTask(with: request)
        let collector = MetaRealtimeTranscriptCollector(mode: mode)
        let state = OSAllocatedUnfairLock(initialState: State())
        webSocketTask.resume()

        do {
            try await webSocketTask.send(.string(try handshakeMessage(
                apiKey: apiKey,
                model: model,
                mode: mode,
                languageHints: languageHints,
                keywords: keywords
            )))
            let handshake = try await receiveHandshake(from: webSocketTask)
            try validateHandshake(handshake)
        } catch {
            webSocketTask.cancel(with: .goingAway, reason: nil)
            throw error
        }

        let receiveTask = Task { [webSocketTask, collector, onProgress, state] in
            do {
                while !Task.isCancelled {
                    let message = try await webSocketTask.receive()
                    guard let data = data(from: message) else { continue }
                    if let snapshot = await collector.applyEvent(data), !snapshot.isEmpty {
                        _ = onProgress(snapshot)
                    }
                    if await collector.error != nil { break }
                }
            } catch is CancellationError {
                return
            } catch {
                let finishRequested = state.withLock { $0.finished && !$0.cancelled }
                if Task.isCancelled || Self.isExpectedReceiveTermination(
                    error,
                    finishRequested: finishRequested,
                    closeCode: webSocketTask.closeCode
                ) {
                    return
                }
                await collector.recordConnectionFailure(error.localizedDescription)
            }
        }

        return MetaLiveTranscriptionSession(
            webSocketTask: webSocketTask,
            receiveTask: receiveTask,
            collector: collector,
            fallbackLanguage: fallbackLanguage,
            state: state
        )
    }

    func appendAudio(samples: [Float]) async throws {
        guard !state.withLock({ $0.finished || $0.cancelled }) else { return }
        if let error = await collector.error {
            throw PluginTranscriptionError.apiError(error)
        }
        let data = Self.pcm16Data(from: samples)
        guard !data.isEmpty else { return }
        do {
            try await webSocketTask.send(.data(data))
        } catch {
            if let serverError = await collector.error {
                throw PluginTranscriptionError.apiError(serverError)
            }
            throw PluginTranscriptionError.networkError(error.localizedDescription)
        }
    }

    func finish() async throws -> PluginTranscriptionResult {
        let shouldFinish = state.withLock { state in
            guard !state.finished else { return false }
            state.finished = true
            return !state.cancelled
        }

        if shouldFinish {
            await collector.prepareForFinish()
            do {
                try await webSocketTask.send(.string(#"{"type":"endStream"}"#))
            } catch {
                if let serverError = await collector.error {
                    throw PluginTranscriptionError.apiError(serverError)
                }
                throw PluginTranscriptionError.networkError(error.localizedDescription)
            }
            await waitForReceiveTask()
        }

        receiveTask.cancel()
        webSocketTask.cancel(with: .normalClosure, reason: nil)

        if let error = await collector.error {
            throw PluginTranscriptionError.apiError(error)
        }
        let result = await collector.finalResult(fallbackLanguage: fallbackLanguage)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginTranscriptionError.apiError("Meta realtime API returned no transcript.")
        }
        return result
    }

    func cancel() async {
        let shouldCancel = state.withLock { state in
            guard !state.cancelled else { return false }
            state.cancelled = true
            return true
        }
        guard shouldCancel else { return }
        receiveTask.cancel()
        webSocketTask.cancel(with: .goingAway, reason: nil)
    }

    static func handshakeMessage(
        apiKey: String,
        model: String,
        mode: MetaTranscriptionMode,
        languageHints: [String],
        keywords: [String]
    ) throws -> String {
        var payload: [String: Any] = [
            "authorization": ["accessToken": "Bearer \(apiKey)"],
            "audioEncoding": "PCM_16KHZ",
            "model": model,
            "mode": mode.rawValue,
            "partialMode": "CUMULATIVE",
            "emitAudioProgress": false,
        ]
        if !languageHints.isEmpty { payload["languageBias"] = languageHints }
        if !keywords.isEmpty { payload["keywords"] = keywords }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw PluginTranscriptionError.apiError("Failed to encode Meta realtime handshake.")
        }
        return string
    }

    static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32_767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func isExpectedReceiveTermination(
        _ error: Error,
        finishRequested: Bool,
        closeCode: URLSessionWebSocketTask.CloseCode
    ) -> Bool {
        if closeCode == .normalClosure {
            return true
        }
        guard finishRequested else { return false }
        return containsGracefulTLSClosure(error)
    }

    private static func containsGracefulTLSClosure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain, nsError.code == -9805 {
            return true
        }
        guard let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return containsGracefulTLSClosure(underlyingError)
    }

    private static func receiveHandshake(from task: URLSessionWebSocketTask) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                guard let data = data(from: try await task.receive()) else {
                    throw PluginTranscriptionError.apiError("Invalid Meta realtime handshake response.")
                }
                return data
            }
            group.addTask {
                try await Task.sleep(nanoseconds: handshakeTimeoutNanoseconds)
                task.cancel(with: .goingAway, reason: nil)
                throw PluginTranscriptionError.networkError("Meta realtime handshake timed out.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func validateHandshake(_ data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginTranscriptionError.apiError("Invalid Meta realtime handshake response.")
        }
        if json["type"] as? String == "error" {
            throw PluginTranscriptionError.apiError(json["message"] as? String ?? "Meta realtime handshake failed.")
        }
        guard let sessionID = json["sessionId"] as? String, !sessionID.isEmpty else {
            throw PluginTranscriptionError.apiError("Meta realtime handshake did not return a session ID.")
        }
    }

    private func waitForReceiveTask() async {
        await withTaskGroup(of: ReceiveWaitResult.self) { group in
            group.addTask { [receiveTask] in
                await receiveTask.value
                return .socketEnded
            }
            group.addTask { [collector] in
                while !Task.isCancelled {
                    if await collector.hasFinalizedAfterFinish {
                        return .finalEventReceived
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return .timedOut
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.finishTimeoutNanoseconds)
                return .timedOut
            }
            let result = await group.next() ?? .timedOut
            if result != .socketEnded {
                receiveTask.cancel()
                webSocketTask.cancel(with: .normalClosure, reason: nil)
            }
            group.cancelAll()
        }
    }

    private static func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .string(let text): text.data(using: .utf8)
        case .data(let data): data
        @unknown default: nil
        }
    }
}

@objc(MetaPlugin)
final class MetaPlugin: NSObject,
    StructuredLanguageHintDictionaryTermHintTranscriptionEnginePlugin,
    LiveLanguageHintDictionaryTermHintTranscriptionCapablePlugin,
    LiveTranscriptionProgressModeProviding,
    TranscriptionModelCatalogProviding,
    DictionaryTermsCapabilityProviding,
    LLMProviderPlugin,
    LLMProviderIdentityProviding,
    LLMProviderSetupStatusProviding,
    LLMModelSelectable,
    PluginAuthRoleStatusProviding,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.meta"
    static let pluginName = "Meta"
    static let defaultTranscriptionModelId = "muse-voice-transcribe-1.0"
    static let defaultLLMModelId = "muse-spark-1.2"

    fileprivate var host: HostServices?
    fileprivate var apiKey: String?
    fileprivate var selectedTranscriptionModelId: String?
    fileprivate var selectedLLMModelId: String?
    fileprivate var fetchedTranscriptionModels: [MetaFetchedModel] = []
    fileprivate var fetchedLLMModels: [MetaFetchedModel] = []
    fileprivate var speakerDiarizationEnabled = false

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        apiKey = host.loadSecret(key: MetaStorageKey.apiKey)
        selectedTranscriptionModelId = host.userDefault(forKey: MetaStorageKey.selectedTranscriptionModel) as? String
            ?? Self.defaultTranscriptionModelId
        selectedLLMModelId = host.userDefault(forKey: MetaStorageKey.selectedLLMModel) as? String
            ?? Self.defaultLLMModelId
        fetchedTranscriptionModels = Self.loadModels(from: host, key: MetaStorageKey.fetchedTranscriptionModels)
        fetchedLLMModels = Self.loadModels(from: host, key: MetaStorageKey.fetchedLLMModels)
        speakerDiarizationEnabled = host.userDefault(forKey: MetaStorageKey.speakerDiarizationEnabled) as? Bool ?? false
        normalizeSelections()
    }

    func deactivate() {
        host = nil
    }

    // MARK: Transcription

    var providerId: String { "meta" }
    var providerDisplayName: String { "Meta" }
    var isConfigured: Bool { normalizedAPIKey != nil }

    var transcriptionModels: [PluginModelInfo] {
        modelInfo(from: fetchedTranscriptionModels, fallback: [
            PluginModelInfo(id: Self.defaultTranscriptionModelId, displayName: "Muse Voice Transcribe 1.0"),
        ])
    }

    var availableModels: [PluginModelInfo] { transcriptionModels }
    var selectedModelId: String? { selectedTranscriptionModelId }

    func selectModel(_ modelId: String) {
        selectedTranscriptionModelId = modelId
        host?.setUserDefault(modelId, forKey: MetaStorageKey.selectedTranscriptionModel)
        host?.notifyCapabilitiesChanged()
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }
    var liveTranscriptionProgressMode: LiveTranscriptionProgressMode { .completeSnapshot }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }
    var supportedLanguages: [String] { Array(Self.languageNames.keys).sorted() }

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
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }
        guard !translate else {
            throw PluginTranscriptionError.apiError("Meta Voice Transcribe does not support translation.")
        }

        let model = selectedTranscriptionModelId ?? Self.defaultTranscriptionModelId
        let languageHints = Self.languageBias(from: languageSelection)
        let promptHints = PluginDictionaryTerms.termHints(fromPrompt: prompt)
        let keywords = PluginDictionaryTerms.normalizedTermHints(from: dictionaryTermHints + promptHints)
            .map(\.text)

        return try await MetaTranscriptionClient(apiKey: apiKey).transcribe(
            audio: audio,
            model: model,
            mode: transcriptionMode,
            languageHints: languageHints,
            keywords: keywords
        )
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

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: PluginLanguageSelection(requestedLanguage: language),
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: [],
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        try await createLiveTranscriptionSession(
            languageSelection: languageSelection,
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
        try await createLiveTranscriptionSession(
            languageSelection: PluginLanguageSelection(requestedLanguage: language),
            translate: translate,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        guard let apiKey = normalizedAPIKey else {
            throw PluginTranscriptionError.notConfigured
        }
        guard !translate else {
            throw PluginTranscriptionError.apiError("Meta Voice Transcribe does not support translation.")
        }

        let promptHints = PluginDictionaryTerms.termHints(fromPrompt: prompt)
        let keywords = PluginDictionaryTerms.normalizedTermHints(from: dictionaryTermHints + promptHints)
            .map(\.text)
        return try await MetaLiveTranscriptionSession.connect(
            apiKey: apiKey,
            model: selectedTranscriptionModelId ?? Self.defaultTranscriptionModelId,
            mode: transcriptionMode,
            languageHints: Self.languageBias(from: languageSelection),
            keywords: keywords,
            fallbackLanguage: languageSelection.requestedLanguage,
            onProgress: onProgress
        )
    }

    // MARK: LLM

    var providerName: String { "Meta" }
    var isAvailable: Bool { isConfigured }
    var providerLegacyAliases: [String] { ["Meta Model API"] }

    var supportedModels: [PluginModelInfo] {
        modelInfo(from: fetchedLLMModels, fallback: [
            PluginModelInfo(id: "muse-spark-1.2", displayName: "Muse Spark 1.2"),
            PluginModelInfo(id: "muse-spark-1.1", displayName: "Muse Spark 1.1"),
            PluginModelInfo(id: "muse-spark-1.2-contributor", displayName: "Muse Spark 1.2 Contributor"),
        ])
    }

    var preferredModelId: String? { selectedLLMModelId }
    var defaultModelId: String? { Self.defaultLLMModelId }
    var requiresExternalCredentials: Bool { true }
    var unavailableReason: String? { isConfigured ? nil : "Meta prompt processing requires a Model API key." }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        guard let apiKey = normalizedAPIKey else {
            throw PluginChatError.notConfigured
        }
        let modelId = model ?? selectedLLMModelId ?? Self.defaultLLMModelId
        return try await MetaResponsesClient(apiKey: apiKey).process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: modelId
        )
    }

    func selectLLMModel(_ modelId: String) {
        selectedLLMModelId = modelId
        host?.setUserDefault(modelId, forKey: MetaStorageKey.selectedLLMModel)
        host?.notifyCapabilitiesChanged()
    }

    // MARK: Authentication and catalog

    func authStatus(for role: PluginAuthRole) -> PluginAuthRoleStatus {
        switch role {
        case .transcription, .llm:
            return isConfigured
                ? .available
                : .unavailable(
                    reason: "Meta Model API requires an API key.",
                    requiredCredentialLabel: "Meta Model API key"
                )
        case .tts:
            return .unavailable(reason: "Meta does not expose text-to-speech through this plugin.")
        }
    }

    var settingsView: AnyView? {
        AnyView(MetaSettingsView(plugin: self))
    }

    func setAPIKey(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = normalized.isEmpty ? nil : normalized
        if let host {
            try? host.storeSecret(key: MetaStorageKey.apiKey, value: normalized)
            host.notifyCapabilitiesChanged()
        }
    }

    var isSpeakerDiarizationEnabled: Bool { speakerDiarizationEnabled }

    func setSpeakerDiarizationEnabled(_ enabled: Bool) {
        guard speakerDiarizationEnabled != enabled else { return }
        speakerDiarizationEnabled = enabled
        host?.setUserDefault(enabled, forKey: MetaStorageKey.speakerDiarizationEnabled)
        host?.notifyCapabilitiesChanged()
    }

    @discardableResult
    func refreshModelCatalog() async -> MetaModelCatalog? {
        guard let apiKey = normalizedAPIKey,
              let url = URL(string: "https://api.meta.ai/v1/models") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            struct ModelsResponse: Decodable { let data: [MetaFetchedModel] }
            let catalog = MetaModelCatalog.categorize(try JSONDecoder().decode(ModelsResponse.self, from: data).data)
            guard !catalog.transcriptionModels.isEmpty || !catalog.llmModels.isEmpty else { return nil }
            setFetchedCatalog(catalog)
            return catalog
        } catch {
            return nil
        }
    }

    private var normalizedAPIKey: String? {
        guard let value = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private var transcriptionMode: MetaTranscriptionMode {
        speakerDiarizationEnabled ? .diarization : .pushToTalk
    }

    private func setFetchedCatalog(_ catalog: MetaModelCatalog) {
        if !catalog.transcriptionModels.isEmpty {
            fetchedTranscriptionModels = catalog.transcriptionModels
            persist(catalog.transcriptionModels, key: MetaStorageKey.fetchedTranscriptionModels)
        }
        if !catalog.llmModels.isEmpty {
            fetchedLLMModels = catalog.llmModels
            persist(catalog.llmModels, key: MetaStorageKey.fetchedLLMModels)
        }
        normalizeSelections()
        host?.notifyCapabilitiesChanged()
    }

    private func persist(_ models: [MetaFetchedModel], key: String) {
        if let data = try? JSONEncoder().encode(models) {
            host?.setUserDefault(data, forKey: key)
        }
    }

    private static func loadModels(from host: HostServices, key: String) -> [MetaFetchedModel] {
        guard let data = host.userDefault(forKey: key) as? Data else { return [] }
        return (try? JSONDecoder().decode([MetaFetchedModel].self, from: data)) ?? []
    }

    private func normalizeSelections() {
        let transcriptionIDs = Set(transcriptionModels.map(\.id))
        if let selectedTranscriptionModelId, !transcriptionIDs.contains(selectedTranscriptionModelId) {
            self.selectedTranscriptionModelId = transcriptionModels.first?.id
        }
        let llmIDs = Set(supportedModels.map(\.id))
        if let selectedLLMModelId, !llmIDs.contains(selectedLLMModelId) {
            self.selectedLLMModelId = supportedModels.first?.id
        }
    }

    private func modelInfo(from models: [MetaFetchedModel], fallback: [PluginModelInfo]) -> [PluginModelInfo] {
        guard !models.isEmpty else { return fallback }
        return models.map { PluginModelInfo(id: $0.id, displayName: Self.displayName(for: $0.id)) }
    }

    static func displayName(for modelID: String) -> String {
        switch modelID {
        case "muse-voice-transcribe-1.0": "Muse Voice Transcribe 1.0"
        case "muse-spark-1.2": "Muse Spark 1.2"
        case "muse-spark-1.1": "Muse Spark 1.1"
        case "muse-spark-1.2-contributor": "Muse Spark 1.2 Contributor"
        default: modelID
        }
    }

    static func languageBias(from selection: PluginLanguageSelection) -> [String] {
        let codes = [selection.requestedLanguage] + selection.languageHints.map(Optional.some)
        var seen = Set<String>()
        return codes.compactMap { code -> String? in
            guard let code else { return nil }
            let normalized = code.lowercased().split(separator: "-").first.map(String.init) ?? code.lowercased()
            guard let name = languageNames[normalized], seen.insert(name).inserted else { return nil }
            return name
        }
    }

    private static let languageNames: [String: String] = [
        "ar": "Arabic", "bn": "Bengali", "nl": "Dutch", "en": "English", "fr": "French",
        "de": "German", "he": "Hebrew", "hi": "Hindi", "id": "Indonesian", "it": "Italian",
        "ja": "Japanese", "kn": "Kannada", "ko": "Korean", "ms": "Malay", "zh": "Mandarin Chinese",
        "mr": "Marathi", "pl": "Polish", "pt": "Portuguese", "es": "Spanish", "tl": "Tagalog",
        "ta": "Tamil", "te": "Telugu", "th": "Thai", "tr": "Turkish", "vi": "Vietnamese",
    ]
}

private extension Data {
    mutating func metaAppend(_ string: String) {
        append(Data(string.utf8))
    }
}

private struct MetaSettingsView: View {
    let plugin: MetaPlugin
    private let bundle = metaPluginBundle

    @State private var apiKeyInput = ""
    @State private var showAPIKey = false
    @State private var selectedTranscriptionModel = ""
    @State private var selectedLLMModel = ""
    @State private var speakerDiarizationEnabled = false
    @State private var isRefreshing = false
    @State private var connectionResult: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Meta Model API", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 8) {
                    Group {
                        if showAPIKey {
                            TextField(String(localized: "API Key", bundle: bundle), text: $apiKeyInput)
                        } else {
                            SecureField(String(localized: "API Key", bundle: bundle), text: $apiKeyInput)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text("The API key is stored securely in the macOS Keychain.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        saveAndRefresh()
                    } label: {
                        Text("Save and Refresh Models", bundle: bundle)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRefreshing)

                    if plugin.isConfigured {
                        Button {
                            plugin.setAPIKey("")
                            apiKeyInput = ""
                            connectionResult = nil
                        } label: {
                            Text("Remove", bundle: bundle)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRefreshing)
                    }

                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else if let connectionResult {
                        Label(
                            connectionResult
                                ? String(localized: "Connected", bundle: bundle)
                                : String(localized: "Connection Failed", bundle: bundle),
                            systemImage: connectionResult ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(connectionResult ? .green : .red)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Transcription Model", bundle: bundle)
                    .font(.headline)
                Picker(String(localized: "Transcription Model", bundle: bundle), selection: $selectedTranscriptionModel) {
                    ForEach(plugin.transcriptionModels, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .labelsHidden()
                .onChange(of: selectedTranscriptionModel) {
                    plugin.selectModel(selectedTranscriptionModel)
                }

                Toggle(String(localized: "Speaker diarization", bundle: bundle), isOn: $speakerDiarizationEnabled)
                    .onChange(of: speakerDiarizationEnabled) {
                        plugin.setSpeakerDiarizationEnabled(speakerDiarizationEnabled)
                    }

                Text("Realtime transcription streams 16 kHz PCM over Meta's WebSocket API. Speaker diarization applies to both realtime and uploaded audio.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt Model", bundle: bundle)
                    .font(.headline)
                Picker(String(localized: "Prompt Model", bundle: bundle), selection: $selectedLLMModel) {
                    ForEach(plugin.supportedModels, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .labelsHidden()
                .onChange(of: selectedLLMModel) {
                    plugin.selectLLMModel(selectedLLMModel)
                }

                if selectedLLMModel.hasSuffix("-contributor") {
                    Text("Contributor models may use prompts and completions to train future Meta models.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Text("Models are loaded dynamically from Meta and cached for offline settings access.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            apiKeyInput = plugin.apiKey ?? ""
            selectedTranscriptionModel = plugin.selectedModelId ?? MetaPlugin.defaultTranscriptionModelId
            selectedLLMModel = plugin.preferredModelId ?? MetaPlugin.defaultLLMModelId
            speakerDiarizationEnabled = plugin.isSpeakerDiarizationEnabled
        }
    }

    private func saveAndRefresh() {
        plugin.setAPIKey(apiKeyInput)
        isRefreshing = true
        connectionResult = nil
        Task {
            let catalog = await plugin.refreshModelCatalog()
            await MainActor.run {
                isRefreshing = false
                connectionResult = catalog != nil
                selectedTranscriptionModel = plugin.selectedModelId ?? MetaPlugin.defaultTranscriptionModelId
                selectedLLMModel = plugin.preferredModelId ?? MetaPlugin.defaultLLMModelId
            }
        }
    }
}

private let metaPluginBundle: Bundle = {
#if SWIFT_PACKAGE
    Bundle.module
#else
    Bundle(for: MetaPlugin.self)
#endif
}()
