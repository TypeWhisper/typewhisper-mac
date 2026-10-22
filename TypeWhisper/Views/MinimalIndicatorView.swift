import SwiftUI

struct MinimalIndicatorFeedbackProgress: View {
    let remainingFraction: Double?

    var body: some View {
        Group {
            if let remainingFraction {
                IndicatorFeedbackProgressBar(remainingFraction: remainingFraction)
            } else {
                Color.clear
                    .frame(height: 2)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, IndicatorFeedbackPanelLayout.minimalFeedbackProgressHorizontalInset)
    }
}

/// Compact floating indicator for power users who only want essential status.
struct MinimalIndicatorView: View {
    @ObservedObject private var viewModel = DictationViewModel.shared
    @ObservedObject private var recorder = AudioRecorderViewModel.shared
    @ObservedObject private var preview = IndicatorPreviewSession.shared
    @ObservedObject private var modelMenu = IndicatorModelMenuController.shared
    @ObservedObject private var countdownModel: CalendarMeetingCountdownModel
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var dotPulse = false
    @State private var revealScale: CGFloat = 1

    private let sizing: IndicatorSizing = .minimal
    private let idleWidth: CGFloat = 42
    private let processingWidth: CGFloat = 76
    private let statusLabelWidth: CGFloat = 220
    private let modelLoadingLabelWidth: CGFloat = 150
    private let insertingWidth: CGFloat = 44
    private let messageWidth = IndicatorFeedbackPanelLayout.minimalFeedbackWidth

    init(countdownModel: CalendarMeetingCountdownModel) {
        _countdownModel = ObservedObject(wrappedValue: countdownModel)
    }

    private var presentation: IndicatorPresentationData {
        IndicatorPresentationData.make(dictation: viewModel, recorder: recorder, preview: preview)
    }

    private var countdownPresentation: CalendarMeetingCountdownPresentation? {
        countdownModel.presentation
    }

    private var recordingWidth: CGFloat {
        if presentation.isPreparingMicrophone {
            return statusLabelWidth
        }
        if presentation.isModelLoading {
            // The recording content stays visible next to the label.
            return max(statusLabelWidth, recordingContentWidth + modelLoadingLabelWidth)
        }
        return recordingContentWidth
    }

    private var recordingContentWidth: CGFloat {
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
        case .model:
            guard !presentation.isRecorder else { return idleWidth }
            let chipWidth = NotchIndicatorLayout.modelChipWidth(
                for: IndicatorModelMenu.contentTitle(modelName: modelMenu.modelName),
                sizing: sizing
            )
            return min(max(96, chipWidth + 44), 220)
        }
    }

    private var isTop: Bool {
        viewModel.overlayPosition == .top
    }

    private var actionFeedbackMessage: String? {
        guard presentation.state == .inserting else { return nil }
        return presentation.actionFeedbackMessage
    }

    private var warningMessage: String? {
        presentation.warningMessage
    }

    private var errorMessage: String? {
        guard case let .error(message) = presentation.state else { return nil }
        return message
    }

    private var showsExpandedMessage: Bool {
        countdownPresentation != nil
            || warningMessage != nil
            || actionFeedbackMessage != nil
            || errorMessage != nil
    }

    private var actionFeedbackBody: IndicatorFeedbackPanelLayout.FeedbackBody {
        IndicatorFeedbackPanelLayout.feedbackBody(
            for: .minimal,
            message: actionFeedbackMessage,
            actionTitle: presentation.actionFeedbackActionTitle
        )
    }

    /// A capsule while the feedback is compact. Taller feedback keeps the same
    /// corner radius so the corners do not cut into multi-line text.
    private var surfaceShape: AnyShape {
        guard countdownPresentation == nil,
              actionFeedbackBody.height > IndicatorFeedbackPanelLayout.feedbackBodyHeight else {
            return AnyShape(Capsule())
        }
        return AnyShape(RoundedRectangle(cornerRadius: IndicatorFeedbackPanelLayout.feedbackBodyHeight / 2))
    }

    private var currentWidth: CGFloat {
        if countdownPresentation == nil, actionFeedbackMessage != nil {
            return actionFeedbackBody.width
        }
        if showsExpandedMessage {
            return messageWidth
        }

        switch presentation.state {
        case .recording:
            return recordingWidth
        case .processing:
            return presentation.isModelLoading ? statusLabelWidth : processingWidth
        case .inserting:
            return insertingWidth
        case .idle, .promptSelection, .promptProcessing:
            return idleWidth
        case .error:
            return messageWidth
        }
    }

    private var shadowColor: Color {
        errorMessage == nil ? .black.opacity(0.22 * viewModel.indicatorTheme.shadowOpacityScale) : .red.opacity(0.18)
    }

