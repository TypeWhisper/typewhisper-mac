import Foundation
import CoreAudio
import AudioToolbox
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioDuckingService")

struct AudioOutputVolumeSnapshot: Equatable {
    let deviceID: AudioDeviceID
    let deviceUID: String?
    let deviceName: String?
    let volume: Float
    let transportType: String?

    init(
        deviceID: AudioDeviceID,
        deviceUID: String?,
        deviceName: String?,
        volume: Float,
        transportType: String? = nil
    ) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.volume = volume
        self.transportType = transportType
    }
}

protocol AudioOutputVolumeControlling: AnyObject {
    func defaultOutputSnapshot() -> AudioOutputVolumeSnapshot?
    func setVolume(_ volume: Float, for deviceID: AudioDeviceID) -> Bool
}

final class CoreAudioOutputVolumeController: AudioOutputVolumeControlling {
    func defaultOutputSnapshot() -> AudioOutputVolumeSnapshot? {
        guard let deviceID = defaultOutputDevice(),
              let volume = getVolume(for: deviceID) else {
            return nil
        }

        return AudioOutputVolumeSnapshot(
            deviceID: deviceID,
            deviceUID: getStringProperty(
                for: deviceID,
                selector: kAudioDevicePropertyDeviceUID
            ),
            deviceName: getStringProperty(
                for: deviceID,
                selector: kAudioDevicePropertyDeviceNameCFString
            ),
            volume: volume,
            transportType: transportType(for: deviceID)
        )
    }

    func setVolume(_ volume: Float, for deviceID: AudioDeviceID) -> Bool {
        var volume = max(0, min(1, volume))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume)
        if status != noErr {
            logger.error("Failed to set output volume: \(status)")
        }
        return status == noErr
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func getVolume(for deviceID: AudioDeviceID) -> Float? {
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    private func getStringProperty(for deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, let cf = value else { return nil }
        return cf.takeUnretainedValue() as String
    }

    private func transportType(for deviceID: AudioDeviceID) -> String? {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard status == noErr else { return nil }

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
}

final class AudioOutputVolumeGuard: @unchecked Sendable {
    private let volumeController: AudioOutputVolumeControlling
    private let tolerance: Float
    private let lock = NSLock()
    private var baseline: AudioOutputVolumeSnapshot?

    init(
        volumeController: AudioOutputVolumeControlling = CoreAudioOutputVolumeController(),
        tolerance: Float = 0.02
    ) {
        self.volumeController = volumeController
        self.tolerance = tolerance
    }

    func captureBaseline() {
        let snapshot = volumeController.defaultOutputSnapshot()
        lock.withLock {
            baseline = snapshot
        }

        guard let snapshot else {
            logger.warning("Could not capture output volume baseline")
            return
        }

        logger.info("Captured output volume baseline \(snapshot.volume, privacy: .public) for \(snapshot.deviceName ?? "unknown", privacy: .public)")
    }

    func captureBaselineIfNeeded() {
        let alreadyCaptured = lock.withLock { baseline != nil }
        guard !alreadyCaptured else { return }
        captureBaseline()
    }

    func restoreIfRaised(reason: String) {
        let capturedBaseline = lock.withLock { baseline }
        guard let capturedBaseline else { return }

        guard let current = volumeController.defaultOutputSnapshot() else {
            logger.warning("Could not read output volume for guarded restore: \(reason, privacy: .public)")
            return
        }

        guard current.volume > capturedBaseline.volume + tolerance else { return }

        if volumeController.setVolume(capturedBaseline.volume, for: current.deviceID) {
            logger.info("Restored output volume after \(reason, privacy: .public): \(current.volume, privacy: .public) -> \(capturedBaseline.volume, privacy: .public)")
        }
    }

    func clear() {
        lock.withLock {
            baseline = nil
        }
    }
}

@MainActor
class AudioDuckingService {
    private let volumeController: AudioOutputVolumeControlling
    private var savedSnapshot: AudioOutputVolumeSnapshot?
    private var isDucked = false

    init(volumeController: AudioOutputVolumeControlling = CoreAudioOutputVolumeController()) {
        self.volumeController = volumeController
    }

    /// Reduces the system output volume to the given factor (0.0–1.0)
    func duckAudio(to factor: Float) {
        guard !isDucked else { return }

        guard let current = volumeController.defaultOutputSnapshot() else {
            logger.warning("No default output device found")
            return
        }

        savedSnapshot = current
        let targetVolume = max(0, min(1, current.volume * factor))
        volumeController.setVolume(targetVolume, for: current.deviceID)
        isDucked = true
        logger.info("Audio ducked: \(current.volume, privacy: .public) -> \(targetVolume, privacy: .public)")
    }

    /// Restores the previously saved volume
    func restoreAudio() {
        guard isDucked, let savedSnapshot else { return }

        let restoreDeviceID = volumeController.defaultOutputSnapshot()?.deviceID ?? savedSnapshot.deviceID
        volumeController.setVolume(savedSnapshot.volume, for: restoreDeviceID)
        logger.info("Audio restored to \(savedSnapshot.volume, privacy: .public)")
        self.savedSnapshot = nil
        isDucked = false
    }
}
