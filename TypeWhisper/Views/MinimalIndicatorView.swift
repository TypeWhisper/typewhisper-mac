import SwiftUI

/// Compact floating indicator for power users who only want essential status.
struct MinimalIndicatorView: View {
    @ObservedObject private var viewModel = DictationViewModel.shared
    @State private var dotPulse = false

    private let sizing: IndicatorSizing = .minimal
    private let idleWidth: CGFloat = 42
    private let processingWidth: CGFloat = 76
    private let insertingWidth: CGFloat = 44
    private let messageWidth: CGFloat = 320

    private var recordingWidth: CGFloat {
        switch viewModel.notchIndicatorRightContent {
        case .none:
            return idleWidth
        case .indicator:
            return 58
        case .waveform:
            return 90
        case .timer:
            return 118
        case .profile:
            guard let name = viewModel.activeProfileName, !name.isEmpty else {
                return idleWidth
            }
            let estimatedTextWidth = CGFloat(min(name.count, 18)) * 7
            return min(max(96, estimatedTextWidth + 44), 190)
        }
    }

    private var isTop: Bool {
        viewModel.overlayPosition == .top
    }

    private var actionFeedbackMessage: String? {
        guard viewModel.state == .inserting else { return nil }
        return viewModel.actionFeedbackMessage
    }

    private var errorMessage: String? {
        guard case let .error(message) = viewModel.state else { return nil }
        return message
    }

    private var showsExpandedMessage: Bool {
        actionFeedbackMessage != nil || errorMessage != nil
    }

    private var currentWidth: CGFloat {
        if showsExpandedMessage {
            return messageWidth
        }

        switch viewModel.state {
        case .recording:
            return recordingWidth
        case .processing:
            return processingWidth
        case .inserting:
            return insertingWidth
        case .idle, .promptSelection, .promptProcessing:
            return idleWidth
        case .error:
            return messageWidth
        }
    }

    private var strokeColor: Color {
        errorMessage == nil ? .white.opacity(0.14) : .red.opacity(0.55)
    }

    private var shadowColor: Color {
        errorMessage == nil ? .black.opacity(0.22) : .red.opacity(0.18)
    }

    var body: some View {
        content
            .frame(width: currentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isTop ? .top : .bottom)
            .preferredColorScheme(.dark)
            .animation(.easeInOut(duration: 0.2), value: currentWidth)
            .animation(.easeInOut(duration: 0.2), value: viewModel.state)
            .animation(.easeInOut(duration: 1.0), value: dotPulse)
            .onChange(of: viewModel.state) {
                if viewModel.state == .recording {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        dotPulse = true
                    }
                } else {
                    dotPulse = false
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        }

    private var accessibilityLabel: String {
        if let message = actionFeedbackMessage {
            return message
        }

        switch viewModel.state {
        case .idle, .promptSelection, .promptProcessing:
            return String(localized: "Idle")
        case .recording:
            return String(localized: "Recording")
        case .processing:
            return String(localized: "Processing transcription")
        case .inserting:
            return String(localized: "Inserting text")
        case .error(let message):
            return String(localized: "Error - \(message)")
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            if let message = errorMessage {
                compactMessage(
                    text: message,
                    icon: "xmark.circle.fill",
                    iconColor: .red
                )
            } else if let message = actionFeedbackMessage {
                compactMessage(
                    text: message,
                    icon: viewModel.actionFeedbackIcon ?? (viewModel.actionFeedbackIsError ? "xmark.circle.fill" : "checkmark.circle.fill"),
                    iconColor: viewModel.actionFeedbackIsError ? .red : .green
                )
            } else {
                compactStatus
            }
        }
        .padding(.horizontal, showsExpandedMessage ? 14 : 12)
        .padding(.vertical, showsExpandedMessage ? 9 : 10)
        .background(.black.opacity(0.84), in: Capsule())
        .overlay(
            Capsule()
                .stroke(strokeColor, lineWidth: 1)
        )
        .shadow(color: shadowColor, radius: 10, y: 4)
    }

    @ViewBuilder
    private var compactStatus: some View {
        switch viewModel.state {
        case .recording:
            HStack(spacing: viewModel.notchIndicatorRightContent == .none ? 0 : 8) {
                IndicatorLeftStatus(
                    viewModel: viewModel,
                    sizing: sizing,
                    dotPulse: dotPulse,
                    hasActionFeedback: false
                )

                if viewModel.notchIndicatorRightContent != .none {
                    IndicatorRecordingContent(
                        viewModel: viewModel,
                        content: viewModel.notchIndicatorRightContent,
                        sizing: sizing,
                        dotPulse: dotPulse
                    )
                }
            }
        case .processing:
            HStack(spacing: 8) {
                if let icon = viewModel.activeAppIcon {
                    IndicatorAppIconView(icon: icon, sizing: sizing)
                }
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
        case .inserting:
            IndicatorLeftStatus(
                viewModel: viewModel,
                sizing: sizing,
                dotPulse: false,
                hasActionFeedback: false
            )
        case .idle, .promptSelection, .promptProcessing:
            Color.clear
                .frame(width: 1, height: 1)
        case .error:
            EmptyView()
        }
    }

    private func compactMessage(text: String, icon: String, iconColor: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
