import Foundation
import XCTest

@testable import TypeWhisper

@MainActor
final class WhisperKitPluginCompatibilityTests: XCTestCase {
    func testStable16HostCompatibilityAvoidsPost16NetworkGuardSDKSymbol() throws {
        let sourceURL = TestSupport.repoRoot.appendingPathComponent(
            "TypeWhisperPluginSDK/Plugins/WhisperKitPlugin/WhisperKitPlugin.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains("PluginHTTPClient.ensureNetworkAccessIsAllowed"),
            "WhisperKit must remain loadable by the declared TypeWhisper 1.6.0 host"
        )
    }

    func testLocalNetworkPolicyAllowsNormalRuntime() {
        XCTAssertNoThrow(
            try WhisperKitNetworkAccessPolicy.ensureAccessIsAllowed(arguments: ["TypeWhisper"])
        )
    }

    func testLocalNetworkPolicyBlocksScreenshotAutomation() {
        XCTAssertThrowsError(
            try WhisperKitNetworkAccessPolicy.ensureAccessIsAllowed(
                arguments: ["TypeWhisper", "--store-screenshots"]
            )
        ) { error in
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }
}
