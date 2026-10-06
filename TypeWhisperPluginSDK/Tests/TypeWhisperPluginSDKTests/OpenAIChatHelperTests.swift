import Network
import os
import XCTest
@testable import TypeWhisperPluginSDK

final class OpenAIChatHelperTests: XCTestCase {
    func testRequestBodyUsesMaxTokensByDefault() {
        let helper = PluginOpenAIChatHelper(baseURL: "https://example.com")

        let requestBody = helper.requestBody(
            model: "gpt-4o",
            systemPrompt: "Fix grammar",
            userText: "hello world",
            maxOutputTokens: 4096,
            maxOutputTokenParameter: "max_tokens",
            reasoningEffort: nil,
            temperature: 0.3
        )

        XCTAssertEqual(requestBody["model"] as? String, "gpt-4o")
        XCTAssertEqual(requestBody["max_tokens"] as? Int, 4096)
        XCTAssertEqual(requestBody["temperature"] as? Double, 0.3)
        XCTAssertNil(requestBody["max_completion_tokens"])
    }

    func testRequestBodySupportsMaxCompletionTokensOverride() {
        let helper = PluginOpenAIChatHelper(baseURL: "https://example.com")

        let requestBody = helper.requestBody(
            model: "gpt-5.4",
            systemPrompt: "Fix grammar",
            userText: "hello world",
            maxOutputTokens: 4096,
            maxOutputTokenParameter: "max_completion_tokens",
            reasoningEffort: nil,
            temperature: 0.3
        )

        XCTAssertEqual(requestBody["max_completion_tokens"] as? Int, 4096)
        XCTAssertNil(requestBody["max_tokens"])
    }

    func testRequestBodyOmitsTokenLimitWhenRequested() {
        let helper = PluginOpenAIChatHelper(baseURL: "https://example.com")

        let requestBody = helper.requestBody(
            model: "gpt-5.4",
            systemPrompt: "Fix grammar",
            userText: "hello world",
            maxOutputTokens: nil,
            maxOutputTokenParameter: "max_completion_tokens",
            reasoningEffort: nil,
            temperature: 0.3
        )

        XCTAssertNil(requestBody["max_tokens"])
        XCTAssertNil(requestBody["max_completion_tokens"])
    }

    func testRequestBodyIncludesReasoningEffortWhenProvided() {
        let helper = PluginOpenAIChatHelper(baseURL: "https://example.com")

        let requestBody = helper.requestBody(
            model: "gpt-5.4",
            systemPrompt: "Fix grammar",
            userText: "hello world",
            maxOutputTokens: 4096,
            maxOutputTokenParameter: "max_completion_tokens",
            reasoningEffort: "high",
            temperature: 0.3
        )

        XCTAssertEqual(requestBody["reasoning_effort"] as? String, "high")
    }

    func testRequestBodyIncludesEnabledThinkingWhenRequested() throws {
        let helper = PluginOpenAIChatHelper(baseURL: "https://example.com")

        let requestBody = helper.requestBody(
            model: "deepseek-v4-flash",
            systemPrompt: "Fix grammar",
            userText: "hello world",
            maxOutputTokens: 4096,
            maxOutputTokenParameter: "max_tokens",
            reasoningEffort: nil,
            temperature: 0.3,
            thinkingEnabled: true
        )

        let thinking = try XCTUnwrap(requestBody["thinking"] as? [String: String])
        XCTAssertEqual(thinking["type"], "enabled")
    }

    func testRequestBodyIncludesDisabledThinkingWhenRequested() throws {
        let helper = PluginOpenAIChatHelper(baseURL: "https://example.com")

        let requestBody = helper.requestBody(
            model: "deepseek-v4-flash",
            systemPrompt: "Fix grammar",
            userText: "hello world",
            maxOutputTokens: 4096,
            maxOutputTokenParameter: "max_tokens",
            reasoningEffort: nil,
            temperature: 0.3,
            thinkingEnabled: false
        )

        let thinking = try XCTUnwrap(requestBody["thinking"] as? [String: String])
        XCTAssertEqual(thinking["type"], "disabled")
    }

    func testRequestBodyOmitsThinkingWhenUnset() {
        let helper = PluginOpenAIChatHelper(baseURL: "https://example.com")

        let requestBody = helper.requestBody(
            model: "deepseek-v4-flash",
            systemPrompt: "Fix grammar",
            userText: "hello world",
            maxOutputTokens: 4096,
            maxOutputTokenParameter: "max_tokens",
            reasoningEffort: nil,
            temperature: 0.3,
            thinkingEnabled: nil
        )

        XCTAssertNil(requestBody["thinking"])
    }

    func testRequestBodyOmitsTemperatureWhenRequested() {
        let helper = PluginOpenAIChatHelper(baseURL: "https://example.com")

        let requestBody = helper.requestBody(
            model: "gpt-5.4",
            systemPrompt: "Fix grammar",
            userText: "hello world",
            maxOutputTokens: 4096,
            maxOutputTokenParameter: "max_completion_tokens",
            reasoningEffort: "high",
            temperature: nil
        )

        XCTAssertNil(requestBody["temperature"])
    }

    // MARK: - Error body parsing

