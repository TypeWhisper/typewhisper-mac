import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class PluginManifestValidationTests: XCTestCase {
    func testAllPluginManifestsDecodeAndDeclareCompatibility() throws {
        let manifestURLs = try FileManager.default.contentsOfDirectory(
            at: TestSupport.repoRoot.appendingPathComponent("Plugins"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        .map { $0.appendingPathComponent("manifest.json") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }

        XCTAssertFalse(manifestURLs.isEmpty)

        let versionPattern = try NSRegularExpression(pattern: #"^\d+\.\d+(\.\d+)?$"#)

        for manifestURL in manifestURLs {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

            XCTAssertFalse(manifest.id.isEmpty, manifestURL.lastPathComponent)
            XCTAssertFalse(manifest.name.isEmpty, manifestURL.lastPathComponent)
            XCTAssertFalse(manifest.principalClass.isEmpty, manifestURL.lastPathComponent)
            XCTAssertNotNil(manifest.minHostVersion, manifestURL.lastPathComponent)

            let range = NSRange(location: 0, length: manifest.version.utf16.count)
            XCTAssertEqual(versionPattern.firstMatch(in: manifest.version, range: range)?.range, range, manifest.version)
        }
    }
}

final class OpenAIPluginTokenParameterTests: XCTestCase {
    func testLegacyOpenAIModelsKeepMaxTokens() {
        XCTAssertEqual(OpenAIPlugin.outputTokenParameter(for: "gpt-4o"), "max_tokens")
    }

    func testGPT5ModelsUseMaxCompletionTokens() {
        XCTAssertEqual(OpenAIPlugin.outputTokenParameter(for: "gpt-5.4"), "max_completion_tokens")
    }

    func testO4ModelsUseMaxCompletionTokens() {
        XCTAssertEqual(OpenAIPlugin.outputTokenParameter(for: "o4-mini"), "max_completion_tokens")
    }
}
