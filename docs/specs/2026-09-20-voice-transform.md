# Voice Transform

Status: implemented on branch `transform`. User reports successful live transform use;
remaining cross-app and edge-case checks are tracked in the manual test checklist.

Implemented: scoped snippets and resolver; dedicated configurable shortcut;
independent instruction recording; global workflow LLM fallback routing; editable
preview, bounded diff, Copy, Retry, Cancel, and guarded replacement. Normal
dictation and recorder entry points reject capture while a transform is busy.
Instruction audio uses a separate recorder with recovery persistence disabled.
The source, prompt, and candidate are cleared when the preview closes or applies.

Pending: broader cross-app/Accessibility checks, legacy on-disk schema
migration verification, and optional selection-palette entry point. The feature
is configured through Settings -> Transform; no default binding
is assigned. This PR is not yet a claim of tested support for every target app.

## Settings and manual testing

Settings → Transform groups the dedicated shortcut, window preferences, limits,
and transform-enabled prompt snippets (including Both). New prompts from this page
default to Voice Transform. Snippets remain one shared store; the existing Snippets
page still manages every scope. Short notes link to Workflows for the global LLM
fallback editor and to Dictation for microphone, transcription, and access
permissions. These shared controls stay in their original pages; fallback changes
also affect inherited workflows.

Follow [the manual test checklist](../testing/voice-transform-manual-tests.md) for
steps, expected outcomes, and a result log.

## Product contract

Select text in another app, invoke a dedicated configurable Voice Transform
shortcut, speak an instruction, review a diff, then Replace or Copy. Ordinary
STT shortcuts retain their existing behavior, including when text is selected.
There is no automatic switch from dictation to transformation.

The transform shortcut toggles instruction recording only. Add an independent
HotkeySlotType and settings recorder, initially unassigned to avoid collisions.
The same action can later be exposed in the selection palette. With no selection,
do not start recording or use pre-existing clipboard contents as an implicit
source. Enable Chromium/Electron accessibility when needed, retry AX briefly,
then attempt a fresh Cmd+C capture before showing the panel. Preserve the previous
clipboard. Copy-captured selections are preview/Copy-only, never automatic paste
targets. Report missing Accessibility permission separately from missing selection.

## Interaction and ownership

VoiceTransformCoordinator owns the state machine:
idle -> capturing -> recording -> transcribing -> generating -> preview -> applying.
Error and cancellation return to a recoverable preview or idle as appropriate.
A session ID invalidates late results. Cancel stops microphone capture and the
provider task; no partial response is applied. Recording and transcription share
the existing engine infrastructure but bypass dictation insertion, cleanup,
inline commands, auto-Enter, correction learning, transcript history, and audio
recovery persistence. Dictation, recorder, and transforms must arbitrate microphone
ownership; a second mode cannot start while another owns capture.

The preview contains original/result diff, editable resolved instruction,
matched snippet names, Replace, Copy, Retry, and Cancel. Retry uses the original
selection and the displayed resolved instruction, not a fresh snippet expansion.
Preserve the original and the candidate in memory until the preview closes.

By default, the window starts at 420 × 180 points for recording and processing, showing only
status and relevant controls. Review expands to 560 × 400 with the result visible;
instruction/original and diff are collapsed disclosures. Errors use 460 × 300.
Settings → Transform → Window controls compact recording and remembering review
size (both on by default). Dragging the review window saves its content size;
recording/error sizes never overwrite it. With compact mode off, recording and
processing use the review size. Reset window size restores 560 × 400 for review.
Saved sizes are fitted to the current screen. Turning off remembering uses default
sizes while retaining the previous saved size until reset.

## Prompt snippets

Reuse the Snippets editor and storage. Add a scope: Dictation, Voice Transform,
or Both. Missing scope in existing stores, sync payloads, and backups means
Dictation. Unknown scope values fail closed for expansion. Old clients are not
scope-aware; mixed-version sync/import cannot enforce transform-only behavior.
Document this compatibility boundary before releasing the feature.

Example: `my rewrite` expands to "Rewrite concisely in a direct, conversational
style. Preserve meaning, names, numbers, and technical terminology. Avoid jargon."
Speaking "my rewrite, and keep it under 100 words" composes the preset with the
additional spoken constraint. Explicit additions take precedence when they
conflict with preset preferences; this is a prompt instruction, not a guarantee
of model behavior, and the result remains reviewable.

Resolve transform snippets before the LLM call, only in the instruction. Match
case-insensitively at Unicode word boundaries, allow whitespace variation, prefer
the longest trigger at a given position, and never rescan inserted expansions.
Reject normalized duplicate transform triggers. Preserve unmatched speech.
Do not guess fuzzy or homophone matches. Display matched triggers and the resolved
instruction so transcription errors are correctable. Disable clipboard placeholders
for transform snippets; date/time placeholders are supported and frozen when the
instruction is first resolved. Existing dictation matching remains unchanged.

