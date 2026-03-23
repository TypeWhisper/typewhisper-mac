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
