# Voice Transform manual test checklist

Use a disposable document. Record Pass / Fail / Not tested for each scenario.
A successful rewrite must change only the selected text. Errors before replacement
must leave the document untouched; spoken instructions must never be pasted as
ordinary dictation. Copy-only operation is an expected fallback in apps that do
not expose a verifiable selection.

## Preparation

1. Build this checkout with `make build`, then install with `make install`.
2. Open Settings → Transform → General and assign a distinct shortcut.
3. Follow the Shared settings link to Workflows and confirm your global LLM fallback
   order. Inherited workflows use the same list: changes affect both. Record its original order before
   testing and restore it afterward.
4. In Transform → Prompts, add `my rewrite` with scope Voice Transform and expansion:
   `Rewrite concisely and politely. Preserve names, dates, numbers, and meaning.`
5. Confirm microphone and Accessibility access. Configure your usual transcription
   engine through Shared settings → Open Dictation settings.
6. Prepare TextEdit (plain text), a Firefox text field, and an Electron editor
   such as the Codex composer. Do not submit/send the test text.

Sample source (select only the middle paragraph):

```text
BEFORE — leave this line unchanged.

Hi Priya, we need the revised report by 25 September. The budget is ₹12,500 and there are 3 reviewers. Please let me know if you need more time. Thank you! 👋

AFTER — leave this line unchanged.
```

Test record: date / app build or commit / macOS version / target app and version /
transcription engine / LLM order / transform shortcut.

## Start here: everyday use

| ID | Steps | Expected result | Result |
| --- | --- | --- | --- |
| S1 | Open Settings → Transform → General. Assign a shortcut, leave the page, return, then relaunch the app. | Shortcut persists and starts/stops transform recording. | ☐ |
| S2 | Select the sample paragraph in TextEdit. Invoke Transform; say “Make this shorter and friendlier, but keep the date, budget, and reviewer count”; stop with the shortcut. | Compact recording panel opens, then expands to a review. Source is unchanged until Replace. Instruction/original and diff can be expanded. | ☐ |
| S3 | Review S2, then Replace. | Only the selected paragraph changes, once. BEFORE/AFTER remain intact. Dates, numbers, and meaning should be preserved; record model-quality errors separately from insertion bugs. | ☐ |
| S4 | Repeat S2 in Firefox and the Codex composer. | Each produces a preview. Replace works only with a verifiable target; otherwise Copy remains usable. Record which behavior each app supports. | ☐ |
| S5 | Generate a result and click Copy, then paste manually into a disposable document. | Clipboard contains the candidate. Original source was not automatically changed. | ☐ |
| S6 | Expand the instruction, edit it to “Use two bullet points”, and Retry. | New candidate uses the original selection plus the edited instruction, not the previous candidate. Nothing is inserted before Replace. | ☐ |
| S7 | Start another transform after closing the previous preview. | Panel starts compact again; previous source, instruction, and result are not shown. | ☐ |

## Spoken prompts and shared settings

| ID | Steps | Expected result | Result |
| --- | --- | --- | --- |
| P1 | Open Transform → Prompts and add `my rewrite` from preparation. | New prompt defaults to Voice Transform scope. It appears here and in the shared Snippets editor. Dictation-only snippets are absent from this filtered page. | ☐ |
| P2 | Transform the sample with “my rewrite, and keep it under 40 words”. | Matched prompt and expanded instruction are visible in review. Extra spoken constraint is preserved. Source text itself is not expanded. | ☐ |
| P3 | Disable `my rewrite`, then invoke it again. Re-enable afterward. | Disabled prompt does not expand; spoken words remain in the instruction. | ☐ |
| P4 | Dictate “my rewrite” with the normal dictation shortcut. Then change the snippet scope to Both and repeat. Restore Voice Transform afterward. | Transform-only prompt does not expand in dictation; Both allows ordinary dictation expansion. Editing a Both snippet affects both uses. | ☐ |
| P5 | Follow Transform → Shared settings → Open Workflows → Global LLM Fallbacks; change order/model/effort and verify a transform uses it. Restore original values. Follow Open Dictation settings as well. | Links open the original Workflows and Dictation pages. Shared controls are edited there; Transform has no duplicate fallback or permission controls. | ☐ |
| P6 | Use a deliberately unavailable first provider with a working second provider; generate a rewrite. Restore configuration afterward. | Generation falls through to the next usable provider. A successful first provider should be used without trying later entries. Capture provider diagnostics if needed to confirm which ran. | ☐ |
| P7 | Make every configured provider unavailable, then try a transform. Restore configuration afterward. | Recoverable error; source untouched, no instruction or partial response pasted. | ☐ |

## Window and limit preferences

