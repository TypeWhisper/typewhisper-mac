import Combine
import Foundation

enum HistoryRetranscriptionError: LocalizedError {
    case busy, audioMissing, unavailable, emptyResult, changed, confirmationRequired, invalidVersion

    var errorDescription: String? {
        switch self {
        case .busy: String(localized: "history.retranscribe.busy")
        case .audioMissing: String(localized: "history.retranscribe.audioMissing")
        case .unavailable: String(localized: "history.retranscribe.unavailable")
        case .emptyResult: String(localized: "history.retranscribe.empty")
        case .changed: String(localized: "history.retranscribe.changed")
        case .confirmationRequired: String(localized: "history.retranscribe.confirmationRequired")
        case .invalidVersion: String(localized: "history.retranscribe.invalidVersion")
        }
    }
}

/// The lease remains held until even a non-cooperative provider returns after cancel.
/// Other entry points must not start recording or change the shared engine meanwhile.
@MainActor
enum HistoryRetranscriptionActivity {
    private static let recordIDSubject = CurrentValueSubject<UUID?, Never>(nil)
    static var recordID: UUID? {
        get { recordIDSubject.value }
        set { recordIDSubject.send(newValue) }
    }
    static var recordIDPublisher: AnyPublisher<UUID?, Never> {
        recordIDSubject.eraseToAnyPublisher()
    }
    @TaskLocal static var ownsEngine = false

    static func checkEngineAccess() throws {
        if recordID != nil, !ownsEngine { throw HistoryRetranscriptionError.busy }
    }
}

@MainActor
final class HistoryRetranscriptionService: ObservableObject {
    struct Request: Equatable {
        var engineID: String
        var modelID: String?
        var language: String?
        var workflowID: UUID?
    }

    struct Plan {
        let requiresCloudConfirmation: Bool
        var cloudProviders: [String] = []
        var confirmedRequest: Request?
        let run: @MainActor ([Float]) async throws -> HistoryTranscriptionVersion
    }

    typealias PlanBuilder = @MainActor (Request) throws -> Plan
    @Published private(set) var runningRecordID: UUID?
    @Published private(set) var isCancelling = false
    @Published private(set) var errorMessage: String?
    private let history: HistoryService
    private let planBuilder: PlanBuilder
    private let isBusy: @MainActor () -> Bool
    private let loadAudio: @MainActor (URL) async throws -> [Float]
    private let retrieveAudio: @MainActor (TranscriptionRecord) async throws -> URL
    private let canRetrieveAudio: @MainActor (TranscriptionRecord) -> Bool
    private var task: Task<Void, Never>?

    init(
        history: HistoryService,
        planBuilder: @escaping PlanBuilder,
        isBusy: @escaping @MainActor () -> Bool,
        loadAudio: @escaping @MainActor (URL) async throws -> [Float],
        canRetrieveAudio: @escaping @MainActor (TranscriptionRecord) -> Bool = { _ in false },
        retrieveAudio: @escaping @MainActor (TranscriptionRecord) async throws -> URL = { _ in
            throw HistoryRetranscriptionError.audioMissing
        }
    ) {
        self.history = history
        self.planBuilder = planBuilder
        self.isBusy = isBusy
        self.loadAudio = loadAudio
        self.canRetrieveAudio = canRetrieveAudio
        self.retrieveAudio = retrieveAudio
    }

