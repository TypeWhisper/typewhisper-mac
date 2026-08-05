import Combine
import Foundation
import SwiftUI

enum CalendarMeetingCountdownKind: Equatable, Sendable {
    case start(title: String)
    case autoStop

    var isStart: Bool {
        if case .start = self { return true }
        return false
    }

    var isAutoStop: Bool { self == .autoStop }

    var headline: String {
        switch self {
        case .start(let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? String(localized: "calendarMeeting.countdown.untitled")
                : trimmed
        case .autoStop:
            return String(localized: "calendarMeeting.notification.autoStopTitle")
        }
    }
}

struct CalendarMeetingCountdownPresentation: Equatable, Sendable {
    let kind: CalendarMeetingCountdownKind
    let startedAt: Date
    let deadline: Date
}

enum CalendarMeetingCountdownTypography {
    static let fontSize: CGFloat = 11
    static let font: Font = .system(size: fontSize, weight: .medium)
}

enum CalendarMeetingCountdown {
    static let normalMinimumInterval: TimeInterval = 1.0 / 30.0
    static let reducedMotionMinimumInterval: TimeInterval = 1

    static func minimumInterval(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? reducedMotionMinimumInterval : normalMinimumInterval
    }

    static func remainingSeconds(deadline: Date, now: Date) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }

    static func remainingFraction(
        startedAt: Date,
        deadline: Date,
        now: Date
    ) -> Double {
        let duration = deadline.timeIntervalSince(startedAt)
        guard duration > 0 else {
            return now < deadline ? 1 : 0
        }
        return min(max(deadline.timeIntervalSince(now) / duration, 0), 1)
    }
}

@MainActor
final class CalendarMeetingCountdownModel: ObservableObject {
    @Published private(set) var presentation: CalendarMeetingCountdownPresentation?

    private let hotkeyService: HotkeyService?
    private let onButtonAction: @MainActor () -> Void
    private var generation: UInt64 = 0
    private var activeAction: (@MainActor () -> Void)?
    private var hotkeyRegistrationID: UUID?

    init(
        hotkeyService: HotkeyService? = nil,
        onButtonAction: @escaping @MainActor () -> Void = {}
    ) {
        self.hotkeyService = hotkeyService
        self.onButtonAction = onButtonAction
    }

    deinit {
        if let hotkeyRegistrationID {
            hotkeyService?.unregisterMeetingCountdownAction(id: hotkeyRegistrationID)
        }
    }

    func presentStart(
        title: String,
        startedAt: Date,
        deadline: Date,
        onCancel: @escaping @MainActor () -> Void
    ) {
        present(
            kind: .start(title: title),
            startedAt: startedAt,
            deadline: deadline,
            action: onCancel,
            registersCancelHotkey: true
        )
    }

    func presentAutoStop(
        startedAt: Date,
        deadline: Date,
        onContinue: @escaping @MainActor () -> Void
    ) {
        present(
            kind: .autoStop,
            startedAt: startedAt,
            deadline: deadline,
            action: onContinue,
            registersCancelHotkey: false
        )
    }

    func cancelStart() {
        guard presentation?.kind.isStart == true else { return }
        performAction(expectedGeneration: generation)
    }

    func continueRecording() {
        guard presentation?.kind.isAutoStop == true else { return }
        performAction(expectedGeneration: generation)
    }

    func dismissStart() {
        guard presentation?.kind.isStart == true else { return }
        dismissAll()
    }

    func dismissAutoStop() {
        guard presentation?.kind.isAutoStop == true else { return }
        dismissAll()
    }

    func dismissAll() {
        generation &+= 1
        presentation = nil
        activeAction = nil
        removeKeyboardAction()
    }

    func action(
        for presentation: CalendarMeetingCountdownPresentation
    ) -> @MainActor () -> Void {
        guard self.presentation == presentation else { return {} }
        let expectedGeneration = generation
        return { [weak self] in
            self?.performAction(
                expectedGeneration: expectedGeneration,
                isButtonAction: true
            )
        }
    }

    private func present(
        kind: CalendarMeetingCountdownKind,
        startedAt: Date,
        deadline: Date,
        action: @escaping @MainActor () -> Void,
        registersCancelHotkey: Bool
    ) {
        generation &+= 1
        removeKeyboardAction()
        presentation = CalendarMeetingCountdownPresentation(
            kind: kind,
            startedAt: startedAt,
            deadline: deadline
        )
        activeAction = action

        guard registersCancelHotkey else { return }
        let expectedGeneration = generation
        let registrationID = UUID()
        hotkeyRegistrationID = registrationID
        hotkeyService?.registerMeetingCountdownAction(id: registrationID) { [weak self] in
            self?.performAction(expectedGeneration: expectedGeneration)
        }
    }

    private func performAction(
        expectedGeneration: UInt64,
        isButtonAction: Bool = false
    ) {
        guard expectedGeneration == generation,
              presentation != nil,
              let action = activeAction else {
            return
        }

        if isButtonAction {
            onButtonAction()
        }
        generation &+= 1
        presentation = nil
        activeAction = nil
        removeKeyboardAction()
        action()
    }

