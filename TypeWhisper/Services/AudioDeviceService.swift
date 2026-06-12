import Foundation
import CoreAudio
import AudioToolbox
import AudioUnit
@preconcurrency import AVFoundation
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioDeviceService")

enum AudioInputDeviceCompatibilityIssue: Sendable, Equatable {
    case cannotSetDevice
    case invalidInputFormat
    case engineStartFailed

    var badgeText: String {
        localizedAppText("Not compatible", de: "Nicht kompatibel")
    }

    var detailText: String {
        switch self {
        case .cannotSetDevice, .invalidInputFormat, .engineStartFailed:
            return localizedAppText(
                "This microphone can't be used by TypeWhisper for preview or recording.",
                de: "Dieses Mikrofon kann von TypeWhisper nicht für Test oder Aufnahme verwendet werden."
            )
        }
    }
}

enum AudioInputDeviceCompatibility: Sendable, Equatable {
    case unknown
    case compatible
    case incompatible(AudioInputDeviceCompatibilityIssue)

    var diagnosticsValue: String {
        switch self {
        case .unknown:
            return "unknown"
        case .compatible:
            return "compatible"
        case .incompatible(let issue):
            return "incompatible:\(issue.diagnosticsValue)"
        }
    }
}

extension AudioInputDeviceCompatibilityIssue {
    var diagnosticsValue: String {
        switch self {
        case .cannotSetDevice:
            return "cannotSetDevice"
        case .invalidInputFormat:
            return "invalidInputFormat"
        case .engineStartFailed:
            return "engineStartFailed"
        }
    }
}

enum SelectedInputDeviceError: LocalizedError, Sendable, Equatable {
    case unavailable
    case incompatible(AudioInputDeviceCompatibilityIssue)
    case routingConflict

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return localizedAppText(
                "Selected input device is no longer available.",
                de: "Das ausgewählte Eingabegerät ist nicht mehr verfügbar."
            )
        case .incompatible(let issue):
            return issue.detailText
        case .routingConflict:
            return localizedAppText(
                "The selected microphone conflicts with your current audio routing. Disconnect Bluetooth or choose a different input.",
                de: "Das ausgewählte Mikrofon kollidiert mit deiner aktuellen Audio-Route. Trenne Bluetooth oder wähle ein anderes Eingabegerät."
            )
        }
    }

    var diagnosticsValue: String {
        switch self {
        case .unavailable:
            return "unavailable"
        case .incompatible(let issue):
            return "incompatible:\(issue.diagnosticsValue)"
        case .routingConflict:
            return "routingConflict"
        }
    }
}

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let deviceID: AudioDeviceID
    let name: String
    let uid: String
    var compatibility: AudioInputDeviceCompatibility = .unknown

    var id: String { uid }
}

struct AudioInputDiagnosticsReport: Encodable, Equatable, Sendable {
    struct Device: Encodable, Equatable, Sendable {
        let deviceID: UInt32
        let uid: String?
        let name: String?
        let inputChannels: Int
        let outputChannels: Int
        let nominalSampleRate: Double?
        let transportType: UInt32?
        let transportTypeName: String?
        let transportTypeFourCC: String?
        let isDefaultInput: Bool
        let isSelected: Bool
        let isAggregate: Bool
        let isVirtual: Bool
        let isAggregateOrVirtual: Bool
        let listedByTypeWhisper: Bool
        let compatibility: String
        let exclusionReason: String?
        let inputOnlyCaptureFormat: String?
        let inputOnlyCaptureFormatError: String?
    }

    let selectedInputDeviceUID: String?
    let selectedInputDeviceID: UInt32?
    let selectedInputDeviceName: String?
    let selectedInputUsesBluetoothTransport: Bool
    let previewActive: Bool
    let previewAudioLevel: Float
    let previewRawLevel: Float
    let previewError: String?
    let defaultInputDeviceID: UInt32?
    let lastInputOnlyCaptureFailure: AudioInputCaptureFailureDiagnostics?
    let devices: [Device]
}

struct AudioInputCaptureFailureDiagnostics: Encodable, Equatable, Sendable {
    let timestamp: Date
    let label: String
    let deviceID: UInt32
    let operation: String
    let status: Int32?
    let statusString: String?
    let errorDescription: String
    let formatSampleRate: Double
    let formatChannelCount: UInt32
}

enum AudioInputCaptureDiagnosticsStore {
    private struct State: Sendable {
        var lastInputOnlyCaptureFailure: AudioInputCaptureFailureDiagnostics?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func recordFailure(
        label: String,
        deviceID: AudioDeviceID,
        format: AVAudioFormat,
        error: Error
    ) {
        let operationError = error as? CoreAudioHALInputOperationError
        let status = operationError?.status
        let statusString: String?
        if let status {
            statusString = audioStatusString(status)
        } else {
            statusString = nil
        }
        let failure = AudioInputCaptureFailureDiagnostics(
            timestamp: Date(),
            label: label,
            deviceID: UInt32(deviceID),
            operation: operationError?.operation ?? "\(label) input-only capture",
            status: status,
            statusString: statusString,
            errorDescription: diagnosticsErrorDescription(error),
            formatSampleRate: format.sampleRate,
            formatChannelCount: format.channelCount
        )
        state.withLock { state in
            state.lastInputOnlyCaptureFailure = failure
        }
    }

    static func lastFailure() -> AudioInputCaptureFailureDiagnostics? {
        state.withLock { state in
            state.lastInputOnlyCaptureFailure
        }
    }

    static func clear() {
        state.withLock { state in
            state.lastInputOnlyCaptureFailure = nil
        }
    }

    private static func diagnosticsErrorDescription(_ error: Error) -> String {
        if let selectedInputError = error as? SelectedInputDeviceError {
            return selectedInputError.diagnosticsValue
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return (error as NSError).localizedDescription
    }
}

final class AudioDeviceService: ObservableObject, @unchecked Sendable {
    /// Serial OperationQueue used by the preview configuration-change
    /// observer. Its `underlyingQueue` is set to `previewRecoveryQueue` in
    /// `init` so that `AVAudioEngineConfigurationChange` notifications are
    /// serialized onto the same queue the recovery coordinator runs on,
    /// preserving the thread-confinement invariants of
    /// `AudioEngineRecoveryCoordinator`. Mirrors the pattern used by
    /// `AudioRecordingService.recoveryNotificationQueue`.
    private let previewNotificationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.typewhisper.preview-recovery.notifications"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedDeviceUID: String? {
        didSet {
            guard selectedDeviceUID != oldValue else { return }
            handleSelectedDeviceSelectionChange(from: oldValue, to: selectedDeviceUID)
        }
    }
    @Published var disconnectedDeviceName: String?
    @Published var isPreviewActive: Bool = false
    @Published var previewAudioLevel: Float = 0
    @Published var previewRawLevel: Float = 0
    @Published private(set) var previewError: SelectedInputDeviceError?

    var hasMicrophonePermissionOverride: Bool?
    var audioDeviceIDResolverOverride: ((String) -> AudioDeviceID?)?
    var selectionValidationOverride: ((AudioDeviceID?) throws -> Void)?
    var startPreviewOverride: ((AudioDeviceID?) throws -> Void)?
    private let inputActivationGuard: AudioInputDeviceActivating
    private let transportResolver: AudioDeviceTransportResolving
    private let bluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing
    private let selectionEngineValidator: AudioInputSelectionEngineValidating
    private let inputCaptureFactory: AudioInputCaptureFactory

    var selectedDeviceID: AudioDeviceID? {
        guard let uid = selectedDeviceUID else { return nil }
        if let audioDeviceIDResolverOverride {
            return audioDeviceIDResolverOverride(uid)
        }
        return Self.audioDeviceID(fromUID: uid)
    }

    var selectedDeviceUsesBluetoothTransport: Bool {
        guard let selectedDeviceID,
              let transportType = transportType(for: selectedDeviceID) else {
            return false
        }
        return Self.isBluetoothTransportType(transportType)
    }

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var previewEngine: AVAudioEngine?
    private var previewInputCaptureSession: AudioInputCaptureSession?
    private var previewConfigChangeObserver: NSObjectProtocol?
    private let deviceChangeSubject = PassthroughSubject<Void, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var disconnectVerificationTask: Task<Void, Never>?
    private let previewLock = NSLock()
    private let previewRecoveryQueue = DispatchQueue(label: "com.typewhisper.preview-recovery", qos: .userInitiated)
    private let previewRecoveryCoordinator = AudioEngineRecoveryCoordinator()
    /// Retains the outgoing preview `AVAudioEngine` for a short interval after
    /// teardown so CoreAudio's internal callbacks cannot outlive the object
    /// they still reference. Mirrors `AudioRecordingService.engineTeardownRetainer`.
    /// See issue #332.
    private let previewEngineTeardownRetainer = DelayedReleaseRetainer<AVAudioEngine>(label: "com.typewhisper.preview-engine-teardown")
    private static let previewEngineTeardownRetentionInterval: TimeInterval = 0.3
    private let outputVolumeGuard: AudioOutputVolumeGuard
    private var activePreviewDeviceID: AudioDeviceID?
    private var activePreviewUsesBluetoothTransport = false
    private var bluetoothPreviewConfigurationChangeIgnoreUntil: TimeInterval?
    private var compatibilityCache: [String: AudioInputDeviceCompatibility] = [:]
    private var isApplyingValidatedSelection = false
    private var isInitializingSelection = false
    private static let bluetoothPreviewConfigurationChangeIgnoreWindow: TimeInterval = 3.0

    private var hasMicrophonePermission: Bool {
        if let hasMicrophonePermissionOverride {
            return hasMicrophonePermissionOverride
        }
        return AVAudioApplication.shared.recordPermission == .granted
    }

    var selectedDevice: AudioInputDevice? {
        guard let selectedDeviceUID else { return nil }
        return inputDevices.first(where: { $0.uid == selectedDeviceUID })
    }

    var selectedDeviceCompatibility: AudioInputDeviceCompatibility? {
        selectedDevice?.compatibility
    }

    var selectedDeviceStatusMessage: String? {
        guard let selectedDevice else { return nil }
        switch selectedDevice.compatibility {
        case .incompatible(let issue):
            return "\(selectedDevice.name): \(issue.detailText)"
        case .unknown, .compatible:
            return nil
        }
    }

