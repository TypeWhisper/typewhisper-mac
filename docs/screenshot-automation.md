# macOS Screenshot Automation

TypeWhisper uses a Fastlane macOS lane to capture the real Settings window in
English, German, Japanese, and Simplified Chinese. Every locale gets a complete
Free pass and a focused Premium pass covering the Premium overview and its four
feature windows. Screenshot mode creates deterministic, language-specific
History, Statistics, Dictionary, Snippet, Workflow, plugin-marketplace, and
term-pack fixtures before each image is taken.

The lane builds an ad-hoc signed Debug app with the isolated bundle identifier
`com.typewhisper.mac.screenshots`, starts a fresh process for each state, waits
for the app to report its Settings window number, and captures that exact native
window with macOS `screencapture`. It does not require an XCTest runner or
Developer Mode.

Fixture stores live in a process-specific temporary Application Support
directory, and the isolated screenshot defaults domain is reset around every
capture. Screenshot runs do not read, replace, or delete the user's TypeWhisper
or TypeWhisper-Dev preferences, keychain items, or application data.

## Setup

Use Ruby 3.3 and install the pinned bundle:

```sh
bundle install
```

## Capture

Capture every supported language:

```sh
bundle exec fastlane mac screenshots
```

Capture a subset while iterating:

```sh
bundle exec fastlane mac screenshots languages:en-US,de-DE
```

Raw screenshots are written to ignored locale folders under
`fastlane/screenshots/` with names such as `en-US/Mac-free-history.png` and
`en-US/Mac-premium-calendar.png`. The Free pass covers 21 Settings states,
including a dedicated Indicator settings view and the production Overlay
indicator in an active dictation context. Premium capture is intentionally
limited to the active Premium overview plus its Access, Calendar, Correction
Learning, and Cloud Sync detail windows. A complete run produces 26 images per
locale, or 104 images across all four locales.

## Publish

After visually reviewing the Free and focused Premium sets in every locale,
promote the English screenshots into `.github/screenshots` and refresh the
generated README gallery block:

```sh
bundle exec fastlane mac screenshots_publish
```

For the complete release step—capture all languages, publish English, and
validate the README block—run:

```sh
bundle exec fastlane mac screenshots_release
```

Validate committed README assets without taking new screenshots:

```sh
bundle exec fastlane mac screenshots_check
```

The menu-bar and hardware-notch images are specialty captures and remain
separate from the Settings-window matrix.
