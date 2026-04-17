import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class PluginRegistryServiceTests: XCTestCase {
    private let sdkCompatibilityVersion = "v1"

    func testLegacyRegistryEntryDoesNotResolveWithoutSDKCompatibilityVersion() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.typewhisper.legacy",
                  "name": "Legacy Plugin",
                  "version": "1.0.5",
                  "minHostVersion": "1.2.0",
                  "author": "TypeWhisper",
                  "description": "Legacy entry",
                  "category": "utility",
                  "size": 42,
                  "downloadURL": "https://example.com/legacy.zip"
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.2.3",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertTrue(plugins.isEmpty)
    }

    func testMultiReleaseRegistryChoosesNewestCompatibleReleaseWithMatchingSDKCompatibilityVersion() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.typewhisper.multi",
                  "name": "Multi Plugin",
                  "author": "TypeWhisper",
                  "description": "Multi-release entry",
                  "category": "transcription",
                  "downloadCount": 100,
                  "releases": [
                    {
                      "version": "1.1.0",
                      "minHostVersion": "1.3.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 20,
                      "downloadURL": "https://example.com/new.zip"
                    },
                    {
                      "version": "1.0.5",
                      "minHostVersion": "1.2.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/compatible.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.2.4",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.version, "1.0.5")
        XCTAssertEqual(plugins.first?.downloadURL, "https://example.com/compatible.zip")
        XCTAssertEqual(plugins.first?.downloadCount, 100)
    }

    func testMultiReleaseRegistryRejectsReleaseWithMismatchedSDKCompatibilityVersionAtSameHostVersion() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.typewhisper.multi",
                  "name": "Multi Plugin",
                  "author": "TypeWhisper",
                  "description": "Multi-release entry",
                  "category": "transcription",
                  "releases": [
                    {
                      "version": "1.0.6",
                      "minHostVersion": "1.2.2",
                      "sdkCompatibilityVersion": "v2",
                      "size": 12,
                      "downloadURL": "https://example.com/mismatched.zip"
                    },
                    {
                      "version": "1.0.5",
                      "minHostVersion": "1.2.2",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/matching.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.2.2",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.version, "1.0.5")
        XCTAssertEqual(plugins.first?.downloadURL, "https://example.com/matching.zip")
    }

    func testMultiReleaseRegistryFiltersIncompatibleReleasesByArchitectureAndOS() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.typewhisper.arch",
                  "name": "Architecture Plugin",
                  "author": "TypeWhisper",
                  "description": "Architecture-sensitive entry",
                  "category": "transcription",
                  "releases": [
                    {
                      "version": "1.2.0",
                      "minHostVersion": "1.0.0",
                      "sdkCompatibilityVersion": "v1",
                      "minOSVersion": "15.0",
                      "supportedArchitectures": ["arm64"],
                      "size": 20,
                      "downloadURL": "https://example.com/arm64-new.zip"
                    },
                    {
                      "version": "1.1.0",
                      "minHostVersion": "1.0.0",
                      "sdkCompatibilityVersion": "v1",
                      "minOSVersion": "14.0",
                      "supportedArchitectures": ["x86_64"],
                      "size": 10,
                      "downloadURL": "https://example.com/intel-compatible.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let osVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)
        let plugins = response.resolvedPlugins(
            appVersion: "1.2.4",
            sdkCompatibilityVersion: sdkCompatibilityVersion,
            currentOSVersion: osVersion,
            architecture: "x86_64"
        )

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.version, "1.1.0")
        XCTAssertEqual(plugins.first?.downloadURL, "https://example.com/intel-compatible.zip")
    }

    func testMalformedPluginEntryIsSkippedInsteadOfFailingEntireRegistry() throws {
        // A single bad entry (wrong type on a required field) must not empty
        // the marketplace: the decoder reports the error and keeps the rest.
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": 42,
                  "name": "Malformed plugin id",
                  "author": "Test",
                  "description": "Bad entry",
                  "category": "utility",
                  "releases": []
                },
                {
                  "id": "com.typewhisper.ok",
                  "name": "Good Plugin",
                  "version": "1.0.0",
                  "minHostVersion": "1.0.0",
                  "author": "TypeWhisper",
                  "description": "Legacy good entry",
                  "category": "utility",
                  "size": 10,
                  "downloadURL": "https://example.com/ok.zip"
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.2.3",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(response.plugins.count, 1)
        XCTAssertTrue(plugins.isEmpty)
    }
}