## Selection integrity

Capture source process identity, AX field, UTF-16 range, selected text, and readable
document state before showing any UI. Revalidate the same target, range, source,
and document immediately before replacement; verify the expected resulting value
afterward. Never interpret an AX success return alone as verified application.
If target state is missing or changed, disable Replace and offer Copy. Clipboard
capture is a fallback for preview, never proof of a replaceable
target. An ambiguous write must not trigger an automatic paste retry.

No error before application changes the source. macOS Accessibility cannot make
cross-process validation and writes atomic: retain originals, report uncertain
write outcomes, and never claim a universal transactional replacement guarantee.

## Provider contract

Use PromptProcessingService's global workflow fallback list, including each
entry's model, effort, and provider temperature settings. No provider override
or Codex readiness gate is applied. Codex CLI, Claude CLI, Apple Intelligence,
and local providers such as Gemma participate through their existing adapters;
availability and failures are handled by the existing ordered fallback executor.
CLI isolation stays in AuthenticatedCLIPlugin. The workflow processing entry
point skips memory injection. Separate the editing instruction from untrusted selected source text;
do not send surrounding document state used for local verification.

Require nonempty instruction and source. Reject empty/invalid/oversized output,
nonzero process exit, timeout, and cancellation; never paste the instruction or
partial result as fallback. Default to 12,000 source characters and 2,000 resolved
instruction characters; reject over-limit input without truncation. Settings →
Transform → Limits allows 100–100,000 source characters and 100–20,000 instruction
characters (including snippet expansions). Preserve the
provider's byte limits as an additional bound. Preview output is additionally
limited to 24,000 characters by default (configurable from 100–100,000), with a
fixed 512 KiB byte ceiling; skip the quadratic word diff above one million
word-pairs while retaining exact original/result panes. Recording stops after
60 seconds by default (configurable from 10–300 seconds). Each new capture
snapshots all limits; Retry reloads the current limits and revalidates both the
original source and edited instruction. A result limit rejects oversized output;
it does not ask the model to generate that many characters. Provider limits remain
independent. These preferences are local to this installation. Do not infer truncation merely
because an intentional summary is shorter; use provider completion/error signals.

## Implementation increments

### Keeping upstream rebases small

Transform-only wiring, selection capture/replacement, and snippet resolution live
in `ServiceContainer+VoiceTransform.swift`, `TextInsertionService+VoiceTransform.swift`,
and `SnippetService+VoiceTransform.swift`. Preference keys live with transform
preferences; scoped-snippet tests have their own suite. Existing services retain
only the integration hooks and persistence changes required by the feature.
Selection verification reuses the original text-insertion helpers, with three
members exposed internally to the same module (not as public SDK API).

The remaining shared-file changes cover shortcut dispatch/cancellation, settings
navigation, snippet scope storage/sync/backup, and microphone ownership. Those
must be reconciled when upstream changes the corresponding contracts. Do not
remove ownership or replacement checks just to resolve a rebase conflict.

### Host versus plugin boundary

Keep capture, microphone arbitration, global shortcut ownership, preview, and
verified replacement in the host. Existing LLMProviderPlugin adapters own model
execution. ActionPlugin receives text/context and produces an action result; it
does not provide the host-managed capture/preview/replacement session lifecycle.
Moving this feature into a plugin now would duplicate OS integration or require
a new session API. Revisit an optional transform-action plugin only if that API
becomes useful to multiple features. Preserve provider flexibility now through
the existing workflow fallback service.

The SDK already supports a plugin-owned settings page and menu commands through
`PluginUserInterfaceProviding`; UI placement alone is not a reason to keep a
feature in the host. `PostProcessorPlugin` can rewrite supplied text, and
`LLMProviderPlugin` supplies model execution. However, `ActionPlugin.execute`
accepts text/context and returns an action result; it does not obtain a verified
selection or own a recording session. `HostServices` currently exposes no API for
microphone arbitration, selection snapshots, the global LLM fallback executor,
or guarded replacement. A standalone plugin could implement its own native macOS
handling, but would duplicate these services and could conflict with dictation.

A future plugin version should first add a host-managed transform session API:
capture a target, acquire/release recording ownership, transcribe an instruction,
invoke shared provider routing, and present/apply a guarded candidate. A plugin
could then own prompt policy and its settings while the host retains these OS
and lifecycle guarantees. That SDK expansion is optional future work, not needed
to make today's providers replaceable.

