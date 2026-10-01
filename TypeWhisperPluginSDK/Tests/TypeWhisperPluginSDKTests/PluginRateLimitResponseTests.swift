import XCTest
@testable import TypeWhisperPluginSDK

final class PluginRateLimitResponseTests: XCTestCase {
    func testQuotaBodySurfacesProviderMessage() {
        let data = Data(
            """
            {
              "error": {
                "message": "You exceeded your current quota, please check your plan and billing details.",
                "type": "insufficient_quota",
                "code": "insufficient_quota"
              }
            }
            """.utf8
        )
        let expected = "API error: HTTP 429: You exceeded your current quota, please check your plan and billing details."

        XCTAssertEqual(PluginTranscriptionError.rateLimitOrQuota(from: data).localizedDescription, expected)
        XCTAssertEqual(PluginChatError.rateLimitOrQuota(from: data).localizedDescription, expected)
    }

    func testProviderMessageReadsKnownBodyShapes() {
        let variants = [
            (#"{"detail":"Detail field"}"#, "Detail field"),
            (#"{"error":{"message":"Nested message"}}"#, "Nested message"),
            (#"{"error":"Plain error string"}"#, "Plain error string"),
            (#"{"message":"Top-level message"}"#, "Top-level message"),
            (#"{"error_message":"Error message field"}"#, "Error message field"),
            (#"[{"error":{"message":"Array-wrapped message"}}]"#, "Array-wrapped message"),
            (#"{"detail":"Detail wins","message":"Top-level message"}"#, "Detail wins"),
        ]

        for (body, expected) in variants {
            XCTAssertEqual(PluginRateLimitResponse.providerMessage(from: Data(body.utf8)), expected)
        }
    }

    func testBodyWithoutMessageFallsBackToGenericRateLimit() {
        let expected = "Rate limit or quota exceeded. Check your provider's usage limits and credit balance, or wait and try again."

        for body in ["", "not json", "[]", #"{"message":"   "}"#, #"{"error":{"code":429}}"#] {
            let data = Data(body.utf8)

            XCTAssertNil(PluginRateLimitResponse.providerMessage(from: data))
            XCTAssertEqual(PluginTranscriptionError.rateLimitOrQuota(from: data).localizedDescription, expected)
            XCTAssertEqual(PluginChatError.rateLimitOrQuota(from: data).localizedDescription, expected)
        }
    }

    func testLongProviderMessageIsBounded() throws {
        let data = try JSONSerialization.data(withJSONObject: ["message": String(repeating: "a", count: 5_000)])

        let message = try XCTUnwrap(PluginRateLimitResponse.providerMessage(from: data))

        XCTAssertLessThan(message.count, 1_000)
    }
}
