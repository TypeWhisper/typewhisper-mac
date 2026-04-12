import Foundation
import CoreAudio
import AudioToolbox
@preconcurrency import AVFoundation
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioDeviceService")

struct AudioInputDevice: Identifiable, Equatable {
    let deviceID: AudioDeviceID
    let name: String
    let uid: String

    var id: String { uid }
}

final class AudioDeviceService: ObservableObject, @unchecked Sendable {

    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedDeviceUID: String? {
        didSet {
            if selectedDeviceUID != oldValue {
                UserDefaults.standard.set(selectedDeviceUID, forKey: UserDefaultsKeys.selectedInputDeviceUID)
            }
        }
    }
    @Published var disconnectedDeviceName: String?
    @Published var isPreviewActive: Bool = false
    @Published var previewAudioLevel: Float = 0
    @Published var previewRawLevel: Float = 0

    var selectedDeviceID: AudioDeviceID? {
        guard let uid = selectedDeviceUID else { return nil }
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

    init() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        inputDevices = listInputDevices()
        installDeviceListener()

        deviceChangeSubject
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleDeviceChange()
            }
            .store(in: &cancellables)

        $selectedDeviceUID
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isPreviewActive else { return }
                self.stopPreview()
                self.startPreview()
            }
            .store(in: &cancellables)
    }

    deinit {
        disconnectVerificationTask?.cancel()
        removeDeviceListener()
        stopPreview()
    }

    // MARK: - Audio Preview

    func startPreview() {
        guard !isPreviewActive else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            logger.warning("Microphone permission not granted, cannot start preview")
            return
        }

        let engine = AVAudioEngine()
        let preferredDeviceID = selectedDeviceID

        previewLock.withLock {
            previewEngine = engine
            activePreviewDeviceID = preferredDeviceID
        }
        previewRecoveryCoordinator.beginStarting()
        installPreviewConfigurationObserver(for: engine)

        do {
            try startPreviewEngineWithRecovery(engine, preferredDeviceID: preferredDeviceID, label: "preview")

            if previewRecoveryCoordinator.finishStartingSuccessfully() == .performImmediateRecovery {
                logger.warning("Preview engine configuration changed while starting, restarting with fresh input format")
                try restartPreviewEngineWithRecovery(engine, preferredDeviceID: preferredDeviceID, label: "preview-startup")
                schedulePreviewRecoveryIfNeeded(previewRecoveryCoordinator.finishRecovery())
            }

            isPreviewActive = true
        } catch {
            logger.error("Failed to start preview engine: \(error.localizedDescription)")
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
                    throw error
                }

                logger.warning("\(label, privacy: .public) audio engine start failed with retryable error, retry \(attempt + 1) in \(delay, privacy: .public)s: \(error.localizedDescription, privacy: .public)")
                Thread.sleep(forTimeInterval: delay)
            }
        }

        try configureAndStartPreviewEngine(engine, preferredDeviceID: preferredDeviceID, label: label)
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
            if !setInputDevice(preferredDeviceID, on: engine, label: label) {
                logger.error("Failed to set \(label, privacy: .public) input device (\(preferredDeviceID)), falling back to system default")
            }
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        logger.info("\(label, privacy: .public) input format: sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "AudioDeviceService",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No audio input available for preview"]
            )
        }

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
        let newDevices = listInputDevices()
        inputDevices = newDevices

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

                let refreshedDevices = self.listInputDevices()
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
