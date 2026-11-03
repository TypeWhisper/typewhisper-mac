import Foundation
import XCTest
@testable import TypeWhisper

final class HTTPRequestParserTests: XCTestCase {
    func testMaxBodySizeIs256MiB() {
        XCTAssertEqual(HTTPRequestParser.maxBodySize, 256 * 1024 * 1024)
    }

    func testServerReassemblesBodyReceivedInManyChunks() async throws {
        let router = APIRouter()
        router.register("POST", "/echo") { request in
            HTTPResponse(status: 200, contentType: "application/octet-stream", body: request.body)
        }
        let server = HTTPServer(router: router)
        let ready = expectation(description: "Loopback API listening")
        server.onStateChange = { if $0 { ready.fulfill() } }
        let port = UInt16.random(in: 49_152...65_535)
        try server.start(port: port)
        defer { server.stopAndCancelActiveRequests() }
        await fulfillment(of: [ready], timeout: 5)

        // The server receives at most 64 KiB per read, so this arrives in many chunks.
        let body = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/echo")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 10
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, body)
    }

    func testParseExtractsHeadersQueryAndBody() throws {
        let body = Data("hello".utf8)
        let requestData = Data("""
        POST /v1/status?lang=de HTTP/1.1\r
        Host: localhost\r
        Content-Type: text/plain\r
        Content-Length: 5\r
        \r
        hello
        """.utf8)

        let request = try HTTPRequestParser.parse(requestData)

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/status")
        XCTAssertEqual(request.queryParams["lang"], "de")
        XCTAssertEqual(request.headers["content-type"], "text/plain")
        XCTAssertEqual(request.body, body)
    }

    func testParseMultipartReadsFilePartAndField() {
        let boundary = "Boundary-123"
        let multipart = Data("""
        --\(boundary)\r
        Content-Disposition: form-data; name="language"\r
        \r
        en\r
        --\(boundary)\r
        Content-Disposition: form-data; name="file"; filename="audio.wav"\r
        Content-Type: audio/wav\r
        \r
        WAVDATA\r
        --\(boundary)--\r
        """.utf8)

        let parts = HTTPRequestParser.parseMultipart(body: multipart, boundary: boundary)

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.first?.name, "language")
        XCTAssertEqual(String(data: parts.first?.data ?? Data(), encoding: .utf8), "en")
        XCTAssertEqual(parts.last?.filename, "audio.wav")
    }

    func testParseRejectsOversizedBodies() {
        let requestData = Data(
            (
                "POST /v1/transcribe HTTP/1.1\r\n" +
                "Content-Length: \(HTTPRequestParser.maxBodySize + 1)\r\n" +
                "\r\n"
            ).utf8
        )

        XCTAssertThrowsError(try HTTPRequestParser.parse(requestData)) { error in
            XCTAssertEqual(error as? HTTPParseError, .bodyTooLarge)
        }
    }
}