    func diagnosticsReport() -> AudioInputDiagnosticsReport {
        let defaultInputDeviceID = CoreAudioInputDeviceDefaultController().defaultInputDeviceID()
        var listedDevicesByID: [AudioDeviceID: AudioInputDevice] = [:]
        var listedDevicesByUID: [String: AudioInputDevice] = [:]
        for device in inputDevices {
            listedDevicesByID[device.deviceID] = device
            listedDevicesByUID[device.uid] = device
        }
        let selectedDeviceID = selectedDeviceID

        let devices = Self.allInputDeviceDiagnostics(
            selectedDeviceID: selectedDeviceID,
            selectedDeviceUID: selectedDeviceUID,
            defaultInputDeviceID: defaultInputDeviceID,
            listedDevicesByID: listedDevicesByID,
            listedDevicesByUID: listedDevicesByUID
        )
        let selectedInputDeviceID: UInt32?
        if let selectedDeviceID {
            selectedInputDeviceID = UInt32(selectedDeviceID)
        } else {
            selectedInputDeviceID = nil
        }
        let defaultInputDeviceIDValue: UInt32?
        if let defaultInputDeviceID {
            defaultInputDeviceIDValue = UInt32(defaultInputDeviceID)
        } else {
            defaultInputDeviceIDValue = nil
        }
        let selectedInputDeviceName = selectedDevice?.name
        let previewErrorValue = previewError?.diagnosticsValue
        let lastInputOnlyCaptureFailure = AudioInputCaptureDiagnosticsStore.lastFailure()

        return AudioInputDiagnosticsReport(
            selectedInputDeviceUID: selectedDeviceUID,
            selectedInputDeviceID: selectedInputDeviceID,
            selectedInputDeviceName: selectedInputDeviceName,
            selectedInputUsesBluetoothTransport: selectedDeviceUsesBluetoothTransport,
            previewActive: isPreviewActive,
            previewAudioLevel: previewAudioLevel,
            previewRawLevel: previewRawLevel,
            previewError: previewErrorValue,
            defaultInputDeviceID: defaultInputDeviceIDValue,
            lastInputOnlyCaptureFailure: lastInputOnlyCaptureFailure,
            devices: devices
        )
    }

    init(
        initialInputDevices: [AudioInputDevice]? = nil,
        monitorDeviceChanges: Bool = true,
        probeCompatibilities: Bool = false,
        outputVolumeGuard: AudioOutputVolumeGuard = AudioOutputVolumeGuard(),
        transportResolver: AudioDeviceTransportResolving = CoreAudioDeviceTransportResolver(),
        bluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing = CoreAudioBluetoothInputRouteStabilizer(),
        selectionEngineValidator: AudioInputSelectionEngineValidating = AVAudioInputSelectionEngineValidator(),
        inputCaptureFactory: AudioInputCaptureFactory = CoreAudioHALInputCaptureFactory(),
        inputActivationGuard: AudioInputDeviceActivating = AudioInputDeviceActivationGuard()
    ) {
        self.outputVolumeGuard = outputVolumeGuard
        self.transportResolver = transportResolver
        self.bluetoothInputRouteStabilizer = bluetoothInputRouteStabilizer
        self.selectionEngineValidator = selectionEngineValidator
        self.inputCaptureFactory = inputCaptureFactory
        self.inputActivationGuard = inputActivationGuard
        previewNotificationQueue.underlyingQueue = previewRecoveryQueue
        isInitializingSelection = true
        selectedDeviceUID = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        inputDevices = applyCompatibilityCache(to: initialInputDevices ?? listInputDevices())
        if monitorDeviceChanges {
            installDeviceListener()
        }
        if probeCompatibilities, let selectedDeviceUID {
            compatibilityCache[selectedDeviceUID] = .unknown
        }

        if monitorDeviceChanges {
            deviceChangeSubject
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
                .sink { [weak self] in
                    self?.handleDeviceChange()
                }
                .store(in: &cancellables)
        }
        isInitializingSelection = false
    }

    deinit {
        disconnectVerificationTask?.cancel()
        removeDeviceListener()
        stopPreview()
    }

    // MARK: - Audio Preview

    func startPreview() {
        guard !isPreviewActive else { return }
        previewError = nil
        guard hasMicrophonePermission else {
            logger.warning("Microphone permission not granted, cannot start preview")
            return
        }

        let preferredDeviceID = selectedDeviceID
        if let selectionError = selectedInputDeviceError(for: preferredDeviceID) {
            previewError = selectionError
            return
        }

        let usesBluetoothPreviewInput = previewInputUsesBluetoothTransport(preferredDeviceID)
        let captureRoute = AudioInputCaptureRoute.selectedRoute(
            selectedDeviceID: preferredDeviceID,
            usesBluetoothTransport: usesBluetoothPreviewInput
        )

        outputVolumeGuard.captureBaseline()

        guard inputActivationGuard.activateIfNeeded(
            deviceID: preferredDeviceID,
            usesBluetoothTransport: usesBluetoothPreviewInput,
            reason: "preview-start"
        ) else {
            outputVolumeGuard.restoreIfRaised(reason: "preview-start-input-activation-failed")
            outputVolumeGuard.clear()
            previewError = .routingConflict
            return
        }

        do {
            try waitForBluetoothRouteStabilizationIfNeeded(
                inputDeviceID: preferredDeviceID,
                usesBluetoothTransport: usesBluetoothPreviewInput,
                reason: "preview-start"
            )
        } catch {
            outputVolumeGuard.restoreIfRaised(reason: "preview-start-route-stabilization-failed")
            outputVolumeGuard.clear()
            inputActivationGuard.restore(reason: "preview-start-route-stabilization-failed")
            previewError = .routingConflict
            return
        }

        if let startPreviewOverride {
            do {
                try startPreviewOverride(captureRoute.avAudioEnginePreferredDeviceID)
                outputVolumeGuard.restoreIfRaised(reason: "preview-start-override")
                outputVolumeGuard.clear()
                isPreviewActive = true
            } catch let error as SelectedInputDeviceError {
                if usesBluetoothPreviewInput {
                    inputActivationGuard.restore(reason: "preview-start-override-failed")
                }
                outputVolumeGuard.restoreIfRaised(reason: "preview-start-override-failed")
                outputVolumeGuard.clear()
                previewError = error
                isPreviewActive = false
            } catch {
                if usesBluetoothPreviewInput {
                    inputActivationGuard.restore(reason: "preview-start-override-failed")
                }
                outputVolumeGuard.restoreIfRaised(reason: "preview-start-override-failed")
                outputVolumeGuard.clear()
                previewError = selectedDeviceUID == nil ? nil : .incompatible(.engineStartFailed)
                isPreviewActive = false
            }
            return
        }

        if case .inputOnlyDevice(let inputOnlyDeviceID) = captureRoute {
            do {
                try startInputOnlyPreviewCapture(deviceID: inputOnlyDeviceID, label: "preview")
                if selectedDeviceUID != nil {
                    markSelectedDeviceCompatibility(.compatible)
                }
                outputVolumeGuard.restoreIfRaised(reason: "preview-start")
                outputVolumeGuard.clear()
                isPreviewActive = true
            } catch let error as SelectedInputDeviceError {
                if case .incompatible(let issue) = error {
                    markSelectedDeviceCompatibility(.incompatible(issue))
                }
                previewError = error
                cleanupAfterFailedInputOnlyPreviewStart()
            } catch {
                logger.error("Failed to start input-only preview capture: \(error.localizedDescription)")
                if selectedDeviceUID != nil {
                    markSelectedDeviceCompatibility(.incompatible(.engineStartFailed))
                    previewError = .incompatible(.engineStartFailed)
                }
                cleanupAfterFailedInputOnlyPreviewStart()
            }
            return
        }

        let enginePreferredDeviceID = captureRoute.avAudioEnginePreferredDeviceID

        let engine = AVAudioEngine()
        previewLock.withLock {
            previewEngine = engine
            previewInputCaptureSession = nil
            activePreviewDeviceID = enginePreferredDeviceID
            activePreviewUsesBluetoothTransport = usesBluetoothPreviewInput
            bluetoothPreviewConfigurationChangeIgnoreUntil = nil
        }
        previewRecoveryCoordinator.beginStarting()
        if !usesBluetoothPreviewInput {
            installPreviewConfigurationObserver(for: engine)
        }

        do {
            try startPreviewEngineWithRecovery(engine, preferredDeviceID: enginePreferredDeviceID, label: "preview")
            if selectedDeviceUID != nil {
                markSelectedDeviceCompatibility(.compatible)
            }

            let startupRecoveryAction = previewRecoveryCoordinator.finishStartingSuccessfully()
            if usesBluetoothPreviewInput {
                beginBluetoothPreviewConfigurationChangeIgnoreWindow()
                installPreviewConfigurationObserver(for: engine)
            } else if startupRecoveryAction == .performImmediateRecovery {
                logger.warning("Preview engine configuration changed while starting, restarting with fresh input format")
                try restartPreviewEngineWithRecovery(engine, preferredDeviceID: enginePreferredDeviceID, label: "preview-startup")
                schedulePreviewRecoveryIfNeeded(previewRecoveryCoordinator.finishRecovery())
            }

            outputVolumeGuard.restoreIfRaised(reason: "preview-start")
            outputVolumeGuard.clear()
            isPreviewActive = true
        } catch let error as SelectedInputDeviceError {
            if case .incompatible(let issue) = error {
                markSelectedDeviceCompatibility(.incompatible(issue))
            }
            previewError = error
            cleanupAfterFailedPreviewStart(engine)
        } catch {
            logger.error("Failed to start preview engine: \(error.localizedDescription)")
            if selectedDeviceUID != nil {
                markSelectedDeviceCompatibility(.incompatible(.engineStartFailed))
                previewError = .incompatible(.engineStartFailed)
            }
            cleanupAfterFailedPreviewStart(engine)
        }
    }

    func stopPreview() {
        previewRecoveryCoordinator.transitionToIdle()
        removePreviewConfigurationObserver()
        let engine: AVAudioEngine? = previewLock.withLock {
            let engine = previewEngine
            previewEngine = nil
            activePreviewDeviceID = nil
            activePreviewUsesBluetoothTransport = false
            bluetoothPreviewConfigurationChangeIgnoreUntil = nil
            return engine
        }
        let inputCaptureSession: AudioInputCaptureSession? = previewLock.withLock {
            let session = previewInputCaptureSession
            previewInputCaptureSession = nil
            return session
        }
        if let engine {
            outputVolumeGuard.captureBaseline()
            teardownPreviewEngine(engine)
            previewEngineTeardownRetainer.retain(engine, for: Self.previewEngineTeardownRetentionInterval)
            outputVolumeGuard.restoreIfRaised(reason: "preview-stop")
        }
        if let inputCaptureSession {
            outputVolumeGuard.captureBaseline()
            inputCaptureSession.stop()
            outputVolumeGuard.restoreIfRaised(reason: "preview-stop")
        }
        outputVolumeGuard.clear()
        inputActivationGuard.restore(reason: "preview-stop")
        isPreviewActive = false
        previewAudioLevel = 0
        previewRawLevel = 0
    }

    func displayName(for device: AudioInputDevice) -> String {
        switch device.compatibility {
        case .incompatible(let issue):
            return "\(device.name) (\(issue.badgeText))"
        case .unknown, .compatible:
            return device.name
        }
    }

