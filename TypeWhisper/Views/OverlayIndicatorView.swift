import SwiftUI

/// Pill-shaped overlay indicator that appears centered on the screen.
/// Supports top and bottom positioning.
struct OverlayIndicatorView: View {
    @ObservedObject private var viewModel = DictationViewModel.shared
    @State private var textExpanded = false
    @State private var dotPulse = false

    private let contentPadding: CGFloat = 20
    private let sizing: IndicatorSizing = .overlay
    private var closedWidth: CGFloat { 280 }

    private var suppressStreamingText: Bool {
        viewModel.externalStreamingDisplayCount > 0
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

    private var isTop: Bool {
        viewModel.overlayPosition == .top
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            if isTop {
                statusBar
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
                expandableContent
            } else {
                expandableContent
                statusBar
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: currentWidth)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isTop ? .top : .bottom)
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
        .onChange(of: suppressStreamingText) {
            if suppressStreamingText {
                withAnimation(.easeInOut(duration: 0.3)) {
                    textExpanded = false
                }
            }
        }
        .animation(.easeInOut(duration: 1.0), value: dotPulse)
    }

    // MARK: - Expandable content (text + action feedback)

    @ViewBuilder
    private var expandableContent: some View {
        if isTop {
            // Top position: text expands downward, action feedback below text
            if viewModel.state == .recording, !suppressStreamingText {
                IndicatorExpandableText(
                    text: viewModel.partialText,
                    sizing: sizing,
                    expanded: textExpanded,
                    contentPadding: contentPadding
                )
                .onChange(of: viewModel.partialText) {
                    if !viewModel.partialText.isEmpty, !textExpanded {
                        withAnimation(.easeOut(duration: 0.25)) {
                            textExpanded = true
                        }
                    }
                }
            }

            if hasActionFeedback {
                Divider().background(Color.white.opacity(0.1))
                IndicatorActionFeedback(
                    message: viewModel.actionFeedbackMessage ?? "",
                    icon: viewModel.actionFeedbackIcon,
                    isError: viewModel.actionFeedbackIsError,
                    contentPadding: contentPadding
                )
            }
        } else {
            // Bottom position: action feedback on top, text above status bar
            if hasActionFeedback {
                IndicatorActionFeedback(
                    message: viewModel.actionFeedbackMessage ?? "",
                    icon: viewModel.actionFeedbackIcon,
                    isError: viewModel.actionFeedbackIsError,
                    contentPadding: contentPadding
                )
                Divider().background(Color.white.opacity(0.1))
            }

            if viewModel.state == .recording, !suppressStreamingText {
                IndicatorExpandableText(
                    text: viewModel.partialText,
                    sizing: sizing,
                    expanded: textExpanded,
                    contentPadding: contentPadding
                )
                .onChange(of: viewModel.partialText) {
                    if !viewModel.partialText.isEmpty, !textExpanded {
                        withAnimation(.easeOut(duration: 0.25)) {
                            textExpanded = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - Status bar

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 12) {
            IndicatorLeftStatus(
                viewModel: viewModel,
                sizing: sizing,
                dotPulse: dotPulse,
                hasActionFeedback: hasActionFeedback
            )

            if case .recording = viewModel.state {
                IndicatorRecordingContent(
                    viewModel: viewModel,
                    content: viewModel.notchIndicatorLeftContent,
                    sizing: sizing,
                    dotPulse: dotPulse
                )
            }

            Spacer()

            if case .recording = viewModel.state {
                IndicatorRecordingContent(
                    viewModel: viewModel,
                    content: viewModel.notchIndicatorRightContent,
                    sizing: sizing,
                    dotPulse: dotPulse
                )
            } else if case .processing = viewModel.state {
                if let phase = viewModel.processingPhase {
                    Text(phase)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
        }
        .padding(.horizontal, 20)
    }
}