    func hasLocalAudio(_ record: TranscriptionRecord) -> Bool {
        guard let url = history.audioFileURL(for: record),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    func canRun(_ record: TranscriptionRecord) -> Bool {
        hasLocalAudio(record) || canRetrieveAudio(record)
    }

    func previewPlan(_ request: Request) throws -> Plan {
        var plan = try planBuilder(request)
        plan.confirmedRequest = request
        return plan
    }

    func start(
        record: TranscriptionRecord, request: Request,
        cloudConfirmed: Bool, downloadConfirmed: Bool, confirmedPlan: Plan? = nil
    ) {
        guard runningRecordID == nil else { return }
        errorMessage = nil
        do {
            guard HistoryRetranscriptionActivity.recordID == nil, !isBusy() else {
                throw HistoryRetranscriptionError.busy
            }
            guard history.record(withID: record.id) === record, !record.isDeleted else {
                throw HistoryRetranscriptionError.changed
            }
            _ = try record.savedTranscriptionVersions() // Never replace a corrupt archive.
            let expected = HistoryTranscriptionVersion.capture(record)
            let audioIdentity = (record.audioFileName, record.remoteAudioSHA256, record.remoteAudioRelativePath, record.durationSeconds)
            let recordIsUnchanged = { @MainActor [history] in
                history.record(withID: expected.id) === record && !record.isDeleted
                    && HistoryTranscriptionVersion.capture(record) == expected
                    && record.audioFileName == audioIdentity.0 && record.remoteAudioSHA256 == audioIdentity.1
                    && record.remoteAudioRelativePath == audioIdentity.2 && record.durationSeconds == audioIdentity.3
            }
            if let confirmedPlan, confirmedPlan.confirmedRequest != request {
                throw HistoryRetranscriptionError.confirmationRequired
            }
            let plan = try confirmedPlan ?? planBuilder(request) // Freeze choices before the first suspension.
            guard !plan.requiresCloudConfirmation || cloudConfirmed else {
                throw HistoryRetranscriptionError.confirmationRequired
            }
            let localURL = hasLocalAudio(record) ? history.audioFileURL(for: record) : nil
            guard localURL != nil || (canRetrieveAudio(record) && downloadConfirmed) else {
                throw HistoryRetranscriptionError.confirmationRequired
            }
            HistoryRetranscriptionActivity.recordID = record.id
            runningRecordID = record.id
            task = Task { [self] in
                defer {
                    HistoryRetranscriptionActivity.recordID = nil
                    runningRecordID = nil
                    isCancelling = false
                    task = nil
                }
                do {
                    let audioURL: URL
                    if let localURL { audioURL = localURL }
                    else { audioURL = try await retrieveAudio(record) }
                    defer { if localURL == nil { try? FileManager.default.removeItem(at: audioURL) } }
                    try Task.checkCancellation()
                    guard localURL != nil || canRetrieveAudio(record) else {
                        throw HistoryRetranscriptionError.changed
                    }
                    let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
                    let samples = try await loadAudio(audioURL)
                    try Task.checkCancellation()
                    guard !samples.isEmpty else { throw HistoryRetranscriptionError.audioMissing }
                    guard recordIsUnchanged() else {
                        throw HistoryRetranscriptionError.changed
                    }
                    let version = try await HistoryRetranscriptionActivity.$ownsEngine.withValue(true) {
                        try await plan.run(samples)
                    }
                    try Task.checkCancellation()
                    let currentAttributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
                    guard recordIsUnchanged(), localURL != nil || canRetrieveAudio(record) else {
                        throw HistoryRetranscriptionError.changed
                    }
                    guard attributes[.size] as? Int == currentAttributes[.size] as? Int,
                          attributes[.modificationDate] as? Date == currentAttributes[.modificationDate] as? Date else {
                        throw HistoryRetranscriptionError.changed
                    }
                    try history.appendTranscriptionVersion(version, to: record, expected: expected)
                } catch {
                    if !Task.isCancelled { errorMessage = error.localizedDescription }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        guard task != nil else { return }
        isCancelling = true
        task?.cancel()
    }

    func promote(_ versionID: UUID, in record: TranscriptionRecord) {
        do {
            guard runningRecordID == nil else { throw HistoryRetranscriptionError.busy }
            try history.promoteTranscriptionVersion(versionID, in: record)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func discard(_ versionID: UUID, in record: TranscriptionRecord) {
        do {
            guard runningRecordID == nil else { throw HistoryRetranscriptionError.busy }
            try history.discardTranscriptionVersion(versionID, in: record)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
