import Foundation
import XCTest
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
@testable import ContributorPlugin

final class ContributorPluginTests: XCTestCase {
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
}
