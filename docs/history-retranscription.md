# History re-transcription

History's **Re-transcribe…** action opens a two-step dialog for a saved recording. Step 1 selects an installed engine/model, a language or automatic detection, and an optional configured Workflow, then runs **Transcribe again**. Step 2 shows the **Current text** (marked *In use*) next to the **New result**; several results are switched with **Compare with**. Save or discard pending History edits before opening it.

Each successful run stores a result under the same entry. The active text, original metadata and recording remain unchanged until **Use this result** is confirmed. The final text is shown; a raw transcript that differs from it is collapsed below it, and both can be copied. The original and active versions cannot be deleted. Switching to a saved result also preserves any intervening edits as another local version. Retention, search, sync and statistics notes are collapsed under **Details**.

## Processing

- Engine, model, language and Workflow settings are captured for the run. The normal engine/model preferences are restored by the existing one-shot model override path. Engines with a selectable model but no restorable previous selection must first be configured in Integrations.
- A Workflow executes only its text transformation. Its destination, insertion, clipboard, export and action-plugin behavior is not invoked. The first resolved Workflow provider is pinned; no undisclosed fallback is attempted.
- Cloud audio/text processing shows the selected provider and requires confirmation, including notice of possible usage charges. Changing the choices clears consent.
- Missing synchronized audio requires a separate download confirmation. Retrieval uses the configured private sync storage, validates the asset hash/size, observes audio-sync/retention settings, and processes a temporary copy. The copy is removed afterward.
- Dictation, recorder, and file-transcription controls stay unavailable during a comparison. Background transcription requests, including recovery, dictionary training, and speaker timing, wait before accessing the shared engine. Cancellation retains the engine lease until the provider has stopped; a late result is discarded.
- Provider errors, empty results, missing models, cancellation, deleted/changed audio or changed/deleted entries do not save a version. A storage failure restores the entry's prior in-memory state and remains visible for retry.

## Versions, sync and retention

- Alternative versions are local to this Mac and are retained until explicitly discarded or their History entry is deleted/purged. They do not duplicate the audio.
- Search, ordinary copy and TXT/Markdown/JSON exports use the active entry. The comparison dialog copies any version's raw or final text explicitly.
- History/Inbox sync sends the active content and provenance through the existing content component. Alternatives are not sent. Promoting a version leaves Inbox status, recording time and duration unchanged.
- Word count on the History entry follows the active text. Re-runs do not count as new dictation sessions or modify lifetime usage statistics. Engine differences and promotion do not feed correction learning.
- Word times, segment times and speaker assignments belong to their version. Rewritten text does not inherit alignment from the original. Promotion sends an additive `alignmentResetAt` content field so updated clients discard older speaker components. Clients predating this field still receive active text, but require an update to invalidate their old speaker alignment; this includes the separate iOS implementation.
- Reusing raw text for a Workflow-only run is not part of this audio re-transcription action.

## Verification

```sh
xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TypeWhisperTests/HistoryRetranscriptionTests \
  -only-testing:TypeWhisperTests/HistoryServiceTests \
  -only-testing:TypeWhisperTests/SpeakerSyncHistoryTests \
  -only-testing:TypeWhisperTests/CloudFolderSyncTests \
  -only-testing:TypeWhisperTests/ModelManagerAppleSpeechModelSelectionTests \
  -only-testing:TypeWhisperTests/FileTranscriptionViewModelTests \
  -only-testing:TypeWhisperTests/AudioRecorderViewModelTests \
  -only-testing:TypeWhisperTests/DictationQuickSelectionTests \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Build and launch Direct with the private `build-typewhisper-mac-dev.sh --run <checkout>` helper; build and launch the sandboxed edition with `scripts/appstore/build-dev.sh --run`.

The debug screenshot states `history-comparison-before`, `history-comparison-first`, `history-comparison`, and `history-comparison-after` use isolated fixture data to show the same entry before promotion, in the dialog before any run, in the comparison dialog with a result, and after promotion. The after fixture calls the production promotion method. These states check English/German layout; they do not demonstrate a real provider run or a UI-click test. Launch the built app with `--store-screenshots --screenshot-state <state> -AppleLanguages '(de)' -preferredAppLanguage de` (or `en`). For a provider smoke test, use known speech with a locally installed model, compare the results, promote and revert a version, and verify the default engine/model afterward. Cloud and synchronized-audio runs require explicit consent in the dialog.

Tracked in [#1149](https://github.com/TypeWhisper/typewhisper-mac/issues/1149). The separate report of Apple Speech omitting the beginning of a recording is not fixed by this feature.

## Screenshots

These native app captures use isolated synthetic entries. The "before" images show the earlier comparison layout, before the usability changes; they are not screenshots of a released version. The result shown in the comparison is a fixture, not output from a live provider run.

| State | English | German |
| --- | --- | --- |
| Earlier comparison layout | [Before](screenshots/history-retranscription/before-en.png) | [Before](screenshots/history-retranscription/before-de.png) |
| First run, before creating a result | [First run](screenshots/history-retranscription/first-run-en.png) | [First run](screenshots/history-retranscription/first-run-de.png) |
| Current and new result | [Comparison](screenshots/history-retranscription/comparison-en.png) | [Comparison](screenshots/history-retranscription/comparison-de.png) |
| Mac App Store edition | [Comparison](screenshots/history-retranscription/app-store-comparison-en.png) | — |
