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

@MainActor
final class SettingsNavigationCoordinator: ObservableObject {
    nonisolated(unsafe) static var shared: SettingsNavigationCoordinator!

    @Published private(set) var request: SettingsNavigationRequest?

    func navigate(to tab: SettingsTab, licenseTarget: LicenseSettingsNavigationTarget? = nil) {
        request = SettingsNavigationRequest(tab: tab, licenseTarget: licenseTarget)
    }

    func navigateToLicense(target: LicenseSettingsNavigationTarget) {
        navigate(to: .license, licenseTarget: target)
    }
}
