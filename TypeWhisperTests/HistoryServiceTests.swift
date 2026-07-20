import XCTest
@testable import TypeWhisper

final class HistoryServiceTests: XCTestCase {
    @MainActor
    func testAddSearchUniqueDomainsAndPurgeHistory() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = HistoryService(appSupportDirectory: appSupportDirectory)
        service.clearAll()
        let usageStatisticsService = UsageStatisticsService(appSupportDirectory: appSupportDirectory)

        service.addRecord(
            rawText: "Weekly planning meeting",
            finalText: "Weekly planning meeting",
            appName: "Safari",
            appBundleIdentifier: "com.apple.Safari",
            appURL: "https://www.github.com/TypeWhisper/typewhisper-mac",
            durationSeconds: 12,
            language: "en",
            engineUsed: "parakeet",
            audioSamples: Array(repeating: 0.25, count: 1600)
        )
        service.addRecord(
            rawText: "Older note",
            finalText: "Older note",
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            durationSeconds: 8,
            language: "en",
            engineUsed: "parakeet"
        )

        XCTAssertEqual(service.records.count, 2)
        XCTAssertEqual(service.searchRecords(query: "planning").count, 1)
        XCTAssertEqual(service.uniqueDomains(), ["github.com"])
        XCTAssertNotNil(service.audioFileURL(for: service.records.first { $0.audioFileName != nil }!))

        let staleRecord = try XCTUnwrap(service.records.first(where: { $0.finalText == "Older note" }))
        staleRecord.timestamp = Calendar.current.date(byAdding: .day, value: -120, to: Date())!
        service.updateRecord(staleRecord, finalText: staleRecord.finalText)
        usageStatisticsService.backfillFromHistoryIfNeeded(service.records)

        service.purgeOldRecords(retentionDays: 30)

        XCTAssertEqual(service.records.count, 1)
        XCTAssertEqual(service.totalRecords, 1)
        XCTAssertEqual(service.totalWords, 3)

        let allTimeUsage = usageStatisticsService.summary(from: nil)
        XCTAssertEqual(allTimeUsage.transcriptionCount, 2)
        XCTAssertEqual(allTimeUsage.words, 5)
        XCTAssertEqual(allTimeUsage.appCount, 2)
    }

    func testTrainingCaptureStoreWritesJSONLWhenEnabled() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let store = TrainingCaptureStore(
            captureDirectory: appSupportDirectory.appendingPathComponent("TrainingCapture", isDirectory: true),
            enabledProvider: { true }
        )
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.record(TrainingCaptureRecord(
            id: id,
            createdAt: createdAt,
            locale: "de_DE",
            configuredLanguage: "de",
            detectedLanguage: "de",
            engineUsed: "qwen3",
            modelId: "qwen3-asr",
            modelDisplayName: "Qwen3",
            workflowId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            workflowName: "Cleaned Text",
            outputFormat: nil,
            pipelineSteps: ["Workflow"],
            rawText: "ähm morgen um neun",
            finalText: "Morgen um 9 Uhr.",
            insertedText: "Morgen um 9 Uhr.",
            targetApp: TrainingCaptureRecord.TargetApp(
                name: "Notes",
                bundleIdentifier: "com.apple.Notes"
            )
        ))

        let contents = try String(contentsOf: store.captureFileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TrainingCaptureRecord.self, from: Data(lines[0].utf8))

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.recordType, "accepted-candidate")
        XCTAssertNil(decoded.parentId)
        XCTAssertEqual(decoded.source, "typewhisper-mac-dev-dictation")
        XCTAssertEqual(decoded.locale, "de_DE")
        XCTAssertEqual(decoded.configuredLanguage, "de")
        XCTAssertEqual(decoded.detectedLanguage, "de")
        XCTAssertEqual(decoded.engineUsed, "qwen3")
        XCTAssertEqual(decoded.modelId, "qwen3-asr")
        XCTAssertEqual(decoded.modelDisplayName, "Qwen3")
        XCTAssertEqual(decoded.workflowName, "Cleaned Text")
        XCTAssertEqual(decoded.pipelineSteps, ["Workflow"])
        XCTAssertEqual(decoded.rawText, "ähm morgen um neun")
        XCTAssertEqual(decoded.finalText, "Morgen um 9 Uhr.")
        XCTAssertEqual(decoded.insertedText, "Morgen um 9 Uhr.")
        XCTAssertNil(decoded.correctedText)
        XCTAssertNil(decoded.commitSignal)
        XCTAssertEqual(decoded.accepted, true)
        XCTAssertEqual(decoded.reviewed, false)
        XCTAssertEqual(decoded.targetApp?.bundleIdentifier, "com.apple.Notes")
    }

    func testTrainingCaptureStoreWritesManualCorrectionJSONLWhenEnabled() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let store = TrainingCaptureStore(
            captureDirectory: appSupportDirectory.appendingPathComponent("TrainingCapture", isDirectory: true),
            enabledProvider: { true }
        )
        let parentID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let parent = TrainingCaptureRecord(
            id: parentID,
            locale: "de_DE",
            configuredLanguage: "de",
            detectedLanguage: "de",
            engineUsed: "reson8",
            modelId: "dictation-model",
            modelDisplayName: "TypeWhisper Dictation Model",
            workflowId: nil,
            workflowName: nil,
            outputFormat: nil,
            pipelineSteps: [],
            rawText: "Ich kaufe ein Auto.",
            finalText: "Ich kaufe ein Auto.",
            insertedText: "Ich kaufe ein Auto.",
            targetApp: nil
        )

        let correctionID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        store.record(parent.manualCorrection(
            correctionId: correctionID,
            correctedText: "Ich kaufe kein Auto.",
            commitSignal: .returnKey
        ))

        let contents = try String(contentsOf: store.captureFileURL, encoding: .utf8)
        let line = try XCTUnwrap(contents.split(separator: "\n").first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TrainingCaptureRecord.self, from: Data(line.utf8))

        XCTAssertEqual(decoded.id, correctionID)
        XCTAssertEqual(decoded.recordType, "manual-correction")
        XCTAssertEqual(decoded.parentId, parentID)
        XCTAssertEqual(decoded.rawText, "Ich kaufe ein Auto.")
        XCTAssertEqual(decoded.insertedText, "Ich kaufe ein Auto.")
        XCTAssertEqual(decoded.correctedText, "Ich kaufe kein Auto.")
        XCTAssertEqual(decoded.commitSignal, "return-key")
        XCTAssertEqual(decoded.accepted, false)
        XCTAssertEqual(decoded.reviewed, true)
    }

    func testTrainingCaptureStoreSkipsWhenDisabled() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let store = TrainingCaptureStore(
            captureDirectory: appSupportDirectory.appendingPathComponent("TrainingCapture", isDirectory: true),
            enabledProvider: { false }
        )

        store.record(TrainingCaptureRecord(
            locale: "de_DE",
            configuredLanguage: "de",
            detectedLanguage: "de",
            engineUsed: "qwen3",
            modelId: nil,
            modelDisplayName: nil,
            workflowId: nil,
            workflowName: nil,
            outputFormat: nil,
            pipelineSteps: [],
            rawText: "test",
            finalText: "Test.",
            insertedText: "Test.",
            targetApp: nil
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.captureFileURL.path))
    }
}
