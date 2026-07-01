import Foundation
import Darwin
import XCTest
@testable import TypeWhisper

final class HTTPRequestParserTests: XCTestCase {
    func testMaxBodySizeIs256MiB() {
        XCTAssertEqual(HTTPRequestParser.maxBodySize, 256 * 1024 * 1024)
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

    func testHTTPServerServesLoopbackRequests() async throws {
        let router = APIRouter()
        router.register("GET", "/ping") { _ in
            .json(["ok": true])
        }

        let server = HTTPServer(router: router)
        let port = try Self.availableLoopbackPort()
        let running = expectation(description: "server running")
        server.onStateChange = { isRunning in
            if isRunning {
                running.fulfill()
            }
        }

        try server.start(port: port)
        await fulfillment(of: [running], timeout: 1)
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/ping")!
        let (data, response) = try await URLSession.shared.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Bool]
        XCTAssertEqual(object?["ok"], true)
    }

    private static func availableLoopbackPort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socket >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(socket) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(socket, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(socket, socketAddress, &length)
            }
        }
        guard nameResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        return UInt16(bigEndian: boundAddress.sin_port)
    }
}
