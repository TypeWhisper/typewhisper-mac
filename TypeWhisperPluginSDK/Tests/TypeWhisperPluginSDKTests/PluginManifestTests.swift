import XCTest
@testable import TypeWhisperPluginSDK

final class PluginManifestTests: XCTestCase {
    func testPluginSDKCompatibilityLineRemainsV1ForAdditiveHostPolicies() {
        XCTAssertEqual(PluginSDKCompatibility.currentVersion, "v1")
    }

    func testModelImportMarkerIsAdditiveAndDistinctFromOlderHosts() {
        XCTAssertNotEqual(PluginSDKCompatibility.modelImportVersion, "v1")
        XCTAssertTrue(PluginSDKCompatibility.isCompatible(manifestVersion: "v1", isBundled: false))
        XCTAssertTrue(PluginSDKCompatibility.isCompatible(manifestVersion: "v1-model-import", isBundled: false))
        XCTAssertNil(PluginSDKCompatibility.incompatibilityReason(manifestVersion: "v1-model-import", isBundled: false))
        XCTAssertFalse(PluginSDKCompatibility.isCompatible(manifestVersion: "v2", isBundled: false))
    }

    func testLocalityDecodesKnownValuesAndTreatsOthersAsUnknown() throws {
        for (raw, expected) in [("local", PluginLocality.local), ("cloud", .cloud), ("configurable", .configurable), (" local ", .local)] {
            XCTAssertEqual(try decodeManifest(locality: raw).resolvedLocality, expected, raw)
        }
        for raw in ["hybrid", "Local", ""] {
            let manifest = try decodeManifest(locality: raw)
            XCTAssertEqual(manifest.locality, raw, "An unknown value still decodes")
            XCTAssertNil(manifest.resolvedLocality, raw)
        }
    }

    func testMissingLocalityIsUnknownEvenWhenHostingIsDeclared() throws {
        let manifest = try decodeManifest(locality: nil, hosting: "local")

        XCTAssertNil(manifest.locality)
        XCTAssertNil(manifest.resolvedLocality)
        XCTAssertEqual(manifest.resolvedHosting, .local)
    }

    private func decodeManifest(locality: String?, hosting: String? = nil) throws -> PluginManifest {
        var json: [String: Any] = [
            "id": "com.typewhisper.mock",
            "name": "Mock Plugin",
            "version": "1.2.3",
            "principalClass": "MockPlugin",
        ]
        json["locality"] = locality
        json["hosting"] = hosting
        return try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testPluginManifestDecodesOptionalCompatibilityFields() throws {
        let data = Data(
            """
            {
              "id": "com.typewhisper.mock",
              "name": "Mock Plugin",
              "version": "1.2.3",
              "minHostVersion": "1.6.0",
              "sdkCompatibilityVersion": "v1",
              "minOSVersion": "14.0",
              "author": "TypeWhisper",
              "principalClass": "MockPlugin"
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(
            manifest,
            PluginManifest(
                id: "com.typewhisper.mock",
                name: "Mock Plugin",
                version: "1.2.3",
                minHostVersion: "1.6.0",
                sdkCompatibilityVersion: "v1",
                minOSVersion: "14.0",
                author: "TypeWhisper",
                principalClass: "MockPlugin"
            )
        )
    }

    func testPluginManifestDecodesSupportedArchitecturesWhenPresent() throws {
        let data = Data(
            """
            {
              "id": "com.typewhisper.mock",
              "name": "Mock Plugin",
              "version": "1.2.3",
              "supportedArchitectures": ["arm64"],
              "principalClass": "MockPlugin"
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.supportedArchitectures, ["arm64"])
    }

    func testPluginManifestDecodesSDKCompatibilityVersionWhenPresent() throws {
        let data = Data(
            """
            {
              "id": "com.typewhisper.mock",
              "name": "Mock Plugin",
              "version": "1.2.3",
              "sdkCompatibilityVersion": "v1",
              "principalClass": "MockPlugin"
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.sdkCompatibilityVersion, "v1")
    }

    func testPluginManifestDecodesHostingWhenPresent() throws {
        let data = Data(
            """
            {
              "id": "com.typewhisper.cloud",
              "name": "Cloud Plugin",
              "version": "1.2.3",
              "principalClass": "CloudPlugin",
              "hosting": "cloud",
              "requiresAPIKey": false
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.hosting, .cloud)
        XCTAssertEqual(manifest.requiresAPIKey, false)
        XCTAssertEqual(manifest.resolvedHosting, .cloud)
    }

    func testPluginManifestDecodesMultipleCategoryIdentifiers() throws {
        let data = Data(
            """
            {
              "id": "com.typewhisper.multi",
              "name": "Multi Plugin",
              "version": "1.2.3",
              "principalClass": "MultiPlugin",
              "category": "transcription",
              "categories": ["transcription", "llm", "memory"],
              "capabilities": ["source-footage-progress", "source-footage-progress", "  future-capability  ", ""]
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.category, "transcription")
        XCTAssertEqual(manifest.categories, ["transcription", "llm", "memory"])
        XCTAssertEqual(manifest.resolvedCategoryIdentifiers, ["transcription", "llm", "memory"])
        XCTAssertEqual(manifest.resolvedCapabilityIdentifiers, ["source-footage-progress", "future-capability"])
        XCTAssertTrue(manifest.supportsCapability(.sourceFootageProgress))
    }

    func testPluginManifestResolvedHostingFallsBackToAPIKeyRequirement() {
        let cloudManifest = PluginManifest(
            id: "com.typewhisper.remote",
            name: "Remote Plugin",
            version: "1.0.0",
            principalClass: "RemotePlugin",
            requiresAPIKey: true
        )
        let localManifest = PluginManifest(
            id: "com.typewhisper.local",
            name: "Local Plugin",
            version: "1.0.0",
            principalClass: "LocalPlugin"
        )

        XCTAssertEqual(cloudManifest.resolvedHosting, .cloud)
        XCTAssertEqual(localManifest.resolvedHosting, .local)
    }
}
