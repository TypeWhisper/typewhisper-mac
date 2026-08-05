# Premium calendar meeting automation

Date: 2026-08-02

Last updated: 2026-08-05

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
- `BrowserURLResolver` centralizes the existing Safari/Chromium/Arc active-tab resolution. `BrowserAudioProcessAttribution` maps the exact main bundle identifier plus the explicitly allowed `.helper` and `.helper.renderer` forms back to the canonical Chrome, Chrome Canary, Brave, Edge, Arc, Opera, Vivaldi, Chromium, or Wavebox identifier. A Safari live test on current macOS showed meeting I/O attributed to the exact `com.apple.WebKit.GPU` process, so that one process identifier is explicitly mapped to Safari; `WebContent`, `Networking`, lookalike, and other WebKit services remain rejected. The mapping only selects Safari for active-URL resolution, and the controller still requires an exact canonical calendar-link match. Updaters, alert services, Firefox, and Zen are rejected.
- `MeetingAudioActivityCollector` listens to public CoreAudio process properties only while a join window is relevant. Process-list and per-process activity properties are required and fail closed when unsupported; the HAL service-restart listener is optional and installed only when advertised by the current system. While those listeners are installed, a deduplicated one-second snapshot reconciliation recovers process activity transitions that some macOS versions do not deliver through the per-process callback. A helper retains its real PID and audio object for listener ownership while snapshots expose the canonical browser identifier. The controller combines input and output across helpers and resolves the active URL once per canonical browser and snapshot. It is stopped together with the collector and never runs in Free, Off, or outside relevant join/auto-stop windows.
- `MeetingCameraActivityCollector` observes only the public CoreMediaIO `DeviceIsRunningSomewhere` property while at least one join window is open. It neither requests camera permission nor reads image frames, device content, or application identity. Camera presence can back a unique eligible occurrence when process input is unavailable; exact browser URL or native-provider evidence still outranks generic camera presence. Camera state is discarded once recording starts and never becomes an auto-stop identity signal.
- Native process attribution includes Zoom and both Teams bundle identifiers. For FaceTime it accepts the app process plus Apple's `com.apple.FaceTime.FTConversationService`, `com.apple.avconferenced`, and `com.apple.TelephonyUtilities` call services because recent macOS versions attribute FaceTime I/O to those services. These processes become a meeting signal only while a matching FaceTime calendar occurrence is already inside its join window.
- `CalendarMeetingAutomationPolicy` is a pure reducer for reminders, dwell, candidate ambiguity, start countdowns, idle retry, signal loss, and auto-stop.
- `CalendarMeetingAutomationController` is the MainActor coordinator and guards asynchronous work with generations and single-flight state.
- `CalendarMeetingNotificationService` stores only occurrence digests in notification metadata and owns both scheduled meeting reminders and the immediate auto-stop warning.
- `CalendarMeetingCountdownModel` exposes one generation-guarded start-or-stop presentation to the existing recording indicators. Start presentations may contain the local event title; stop presentations remain title-free. Neither presentation contains URLs, participants, recorder handles, or output paths.
- The selected Notch, Overlay, or Minimal indicator is the only five-second start-countdown surface. No separate AppKit countdown panel or start-countdown notification is created.
- `AudioRecorderViewModel` exposes one narrow calendar handle while preserving the existing capture, finalization, transcription, plugin-event, and API paths.

## Privacy and persistence

The calendar title is used only in local settings UI, local notifications, and the requested local recording filename. URLs, attendees, and titles are not logged, telemetered, synced, backed up, or placed in notification `userInfo`.

Suppression and the reminder-delivery ledger each persist at most 256 SHA-256 occurrence digests. Calendar and provider selections remain local. Reminder requests are bounded to seven days and 48 occurrences. If an eligible event first appears after its five-minute fire time but before the end of its join window, TypeWhisper sends one immediate catch-up reminder. A rescheduled occurrence has a new digest and is evaluated independently.

## Start semantics

Upcoming notifications never start the recorder directly. In Reminder mode, the explicit “Start When I Join” action stores only the occurrence digest in the in-memory policy state. TypeWhisper must remain running after that action. The arm is discarded on process shutdown and is never written to defaults, sync, backup data, telemetry, or notification metadata.

An armed occurrence starts only after matching join evidence remains stable for three seconds and the cancellable five-second countdown in the selected recording indicator completes. Preferred evidence is attributed CoreAudio input: native providers match their process family, while browsers require an exact canonical URL. If a browser helper exposes only output, an active camera can combine with that exact URL; input and output may come from different helpers. As a lower-confidence fallback, camera activity alone may select exactly one eligible calendar occurrence. Competing equally ranked occurrences fail closed, and output-only audio never starts without camera activity. Firefox and Zen receive no automatic URL attribution; without the unique camera fallback they remain reminder-only.

The indicator shows the local event title, remaining time, deadline-based progress, and Cancel. A real join before the scheduled start is valid inside the existing window from ten minutes before start through thirty minutes after end. Signal loss dismisses the current countdown but preserves the arm so a later stable rejoin may try again. Explicit countdown cancellation, including Command-Period, suppresses and disarms the occurrence. Unsupported activity metadata and ambiguous candidates fail closed without a calendar-time fallback.

In Automatic mode, the five-minute notification is status-only and offers suppression rather than a redundant start action. Its body explains that recording begins after the user joins. In Reminder mode, the later detected-meeting notification retains “Start Recording”, but that action also maps to the in-memory arm and the same countdown instead of bypassing live detection. A single armed occurrence may disambiguate overlapping unarmed candidates; equally ranked armed candidates never auto-start.

