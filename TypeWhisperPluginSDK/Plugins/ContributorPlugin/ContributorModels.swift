import Foundation
import TypeWhisperPluginSDK

enum ContributionLocalStatus: String, Codable, Sendable {
    case local
    case pending
    case accepted
    case rejected
    case quarantined

    var isRemote: Bool {
        self != .local
    }

    var isTerminal: Bool {
        self == .accepted || self == .rejected
    }
}

struct ContributionRecord: Codable, Identifiable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let capturedAt: Date
    let originalText: String
    let correctedText: String
    let language: String?
    let engineId: String
    let modelId: String?
    let appVersion: String
    let appBuild: String
    let platformVersion: String
    let commitSignal: String?
    let sourceChannel: TextCorrectionCommittedPayload.SourceChannel
    var status: ContributionLocalStatus
    var reasonCode: String?
    var qualityCredit: Int

    init(
        payload: TextCorrectionCommittedPayload,
        status: ContributionLocalStatus = .local,
        reasonCode: String? = nil,
        qualityCredit: Int = 0
    ) {
        self.schemaVersion = payload.schemaVersion
        self.id = payload.id
        self.capturedAt = payload.capturedAt
        self.originalText = payload.originalText
        self.correctedText = payload.correctedText
        self.language = payload.language
        self.engineId = payload.engineId
        self.modelId = payload.modelId
        self.appVersion = payload.appVersion
        self.appBuild = payload.appBuild
        self.platformVersion = payload.platformVersion
        self.commitSignal = payload.commitSignal
        self.sourceChannel = payload.sourceChannel
        self.status = status
        self.reasonCode = reasonCode
        self.qualityCredit = qualityCredit
    }

    var isValidCorrection: Bool {
        schemaVersion == 1
            && !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && originalText != correctedText
            && !engineId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ContributionReceipt: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let status: ContributionLocalStatus
    let reasonCode: String?
    let qualityCredit: Int
    let completedAt: Date
}

struct ContributionRemoteStatus: Codable, Sendable {
    let id: UUID
    let status: ContributionLocalStatus
    let reasonCode: String?
    let qualityCredit: Int

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case reasonCode = "reason_code"
        case qualityCredit = "quality_credit"
    }
}

struct ContributionSession: Codable, Sendable {
    let contributorId: UUID
    let token: String
}

struct ContributionBatchResponse: Codable, Sendable {
    let batchId: UUID
    let records: [ContributionRemoteStatus]
}

struct ContributionStatusResponse: Codable, Sendable {
    let records: [ContributionRemoteStatus]
}

private struct ContributionUploadRecord: Encodable {
    let schemaVersion: Int
    let id: UUID
    let capturedAt: Date
    let originalText: String
    let correctedText: String
    let language: String?
    let engineId: String
    let modelId: String?
    let appVersion: String
    let appBuild: String
    let platformVersion: String
    let commitSignal: String?
    let sourceChannel: TextCorrectionCommittedPayload.SourceChannel

    init(_ record: ContributionRecord) {
        schemaVersion = record.schemaVersion
        id = record.id
        capturedAt = record.capturedAt
        originalText = record.originalText
        correctedText = record.correctedText
        language = record.language
        engineId = record.engineId
        modelId = record.modelId
        appVersion = record.appVersion
        appBuild = record.appBuild
        platformVersion = record.platformVersion
        commitSignal = record.commitSignal
        sourceChannel = record.sourceChannel
    }
}

struct ContributionBatchRequest: Encodable {
    let batchId: UUID
    let consentVersion: String
    let pluginVersion: String
    private let contributions: [ContributionUploadRecord]

    init(
        batchId: UUID,
        consentVersion: String,
        pluginVersion: String,
        records: [ContributionRecord]
    ) {
        self.batchId = batchId
        self.consentVersion = consentVersion
        self.pluginVersion = pluginVersion
        self.contributions = records.map(ContributionUploadRecord.init)
    }
}
