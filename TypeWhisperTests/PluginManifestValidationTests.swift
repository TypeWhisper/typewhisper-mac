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

@MainActor
final class PluginRegistryDestinationTests: XCTestCase {
    func testFreshInstallTargetsPluginsDirectory() {
        let pluginsDirectory = URL(fileURLWithPath: "/tmp/TypeWhisper-Dev/Plugins", isDirectory: true)

        let destination = PluginRegistryService.resolveInstallDestinationURL(
            currentURL: nil,
            builtInPluginsURL: nil,
            pluginsDirectory: pluginsDirectory,
            incomingBundleName: "ParakeetPlugin.bundle"
        )

        XCTAssertEqual(destination, pluginsDirectory.appendingPathComponent("ParakeetPlugin.bundle"))
    }

    func testExistingBundleInsidePluginsDirectoryKeepsItsPath() {
        let pluginsDirectory = URL(fileURLWithPath: "/tmp/TypeWhisper-Dev/Plugins", isDirectory: true)
        let existingURL = pluginsDirectory.appendingPathComponent("CustomParakeet.bundle")

        let destination = PluginRegistryService.resolveInstallDestinationURL(
            currentURL: existingURL,
            builtInPluginsURL: nil,
            pluginsDirectory: pluginsDirectory,
            incomingBundleName: "ParakeetPlugin.bundle"
        )

        XCTAssertEqual(destination, existingURL)
    }

    func testTemporaryLoadedBundleIsRehomedIntoPluginsDirectory() {
        let pluginsDirectory = URL(fileURLWithPath: "/tmp/TypeWhisper-Dev/Plugins", isDirectory: true)
        let temporaryURL = URL(fileURLWithPath: "/tmp/typewhisper-install/extracted/ParakeetPlugin.bundle", isDirectory: true)

        let destination = PluginRegistryService.resolveInstallDestinationURL(
            currentURL: temporaryURL,
            builtInPluginsURL: nil,
            pluginsDirectory: pluginsDirectory,
            incomingBundleName: "ParakeetPlugin.bundle"
        )

        XCTAssertEqual(destination, pluginsDirectory.appendingPathComponent("ParakeetPlugin.bundle"))
    }

    func testBuiltInBundleIsRehomedIntoPluginsDirectory() {
        let pluginsDirectory = URL(fileURLWithPath: "/tmp/TypeWhisper-Dev/Plugins", isDirectory: true)
        let builtInPluginsURL = URL(fileURLWithPath: "/Applications/TypeWhisper.app/Contents/PlugIns", isDirectory: true)
        let builtInURL = builtInPluginsURL.appendingPathComponent("ParakeetPlugin.bundle")

        let destination = PluginRegistryService.resolveInstallDestinationURL(
            currentURL: builtInURL,
            builtInPluginsURL: builtInPluginsURL,
            pluginsDirectory: pluginsDirectory,
            incomingBundleName: "ParakeetPlugin.bundle"
        )

        XCTAssertEqual(destination, pluginsDirectory.appendingPathComponent("ParakeetPlugin.bundle"))
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
