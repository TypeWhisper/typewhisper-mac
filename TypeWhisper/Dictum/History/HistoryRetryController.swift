import Combine
import Foundation

@MainActor
final class HistoryRetryController: ObservableObject {
    @Published var message: String?
    @Published var confirmation: String?
    @Published private(set) var isRunning = false
    private var pending: (TranscriptionRecord, HistoryRetranscriptionService.Request, HistoryRetranscriptionService.Plan)?
    private var active: (record: TranscriptionRecord, versions: Set<UUID>)?
    private var observation: AnyCancellable?
    private let container: ServiceContainer

    init(container: ServiceContainer = .shared) {
        self.container = container
        observation = container.historyRetranscriptionService.$runningRecordID.sink { [weak self] id in
            guard id == nil else { return }
            Task { @MainActor [weak self] in self?.finish() }
        }
    }

    func request(_ record: TranscriptionRecord) {
        guard !isRunning else { return }
        do {
            let engineID = container.modelManagerService.selectedProviderId ?? ""
            let engine = PluginManager.shared?.transcriptionEngine(for: engineID)
            let request = HistoryRetranscriptionService.Request(
                engineID: engineID, modelID: engine?.selectedModelId,
                language: HistoryRetranscriptionEnvironment.supportedLanguage(record.language, modelID: engine?.selectedModelId, engine: engine),
                workflowID: container.workflowService.matchWorkflow(bundleIdentifier: record.appBundleIdentifier, url: record.appURL)?.workflow.id,
                appBundleIdentifier: record.appBundleIdentifier, appURL: record.appURL)
            let plan = try container.historyRetranscriptionService.previewPlan(request)
            pending = (record, request, plan)
            if plan.requiresCloudConfirmation { confirmation = plan.cloudProviders.joined(separator: " · ") }
            else { start() }
        } catch { message = error.localizedDescription }
    }

    func cancelConfirmation() { pending = nil; confirmation = nil }

    func start() {
        guard let (record, request, plan) = pending else { return }
        pending = nil
        confirmation = nil
        do {
            active = (record, Set(try record.savedTranscriptionVersions().map(\.id)))
            isRunning = true
            message = String(localized: "Reprocessing with current settings…", table: "DictumHistory")
            container.historyRetranscriptionService.start(record: record, request: request, cloudConfirmed: true, downloadConfirmed: false, confirmedPlan: plan)
            if container.historyRetranscriptionService.runningRecordID == nil { finish() }
        } catch { message = error.localizedDescription; isRunning = false; active = nil }
    }

    private func finish() {
        guard let active, container.historyRetranscriptionService.runningRecordID == nil else { return }
        self.active = nil
        isRunning = false
        if let error = container.historyRetranscriptionService.errorMessage { message = error; return }
        do {
            guard let version = try active.record.savedTranscriptionVersions().last(where: { !active.versions.contains($0.id) && $0.id != active.record.id }) else { return }
            try container.historyService.promoteTranscriptionVersion(version.id, in: active.record)
            message = String(localized: "Reprocessed", table: "DictumHistory")
        } catch { message = error.localizedDescription }
    }
}
