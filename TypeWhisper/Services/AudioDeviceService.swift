import Foundation
import CoreAudio
import AudioToolbox
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
}

enum SelectedInputDeviceError: LocalizedError, Sendable, Equatable {
    case unavailable
    case incompatible(AudioInputDeviceCompatibilityIssue)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return localizedAppText(
                "Selected input device is no longer available.",
                de: "Das ausgewählte Eingabegerät ist nicht mehr verfügbar."
            )
        case .incompatible(let issue):
            return issue.detailText
        }
    }
}

struct AudioInputDevice: Identifiable, Equatable {
    let deviceID: AudioDeviceID
    let name: String
    let uid: String
    var compatibility: AudioInputDeviceCompatibility = .unknown

    var id: String { uid }
}

final class AudioDeviceService: ObservableObject, @unchecked Sendable {

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

    var selectedDeviceID: AudioDeviceID? {
        guard let uid = selectedDeviceUID else { return nil }
        if let audioDeviceIDResolverOverride {
            return audioDeviceIDResolverOverride(uid)
        }
        return audioDeviceID(fromUID: uid)
    }

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var previewEngine: AVAudioEngine?
    private var previewConfigChangeObserver: NSObjectProtocol?
    private let deviceChangeSubject = PassthroughSubject<Void, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var disconnectVerificationTask: Task<Void, Never>?
    private let previewLock = NSLock()
    private let previewRecoveryQueue = DispatchQueue(label: "com.typewhisper.preview-recovery", qos: .userInitiated)
    private let previewRecoveryCoordinator = AudioEngineRecoveryCoordinator()
    private var activePreviewDeviceID: AudioDeviceID?
    private var compatibilityCache: [String: AudioInputDeviceCompatibility] = [:]
    private var isApplyingValidatedSelection = false
    private var isInitializingSelection = false

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

    init(initialInputDevices: [AudioInputDevice]? = nil, monitorDeviceChanges: Bool = true, probeCompatibilities: Bool = false) {
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

        if let startPreviewOverride {
            do {
                try startPreviewOverride(preferredDeviceID)
                isPreviewActive = true
            } catch let error as SelectedInputDeviceError {
                previewError = error
                isPreviewActive = false
            } catch {
                previewError = selectedDeviceUID == nil ? nil : .incompatible(.engineStartFailed)
                isPreviewActive = false
            }
            return
        }

        let engine = AVAudioEngine()
        previewLock.withLock {
            previewEngine = engine
            activePreviewDeviceID = preferredDeviceID
        }
        previewRecoveryCoordinator.beginStarting()
        installPreviewConfigurationObserver(for: engine)

        do {
            try startPreviewEngineWithRecovery(engine, preferredDeviceID: preferredDeviceID, label: "preview")
            if selectedDeviceUID != nil {
                markSelectedDeviceCompatibility(.compatible)
            }

            if previewRecoveryCoordinator.finishStartingSuccessfully() == .performImmediateRecovery {
                logger.warning("Preview engine configuration changed while starting, restarting with fresh input format")
                try restartPreviewEngineWithRecovery(engine, preferredDeviceID: preferredDeviceID, label: "preview-startup")
                schedulePreviewRecoveryIfNeeded(previewRecoveryCoordinator.finishRecovery())
            }

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
            return engine
        }
        if let engine {
            teardownPreviewEngine(engine)
        }
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
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(max(frames, 1)))
        let level = min(1.0, rms * 5)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPreviewActive else { return }
            self.previewAudioLevel = level
            self.previewRawLevel = rms
        }
    }

    private func handlePreviewConfigurationChangeNotification() {
        schedulePreviewRecoveryIfNeeded(previewRecoveryCoordinator.noteConfigurationChange())
    }

    private func schedulePreviewRecoveryIfNeeded(_ action: AudioEngineRecoveryAction) {
        guard case .schedule(let generation, let delay) = action else { return }

        previewRecoveryQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performScheduledPreviewRecovery(generation: generation)
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
        guard isPreviewActive, let engine else { return }

        logger.warning("Preview audio engine configuration changed, restarting engine")

        do {
            try restartPreviewEngineWithRecovery(engine, preferredDeviceID: preferredDeviceID, label: "preview-config-change")
        } catch {
            logger.error("Failed to restart preview engine after configuration change: \(error.localizedDescription)")
        }
    }

    private func installPreviewConfigurationObserver(for engine: AVAudioEngine) {
        removePreviewConfigurationObserver()
        previewConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
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
        for (attempt, delay) in AudioEngineRecoveryPolicy.retryBackoff.enumerated() {
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
        teardownPreviewEngine(engine)
        try startPreviewEngineWithRecovery(engine, preferredDeviceID: preferredDeviceID, label: label)
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
        let format = inputNode.outputFormat(forBus: 0)
        logger.info("\(label, privacy: .public) input format: sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
        try validateInputFormat(format, for: preferredDeviceID)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processPreviewBuffer(buffer)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    private func teardownPreviewEngine(_ engine: AVAudioEngine) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func cleanupAfterFailedPreviewStart(_ engine: AVAudioEngine) {
        previewRecoveryCoordinator.transitionToIdle()
        removePreviewConfigurationObserver()
        previewLock.withLock {
            if previewEngine === engine {
                previewEngine = nil
                activePreviewDeviceID = nil
            }
        }
        teardownPreviewEngine(engine)
        isPreviewActive = false
        previewAudioLevel = 0
        previewRawLevel = 0
    }

    // MARK: - CoreAudio Device Enumeration

    static func hasAvailableInputDevice() -> Bool {
        !availableInputDevices().isEmpty
    }

    static func isInputDeviceAvailable(_ deviceID: AudioDeviceID) -> Bool {
        inputChannelCount(for: deviceID) > 0 && !isAggregateDevice(deviceID)
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
            guard isInputDeviceAvailable(id) else { continue }
            guard let name = deviceName(for: id),
                  let uid = deviceUID(for: id) else { continue }
            // Filter virtual/internal devices by known patterns
            let lowerName = name.lowercased()
            if lowerName.contains("cadefault") || lowerName.contains("aggregate") {
                continue
            }
            devices.append(AudioInputDevice(deviceID: id, name: name, uid: uid))
        }
        return devices
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return getCFStringProperty(deviceID: deviceID, address: &address)
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
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

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
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

    private static func isAggregateDevice(_ deviceID: AudioDeviceID) -> Bool {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard status == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeAggregate
            || transportType == kAudioDeviceTransportTypeVirtual
    }

    private func audioDeviceID(fromUID uid: String) -> AudioDeviceID? {
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
        guard let deviceID = audioDeviceIDResolverOverride?(uid) ?? audioDeviceID(fromUID: uid) else {
            throw SelectedInputDeviceError.unavailable
        }

        if let selectionValidationOverride {
            try selectionValidationOverride(deviceID)
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        do {
            try configureExplicitInputDevice(deviceID, on: engine, label: "selection")
            let format = inputNode.outputFormat(forBus: 0)
            try validateInputFormat(format, for: deviceID)
            inputNode.installTap(onBus: 0, bufferSize: 256, format: format) { _, _ in }
            defer {
                inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            try engine.start()
        } catch let error as SelectedInputDeviceError {
            throw error
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            throw SelectedInputDeviceError.incompatible(.engineStartFailed)
        }
    }

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
