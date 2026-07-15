import Foundation
import Combine

@MainActor
final class HomeViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: HomeViewModel?
    static var shared: HomeViewModel {
        guard let instance = _shared else {
            fatalError("HomeViewModel not initialized")
        }
        return instance
    }

    @Published var recentTranscriptions: [TranscriptionRecord] = []
    @Published var navigateToHistory = false
    @Published var navigateToStatistics = false
    @Published var hasAnyTranscriptions = false
    @Published var showSetupWizard: Bool {
        didSet { UserDefaults.standard.set(!showSetupWizard, forKey: UserDefaultsKeys.setupWizardCompleted) }
    }

    private let historyService: HistoryService
    private let usageStatisticsService: UsageStatisticsService
    private var cancellables = Set<AnyCancellable>()
    private var refreshWorkItem: DispatchWorkItem?

    init(historyService: HistoryService, usageStatisticsService: UsageStatisticsService) {
        self.historyService = historyService
        self.usageStatisticsService = usageStatisticsService
        self.showSetupWizard = !UserDefaults.standard.bool(forKey: UserDefaultsKeys.setupWizardCompleted)

        setupBindings()
        refresh()
    }

    private func setupBindings() {
        historyService.$records
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)

        usageStatisticsService.$days
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func refresh() {
        let allRecords = historyService.records
        hasAnyTranscriptions = usageStatisticsService.hasAnyStatistics || !allRecords.isEmpty
        recentTranscriptions = Array(allRecords.prefix(3))
    }

    func completeSetupWizard() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.setupWizardCurrentStep)
        showSetupWizard = false
    }

    func resetSetupWizard() {
        UserDefaults.standard.set(0, forKey: UserDefaultsKeys.setupWizardCurrentStep)
        showSetupWizard = true
    }
}
