import Foundation
import XCTest
@_spi(Testing) import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import WebhookPlugin

final class WebhookPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testSaveMovesSensitiveHeadersToSecrets() throws {
        let host = try PluginTestHostServices()
        let service = ExampleWebhookService(dataDirectory: host.pluginDataDirectory, host: host)
        let webhook = ExampleWebhookConfig(
            name: "Secure Hook",
            url: "https://example.com/hook",
            headers: [
                "Authorization": "Bearer local-token",
                "Content-Type": "application/json",
                "X-API-Key": "api-key-value",
            ]
        )

        service.addWebhook(webhook)

        let storedData = try Data(contentsOf: configURL(for: host))
        let storedRaw = String(decoding: storedData, as: UTF8.self)
        XCTAssertFalse(storedRaw.contains("Bearer local-token"))
        XCTAssertFalse(storedRaw.contains("api-key-value"))

        let persisted = try XCTUnwrap(try JSONDecoder().decode([ExampleWebhookConfig].self, from: storedData).first)
        XCTAssertEqual(persisted.headers["Authorization"], ExampleWebhookConfig.secretHeaderPlaceholder)
        XCTAssertEqual(persisted.headers["X-API-Key"], ExampleWebhookConfig.secretHeaderPlaceholder)
        XCTAssertEqual(persisted.headers["Content-Type"], "application/json")
        XCTAssertEqual(Set(persisted.secretHeaderNames), ["Authorization", "X-API-Key"])
        XCTAssertEqual(
            host.loadSecret(key: ExampleWebhookService.secretStorageKey(
                webhookID: webhook.id,
                headerName: "Authorization"
            )),
            "Bearer local-token"
        )
        XCTAssertEqual(
            host.loadSecret(key: ExampleWebhookService.secretStorageKey(
                webhookID: webhook.id,
                headerName: "X-API-Key"
            )),
            "api-key-value"
        )
    }

    func testNewDraftIsNotPersistedUntilSaved() throws {
        let host = try PluginTestHostServices()
        let service = ExampleWebhookService(dataDirectory: host.pluginDataDirectory, host: host)
        var draft = ExampleWebhookConfig()

        XCTAssertTrue(service.webhooks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL(for: host).path))

        draft.name = "New Hook"
        draft.url = "https://example.com/new"
        service.saveWebhook(draft)

        XCTAssertEqual(service.webhooks.map(\.id), [draft.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL(for: host).path))
    }

    func testSaveWebhookUpdatesExistingWebhookWithoutDuplicatingIt() throws {
        let host = try PluginTestHostServices()
        let service = ExampleWebhookService(dataDirectory: host.pluginDataDirectory, host: host)
        var webhook = ExampleWebhookConfig(name: "Original", url: "https://example.com/original")

        service.saveWebhook(webhook)
        webhook.name = "Updated"
        webhook.url = "https://example.com/updated"
        service.saveWebhook(webhook)

        XCTAssertEqual(service.webhooks.count, 1)
        XCTAssertEqual(service.webhooks.first?.id, webhook.id)
        XCTAssertEqual(service.webhooks.first?.name, "Updated")
        XCTAssertEqual(service.webhooks.first?.url, "https://example.com/updated")
    }

    func testWebhookEditorPresentationHandlesAddEditAndDismiss() throws {
        var presentation = ExampleWebhookEditorPresentation()

        XCTAssertNil(presentation.editingWebhook)

        presentation.beginAddingWebhook()
        XCTAssertTrue(try XCTUnwrap(presentation.editingWebhook).isUnmodifiedDefaultDraft)

        presentation.dismissEditor()
        XCTAssertNil(presentation.editingWebhook)

        let existingWebhook = ExampleWebhookConfig(
            name: "Existing Hook",
            url: "https://example.com/existing"
        )
        presentation.beginEditingWebhook(existingWebhook)
        XCTAssertEqual(presentation.editingWebhook?.id, existingWebhook.id)
    }

    func testLoadRemovesOnlyUnmodifiedDefaultDrafts() throws {
        let host = try PluginTestHostServices()
        let emptyDraft = ExampleWebhookConfig()
        let namedDraft = ExampleWebhookConfig(name: "Keep Me")
        let configuredWebhook = ExampleWebhookConfig(
            name: "Configured",
            url: "https://example.com/configured"
        )
        let configData = try JSONEncoder().encode([emptyDraft, namedDraft, configuredWebhook])
        try configData.write(to: configURL(for: host), options: .atomic)

        let service = ExampleWebhookService(dataDirectory: host.pluginDataDirectory, host: host)

        XCTAssertEqual(Set(service.webhooks.map(\.id)), Set([namedDraft.id, configuredWebhook.id]))

        let storedData = try Data(contentsOf: configURL(for: host))
        let persisted = try JSONDecoder().decode([ExampleWebhookConfig].self, from: storedData)
        XCTAssertEqual(Set(persisted.map(\.id)), Set([namedDraft.id, configuredWebhook.id]))
    }

    func testLoadMigratesLegacyPlaintextSensitiveHeaders() throws {
        let host = try PluginTestHostServices()
        let legacyWebhook = ExampleWebhookConfig(
            name: "Legacy Hook",
            url: "https://example.com/hook",
            headers: [
                "Authorization": "Bearer legacy-token",
                "Content-Type": "application/json",
            ]
        )
        let configData = try JSONEncoder().encode([legacyWebhook])
        try configData.write(to: configURL(for: host), options: .atomic)

        let service = ExampleWebhookService(dataDirectory: host.pluginDataDirectory, host: host)

        XCTAssertEqual(service.webhooks.first?.headers["Authorization"], "Bearer legacy-token")
        XCTAssertEqual(
            host.loadSecret(key: ExampleWebhookService.secretStorageKey(
                webhookID: legacyWebhook.id,
                headerName: "Authorization"
            )),
            "Bearer legacy-token"
        )

        let storedData = try Data(contentsOf: configURL(for: host))
        let storedRaw = String(decoding: storedData, as: UTF8.self)
        XCTAssertFalse(storedRaw.contains("Bearer legacy-token"))

        let persisted = try XCTUnwrap(try JSONDecoder().decode([ExampleWebhookConfig].self, from: storedData).first)
        XCTAssertEqual(persisted.headers["Authorization"], ExampleWebhookConfig.secretHeaderPlaceholder)
        XCTAssertEqual(persisted.secretHeaderNames, ["Authorization"])
    }

    func testBlankSensitiveHeaderClearsSecretAndDoesNotReloadOrSend() async throws {
        let host = try PluginTestHostServices()
        let service = ExampleWebhookService(dataDirectory: host.pluginDataDirectory, host: host)
        let webhook = ExampleWebhookConfig(
            name: "Rotated Hook",
            url: "https://example.com/hook",
            headers: [
                "Authorization": "Bearer old-token",
                "Content-Type": "application/json",
            ]
        )
        let storageKey = ExampleWebhookService.secretStorageKey(
            webhookID: webhook.id,
            headerName: "Authorization"
        )

        service.addWebhook(webhook)
        XCTAssertEqual(host.loadSecret(key: storageKey), "Bearer old-token")

        var updated = try XCTUnwrap(service.webhooks.first)
        updated.headers["Authorization"] = ""
        service.updateWebhook(updated)

        XCTAssertEqual(host.loadSecret(key: storageKey), "")

        let storedData = try Data(contentsOf: configURL(for: host))
        let storedRaw = String(decoding: storedData, as: UTF8.self)
        XCTAssertFalse(storedRaw.contains("Bearer old-token"))

        let persisted = try XCTUnwrap(try JSONDecoder().decode([ExampleWebhookConfig].self, from: storedData).first)
        XCTAssertNil(persisted.headers["Authorization"])
        XCTAssertFalse(persisted.secretHeaderNames.contains("Authorization"))

        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com/hook")!,
            statusCode: 204,
            httpVersion: nil,
            headerFields: nil
        ))
        let sessionStore = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            sessionStore.makeSession(outcomes: [.success(Data(), response)])
        }

        let reloadedService = ExampleWebhookService(dataDirectory: host.pluginDataDirectory, host: host)
        XCTAssertNil(reloadedService.webhooks.first?.headers["Authorization"])

        await reloadedService.sendWebhooks(for: TranscriptionCompletedPayload(
            rawText: "raw",
            finalText: "final",
            engineUsed: "test",
            durationSeconds: 1,
            ruleName: nil
        ))

        let request = try XCTUnwrap(sessionStore.sessions.first?.requestedRequests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testSendUsesRestoredSensitiveHeaders() async throws {
        let host = try PluginTestHostServices()
        let webhook = ExampleWebhookConfig(
            name: "Restored Hook",
            url: "https://example.com/hook",
            headers: [
                "Authorization": ExampleWebhookConfig.secretHeaderPlaceholder,
                "Content-Type": "application/json",
            ],
            secretHeaderNames: ["Authorization"]
        )
        try host.storeSecret(
            key: ExampleWebhookService.secretStorageKey(
                webhookID: webhook.id,
                headerName: "Authorization"
            ),
            value: "Bearer restored-token"
        )
        let configData = try JSONEncoder().encode([webhook])
        try configData.write(to: configURL(for: host), options: .atomic)

        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com/hook")!,
            statusCode: 204,
            httpVersion: nil,
            headerFields: nil
        ))
        let sessionStore = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            sessionStore.makeSession(outcomes: [.success(Data(), response)])
        }

        let service = ExampleWebhookService(dataDirectory: host.pluginDataDirectory, host: host)
        await service.sendWebhooks(for: TranscriptionCompletedPayload(
            rawText: "raw",
            finalText: "final",
            engineUsed: "test",
            durationSeconds: 1,
            ruleName: nil
        ))

        let request = try XCTUnwrap(sessionStore.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer restored-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    private func configURL(for host: PluginTestHostServices) -> URL {
        host.pluginDataDirectory.appendingPathComponent("webhooks.json")
    }
}
