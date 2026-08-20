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

## Plugin screenshots for typewhisper.com

The plugin lane covers the 42 current first-party bundles. It builds each
selected bundle, stages only that bundle in a temporary Application Support
directory, opens its native settings window, and captures English and German
website assets:

```sh
bundle exec fastlane mac plugin_screenshots
```

Use comma-separated locale and add-on slug filters while iterating:

```sh
bundle exec fastlane mac plugin_screenshots \
  languages:en-US plugins:groq,qwen3-asr
```

Raw PNGs are written to ignored paths such as
`fastlane/screenshots/en-US/plugins/groq.png`. Pass `skip_build:true` only when
the screenshot app and every selected plugin bundle were already built from
the current checkout.

Long settings views are captured page by page. The app scrolls its primary
native scroll view with a small overlap, and Fastlane stitches the pages into
one window image with a single title bar and continuous window shadow. Requested
plugin window sizes are clamped to the current display before capture, so a tall
window cannot be clipped at the screen edge. Multi-page capture requires
ImageMagick's `magick` executable. If a plugin has a nested scrollable region,
the surrounding controls are kept once while only that region is expanded in
the stitched result.

Credential-gated settings use deterministic dummy credentials scoped to the
single selected plugin. Screenshot mode never reads or writes real keychain
items, and requests made through `PluginHTTPClient` fail locally before reaching
a provider. Local-model settings display their catalog without downloading a
model. If a future settings screen requires remote-only response data, add a
deterministic screenshot fixture for that response instead of using a real API
key or live service.

Publishing requires `cwebp`, `oxipng`, and ImageMagick's `identify`. After
reviewing both locale images, copy and optimize the PNG/WebP assets in a local
website checkout:

```sh
bundle exec fastlane mac plugin_screenshots_publish \
  website_path:/absolute/path/to/typewhisper.com
```

The English image is written to both `public/screenshots/en/plugins/` and the
legacy `public/screenshots/plugins/` fallback. The German image is written to
`public/screenshots/de/plugins/`. Capture and publish can be combined:

```sh
bundle exec fastlane mac plugin_screenshots_release \
  website_path:/absolute/path/to/typewhisper.com
```

`openai-chatgpt-login`, `mcp-client-activity`, and `mcp-client-servers` show
secondary interaction states and remain specialty captures. The main
`openai` and `mcp-client` settings windows are part of the automated matrix.
The legacy website entries `gemma-local`, `sherpa-onnx`, and `whisper-cpp` do
not have matching Xcode plugin targets in this repository and are not part of
the lane.
