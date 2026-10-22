# Premium calendar meeting automation

Date: 2026-08-02

Last updated: 2026-10-17

## Scope

TypeWhisper adds a premium, local-only automation for EventKit meetings from Zoom, Microsoft Teams, Google Meet, FaceTime, and Kontur Talk. Users explicitly choose Off, Reminder, or Automatic. Calendar access is never requested at launch or for users without a commercial license or active Premium account entitlement.

An independent, disabled-by-default “Detect calls without a calendar event” option also supports Zoom, Teams, and Kontur Talk app microphone activity and recognized browser meeting links, including Google Meet in background tabs. It uses the same Off, Reminder, or Automatic mode and provider selection. This option works without EventKit access and does not prompt for calendar permission. It does not connect to Microsoft 365: Outlook-only and ad-hoc calls are detected from local app activity.

The implementation uses detached value types around a single long-lived `EKEventStore`, public CoreAudio process metadata, local notifications, a pure policy reducer, and the existing recorder finalization/transcription path. It adds no HTTP, plugin, sync, or public SDK API.

## Clean-room boundary

MacParakeet was inspected only as a behavioral and architectural research reference. The clean reference checkout is kept at `/Users/marco/Projects/macparakeet` on `main` (`b9ed08cd04c81128f06231afd2e64eae66bcaa6e`); its `v0.7.3` tag resolves to `d6321f87dccecf29bd4792113f522bb0c98d1f35`.

MacParakeet is GPLv3. No source file, implementation fragment, dependency, or generated artifact from that checkout is copied into or linked by TypeWhisper. This feature is independently implemented against Apple public APIs and TypeWhisper's existing internal interfaces.

The previous TypeWhisper experiment remains untouched at `/Users/marco/.codex/worktrees/c3bf/typewhisper-mac`, branch `seofood/meeting-auto-recording`, commit `9ed6d4ef7ad5118acffb78bef950f15f4dbbebd0`. Its large recorder rewrite is not reused.

## Architecture

- `EventKitCalendarMeetingProvider` owns one `EKEventStore` actor-isolated and emits detached calendars and occurrences.
- `MeetingLinkParser` canonicalizes only links found in EventKit URL, location, and notes fields.
- `BrowserURLResolver` keeps active-tab resolution for dictation and website workflows, and provides a separate bounded, timed query of all open tab URLs for meeting detection. `BrowserAudioProcessAttribution` maps the exact main bundle identifier plus the explicitly allowed `.helper` and `.helper.renderer` forms back to the canonical Chrome, Chrome Beta, Chrome Dev, Chrome Canary, Brave, Edge, Arc, Opera, Vivaldi, Chromium, or Wavebox identifier. Every Chrome release channel ships helpers named `com.google.Chrome.helper`, and CoreAudio reports that identifier for Chrome Beta's audio too, so a helper is attributed to the supported browser app bundle that contains its executable; a helper inside an unsupported app is rejected, and the helper identifier alone decides only when the executable path or host bundle cannot be read. A Safari live test on current macOS showed meeting I/O attributed to the exact `com.apple.WebKit.GPU` process, so that one process identifier is explicitly mapped to Safari; `WebContent`, `Networking`, lookalike, and other WebKit services remain rejected. The mapping selects Safari for tab-URL resolution. Detection requires a recognized canonical meeting link; multiple different meeting links fail closed for a new start. An existing recording can retain its exact identity in a background tab. Updaters, alert services, Firefox, and Zen are rejected.
- `MeetingAudioActivityCollector` listens to public CoreAudio process properties while a calendar join window is relevant, auto-stop is tracking a recording, or ad-hoc detection is explicitly enabled. Process-list and per-process activity properties are required and fail closed when unsupported; the HAL service-restart listener is optional and installed only when advertised by the current system. While those listeners are installed, a deduplicated one-second snapshot reconciliation recovers process activity transitions that some macOS versions do not deliver through the per-process callback. A helper retains its real PID and audio object for listener ownership while snapshots expose the canonical browser identifier. The controller combines input and output across helpers and resolves the open tab URLs once per canonical browser and snapshot. While collecting, a one-second controller tick also refreshes tab identity when CoreAudio activity is unchanged. It is stopped together with the collector and never runs in Free or Off; outside join/auto-stop windows it runs only with ad-hoc detection enabled.
- `MeetingCameraActivityCollector` observes only the public CoreMediaIO `DeviceIsRunningSomewhere` property while at least one join window is open. It neither requests camera permission nor reads image frames, device content, or application identity. Camera presence can back a unique eligible occurrence when process input is unavailable; exact browser URL or native-provider evidence still outranks generic camera presence. Camera state is discarded once recording starts and never becomes an auto-stop identity signal.
- Native process attribution includes Zoom, both Teams bundle identifiers, and Kontur Talk (`kontur.talk`; its Electron `kontur.talk.helper*` processes count as the app). Kontur Talk rooms in the browser are recognized as `<space>.ktalk.ru/<room>`; app pages such as `/chats` or `/calendar` are not meeting identities. For FaceTime it accepts the app process plus Apple's `com.apple.FaceTime.FTConversationService`, `com.apple.avconferenced`, and `com.apple.TelephonyUtilities` call services because recent macOS versions attribute FaceTime I/O to those services. These processes become a meeting signal only while a matching FaceTime calendar occurrence is already inside its join window.
- `CalendarMeetingAutomationPolicy` is a pure reducer for reminders, dwell, candidate ambiguity, start countdowns, idle retry, signal loss, and auto-stop.
- `CalendarMeetingAutomationController` is the MainActor coordinator and guards asynchronous work with generations and single-flight state.
- `CalendarMeetingNotificationService` stores only occurrence digests in notification metadata and owns both scheduled meeting reminders and the immediate auto-stop warning.
- `CalendarMeetingCountdownModel` exposes one generation-guarded start-or-stop presentation to the existing recording indicators. Start presentations may contain the local event title; stop presentations remain title-free. Neither presentation contains URLs, participants, recorder handles, or output paths.
- The bottom overlay is the only five-second start-countdown surface, independent of the preferred Notch, Overlay, or Minimal style. No separate AppKit countdown panel or start-countdown notification is created.
- `AudioRecorderViewModel` exposes one narrow calendar handle while preserving the existing capture, finalization, transcription, plugin-event, and API paths.

