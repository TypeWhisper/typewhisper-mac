import Foundation
import TypeWhisperPluginSDK
import XCTest
@testable import R2T2Plugin

final class R2T2PluginTests: XCTestCase {
    func testLanguageMappingUsesCanonicalNamesAndAutoFallback() {
        XCTAssertEqual(R2T2Protocol.languageName(for: nil), "zhen")
        XCTAssertEqual(R2T2Protocol.languageName(for: " "), "zhen")
        XCTAssertEqual(R2T2Protocol.languageName(for: "zh"), "Chinese")
        XCTAssertEqual(R2T2Protocol.languageName(for: "en-US"), "English")
        XCTAssertEqual(R2T2Protocol.languageName(for: "de_DE"), "German")
        XCTAssertEqual(R2T2Protocol.languageName(for: "xx"), "zhen")
    }

    func testHeaderContainsRequiredServerFields() {
        let header = R2T2Protocol.makeHeader(requestId: "req-1", language: "en", secretKey: "s3cret", useVAD: true)

        XCTAssertEqual(header["requestId"] as? String, "req-1")
        XCTAssertEqual(header["language"] as? String, "English")
        XCTAssertEqual(header["secret_key"] as? String, "s3cret")
        XCTAssertEqual(header["use_vad"] as? Bool, true)
        XCTAssertEqual(header["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(header["channels"] as? Int, 1)
        XCTAssertEqual(header["mode"] as? String, "slow")
    }

    func testParseServerMessages() {
        XCTAssertEqual(R2T2Protocol.parseServerMessage(#"{"status":"connected","requestId":"r","msg":""}"#), .connected)
        XCTAssertEqual(R2T2Protocol.parseServerMessage("{}"), .keepAlive)
        XCTAssertEqual(
            R2T2Protocol.parseServerMessage(#"{"status":"success","requestId":"r","msg":{"text":" hello","reset":false,"asr_cost_ms":12.5}}"#),
            .text(delta: " hello", reset: false)
        )
        XCTAssertEqual(
            R2T2Protocol.parseServerMessage(#"{"status":"success","msg":{"text":"","reset":true}}"#),
            .text(delta: "", reset: true)
        )
        XCTAssertEqual(R2T2Protocol.parseServerMessage(#"{"status":"error","msg":"bad header"}"#), .error("bad header"))
        XCTAssertNil(R2T2Protocol.parseServerMessage("not json"))
    }

    func testPCM16LEEncodingClampsAndUsesLittleEndian() {
        let data = R2T2Protocol.makePCM16LEData(samples: [-1, 0, 1, 0.5])
        XCTAssertEqual([UInt8](data), [0x01, 0x80, 0x00, 0x00, 0xff, 0x7f, 0xff, 0x3f])
    }

    func testServerURLNormalization() {
        XCTAssertEqual(R2T2Protocol.normalizedServerURL("ws://localhost:8272/asr_stream_api_v1")?.absoluteString, "ws://localhost:8272/asr_stream_api_v1")
        XCTAssertEqual(R2T2Protocol.normalizedServerURL("localhost:8272")?.absoluteString, "ws://localhost:8272/asr_stream_api_v1")
        XCTAssertEqual(R2T2Protocol.normalizedServerURL("http://gpu-box:8272/")?.absoluteString, "ws://gpu-box:8272/asr_stream_api_v1")
        XCTAssertEqual(R2T2Protocol.normalizedServerURL("https://r2t2.example.com/custom")?.absoluteString, "wss://r2t2.example.com/custom")
        XCTAssertNil(R2T2Protocol.normalizedServerURL(""))
    }

    func testPluginDefaults() {
        let plugin = R2T2Plugin()
        XCTAssertTrue(plugin.isConfigured)
        XCTAssertEqual(plugin.secretKey, "test0102")
        XCTAssertEqual(plugin.selectedModelId, "confucius4-r2t2")
        XCTAssertTrue(plugin.supportedLanguages.contains("zh"))
        XCTAssertTrue(plugin.supportedLanguages.contains("en"))
        XCTAssertTrue(plugin.supportsStreaming)
    }
}
