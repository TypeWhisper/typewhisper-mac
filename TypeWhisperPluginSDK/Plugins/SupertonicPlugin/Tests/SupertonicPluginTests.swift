import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import SupertonicPlugin

final class SupertonicPluginTests: XCTestCase {
    func testManifestDeclaresLocalTTSPluginForHost14AndArm64() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("manifest.json")

        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: try Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(manifest.id, "com.typewhisper.tts.supertonic")
        XCTAssertEqual(manifest.name, "Supertonic (Experimental)")
        XCTAssertEqual(manifest.category, "tts")
        XCTAssertEqual(manifest.hosting, .local)
        XCTAssertEqual(manifest.requiresAPIKey, false)
        XCTAssertEqual(manifest.minHostVersion, "1.4.0")
        XCTAssertEqual(manifest.supportedArchitectures, ["arm64"])
    }

    func testDownloadRequiresCurrentModelLicenseAcceptance() throws {
        let host = try PluginTestHostServices()
        let plugin = SupertonicPlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.hasAcceptedCurrentModelLicense)
        XCTAssertFalse(plugin.canDownloadModel)

        plugin.acceptCurrentModelLicense(now: Date(timeIntervalSince1970: 1_716_000_000))

        XCTAssertTrue(plugin.hasAcceptedCurrentModelLicense)
        XCTAssertTrue(plugin.canDownloadModel)
        XCTAssertEqual(host.userDefault(forKey: "acceptedModelLicenseId") as? String, SupertonicModelLicense.id)
        XCTAssertEqual(host.userDefault(forKey: "acceptedModelLicenseRevision") as? String, SupertonicModelLicense.revision)
        XCTAssertEqual(host.userDefault(forKey: "acceptedModelLicenseAt") as? String, "2024-05-18T02:40:00Z")
    }

    func testDownloadWithoutAcceptedLicenseDoesNotStartDownloadFlow() async throws {
        let host = try PluginTestHostServices()
        let plugin = SupertonicPlugin()
        plugin.activate(host: host)

        await plugin.downloadModel()

        XCTAssertEqual(plugin.modelState, .error(SupertonicPluginError.licenseNotAccepted.localizedDescription))
        let modelDirectory = SupertonicModelAssetManager(rootDirectory: host.pluginDataDirectory).modelDirectory
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
    }

    func testChangedModelLicenseRevisionInvalidatesPriorAcceptance() throws {
        let host = try PluginTestHostServices(defaults: [
            "acceptedModelLicenseId": SupertonicModelLicense.id,
            "acceptedModelLicenseRevision": "old-revision",
            "acceptedModelLicenseAt": "2024-05-18T08:00:00Z",
        ])
        let plugin = SupertonicPlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.hasAcceptedCurrentModelLicense)
        XCTAssertFalse(plugin.canDownloadModel)
    }

    func testSelectVoiceSpeedAndQualityPersistChoices() throws {
        let host = try PluginTestHostServices()
        let plugin = SupertonicPlugin()
        plugin.activate(host: host)

        plugin.selectVoice("F1")
        plugin.setSpeed(1.35)
        plugin.setQuality(.high)

        XCTAssertEqual(plugin.selectedVoiceId, "F1")
        XCTAssertEqual(plugin.selectedSpeed, 1.35, accuracy: 0.001)
        XCTAssertEqual(plugin.selectedQuality, .high)
        XCTAssertEqual(host.userDefault(forKey: "selectedVoiceId") as? String, "F1")
        XCTAssertEqual(host.userDefault(forKey: "speed") as? Double, 1.35)
        XCTAssertEqual(host.userDefault(forKey: "quality") as? String, "high")
    }

    func testLanguageNormalizationFallsBackToEnglish() {
        XCTAssertEqual(SupertonicLanguageResolver.normalizedLanguageCode(for: "de-DE"), "de")
        XCTAssertEqual(SupertonicLanguageResolver.normalizedLanguageCode(for: "ja"), "ja")
        XCTAssertEqual(SupertonicLanguageResolver.normalizedLanguageCode(for: nil), "en")
        XCTAssertEqual(SupertonicLanguageResolver.normalizedLanguageCode(for: "ga-IE"), "en")
    }

    func testModelInstallerDoesNotWriteFinalDirectoryWhenRequiredFileIsMissing() throws {
        let root = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = SupertonicModelAssetManager(rootDirectory: root)
        var files = SupertonicModelAssetManager.requiredRelativePaths.reduce(into: [String: Data]()) { result, path in
            result[path] = Data("fixture-\(path)".utf8)
        }
        files.removeValue(forKey: "onnx/vocoder.onnx")

        XCTAssertThrowsError(try installer.install(files: files, licenseAccepted: true)) { error in
            XCTAssertEqual((error as? SupertonicPluginError), .incompleteModelAssets)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.modelDirectory.path))
    }

    func testSpeakBeforeModelSetupThrowsNotConfigured() async throws {
        let host = try PluginTestHostServices()
        let plugin = SupertonicPlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.speak(TTSSpeakRequest(text: "Hello", language: "en", purpose: .manualReadback))
            XCTFail("Expected speak to fail before model setup")
        } catch {
            XCTAssertEqual(error as? SupertonicPluginError, .notConfigured)
        }
    }
}
