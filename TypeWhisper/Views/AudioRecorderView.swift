import SwiftUI

struct AudioRecorderView: View {
    @ObservedObject var viewModel: AudioRecorderViewModel

    var body: some View {
        Form {
            // Recording Controls
            Section {
                VStack(spacing: 16) {
                    // Duration display
                    Text(viewModel.formattedDuration(viewModel.duration))
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundStyle(viewModel.state == .recording ? .primary : .secondary)
                        .frame(maxWidth: .infinity)

                    // Record/Stop button
                    Button {
                        if viewModel.state == .recording {
                            viewModel.stopRecording()
                        } else {
                            viewModel.startRecording()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: viewModel.state == .recording ? "stop.fill" : "record.circle")
                                .font(.title2)
                            Text(viewModel.state == .recording
                                ? String(localized: "recorder.stopRecording")
                                : String(localized: "recorder.startRecording"))
                        }
                        .frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(viewModel.state == .recording ? .red : .accentColor)
                    .controlSize(.large)
                    .disabled(!viewModel.micEnabled && !viewModel.systemAudioEnabled)

                    // Level meters
                    if viewModel.state == .recording {
                        VStack(spacing: 8) {
                            if viewModel.micEnabled {
                                LevelMeterRow(
                                    label: String(localized: "recorder.mic"),
                                    icon: "mic.fill",
                                    level: viewModel.micLevel
                                )
                            }
                            if viewModel.systemAudioEnabled {
                                LevelMeterRow(
                                    label: String(localized: "recorder.systemAudio"),
                                    icon: "speaker.wave.2.fill",
                                    level: viewModel.systemLevel
                                )
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 8)

                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            // Audio Sources
            Section(String(localized: "recorder.sources")) {
                Toggle(String(localized: "recorder.mic"), isOn: $viewModel.micEnabled)
                    .disabled(viewModel.state == .recording)

                Toggle(String(localized: "recorder.systemAudio"), isOn: $viewModel.systemAudioEnabled)
                    .disabled(viewModel.state == .recording)

                if viewModel.systemAudioEnabled {
                    Label(
                        String(localized: "recorder.systemAudioPermission"),
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Picker(String(localized: "recorder.format"), selection: $viewModel.outputFormat) {
                    Text("WAV").tag(AudioRecorderService.OutputFormat.wav)
                    Text("M4A").tag(AudioRecorderService.OutputFormat.m4a)
                }
                .disabled(viewModel.state == .recording)
            }

            // Recordings list
            Section {
                if viewModel.recordings.isEmpty {
                    Text(String(localized: "recorder.noRecordings"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ForEach(viewModel.recordings) { item in
                        RecordingRow(item: item, viewModel: viewModel)
                    }
                }
            } header: {
                HStack {
                    Text(String(localized: "recorder.recordings"))
                    Spacer()
                    if !viewModel.recordings.isEmpty {
                        Button {
                            viewModel.openRecordingsFolder()
                        } label: {
                            Label(String(localized: "recorder.revealInFinder"), systemImage: "folder")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }
}

// MARK: - Level Meter Row

private struct LevelMeterRow: View {
    let label: String
    let icon: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 16)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            GeometryReader { geo in
                let maxRms: Float = 0.8
                let levelWidth = max(0, geo.size.width * CGFloat(min(level, maxRms) / maxRms))

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(levelColor(level).gradient)
                        .frame(width: levelWidth)
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(height: 6)
        }
    }

    private func levelColor(_ level: Float) -> Color {
        if level > 0.7 {
            return .red
        } else if level > 0.4 {
            return .yellow
        }
        return .green
    }
}

// MARK: - Recording Row

private struct RecordingRow: View {
    let item: AudioRecorderViewModel.RecordingItem
    @ObservedObject var viewModel: AudioRecorderViewModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Label(formattedDate(item.date), systemImage: "calendar")
                    Label(viewModel.formattedDuration(item.duration), systemImage: "clock")
                    Label(viewModel.formattedFileSize(item.fileSize), systemImage: "doc")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Button {
                    viewModel.transcribeRecording(item)
                } label: {
                    Image(systemName: "text.viewfinder")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "recorder.transcribe"))

                Button {
                    viewModel.revealInFinder(item)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "recorder.revealInFinder"))

                Button(role: .destructive) {
                    viewModel.deleteRecording(item)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "recorder.delete"))
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(String(localized: "recorder.transcribe")) {
                viewModel.transcribeRecording(item)
            }
            Button(String(localized: "recorder.revealInFinder")) {
                viewModel.revealInFinder(item)
            }
            Divider()
            Button(String(localized: "recorder.delete"), role: .destructive) {
                viewModel.deleteRecording(item)
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
