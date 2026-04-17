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

    func testRegistryFeedUsesLegacyForStableBuildBefore130() {
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.2.2",
                releaseChannel: .stable
            ),
            .legacy
        )
    }

    func testRegistryFeedKeepsLegacyForPre130PreviewBuilds() {
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.2.2",
                releaseChannel: .releaseCandidate
            ),
            .legacy
        )
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.2.2",
                releaseChannel: .daily
            ),
            .legacy
        )
    }

    func testRegistryFeedUsesV1ForReleaseCandidateBuild() {
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.3.0",
                releaseChannel: .releaseCandidate
            ),
            .v1
        )
    }

    func testRegistryFeedUsesV1ForDailyBuild() {
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.3.0",
                releaseChannel: .daily
            ),
            .v1
        )
    }

    func testRegistryFeedUsesV1ForStable130AndNewer() {
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.3.0",
                releaseChannel: .stable
            ),
            .v1
        )
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.4.0",
                releaseChannel: .stable
            ),
            .v1
        )
    }

    @MainActor
    func testFetchRegistryUsesReleaseChannelSpecificFeedAndWritesLastKnownGoodCache() async throws {
        let suiteName = "PluginRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginRegistryCache")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            TestSupport.remove(cacheDirectory)
        }

        let payload = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.typewhisper.cached",
                  "name": "Cached Plugin",
                  "author": "TypeWhisper",
                  "description": "Cacheable entry",
                  "category": "utility",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.3.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/cached.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        var requestedURL: URL?
        let service = PluginRegistryService(
            registryBaseURL: URL(string: "https://example.com")!,
            cacheDirectory: cacheDirectory,
            cacheDuration: 0,
            userDefaults: defaults,
            infoDictionary: [
                "CFBundleShortVersionString": "1.3.0",
                "TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.releaseCandidate.rawValue,
            ],
            fetchData: { request in
                requestedURL = request.url
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (payload, response)
            }
        )

        await service.fetchRegistry(force: true)

        XCTAssertEqual(requestedURL?.absoluteString, "https://example.com/plugins-v1.json")
        XCTAssertEqual(service.fetchState, .loaded)
        XCTAssertEqual(service.registry.map(\.id), ["com.typewhisper.cached"])

        let cachedData = try Data(contentsOf: cacheDirectory.appendingPathComponent("plugins-v1.json"))
        let cachedResponse = try JSONDecoder().decode(PluginRegistryResponse.self, from: cachedData)
        XCTAssertEqual(cachedResponse.plugins.map(\.id), ["com.typewhisper.cached"])
    }

    @MainActor
    func testFetchRegistryFallsBackToLastKnownGoodCacheWhenRemoteFetchFails() async throws {
        let suiteName = "PluginRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginRegistryCache")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            TestSupport.remove(cacheDirectory)
        }

        let payload = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.typewhisper.cached",
                  "name": "Cached Plugin",
                  "author": "TypeWhisper",
                  "description": "Cacheable entry",
                  "category": "utility",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.3.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/cached.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )
        try payload.write(to: cacheDirectory.appendingPathComponent("plugins-v1.json"))

        let service = PluginRegistryService(
            registryBaseURL: URL(string: "https://example.com")!,
            cacheDirectory: cacheDirectory,
            cacheDuration: 0,
            userDefaults: defaults,
            infoDictionary: [
                "CFBundleShortVersionString": "1.3.0",
                "TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.daily.rawValue,
            ],
            fetchData: { _ in
                throw URLError(.notConnectedToInternet)
            }
        )

        await service.fetchRegistry(force: true)

        XCTAssertEqual(service.fetchState, .loaded)
        XCTAssertEqual(service.registry.map(\.id), ["com.typewhisper.cached"])
    }
}