    func testErrorMessageParsesDictionaryBody() {
        let data = Data(#"{"error":{"code":404,"message":"OpenAI says no"}}"#.utf8)

        let message = PluginOpenAIChatHelper.errorMessage(from: data, statusCode: 404)

        XCTAssertEqual(message, "OpenAI says no")
    }

    func testErrorMessageParsesTopLevelArrayBody() {
        // Gemini's OpenAI-compat endpoint wraps the error in a top-level array.
        let data = Data(
            """
            [{
              "error": {
                "code": 404,
                "message": "This model models/gemini-2.0-flash is no longer available.",
                "status": "NOT_FOUND"
              }
            }]
            """.utf8
        )

        let message = PluginOpenAIChatHelper.errorMessage(from: data, statusCode: 404)

        XCTAssertEqual(message, "This model models/gemini-2.0-flash is no longer available.")
    }

    func testErrorMessageFallsBackToStatusForUnparseableBody() {
        let data = Data("not json".utf8)

        let message = PluginOpenAIChatHelper.errorMessage(from: data, statusCode: 404)

        XCTAssertEqual(message, "HTTP 404")
    }

    func testErrorMessageFallsBackToStatusForEmptyArrayBody() {
        let data = Data("[]".utf8)

        let message = PluginOpenAIChatHelper.errorMessage(from: data, statusCode: 503)

        XCTAssertEqual(message, "HTTP 503")
    }

    func testErrorMessagePrefersTopLevelDetail() {
        let data = Data(#"{"detail":"Invalid request payload"}"#.utf8)

        let message = PluginOpenAIChatHelper.errorMessage(from: data, statusCode: 422)

        XCTAssertEqual(message, "Invalid request payload")
    }

    func testErrorMessageFallsBackToTopLevelMessage() {
        let data = Data(#"{"message":"Something went wrong"}"#.utf8)

        let message = PluginOpenAIChatHelper.errorMessage(from: data, statusCode: 500)

        XCTAssertEqual(message, "Something went wrong")
    }
    func testChatMessageContentReadsPlainString() {
        XCTAssertEqual(
            PluginOpenAIChatHelper.chatMessageContent(from: ["content": "hello"]),
            "hello"
        )
    }

    func testChatMessageContentTreatsNullContentAsEmptyAnswer() {
        // Reasoning-capable models return content: null when the visible answer
        // is empty - a valid empty response, previously "Failed to parse response".
        XCTAssertEqual(
            PluginOpenAIChatHelper.chatMessageContent(from: ["content": NSNull(), "reasoning": "thinking..."]),
            ""
        )
        XCTAssertEqual(
            PluginOpenAIChatHelper.chatMessageContent(from: ["role": "assistant"]),
            ""
        )
    }

    func testChatMessageContentJoinsTypedContentParts() {
        let message: [String: Any] = ["content": [
            ["type": "text", "text": "Hello "],
            ["type": "text", "text": "world"],
        ]]
        XCTAssertEqual(PluginOpenAIChatHelper.chatMessageContent(from: message), "Hello world")
    }

    func testChatMessageContentDoesNotPromoteReasoningText() {
        let message: [String: Any] = ["content": NSNull(), "reasoning_content": "chain of thought"]
        XCTAssertEqual(PluginOpenAIChatHelper.chatMessageContent(from: message), "")
    }

    func testChatMessageContentIgnoresTypedReasoningPartsEvenWhenTheyCarryText() {
        let message: [String: Any] = ["content": [
            ["type": "reasoning", "text": "let me think"],
            ["type": "text", "text": "Answer"],
            ["type": "reasoning", "content": "more thinking"],
            ["type": "text", "content": " two"],
            ["text": "untyped part is not promoted"],
        ]]
        XCTAssertEqual(PluginOpenAIChatHelper.chatMessageContent(from: message), "Answer two")
    }

    // MARK: - Truncated replies

    func testProcessThrowsWhenReplyStoppedAtTokenLimit() async throws {
        let server = try await ChatStubServer.start(
            body: #"{"choices":[{"message":{"content":"half a sen"},"finish_reason":"length"}]}"#
        )
        defer { server.stop() }
        let helper = PluginOpenAIChatHelper(baseURL: server.baseURL)

        do {
            _ = try await helper.process(apiKey: "key", model: "m", systemPrompt: "s", userText: "u")
            XCTFail("Expected the truncated reply to throw")
        } catch let error as PluginChatError {
            guard case .apiError(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("4096"), message)
        }
    }

    func testProcessThrowsWhenThinkingModelHitTokenLimitWithoutVisibleText() async throws {
        let server = try await ChatStubServer.start(
            body: #"{"choices":[{"message":{"content":null},"finish_reason":"length"}]}"#
        )
        defer { server.stop() }
        let helper = PluginOpenAIChatHelper(baseURL: server.baseURL)

        do {
            _ = try await helper.process(apiKey: "key", model: "m", systemPrompt: "s", userText: "u")
            XCTFail("Expected the truncated reply to throw")
        } catch is PluginChatError {
        }
    }

    func testProcessReturnsReplyThatFinishedNormally() async throws {
        let server = try await ChatStubServer.start(
            body: #"{"choices":[{"message":{"content":" done \n"},"finish_reason":"stop"}]}"#
        )
        defer { server.stop() }
        let helper = PluginOpenAIChatHelper(baseURL: server.baseURL)

        let result = try await helper.process(apiKey: "key", model: "m", systemPrompt: "s", userText: "u")

        XCTAssertEqual(result, "done")
    }
}

/// Minimal loopback HTTP server that answers every request with one JSON body.
private final class ChatStubServer: @unchecked Sendable {
    private let listener: NWListener
    let baseURL: String

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.baseURL = "http://127.0.0.1:\(port)"
    }

    static func start(body: String) async throws -> ChatStubServer {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { _, _, _, _ in
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !finished.withLock({ let was = $0; $0 = true; return was }) {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if !finished.withLock({ let was = $0; $0 = true; return was }) {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
        return ChatStubServer(listener: listener, port: port)
    }

    func stop() {
        listener.cancel()
    }
}
