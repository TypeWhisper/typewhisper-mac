import AppKit
import SwiftUI

enum MeetingAutomationCountdownPresentation: Equatable {
    case start(title: String, deadline: Date)
    case stop(deadline: Date)

    var deadline: Date {
        switch self {
        case .start(_, let deadline), .stop(let deadline): deadline
        }
    }
}

enum MeetingAutomationCountdownAccessibility {
    static let cancelStart = "calendarMeeting.startCountdown.cancel"
    static let continueRecording = "calendarMeeting.stopCountdown.continue"
}

@MainActor
protocol MeetingAutomationCountdownPresenting: AnyObject {
    func showStart(
        title: String,
        deadline: Date,
        onCancel: @escaping @MainActor () -> Void
    )
    func showStop(
        deadline: Date,
        onContinue: @escaping @MainActor () -> Void
    )
    func dismiss()
}

private final class MeetingAutomationFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class MeetingAutomationCountdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct MeetingAutomationCountdownView: View {
    let presentation: MeetingAutomationCountdownPresentation
    let action: @MainActor () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 14) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.headline)
                        .lineLimit(1)
                    Text(detail(at: context.date))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .accessibilityIdentifier(actionAccessibilityIdentifier)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(width: 520, height: 78)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
        }
    }

    private var headline: String {
        switch presentation {
        case .start(let title, _):
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "calendarMeeting.countdown.untitled")
                : title
        case .stop:
            String(localized: "calendarMeeting.countdown.stopHeadline")
        }
    }

    private func detail(at date: Date) -> String {
        let seconds = max(0, Int(ceil(presentation.deadline.timeIntervalSince(date))))
        switch presentation {
        case .start:
            return String(
                format: String(localized: "calendarMeeting.countdown.startDetail"),
                Int32(seconds)
            )
        case .stop:
            return String(
                format: String(localized: "calendarMeeting.countdown.stopDetail"),
                Int32(seconds)
            )
        }
    }

    private var actionTitle: String {
        switch presentation {
        case .start: String(localized: "calendarMeeting.countdown.cancel")
        case .stop: String(localized: "calendarMeeting.countdown.continue")
        }
    }

    private var actionAccessibilityIdentifier: String {
        switch presentation {
        case .start: MeetingAutomationCountdownAccessibility.cancelStart
        case .stop: MeetingAutomationCountdownAccessibility.continueRecording
        }
    }

    private var iconName: String {
        switch presentation {
        case .start: "record.circle"
        case .stop: "stop.circle"
        }
    }

    private var iconColor: Color {
        switch presentation {
        case .start: .red
        case .stop: .orange
        }
    }
}

@MainActor
final class MeetingAutomationCountdownPanelController: MeetingAutomationCountdownPresenting {
    private var panel: MeetingAutomationCountdownPanel?

    func showStart(
        title: String,
        deadline: Date,
        onCancel: @escaping @MainActor () -> Void
    ) {
        show(.start(title: title, deadline: deadline), action: onCancel)
    }

    func showStop(
        deadline: Date,
        onContinue: @escaping @MainActor () -> Void
    ) {
        show(.stop(deadline: deadline), action: onContinue)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func show(
        _ presentation: MeetingAutomationCountdownPresentation,
        action: @escaping @MainActor () -> Void
    ) {
        dismiss()
        let panel = MeetingAutomationCountdownPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 78),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let hostingView = MeetingAutomationFirstMouseHostingView(
            rootView: MeetingAutomationCountdownView(
                presentation: presentation,
                action: action
            )
        )
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = panel.frame
        let origin = NSPoint(
            x: screen.visibleFrame.midX - frame.width / 2,
            y: screen.visibleFrame.maxY - frame.height - 24
        )
        panel.setFrameOrigin(origin)
    }
}