## Privacy and persistence

The calendar title is used only in local settings UI, local notifications, and the requested local recording filename. URLs, attendees, and titles are not logged, telemetered, synced, backed up, or placed in notification `userInfo`.

Suppression and the reminder-delivery ledger each persist at most 256 SHA-256 occurrence digests. Calendar and provider selections remain local. Reminder requests are bounded to seven days and 48 occurrences. If an eligible event first appears after its five-minute fire time but before the end of its join window, TypeWhisper sends one immediate catch-up reminder. A rescheduled occurrence has a new digest and is evaluated independently.

Explicit start handoff or user-dismissal cleanup preserves the delivery ledger entry, including when the user arms the occurrence. Restarting the app discards the arm without repeating that reminder. A configuration change that interrupts a countdown, an in-flight recording start, or a deferred start explicitly resets the entry only if the occurrence is eligible for a restored reminder; the next successful request records it again. If automation is switched off or the occurrence is temporarily unavailable, the policy retains this restoration intent in memory until the occurrence becomes eligible again or its join window expires.

Start notification requests use fresh identifiers so delayed removal of an older request cannot delete a restored copy. Cleanup finds pending and delivered copies by occurrence, including after a relaunch. When reconciliation or automation shutdown removes an unhandled upcoming reminder or detected replacement, it clears that occurrence's reminder ledger entry so an eligible returning occurrence can restore the prompt even without new join evidence. Requests already removed for handoff keep their ledger entry even if asynchronous cleanup still exposes them in a later snapshot. Eligible catch-up and detected prompts stay pending through refreshes until delivery; explicit handoff and automation shutdown still remove them.

If an eligible occurrence changes between Automatic and Reminder, reconciliation compares the actual categories of pending and delivered reminders with the effective mode. It replaces obsolete actions, including legacy categories and prompts retained across a relaunch. The original remains available until the replacement is successfully scheduled. Unchanged categories and prompts already accepted for handoff remain deduplicated, including while old copies await asynchronous removal.

## Start semantics

Upcoming notifications never start the recorder directly. In Reminder mode, the explicit “Start When I Join” action stores only the occurrence digest in the in-memory policy state. TypeWhisper must remain running after that action. The arm is discarded on process shutdown and is never written to defaults, sync, backup data, telemetry, or notification metadata.

An armed occurrence starts only after matching join evidence remains stable for three seconds and the cancellable five-second countdown in the bottom overlay completes. Preferred evidence is attributed CoreAudio input: native providers match their process family, while browsers require an exact canonical URL. If a browser helper exposes only output, an active camera can combine with that exact URL; input and output may come from different helpers. As a lower-confidence fallback, camera activity alone may select exactly one eligible calendar occurrence. Competing equally ranked occurrences fail closed, and output-only audio never starts without camera activity. Firefox and Zen receive no automatic URL attribution; without the unique camera fallback they remain reminder-only.

If recording becomes busy after the countdown has taken over, the deferred start keeps its reminder suppressed while waiting to retry. A recorder that was already busy before any countdown leaves the original reminder available. The indicator shows the local event title, remaining time, deadline-based progress, and Cancel. A real join before the scheduled start is valid inside the existing window from ten minutes before start through thirty minutes after end. Signal loss dismisses the current countdown or deferred start. An automatic occurrence restores its eligible reminder immediately without waiting for a calendar refresh; an explicitly armed occurrence keeps its consent and reminder deduplication so a later stable rejoin may try again. Explicit countdown cancellation, including Command-Period, suppresses and disarms the occurrence. Unsupported activity metadata and ambiguous candidates fail closed without a calendar-time fallback.