    private func processPreviewBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let monoBuffer = AudioInputBufferNormalizer.monoFloatBuffer(from: buffer),
              let channelData = monoBuffer.floatChannelData?[0] else { return }
        let frames = Int(monoBuffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(max(frames, 1)))
        let level = AudioLevelMeter.normalizedLevel(rms: rms)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPreviewActive else { return }
            self.previewAudioLevel = level
            self.previewRawLevel = rms
        }
    }

    private func startInputOnlyPreviewCapture(deviceID: AudioDeviceID, label: String) throws {
        let session = try inputCaptureFactory.startInputOnlyCapture(
            deviceID: deviceID,
            label: label,
            bufferSize: 1024
        ) { [weak self] buffer in
            self?.processPreviewBuffer(buffer)
        }

        previewRecoveryCoordinator.transitionToIdle()
        removePreviewConfigurationObserver()
        previewLock.withLock {
            previewEngine = nil
            previewInputCaptureSession = session
            activePreviewDeviceID = deviceID
            activePreviewUsesBluetoothTransport = false
            bluetoothPreviewConfigurationChangeIgnoreUntil = nil
        }
    }

    private func handlePreviewConfigurationChangeNotification() {
        if shouldSuppressBluetoothPreviewConfigurationChange() {
            logger.info("Ignoring Bluetooth preview configuration change during route settle window")
            return
        }
        schedulePreviewRecoveryIfNeeded(previewRecoveryCoordinator.noteConfigurationChange())
    }

    private func schedulePreviewRecoveryIfNeeded(_ action: AudioEngineRecoveryAction) {
        switch action {
        case .none, .performImmediateRecovery:
            return
        case .schedule(let generation, let delay):
            previewRecoveryQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.performScheduledPreviewRecovery(generation: generation)
            }
        case .fail(let failure):
            handlePreviewRecoveryFailure(failure)
        }
    }

    private func performScheduledPreviewRecovery(generation: UInt64) {
        guard previewRecoveryCoordinator.beginScheduledRecovery(generation: generation) else { return }
        defer {
            schedulePreviewRecoveryIfNeeded(previewRecoveryCoordinator.finishRecovery())
        }

        let (engine, preferredDeviceID): (AVAudioEngine?, AudioDeviceID?) = previewLock.withLock {
            (previewEngine, activePreviewDeviceID)
        }
        let hasInputOnlyCapture = previewLock.withLock { previewInputCaptureSession != nil }
        guard isPreviewActive, !hasInputOnlyCapture, let engine else { return }

        logger.warning("Preview audio engine configuration changed, restarting engine")

        do {
            try restartPreviewEngineWithRecovery(engine, preferredDeviceID: preferredDeviceID, label: "preview-config-change")
        } catch {
            logger.error("Failed to restart preview engine after configuration change: \(error.localizedDescription)")
        }
    }

    private func handlePreviewRecoveryFailure(_ failure: AudioEngineRecoveryFailure) {
        let error: SelectedInputDeviceError
        switch failure {
        case .configurationChangeBurstLimitExceeded:
            logger.error("Preview recovery circuit breaker tripped after repeated configuration changes")
            error = .routingConflict
        }

        failActivePreviewDueToRecovery(error)
    }

    private func failActivePreviewDueToRecovery(_ error: SelectedInputDeviceError) {
        previewRecoveryCoordinator.transitionToIdle()
        removePreviewConfigurationObserver()
        outputVolumeGuard.captureBaselineIfNeeded()
        let engine: AVAudioEngine? = previewLock.withLock {
            let engine = previewEngine
            previewEngine = nil
            activePreviewDeviceID = nil
            activePreviewUsesBluetoothTransport = false
            bluetoothPreviewConfigurationChangeIgnoreUntil = nil
            return engine
        }
        let inputCaptureSession: AudioInputCaptureSession? = previewLock.withLock {
            let session = previewInputCaptureSession
            previewInputCaptureSession = nil
            return session
        }
        if let engine {
            teardownPreviewEngine(engine)
            previewEngineTeardownRetainer.retain(engine, for: Self.previewEngineTeardownRetentionInterval)
        }
        inputCaptureSession?.stop()
        outputVolumeGuard.restoreIfRaised(reason: "preview-recovery-failure")
        outputVolumeGuard.clear()
        inputActivationGuard.restore(reason: "preview-recovery-failure")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPreviewActive = false
            self.previewAudioLevel = 0
            self.previewRawLevel = 0
            self.previewError = error
        }
    }

    private func installPreviewConfigurationObserver(for engine: AVAudioEngine) {
        removePreviewConfigurationObserver()
        previewConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: previewNotificationQueue
        ) { [weak self] _ in
            self?.handlePreviewConfigurationChangeNotification()
        }
    }

    private func removePreviewConfigurationObserver() {
        if let observer = previewConfigChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            previewConfigChangeObserver = nil
        }
    }

    private func startPreviewEngineWithRecovery(
        _ engine: AVAudioEngine,
        preferredDeviceID: AudioDeviceID?,
        label: String
    ) throws {
        // Main-thread callers get a bounded backoff to keep UI responsive; the
        // observer path uses the full schedule. See M1 in the release review.
        let backoff = AudioEngineRecoveryPolicy.retryBackoffForCurrentThread()
        for (attempt, delay) in backoff.enumerated() {
            do {
                try configureAndStartPreviewEngine(engine, preferredDeviceID: preferredDeviceID, label: label)
                return
            } catch {
                guard AudioEngineRecoveryPolicy.isRetryable(error: error) else {
                    if preferredDeviceID != nil {
                        throw SelectedInputDeviceError.incompatible(.engineStartFailed)
                    }
                    throw error
                }

                logger.warning("\(label, privacy: .public) audio engine start failed with retryable error, retry \(attempt + 1) in \(delay, privacy: .public)s: \(error.localizedDescription, privacy: .public)")
                Thread.sleep(forTimeInterval: delay)
            }
        }

        do {
            try configureAndStartPreviewEngine(engine, preferredDeviceID: preferredDeviceID, label: label)
        } catch let error as SelectedInputDeviceError {
            throw error
        } catch {
            if preferredDeviceID != nil {
                throw SelectedInputDeviceError.incompatible(.engineStartFailed)
            }
            throw error
        }
    }

    private func restartPreviewEngineWithRecovery(
        _ engine: AVAudioEngine,
        preferredDeviceID: AudioDeviceID?,
        label: String
    ) throws {
        outputVolumeGuard.captureBaselineIfNeeded()
        // Swap in a fresh AVAudioEngine instead of reusing the stuck one.
        // Reusing the same engine after CoreAudio flagged its AUHAL mid-switch
        // causes `AudioUnitSetProperty` to return 'nope'
        // (kAudioHardwareIllegalOperationError). See issue #332.
        guard let replacementEngine = replacePreviewAudioEngineForRecoveryIfNeeded(engine) else { return }
        defer {
            outputVolumeGuard.restoreIfRaised(reason: "\(label)-engine-restart")
            outputVolumeGuard.clear()
        }

        let usesBluetoothPreviewInput = previewLock.withLock { activePreviewUsesBluetoothTransport }
        if !usesBluetoothPreviewInput {
            installPreviewConfigurationObserver(for: replacementEngine)
        }
        teardownPreviewEngine(engine)
        previewEngineTeardownRetainer.retain(engine, for: Self.previewEngineTeardownRetentionInterval)

        do {
            try startPreviewEngineWithRecovery(replacementEngine, preferredDeviceID: preferredDeviceID, label: label)
            if usesBluetoothPreviewInput {
                beginBluetoothPreviewConfigurationChangeIgnoreWindow()
                installPreviewConfigurationObserver(for: replacementEngine)
            }
        } catch {
            cleanupAfterFailedPreviewStart(replacementEngine)
            throw error
        }
    }

    private func configureAndStartPreviewEngine(
        _ engine: AVAudioEngine,
        preferredDeviceID: AudioDeviceID?,
        label: String
    ) throws {
        if let preferredDeviceID {
            try configureExplicitInputDevice(preferredDeviceID, on: engine, label: label)
        }

        let inputNode = engine.inputNode
        let format = try settledInputFormat(for: inputNode, preferredDeviceID: preferredDeviceID, label: label)
        logger.info("\(label, privacy: .public) input format: sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
        try validateInputFormat(format, for: preferredDeviceID)

        // Re-read the format immediately before installTap and reject the
        // install if it has drifted (e.g. Bluetooth flipping from A2DP to HFP
        // between `configureExplicitInputDevice` and here). Mirrors
        // `AudioRecordingService.validateTapInstallationPreconditions`.
        // See issue #332.
        let currentFormat = try settledInputFormat(for: inputNode, preferredDeviceID: preferredDeviceID, label: "\(label)-tap")
        try validatePreviewTapInstallationPreconditions(expected: format, current: currentFormat)

        // Wrap installTap so NSException (e.g. AVAudioSession incompatible format)
        // is converted into a Swift error instead of crashing the app. See K2.
        do {
            _ = try ObjCExceptionCatcher.catching {
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: currentFormat) { [weak self] buffer, _ in
                    self?.processPreviewBuffer(buffer)
                }
            }
        } catch {
            let tapError = error as NSError? ?? NSError(
                domain: AudioEngineRecoveryErrorDomains.avfException,
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "installTap raised NSException"]
            )
            let exceptionName = tapError.userInfo[AudioEngineRecoveryErrorUserInfoKeys.exceptionName] as? String ?? "NSException"
            logger.error("\(label, privacy: .public) preview installTap raised \(exceptionName, privacy: .public): \(tapError.localizedDescription, privacy: .public)")
            throw tapError
        }

        do {
            try engine.start()
            // Open the post-start quiescence window. Without this, the
            // observer armed on this engine catches the config-change
            // triggered by our own `AudioUnitSetProperty(...CurrentDevice)`
            // write and schedules another restart — indefinitely.
            // See issue #332.
            previewRecoveryCoordinator.noteEngineStarted()
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    @discardableResult
    private func replacePreviewAudioEngineForRecoveryIfNeeded(_ engine: AVAudioEngine) -> AVAudioEngine? {
        let replacementEngine = AVAudioEngine()
        let didReplace = previewLock.withLock { () -> Bool in
            guard previewEngine === engine else { return false }
            previewEngine = replacementEngine
            return true
        }
        return didReplace ? replacementEngine : nil
    }

    private func validatePreviewTapInstallationPreconditions(expected: AVAudioFormat, current: AVAudioFormat) throws {
        let currentSampleRate = current.sampleRate
        let currentChannelCount = current.channelCount
        let matchesExpected = currentSampleRate == expected.sampleRate && currentChannelCount == expected.channelCount

        guard currentSampleRate > 0, currentChannelCount > 0, matchesExpected else {
            throw NSError(
                domain: AudioEngineRecoveryErrorDomains.transientFormatMismatch,
                code: 0,
                userInfo: [
                    NSLocalizedDescriptionKey: "Format mismatch before preview installTap: expected \(expected.sampleRate) Hz/\(expected.channelCount) ch, got \(current.sampleRate) Hz/\(current.channelCount) ch"
                ]
            )
        }
    }

    private func teardownPreviewEngine(_ engine: AVAudioEngine) {
        guard engine.isRunning else {
            engine.stop()
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func cleanupAfterFailedPreviewStart(_ engine: AVAudioEngine) {
        previewRecoveryCoordinator.transitionToIdle()
        removePreviewConfigurationObserver()
        previewLock.withLock {
            if previewEngine === engine {
                previewEngine = nil
                previewInputCaptureSession = nil
                activePreviewDeviceID = nil
                activePreviewUsesBluetoothTransport = false
                bluetoothPreviewConfigurationChangeIgnoreUntil = nil
            }
        }
        teardownPreviewEngine(engine)
        previewEngineTeardownRetainer.retain(engine, for: Self.previewEngineTeardownRetentionInterval)
        outputVolumeGuard.restoreIfRaised(reason: "preview-start-failed")
        outputVolumeGuard.clear()
        inputActivationGuard.restore(reason: "preview-start-failed")
        isPreviewActive = false
        previewAudioLevel = 0
        previewRawLevel = 0
    }

    private func cleanupAfterFailedInputOnlyPreviewStart() {
        previewRecoveryCoordinator.transitionToIdle()
        removePreviewConfigurationObserver()
        let session: AudioInputCaptureSession? = previewLock.withLock {
            let session = previewInputCaptureSession
            previewInputCaptureSession = nil
            previewEngine = nil
            activePreviewDeviceID = nil
            activePreviewUsesBluetoothTransport = false
            bluetoothPreviewConfigurationChangeIgnoreUntil = nil
            return session
        }
        session?.stop()
        outputVolumeGuard.restoreIfRaised(reason: "preview-start-failed")
        outputVolumeGuard.clear()
        inputActivationGuard.restore(reason: "preview-start-failed")
        isPreviewActive = false
        previewAudioLevel = 0
        previewRawLevel = 0
    }

    private func previewInputUsesBluetoothTransport(_ preferredDeviceID: AudioDeviceID?) -> Bool {
        guard let preferredDeviceID,
              let transportType = transportType(for: preferredDeviceID) else {
            return false
        }
        return Self.isBluetoothTransportType(transportType)
    }

    private func beginBluetoothPreviewConfigurationChangeIgnoreWindow(now: TimeInterval = CFAbsoluteTimeGetCurrent()) {
        previewLock.withLock {
            guard activePreviewUsesBluetoothTransport else { return }
            bluetoothPreviewConfigurationChangeIgnoreUntil = now + Self.bluetoothPreviewConfigurationChangeIgnoreWindow
        }
    }

    private func shouldSuppressBluetoothPreviewConfigurationChange(now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        previewLock.withLock {
            guard activePreviewUsesBluetoothTransport,
                  let ignoreUntil = bluetoothPreviewConfigurationChangeIgnoreUntil else {
                return false
            }
            guard now < ignoreUntil else {
                bluetoothPreviewConfigurationChangeIgnoreUntil = nil
                return false
            }
            return true
        }
    }

    // MARK: - CoreAudio Device Enumeration

    static func hasAvailableInputDevice() -> Bool {
        !availableInputDevices().isEmpty
    }

    static func isInputDeviceAvailable(_ deviceID: AudioDeviceID) -> Bool {
        inputChannelCount(for: deviceID) > 0
    }

    private func listInputDevices() -> [AudioInputDevice] {
        Self.availableInputDevices()
    }

    private static func availableInputDevices() -> [AudioInputDevice] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceIDs
        )
        guard status == noErr else { return [] }

        var devices: [AudioInputDevice] = []
        for id in deviceIDs {
            let snapshot = AudioInputDeviceSnapshot(
                deviceID: id,
                name: deviceName(for: id),
                uid: deviceUID(for: id),
                inputChannels: inputChannelCount(for: id),
                outputChannels: outputChannelCount(for: id),
                nominalSampleRate: nominalSampleRate(for: id),
                transportType: transportType(for: id)
            )
            guard let device = listedInputDevice(from: snapshot) else { continue }
            devices.append(device)
        }
        return devices
    }

    fileprivate struct AudioInputDeviceSnapshot: Sendable, Equatable {
        let deviceID: AudioDeviceID
        let name: String?
        let uid: String?
        let inputChannels: Int
        let outputChannels: Int
        let nominalSampleRate: Double?
        let transportType: UInt32?
    }

    private enum AudioInputDeviceExclusionReason: String {
        case noInputChannels
        case missingName
        case missingUID
        case nameMatchedCADefault
    }

    private static func listedInputDevice(from snapshot: AudioInputDeviceSnapshot) -> AudioInputDevice? {
        guard inputDeviceExclusionReason(for: snapshot) == nil,
              let name = snapshot.name,
              let uid = snapshot.uid else {
            return nil
        }
        return AudioInputDevice(deviceID: snapshot.deviceID, name: name, uid: uid)
    }

    private static func inputDeviceExclusionReason(
        for snapshot: AudioInputDeviceSnapshot
    ) -> AudioInputDeviceExclusionReason? {
        guard snapshot.inputChannels > 0 else { return .noInputChannels }
        guard let name = snapshot.name, !name.isEmpty else { return .missingName }
        guard let uid = snapshot.uid, !uid.isEmpty else { return .missingUID }

        let lowerName = name.lowercased()
        if lowerName.contains("cadefault") {
            return .nameMatchedCADefault
        }

        return nil
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return getCFStringProperty(deviceID: deviceID, address: &address)
    }

    fileprivate static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return getCFStringProperty(deviceID: deviceID, address: &address)
    }

    private static func getCFStringProperty(deviceID: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, let cf = value else { return nil }
        return cf.takeUnretainedValue() as String
    }

    static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        channelCount(for: deviceID, scope: kAudioDevicePropertyScopeInput)
    }

    private static func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        channelCount(for: deviceID, scope: kAudioDevicePropertyScopeOutput)
    }

    private static func channelCount(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return 0 }

        // Allocate based on actual size - AudioBufferList is variable-length
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let getStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawPointer)
        guard getStatus == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(rawPointer.assumingMemoryBound(to: AudioBufferList.self))
        var channels = 0
        for buffer in bufferList {
            channels += Int(buffer.mNumberChannels)
        }
        return channels
    }

    private static func allInputDeviceDiagnostics(
        selectedDeviceID: AudioDeviceID?,
        selectedDeviceUID: String?,
        defaultInputDeviceID: AudioDeviceID?,
        listedDevicesByID: [AudioDeviceID: AudioInputDevice],
        listedDevicesByUID: [String: AudioInputDevice]
    ) -> [AudioInputDiagnosticsReport.Device] {
        var deviceIDs = Set(inputCapableAudioDeviceIDs())
        deviceIDs.formUnion(listedDevicesByID.keys)

        return deviceIDs.sorted().map { deviceID in
            inputDeviceDiagnostics(
                for: deviceID,
                selectedDeviceID: selectedDeviceID,
                selectedDeviceUID: selectedDeviceUID,
                defaultInputDeviceID: defaultInputDeviceID,
                listedDevicesByID: listedDevicesByID,
                listedDevicesByUID: listedDevicesByUID
            )
        }
    }

    private static func inputDeviceDiagnostics(
        for deviceID: AudioDeviceID,
        selectedDeviceID: AudioDeviceID?,
        selectedDeviceUID: String?,
        defaultInputDeviceID: AudioDeviceID?,
        listedDevicesByID: [AudioDeviceID: AudioInputDevice],
        listedDevicesByUID: [String: AudioInputDevice]
    ) -> AudioInputDiagnosticsReport.Device {
        let coreAudioUID = deviceUID(for: deviceID)
        var listedDevice = listedDevicesByID[deviceID]
        if listedDevice == nil, let coreAudioUID {
            listedDevice = listedDevicesByUID[coreAudioUID]
        }

        let transport = transportType(for: deviceID)
        let transportName = transport.map { value in transportTypeName(value) }
        let transportFourCC = transport.map { value in transportTypeFourCC(value) }
        let isAggregate = transport == kAudioDeviceTransportTypeAggregate
        let isVirtual = transport == kAudioDeviceTransportTypeVirtual
        let isAggregateOrVirtual = isAggregate || isVirtual
        let isSelectedByID = selectedDeviceID == deviceID
        let isSelectedByUID = selectedDeviceID == nil && listedDevice?.uid == selectedDeviceUID
        let formatDiagnostic = inputOnlyCaptureFormatDiagnostic(for: deviceID)
        let snapshot = AudioInputDeviceSnapshot(
            deviceID: deviceID,
            name: deviceName(for: deviceID) ?? listedDevice?.name,
            uid: coreAudioUID ?? listedDevice?.uid,
            inputChannels: inputChannelCount(for: deviceID),
            outputChannels: outputChannelCount(for: deviceID),
            nominalSampleRate: nominalSampleRate(for: deviceID),
            transportType: transport
        )
        let exclusionReason = listedDevice == nil
            ? inputDeviceExclusionReason(for: snapshot)?.rawValue ?? "notListed"
            : nil

        return AudioInputDiagnosticsReport.Device(
            deviceID: UInt32(deviceID),
            uid: snapshot.uid,
            name: snapshot.name,
            inputChannels: snapshot.inputChannels,
            outputChannels: snapshot.outputChannels,
            nominalSampleRate: snapshot.nominalSampleRate,
            transportType: transport,
            transportTypeName: transportName,
            transportTypeFourCC: transportFourCC,
            isDefaultInput: defaultInputDeviceID == deviceID,
            isSelected: isSelectedByID || isSelectedByUID,
            isAggregate: isAggregate,
            isVirtual: isVirtual,
            isAggregateOrVirtual: isAggregateOrVirtual,
            listedByTypeWhisper: listedDevice != nil,
            compatibility: listedDevice?.compatibility.diagnosticsValue ?? "notListed",
            exclusionReason: exclusionReason,
            inputOnlyCaptureFormat: formatDiagnostic.format,
            inputOnlyCaptureFormatError: formatDiagnostic.error
        )
    }

    private static func inputCapableAudioDeviceIDs() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceIDs
        )
        guard status == noErr else { return [] }
        return deviceIDs.filter { inputChannelCount(for: $0) > 0 }
    }

    private static func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard status == noErr else { return nil }
        return sampleRate
    }

    private static func inputOnlyCaptureFormatDiagnostic(for deviceID: AudioDeviceID) -> (format: String?, error: String?) {
        do {
            let format = try CoreAudioHALInputCaptureSession.captureFormat(for: deviceID)
            return (audioFormatDescription(format), nil)
        } catch {
            return (nil, diagnosticsErrorDescription(error))
        }
    }

    private static func audioFormatDescription(_ format: AVAudioFormat) -> String {
        "\(format.sampleRate) Hz/\(format.channelCount) ch/\(audioCommonFormatName(format.commonFormat))/interleaved=\(format.isInterleaved)"
    }

    private static func audioCommonFormatName(_ format: AVAudioCommonFormat) -> String {
        switch format {
        case .pcmFormatFloat32:
            return "pcmFloat32"
        case .pcmFormatFloat64:
            return "pcmFloat64"
        case .pcmFormatInt16:
            return "pcmInt16"
        case .pcmFormatInt32:
            return "pcmInt32"
        case .otherFormat:
            return "other"
        @unknown default:
            return "unknown"
        }
    }

    func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        transportResolver.transportType(for: deviceID)
    }

    static func isBluetoothTransportType(_ transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    fileprivate static func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard status == noErr else { return nil }
        return transportType
    }

    private static func transportTypeName(_ transportType: UInt32) -> String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "builtIn"
        case kAudioDeviceTransportTypeAggregate:
            return "aggregate"
        case kAudioDeviceTransportTypeVirtual:
            return "virtual"
        case kAudioDeviceTransportTypePCI:
            return "pci"
        case kAudioDeviceTransportTypeUSB:
            return "usb"
        case kAudioDeviceTransportTypeFireWire:
            return "fireWire"
        case kAudioDeviceTransportTypeBluetooth:
            return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "bluetoothLE"
        case kAudioDeviceTransportTypeHDMI:
            return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort:
            return "displayPort"
        case kAudioDeviceTransportTypeAirPlay:
            return "airPlay"
        case kAudioDeviceTransportTypeAVB:
            return "avb"
        default:
            return "unknown(\(transportType))"
        }
    }

    private static func transportTypeFourCC(_ transportType: UInt32) -> String {
        let bytes = [
            UInt8((transportType >> 24) & 0xFF),
            UInt8((transportType >> 16) & 0xFF),
            UInt8((transportType >> 8) & 0xFF),
            UInt8(transportType & 0xFF),
        ]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(bytes.map { Character(UnicodeScalar($0)) })
        }
        return "\(transportType)"
    }

    private static func diagnosticsErrorDescription(_ error: Error) -> String {
        if let selectedInputError = error as? SelectedInputDeviceError {
            return selectedInputError.diagnosticsValue
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return (error as NSError).localizedDescription
    }

    fileprivate static func audioDeviceID(fromUID uid: String) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: Unmanaged<CFString>? = Unmanaged.passUnretained(uid as CFString)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &cfUID,
            &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // MARK: - Device Change Monitoring

    private func installDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.deviceChangeSubject.send()
        }
        listenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDeviceListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        listenerBlock = nil
    }

    private func handleDeviceChange() {
        let oldDevices = inputDevices
        let newDevices = applyCompatibilityCache(to: listInputDevices())
        inputDevices = newDevices
        compatibilityCache = compatibilityCache.filter { uid, _ in
            newDevices.contains(where: { $0.uid == uid })
        }
        inputDevices = applyCompatibilityCache(to: newDevices)

        if let uid = selectedDeviceUID,
           !newDevices.contains(where: { $0.uid == uid }) {
            // Device UID not in current list - could be transient (Continuity/Bluetooth
            // reconfiguration) or genuine disconnect. Schedule a delayed re-check.
            let deviceName = oldDevices.first(where: { $0.uid == uid })?.name
            logger.info("Selected device missing from list, scheduling re-verification: \(deviceName ?? uid)")

            disconnectVerificationTask?.cancel()
            disconnectVerificationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                guard let self else { return }

                guard let currentUID = self.selectedDeviceUID, currentUID == uid else { return }

                let refreshedDevices = self.applyCompatibilityCache(to: self.listInputDevices())
                if refreshedDevices.contains(where: { $0.uid == uid }) {
                    logger.info("Device reappeared after reconfiguration: \(deviceName ?? uid)")
                    self.inputDevices = refreshedDevices
                } else {
                    logger.info("Selected device confirmed disconnected: \(deviceName ?? uid)")
                    self.inputDevices = refreshedDevices
                    if self.isPreviewActive { self.stopPreview() }
                    self.selectedDeviceUID = nil
                    self.disconnectedDeviceName = deviceName
                }
            }
        } else {
            // Selected device still present - cancel any pending disconnect verification
            disconnectVerificationTask?.cancel()
            disconnectVerificationTask = nil
        }
    }

    private func applyCompatibilityCache(to devices: [AudioInputDevice]) -> [AudioInputDevice] {
        devices.map { device in
            var device = device
            device.compatibility = compatibilityCache[device.uid] ?? device.compatibility
            return device
        }
    }

    func markSelectedDeviceCompatibility(_ compatibility: AudioInputDeviceCompatibility) {
        guard let selectedDeviceUID else { return }
        compatibilityCache[selectedDeviceUID] = compatibility
        inputDevices = applyCompatibilityCache(to: inputDevices)
    }

    private func handleSelectedDeviceSelectionChange(from oldValue: String?, to newValue: String?) {
        if isInitializingSelection {
            return
        }

        if isApplyingValidatedSelection {
            persistSelectedDeviceUID()
            return
        }

        previewError = nil

        guard let newValue else {
            persistSelectedDeviceUID()
            if isPreviewActive {
                stopPreview()
                startPreview()
            }
            return
        }

        do {
            try validateDeviceSelection(uid: newValue)
            compatibilityCache[newValue] = .compatible
            inputDevices = applyCompatibilityCache(to: inputDevices)
            persistSelectedDeviceUID()

            if isPreviewActive {
                stopPreview()
                startPreview()
            }
        } catch let error as SelectedInputDeviceError {
            if case .incompatible(let issue) = error {
                compatibilityCache[newValue] = .incompatible(issue)
                inputDevices = applyCompatibilityCache(to: inputDevices)
            }
            previewError = error
            revertSelectedDeviceUID(to: oldValue)
        } catch {
            compatibilityCache[newValue] = .incompatible(.engineStartFailed)
            inputDevices = applyCompatibilityCache(to: inputDevices)
            previewError = .incompatible(.engineStartFailed)
            revertSelectedDeviceUID(to: oldValue)
        }
    }

    private func validateDeviceSelection(uid: String) throws {
        guard let deviceID = audioDeviceIDResolverOverride?(uid) ?? Self.audioDeviceID(fromUID: uid) else {
            throw SelectedInputDeviceError.unavailable
        }

        if let selectionValidationOverride {
            try selectionValidationOverride(deviceID)
            return
        }

        let usesBluetoothInput = previewInputUsesBluetoothTransport(deviceID)
        let engineDeviceID = AudioEngineInputRoute.preferredDeviceIDForEngine(
            selectedDeviceID: deviceID,
            usesBluetoothTransport: usesBluetoothInput
        )
        guard inputActivationGuard.activateIfNeeded(
            deviceID: deviceID,
            usesBluetoothTransport: usesBluetoothInput,
            reason: "selection-validation"
        ) else {
            throw SelectedInputDeviceError.routingConflict
        }
        defer {
            if usesBluetoothInput {
                inputActivationGuard.restore(reason: "selection-validation")
            }
        }

        try waitForBluetoothRouteStabilizationIfNeeded(
            inputDeviceID: deviceID,
            usesBluetoothTransport: usesBluetoothInput,
            reason: "selection-validation"
        )

        // Non-Bluetooth inputs use input-only HAL capture during preview and recording.
        // Keep selection non-blocking so device-specific HAL start failures surface
        // when the user actually tests or records with that input.
        guard usesBluetoothInput else { return }

        try validateSelectionEngineRoute(preferredDeviceID: engineDeviceID)
    }

    private func waitForBluetoothRouteStabilizationIfNeeded(
        inputDeviceID: AudioDeviceID?,
        usesBluetoothTransport: Bool,
        reason: String
    ) throws {
        guard usesBluetoothTransport else { return }

        guard bluetoothInputRouteStabilizer.waitForActivatedDefaultInput(
            deviceID: inputDeviceID,
            reason: reason
        ) else {
            throw SelectedInputDeviceError.routingConflict
        }
    }

    private func validateSelectionEngineRoute(preferredDeviceID: AudioDeviceID?) throws {
        try selectionEngineValidator.validate(preferredDeviceID: preferredDeviceID)
    }
}