The legacy notification start identifier remains registered for requests scheduled by older builds, but its response is mapped to the same arm behavior. Default notification clicks still open Premium settings and never arm or start a recording. User info remains limited to the occurrence digest and notification kind.

## Stop semantics

Auto-stop is separately disabled by default and applies only to the exact calendar handle created while the option was enabled. It can be enabled and armed only while macOS notification authorization permits alerts. If that permission is unavailable or later revoked, the persisted auto-stop option is switched off; an existing recording continues and is permanently detached from auto-stop.

For browser recordings, a successfully resolved active URL that is no longer a recognized meeting URL is positive evidence that the recorded meeting identity is absent; it starts the normal auto-stop warning path. Only a genuinely unavailable URL resolution, such as denied automation access or a resolver timeout, fails closed and detaches auto-stop rather than risking an unintended stop.

The first snapshot without input or output for the matched identity immediately expands the currently selected Notch, Overlay, or Minimal recording indicator with “Meeting seems to have ended”, the live 15-second countdown, progress, and “Continue recording”. Start and stop use the same system font metrics throughout the shared countdown surface. The warning temporarily overrides the user's Never visibility setting and normal fullscreen suppression, but does not activate TypeWhisper or create a separate window. The original indicator visibility, placement, and capture settings resume as soon as the warning ends.

Countdown buttons and background notification actions suppress the corresponding transient AppKit reopen event. They perform their calendar action without opening or flashing the Settings window; an explicit notification default click for non-auto-stop reminders continues to open Premium settings as designed.

At the same time, TypeWhisper publishes the same warning as a time-sensitive native notification. macOS can still suppress its banner while the display is shared, so this notification is an additional surface and the recording indicator is the reliable warning surface. The indicator button, notification action, and notification default click all enter the same validated sticky-veto path. Explicitly dismissing the notification does not veto the stop. A returned meeting signal must remain present for three uninterrupted seconds before both warning surfaces are removed. This prevents brief post-call CoreAudio activity from dismissing and immediately restarting the countdown, while a genuine rejoin still cancels the stop. Continue responses are accepted only while the occurrence digest and calendar recording handle match the currently presented warning; the presentation model rejects actions from replaced generations.

Without a veto, the existing pure policy requests exactly one stop when the same 15-second warning deadline passes. The indicator and notification are presentation only and do not own or pause the timer; hover and focus do not extend it. Focus modes, display sharing, and other system policy may delay or hide the native notification. Calendar end is never a stop signal. Gate or setting loss removes both warning surfaces, lets the recording continue, and permanently detaches auto-stop for that recording.

## Premium settings experience

The Premium settings page is a native feature hub rather than one long configuration form. It always presents three equally weighted cards for meeting automation, correction learning, and dictionary/snippet sync. Each card explains the benefit, shows no more than two local status lines, and reports its actual entitlement requirement. The existing product gates remain unchanged: meeting automation accepts a Commercial license or Premium account entitlement, correction learning requires Commercial, and cloud sync requires a signed-in Premium account.

Free and Supporter-only states render static preview cards plus one unlock action. They do not construct or query EventKit, notification, CoreAudio, or browser services. No calendar title or meeting URL is added to the overview.

Available feature cards open separate, nonmodal, resizable AppKit windows, matching the established plugin-settings behavior. One window is retained per feature, re-opening focuses it, and frames are autosaved. The account/license controls use the same window pattern. If access is lost while a feature window is open, its controls are replaced by a locked explanation; the underlying automation and recording gate semantics remain authoritative.

A signed-in account with an active local Commercial license but no linked account entitlement is shown as “Connect purchase”, not as a generic missing-account state. The access window offers an explicit link action through the existing Polar device-attachment endpoint. Missing entitlements are refreshed on launch even when a recent empty result exists; the seven-day refresh throttle applies only to an already active, cryptographically verified entitlement.

The meeting automation window communicates that auto-stop requires macOS notifications. The option cannot remain enabled when that permission is missing. It offers the existing notification-settings action rather than silently falling back to a custom window.

## Auto-stop warning verification

- Notification categories include a dedicated auto-stop category and a non-foreground “Continue recording” action.
- Only the auto-stop notification uses the time-sensitive interruption level; foreground presentation requests banner, list, and sound.
- The notification payload contains only the occurrence digest and action kind; it contains no title, URL, participant, recorder path, or public handle.
- Notch, Overlay, and Minimal reuse one warning view and one MainActor presentation model. Only the selected style is shown.
- The warning temporarily overrides Never visibility and fullscreen suppression, accepts first-mouse interaction, and remains a nonactivating panel that cannot become key or main.
- Default click and “Continue recording” veto only the matching active occurrence.
- Dismissal leaves the 15-second stop deadline active.
- Three seconds of uninterrupted signal return remove the indicator plus pending and delivered notifications and prevent the stop; shorter activity flaps leave the original countdown untouched.
- Missing or revoked notification permission turns auto-stop off and never stops the current recording.
- Start and auto-stop share the same generation-protected indicator presentation model. Typed dismissal prevents a late start dismissal from removing a newer stop warning and vice versa.
- Both countdown kinds temporarily override Never visibility and fullscreen suppression while preserving nonactivating panels and first-mouse button interaction.
- Countdown progress is calculated from start time, deadline, and the current timeline date. Normal motion uses at most a 30 Hz animation timeline and a fixed-width scale transform; Reduce Motion updates once per second. No countdown ticker exists without an active presentation.
- Overlay start countdowns use a standalone indicator pill without an empty recorder-status row. Auto-stop retains the active recorder row and warning content.
