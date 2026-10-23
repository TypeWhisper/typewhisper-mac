import Combine
import Foundation

struct SettingsNavigationRequest: Identifiable, Equatable {
    let id = UUID()
    let tab: SettingsTab
}

enum RecorderSettingsPart: Hashable, CaseIterable, Sendable {
    case recorder, meetings
}

enum HistorySettingsPart: Hashable, CaseIterable, Sendable {
    case history, sync
}

enum DictionarySettingsPart: Hashable, CaseIterable, Sendable {
    case dictionary, learning
}

@MainActor
final class SettingsNavigationCoordinator: ObservableObject {
    nonisolated(unsafe) static var shared: SettingsNavigationCoordinator!
    @Published private(set) var request: SettingsNavigationRequest?
    @Published var recorderPart: RecorderSettingsPart = .recorder
    @Published var historyPart: HistorySettingsPart = .history
    @Published var dictionaryPart: DictionarySettingsPart = .dictionary

    func navigate(to feature: PremiumFeatureID) {
        switch feature {
        case .calendarMeeting:
            recorderPart = .meetings
            navigate(to: .recorder)
        case .correctionLearning:
            dictionaryPart = .learning
            navigate(to: .dictionary)
        case .cloudSync:
            historyPart = .sync
            navigate(to: .history)
        case .speakerWorkspace:
            navigate(to: .speakers)
        }
    }

    func navigate(to tab: SettingsTab) {
        request = SettingsNavigationRequest(tab: tab)
    }
}