protocol AudioInputSelectionEngineValidating: AnyObject {
    func validate(preferredDeviceID: AudioDeviceID?) throws
}

final class AVAudioInputSelectionEngineValidator: AudioInputSelectionEngineValidating {
    private let inputCaptureFactory: AudioInputCaptureFactory

    init(inputCaptureFactory: AudioInputCaptureFactory = CoreAudioHALInputCaptureFactory()) {
        self.inputCaptureFactory = inputCaptureFactory
    }

    func validate(preferredDeviceID: AudioDeviceID?) throws {
        if let preferredDeviceID {
            try inputCaptureFactory.validateInputOnlyDevice(deviceID: preferredDeviceID, label: "selection")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Single cleanup path guarded by a flag to avoid the double-teardown that
        // used to happen when engine.start() threw after the defer was already armed
        // (release review K1). Tap installation is also wrapped in
        // ObjCExceptionCatcher so NSException crashes on incompatible devices are
        // converted into throws (K2).
        var tapInstalled = false
        defer {
            if tapInstalled {
                inputNode.removeTap(onBus: 0)
            }
            engine.stop()
        }

        do {
            if let preferredDeviceID {
                try configureExplicitInputDevice(preferredDeviceID, on: engine, label: "selection")
            }
            let format = try settledInputFormat(for: inputNode, preferredDeviceID: preferredDeviceID, label: "selection")
            try validateInputFormat(format, for: preferredDeviceID)
            do {
                _ = try ObjCExceptionCatcher.catching {
                    inputNode.installTap(onBus: 0, bufferSize: 256, format: format) { _, _ in }
                }
                tapInstalled = true
            } catch {
                let tapError = error as NSError? ?? NSError(
                    domain: AudioEngineRecoveryErrorDomains.avfException,
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "installTap raised NSException"]
                )
                let exceptionName = tapError.userInfo[AudioEngineRecoveryErrorUserInfoKeys.exceptionName] as? String ?? "NSException"
                logger.error("selection installTap raised \(exceptionName, privacy: .public): \(tapError.localizedDescription, privacy: .public)")
                throw SelectedInputDeviceError.incompatible(.engineStartFailed)
            }
            try engine.start()
        } catch let error as SelectedInputDeviceError {
            throw error
        } catch let error as CoreAudioHALInputOperationError {
            if error.operation.contains("set current input device") {
                throw SelectedInputDeviceError.incompatible(.cannotSetDevice)
            }
            throw SelectedInputDeviceError.incompatible(.engineStartFailed)
        } catch {
            throw SelectedInputDeviceError.incompatible(.engineStartFailed)
        }
    }
}