    var body: some View {
        content
            .frame(width: currentWidth)
            .indicatorPointerSurface()
            .scaleEffect(revealScale, anchor: isTop ? .top : .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isTop ? .top : .bottom)
            .environment(\.colorScheme, viewModel.indicatorTheme.preferredColorScheme ?? systemColorScheme)
            .animation(IndicatorMotion.expand, value: currentWidth)
            .animation(.easeInOut(duration: 0.2), value: presentation.state)
            .animation(.easeInOut(duration: 1.0), value: dotPulse)
            .onChange(of: presentation.state) {
                if presentation.state == .recording {
                    IndicatorMotion.popIn($revealScale)
                    IndicatorMotion.startRecordingPulse($dotPulse)
                } else {
                    dotPulse = false
                }
            }
            .accessibilityElement(
                children: countdownPresentation != nil
                    || presentation.actionFeedbackMessage != nil ? .contain : .combine
            )
            .accessibilityLabel(accessibilityLabel)
            .indicatorModelMenuAccessibilityAction(isAvailable: presentation.offersModelMenu)
        }

    private var accessibilityLabel: String {
        if let countdownPresentation {
            return countdownPresentation.kind.headline
        }
        if let message = warningMessage {
            return message
        }

        if let message = actionFeedbackMessage {
            return message
        }

        switch presentation.state {
        case .idle, .promptSelection, .promptProcessing:
            return String(localized: "Idle")
        case .recording:
            return presentation.recordingStatusLabel
        case .processing:
            return presentation.modelLoadingLabel ?? String(localized: "Processing transcription")
        case .inserting:
            return String(localized: "Inserting text")
        case .error(let message):
            return String(localized: "Error - \(message)")
        }
    }

    private var content: some View {
        contentBody
            .indicatorSurface(
                theme: viewModel.indicatorTheme,
                shape: surfaceShape,
                strokeColor: errorMessage == nil ? nil : .red.opacity(0.55)
            )
            .shadow(color: shadowColor, radius: 10, y: 4)
    }

    @ViewBuilder
    private var contentBody: some View {
        if let countdownPresentation {
            MeetingAutomationCountdownIndicator(
                model: countdownModel,
                presentation: countdownPresentation,
                contentPadding: 14
            )
        } else if let message = actionFeedbackMessage {
            VStack(spacing: 0) {
                MinimalIndicatorFeedbackProgress(
                    remainingFraction: presentation.actionFeedbackRemainingFraction
                )

                compactMessage(
                    text: message,
                    icon: presentation.actionFeedbackIcon ?? (presentation.actionFeedbackIsError ? "xmark.circle.fill" : "checkmark.circle.fill"),
                    iconColor: presentation.actionFeedbackIsError ? .red : .green,
                    actionTitle: presentation.actionFeedbackActionTitle,
                    onAction: presentation.actionFeedbackActionTitle == nil ? nil : {
                        viewModel.performActionFeedbackAction()
                    },
                    onDismiss: !presentation.isRecorder && viewModel.canDismissActionFeedback
                        ? { viewModel.dismissActionFeedback() } : nil,
                    lineLimit: actionFeedbackBody.lineLimit
                )
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
            }
            .frame(height: actionFeedbackBody.height)
            .contentShape(Rectangle())
            .onHover { hovered in
                viewModel.setActionFeedbackHovered(hovered)
            }
        } else {
            HStack(spacing: 8) {
                if let message = errorMessage {
                    compactMessage(
                        text: message,
                        icon: "xmark.circle.fill",
                        iconColor: .red
                    )
                } else if let message = warningMessage {
                    compactMessage(
                        text: message,
                        icon: "exclamationmark.triangle.fill",
                        iconColor: .yellow
                    )
                } else {
                    compactStatus
                }
            }
            .padding(.horizontal, showsExpandedMessage ? 14 : 12)
            .padding(.vertical, showsExpandedMessage ? 9 : 10)
        }
    }

    @ViewBuilder
    private var compactStatus: some View {
        switch presentation.state {
        case .recording:
            HStack(spacing: presentation.isPreparingMicrophone
                || presentation.isModelLoading
                || viewModel.notchIndicatorRightContent != .none ? 8 : 0) {
                IndicatorLeftStatus(
                    presentation: presentation,
                    sizing: sizing,
                    dotPulse: dotPulse,
                    hasActionFeedback: false
                )

                if presentation.isPreparingMicrophone || presentation.isModelLoading {
                    IndicatorPreparingLabel(presentation: presentation, sizing: sizing)
                }
                if !presentation.isPreparingMicrophone && viewModel.notchIndicatorRightContent != .none {
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
                    .tint(.primary)
                if let label = presentation.modelLoadingLabel {
                    Text(label)
                        .font(.system(size: sizing.profileFontSize, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(sizing.timerOpacity))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
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
        onAction: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        lineLimit: Int = 2
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.92))
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.12), in: Capsule())
            }
            if let onDismiss {
                IndicatorFeedbackDismissButton(action: onDismiss)
            }
        }
    }
}
