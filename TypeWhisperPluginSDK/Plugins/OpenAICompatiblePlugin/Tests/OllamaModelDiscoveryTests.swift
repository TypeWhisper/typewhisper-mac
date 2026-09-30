import Foundation
import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import OpenAICompatiblePlugin

final class OllamaModelDiscoveryTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    // MARK: - URL Resolution

    func testOllamaDiscoveryURLResolvesBareHostURL() throws {
        let url = try XCTUnwrap(OpenAICompatiblePlugin.ollamaDiscoveryURL(baseURL: "http://localhost:11434"))
        XCTAssertEqual(url.absoluteString, "http://localhost:11434/api/tags")
    }

    func testOllamaDiscoveryURLStripsV1Suffix() throws {
        let url = try XCTUnwrap(OpenAICompatiblePlugin.ollamaDiscoveryURL(baseURL: "http://localhost:11434/v1"))
        XCTAssertEqual(url.absoluteString, "http://localhost:11434/api/tags")
    }

    func testOllamaDiscoveryURLStripsTrailingSlashAndV1Suffix() throws {
        let url = try XCTUnwrap(OpenAICompatiblePlugin.ollamaDiscoveryURL(baseURL: "http://localhost:11434/v1/"))
        XCTAssertEqual(url.absoluteString, "http://localhost:11434/api/tags")
    }

    func testOllamaDiscoveryURLRejectsEmptyBaseURL() {
        XCTAssertNil(OpenAICompatiblePlugin.ollamaDiscoveryURL(baseURL: ""))
        XCTAssertNil(OpenAICompatiblePlugin.ollamaDiscoveryURL(baseURL: "   "))
    }

    // MARK: - Discovery

    func testFetchModelsUsesApiTagsForOllamaProfile() async throws {
        let (plugin, profileId) = try makeOllamaPlugin(baseURL: "http://localhost:11434")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"models":[{"name":"llama3.1:8b"},{"name":"qwen2.5:7b"}]}"#.utf8),
                    Self.httpResponse(url: "http://localhost:11434/api/tags", statusCode: 200)
                )
            ])
        }

        let models = await plugin.fetchModels(for: profileId)

        XCTAssertEqual(models.map(\.id), ["llama3.1:8b", "qwen2.5:7b"])
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/api/tags"])
        XCTAssertNil(store.sessions[0].requestedRequests.first?.url?.query)
        // Ollama needs no API key; none configured means no auth header.
        XCTAssertNil(store.sessions[0].requestedRequests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testOllamaDiscoveryPreservesModelNamesExactly() async throws {
        let (plugin, profileId) = try makeOllamaPlugin(baseURL: "http://localhost:11434")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"models":[{"name":"z-model:latest"},{"name":"a-model:8b-instruct-q4_K_M"},{"name":"Mixtral-8x7B"}]}"#.utf8),
                    Self.httpResponse(url: "http://localhost:11434/api/tags", statusCode: 200)
                )
            ])
        }

        let models = await plugin.fetchModels(for: profileId)

        XCTAssertEqual(models.map(\.id), ["Mixtral-8x7B", "a-model:8b-instruct-q4_K_M", "z-model:latest"])
    }

    func testDiscoverOllamaModelsReportsEmptyResult() async throws {
        let (plugin, profileId) = try makeOllamaPlugin(baseURL: "http://localhost:11434")

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientSessionStore().makeSession(outcomes: [
                .success(
                    Data(#"{"models":[]}"#.utf8),
                    Self.httpResponse(url: "http://localhost:11434/api/tags", statusCode: 200)
                )
            ])
        }

        let result = await plugin.discoverOllamaModels(for: profileId)

        XCTAssertEqual(result, .failure(.emptyResult))
    }

    func testDiscoverOllamaModelsReportsUnauthorized() async throws {
        let (plugin, profileId) = try makeOllamaPlugin(baseURL: "http://localhost:11434")

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientSessionStore().makeSession(outcomes: [
                .success(
                    Data(),
                    Self.httpResponse(url: "http://localhost:11434/api/tags", statusCode: 401)
                )
            ])
        }

        let result = await plugin.discoverOllamaModels(for: profileId)

        XCTAssertEqual(result, .failure(.unauthorized))
    }

    func testDiscoverOllamaModelsReportsDecodingFailure() async throws {
        let (plugin, profileId) = try makeOllamaPlugin(baseURL: "http://localhost:11434")

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientSessionStore().makeSession(outcomes: [
                .success(
                    Data("not json".utf8),
                    Self.httpResponse(url: "http://localhost:11434/api/tags", statusCode: 200)
                )
            ])
        }

        let result = await plugin.discoverOllamaModels(for: profileId)

        XCTAssertEqual(result, .failure(.decodingFailed))
    }

    func testDiscoverOllamaModelsReportsServerError() async throws {
        let (plugin, profileId) = try makeOllamaPlugin(baseURL: "http://localhost:11434")

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientSessionStore().makeSession(outcomes: [
                .success(
                    Data(),
                    Self.httpResponse(url: "http://localhost:11434/api/tags", statusCode: 500)
                )
            ])
        }

        let result = await plugin.discoverOllamaModels(for: profileId)

        XCTAssertEqual(result, .failure(.serverError(statusCode: 500)))
    }

    func testDiscoverOllamaModelsReportsConnectionFailure() async throws {
        let (plugin, profileId) = try makeOllamaPlugin(baseURL: "http://localhost:11434")

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientSessionStore().makeSession(outcomes: [
                .failure(URLError(.notConnectedToInternet))
            ])
        }

        let result = await plugin.discoverOllamaModels(for: profileId)

        XCTAssertEqual(result, .failure(.connectionFailed))
    }

    func testDiscoverOllamaModelsReportsInvalidURL() async throws {
        let host = try PluginTestHostServices()
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        let profile = plugin.addProfile()
        plugin.setServerKind(.ollama, for: profile.id)
        // No base URL configured.

        let result = await plugin.discoverOllamaModels(for: profile.id)

        XCTAssertEqual(result, .failure(.invalidURL))
    }

    // MARK: - Fallback

    func testOllamaDiscoveryEmptyResultFallsBackToV1Models() async throws {
        let (plugin, profileId) = try makeOllamaPlugin(baseURL: "http://localhost:11434")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"models":[]}"#.utf8),
                    Self.httpResponse(url: "http://localhost:11434/api/tags", statusCode: 200)
                ),
                .success(
                    Data(#"{"data":[{"id":"fallback-model"}]}"#.utf8),
                    Self.httpResponse(url: "http://localhost:11434/v1/models", statusCode: 200)
                ),
            ])
        }

        let models = await plugin.fetchModels(for: profileId)

        XCTAssertEqual(models.map(\.id), ["fallback-model"])
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/api/tags", "/v1/models"])
    }

    func testOllamaDiscoveryFailureFallsBackToV1Models() async throws {
        let (plugin, profileId) = try makeOllamaPlugin(baseURL: "http://localhost:11434")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(),
                    Self.httpResponse(url: "http://localhost:11434/api/tags", statusCode: 404)
                ),
                .success(
                    Data(#"{"data":[{"id":"fallback-model"}]}"#.utf8),
                    Self.httpResponse(url: "http://localhost:11434/v1/models", statusCode: 200)
                ),
            ])
        }

        let models = await plugin.fetchModels(for: profileId)

        XCTAssertEqual(models.map(\.id), ["fallback-model"])
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/api/tags", "/v1/models"])
    }

    // MARK: - Generic Profiles Untouched

    func testGenericProfileNeverProbesApiTags() async throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"data":[{"id":"gpt-model"}]}"#.utf8),
                    Self.httpResponse(url: "https://example.test/v1/models", statusCode: 200)
                )
            ])
        }

        let models = await plugin.fetchModels()

        XCTAssertEqual(models.map(\.id), ["gpt-model"])
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/v1/models"])
    }

    // MARK: - Persistence & Migration

    func testServerKindDefaultsToGenericForLegacyProfiles() throws {
        let savedProfiles = Data(
            """
            [
              {
                "id": "openai-compatible",
                "name": "OpenAI Compatible",
                "baseURL": "http://localhost:11434",
                "selectedModelId": "",
                "selectedLLMModelId": "",
                "llmTemperatureModeRaw": "providerDefault",
                "llmTemperatureValue": 0.3,
                "fetchedModels": []
              }
            ]
            """.utf8
        )
        let host = try PluginTestHostServices(defaults: ["profiles": savedProfiles])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        let profile = try XCTUnwrap(plugin.profileSnapshot(for: plugin.providerId))
        XCTAssertEqual(profile.serverKind, .generic)
    }

    func testServerKindPersistsAcrossActivation() throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "http://localhost:11434"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        plugin.setServerKind(.ollama)
        plugin.deactivate()

        let reloaded = OpenAICompatiblePlugin()
        reloaded.activate(host: host)

        XCTAssertEqual(reloaded.profileSnapshot(for: reloaded.providerId)?.serverKind, .ollama)
    }

    func testServerKindRoundTripsThroughJSON() throws {
        var profile = OpenAICompatibleProfile(id: "x", name: "y")
        XCTAssertEqual(profile.serverKind, .generic)

        profile.serverKindRaw = OpenAICompatibleServerKind.ollama.rawValue
        let decoded = try JSONDecoder().decode(
            OpenAICompatibleProfile.self,
            from: JSONEncoder().encode(profile)
        )
        XCTAssertEqual(decoded.serverKind, .ollama)
        XCTAssertEqual(decoded.serverKindRaw, "ollama")
    }

    func testSettingsRefreshUsesOneNativeRequestForModelsAndError() async throws {
        let (plugin, profileId) = try makeOllamaPlugin(baseURL: "http://localhost:11434")
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"models":[{"name":"first:latest"}]}"#.utf8),
                    Self.httpResponse(url: "http://localhost:11434/api/tags", statusCode: 200)
                ),
                .success(
                    Data(#"{"models":[{"name":"second:latest"}]}"#.utf8),
                    Self.httpResponse(url: "http://localhost:11434/api/tags", statusCode: 200)
                ),
            ])
        }

        let result = await plugin.fetchModelsWithDiscoveryError(for: profileId)

        XCTAssertEqual(result.models.map(\.id), ["first:latest"])
        XCTAssertNil(result.error)
        XCTAssertEqual(store.sessions.flatMap(\.requestedPaths), ["/api/tags"])
    }

    func testSettingsRefreshFallsBackWithoutRepeatingFailedNativeRequest() async throws {
        let (plugin, profileId) = try makeOllamaPlugin(baseURL: "http://localhost:11434")
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(),
                    Self.httpResponse(url: "http://localhost:11434/api/tags", statusCode: 401)
                ),
                .success(
                    Data(#"{"models":[{"name":"unexpected-second-native-result"}],"data":[{"id":"fallback-model"}]}"#.utf8),
                    Self.httpResponse(url: "http://localhost:11434/v1/models", statusCode: 200)
                ),
            ])
        }

        let result = await plugin.fetchModelsWithDiscoveryError(for: profileId)

        XCTAssertEqual(result.models.map(\.id), ["fallback-model"])
        XCTAssertEqual(result.error, .unauthorized)
        XCTAssertEqual(store.sessions.flatMap(\.requestedPaths), ["/api/tags", "/v1/models"])
    }

    func testSettingsRefreshNeverProbesNativeEndpointForGenericProfile() async throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"data":[{"id":"generic-model"}]}"#.utf8),
                    Self.httpResponse(url: "https://example.test/v1/models", statusCode: 200)
                ),
            ])
        }

        let result = await plugin.fetchModelsWithDiscoveryError(for: plugin.providerId)

        XCTAssertEqual(result.models.map(\.id), ["generic-model"])
        XCTAssertNil(result.error)
        XCTAssertEqual(store.sessions.flatMap(\.requestedPaths), ["/v1/models"])
    }

    // MARK: - Helpers

    private func makeOllamaPlugin(baseURL: String) throws -> (OpenAICompatiblePlugin, String) {
        let host = try PluginTestHostServices()
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        let profile = plugin.addProfile()
        plugin.setBaseURL(baseURL, for: profile.id)
        plugin.setServerKind(.ollama, for: profile.id)
        return (plugin, profile.id)
    }

    private static func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