| ID | Steps | Expected result | Result |
| --- | --- | --- | --- |
| W1 | Leave both Window toggles on. Generate a preview, drag it larger, cancel, then start another transform. Relaunch and repeat. | Recording starts compact; review returns to the size you chose, including after relaunch. | ☐ |
| W2 | Resize during recording or cause a missing-selection error after saving a review size. Start a fresh transform. | Those window sizes do not overwrite the saved review size. | ☐ |
| W3 | Turn off Start compact while recording, then start Transform. | Recording/processing use the review size. Turn it back on to restore compact recording. | ☐ |
| W4 | Turn off Remember review window size. Start a fresh transform, then turn it back on and repeat. Click Reset window size with a preview open. | Off uses default review dimensions. On reuses the saved size. Reset restores the default 560 × 400 review size immediately. | ☐ |
| W5 | Save a large review size on an external screen, disconnect it, and reopen Transform. | Window fits the available screen and its controls remain reachable. | ☐ |
| L1 | Set Instruction characters to 100. Use a short spoken trigger whose expanded prompt exceeds 100 characters. Raise the limit and Retry. | First request fails before LLM generation and displays the expanded instruction. Retry succeeds with the higher limit. | ☐ |
| L2 | Set Selected-text characters to 100; select 101 characters and invoke Transform. Raise the setting to 200 and repeat. | First attempt rejects without recording; second can start. No silent truncation. | ☐ |
| L3 | Set Result characters to 100 and request a detailed rewrite likely to exceed that length. Raise the limit and Retry. | An over-limit result is rejected without source mutation. This limit does not force the model to return an exact length. | ☐ |
| L4 | Set Recording seconds to 10 and keep speaking. | Recording stops automatically after about 10 seconds and proceeds to transcription/review. | ☐ |
| L5 | Start recording, change a limit in Settings, then finish. Retry afterward. | The active attempt uses its original limits; Retry picks up the change. | ☐ |
| L6 | Type a value and press Return or move focus. Try an out-of-range number and invalid text. Relaunch. Click Reset limits. | Valid values persist, out-of-range values clamp to the shown range, invalid input restores the prior value. Reset restores 2,000 / 12,000 / 24,000 characters and 60 seconds. | ☐ |

Restore defaults before the following boundary tests.

## Cancellation and selection safety

| ID | Steps | Expected result | Result |
| --- | --- | --- | --- |
| E1 | Copy a recognizable marker to the clipboard. Deselect all text and invoke Transform. | “Select text” feedback; recording does not start using the old clipboard marker. Clipboard remains intact. | ☐ |
| E2 | In an app that uses copy capture, copy a marker first, select the sample, then invoke Transform. Inspect clipboard after capture, before clicking Copy. | Fresh selection is captured; previous clipboard is restored. Preview is Copy-only. | ☐ |
| E3 | Cancel during recording. Repeat and cancel while generation is running. Wait for any delayed response. | Microphone stops, source stays unchanged, and no late preview or insertion appears. Another transform can start. | ☐ |
| E4 | While generation is running, move the selection to another part of the original document, then attempt Replace. | Replacement is refused when the captured selection no longer matches; candidate remains available to copy. | ☐ |
| E5 | While generation is running, change the original document (including text outside the selection), then attempt Replace. | Stale document is detected; no replacement or blind paste. | ☐ |
| E6 | During generation switch apps, then attempt Replace. Repeat after closing the original document. | No text lands in the newly focused app or another document. Replacement may return to a still-verifiable original target; otherwise it is refused. | ☐ |
| E7 | Select text containing emoji, accented letters, and non-Latin text; transform and Replace. | Selection boundaries remain correct; adjacent characters are not removed or duplicated. | ☐ |
| E8 | Start transform recording, then invoke normal dictation or Recorder. Also try Transform while dictation is recording. | Only one mode owns the microphone. No mixed recording or accidental instruction insertion. | ☐ |
| E9 | Invoke ordinary dictation with text selected. | Existing dictation behavior remains unchanged; it does not automatically enter Transform. | ☐ |
| E10 | Stop without speaking. Separately, record until the 60-second limit. | Empty instruction cannot be applied. Long recording stops at the limit and follows the normal transcription/review or error path. | ☐ |
| E11 | Select more than 12,000 characters. Separately, edit the resolved instruction beyond 2,000 characters and Retry. | Clear input-limit error; input is not silently truncated and source stays intact. | ☐ |

## Optional release checks

These are separate from normal daily-use testing. Use a test macOS account or an
isolated copy of old data; do not replace your active database to perform migration tests.

- [ ] **Permissions:** With microphone or Accessibility denied in the test account,
  try Transform. Confirm actionable permission feedback, no document mutation,
  and successful recovery after permission is granted.
- [ ] **Legacy store:** Open a real pre-scope snippet database in an isolated test
  setup with this build. Existing entries retain content/enabled state and default
  to Dictation. New Transform/Both scopes survive relaunch.
- [ ] **Backup round trip:** Export snippets with all three scopes and import into
  an isolated test setup. Check scopes and contents. An old backup lacking scope
  should import as Dictation. Older clients cannot enforce transform-only scope.
- [ ] **History/privacy:** After closing a transform preview, verify the spoken
  instruction did not create a normal dictation history/recovery entry.

## Report a failure

```text
Scenario ID:
App/build/macOS:
Target app:
Transcription engine and LLM order:
Steps:
Expected:
Actual:
Was source text changed? Was Replace available?
Screenshot/error text (omit private text):
```

For maintainer regression checks, run `make check` (app, SDK, and installer tests).
Automated tests do not substitute for the live microphone and cross-app checks above.