    private func removeKeyboardAction() {
        guard let hotkeyRegistrationID else { return }
        hotkeyService?.unregisterMeetingCountdownAction(id: hotkeyRegistrationID)
        self.hotkeyRegistrationID = nil
    }
}

enum CalendarMeetingCountdownIndicatorAccessibility {
    static let startIndicator = "calendarMeeting.startCountdown.indicator"
    static let startCountdown = "calendarMeeting.startCountdown.countdown"
    static let cancelStart = "calendarMeeting.startCountdown.cancel"
    static let autoStopIndicator = "calendarMeeting.autoStopIndicator"
    static let autoStopCountdown = "calendarMeeting.autoStopIndicator.countdown"
    static let continueRecording = "calendarMeeting.autoStopIndicator.continue"
}

enum CalendarMeetingCountdownIndicatorPolicy {
    static func shouldShow(
        normalVisibilityAllowsPresentation: Bool,
        countdownPresented: Bool
    ) -> Bool {
        countdownPresented || normalVisibilityAllowsPresentation
    }

    static func shouldSuppressForFullscreen(
        normallySuppressed: Bool,
        countdownPresented: Bool
    ) -> Bool {
        normallySuppressed && !countdownPresented
    }
}

struct MeetingAutomationCountdownIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var model: CalendarMeetingCountdownModel
    let presentation: CalendarMeetingCountdownPresentation
    let contentPadding: CGFloat

    init(
        model: CalendarMeetingCountdownModel,
        presentation: CalendarMeetingCountdownPresentation,
        contentPadding: CGFloat
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.presentation = presentation
        self.contentPadding = contentPadding
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: CalendarMeetingCountdown.minimumInterval(
                reduceMotion: reduceMotion
            ),
            paused: false
        )) { timeline in
            countdownContent(now: timeline.date)
        }
        .frame(maxWidth: .infinity)
        .frame(height: IndicatorFeedbackPanelLayout.feedbackBodyHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(indicatorAccessibilityIdentifier)
    }

    private func countdownContent(now: Date) -> some View {
        let remainingSeconds = CalendarMeetingCountdown.remainingSeconds(
            deadline: presentation.deadline,
            now: now
        )
        let remainingFraction = CalendarMeetingCountdown.remainingFraction(
            startedAt: presentation.startedAt,
            deadline: presentation.deadline,
            now: now
        )

        return VStack(spacing: 0) {
            IndicatorFeedbackProgressBar(remainingFraction: remainingFraction)

            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(CalendarMeetingCountdownTypography.font)
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)

                    Text(countdownText(remainingSeconds))
                        .font(CalendarMeetingCountdownTypography.font)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .accessibilityIdentifier(countdownAccessibilityIdentifier)
                }

                Spacer(minLength: 4)

                Button(actionTitle, action: model.action(for: presentation))
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(CalendarMeetingCountdownTypography.font)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .accessibilityIdentifier(actionAccessibilityIdentifier)
                    .accessibilityHint(actionAccessibilityHint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, contentPadding)
        }
    }

    private var headline: String {
        presentation.kind.headline
    }

    private func countdownText(_ seconds: Int) -> String {
        switch presentation.kind {
        case .start:
            return String(
                format: String(localized: "calendarMeeting.countdown.startDetail"),
                Int32(seconds)
            )
        case .autoStop:
            if seconds == 1 {
                return String(localized: "calendarMeeting.autoStopIndicator.countdown.one")
            }
            return String.localizedStringWithFormat(
                String(localized: "calendarMeeting.autoStopIndicator.countdown.other"),
                Int64(seconds)
            )
        }
    }

    private var actionTitle: String {
        switch presentation.kind {
        case .start:
            String(localized: "calendarMeeting.countdown.cancel")
        case .autoStop:
            String(localized: "calendarMeeting.notification.continueAction")
        }
    }

    private var actionAccessibilityHint: String {
        switch presentation.kind {
        case .start:
            String(localized: "calendarMeeting.countdown.keyboardHint")
        case .autoStop:
            ""
        }
    }

    private var iconName: String {
        presentation.kind.isStart ? "record.circle" : "exclamationmark.triangle.fill"
    }

    private var iconColor: Color {
        presentation.kind.isStart ? .red : .orange
    }

    private var accessibilityLabel: String {
        headline
    }

    private var indicatorAccessibilityIdentifier: String {
        presentation.kind.isStart
            ? CalendarMeetingCountdownIndicatorAccessibility.startIndicator
            : CalendarMeetingCountdownIndicatorAccessibility.autoStopIndicator
    }

    private var countdownAccessibilityIdentifier: String {
        presentation.kind.isStart
            ? CalendarMeetingCountdownIndicatorAccessibility.startCountdown
            : CalendarMeetingCountdownIndicatorAccessibility.autoStopCountdown
    }

    private var actionAccessibilityIdentifier: String {
        presentation.kind.isStart
            ? CalendarMeetingCountdownIndicatorAccessibility.cancelStart
            : CalendarMeetingCountdownIndicatorAccessibility.continueRecording
    }
}
