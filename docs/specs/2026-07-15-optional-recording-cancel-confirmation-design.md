# Optional Recording Cancel Confirmation

## Context

TypeWhisper intentionally requires two Escape presses before cancelling an active dictation recording. This protects long recordings from accidental global Escape presses. Some users prefer a faster cancellation path and accept the risk of immediately discarding the active recording.

The preference must remain an expert option and must not add more visual weight to the primary Recording or Hotkeys settings.

## Design

Add one toggle to the existing **Advanced > Recording** section:

- Label: **Require second Esc press to cancel recording**
- Help text: **When disabled, pressing Esc once immediately discards the active recording.**
- Default: enabled

No new settings page or section is introduced.

## Behavior

- With the preference enabled, the current behavior is unchanged: the first Escape press shows the cancellation warning and the second press cancels the active recording.
- With the preference disabled, the first Escape press immediately cancels and discards the active recording.
- The preference applies only while `DictationViewModel` is in the `.recording` state.
- Cancellation during `.processing` remains unchanged and continues to require two Escape presses.
- The Audio Recorder feature and its recordings are not affected.

## Persistence and Integration

- Add a boolean `UserDefaultsKeys` entry for the preference.
- Expose the persisted value through `DictationViewModel`, following its existing load/persist helpers for advanced recording preferences.
- Default to `true` when the key is absent so existing and upgraded installations retain the safe behavior.
- Branch in `handleCancelHotkey()` only for the `.recording` target. Reuse the existing immediate cancellation path rather than introducing a second cancellation implementation.

## Localization and Accessibility

- Add English, German, and Japanese localizations for the toggle label and help text.
- Use the existing `SettingsInfoLabel` pattern so the risk explanation is available consistently and exposed to accessibility clients.

## Verification

Add focused regression coverage proving:

1. The absent preference defaults to requiring confirmation.
2. The first Escape press during recording only warns when confirmation is enabled.
3. A second Escape press cancels when confirmation is enabled.
4. A single Escape press cancels during recording when confirmation is disabled.
5. Disabling recording confirmation does not change the two-press processing cancellation behavior.
6. Preference persistence round-trips through `UserDefaults`.

Run the focused `APIRouterAndHandlersTests` cancellation tests and the relevant settings/defaults tests, followed by the normal project build or broader test suite appropriate for the changed files.

## Non-Goals

- Making Escape configurable or removable.
- Changing cancellation behavior during transcription processing.
- Adding workflow-specific or profile-specific overrides.
- Changing Audio Recorder controls.