If readiness changes while the recorder start is awaiting completion, cancelling that in-flight start also restores an eligible automatic reminder without a calendar refresh. Explicitly armed reminders keep their consent and deduplication. A late cancellation for a start that is no longer requested cannot dismiss a newer countdown.

Automatic restoration after a lost countdown, deferred start, or cancelled recording start requests at most one immediate catch-up reminder per active occurrence. Repeated join-and-loss cycles can retry recording but do not keep posting audible banners. Future reminders can still be rescheduled after each interrupted handoff because scheduling them does not alert immediately.

In Automatic mode, the five-minute notification is status-only and offers suppression rather than a redundant start action. Its body explains that recording begins after the user joins. In Reminder mode, the later detected-meeting notification retains “Start Recording”, but that action also maps to the in-memory arm and the same countdown instead of bypassing live detection. A single armed occurrence may disambiguate overlapping unarmed candidates; equally ranked armed candidates never auto-start.

The legacy notification start identifier remains registered for requests scheduled by older builds, but its response is mapped to the same arm behavior. Default notification clicks open Recorder and never arm or start a recording. User info remains limited to the occurrence digest and notification kind.

## Calls without calendar events

Meeting-tab queries use a separate operation queue with at most two concurrent `osascript` subprocesses so a stalled in-process AppleScript used by dictation cannot starve meeting detection, and one slow browser does not block another. Each subprocess is terminated after two seconds; its independent 2.5-second fallback starts when the queued operation begins, so waiting for a worker cannot produce a false browser-unavailable result. Timeout diagnostics never include tab URLs or titles.

`BrowserURLResolverTests.testLiveMeetingTabsResolveWhileActiveAppleScriptIsBlocked` is an opt-in live regression test. Open a disposable test URL in a supported browser, then set `TEST_RUNNER_TYPEWHISPER_TEST_BROWSER_BUNDLE_ID` and `TEST_RUNNER_TYPEWHISPER_TEST_BROWSER_URL` when running that test with `xcodebuild test`. It verifies the real tab query while an in-process AppleScript is blocked; normal test runs skip it without those explicit inputs. `MeetingAudioActivityCollectorTests.testLiveBrowserAudioIsAttributedToItsHostBrowser` is the matching opt-in CoreAudio check: play audio in the selected browser and set `TEST_RUNNER_TYPEWHISPER_TEST_AUDIO_BROWSER_BUNDLE_ID` to verify that its helper is attributed to that browser rather than to another Chrome release channel.

Ad-hoc native calls require five seconds of attributed microphone activity; browser calls require twenty seconds plus exactly one recognized meeting identity across open tabs. Both then use the cancellable five-second start countdown. Reminder mode publishes a detected-call notification and waits for the explicit Start action. Output-only activity and generic camera presence cannot start an ad-hoc recording. FaceTime's shared telephony services remain calendar-only.

A matching selected calendar event takes precedence, including its declined/suppressed state; ad-hoc detection does not bypass it. Detected sessions have ephemeral IDs, use a provider-based filename, and never export fabricated calendar metadata. A ninety-second gap permits a new session; shorter gaps preserve cancellation and recorded-session state. Active recordings retain their session until stopped. Auto-stop waits through ninety seconds without matching activity before showing the existing fifteen-second warning.

CoreAudio attributes browser audio to the browser process, not to an individual tab. A unique meeting tab plus microphone activity is still a heuristic: an unrelated microphone-using tab can be misattributed. The feature remains opt-in, supports Reminder mode, and refuses ambiguous meeting identities. Browser automation denial/timeouts detach auto-stop without stopping the recording.

## Stop semantics

Auto-stop is separately disabled by default and applies only to the exact calendar handle created while the option was enabled. Its setting and in-app countdown work independently of macOS notification authorization. Permission denial, revocation, or notification delivery failure does not reset the preference or dismiss the warning. The bottom countdown overlay retains the validated Continue recording action.

For browser recordings, a successful tab snapshot without the recorded meeting identity is evidence that the identity is absent; it starts the normal auto-stop warning path. Only a genuinely unavailable URL resolution, such as denied automation access or a resolver timeout, fails closed and detaches auto-stop rather than risking an unintended stop.

