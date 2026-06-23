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
}