extension AudioDeviceService {
    private func revertSelectedDeviceUID(to value: String?) {
        isApplyingValidatedSelection = true
        selectedDeviceUID = value
        isApplyingValidatedSelection = false
    }

    private func persistSelectedDeviceUID() {
        UserDefaults.standard.set(selectedDeviceUID, forKey: UserDefaultsKeys.selectedInputDeviceUID)
    }

    private func selectedInputDeviceError(for preferredDeviceID: AudioDeviceID?) -> SelectedInputDeviceError? {
        guard let selectedDeviceUID else { return nil }
        guard preferredDeviceID != nil else { return .unavailable }

        switch compatibilityCache[selectedDeviceUID] ?? selectedDevice?.compatibility ?? .unknown {
        case .incompatible(let issue):
            return .incompatible(issue)
        case .unknown, .compatible:
            return nil
        }
    }
}

// MARK: - Audio Device Helper

private let deviceHelperLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioDeviceHelper")

protocol AudioDeviceTransportResolving: AnyObject {
    func transportType(for deviceID: AudioDeviceID) -> UInt32?
}

final class CoreAudioDeviceTransportResolver: AudioDeviceTransportResolving {
    func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        AudioDeviceService.transportType(for: deviceID)
    }
}

enum AudioLevelMeter {
    private static let minimumDecibels: Float = -55
    private static let maximumDecibels: Float = -18

