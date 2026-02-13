import Foundation
import CoreAudio
import AudioToolbox
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioDuckingService")

@MainActor
class AudioDuckingService {
    private var savedVolume: Float?
    private var isDucked = false

    /// Reduces the system output volume to the given factor (0.0–1.0)
    func duckAudio(to factor: Float) {
        guard !isDucked else { return }

        guard let deviceID = defaultOutputDevice() else {
            logger.warning("No default output device found")
            return
        }

        guard let currentVolume = getVolume(for: deviceID) else {
            logger.warning("Could not read current volume")
            return
        }

        savedVolume = currentVolume
        let targetVolume = currentVolume * factor
        setVolume(targetVolume, for: deviceID)
        isDucked = true
        logger.info("Audio ducked: \(currentVolume, privacy: .public) → \(targetVolume, privacy: .public)")
    }

    /// Restores the previously saved volume
    func restoreAudio() {
        guard isDucked, let savedVolume else { return }

        guard let deviceID = defaultOutputDevice() else {
            logger.warning("No default output device found for restore")
            self.savedVolume = nil
            isDucked = false
            return
        }

        setVolume(savedVolume, for: deviceID)
        logger.info("Audio restored to \(savedVolume, privacy: .public)")
        self.savedVolume = nil
        isDucked = false
    }

    // MARK: - CoreAudio Helpers

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

        return status == noErr ? deviceID : nil
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

    private func setVolume(_ volume: Float, for deviceID: AudioDeviceID) {
        var volume = volume
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume)
        if status != noErr {
            logger.error("Failed to set volume: \(status)")
        }
    }
}
