import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Three-zone status bar
            statusBar
                .frame(height: geometry.notchHeight)

            // Expandable partial text area
            if viewModel.state == .recording {
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

            } else {
                dotPulse = false

                textExpanded = false
            }
        }
        .animation(.easeInOut(duration: 1.0), value: dotPulse)
    }

    // MARK: - Status bar (three-zone layout)

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                leftIndicator
                leftContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 14)

            // Center: notch spacer (invisible black, matches hardware notch)
            if geometry.hasNotch {
                Color.clear
                    .frame(width: geometry.notchWidth)
            }

            rightContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 34)
        }
    }

    // MARK: - Left indicator (app icon or fallback state icon)

    @ViewBuilder
    private var leftIndicator: some View {
        switch viewModel.state {
        case .idle, .promptSelection, .promptProcessing:
            Color.clear.frame(width: 0, height: 0)
        case .recording:
            if let icon = viewModel.activeAppIcon {
                appIconView(icon)
            } else {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .scaleEffect(1.0 + CGFloat(viewModel.audioLevel) * 0.8)
                    .shadow(color: .yellow.opacity(dotPulse ? 0.8 : 0.2),
                        radius: dotPulse ? 6 : 2)
            }
        case .processing:
            if let icon = viewModel.activeAppIcon {
                appIconView(icon)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
        case .inserting:
            if hasActionFeedback {
                Color.clear.frame(width: 0, height: 0)
            } else if let icon = viewModel.activeAppIcon {
                appIconView(icon)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 11))
            }
        case .error:
            if let icon = viewModel.activeAppIcon {
                appIconView(icon, borderColor: .red)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 11))
            }
        }
    }

    private func appIconView(_ icon: NSImage, borderColor: Color? = nil) -> some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: 14, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(borderColor ?? .clear, lineWidth: 1.5)
            )
    }

    // MARK: - Configurable content

    @ViewBuilder
    private var leftContent: some View {
        if case .recording = viewModel.state {
            recordingContent(for: viewModel.notchIndicatorLeftContent)
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        if case .recording = viewModel.state {
            recordingContent(for: viewModel.notchIndicatorRightContent)
        }
    }

    @ViewBuilder
    private func recordingContent(for content: DictationViewModel.NotchIndicatorContent) -> some View {
        switch content {
        case .indicator:
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .scaleEffect(1.0 + CGFloat(viewModel.audioLevel) * 0.8)
                .shadow(color: .yellow.opacity(dotPulse ? 0.8 : 0.2),
                    radius: dotPulse ? 6 : 2)
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

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