    static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }

        let decibels = 20 * log10(rms)
        guard decibels > minimumDecibels else { return 0 }

        let normalized = (decibels - minimumDecibels) / (maximumDecibels - minimumDecibels)
        return min(1, max(0, normalized))
    }
}

enum AudioInputSignal {
    private static let signalPeakThreshold: Float = 0.000_01

    static func containsSignal(_ buffer: AVAudioPCMBuffer, peakThreshold: Float = signalPeakThreshold) -> Bool {
        guard buffer.frameLength > 0,
              let channels = buffer.floatChannelData else {
            return false
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for frameIndex in 0..<frameCount where abs(channel[frameIndex]) > peakThreshold {
                return true
            }
        }
        return false
    }
}

enum AudioEngineInputRoute {
    static func preferredDeviceIDForEngine(
        selectedDeviceID: AudioDeviceID?,
        usesBluetoothTransport: Bool
    ) -> AudioDeviceID? {
        guard let selectedDeviceID else { return nil }
        return usesBluetoothTransport ? nil : selectedDeviceID
    }
}

enum AudioInputCaptureRoute: Equatable {
    case avAudioEngine(preferredDeviceID: AudioDeviceID?)
    case inputOnlyDevice(AudioDeviceID)

    var avAudioEnginePreferredDeviceID: AudioDeviceID? {
        switch self {
        case .avAudioEngine(let preferredDeviceID):
            return preferredDeviceID
        case .inputOnlyDevice:
            return nil
        }
    }

    static func selectedRoute(
        selectedDeviceID: AudioDeviceID?,
        usesBluetoothTransport: Bool
    ) -> AudioInputCaptureRoute {
        guard let selectedDeviceID else {
            return .avAudioEngine(preferredDeviceID: nil)
        }
        guard !usesBluetoothTransport else {
            return .avAudioEngine(preferredDeviceID: nil)
        }
        return .inputOnlyDevice(selectedDeviceID)
    }
}

protocol AudioInputCaptureSession: AnyObject {
    func stop()
}

protocol AudioInputCaptureFactory: AnyObject {
    func inputOnlyCaptureFormat(deviceID: AudioDeviceID) throws -> AVAudioFormat
    func validateInputOnlyDevice(deviceID: AudioDeviceID, label: String) throws
    func startInputOnlyCapture(
        deviceID: AudioDeviceID,
        label: String,
        bufferSize: AVAudioFrameCount,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws -> AudioInputCaptureSession
}

final class CoreAudioHALInputCaptureFactory: AudioInputCaptureFactory {
    private let operations: CoreAudioHALInputOperating

    init(operations: CoreAudioHALInputOperating = CoreAudioHALInputOperations()) {
        self.operations = operations
    }

    func inputOnlyCaptureFormat(deviceID: AudioDeviceID) throws -> AVAudioFormat {
        try CoreAudioHALInputCaptureSession.captureFormat(for: deviceID)
    }

    func validateInputOnlyDevice(deviceID: AudioDeviceID, label: String) throws {
        let session = try startInputOnlyCapture(
            deviceID: deviceID,
            label: label,
            bufferSize: 128,
            onBuffer: { _ in }
        )
        session.stop()
    }

    func startInputOnlyCapture(
        deviceID: AudioDeviceID,
        label: String,
        bufferSize: AVAudioFrameCount,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws -> AudioInputCaptureSession {
        let format = try inputOnlyCaptureFormat(deviceID: deviceID)
        do {
            return try CoreAudioHALInputCaptureSession(
                deviceID: deviceID,
                format: format,
                bufferSize: bufferSize,
                label: label,
                operations: operations,
                onBuffer: onBuffer
            )
        } catch let error as SelectedInputDeviceError {
            throw error
        } catch {
            throw SelectedInputDeviceError.incompatible(.engineStartFailed)
        }
    }
}

protocol CoreAudioHALInputOperating: AnyObject {
    func makeInputUnit() throws -> AudioUnit
    func setEnableIO(
        _ enabled: UInt32,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        audioUnit: AudioUnit,
        label: String
    ) throws
    func setCurrentDevice(_ deviceID: AudioDeviceID, audioUnit: AudioUnit, label: String) throws
    func setStreamFormat(_ streamDescription: inout AudioStreamBasicDescription, audioUnit: AudioUnit, label: String) throws
    func setInputCallback(_ callback: inout AURenderCallbackStruct, audioUnit: AudioUnit, label: String) throws
    func initialize(_ audioUnit: AudioUnit, label: String) throws
    func start(_ audioUnit: AudioUnit, label: String) throws
    func stop(_ audioUnit: AudioUnit)
    func uninitialize(_ audioUnit: AudioUnit)
    func dispose(_ audioUnit: AudioUnit)
    func render(
        audioUnit: AudioUnit,
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus
}

struct CoreAudioHALInputOperationError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed with status \(status) (\(audioStatusString(status)))"
    }
}

final class CoreAudioHALInputOperations: CoreAudioHALInputOperating {
    func makeInputUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioHALInputOperationError(operation: "find HAL output component", status: -1)
        }

        var audioUnit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let audioUnit else {
            throw CoreAudioHALInputOperationError(operation: "create HAL input unit", status: status)
        }
        return audioUnit
    }

    func setEnableIO(
        _ enabled: UInt32,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        audioUnit: AudioUnit,
        label: String
    ) throws {
        var enabled = enabled
        try setUInt32Property(
            kAudioOutputUnitProperty_EnableIO,
            scope: scope,
            element: element,
            audioUnit: audioUnit,
            value: &enabled,
            operation: "\(label) set EnableIO scope=\(scope) element=\(element)"
        )
    }

    func setCurrentDevice(_ deviceID: AudioDeviceID, audioUnit: AudioUnit, label: String) throws {
        var deviceID = deviceID
        do {
            try setUInt32Property(
                kAudioOutputUnitProperty_CurrentDevice,
                scope: kAudioUnitScope_Global,
                element: 0,
                audioUnit: audioUnit,
                value: &deviceID,
                operation: "\(label) set current input device"
            )
        } catch let error as CoreAudioHALInputOperationError {
            deviceHelperLogger.error("[\(label)] Could not set HAL input device \(deviceID): status=\(error.status)")
            throw error
        }
    }

    func setStreamFormat(_ streamDescription: inout AudioStreamBasicDescription, audioUnit: AudioUnit, label: String) throws {
        try setStreamDescriptionProperty(
            kAudioUnitProperty_StreamFormat,
            scope: kAudioUnitScope_Output,
            element: 1,
            audioUnit: audioUnit,
            value: &streamDescription,
            operation: "\(label) set HAL input stream format"
        )
    }

    func setInputCallback(_ callback: inout AURenderCallbackStruct, audioUnit: AudioUnit, label: String) throws {
        try setInputCallbackProperty(
            kAudioOutputUnitProperty_SetInputCallback,
            scope: kAudioUnitScope_Global,
            element: 0,
            audioUnit: audioUnit,
            value: &callback,
            operation: "\(label) set HAL input callback"
        )
    }

    func initialize(_ audioUnit: AudioUnit, label: String) throws {
        let status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw CoreAudioHALInputOperationError(operation: "\(label) initialize HAL input unit", status: status)
        }
    }

    func start(_ audioUnit: AudioUnit, label: String) throws {
        let status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            throw CoreAudioHALInputOperationError(operation: "\(label) start HAL input unit", status: status)
        }
    }

    func stop(_ audioUnit: AudioUnit) {
        AudioOutputUnitStop(audioUnit)
    }

    func uninitialize(_ audioUnit: AudioUnit) {
        AudioUnitUninitialize(audioUnit)
    }

    func dispose(_ audioUnit: AudioUnit) {
        AudioComponentInstanceDispose(audioUnit)
    }

    func render(
        audioUnit: AudioUnit,
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        AudioUnitRender(audioUnit, actionFlags, timestamp, busNumber, frameCount, data)
    }

    private func setUInt32Property(
        _ propertyID: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        audioUnit: AudioUnit,
        value: inout UInt32,
        operation: String
    ) throws {
        let status = withUnsafePointer(to: &value) { pointer in
            AudioUnitSetProperty(
                audioUnit,
                propertyID,
                scope,
                element,
                pointer,
                UInt32(MemoryLayout<UInt32>.size)
            )
        }
        try checkPropertyStatus(status, operation: operation)
    }

    private func setStreamDescriptionProperty(
        _ propertyID: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        audioUnit: AudioUnit,
        value: inout AudioStreamBasicDescription,
        operation: String
    ) throws {
        let status = withUnsafePointer(to: &value) { pointer in
            AudioUnitSetProperty(
                audioUnit,
                propertyID,
                scope,
                element,
                pointer,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
        }
        try checkPropertyStatus(status, operation: operation)
    }

    private func setInputCallbackProperty(
        _ propertyID: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        audioUnit: AudioUnit,
        value: inout AURenderCallbackStruct,
        operation: String
    ) throws {
        let status = withUnsafePointer(to: &value) { pointer in
            AudioUnitSetProperty(
                audioUnit,
                propertyID,
                scope,
                element,
                pointer,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
        }
        try checkPropertyStatus(status, operation: operation)
    }

    private func checkPropertyStatus(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioHALInputOperationError(operation: operation, status: status)
        }
    }
}

final class CoreAudioHALInputCaptureSession: AudioInputCaptureSession, @unchecked Sendable {
    final class RenderState: @unchecked Sendable {
        let audioUnit: AudioUnit
        let operations: CoreAudioHALInputOperating
        let format: AVAudioFormat
        let onBuffer: (AVAudioPCMBuffer) -> Void

        init(
            audioUnit: AudioUnit,
            operations: CoreAudioHALInputOperating,
            format: AVAudioFormat,
            onBuffer: @escaping (AVAudioPCMBuffer) -> Void
        ) {
            self.audioUnit = audioUnit
            self.operations = operations
            self.format = format
            self.onBuffer = onBuffer
        }
    }

    private let audioUnit: AudioUnit
    private let operations: CoreAudioHALInputOperating
    private let renderState: RenderState
    private let lock = NSLock()
    private var isStopped = false

