import SwiftUI
import IOKit.ps

/// Notch-extending indicator that visually expands the MacBook notch area.
/// Three-zone layout: left ear | center (notch spacer) | right ear.
/// Both sides are configurable (indicator, timer, waveform, clock, battery).
/// Expands wider and downward to show streaming partial text.
/// Blue glow emanates from the notch shape, reacting to audio level.
struct NotchIndicatorView: View {
    @ObservedObject private var viewModel = DictationViewModel.shared
    @ObservedObject var geometry: NotchGeometry
    @State private var textExpanded = false
    @State private var dotPulse = false
    @State private var pausePulse = false

    private let extensionWidth: CGFloat = 60
    /// Consistent horizontal padding for all expanded content (lists, results, text).
    private let contentPadding: CGFloat = 28

    private var closedWidth: CGFloat {
        geometry.hasNotch ? geometry.notchWidth + 2 * extensionWidth : 200
    }

    private var hasActionFeedback: Bool {
        viewModel.state == .inserting && viewModel.actionFeedbackMessage != nil
    }

    private var isExpanded: Bool {
        textExpanded || hasActionFeedback
    }

    private var currentWidth: CGFloat {
        if textExpanded { return max(closedWidth, 400) }
        if hasActionFeedback { return max(closedWidth, 340) }
        return closedWidth
    }

    // MARK: - Audio-reactive glow

    private var glowColor: Color {
        if case .paused = viewModel.state {
            return Color(red: 1.0, green: 0.6, blue: 0.2) // amber/orange
        }
        return Color(red: 0.3, green: 0.5, blue: 1.0) // blue
    }

    private var glowOpacity: Double {
        switch viewModel.state {
        case .recording:
            return max(0.4, min(Double(viewModel.audioLevel) * 3.5, 1.0))
        case .paused:
            return pausePulse ? 0.8 : 0.3
        default:
            return 0
        }
    }

    private var glowRadius: CGFloat {
        switch viewModel.state {
        case .recording:
            return max(10, CGFloat(viewModel.audioLevel) * 40 + 6)
        case .paused:
            return pausePulse ? 22 : 10
        case .promptProcessing:
            return 12
        default:
            return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Three-zone status bar
            statusBar
                .frame(height: geometry.notchHeight)

            // Expandable partial text area
            if viewModel.state == .recording || viewModel.state == .paused {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(viewModel.partialText)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 34)
                            .padding(.top, 14)
                            .padding(.bottom, 16)
                            .id("bottom")
                    }
                    .frame(height: textExpanded ? 80 : 0)
                    .clipped()
                    .onChange(of: viewModel.partialText) {
                        if !viewModel.partialText.isEmpty, !textExpanded {
                            withAnimation(.easeOut(duration: 0.25)) {
                                textExpanded = true
                            }
                        }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .transaction { $0.disablesAnimations = true }
            }

            // Action feedback banner
            if hasActionFeedback {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.actionFeedbackIcon ?? "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 16))
                    Text(viewModel.actionFeedbackMessage ?? "")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, contentPadding)
            }

        }
        .frame(width: currentWidth)
        .background(.black)
        .clipShape(NotchShape(
            topCornerRadius: isExpanded ? 19 : 6,
            bottomCornerRadius: isExpanded ? 24 : 14
        ))
        // Blue glow that reacts to audio level
        .shadow(color: glowColor.opacity(glowOpacity), radius: glowRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: textExpanded)
        .animation(.easeInOut(duration: 0.2), value: viewModel.state)
        .animation(.easeOut(duration: 0.08), value: viewModel.audioLevel)
        .onChange(of: viewModel.state) {
            if viewModel.state == .recording {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    dotPulse = true
                }
                pausePulse = false
            } else if viewModel.state == .paused {
                dotPulse = false
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    pausePulse = true
                }
            } else {
                dotPulse = false
                pausePulse = false
                textExpanded = false
            }
        }
        .animation(.easeInOut(duration: 1.5), value: pausePulse)
    }

    // MARK: - Status bar (three-zone layout)

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 0) {
            contentView(for: viewModel.notchIndicatorLeftContent, side: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 34)

            // Center: notch spacer (invisible black, matches hardware notch)
            if geometry.hasNotch {
                Color.clear
                    .frame(width: geometry.notchWidth)
            }

            contentView(for: viewModel.notchIndicatorRightContent, side: .trailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 34)
        }
    }

    // MARK: - Configurable content

    private enum Side {
        case leading, trailing
    }

    @ViewBuilder
    private func contentView(for content: DictationViewModel.NotchIndicatorContent, side: Side) -> some View {
        switch viewModel.state {
        case .idle:
            Color.clear
        case .recording, .paused:
            recordingContent(for: content)
        case .processing:
            if side == .leading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            } else {
                Color.clear
            }
        case .inserting:
            if side == .leading, !hasActionFeedback {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 11))
            } else {
                Color.clear
            }
        case .promptSelection, .promptProcessing:
            Color.clear
        case .error:
            if side == .leading {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 11))
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func recordingContent(for content: DictationViewModel.NotchIndicatorContent) -> some View {
        switch content {
        case .indicator:
            Circle()
                .fill(viewModel.state == .paused ? Color.orange : Color.red)
                .frame(width: 6, height: 6)
                .scaleEffect(viewModel.state == .paused ? (pausePulse ? 1.3 : 0.8) : 1.0 + CGFloat(viewModel.audioLevel) * 0.8)
                .shadow(color: viewModel.state == .paused
                    ? .orange.opacity(pausePulse ? 0.8 : 0.2)
                    : .yellow.opacity(dotPulse ? 0.8 : 0.2),
                    radius: viewModel.state == .paused ? (pausePulse ? 6 : 2) : (dotPulse ? 6 : 2))
        case .timer:
            Text(formatDuration(viewModel.recordingDuration))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        case .waveform:
            AudioWaveformView(
                audioLevel: viewModel.audioLevel,
                isSetup: viewModel.recordingDuration < 0.5 && viewModel.audioLevel < 0.05,
                compact: true
            )
        case .clock:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        case .battery:
            batteryView
        case .profile:
            if let name = viewModel.activeProfileName {
                Text(name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.2), in: Capsule())
            } else {
                Color.clear
            }
        case .none:
            Color.clear
        }
    }

    // MARK: - Battery

    @ViewBuilder
    private var batteryView: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            if let level = Self.readBatteryLevel() {
                HStack(spacing: 3) {
                    Image(systemName: Self.batteryIconName(level: level))
                        .font(.system(size: 10))
                    Text("\(level)%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    nonisolated private static func readBatteryLevel() -> Int? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for source in sources {
            if let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               let capacity = info[kIOPSCurrentCapacityKey] as? Int {
                return capacity
            }
        }
        return nil
    }

    nonisolated private static func batteryIconName(level: Int) -> String {
        switch level {
        case 0..<13: return "battery.0percent"
        case 13..<38: return "battery.25percent"
        case 38..<63: return "battery.50percent"
        case 63..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
