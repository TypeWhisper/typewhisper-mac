import SwiftUI

/// Compact pill overlay showing dictation state (recording, processing, done, error).
struct DictationOverlayView: View {
    @ObservedObject private var viewModel = DictationViewModel.shared

    private var hasPartialText: Bool {
        !viewModel.partialText.isEmpty && viewModel.state == .recording
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status pill
            HStack(spacing: 8) {
                statusIcon
                statusText
                if case .recording = viewModel.state {
                    audioLevelBar
                    durationText
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Partial transcription text
            if hasPartialText {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(viewModel.partialText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                            .id("partialTextBottom")
                    }
                    .frame(maxHeight: 80)
                    .onChange(of: viewModel.partialText) {
                        proxy.scrollTo("partialTextBottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: hasPartialText ? 320 : 240)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: hasPartialText ? 16 : 26))
        .overlay(RoundedRectangle(cornerRadius: hasPartialText ? 16 : 26).strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .animation(.easeInOut(duration: 0.2), value: viewModel.state)
        .animation(.easeInOut(duration: 0.2), value: hasPartialText)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.state {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .fill(.red.opacity(0.4))
                        .frame(width: 16, height: 16)
                        .opacity(viewModel.audioLevel > 0.1 ? 1 : 0)
                )

        case .processing:
            ProgressView()
                .controlSize(.small)

        case .inserting:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))

        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))

        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch viewModel.state {
        case .recording:
            HStack(spacing: 4) {
                Text("Recording")
                    .font(.system(size: 12, weight: .medium))
                if let mode = viewModel.hotkeyMode {
                    Text(mode == .pushToTalk ? "PTT" : "TOG")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }

        case .processing:
            Text("Transcribing...")
                .font(.system(size: 12, weight: .medium))

        case .inserting:
            Text("Done")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)

        case .error(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(1)

        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var audioLevelBar: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.green.gradient)
                .frame(width: geo.size.width * CGFloat(viewModel.audioLevel))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 40, height: 6)
        .background(.quaternary, in: Capsule())
    }

    @ViewBuilder
    private var durationText: some View {
        Text(formatDuration(viewModel.recordingDuration))
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
