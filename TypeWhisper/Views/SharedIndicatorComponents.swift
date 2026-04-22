import SwiftUI

// MARK: - Sizing

struct IndicatorSizing {
    let iconSize: CGFloat
    let iconCornerRadius: CGFloat
    let dotSize: CGFloat
    let symbolSize: CGFloat
    let timerFontSize: CGFloat
    let timerOpacity: Double
    let profileFontSize: CGFloat
    let profilePaddingH: CGFloat
    let profilePaddingV: CGFloat
    let textFontSize: CGFloat
    let textExpandedHeight: CGFloat

    static let notch = IndicatorSizing(
        iconSize: 14,
        iconCornerRadius: 3,
        dotSize: 6,
        symbolSize: 11,
        timerFontSize: 10,
        timerOpacity: 0.6,
        profileFontSize: 9,
        profilePaddingH: 5,
        profilePaddingV: 2,
        textFontSize: IndicatorStyle.notch.transcriptPreviewBaseFontSize,
        textExpandedHeight: IndicatorStyle.notch.transcriptPreviewBaseExpandedHeight
    )

    static let overlay = IndicatorSizing(
        iconSize: 18,
        iconCornerRadius: 4,
        dotSize: 8,
        symbolSize: 14,
        timerFontSize: 12,
        timerOpacity: 0.8,
        profileFontSize: 11,
        profilePaddingH: 6,
        profilePaddingV: 3,
        textFontSize: IndicatorStyle.overlay.transcriptPreviewBaseFontSize,
        textExpandedHeight: IndicatorStyle.overlay.transcriptPreviewBaseExpandedHeight
    )

    static let minimal = IndicatorSizing(
        iconSize: 14,
        iconCornerRadius: 3,
        dotSize: 6,
        symbolSize: 12,
        timerFontSize: 11,
        timerOpacity: 0.75,
        profileFontSize: 10,
        profilePaddingH: 5,
        profilePaddingV: 2,
        textFontSize: 12,
        textExpandedHeight: 0
    )
}

// MARK: - App Icon

struct IndicatorAppIconView: View {
    let icon: NSImage
    var borderColor: Color?
    let sizing: IndicatorSizing

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: sizing.iconSize, height: sizing.iconSize)
            .clipShape(RoundedRectangle(cornerRadius: sizing.iconCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: sizing.iconCornerRadius)
                    .stroke(borderColor ?? .clear, lineWidth: 1.5)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Left Status Indicator

struct IndicatorLeftStatus: View {
    @ObservedObject var viewModel: DictationViewModel
    let sizing: IndicatorSizing
    let dotPulse: Bool
    let hasActionFeedback: Bool

    var body: some View {
        statusContent
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch viewModel.state {
        case .idle, .promptSelection, .promptProcessing:
            Color.clear.frame(width: 0, height: 0)
        case .recording:
            if let icon = viewModel.activeAppIcon {
                IndicatorAppIconView(icon: icon, sizing: sizing)
            } else {
                IndicatorDot(audioLevel: viewModel.audioLevel, dotPulse: dotPulse, sizing: sizing)
            }
        case .processing:
            if let icon = viewModel.activeAppIcon {
                IndicatorAppIconView(icon: icon, sizing: sizing)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
        case .inserting:
            if hasActionFeedback {
                Color.clear.frame(width: 0, height: 0)
            } else if let icon = viewModel.activeAppIcon {
                IndicatorAppIconView(icon: icon, sizing: sizing)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: sizing.symbolSize))
            }
        case .error:
            if let icon = viewModel.activeAppIcon {
                IndicatorAppIconView(icon: icon, borderColor: .red, sizing: sizing)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: sizing.symbolSize))
            }
        }
    }
}

// MARK: - Recording Dot

struct IndicatorDot: View {
    let audioLevel: Float
    let dotPulse: Bool
    let sizing: IndicatorSizing

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: sizing.dotSize, height: sizing.dotSize)
            .scaleEffect(1.0 + CGFloat(audioLevel) * 0.8)
            .shadow(color: .yellow.opacity(dotPulse ? 0.8 : 0.2), radius: dotPulse ? 6 : 2)
            .accessibilityHidden(true)
    }
}

// MARK: - Recording Content

struct IndicatorRecordingContent: View {
    @ObservedObject var viewModel: DictationViewModel
    let content: NotchIndicatorContent
    let sizing: IndicatorSizing
    let dotPulse: Bool

    var body: some View {
        switch content {
        case .indicator:
            IndicatorDot(audioLevel: viewModel.audioLevel, dotPulse: dotPulse, sizing: sizing)
        case .timer:
            Text(formatDuration(viewModel.recordingDuration))
                .font(.system(size: sizing.timerFontSize, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(sizing.timerOpacity))
                .accessibilityLabel(String(localized: "Recording timer"))
                .accessibilityValue(formatDuration(viewModel.recordingDuration))
        case .waveform:
            AudioWaveformView(
                audioLevel: viewModel.audioLevel,
                isSetup: viewModel.recordingDuration < 0.5 && viewModel.audioLevel < 0.05,
                compact: true
            )
        case .profile:
            if let name = viewModel.activeRuleName {
                Text(name)
                    .font(.system(size: sizing.profileFontSize, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, sizing.profilePaddingH)
                    .padding(.vertical, sizing.profilePaddingV)
                    .background(.white.opacity(0.2), in: Capsule())
                    .accessibilityLabel("Active rule")
                    .accessibilityValue(name)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        case .none:
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

// MARK: - Expandable Text

struct IndicatorExpandableText: View {
    let text: String
    let fontSize: CGFloat
    let expandedHeight: CGFloat
    let expanded: Bool
    let contentPadding: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                Text(text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, contentPadding)
                    .padding(.vertical, 14)
                    .id("bottom")
            }
            .frame(height: expanded ? expandedHeight : 0)
            .clipped()
            .onChange(of: text) {
                withAnimation(nil) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .accessibilityLabel(String(localized: "Streaming text"))
        .accessibilityValue(text)
    }
}

// MARK: - Action Feedback Banner

struct IndicatorActionFeedback: View {
    let message: String
    let icon: String?
    let isError: Bool
    let iconColor: Color?
    let contentPadding: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon ?? (isError ? "xmark.circle.fill" : "checkmark.circle.fill"))
                .foregroundStyle(iconColor ?? (isError ? .red : .green))
                .font(.system(size: 16))
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, contentPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

// MARK: - Helpers

func formatDuration(_ seconds: TimeInterval) -> String {
    let totalSeconds = Int(seconds)
    let minutes = totalSeconds / 60
    let secs = totalSeconds % 60
    return String(format: "%d:%02d", minutes, secs)
}
