import XCTest
import os
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import ZoomPlugin

final class ZoomPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    // MARK: - Models And Requests

    func testModelsDecideLanguagesAndDictionarySupport() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "zoom-key"])
        let plugin = ZoomPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.transcriptionModels.map(\.id), [
            "zoom-scribe-multilingual", "zoom-scribe-language", "zoom-scribe-en-pro",
        ])
        XCTAssertNil(plugin.selectedModelId)
        XCTAssertEqual(plugin.supportedLanguages.count, 10)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .unsupported)

        plugin.selectModel("zoom-scribe-language")
        XCTAssertEqual(plugin.selectedModelId, "zoom-scribe-language")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "zoom-scribe-language")
        XCTAssertFalse(plugin.supportedLanguages.contains("ko"))
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)

        plugin.selectModel("zoom-scribe-en-pro")
        XCTAssertEqual(plugin.supportedLanguages, ["en"])
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)

        plugin.selectModel("unknown")
        XCTAssertNil(plugin.selectedModelId)
    }

    func testRequestsPickTheModelAndLocaleForTheLanguage() {
        let terms = ["TypeWhisper"]
        XCTAssertEqual(
            ZoomAPIClient.Request.make(model: ZoomPlugin.languageModel, language: "de", vocabulary: terms),
            .init(model: "zoom-scribe-de", locale: "de-DE", vocabulary: terms)
        )
        XCTAssertEqual(
            ZoomAPIClient.Request.make(model: ZoomPlugin.languageModel, language: "pt-PT", vocabulary: terms),
            .init(model: "zoom-scribe-pt", locale: "pt-BR", vocabulary: terms)
        )
        // Korean has no language model; the multilingual model takes it without terms.
        XCTAssertEqual(
            ZoomAPIClient.Request.make(model: ZoomPlugin.languageModel, language: "ko", vocabulary: terms),
            .init(model: "zoom-scribe-multilingual", locale: "ko-KR", vocabulary: [])
        )
        XCTAssertEqual(
            ZoomAPIClient.Request.make(model: ZoomPlugin.englishProModel, language: "en", vocabulary: terms),
            .init(model: "zoom-scribe-en-pro", locale: "en-US", vocabulary: terms)
        )
        XCTAssertEqual(
            ZoomAPIClient.Request.make(model: ZoomPlugin.englishProModel, language: "fr", vocabulary: terms),
            .init(model: "zoom-scribe-multilingual", locale: "fr-FR", vocabulary: [])
        )
        XCTAssertEqual(
            ZoomAPIClient.Request.make(model: ZoomPlugin.multilingualModel, language: "de", vocabulary: terms),
            .init(model: "zoom-scribe-multilingual", locale: "de-DE", vocabulary: [])
        )
        // No language, or one Scribe does not know: the multilingual model detects it.
        for language in [nil, "nl"] as [String?] {
            let request = ZoomAPIClient.Request.make(model: ZoomPlugin.languageModel, language: language, vocabulary: terms)
            XCTAssertEqual(request, .init(model: "zoom-scribe-multilingual", locale: nil, vocabulary: []))
            XCTAssertNil(request.config["language"])
            XCTAssertEqual((request.config["language_detection"] as? [String: String])?["mode"], "continuous")
        }
    }

    // MARK: - Fast Mode

    func testRecordingsGoToTheFastModeWithTheLanguageModelAndTerms() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "zoom-key"])
        let plugin = ZoomPlugin()
        plugin.activate(host: host)
        plugin.selectModel("zoom-scribe-language")
        let store = Self.store(answers: [
            (200, #"{"request_id":"r1","model":"zoom-scribe-de","result":{"language":"de-DE","text_display":" Saoirse Ronan nutzt TypeWhisper. "}}"#),
        ])

        let result = try await plugin.transcribe(
            audio: Self.audio(),
            language: "de",
            translate: false,
            prompt: "Saoirse Ronan, TypeWhisper, saoirse ronan"
        )

        XCTAssertEqual(result.text, "Saoirse Ronan nutzt TypeWhisper.")
        XCTAssertEqual(result.detectedLanguage, "de")
        let request = store.sessions[0].requestedRequests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.zoom.us/v2/aiservices/scribe/transcribe")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer zoom-key")
        let body = try Self.json(request.httpBody)
        let file = try XCTUnwrap(body["file"] as? String)
        XCTAssertTrue(file.hasPrefix("data:audio/mp4;base64,") || file.hasPrefix("data:audio/wav;base64,"))
        let config = try XCTUnwrap(body["config"] as? [String: Any])
        XCTAssertEqual(config["model"] as? String, "zoom-scribe-de")
        XCTAssertEqual(config["language"] as? String, "de-DE")
        XCTAssertEqual((config["vocabulary"] as? [String: Any])?["phrases"] as? [String], ["Saoirse Ronan", "TypeWhisper"])
    }

    func testDetectedLanguageFallsBackToTheSegments() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "zoom-key"])
        let plugin = ZoomPlugin()
        plugin.activate(host: host)
        let store = Self.store(answers: [
            (200, #"{"result":{"segments":[{"text":"Hallo"},{"text":" Welt."}]}}"#),
        ])

        let result = try await plugin.transcribe(audio: Self.audio(), language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "Hallo Welt.")
        XCTAssertNil(result.detectedLanguage)
        let config = try XCTUnwrap(try Self.json(store.sessions[0].requestedRequests[0].httpBody)["config"] as? [String: Any])
        XCTAssertEqual(config["model"] as? String, "zoom-scribe-multilingual")
        XCTAssertNil(config["vocabulary"])
    }

    func testRejectedRequestsReportZoomsMessage() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "zoom-key"])
        let plugin = ZoomPlugin()
        plugin.activate(host: host)
        _ = Self.store(answers: [
            (401, #"{"code":124,"message":"Invalid Access token"}"#),
            (400, #"{"code":400,"reason":"UNSUPPORTED_MODEL","message":"Unsupported model 'x'."}"#),
        ])

        do {
            _ = try await plugin.transcribe(audio: Self.audio(), language: "en", translate: false, prompt: nil)
            XCTFail("expected an invalid key")
        } catch PluginTranscriptionError.invalidApiKey {}

        do {
            _ = try await plugin.transcribe(audio: Self.audio(), language: "en", translate: false, prompt: nil)
            XCTFail("expected an API error")
        } catch PluginTranscriptionError.apiError(let message) {
            XCTAssertEqual(message, "Unsupported model 'x'.")
        }
    }

    func testKeyCheckTellsAValidKeyFromAnInvalidOne() async throws {
        let plugin = ZoomPlugin()
        let store = Self.store(answers: [
            (400, #"{"code":400,"reason":"UNSUPPORTED_MODEL","message":"Unsupported model"}"#),
            (401, #"{"code":124,"message":"Invalid Access token"}"#),
        ])

        let valid = try await plugin.validateApiKey("good")
        let invalid = try await plugin.validateApiKey("bad")

        XCTAssertTrue(valid)
        XCTAssertFalse(invalid)
        let config = try XCTUnwrap(try Self.json(store.sessions[0].requestedRequests[0].httpBody)["config"] as? [String: Any])
        XCTAssertEqual(config["model"] as? String, "typewhisper-key-check")
    }

    // MARK: - Live Mode

    func testModesDecideAboutLiveSessionsAndPreviews() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "zoom-key"])
        let plugin = ZoomPlugin()
        plugin.activate(host: host)

        XCTAssertTrue(plugin.supportsLiveTranscriptionSession(forModelId: nil))
        XCTAssertTrue(plugin.supportsStreaming)
        XCTAssertTrue(plugin.allowsTranscriptPreviewFallback)

        plugin.setTranscriptionMode(.batch)
        XCTAssertFalse(plugin.supportsLiveTranscriptionSession(forModelId: nil))
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertFalse(plugin.allowsTranscriptPreviewFallback)
        XCTAssertEqual(host.userDefault(forKey: ZoomPlugin.transcriptionModeKey) as? String, "batch")
    }

    func testLiveSessionSendsSettingsThenAudioAndReturnsTheCompletedItems() async throws {
        let socket = FakeZoomLiveSocket(textAnswers: [
            "session.update": [#"{"type":"session.updated","model":"zoom-scribe-en-pro","language":"en-US"}"#],
            "session.close": [
                #"{"type":"transcription.delta","item_id":"b","delta":"Second"}"#,
                #"{"type":"transcription.completed","item_id":"b","transcript":"Second item."}"#,
                #"{"type":"session.closed","reason":"client_requested"}"#,
            ],
        ], audioAnswers: [
            #"{"type":"transcription.delta","item_id":"a","delta":"First"}"#,
            #"{"type":"transcription.completed","item_id":"a","transcript":"First item."}"#,
        ])
        let requests = RequestRecorder()
        let host = try PluginTestHostServices(secrets: ["api-key": "zoom-key"])
        let plugin = ZoomPlugin(liveSocketFactory: { request in
            requests.append(request)
            return socket
        })
        plugin.activate(host: host)
        plugin.selectModel("zoom-scribe-en-pro")
        let progress = LiveProgressRecorder()
        let previewShown = expectation(description: "the preview shows the finished first item")

        let session = try await plugin.createLiveTranscriptionSession(
            language: "en",
            translate: false,
            prompt: "TypeWhisper",
            onProgress: { text in
                progress.append(text)
                if text == "First item." { previewShown.fulfill() }
                return true
            }
        )
        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 4_000))
        await fulfillment(of: [previewShown], timeout: 5)
        let result = try await session.finish()

        XCTAssertEqual(result.text, "First item. Second item.")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(progress.values, ["First", "First item.", "First item. Second", "First item. Second item."])

        let request = try XCTUnwrap(requests.values.first)
        XCTAssertEqual(request.url?.absoluteString, "wss://api.zoom.us/v2/aiservices/scribe/live")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer zoom-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "live-asr")

        let messages = socket.sentMessages
        XCTAssertEqual(messages.map(\.type), ["session.update", "audio", "audio", "audio", "session.close"])
        let update = try XCTUnwrap(messages.first?.json)
        let config = try XCTUnwrap(update["config"] as? [String: Any])
        XCTAssertEqual(config["model"] as? String, "zoom-scribe-en-pro")
        XCTAssertEqual(config["language"] as? String, "en-US")
        XCTAssertEqual(config["interim_results"] as? Bool, true)
        XCTAssertEqual((config["vocabulary"] as? [String: Any])?["phrases"] as? [String], ["TypeWhisper"])
        XCTAssertEqual((update["audio"] as? [String: Any])?["format"] as? String, "pcm16")
        XCTAssertEqual(messages.compactMap(\.audioByteCount), [3_200, 3_200, 1_600])
        XCTAssertTrue(socket.isClosed)
    }

    func testLiveSessionDetectsTheLanguageWithoutOne() async throws {
        let socket = FakeZoomLiveSocket(textAnswers: [
            "session.update": [#"{"type":"session.updated","language":"auto"}"#],
            "session.close": [
                #"{"type":"transcription.completed","item_id":"a","transcript":"Hallo Welt.","language":"de"}"#,
                #"{"type":"session.closed","reason":"client_requested"}"#,
            ],
        ])
        let host = try PluginTestHostServices(secrets: ["api-key": "zoom-key"])
        let plugin = ZoomPlugin(liveSocketFactory: { _ in socket })
        plugin.activate(host: host)

        let session = try await plugin.createLiveTranscriptionSession(
            language: nil, translate: false, prompt: nil, onProgress: { _ in true }
        )
        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 1_600))
        let result = try await session.finish()

        XCTAssertEqual(result.text, "Hallo Welt.")
        XCTAssertEqual(result.detectedLanguage, "de")
        let config = try XCTUnwrap(socket.sentMessages.first?.json?["config"] as? [String: Any])
        XCTAssertEqual(config["model"] as? String, "zoom-scribe-multilingual")
        XCTAssertNil(config["language"])
        XCTAssertEqual((config["language_detection"] as? [String: String])?["mode"], "continuous")
    }

    func testLiveSessionFailsWhenZoomRejectsTheSettings() async throws {
        let socket = FakeZoomLiveSocket(textAnswers: [
            "session.update": [#"{"type":"error","error":{"code":"unsupported_model","message":"Unsupported model","fatal":true}}"#],
        ])
        let host = try PluginTestHostServices(secrets: ["api-key": "zoom-key"])
        let plugin = ZoomPlugin(liveSocketFactory: { _ in socket })
        plugin.activate(host: host)

        do {
            _ = try await plugin.createLiveTranscriptionSession(
                language: "en", translate: false, prompt: nil, onProgress: { _ in true }
            )
            XCTFail("expected the session to fail")
        } catch PluginTranscriptionError.apiError(let message) {
            XCTAssertEqual(message, "Unsupported model")
        }
        XCTAssertTrue(socket.isClosed)
    }

    func testLiveSessionFailsWhenTheConnectionEndsBeforeSessionClosed() async throws {
        let socket = FakeZoomLiveSocket(
            textAnswers: ["session.update": [#"{"type":"session.updated"}"#]],
            closesOnSessionClose: true
        )
        let host = try PluginTestHostServices(secrets: ["api-key": "zoom-key"])
        let plugin = ZoomPlugin(liveSocketFactory: { _ in socket })
        plugin.activate(host: host)

        let session = try await plugin.createLiveTranscriptionSession(
            language: "en", translate: false, prompt: nil, onProgress: { _ in true }
        )
        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 1_600))
        do {
            _ = try await session.finish()
            XCTFail("expected the session to fail")
        } catch PluginTranscriptionError.networkError {}
    }

    func testLiveItemsJoinWithoutSpacesBetweenChineseOrJapaneseText() {
        XCTAssertEqual(ZoomLiveTranscriptionSession.joinedText(["今日は晴れです。", "明日は雨です。"]), "今日は晴れです。明日は雨です。")
        XCTAssertEqual(ZoomLiveTranscriptionSession.joinedText(["First item.", "", "Second item."]), "First item. Second item.")
        XCTAssertEqual(ZoomLiveTranscriptionSession.joinedText(["안녕하세요.", "반갑습니다."]), "안녕하세요. 반갑습니다.")
    }

    // MARK: - Helpers

    private static func audio() -> AudioData {
        let samples = [Float](repeating: 0.1, count: 16_000)
        return AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
    }

    private static func store(answers: [(Int, String)]) -> PluginHTTPClientSessionStore {
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: answers.map { status, body in
                .success(
                    Data(body.utf8),
                    HTTPURLResponse(
                        url: ZoomAPIClient.fastURL,
                        statusCode: status,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            })
        }
        return store
    }

    private static func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }
}

