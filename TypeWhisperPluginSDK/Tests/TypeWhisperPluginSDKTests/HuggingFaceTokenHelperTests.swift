import Foundation
import XCTest
@testable import TypeWhisperPluginSDK

private final class MockHuggingFaceEventBus: EventBusProtocol, @unchecked Sendable {
    func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID {
        UUID()
    }

    func unsubscribe(id: UUID) {}
}

private struct MockHuggingFaceHostServices: HostServices {
    private final class Storage: @unchecked Sendable {
        var secrets: [String: String] = [:]
    }

    private let storage = Storage()

    let pluginDataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let activeAppBundleId: String? = nil
    let activeAppName: String? = nil
    let eventBus: EventBusProtocol = MockHuggingFaceEventBus()
    let availableRuleNames: [String] = []

    func storeSecret(key: String, value: String) throws {
        storage.secrets[key] = value
    }

    func loadSecret(key: String) -> String? {
        storage.secrets[key]
    }

    func userDefault(forKey: String) -> Any? { nil }
    func setUserDefault(_ value: Any?, forKey key: String) {}
    func notifyCapabilitiesChanged() {}
    func setStreamingDisplayActive(_ active: Bool) {}
}

final class HuggingFaceTokenHelperTests: XCTestCase {
    func testSaveLoadAndClearTokenRoundTripsThroughHostServices() {
        let host = MockHuggingFaceHostServices()

        XCTAssertNil(PluginHuggingFaceTokenHelper.loadToken(from: host))

        let savedToken = PluginHuggingFaceTokenHelper.saveToken("  hf_test_token  ", to: host)

        XCTAssertEqual(savedToken, "hf_test_token")
        XCTAssertEqual(host.loadSecret(key: PluginHuggingFaceTokenHelper.storageKey), "hf_test_token")
        XCTAssertEqual(PluginHuggingFaceTokenHelper.loadToken(from: host), "hf_test_token")

        PluginHuggingFaceTokenHelper.clearToken(from: host)

        XCTAssertEqual(host.loadSecret(key: PluginHuggingFaceTokenHelper.storageKey), "")
        XCTAssertNil(PluginHuggingFaceTokenHelper.loadToken(from: host))
    }

    func testValidateTokenAcceptsWhoAmIPayload() async throws {
        let requestRecorder = RequestRecorder()

        let isValid = await PluginHuggingFaceTokenHelper.validateToken(" hf_test_token ") { request in
            await requestRecorder.set(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(#"{"name":"typewhisper","type":"user"}"#.utf8)
            return (data, response)
        }

        XCTAssertTrue(isValid)
        let recordedRequest = await requestRecorder.get()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://huggingface.co/api/whoami-v2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hf_test_token")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testValidateTokenRejectsInvalidResponses() async {
        let non200 = await PluginHuggingFaceTokenHelper.validateToken("hf_test_token") { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://huggingface.co")!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
        XCTAssertFalse(non200)

        let empty = await PluginHuggingFaceTokenHelper.validateToken("   ")
        XCTAssertFalse(empty)
    }
}

private actor RequestRecorder {
    private var request: URLRequest?

    func set(_ request: URLRequest) {
        self.request = request
    }

    func get() -> URLRequest? {
        request
    }
}
