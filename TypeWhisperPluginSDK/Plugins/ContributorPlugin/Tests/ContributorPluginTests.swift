import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import ContributorPlugin

final class ContributorPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testPluginIdentity() {
        XCTAssertEqual(ContributorPlugin.pluginId, "com.typewhisper.improve")
        XCTAssertEqual(ContributorPlugin.pluginName, "Improve TypeWhisper")
        XCTAssertEqual(
            ContributorPlugin.contributionPolicyURL.absoluteString,
            "https://www.typewhisper.com/addons/improve-typewhisper/"
        )
    }

    func testQueuePersistsOnlyCorrectionPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContributorPluginTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContributorQueueStore(rootDirectory: directory)
        let record = makeRecord()

        XCTAssertTrue(try store.insert(record))
        var submittedRecord = record
        submittedRecord.status = .pending
        try store.upsert(submittedRecord)
        XCTAssertFalse(try store.insert(record))
        XCTAssertEqual(try store.loadRecords(), [submittedRecord])

        let fileURL = directory
            .appendingPathComponent("pending")
            .appendingPathComponent("\(record.id.uuidString.lowercased()).json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertNil(object["targetApp"])
        XCTAssertNil(object["bundleIdentifier"])
        XCTAssertNil(object["url"])
        XCTAssertNil(object["audio"])
    }

    func testQueueUsesPrivateFilePermissions() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ContributorPluginPermissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let pendingDirectory = directory.appendingPathComponent("pending", isDirectory: true)
        let receiptsDirectory = directory.appendingPathComponent("receipts", isDirectory: true)
        let store = ContributorQueueStore(rootDirectory: directory)
        let record = makeRecord()
        let pendingFile = pendingDirectory
            .appendingPathComponent("\(record.id.uuidString.lowercased()).json")

        XCTAssertTrue(try store.insert(record))
        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: pendingDirectory), 0o700)
        XCTAssertEqual(try permissions(at: receiptsDirectory), 0o700)
        XCTAssertEqual(try permissions(at: pendingFile), 0o600)

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pendingDirectory.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pendingFile.path)
        _ = try store.loadRecords()

        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: pendingDirectory), 0o700)
        XCTAssertEqual(try permissions(at: pendingFile), 0o600)

        var acceptedRecord = record
        acceptedRecord.status = .accepted
        try store.complete(acceptedRecord)
        let receiptFile = receiptsDirectory
            .appendingPathComponent("\(record.id.uuidString.lowercased()).json")
        XCTAssertEqual(try permissions(at: receiptFile), 0o600)
    }

    func testQueueSkipsCorruptPendingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContributorPluginCorruptQueue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContributorQueueStore(rootDirectory: directory)
        let record = makeRecord()

        XCTAssertTrue(try store.insert(record))
        let corruptFile = directory
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("corrupt.json")
        try Data("not-json".utf8).write(to: corruptFile)

        XCTAssertEqual(try store.loadRecords(), [record])
    }

    @MainActor
    func testPluginCapturesEventOnlyWhenEnabled() async throws {
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(
            defaults: ["collectCorrections": true],
            eventBus: eventBus
        )
        let plugin = ContributorPlugin()
        plugin.activate(host: host)

        await eventBus.emit(.textCorrectionCommitted(makePayload()))

        XCTAssertEqual(plugin.records.count, 1)
        XCTAssertEqual(plugin.records.first?.correctedText, "Ich kaufe kein Auto.")
        XCTAssertTrue(plugin.selectedIds.isEmpty)
        plugin.deactivate()
    }

    @MainActor
    func testPluginDoesNotCaptureEventWhenDisabled() async throws {
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(eventBus: eventBus)
        let plugin = ContributorPlugin()
        plugin.activate(host: host)

        await eventBus.emit(.textCorrectionCommitted(makePayload()))

        XCTAssertTrue(plugin.records.isEmpty)
        plugin.deactivate()
    }

    @MainActor
    func testPluginRenewsStaleContributorTokenAfterAuthenticationFailure() async throws {
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(
            defaults: ["collectCorrections": true],
            secrets: ["contributor-token": "stale-token"],
            eventBus: eventBus
        )
        let plugin = ContributorPlugin()
        plugin.activate(host: host)
        await eventBus.emit(.textCorrectionCommitted(makePayload()))
        plugin.selectedIds = [makePayload().id]
        plugin.sendConfirmed = true

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":"Not authenticated."}"#.utf8),
                    Self.httpResponse(path: "/v1/contributions/batches", statusCode: 401)
                ),
                .success(
                    Data(
                        #"""
                        {
                          "contributorId": "66666666-6666-4666-8666-666666666666",
                          "token": "fresh-token"
                        }
                        """#.utf8
                    ),
                    Self.httpResponse(path: "/v1/contributors/session", statusCode: 201)
                ),
                .success(
                    Data(
                        #"""
                        {
                          "batchId": "77777777-7777-4777-8777-777777777777",
                          "records": [{
                            "id": "55555555-5555-4555-8555-555555555555",
                            "status": "pending",
                            "reason_code": null,
                            "quality_credit": 0
                          }]
                        }
                        """#.utf8
                    ),
                    Self.httpResponse(path: "/v1/contributions/batches", statusCode: 201)
                ),
            ])
        }

        plugin.sendSelected()
        for _ in 0..<1_000 where plugin.isWorking {
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertFalse(plugin.isWorking)
        XCTAssertEqual(host.loadSecret(key: "contributor-token"), "fresh-token")
        XCTAssertEqual(plugin.records.first?.status, .pending)
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.map(\.url?.path), [
            "/v1/contributions/batches",
            "/v1/contributors/session",
            "/v1/contributions/batches",
        ])
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Authorization"),
            "Contributor stale-token"
        )
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "Authorization"),
            "Contributor fresh-token"
        )
        plugin.deactivate()
    }

    func testUploadShapeExcludesContext() throws {
        let request = ContributionBatchRequest(
            batchId: UUID(),
            consentVersion: "contribution-text-v1",
            pluginVersion: "0.1.0",
            records: [makeRecord()]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        )
        let contributions = try XCTUnwrap(object["contributions"] as? [[String: Any]])
        let contribution = try XCTUnwrap(contributions.first)
        XCTAssertNil(contribution["targetApp"])
        XCTAssertNil(contribution["bundleIdentifier"])
        XCTAssertNil(contribution["url"])
        XCTAssertNil(contribution["audio"])
    }

    private func makeRecord() -> ContributionRecord {
        ContributionRecord(payload: makePayload())
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func makePayload() -> TextCorrectionCommittedPayload {
        TextCorrectionCommittedPayload(
            id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
            capturedAt: Date(timeIntervalSince1970: 1_721_476_800),
            originalText: "Ich kaufe ein Auto.",
            correctedText: "Ich kaufe kein Auto.",
            language: "de",
            engineId: "reson8",
            modelId: "typewhisper",
            appVersion: "1.6.0",
            appBuild: "160",
            platformVersion: "macOS 26.0",
            commitSignal: "return-key",
            sourceChannel: .development
        )
    }

    private static func httpResponse(path: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://app.typewhisper.com\(path)")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}