/// Plays Zoom's Live API: opens with `session.created`, answers each sent JSON
/// message type with scripted messages, and sends one scripted message after
/// each binary audio frame.
private final class FakeZoomLiveSocket: ZoomLiveSocket, @unchecked Sendable {
    struct Sent: Sendable {
        let type: String
        let text: String?
        let audioByteCount: Int?

        var json: [String: Any]? {
            text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }

    private struct State {
        var sent: [Sent] = []
        var textAnswers: [String: [String]]
        var audioAnswers: [String]
        var closesOnSessionClose: Bool
        var isClosed = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let stream: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation

    init(textAnswers: [String: [String]], audioAnswers: [String] = [], closesOnSessionClose: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(
            textAnswers: textAnswers,
            audioAnswers: audioAnswers,
            closesOnSessionClose: closesOnSessionClose
        ))
        (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.yield(#"{"type":"session.created","session_id":"ls_1"}"#)
    }

    var sentMessages: [Sent] { state.withLock { $0.sent } }
    var isClosed: Bool { state.withLock { $0.isClosed } }

    func send(text: String) async throws {
        let type = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"] as? String ?? ""
        let (answers, closes) = state.withLock { state -> ([String], Bool) in
            state.sent.append(Sent(type: type, text: text, audioByteCount: nil))
            let answers = state.textAnswers[type] ?? []
            state.textAnswers[type] = nil
            return (answers, type == "session.close" && state.closesOnSessionClose)
        }
        answers.forEach { continuation.yield($0) }
        if closes {
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }
    }

    func send(data: Data) async throws {
        let answer = state.withLock { state -> String? in
            state.sent.append(Sent(type: "audio", text: nil, audioByteCount: data.count))
            return state.audioAnswers.isEmpty ? nil : state.audioAnswers.removeFirst()
        }
        if let answer { continuation.yield(answer) }
    }

    func receive() async throws -> String {
        var iterator = stream.makeAsyncIterator()
        guard let message = try await iterator.next() else { throw URLError(.cancelled) }
        return message
    }

    func close() {
        state.withLock { $0.isClosed = true }
        continuation.finish()
    }
}

private final class LiveProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var values: [URLRequest] { lock.withLock { storage } }

    func append(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}
