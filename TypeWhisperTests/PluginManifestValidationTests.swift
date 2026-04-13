import Foundation
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

@MainActor
final class PluginInstallationErrorLoggingTests: XCTestCase {
    func testLoadPluginLogsManifestReadFailuresToErrorLog() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let errorLogService = ErrorLogService(appSupportDirectory: appSupportDirectory)
        let pluginManager = PluginManager(
            appSupportDirectory: appSupportDirectory,
            errorLogService: errorLogService
        )
        let bundleURL = appSupportDirectory.appendingPathComponent("Broken.bundle", isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try pluginManager.loadPlugin(at: bundleURL))
        XCTAssertEqual(errorLogService.entries.count, 1)
        XCTAssertEqual(errorLogService.entries.first?.category, "plugins")
        XCTAssertTrue(errorLogService.entries.first?.message.contains("Broken.bundle") == true)
    }

    func testDownloadAndInstallLogsValidationErrorsBeforeLoadPhase() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let errorLogService = ErrorLogService(appSupportDirectory: appSupportDirectory)
        let pluginManager = PluginManager(
            appSupportDirectory: appSupportDirectory,
            errorLogService: errorLogService
        )
        let registryService = PluginRegistryService(errorLogService: errorLogService)
        PluginManager.shared = pluginManager
        PluginRegistryService.shared = registryService

        let archiveSourceURL = appSupportDirectory.appendingPathComponent("ArchiveSource", isDirectory: true)
        let archiveURL = appSupportDirectory.appendingPathComponent("BrokenPlugin.zip", isDirectory: false)
        try FileManager.default.createDirectory(at: archiveSourceURL, withIntermediateDirectories: true)
        try Self.createZip(from: archiveSourceURL, to: archiveURL)

        let plugin = RegistryPlugin(
            id: "com.typewhisper.test.broken",
            name: "Broken Plugin",
            version: "1.0.0",
            minHostVersion: "1.0.0",
            minOSVersion: "14.0",
            author: "TypeWhisper",
            description: "Broken test plugin",
            category: "utility",
            size: 1,
            downloadURL: archiveURL.absoluteURL.absoluteString,
            iconSystemName: nil,
            requiresAPIKey: nil,
            descriptions: nil,
            downloadCount: nil
        )

        await registryService.downloadAndInstall(plugin)

        XCTAssertEqual(registryService.installStates[plugin.id], .error("No .bundle found in ZIP"))
        XCTAssertEqual(errorLogService.entries.count, 1)
        XCTAssertEqual(errorLogService.entries.first?.category, "plugins")
        XCTAssertTrue(errorLogService.entries.first?.message.contains("Failed to install Broken Plugin") == true)
        XCTAssertTrue(errorLogService.entries.first?.message.contains("No .bundle found in ZIP") == true)
    }

    private static func createZip(from sourceURL: URL, to zipURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-ck", "--keepParent", sourceURL.path, zipURL.path]
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
    }
}
