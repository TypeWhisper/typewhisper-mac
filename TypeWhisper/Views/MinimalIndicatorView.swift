import SwiftUI

/// Compact floating indicator for power users who only want essential status.
struct MinimalIndicatorView: View {
    @ObservedObject private var viewModel = DictationViewModel.shared
    @ObservedObject private var recorder = AudioRecorderViewModel.shared
    @State private var dotPulse = false

    private let sizing: IndicatorSizing = .minimal
    private let idleWidth: CGFloat = 42
    private let processingWidth: CGFloat = 76
    private let insertingWidth: CGFloat = 44
    private let messageWidth: CGFloat = 360

    private var presentation: IndicatorPresentationData {
        IndicatorPresentationData.make(dictation: viewModel, recorder: recorder)
    }

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
            guard let name = presentation.activeRuleName, !name.isEmpty else {
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
        guard presentation.state == .inserting else { return nil }
        return presentation.actionFeedbackMessage
    }

    private var cancelWarningMessage: String? {
        presentation.cancelWarningMessage
    }

    private var errorMessage: String? {
        guard case let .error(message) = presentation.state else { return nil }
        return message
    }

    private var showsExpandedMessage: Bool {
        cancelWarningMessage != nil || actionFeedbackMessage != nil || errorMessage != nil
    }

    private var currentWidth: CGFloat {
        if showsExpandedMessage {
            return messageWidth
        }

        switch presentation.state {
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
            .animation(.easeInOut(duration: 0.2), value: presentation.state)
            .animation(.easeInOut(duration: 1.0), value: dotPulse)
            .onChange(of: presentation.state) {
                if presentation.state == .recording {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        dotPulse = true
                    }
                } else {
                    dotPulse = false
                }
            }
            .accessibilityElement(children: presentation.actionFeedbackUndoTitle == nil ? .combine : .contain)
            .accessibilityLabel(accessibilityLabel)
        }

    private var accessibilityLabel: String {
        if let message = cancelWarningMessage {
            return message
        }

        if let message = actionFeedbackMessage {
            return message
        }

        switch presentation.state {
        case .idle, .promptSelection, .promptProcessing:
            return String(localized: "Idle")
        case .recording:
            if !presentation.isRecordingInputReady {
                return String(localized: "Preparing microphone")
            }
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
            } else if let message = cancelWarningMessage {
                compactMessage(
                    text: message,
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .yellow
                )
            } else if let message = actionFeedbackMessage {
                compactMessage(
                    text: message,
                    icon: presentation.actionFeedbackIcon ?? (presentation.actionFeedbackIsError ? "xmark.circle.fill" : "checkmark.circle.fill"),
                    iconColor: presentation.actionFeedbackIsError ? .red : .green,
                    actionTitle: presentation.actionFeedbackUndoTitle,
                    onAction: presentation.actionFeedbackUndoTitle == nil ? nil : {
                        viewModel.undoActionFeedback()
                    }
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
        switch presentation.state {
        case .recording:
            HStack(spacing: viewModel.notchIndicatorRightContent == .none ? 0 : 8) {
                IndicatorLeftStatus(
                    presentation: presentation,
                    sizing: sizing,
                    dotPulse: dotPulse,
                    hasActionFeedback: false
                )

                if viewModel.notchIndicatorRightContent != .none {
                    IndicatorRecordingContent(
                        presentation: presentation,
                        content: viewModel.notchIndicatorRightContent,
                        sizing: sizing,
                        dotPulse: dotPulse
                    )
                }
            }
        case .processing:
            HStack(spacing: 8) {
                if let icon = presentation.activeAppIcon {
                    IndicatorAppIconView(icon: icon, sizing: sizing)
                }
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
        case .inserting:
            IndicatorLeftStatus(
                presentation: presentation,
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

    private func compactMessage(
        text: String,
        icon: String,
        iconColor: Color,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) -> some View {
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

            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
        }
    }
}
