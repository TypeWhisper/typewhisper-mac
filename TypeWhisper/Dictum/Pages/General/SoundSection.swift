import SwiftUI

struct SoundSection: View {
    @ObservedObject private var devices = ServiceContainer.shared.audioDeviceService
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var audio = ServiceContainer.shared.audioRecordingService

    private var level: Float { audio.isRecording ? audio.audioLevel : devices.previewAudioLevel }

    private var automaticLabel: String {
        String(localized: "Automatic (\(devices.systemDefaultInputDeviceName ?? String(localized: "No microphone", table: "DictumShell")))", table: "DictumShell")
    }

    private var microphoneLabel: String {
        guard let device = devices.inputDevices.first(where: { $0.uid == devices.selectedDeviceUID }) else {
            return automaticLabel
        }
        return devices.displayName(for: device)
    }

    var body: some View {
        GroupedFormSection(title: "Sound", tableName: "Localizable") {
            GroupedFormRow {
                Text("Microphone", tableName: "DictumShell")
                Spacer()
                HStack(spacing: 2) {
                    ForEach(0..<12) { segment in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Float(segment) < level * 12 ? DictumTheme.accent : DictumTheme.separatorStrong)
                            .frame(height: 8)
                    }
                }
                .frame(width: 120)
                .accessibilityLabel(Text("Microphone level", tableName: "DictumShell"))
                .accessibilityValue(level.formatted(.percent))
                DictumPopup(title: "Microphone", selection: $devices.selectedDeviceUID, value: Text(verbatim: microphoneLabel)) {
                    Text(verbatim: automaticLabel).tag(nil as String?)
                    ForEach(devices.inputDevices) { device in
                        Text(devices.displayName(for: device)).tag(Optional(device.uid))
                    }
                }
            }
            GroupedFormToggle(title: "Interaction sounds", isOn: $dictation.soundFeedbackEnabled, tableName: "DictumShell")
            GroupedFormToggle(title: "Pause other audio while dictating", isOn: Binding(
                get: { dictation.mediaPauseEnabled || dictation.audioDuckingEnabled },
                set: { enabled in
                    dictation.mediaPauseEnabled = enabled
                    dictation.audioDuckingEnabled = enabled
                }
            ))
            if let message = devices.selectedDeviceStatusMessage {
                Text(message).font(DictumTheme.Typography.secondary).foregroundStyle(DictumTheme.danger).padding(10)
            }
        }
        .onAppear { updatePreview() }
        .onChange(of: dictation.state) { _, _ in updatePreview() }
        .onDisappear { devices.stopPreview() }
    }

    private func updatePreview() {
        #if DEBUG
        if DictumDebugAudioConfiguration.fileURL != nil { return }
        #endif
        if dictation.state == .idle { devices.startPreview() }
        else { devices.stopPreview() }
    }
}
