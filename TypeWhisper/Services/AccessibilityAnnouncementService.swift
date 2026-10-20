import Accessibility
import AppKit

@MainActor
class AccessibilityAnnouncementService {

    /// Announcements stay silent unless VoiceOver runs. Tests replace this to observe them.
    var isVoiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    /// Delivers an announcement. Tests replace this to observe the messages.
    var post: (_ message: String, _ isUrgent: Bool) -> Void = { message, isUrgent in
        var announcement = AttributedString(message)
        // Errors interrupt; status updates wait until VoiceOver finishes speaking.
        announcement.accessibilitySpeechAnnouncementPriority = isUrgent ? .high : .default
        AccessibilityNotification.Announcement(announcement).post()
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
    /// confirmation or a silent microphone.
    func announceWarning(_ message: String) {
        announce(message, isUrgent: true)
    }
}
