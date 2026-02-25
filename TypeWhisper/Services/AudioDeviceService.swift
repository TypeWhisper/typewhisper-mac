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
    private let deviceChangeSubject = PassthroughSubject<Void, Never>()
    private var cancellables = Set<AnyCancellable>()

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
    }

    deinit {
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

        if let deviceID = selectedDeviceID,
           let audioUnit = engine.inputNode.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            logger.warning("No audio input available for preview")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processPreviewBuffer(buffer)
        }

        do {
            try engine.start()
            previewEngine = engine
            isPreviewActive = true
        } catch {
            logger.error("Failed to start preview engine: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    func stopPreview() {
        previewEngine?.inputNode.removeTap(onBus: 0)
        previewEngine?.stop()
        previewEngine = nil
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

    // MARK: - CoreAudio Device Enumeration

    private func listInputDevices() -> [AudioInputDevice] {
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
            guard inputChannelCount(for: id) > 0 else { continue }
            guard !isAggregateDevice(id) else { continue }
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

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return getCFStringProperty(deviceID: deviceID, address: &address)
    }

    private func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return getCFStringProperty(deviceID: deviceID, address: &address)
    }

    private func getCFStringProperty(deviceID: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, let cf = value else { return nil }
        return cf.takeUnretainedValue() as String
    }

    private func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return 0 }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPointer.deallocate() }

        let getStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer)
        guard getStatus == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        var channels = 0
        for buffer in bufferList {
            channels += Int(buffer.mNumberChannels)
        }
        return channels
    }

    private func isAggregateDevice(_ deviceID: AudioDeviceID) -> Bool {
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

        // Check if selected device was disconnected
        if let uid = selectedDeviceUID,
           !newDevices.contains(where: { $0.uid == uid }) {
            let disconnectedName = oldDevices.first(where: { $0.uid == uid })?.name
            logger.info("Selected device disconnected: \(disconnectedName ?? uid)")
            selectedDeviceUID = nil
            disconnectedDeviceName = disconnectedName

            // If preview was running on the disconnected device, stop it
            if isPreviewActive {
                stopPreview()
            }
        }
    }
}
