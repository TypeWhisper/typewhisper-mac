import Foundation
import XCTest
@testable import TypeWhisperPluginSDK

final class HTTPErrorBodyFormatterTests: XCTestCase {
    func testSummarizesHTMLPageWithTitleAndByteCount() throws {
        let html = """
            <!DOCTYPE html>
            <html><head><title>example.com | 522: Connection timed out</title></head>
            <body>IP address: 203.0.113.42; trace: secret-trace</body></html>
            """
        var data = Data(html.utf8)
        data.append(Data(repeating: 0x20, count: 7_224 - data.count))

        let summary = PluginHTTPErrorBodyFormatter.summary(
            from: data,
            response: try response(contentType: "text/html; charset=UTF-8")
        )

        XCTAssertEqual(
            summary,
            "upstream returned an HTML error page (7224 bytes): example.com | 522: Connection timed out"
        )
        XCTAssertFalse(summary.contains("203.0.113.42"))
        XCTAssertFalse(summary.contains("secret-trace"))
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("doctype"))
    }

    func testSniffsHTMLWithoutContentTypeAndDecodesTitleEntities() throws {
        let data = Data("  <HTML><head><TITLE class=\"error\">Origin &amp; CDN</TITLE></head></HTML>".utf8)

        let summary = PluginHTTPErrorBodyFormatter.summary(
            from: data,
            response: try response(contentType: nil)
        )

        XCTAssertEqual(
            summary,
            "upstream returned an HTML error page (73 bytes): Origin & CDN"
        )
    }

    func testMislabeledJSONIsKeptAndBounded() throws {
        let data = Data("{\"error\":\"\(String(repeating: "x", count: 700))\"}".utf8)

        let summary = PluginHTTPErrorBodyFormatter.summary(
            from: data,
            response: try response(contentType: "text/html")
        )

        XCTAssertTrue(summary.hasPrefix("{\"error\":\""))
        XCTAssertTrue(summary.hasSuffix("(truncated from 712 bytes)"))
        XCTAssertFalse(summary.contains("HTML error page"))
        XCTAssertLessThan(summary.count, 560)
    }

    func testPlainTextServedAsHTMLRemainsPlainText() throws {
        let data = Data("origin connection timed out".utf8)

        let summary = PluginHTTPErrorBodyFormatter.summary(
            from: data,
            response: try response(contentType: "text/html")
        )

        XCTAssertEqual(summary, "origin connection timed out")
    }

    func testSimilarMimeAndTagNamesDoNotClassifyAsHTML() throws {
        let data = Data("<html-widget><title-widget>plain diagnostic</title-widget></html-widget>".utf8)

        let summary = PluginHTTPErrorBodyFormatter.summary(
            from: data,
            response: try response(contentType: "text/htmlish")
        )

        XCTAssertFalse(summary.contains("HTML error page"))
        XCTAssertTrue(summary.contains("plain diagnostic"))
    }

    func testTitleRequiresClosingTagBoundary() throws {
        let data = Data(
            "<html><head><title>Keep </title-widget> remaining</title></head></html>".utf8
        )

        let summary = PluginHTTPErrorBodyFormatter.summary(
            from: data,
            response: try response(contentType: "text/html")
        )

        XCTAssertTrue(summary.hasSuffix(": Keep remaining"))
    }

    func testExtractsUnicodeTitleWhenEarlierTextUsesMultibyteCharacters() throws {
        let data = Data(
            "<html><head><!-- Grüße --><title>Überlastet</title></head></html>".utf8
        )

        let summary = PluginHTTPErrorBodyFormatter.summary(
            from: data,
            response: try response(contentType: "text/html")
        )

        XCTAssertTrue(summary.hasSuffix(": Überlastet"))
    }

    func testMarkerBeyondSniffWindowDoesNotReclassifyBody() throws {
        let data = Data(("<diagnostic>" + String(repeating: "x", count: 5_000) + "<html><title>Late</title>").utf8)

        let summary = PluginHTTPErrorBodyFormatter.summary(
            from: data,
            response: try response(contentType: nil)
        )

        XCTAssertFalse(summary.contains("HTML error page"))
        XCTAssertTrue(summary.hasSuffix("(truncated from \(data.count) bytes)"))
    }

    func testEmptyAndBinaryBodiesHaveBoundedFallbacks() throws {
        XCTAssertEqual(
            PluginHTTPErrorBodyFormatter.summary(
                from: Data(),
                response: try response(contentType: nil)
            ),
            "upstream returned an empty error body"
        )
        XCTAssertEqual(
            PluginHTTPErrorBodyFormatter.summary(
                from: Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB]),
                response: try response(contentType: "application/octet-stream")
            ),
            "upstream returned non-UTF-8 error data (5 bytes)"
        )
    }

    private func response(contentType: String?) throws -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let contentType {
            headers["Content-Type"] = contentType
        }
        return try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.test/error")!,
                statusCode: 522,
                httpVersion: nil,
                headerFields: headers
            )
        )
    }
}
