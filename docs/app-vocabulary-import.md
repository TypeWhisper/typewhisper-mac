# Importing words and snippets from other apps

In **Dictionary**, open the overflow menu and choose **Import from Another App…**.
The same action is available in **Snippets**.

Below the introduction and feature overview, the setup wizard offers a discreet
**Import from Wispr Flow or Handy…** text link. The link opens a dialog for choosing
the source and reviewing words or snippets. A regular source file at either standard
macOS path preselects a detected app. Detection checks file metadata only; it does not
read the vocabulary or infer that the person used the app. Clicking **Review Words…**
or **Review Snippets…** reads the detected source. Without detected files, users can
choose a file manually in the review dialog. Continuing setup requires no import,
and existing saved wizard steps keep their indices.

Supported sources:

| Source | Dictionary | Snippets |
| --- | --- | --- |
| Wispr Flow `flow.sqlite` | Canonical terms plus alternate spellings as corrections | Plain-text expansions |
| Handy `settings_store.json` | Custom words | Not supported by the verified Handy schema |
| Wispr Flow-compatible CSV | One column for terms, two for original/replacement | Two columns for trigger/replacement |

**Read from App** uses the standard macOS Application Support location. **Choose File…**
also accepts a manually located database or settings file. CSV supports UTF-8, an
optional BOM/header, quoted commas, escaped quotes, and multiline expansions.
The first row is preserved by default; select **First row is a header** to omit it.

Nothing is saved until **Import Selected** is clicked. The review shows new entries,
duplicates, conflicts and excluded counts. Existing entries are never overwritten or
re-enabled. Identical text with different case-sensitivity or enabled state is a
conflict, not a duplicate. Selecting a preview row shows its complete content in a
scrollable detail area. Trigger/original collisions are compared using Unicode case folding; the
first source entry wins. A changed destination invalidates the review and requires a
new confirmation. Dictionary and snippet imports are separate, single-store saves.
Save failures remove only the import's new objects and preserve pending usage counts.

Wispr Flow's database and WAL are copied into a private temporary directory. Source
parts are checked before and after copying using SHA-256 and file metadata; copied
bytes must match. The source is never opened with SQLite. Only the private copy is
opened read/write so SQLite can recreate missing WAL sidecars after a clean shutdown;
`query_only=ON` prevents data changes through queries. The copy is removed after reading.
A rollback journal, symlink, invalid schema or
unstable snapshot prevents import. Acquisition retries up to three times for transient failures. Stable unsupported
schemas and malformed rows report a format error without retrying. Handy's
JSON is accepted only after two identical reads decode successfully.

Deleted Wispr Flow rows and rows belonging to the other destination are excluded.
Foreign snippets containing TypeWhisper's dynamic placeholders are excluded rather
than silently activating clipboard/date expansion. Other snippet text retains its
whitespace. Rich-text formatting is not imported.

Limits: 25,000 source rows (including excluded rows), 2 GiB for the source database
parts, 8 MiB for JSON/CSV, 1,000 UTF-8 bytes per original/trigger, and 100,000 bytes per
replacement. No source contents are logged or uploaded.

## Format references

- [EnviousWispr's Wispr Flow database reader](https://github.com/Envious-Labs-LLC/enviouswispr-windows/blob/main/src/Production/EnviousWispr.Services/AppImport/WisprFlowDatabase.cs)
- [EnviousWispr macOS word adapters](https://github.com/saurabhav88/EnviousWispr/blob/main/Sources/EnviousWisprPostProcessing/SmartImportSource.swift)
- [EnviousWispr macOS snippet adapters](https://github.com/saurabhav88/EnviousWispr/blob/main/Sources/EnviousWisprPostProcessing/SnippetImportAppAdapters.swift)
- [Handy settings schema](https://github.com/cjpais/Handy/blob/main/src-tauri/src/settings.rs)
- [TypeWhisper Windows import PR #550](https://github.com/TypeWhisper/typewhisper-win/pull/550)
  (compared at `af14b2322d03820e8dfc7209c02915fa8c9ec550`): canonical-word mapping,
  conflict classification and the full-content preview are shared behaviors.
  The private-copy WAL open mode also supports cleanly closed databases without sidecars.
  macOS correction replacements already preserve literal backslashes, so they do
  not need Windows' formatting-escape exclusions.

## Verification

```sh
xcodebuild test -skipPackagePluginValidation -project TypeWhisper.xcodeproj \
  -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' \
  -only-testing:TypeWhisperTests/AppVocabularyImportTests \
  -only-testing:TypeWhisperTests/DictionaryServiceTests \
  -only-testing:TypeWhisperTests/SnippetServiceTests \
  -only-testing:TypeWhisperTests/SetupWizardRecommendationAvailabilityTests \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Tests use synthetic databases matching the verified schemas, including committed
WAL data, cleanly closed WAL databases without sidecars, same-size source mutations with restored timestamps, copy tampering,
journals, symlinks, malformed rows, row limits, conflicts, stale reviews and failed
saves, preserved deferred usage counts, Unicode collisions and explicit CSV header selection.
They do not establish compatibility with every released vendor version.

Local validation on 2026-09-27: all 107 selected tests passed. The signed development
app was also checked through its native UI: source detection in the wizard, the
import text link below the feature overview, real Wispr Flow word and snippet previews,
Handy's empty custom-word list and a synthetic nonempty Handy file, row selection,
full-content detail, CSV header toggling in both directions and cancellation. The real Wispr source and sidecar presence
were unchanged by SHA-256 comparison before and after the UI previews. Preview
dialogs were cancelled; persistence and rollback were tested in isolated stores.
