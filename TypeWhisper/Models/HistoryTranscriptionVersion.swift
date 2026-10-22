import Foundation

/// A saved run owns its text and alignment data. Promoting a run never reuses another
/// run's word times or speaker assignments. Legacy entries become the original lazily.
/// Microphone-channel evidence belongs to the recording and survives every promotion.
struct HistoryTranscriptionVersion: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var rawText: String
    var finalText: String
    var engineID: String
    var engineName: String?
    var modelID: String?
    var modelName: String?
    var language: String?
    var requestedLanguage: String?
    var workflowID: UUID?
    var workflowName: String?
    var workflowConfiguration: Data?
    var workflowRecorded: Bool = false
    var pipelineSteps: String?
    var renderedDocument: String?
    var structuredDocumentData: Data?
    var speakerTranscriptStateRaw: String?
    var speakerTranscriptData: Data?
    var speakerNamesData: Data?
    var timedTextData: Data?
    var timedTextGranularityRaw: String?
    var speakerWordsData: Data?
    var speakerWordsAreFromSecondPass: Bool?
    var processingStateRaw: String?
    var processingFailureCategory: String?
    var processingFailureMessage: String?
    /// The LLM requests behind this version's text (`HistoryLLMUsage` as JSON).
    /// Nil for versions saved before this existed.
    var llmUsageData: Data?

    static func capture(_ record: TranscriptionRecord, provenance: Self? = nil) -> Self {
        Self(
            id: record.id, createdAt: record.timestamp,
            rawText: record.rawText, finalText: record.finalText,
            engineID: record.engineUsed, engineName: provenance?.engineName,
            modelID: provenance?.modelID, modelName: record.modelUsed,
            language: record.language, requestedLanguage: provenance?.requestedLanguage,
            workflowID: provenance?.workflowID, workflowName: provenance?.workflowName,
            workflowConfiguration: provenance?.workflowConfiguration,
            workflowRecorded: provenance?.workflowRecorded ?? false,
            pipelineSteps: record.pipelineSteps,
            renderedDocument: record.renderedDocument,
            structuredDocumentData: record.structuredDocumentData,
            speakerTranscriptStateRaw: record.speakerTranscriptStateRaw,
            speakerTranscriptData: record.speakerTranscriptData,
            speakerNamesData: record.speakerNamesData,
            timedTextData: record.timedTextData,
            timedTextGranularityRaw: record.timedTextGranularityRaw,
            speakerWordsData: record.speakerWordsData,
            speakerWordsAreFromSecondPass: record.speakerWordsAreFromSecondPass,
            processingStateRaw: record.processingStateRaw,
            processingFailureCategory: record.processingFailureCategory,
            processingFailureMessage: record.processingFailureMessage,
            llmUsageData: record.llmUsageData
        )
    }

    func apply(to record: TranscriptionRecord) {
        record.rawText = rawText
        record.finalText = finalText
        record.engineUsed = engineID
        record.modelUsed = modelName ?? modelID
        record.language = language
        record.pipelineSteps = pipelineSteps
        record.renderedDocument = renderedDocument
        record.structuredDocumentData = structuredDocumentData
        record.speakerTranscriptStateRaw = speakerTranscriptStateRaw
        record.speakerTranscriptData = speakerTranscriptData
        record.speakerNamesData = speakerNamesData
        record.timedTextData = timedTextData
        record.timedTextGranularityRaw = timedTextGranularityRaw
        record.speakerWordsData = speakerWordsData
        record.speakerWordsAreFromSecondPass = speakerWordsAreFromSecondPass
        record.processingStateRaw = processingStateRaw ?? RecordingProcessingState.ready.rawValue
        record.processingFailureCategory = processingFailureCategory
        record.processingFailureMessage = processingFailureMessage
        record.llmUsageData = llmUsageData
    }

    func matchesContent(of record: TranscriptionRecord) -> Bool {
        // Compare just the materialized fields; provenance belongs to the saved run.
        var current = Self.capture(record, provenance: self)
        current.id = id
        current.createdAt = createdAt
        var expected = self
        expected.modelName = modelName ?? modelID
        expected.processingStateRaw = processingStateRaw ?? RecordingProcessingState.ready.rawValue
        return current == expected
    }

    func isActive(in record: TranscriptionRecord) -> Bool {
        id == (record.activeTranscriptionVersionID ?? record.id) && matchesContent(of: record)
    }

    func canDiscard(in record: TranscriptionRecord) -> Bool {
        id != record.id && !isActive(in: record)
    }
}

extension TranscriptionRecord {
    func savedTranscriptionVersions() throws -> [HistoryTranscriptionVersion] {
        guard let transcriptionVersionsData else { return [] }
        return try JSONDecoder().decode([HistoryTranscriptionVersion].self, from: transcriptionVersionsData)
    }
}
