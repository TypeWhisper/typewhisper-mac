import XCTest
@testable import TypeWhisperPluginSDK

final class PluginManifestTests: XCTestCase {
    func testPluginManifestDecodesOptionalCompatibilityFields() throws {
        let data = Data(
            """
            {
              "id": "com.typewhisper.mock",
              "name": "Mock Plugin",
              "version": "1.2.3",
              "minHostVersion": "1.0.0",
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
                minHostVersion: "1.0.0",
                minOSVersion: "14.0",
                author: "TypeWhisper",
                principalClass: "MockPlugin"
            )
        )
    }
}
