import XCTest
@testable import TypeWhisper

final class SpeechCredentialCheckTests: XCTestCase {
    func testDeepgramPreservesItsConfiguredEndpointAndAuthenticationHeader() throws {
        let request = try XCTUnwrap(SpeechCredentialCheck.request(pluginId: "com.typewhisper.deepgram", key: "",
            deepgramBaseURL: "https://api.deepgram.com/", deepgramAuthHeader: "X-API-Key"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepgram.com/v1/projects")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testRegionalSonioxValidationStaysInTheSelectedRegion() throws {
        let request = try XCTUnwrap(SpeechCredentialCheck.request(pluginId: "com.typewhisper.soniox", key: "", sonioxRegion: "eu"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.eu.soniox.com/v1/files")
        XCTAssertNil(request.url?.query)
    }

    func testGeminiUsesHeaderAuthentication() throws {
        let request = try XCTUnwrap(SpeechCredentialCheck.request(pluginId: "com.typewhisper.gemini", key: ""))
        XCTAssertEqual(request.url?.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(request.url?.query, "pageSize=1")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
    }

    func testInvalidCredentialsAndServerOutagesRemainDistinct() {
        XCTAssertEqual(SpeechCredentialCheck.result(pluginId: "com.typewhisper.openai", statusCode: 200, data: Data()), .connected)
        XCTAssertEqual(SpeechCredentialCheck.result(pluginId: "com.typewhisper.openai", statusCode: 401, data: Data()), .invalid)
        XCTAssertEqual(SpeechCredentialCheck.result(pluginId: "com.typewhisper.openai", statusCode: 503, data: Data()), .unavailable)
    }

    func testElevenLabsSpeechOnlyKeyDoesNotRequireUserReadPermission() throws {
        let response = try JSONSerialization.data(withJSONObject: ["detail": [
            "status": "missing_permissions",
            "message": "The API key you used is missing the permission user_read to execute this operation."
        ]])
        XCTAssertEqual(SpeechCredentialCheck.result(pluginId: "com.typewhisper.elevenlabs", statusCode: 401, data: response), .connected)
        XCTAssertEqual(SpeechCredentialCheck.result(pluginId: "com.typewhisper.openai", statusCode: 401, data: response), .invalid)
    }
}
