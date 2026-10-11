import Foundation
import Combine

@MainActor
final class RemoteLinkViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: RemoteLinkViewModel?
    static var shared: RemoteLinkViewModel {
        guard let instance = _shared else {
            fatalError("RemoteLinkViewModel not initialized")
        }
        return instance
    }

    enum PairingState: Equatable {
        case closed
        case waiting
        case confirming(RemoteLinkPairingRequest)
        case finishing(RemoteLinkPairingRequest)
        case paired(String)
        case failed
    }

    @Published private(set) var isEnabled: Bool
    @Published var isWritingAllowed: Bool {
        didSet { defaults.set(isWritingAllowed, forKey: UserDefaultsKeys.remoteLinkWritingAllowed) }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isAdvertised = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var devices: [RemoteLinkDevice] = []
    @Published private(set) var pairingState: PairingState = .closed

    let computerName = RemoteLinkServer.computerName()

    private let server: RemoteLinkServer
    private let defaults: UserDefaults
    private let premiumAccess: @MainActor () -> Bool
    private var premiumObservation: AnyCancellable?
    private var approval: (request: RemoteLinkPairingRequest, continuation: CheckedContinuation<Bool, Never>)?

    init(
        server: RemoteLinkServer,
        defaults: UserDefaults = .standard,
        premiumAccess: @escaping @MainActor () -> Bool = { true }
    ) {
        self.server = server
        self.defaults = defaults
        self.premiumAccess = premiumAccess
        isEnabled = defaults.bool(forKey: UserDefaultsKeys.remoteLinkEnabled)
        isWritingAllowed = defaults.bool(forKey: UserDefaultsKeys.remoteLinkWritingAllowed)
        devices = server.store.devices()

        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
        server.onAdvertisingChange = { [weak self] advertised in
            Task { @MainActor in self?.isAdvertised = advertised }
        }
        server.onDevicesChange = { [weak self] in
            Task { @MainActor in self?.reloadDevices() }
        }
        server.onPairingFinished = { [weak self] device in
            Task { @MainActor in self?.pairingFinished(device) }
        }
    }

    func startIfEnabled() {
        guard isEnabled, premiumAccess() else { return }
        start()
    }

    /// Paired devices are a Premium feature: losing access stops the listener,
    /// regaining it starts the listener again if the user had it on.
    func observePremiumChanges(_ changes: [AnyPublisher<Void, Never>]) {
        premiumObservation = Publishers.MergeMany(changes)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.premiumAccessChanged() }
    }

    func premiumAccessChanged() {
        if premiumAccess() {
            if isEnabled && !isRunning { start() }
        } else {
            // A listener that is still starting or waiting for Local Network
            // permission has not reported `isRunning` yet; stop it anyway.
            endPairing()
            stop()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: UserDefaultsKeys.remoteLinkEnabled)
        if enabled {
            start()
        } else {
            endPairing()
            stop()
        }
    }

    func stop() {
        server.stop()
        isRunning = false
        isAdvertised = false
    }

    func beginPairing() {
        pairingState = .waiting
        server.openPairing { [weak self] request in
            await self?.requestApproval(request) ?? false
        }
    }

    func endPairing() {
        server.closePairing()
        resolveApproval(false)
        pairingState = .closed
    }

    func approvePairing() {
        guard case .confirming(let request) = pairingState else { return }
        pairingState = .finishing(request)
        resolveApproval(true)
    }

    func denyPairing() {
        resolveApproval(false)
        pairingState = .waiting
    }

    func removeDevice(_ device: RemoteLinkDevice) {
        devices.removeAll { $0.id == device.id }
        let server = server
        Task.detached {
            server.removeDevice(id: device.id)
        }
    }

    private func start() {
        guard premiumAccess() else { return }
        errorMessage = nil
        do {
            try server.start()
        } catch {
            errorMessage = error.localizedDescription
            isRunning = false
        }
    }

    private func apply(_ state: RemoteLinkServer.State) {
        switch state {
        case .ready:
            isRunning = true
            errorMessage = nil
        case .stopped:
            isRunning = false
            isAdvertised = false
        case .failed(let message):
            isRunning = false
            isAdvertised = false
            errorMessage = message
        }
    }

    private func reloadDevices() {
        devices = server.store.devices()
    }

    private func requestApproval(_ request: RemoteLinkPairingRequest) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resolveApproval(false)
                guard !Task.isCancelled, pairingState != .closed else {
                    continuation.resume(returning: false)
                    return
                }
                approval = (request, continuation)
                pairingState = .confirming(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelApproval(for: request)
            }
        }
    }

    private func cancelApproval(for request: RemoteLinkPairingRequest) {
        guard approval?.request == request else { return }
        resolveApproval(false)
        if pairingState == .confirming(request) {
            pairingState = .failed
        }
    }

    private func resolveApproval(_ decision: Bool) {
        guard let pending = approval else { return }
        approval = nil
        pending.continuation.resume(returning: decision)
    }

    private func pairingFinished(_ device: RemoteLinkDevice?) {
        guard pairingState != .closed else { return }
        if let device {
            pairingState = .paired(device.name)
        } else if case .waiting = pairingState {
            return
        } else {
            pairingState = .failed
        }
    }
}