1. Snippet foundation: scope, backward-compatible storage/sync/backup, editor,
   deterministic resolver, matching and compatibility tests.
2. Dedicated shortcut and coordinator: capture arbitration, independent instruction
   transcription, selection snapshot, provider-fallback generation, copyable preview.
3. Complete MVP: diff, verified replacement, editable instruction/retry, cancellation
   and late-result tests, live app verification.
4. Later: verified single-level undo and explicit clipboard-context options.

Automatic context-sensitive STT switching, style learning, multi-turn chat,
rich-text preservation, and automatic replacement are outside this scope.

## Verification

September 21 maintenance pass: 225 focused/regression tests passed after extracting
feature-owned wiring, selection, and snippet code. Suites: VoiceTransformCoordinatorTests,
VoiceTransformSnippetTests, SnippetServiceTests, SettingsBackupExporterTests,
HotkeyServiceCompatibilityTests, AudioRecorderViewModelTests,
PromptProcessingModelResolutionTests, and the two transform integration tests.
The extracted selection and resolver blocks were verified unchanged. Project plist
validation and `git diff --check` passed. Full-suite and live UI verification remain
separate from these focused checks.

Selection/fallback follow-up: local build and 141 tests passed. This includes fresh
copy capture and clipboard restoration, stale-clipboard rejection, permission
diagnostics, cancellation during capture, panel focus ordering, and an integration
test that fails the first LLM provider and succeeds with the next. No live
Codex/Firefox capture claim is made by these mocked tests. GitHub CI is unavailable
due to credits; validation for this increment is local.

```sh
xcodebuild test -skipPackagePluginValidation \
  -project TypeWhisper.xcodeproj -scheme TypeWhisper \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:TypeWhisperTests/VoiceTransformCoordinatorTests \
  -only-testing:TypeWhisperTests/PromptProcessingModelResolutionTests \
  -only-testing:TypeWhisperTests/HotkeyServiceCompatibilityTests \
  -only-testing:TypeWhisperTests/TypeWhisperIntegrationTests/testVoiceTransformUsesGlobalFallbacksWithoutCodexRequirement \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Follow-up implementation: the app compiled and 198 focused/regression tests passed
(coordinator, snippets, backups, hotkeys, recorder, and dictation API ownership).
Reproduce with:

```sh
xcodebuild test -skipPackagePluginValidation \
  -project TypeWhisper.xcodeproj -scheme TypeWhisper \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:TypeWhisperTests/VoiceTransformCoordinatorTests \
  -only-testing:TypeWhisperTests/SnippetServiceTests \
  -only-testing:TypeWhisperTests/VoiceTransformSnippetTests \
  -only-testing:TypeWhisperTests/SettingsBackupExporterTests \
  -only-testing:TypeWhisperTests/HotkeyServiceCompatibilityTests \
  -only-testing:TypeWhisperTests/AudioRecorderViewModelTests \
  -only-testing:TypeWhisperTests/TypeWhisperIntegrationTests/testVoiceTransformOwnershipBlocksDictationAPI \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

First increment: 31 focused tests passed on September 20, 2026 (9 snippet tests
and 22 backup tests), using:

```sh
xcodebuild test -skipPackagePluginValidation \
  -project TypeWhisper.xcodeproj -scheme TypeWhisper \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:TypeWhisperTests/SnippetServiceTests \
  -only-testing:TypeWhisperTests/VoiceTransformSnippetTests \
  -only-testing:TypeWhisperTests/SettingsBackupExporterTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

This compiles the app and runs the selected suites. Full suite, legacy on-disk
schema migration, and end-to-end microphone/Accessibility checks remain pending.

Run `make test` and `make test-sdk`. Cover scoped snippet isolation, old persisted
data, backup/sync round trips, Unicode and overlapping triggers, no recursive
expansion, duplicate aliases, clipboard placeholder rejection, and instruction
composition. Coordinator tests must cover cancellation at each await, stale
results, busy microphone, unavailable/auth-failed providers, invalid output, changed
selection/app/document, and uncertain AX writes without duplicate insertion.

Manually verify TextEdit, a browser text field, and an Electron editor. Switch
apps, move selection, and edit the document during generation. Confirm normal
STT stays on its existing path. Live microphone/AX/provider checks are required
before claiming the complete feature works.

## References

- https://docs.wisprflow.ai/articles/8068950331-how-to-use-transforms-beta
- https://github.com/zachlatta/freeflow#edit-mode
- https://github.com/conrader/plainsay#voice-edit-new-in-v0234
- https://github.com/moona3k/macparakeet

Borrow interaction ideas; reference applications were documentation-checked, not
installed or behavior-tested for this specification.