    init(
        deviceID: AudioDeviceID,
        format: AVAudioFormat,
        bufferSize: AVAudioFrameCount,
        label: String,
        operations: CoreAudioHALInputOperating,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        self.operations = operations

        let audioUnit: AudioUnit
        do {
            audioUnit = try operations.makeInputUnit()
        } catch {
            AudioInputCaptureDiagnosticsStore.recordFailure(
                label: label,
                deviceID: deviceID,
                format: format,
                error: error
            )
            throw error
        }
        self.audioUnit = audioUnit

        do {
            let disabled: UInt32 = 0
            let enabled: UInt32 = 1
            try operations.setEnableIO(disabled, scope: kAudioUnitScope_Output, element: 0, audioUnit: audioUnit, label: label)
            try operations.setEnableIO(enabled, scope: kAudioUnitScope_Input, element: 1, audioUnit: audioUnit, label: label)
            try operations.setCurrentDevice(deviceID, audioUnit: audioUnit, label: label)

            var streamDescription = try Self.streamDescription(for: format)
            try operations.setStreamFormat(&streamDescription, audioUnit: audioUnit, label: label)

            let renderState = RenderState(
                audioUnit: audioUnit,
                operations: operations,
                format: format,
                onBuffer: onBuffer
            )
            self.renderState = renderState
            var callback = AURenderCallbackStruct(
                inputProc: coreAudioHALInputRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(renderState).toOpaque()
            )
            try operations.setInputCallback(&callback, audioUnit: audioUnit, label: label)
            try operations.initialize(audioUnit, label: label)
            try operations.start(audioUnit, label: label)

            AudioInputCaptureDiagnosticsStore.clear()
            deviceHelperLogger.info("[\(label)] Started input-only HAL capture for device \(deviceID), sampleRate=\(format.sampleRate), channels=\(format.channelCount), bufferSize=\(bufferSize)")
        } catch {
            operations.stop(audioUnit)
            operations.uninitialize(audioUnit)
            operations.dispose(audioUnit)
            AudioInputCaptureDiagnosticsStore.recordFailure(
                label: label,
                deviceID: deviceID,
                format: format,
                error: error
            )
            throw error
        }
    }

    static func captureFormat(for deviceID: AudioDeviceID) throws -> AVAudioFormat {
        guard let hardwareFormat = AudioInputFormatStabilizer.expectedHardwareFormat(for: deviceID),
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: hardwareFormat.sampleRate,
                  channels: inputOnlyCaptureChannelCount(for: hardwareFormat.channelCount),
                  interleaved: false
              ) else {
            throw SelectedInputDeviceError.incompatible(.invalidInputFormat)
        }
        return format
    }

    private static func inputOnlyCaptureChannelCount(for hardwareChannelCount: AVAudioChannelCount) -> AVAudioChannelCount {
        min(hardwareChannelCount, 2)
    }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard !isStopped else { return false }
            isStopped = true
            return true
        }
        guard shouldStop else { return }
        operations.stop(audioUnit)
        operations.uninitialize(audioUnit)
        operations.dispose(audioUnit)
    }

    private static func streamDescription(for format: AVAudioFormat) throws -> AudioStreamBasicDescription {
        let streamDescription = format.streamDescription.pointee
        guard streamDescription.mFormatID == kAudioFormatLinearPCM,
              streamDescription.mChannelsPerFrame > 0,
              streamDescription.mSampleRate > 0 else {
            throw SelectedInputDeviceError.incompatible(.invalidInputFormat)
        }
        return streamDescription
    }
}

private func coreAudioHALInputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let renderState = Unmanaged<CoreAudioHALInputCaptureSession.RenderState>
        .fromOpaque(inRefCon)
        .takeUnretainedValue()

    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: renderState.format,
        frameCapacity: AVAudioFrameCount(inNumberFrames)
    ) else {
        return kAudioUnitErr_InvalidPropertyValue
    }
    buffer.frameLength = AVAudioFrameCount(inNumberFrames)

    let status = renderState.operations.render(
        audioUnit: renderState.audioUnit,
        actionFlags: ioActionFlags,
        timestamp: inTimeStamp,
        busNumber: 1,
        frameCount: inNumberFrames,
        data: buffer.mutableAudioBufferList
    )
    guard status == noErr else { return status }

    renderState.onBuffer(buffer)
    return noErr
}

enum AudioInputBufferNormalizer {
    static func monoFloatFormat(for format: AVAudioFormat) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    static func monoFloatBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              buffer.format.sampleRate > 0,
              let sourceChannels = buffer.floatChannelData else {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return nil }

        if channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32,
           !buffer.format.isInterleaved {
            return buffer
        }

        guard let monoFormat = monoFloatFormat(for: buffer.format),
              let monoBuffer = AVAudioPCMBuffer(
                  pcmFormat: monoFormat,
                  frameCapacity: buffer.frameLength
              ),
              let monoChannel = monoBuffer.floatChannelData?[0] else {
            return nil
        }

        monoBuffer.frameLength = buffer.frameLength
        for frameIndex in 0..<frameCount {
            var sum: Float = 0
            for channelIndex in 0..<channelCount {
                sum += sourceChannels[channelIndex][frameIndex]
            }
            monoChannel[frameIndex] = sum / Float(channelCount)
        }
        return monoBuffer
    }
}

enum BluetoothAudioRouteStabilizer {
    static let defaultTimeout: TimeInterval = 1.5
    static let defaultStableDuration: TimeInterval = 0.25
    static let defaultPollInterval: TimeInterval = 0.02

    static func waitForActivatedDefaultRoute(
        inputDeviceID: AudioDeviceID?,
        reason: String,
        timeout: TimeInterval = defaultTimeout,
        stableDuration: TimeInterval = defaultStableDuration,
        pollInterval: TimeInterval = defaultPollInterval,
        now: () -> TimeInterval = { CFAbsoluteTimeGetCurrent() },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        readDefaultInput: () -> AudioDeviceID? = { CoreAudioInputDeviceDefaultController().defaultInputDeviceID() }
    ) -> Bool {
        let deadline = now() + timeout
        var stableSince: TimeInterval?

        while true {
            let currentTime = now()
            let inputMatches = inputDeviceID.map { readDefaultInput() == $0 } ?? true

            if inputMatches {
                if stableSince == nil {
                    stableSince = currentTime
                }
                if let stableSince, currentTime - stableSince >= stableDuration {
                    deviceHelperLogger.info("Bluetooth default route stabilized for \(reason, privacy: .public)")
                    return true
                }
            } else {
                stableSince = nil
            }

            guard currentTime < deadline else {
                deviceHelperLogger.warning("Bluetooth default route did not stabilize for \(reason, privacy: .public)")
                return false
            }

            sleep(min(pollInterval, max(0, deadline - currentTime)))
        }
    }
}

struct AudioInputHardwareFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
}

enum AudioInputFormatStabilizer {
    static let defaultTimeout: TimeInterval = 1.0
    static let defaultPollInterval: TimeInterval = 0.02

    static func expectedHardwareFormat(for deviceID: AudioDeviceID?) -> AudioInputHardwareFormat? {
        guard let deviceID,
              let sampleRate = nominalSampleRate(for: deviceID),
              sampleRate > 0 else {
            return nil
        }

        let channelCount = AVAudioChannelCount(AudioDeviceService.inputChannelCount(for: deviceID))
        guard channelCount > 0 else { return nil }
        return AudioInputHardwareFormat(sampleRate: sampleRate, channelCount: channelCount)
    }

    static func isSettled(
        _ format: AVAudioFormat,
        expectedHardwareFormat: AudioInputHardwareFormat?
    ) -> Bool {
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        guard let expectedHardwareFormat else { return true }

        let sampleRateMatches = abs(format.sampleRate - expectedHardwareFormat.sampleRate) < 1.0
        let channelCountMatches = format.channelCount == expectedHardwareFormat.channelCount
        return sampleRateMatches && channelCountMatches
    }

    static func waitForSettledFormat(
        label: String,
        expectedHardwareFormat: AudioInputHardwareFormat?,
        timeout: TimeInterval = defaultTimeout,
        pollInterval: TimeInterval = defaultPollInterval,
        now: () -> TimeInterval = { CFAbsoluteTimeGetCurrent() },
        readFormat: () -> AVAudioFormat,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> AVAudioFormat {
        let deadline = now() + timeout
        var lastFormat = readFormat()

        while true {
            if isSettled(lastFormat, expectedHardwareFormat: expectedHardwareFormat) {
                return lastFormat
            }

            let currentTime = now()
            guard currentTime < deadline else { break }
            sleep(min(pollInterval, max(0, deadline - currentTime)))
            lastFormat = readFormat()
        }

        throw makeFormatMismatchError(
            label: label,
            expectedHardwareFormat: expectedHardwareFormat,
            actualFormat: lastFormat
        )
    }

    private static func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard status == noErr else { return nil }
        return sampleRate
    }

    private static func makeFormatMismatchError(
        label: String,
        expectedHardwareFormat: AudioInputHardwareFormat?,
        actualFormat: AVAudioFormat
    ) -> NSError {
        let expectedDescription: String
        if let expectedHardwareFormat {
            expectedDescription = "\(expectedHardwareFormat.sampleRate) Hz/\(expectedHardwareFormat.channelCount) ch"
        } else {
            expectedDescription = "valid non-zero input format"
        }

        return NSError(
            domain: AudioEngineRecoveryErrorDomains.transientFormatMismatch,
            code: 0,
            userInfo: [
                NSLocalizedDescriptionKey: "\(label) input format did not settle: expected \(expectedDescription), got \(actualFormat.sampleRate) Hz/\(actualFormat.channelCount) ch"
            ]
        )
    }
}

protocol BluetoothInputRouteStabilizing: AnyObject {
    func waitForActivatedDefaultInput(deviceID: AudioDeviceID?, reason: String) -> Bool
}

final class CoreAudioBluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing {
    func waitForActivatedDefaultInput(deviceID: AudioDeviceID?, reason: String) -> Bool {
        BluetoothAudioRouteStabilizer.waitForActivatedDefaultRoute(
            inputDeviceID: deviceID,
            reason: reason
        )
    }
}

func settledInputFormat(
    for inputNode: AVAudioInputNode,
    preferredDeviceID: AudioDeviceID?,
    label: String
) throws -> AVAudioFormat {
    let expectedHardwareFormat = AudioInputFormatStabilizer.expectedHardwareFormat(for: preferredDeviceID)
    return try AudioInputFormatStabilizer.waitForSettledFormat(
        label: label,
        expectedHardwareFormat: expectedHardwareFormat,
        readFormat: { inputNode.outputFormat(forBus: 0) }
    )
}

protocol AudioInputDeviceDefaultControlling: AnyObject {
    func defaultInputDeviceID() -> AudioDeviceID?
    func setDefaultInputDeviceID(_ deviceID: AudioDeviceID) -> Bool
}

