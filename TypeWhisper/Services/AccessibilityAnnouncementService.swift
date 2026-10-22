import Accessibility
import AppKit

@MainActor
class AccessibilityAnnouncementService {

    /// Announcements stay silent unless VoiceOver runs. Tests replace this to observe them.
    var isVoiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    /// Delivers an announcement. Tests replace this to observe the messages.
    var post: (_ message: String, _ isUrgent: Bool) -> Void = { message, isUrgent in
        AccessibilityNotification.Announcement(
            AccessibilityAnnouncementService.announcement(message, isUrgent: isUrgent)
        ).post()
    }

    /// The announcement text with its speech priority. As documented for the
    /// announcement priorities, high interrupts current speech and is not
    /// interrupted itself, so errors and warnings are heard in full. Default also
    /// interrupts current speech but gives way to the next announcement, so a newer
    /// status or a newly highlighted entry replaces an older one instead of queueing.
    nonisolated static func announcement(_ message: String, isUrgent: Bool) -> AttributedString {
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = isUrgent ? .high : .default
        return announcement
    }

    /// Speaks the entry a list highlights while VoiceOver's cursor stays elsewhere,
    /// such as a palette driven by the arrow keys. Each highlight replaces the
    /// previous one and is not held back by the duplicate filter.
    static func announceHighlight(_ label: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, !label.isEmpty else { return }
        AccessibilityNotification.Announcement(announcement(label, isUrgent: false)).post()
    }

    /// Current time, replaceable in tests.
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }
    /// A message repeated within this window is spoken once. Some paths show the
    /// same error banner twice in a row, e.g. as feedback and then as an error.
    static let duplicateWindow: Duration = .seconds(1)

    private var lastAnnouncement: (message: String, time: ContinuousClock.Instant)?

    func announce(_ message: String, isUrgent: Bool = false) {
        guard isVoiceOverEnabled() else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let time = now()
        if let lastAnnouncement,
           lastAnnouncement.message == trimmed,
           time - lastAnnouncement.time < Self.duplicateWindow {
            return
        }
        lastAnnouncement = (trimmed, time)
        post(trimmed, isUrgent)
    }

    func announceRecordingStarted() {
        announce(String(localized: "Recording started"))
    }

    func announceRecordingStopped() {
        announce(localizedAppText(
            "Recording stopped, transcribing",
            de: "Aufnahme beendet, wird transkribiert",
            ja: "録音を停止しました。文字起こし中",
            zh: "录音已停止，正在转录"
        ))
    }

    /// A toggle dictation that ended on its own after the configured silence (#1023).
    func announceRecordingStoppedAfterSilence() {
        announce(String(localized: "Recording stopped after silence, transcribing"))
    }

    func announceTranscriptionComplete(wordCount: Int) {
        announce(String(localized: "Transcription complete, \(wordCount) words"))
    }

    func announceError(_ reason: String) {
        announce(String(localized: "Error: \(reason)"), isUrgent: true)
    }

    /// Feedback the dictation indicator shows as a banner, which VoiceOver users
    /// cannot otherwise notice while they work in another app.
    func announceFeedback(_ message: String, isError: Bool) {
        if isError {
            announceError(message)
        } else {
            announce(message)
        }
    }

    /// A warning the indicator shows during a recording, such as the cancel
    /// confirmation or a silent microphone. These use the replaceable default
    /// priority, so the result that follows (e.g. "Cancelled") or an error is not
    /// held back. Time-critical warnings, such as a countdown, pass `isUrgent`.
    func announceWarning(_ message: String, isUrgent: Bool = false) {
        announce(message, isUrgent: isUrgent)
    }
}
