import Combine
import Foundation
import ServiceManagement

@MainActor
protocol LoginItemRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemRegistering {}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var lastErrorDescription: String?

    private let service: any LoginItemRegistering

    init(service: any LoginItemRegistering = SMAppService.mainApp) {
        self.service = service
        refreshStatus()
    }

    func setUserChoice(_ enabled: Bool) {
        defer { refreshStatus() }
        lastErrorDescription = nil
        guard enabled != (isEnabled || requiresApproval) else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    func refreshStatus() {
        let status = service.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }
}