For calendar recordings, the first snapshot without input or output for the matched identity immediately shows a bottom overlay with “Meeting seems to have ended”, the live 15-second countdown, progress, and “Continue recording”. Start and stop use the same system font metrics throughout the shared countdown surface. The warning temporarily overrides the user's Never visibility setting and normal fullscreen suppression, but does not activate TypeWhisper or create a separate window. Start and stop countdowns temporarily use the bottom overlay regardless of the preferred Notch, Overlay, or Minimal style. The original indicator style, visibility, placement, and capture settings resume as soon as the countdown ends.

Countdown buttons and background notification actions suppress the corresponding transient AppKit reopen event. They perform their calendar action without opening or flashing the Settings window; an explicit notification default click for non-auto-stop reminders opens Recorder without arming or starting a recording.

When macOS allows it, TypeWhisper also publishes the same warning as a time-sensitive native notification. macOS can still suppress its banner while the display is shared, so this notification is an additional surface and the bottom countdown overlay is the reliable warning surface. The indicator button, notification action, and notification default click all enter the same validated sticky-veto path. Explicitly dismissing the notification does not veto the stop. A returned meeting signal must remain present for three uninterrupted seconds before both warning surfaces are removed. This prevents brief post-call CoreAudio activity from dismissing and immediately restarting the countdown, while a genuine rejoin still cancels the stop. Continue responses are accepted only while the occurrence digest and calendar recording handle match the currently presented warning; the presentation model rejects actions from replaced generations.

Without a veto, the existing pure policy requests exactly one stop when the same 15-second warning deadline passes. The indicator and notification are presentation only and do not own or pause the timer; hover and focus do not extend it. Focus modes, display sharing, and other system policy may delay or hide the native notification. Calendar end is never a stop signal. Gate or setting loss removes both warning surfaces, lets the recording continue, and permanently detaches auto-stop for that recording.

## Premium settings experience

The Premium settings page is a native feature hub rather than one long configuration form. It always presents three equally weighted cards for meeting automation, correction learning, and dictionary/snippet sync. Each card explains the benefit, shows no more than two local status lines, and reports its actual entitlement requirement. The existing product gates remain unchanged: meeting automation accepts a Commercial license or Premium account entitlement, correction learning requires Commercial, and cloud sync requires a signed-in Premium account.

Free and Supporter-only states render static preview cards plus one unlock action. They do not construct or query EventKit, notification, CoreAudio, or browser services. No calendar title or meeting URL is added to the overview.

Available feature cards open separate, nonmodal, resizable AppKit windows, matching the established plugin-settings behavior. One window is retained per feature, re-opening focuses it, and frames are autosaved. The account/license controls use the same window pattern. If access is lost while a feature window is open, its controls are replaced by a locked explanation; the underlying automation and recording gate semantics remain authoritative.

A signed-in account with an active local Commercial license but no linked account entitlement is shown as “Connect purchase”, not as a generic missing-account state. The access window offers an explicit link action through the existing Polar device-attachment endpoint. Missing entitlements are refreshed on launch even when a recent empty result exists; the seven-day refresh throttle applies only to an already active, cryptographically verified entitlement.

The meeting automation window explains that notifications are optional for automatic recording and auto-stop. It keeps the auto-stop preference enabled without that permission and explains the in-app warning. Reminder mode still requires notification permission. Ad-hoc detection exposes provider selection and auto-stop even without calendar access.

## Auto-stop warning verification

- Notification categories include a dedicated auto-stop category and a non-foreground “Continue recording” action.
- Only the auto-stop notification uses the time-sensitive interruption level; foreground presentation requests banner, list, and sound.
- The notification payload contains only the occurrence digest and action kind; it contains no title, URL, participant, recorder path, or public handle.
- Start and stop countdowns share one warning view and one MainActor presentation model in the bottom overlay. The preferred Notch, Overlay, or Minimal style resumes afterward.
- The warning temporarily overrides Never visibility and fullscreen suppression, accepts first-mouse interaction, and remains a nonactivating panel that cannot become key or main.
- Default click and “Continue recording” veto only the matching active occurrence.
- Dismissal leaves the 15-second stop deadline active.
- Three seconds of uninterrupted signal return remove the indicator plus pending and delivered notifications and prevent the stop; shorter activity flaps leave the original countdown untouched.
- Missing/revoked notification permission and failed delivery preserve auto-stop and the in-app Continue recording action; tests cover calendar and ad-hoc sessions.
- Start and auto-stop share the same generation-protected indicator presentation model. Typed dismissal prevents a late start dismissal from removing a newer stop warning and vice versa.
- Both countdown kinds temporarily override Never visibility and fullscreen suppression while preserving nonactivating panels and first-mouse button interaction.
- Countdown progress is calculated from start time, deadline, and the current timeline date. Normal motion uses at most a 30 Hz animation timeline and a fixed-width scale transform; Reduce Motion updates once per second. No countdown ticker exists without an active presentation.
- Overlay start countdowns use a standalone indicator pill without an empty recorder-status row. Auto-stop retains the active recorder row and warning content.
