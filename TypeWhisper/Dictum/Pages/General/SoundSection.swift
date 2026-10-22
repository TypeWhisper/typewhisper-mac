import SwiftUI

struct SoundSection: View {
    @ObservedObject private var devices = ServiceContainer.shared.audioDeviceService
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var audio = ServiceContainer.shared.audioRecordingService

    private var level: Float { audio.isRecording ? audio.audioLevel : devices.previewAudioLevel }

    var body: some View {
        GroupedFormSection(title: "Sound") {
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
                Picker(selection: $devices.selectedDeviceUID) {
                    Text(String(localized: "Automatic (\(devices.systemDefaultInputDeviceName ?? String(localized: "No microphone", table: "DictumShell")))", table: "DictumShell"))
                        .tag(nil as String?)
                    ForEach(devices.inputDevices) { device in
                        Text(devices.displayName(for: device)).tag(Optional(device.uid))
                    }
                } label: {
                    Text("Microphone", tableName: "DictumShell")
                }.labelsHidden().fixedSize()
            }
            GroupedFormToggle(title: "Interaction sounds", isOn: $dictation.soundFeedbackEnabled)
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
