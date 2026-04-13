import Foundation
import XCTest
@testable import TypeWhisperPluginSDK

final class OpenAIChatHelperTests: XCTestCase {
    @available(*, deprecated, message: "Testing the legacy compatibility shim.")
    func testLegacyProcessOverloadUsesMaxTokensDefaults() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let requestBodyURL = tempDirectory.appendingPathComponent("request-body.json", isDirectory: false)
        let portURL = tempDirectory.appendingPathComponent("port.txt", isDirectory: false)
        let scriptURL = tempDirectory.appendingPathComponent("server.py", isDirectory: false)

        let script = """
        import http.server
        import json
        import socketserver
        import sys

        port_file, request_file = sys.argv[1], sys.argv[2]

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                with open(request_file, "wb") as f:
                    f.write(body)

                response = json.dumps({"choices": [{"message": {"content": "ok"}}]}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

            def log_message(self, format, *args):
                pass

        with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
            with open(port_file, "w", encoding="utf-8") as f:
                f.write(str(httpd.server_address[1]))
            httpd.serve_forever()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let serverProcess = Process()
        serverProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        serverProcess.arguments = [scriptURL.path, portURL.path, requestBodyURL.path]
        try serverProcess.run()
        defer {
            if serverProcess.isRunning {
                serverProcess.terminate()
                serverProcess.waitUntilExit()
            }
        }

        let port = try await waitForPort(at: portURL)
        let helper = PluginOpenAIChatHelper(baseURL: "http://127.0.0.1:\(port)")

        let result = try await callLegacyProcess(
            helper,
            apiKey: "test-key",
            model: "gpt-4o",
            systemPrompt: "Fix grammar",
            userText: "hello world"
        )

        let requestBodyData = try Data(contentsOf: requestBodyURL)
        let requestBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestBodyData) as? [String: Any]
        )

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(requestBody["max_tokens"] as? Int, 4096)
        XCTAssertNil(requestBody["max_completion_tokens"])
    }

    func testRequestBodyUsesMaxTokensByDefault() {
        let helper = PluginOpenAIChatHelper(baseURL: "https://example.com")

        let requestBody = helper.requestBody(
            model: "gpt-4o",
            systemPrompt: "Fix grammar",
            userText: "hello world",
            maxOutputTokens: 4096,
            maxOutputTokenParameter: "max_tokens"
        )

        XCTAssertEqual(requestBody["model"] as? String, "gpt-4o")
        XCTAssertEqual(requestBody["max_tokens"] as? Int, 4096)
        XCTAssertNil(requestBody["max_completion_tokens"])
    }

    func testRequestBodySupportsMaxCompletionTokensOverride() {
        let helper = PluginOpenAIChatHelper(baseURL: "https://example.com")

        let requestBody = helper.requestBody(
            model: "gpt-5.4",
            systemPrompt: "Fix grammar",
            userText: "hello world",
            maxOutputTokens: 4096,
            maxOutputTokenParameter: "max_completion_tokens"
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
            maxOutputTokenParameter: "max_completion_tokens"
        )

        XCTAssertNil(requestBody["max_tokens"])
        XCTAssertNil(requestBody["max_completion_tokens"])
    }

    private func waitForPort(at url: URL) async throws -> String {
        for _ in 0..<50 {
            if let port = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !port.isEmpty {
                return port
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTFail("Timed out waiting for test server port")
        throw URLError(.timedOut)
    }

    @available(*, deprecated, message: "Exercising the legacy compatibility shim.")
    private func callLegacyProcess(
        _ helper: PluginOpenAIChatHelper,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String
    ) async throws -> String {
        try await helper.process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText
        )
    }
}
