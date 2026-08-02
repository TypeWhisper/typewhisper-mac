# Premium calendar meeting automation

Date: 2026-08-02

## Scope

TypeWhisper adds a premium, local-only automation for EventKit meetings from Zoom, Microsoft Teams, Google Meet, and FaceTime. Users explicitly choose Off, Reminder, or Automatic. Calendar access is never requested at launch or for users without a commercial license or active Premium account entitlement.

The implementation uses detached value types around a single long-lived `EKEventStore`, public CoreAudio process metadata, local notifications, a pure policy reducer, and the existing recorder finalization/transcription path. It adds no HTTP, plugin, sync, or public SDK API.

## Clean-room boundary

MacParakeet was inspected only as a behavioral and architectural research reference. The clean reference checkout is kept at `/Users/marco/Projects/macparakeet` on `main` (`b9ed08cd04c81128f06231afd2e64eae66bcaa6e`); its `v0.7.3` tag resolves to `d6321f87dccecf29bd4792113f522bb0c98d1f35`.

MacParakeet is GPLv3. No source file, implementation fragment, dependency, or generated artifact from that checkout is copied into or linked by TypeWhisper. This feature is independently implemented against Apple public APIs and TypeWhisper's existing internal interfaces.

The previous TypeWhisper experiment remains untouched at `/Users/marco/.codex/worktrees/c3bf/typewhisper-mac`, branch `seofood/meeting-auto-recording`, commit `9ed6d4ef7ad5118acffb78bef950f15f4dbbebd0`. Its large recorder rewrite is not reused.

## Architecture

- `EventKitCalendarMeetingProvider` owns one `EKEventStore` actor-isolated and emits detached calendars and occurrences.
- `MeetingLinkParser` canonicalizes only links found in EventKit URL, location, and notes fields.
- `BrowserURLResolver` centralizes the existing Safari/Chromium/Arc active-tab resolution; Firefox and Zen remain reminder-only.
- `MeetingAudioActivityCollector` listens to public CoreAudio process properties only while a join window is relevant and fails closed when unsupported.
- `CalendarMeetingAutomationPolicy` is a pure reducer for reminders, dwell, candidate ambiguity, start countdowns, idle retry, signal loss, and auto-stop.
- `CalendarMeetingAutomationController` is the MainActor coordinator and guards asynchronous work with generations and single-flight state.
- `CalendarMeetingNotificationService` stores only occurrence digests in notification metadata.
- `MeetingAutomationCountdownPanelController` presents nonactivating start and stop veto panels.
- `AudioRecorderViewModel` exposes one narrow calendar handle while preserving the existing capture, finalization, transcription, plugin-event, and API paths.

## Privacy and persistence

The calendar title is used only in local settings UI, local notifications, and the requested local recording filename. URLs, attendees, and titles are not logged, telemetered, synced, backed up, or placed in notification `userInfo`.

Suppression persists at most 256 SHA-256 occurrence digests. Calendar and provider selections remain local. Reminder requests are bounded to seven days and 48 occurrences.

## Stop semantics

Auto-stop is separately disabled by default and applies only to the exact calendar handle created while the option was enabled. Thirty seconds without input or output for the matched identity opens a 15-second veto panel. Signal return cancels the grace/countdown. “Continue recording” is sticky. Calendar end is never a stop signal. Gate or setting loss lets the recording continue and permanently detaches auto-stop for that recording.
