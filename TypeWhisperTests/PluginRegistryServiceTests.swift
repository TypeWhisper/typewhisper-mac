import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class PluginRegistryServiceTests: XCTestCase {
    private let sdkCompatibilityVersion = "v1"

    func testFlatRegistryEntryWithoutReleasesDoesNotResolve() throws {
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
                  "description": "Legacy flat entry",
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
                  "detailsURL": "https://typewhisper.com/addons/multi",
                  "homepageURL": "http://example.com/multi",
                  "iconURL": "https://www.typewhisper.com/brand-logos/example/logo.svg",
                  "iconDarkURL": "https://www.typewhisper.com/brand-logos/example/logo-dark.svg",
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
        XCTAssertEqual(plugins.first?.detailsURL, "https://typewhisper.com/addons/multi")
        XCTAssertEqual(plugins.first?.homepageURL, "http://example.com/multi")
        XCTAssertEqual(plugins.first?.iconURL, "https://www.typewhisper.com/brand-logos/example/logo.svg")
        XCTAssertEqual(plugins.first?.iconDarkURL, "https://www.typewhisper.com/brand-logos/example/logo-dark.svg")
    }

    func testRegistryPluginIgnoresInvalidOptionalLinkMetadata() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.typewhisper.links",
                  "name": "Links Plugin",
                  "author": "TypeWhisper",
                  "description": "Invalid link metadata should not block the registry.",
                  "category": "utility",
                  "detailsURL": "not a url",
                  "homepageURL": 42,
                  "iconURL": "http://example.com/icon.svg",
                  "iconDarkURL": ["https://example.com/icon-dark.svg"],
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.0.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/links.zip"
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
        XCTAssertNil(plugins.first?.detailsURL)
        XCTAssertNil(plugins.first?.homepageURL)
        XCTAssertNil(plugins.first?.iconURL)
        XCTAssertNil(plugins.first?.iconDarkURL)
    }

    func testTopLevelReleaseMetadataDoesNotAffectMultiReleaseMatching() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.typewhisper.future",
                  "name": "Future Plugin",
                  "author": "TypeWhisper",
                  "description": "New releases are gated by host version.",
                  "category": "transcription",
                  "version": "9.9.9",
                  "minHostVersion": "1.0.0",
                  "sdkCompatibilityVersion": "v1",
                  "size": 1,
                  "downloadURL": "https://example.com/stale-top-level.zip",
                  "releases": [
                    {
                      "version": "1.2.0",
                      "minHostVersion": "1.4.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 20,
                      "downloadURL": "https://example.com/requires-1.4.zip"
                    },
                    {
                      "version": "1.1.6",
                      "minHostVersion": "1.2.2",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/compatible-1.3.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let pre14Plugins = response.resolvedPlugins(
            appVersion: "1.3.3",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )
        let plugins14 = response.resolvedPlugins(
            appVersion: "1.4.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(pre14Plugins.first?.version, "1.1.6")
        XCTAssertEqual(pre14Plugins.first?.downloadURL, "https://example.com/compatible-1.3.zip")
        XCTAssertEqual(plugins14.first?.version, "1.2.0")
        XCTAssertEqual(plugins14.first?.downloadURL, "https://example.com/requires-1.4.zip")
    }

    func testRegistryEntryDecodesMultipleCategoryIdentifiers() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.typewhisper.multi-capability",
                  "name": "Multi Capability Plugin",
                  "author": "TypeWhisper",
                  "description": "Transcribes and provides LLM processing.",
                  "category": "transcription",
                  "categories": ["transcription", "llm", "memory"],
                  "capabilities": ["source-footage-progress", "source-footage-progress", "  future-capability  ", ""],
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.4.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/plugin.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.4.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins.first?.category, "transcription")
        XCTAssertEqual(plugins.first?.categories, ["transcription", "llm", "memory"])
        XCTAssertEqual(plugins.first?.capabilities, ["source-footage-progress", "future-capability"])
        XCTAssertEqual(plugins.first?.supportsCapability(.sourceFootageProgress), true)
    }

    func testReleaseScopedCapabilitiesDoNotMarkLegacyCompatibleReleaseAsSourceProgressCapable() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.typewhisper.whisperkit",
                  "name": "WhisperKit",
                  "author": "TypeWhisper",
                  "description": "Local speech-to-text powered by WhisperKit.",
                  "category": "transcription",
                  "capabilities": ["source-footage-progress"],
                  "releases": [
                    {
                      "version": "1.0.24",
                      "minHostVersion": "1.4.0",
                      "sdkCompatibilityVersion": "v1",
                      "capabilities": [],
                      "size": 10,
                      "downloadURL": "https://example.com/whisperkit-1.0.24.zip"
                    },
                    {
                      "version": "1.0.25",
                      "minHostVersion": "1.5.0",
                      "sdkCompatibilityVersion": "v1",
                      "capabilities": ["source-footage-progress"],
                      "size": 12,
                      "downloadURL": "https://example.com/whisperkit-1.0.25.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let pre15Plugin = try XCTUnwrap(response.resolvedPlugins(
            appVersion: "1.4.9",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        ).first)
        let plugin15 = try XCTUnwrap(response.resolvedPlugins(
            appVersion: "1.5.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        ).first)

        XCTAssertEqual(pre15Plugin.version, "1.0.24")
        XCTAssertFalse(pre15Plugin.supportsCapability(.sourceFootageProgress))
        XCTAssertEqual(plugin15.version, "1.0.25")
        XCTAssertTrue(plugin15.supportsCapability(.sourceFootageProgress))
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

    func testRegistryEntryWithCloudHostingOverridesAPIKeyRequirementForClassification() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.typewhisper.openai",
                  "name": "OpenAI / ChatGPT",
                  "author": "TypeWhisper",
                  "description": "Cloud transcription plus OpenAI/ChatGPT prompts.",
                  "category": "transcription",
                  "hosting": "cloud",
                  "requiresAPIKey": false,
                  "releases": [
                    {
                      "version": "1.1.5",
                      "minHostVersion": "1.2.2",
                      "sdkCompatibilityVersion": "v1",
                      "size": 20,
                      "downloadURL": "https://example.com/openai.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugin = try XCTUnwrap(response.resolvedPlugins(
            appVersion: "1.3.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        ).first)

        XCTAssertEqual(plugin.hosting, .cloud)
        XCTAssertEqual(plugin.requiresAPIKey, false)
        XCTAssertEqual(plugin.resolvedHosting, .cloud)
    }

    func testRegistryEntryWithoutHostingFallsBackToAPIKeyRequirementForClassification() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "plugins": [
                {
                  "id": "com.typewhisper.remote",
                  "name": "Remote Plugin",
                  "author": "TypeWhisper",
                  "description": "Remote entry",
                  "category": "transcription",
                  "requiresAPIKey": true,
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.0.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/remote.zip"
                    }
                  ]
                },
                {
                  "id": "com.typewhisper.local",
                  "name": "Local Plugin",
                  "author": "TypeWhisper",
                  "description": "Local entry",
                  "category": "transcription",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.0.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/local.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.3.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        let remote = try XCTUnwrap(plugins.first { $0.id == "com.typewhisper.remote" })
        let local = try XCTUnwrap(plugins.first { $0.id == "com.typewhisper.local" })
        XCTAssertNil(remote.hosting)
        XCTAssertEqual(remote.resolvedHosting, .cloud)
        XCTAssertNil(local.hosting)
        XCTAssertEqual(local.resolvedHosting, .local)
    }

    @MainActor
    func testDownloadAndInstallReportsFailureForIncompatiblePlugin() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let service = PluginRegistryService(
            registryBaseURL: URL(string: "https://example.com")!,
            cacheDirectory: cacheDirectory,
            fetchData: { _ in
                throw URLError(.badServerResponse)
            }
        )
        let plugin = RegistryPlugin(
            id: "com.typewhisper.incompatible",
            source: .official,
            name: "Incompatible Plugin",
            version: "1.0.0",
            minHostVersion: "1.0.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion,
            minOSVersion: "99.0",
            supportedArchitectures: nil,
            author: "TypeWhisper",
            description: "Requires a future macOS version.",
            category: "utility",
            categories: ["utility"],
            size: 10,
            downloadURL: "https://example.com/plugin.zip",
            iconSystemName: nil,
            requiresAPIKey: nil,
            hosting: nil,
            descriptions: nil,
            downloadCount: nil
        )

        let installed = await service.downloadAndInstall(plugin)

        XCTAssertFalse(installed)
        XCTAssertEqual(
            service.installStates[plugin.id],
            .error("Plugin is not compatible with this Mac")
        )
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
                  "author": "TypeWhisper",
                  "description": "Entry without releases",
                  "category": "utility",
                  "size": 10
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

    func testRegistryFeedUsesV1ForPre14Builds() {
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.2.2",
                releaseChannel: .stable
            ),
            .v1
        )
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.2.2",
                releaseChannel: .releaseCandidate
            ),
            .v1
        )
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.2.2",
                releaseChannel: .daily
            ),
            .v1
        )
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.3.0",
                releaseChannel: .releaseCandidate
            ),
            .v1
        )
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.3.0",
                releaseChannel: .daily
            ),
            .v1
        )
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.3.0",
                releaseChannel: .stable
            ),
            .v1
        )
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.3.1",
                releaseChannel: .stable
            ),
            .v1
        )
    }

    func testRegistryFeedUsesCommunityFeedFor14PreviewAndStableBuilds() {
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.4.0-rc1",
                releaseChannel: .releaseCandidate
            ),
            .communityV1
        )
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.4.0",
                releaseChannel: .daily
            ),
            .communityV1
        )
        XCTAssertEqual(
            PluginRegistryService.registryFeed(
                appVersion: "1.4.0",
                releaseChannel: .stable
            ),
            .communityV1
        )
    }

    func testRegistryPluginSourceDefaultsToOfficialAndDecodesCommunity() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.typewhisper.official",
                  "name": "Official Plugin",
                  "author": "TypeWhisper",
                  "description": "Official entry",
                  "category": "utility",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.4.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 10,
                      "downloadURL": "https://example.com/official.zip"
                    }
                  ]
                },
                {
                  "id": "com.community.volcengine",
                  "source": "community",
                  "name": "Community Plugin",
                  "author": "Community Author",
                  "description": "Community entry",
                  "category": "llm",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.4.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 12,
                      "downloadURL": "https://github.com/TypeWhisper/typewhisper-mac/releases/download/plugin-community-v1.0.0/CommunityPlugin.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.4.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertEqual(plugins.map(\.source), [.official, .community])
    }

    func testCommunityPluginWithExternalDownloadURLDoesNotResolve() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.community.external",
                  "source": "community",
                  "name": "External Community Plugin",
                  "author": "Community Author",
                  "description": "Community entry with an external ZIP.",
                  "category": "utility",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.4.0",
                      "sdkCompatibilityVersion": "v1",
                      "size": 12,
                      "downloadURL": "https://github.com/contributor/plugin/releases/download/v1.0.0/Plugin.zip"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.4.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertTrue(plugins.isEmpty)
    }

    func testCommunityPluginSourceMetadataWithoutReleasesDoesNotResolve() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "com.community.source-only",
                  "source": "community",
                  "name": "Source Only Community Plugin",
                  "author": "Community Author",
                  "description": "Reviewed source without a published artifact.",
                  "category": "utility"
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(PluginRegistryResponse.self, from: data)
        let plugins = response.resolvedPlugins(
            appVersion: "1.4.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion
        )

        XCTAssertTrue(plugins.isEmpty)
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

    @MainActor
    func testHostFingerprintChangeForcesRegistryRefreshInsideThrottleWindow() async throws {
        let suiteName = "PluginRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginRegistryFingerprint")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            TestSupport.remove(cacheDirectory)
        }

        var requestCount = 0
        let service = PluginRegistryService(
            registryBaseURL: URL(string: "https://example.com")!,
            cacheDirectory: cacheDirectory,
            cacheDuration: 0,
            userDefaults: defaults,
            infoDictionary: [
                "CFBundleShortVersionString": "1.4.0",
                "TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.stable.rawValue,
            ],
            fetchData: { request in
                requestCount += 1
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Self.registryPayload(pluginId: "com.typewhisper.fingerprint"), response)
            }
        )
        let now = Date(timeIntervalSince1970: 2_000)

        let initialFetch = await service.refreshRegistryForHostUpdateIfNeeded(currentFingerprint: "1.4.0+803@stable", now: now)
        let throttledFetch = await service.refreshRegistryForHostUpdateIfNeeded(
            currentFingerprint: "1.4.0+803@stable",
            now: now.addingTimeInterval(60)
        )
        let fingerprintFetch = await service.refreshRegistryForHostUpdateIfNeeded(
            currentFingerprint: "1.4.1+804@stable",
            now: now.addingTimeInterval(120)
        )

        XCTAssertTrue(initialFetch)
        XCTAssertFalse(throttledFetch)
        XCTAssertTrue(fingerprintFetch)
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testUnchangedHostFingerprintPreservesBackgroundUpdateThrottle() async throws {
        let suiteName = "PluginRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginRegistryFingerprintThrottle")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            TestSupport.remove(cacheDirectory)
        }

        var requestCount = 0
        let service = PluginRegistryService(
            registryBaseURL: URL(string: "https://example.com")!,
            cacheDirectory: cacheDirectory,
            cacheDuration: 0,
            userDefaults: defaults,
            infoDictionary: [
                "CFBundleShortVersionString": "1.4.0",
                "TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.stable.rawValue,
            ],
            fetchData: { request in
                requestCount += 1
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Self.registryPayload(pluginId: "com.typewhisper.throttle"), response)
            }
        )
        let now = Date(timeIntervalSince1970: 3_000)

        let initialFetch = await service.refreshRegistryForHostUpdateIfNeeded(currentFingerprint: "1.4.0+803@stable", now: now)
        let throttledFetch = await service.refreshRegistryForHostUpdateIfNeeded(
            currentFingerprint: "1.4.0+803@stable",
            now: now.addingTimeInterval(23 * 3600)
        )
        let expiredFetch = await service.refreshRegistryForHostUpdateIfNeeded(
            currentFingerprint: "1.4.0+803@stable",
            now: now.addingTimeInterval(25 * 3600)
        )

        XCTAssertTrue(initialFetch)
        XCTAssertFalse(throttledFetch)
        XCTAssertTrue(expiredFetch)
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testHostFingerprintRefreshDoesNotAdvanceThrottleWhenOnlyCacheFallbackLoads() async throws {
        let suiteName = "PluginRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginRegistryFingerprintCacheFallback")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            TestSupport.remove(cacheDirectory)
        }

        try Self.registryPayload(pluginId: "com.typewhisper.cached-fallback")
            .write(to: cacheDirectory.appendingPathComponent("plugins-community-v1.json"))

        var requestCount = 0
        let service = PluginRegistryService(
            registryBaseURL: URL(string: "https://example.com")!,
            cacheDirectory: cacheDirectory,
            cacheDuration: 0,
            userDefaults: defaults,
            infoDictionary: [
                "CFBundleShortVersionString": "1.4.0",
                "TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.stable.rawValue,
            ],
            fetchData: { _ in
                requestCount += 1
                throw URLError(.notConnectedToInternet)
            }
        )
        let now = Date(timeIntervalSince1970: 4_000)

        let fallbackFetch = await service.refreshRegistryForHostUpdateIfNeeded(
            currentFingerprint: "1.4.0+803@stable",
            now: now
        )
        let retryFetch = await service.refreshRegistryForHostUpdateIfNeeded(
            currentFingerprint: "1.4.0+803@stable",
            now: now.addingTimeInterval(60)
        )

        XCTAssertFalse(fallbackFetch)
        XCTAssertFalse(retryFetch)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(service.fetchState, .loaded)
        XCTAssertEqual(service.registry.map(\.id), ["com.typewhisper.cached-fallback"])
    }

    private static func registryPayload(pluginId: String) -> Data {
        Data(
            """
            {
              "schemaVersion": 1,
              "plugins": [
                {
                  "id": "\(pluginId)",
                  "name": "Cached Plugin",
                  "author": "TypeWhisper",
                  "description": "Cacheable entry",
                  "category": "utility",
                  "releases": [
                    {
                      "version": "1.0.0",
                      "minHostVersion": "1.4.0",
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
    }
}
