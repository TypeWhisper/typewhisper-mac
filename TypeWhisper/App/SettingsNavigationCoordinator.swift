import Combine
import Foundation

enum LicenseSettingsNavigationTarget: Equatable, Sendable {
    case top
    case supporter
    case activationKey
}

struct SettingsNavigationRequest: Identifiable, Equatable {
    let id = UUID()
    let tab: SettingsTab
    let licenseTarget: LicenseSettingsNavigationTarget?
}

/// The parts of the Settings pages that host a Premium feature next to
/// their own content.
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

    /// Opens the Settings page where a Premium feature lives.
    func navigate(to destination: PremiumSettingsDestination) {
        switch destination {
        case .access:
            navigate(to: .premium)
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

    func navigate(to tab: SettingsTab, licenseTarget: LicenseSettingsNavigationTarget? = nil) {
        request = SettingsNavigationRequest(tab: tab, licenseTarget: licenseTarget)
    }

    func navigateToLicense(target: LicenseSettingsNavigationTarget) {
        navigate(to: .license, licenseTarget: target)
    }
}