final class CoreAudioInputDeviceDefaultController: AudioInputDeviceDefaultControlling {
    func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            deviceHelperLogger.warning("Could not read default input device: status=\(status)")
            return nil
        }
        return deviceID
    }

    func setDefaultInputDeviceID(_ deviceID: AudioDeviceID) -> Bool {
        var deviceID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
        if status != noErr {
            deviceHelperLogger.error("Could not set default input device \(deviceID): status=\(status)")
        }
        return status == noErr
    }
}

protocol AudioInputDeviceActivating: AnyObject {
    @discardableResult
    func activate(deviceID: AudioDeviceID, reason: String) -> Bool
    func restore(reason: String)
}

extension AudioInputDeviceActivating {
    @discardableResult
    func activateIfNeeded(
        deviceID: AudioDeviceID?,
        usesBluetoothTransport: Bool,
        reason: String
    ) -> Bool {
        guard usesBluetoothTransport else { return true }
        guard let deviceID else { return false }
        return activate(deviceID: deviceID, reason: reason)
    }
}

final class AudioInputDeviceActivationGuard: AudioInputDeviceActivating, @unchecked Sendable {
    private struct Activation {
        let deviceID: AudioDeviceID
        let previousDeviceID: AudioDeviceID?
        var retainCount: Int
    }

    private let controller: AudioInputDeviceDefaultControlling
    private let lock = NSLock()
    private var activation: Activation?

    init(controller: AudioInputDeviceDefaultControlling = CoreAudioInputDeviceDefaultController()) {
        self.controller = controller
    }

    @discardableResult
    func activate(deviceID: AudioDeviceID, reason: String) -> Bool {
        lock.lock()
        if var currentActivation = activation {
            guard currentActivation.deviceID == deviceID else {
                lock.unlock()
                deviceHelperLogger.warning("Cannot activate input device \(deviceID) for \(reason, privacy: .public); \(currentActivation.deviceID) is already active")
                return false
            }
            currentActivation.retainCount += 1
            activation = currentActivation
            lock.unlock()
            return true
        }
        lock.unlock()

        let previousDeviceID = controller.defaultInputDeviceID()
        guard previousDeviceID != deviceID else {
            lock.withLock {
                activation = Activation(deviceID: deviceID, previousDeviceID: nil, retainCount: 1)
            }
            deviceHelperLogger.info("Default input already matches Bluetooth input \(deviceID) for \(reason, privacy: .public)")
            return true
        }

        guard controller.setDefaultInputDeviceID(deviceID) else {
            return false
        }

        lock.withLock {
            activation = Activation(deviceID: deviceID, previousDeviceID: previousDeviceID, retainCount: 1)
        }
        deviceHelperLogger.info("Temporarily activated input device \(deviceID) for \(reason, privacy: .public)")
        return true
    }

    func restore(reason: String) {
        lock.lock()
        guard var currentActivation = activation else {
            lock.unlock()
            return
        }

        if currentActivation.retainCount > 1 {
            currentActivation.retainCount -= 1
            activation = currentActivation
            lock.unlock()
            return
        }

        activation = nil
        lock.unlock()

        guard let previousDeviceID = currentActivation.previousDeviceID else { return }
        guard controller.defaultInputDeviceID() == currentActivation.deviceID else {
            deviceHelperLogger.info("Leaving default input unchanged after \(reason, privacy: .public) because it no longer matches \(currentActivation.deviceID)")
            return
        }

        if controller.setDefaultInputDeviceID(previousDeviceID) {
            deviceHelperLogger.info("Restored default input device after \(reason, privacy: .public)")
        }
    }
}

/// Sets the CoreAudio input device on an AVAudioEngine's input node AUHAL.
/// Checks the return status and verifies the device was actually set.
/// Returns true if the device was set successfully.
func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine, label: String) -> Bool {
    guard let audioUnit = engine.inputNode.audioUnit else {
        deviceHelperLogger.error("[\(label)] engine.inputNode.audioUnit is nil - cannot set device \(deviceID)")
        return false
    }

    var id = deviceID
    let setStatus = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0,
        &id,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )

    if setStatus != noErr {
        deviceHelperLogger.error("[\(label)] AudioUnitSetProperty failed: status=\(setStatus) (\(audioStatusString(setStatus))), deviceID=\(deviceID)")
        return false
    }

    // Verify by reading back the current device
    var verifyID = AudioDeviceID(0)
    var verifySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    let getStatus = AudioUnitGetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0,
        &verifyID,
        &verifySize
    )

    if getStatus != noErr {
        deviceHelperLogger.warning("[\(label)] Could not verify device after set: status=\(getStatus)")
    } else if verifyID != deviceID {
        deviceHelperLogger.error("[\(label)] Device verification mismatch: requested=\(deviceID), actual=\(verifyID)")
        return false
    }

    deviceHelperLogger.info("[\(label)] Input device set and verified: \(deviceID)")
    return true
}

func configureExplicitInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine, label: String) throws {
    guard AudioDeviceService.isInputDeviceAvailable(deviceID) else {
        throw SelectedInputDeviceError.unavailable
    }

    guard setInputDevice(deviceID, on: engine, label: label) else {
        throw SelectedInputDeviceError.incompatible(.cannotSetDevice)
    }
}

func validateInputFormat(_ format: AVAudioFormat, for preferredDeviceID: AudioDeviceID?) throws {
    guard format.sampleRate > 0, format.channelCount > 0 else {
        if preferredDeviceID != nil {
            throw SelectedInputDeviceError.incompatible(.invalidInputFormat)
        }
        throw NSError(
            domain: "AudioDeviceService",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "No audio input available for preview"]
        )
    }
}

private func audioStatusString(_ status: OSStatus) -> String {
    let bytes: [UInt8] = [
        UInt8((status >> 24) & 0xFF),
        UInt8((status >> 16) & 0xFF),
        UInt8((status >> 8) & 0xFF),
        UInt8(status & 0xFF),
    ]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }
    return "\(status)"
}

#if DEBUG
extension AudioDeviceService {
    struct TestingInputDeviceSnapshot: Sendable, Equatable {
        let deviceID: AudioDeviceID
        let name: String?
        let uid: String?
        let inputChannels: Int
        let outputChannels: Int
        let transportType: UInt32?

        init(
            deviceID: AudioDeviceID,
            name: String?,
            uid: String?,
            inputChannels: Int,
            outputChannels: Int,
            transportType: UInt32?
        ) {
            self.deviceID = deviceID
            self.name = name
            self.uid = uid
            self.inputChannels = inputChannels
            self.outputChannels = outputChannels
            self.transportType = transportType
        }

        fileprivate var snapshot: AudioInputDeviceSnapshot {
            AudioInputDeviceSnapshot(
                deviceID: deviceID,
                name: name,
                uid: uid,
                inputChannels: inputChannels,
                outputChannels: outputChannels,
                nominalSampleRate: nil,
                transportType: transportType
            )
        }
    }

    static func testingAvailableInputDevices(
        from snapshots: [TestingInputDeviceSnapshot]
    ) -> [AudioInputDevice] {
        snapshots.compactMap { listedInputDevice(from: $0.snapshot) }
    }

    static func testingInputDeviceDiagnostics(
        from snapshots: [TestingInputDeviceSnapshot],
        listedDevices: [AudioInputDevice]
    ) -> [AudioInputDiagnosticsReport.Device] {
        var listedDevicesByID: [AudioDeviceID: AudioInputDevice] = [:]
        var listedDevicesByUID: [String: AudioInputDevice] = [:]
        for device in listedDevices {
            listedDevicesByID[device.deviceID] = device
            listedDevicesByUID[device.uid] = device
        }

        return snapshots.map { testingSnapshot in
            let snapshot = testingSnapshot.snapshot
            var listedDevice = listedDevicesByID[snapshot.deviceID]
            if listedDevice == nil, let uid = snapshot.uid {
                listedDevice = listedDevicesByUID[uid]
            }

            let transportName = snapshot.transportType.map { value in transportTypeName(value) }
            let transportFourCC = snapshot.transportType.map { value in transportTypeFourCC(value) }
            let isAggregate = snapshot.transportType == kAudioDeviceTransportTypeAggregate
            let isVirtual = snapshot.transportType == kAudioDeviceTransportTypeVirtual
            let exclusionReason = listedDevice == nil
                ? inputDeviceExclusionReason(for: snapshot)?.rawValue ?? "notListed"
                : nil

            return AudioInputDiagnosticsReport.Device(
                deviceID: UInt32(snapshot.deviceID),
                uid: snapshot.uid,
                name: snapshot.name,
                inputChannels: snapshot.inputChannels,
                outputChannels: snapshot.outputChannels,
                nominalSampleRate: snapshot.nominalSampleRate,
                transportType: snapshot.transportType,
                transportTypeName: transportName,
                transportTypeFourCC: transportFourCC,
                isDefaultInput: false,
                isSelected: false,
                isAggregate: isAggregate,
                isVirtual: isVirtual,
                isAggregateOrVirtual: isAggregate || isVirtual,
                listedByTypeWhisper: listedDevice != nil,
                compatibility: listedDevice?.compatibility.diagnosticsValue ?? "notListed",
                exclusionReason: exclusionReason,
                inputOnlyCaptureFormat: nil,
                inputOnlyCaptureFormatError: nil
            )
        }
    }

    @discardableResult
    func testingReplacePreviewEngineForRecoveryIfNeeded(_ engine: AVAudioEngine) -> AVAudioEngine? {
        replacePreviewAudioEngineForRecoveryIfNeeded(engine)
    }

    func testingSetPreviewEngine(
        _ engine: AVAudioEngine?,
        activeDeviceID: AudioDeviceID? = nil,
        usesBluetoothTransport: Bool = false
    ) {
        previewLock.withLock {
            previewEngine = engine
            activePreviewDeviceID = activeDeviceID
            activePreviewUsesBluetoothTransport = usesBluetoothTransport
        }
    }

    func testingCurrentPreviewEngine() -> AVAudioEngine? {
        previewLock.withLock { previewEngine }
    }

    func testingCurrentPreviewDeviceID() -> AudioDeviceID? {
        previewLock.withLock { activePreviewDeviceID }
    }

    func testingValidatePreviewTapInstallationPreconditions(expected: AVAudioFormat, current: AVAudioFormat) throws {
        try validatePreviewTapInstallationPreconditions(expected: expected, current: current)
    }

    func testingBeginBluetoothPreviewConfigurationChangeIgnoreWindow(now: TimeInterval) {
        beginBluetoothPreviewConfigurationChangeIgnoreWindow(now: now)
    }

    func testingShouldSuppressBluetoothPreviewConfigurationChange(now: TimeInterval) -> Bool {
        shouldSuppressBluetoothPreviewConfigurationChange(now: now)
    }
}

extension CoreAudioHALInputCaptureSession {
    static func testingInputOnlyCaptureChannelCount(for hardwareChannelCount: AVAudioChannelCount) -> AVAudioChannelCount {
        inputOnlyCaptureChannelCount(for: hardwareChannelCount)
    }
}
#endif
