import Foundation
import XCTest
@testable import TypeWhisper

final class HTTPRequestParserTests: XCTestCase {
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
