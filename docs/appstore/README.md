# TypeWhisper for the Mac App Store

The Mac App Store edition ships the regular TypeWhisper app through the Mac App
Store. Instead of a separate reimplementation, it compiles the same app sources
with the `APPSTORE` compilation condition, the App Sandbox and a fixed set of
first-party plugins. The direct-distribution app (`TypeWhisper.xcodeproj`) is
unaffected by `APPSTORE` code.

## Decisions

| Topic | Decision |
|---|---|
| Code base | One repository for both editions. App Store differences live in `AppStore/` and in small `#if APPSTORE` blocks in shared files; keep them minimal and explain why in a comment. |
| Store record | Universal purchase with the iOS app: bundle ID `com.typewhisper.typewhisper-app`, App Store Connect app `6759319267`. |
| Business model | Free download with Premium in-app purchases shared with iOS (`com.typewhisper.premium.individual.monthly`, `com.typewhisper.premium.individual.lifetime`, subscription group "TypeWhisper Premium"). |
| Text insertion | Paste through `CGEvent.post` (TCC "PostEvent", listed under Accessibility) with clipboard fallback. Must stay switchable to clipboard-only in case App Review rejects it under guideline 2.4.5. |
| Architectures | Universal. Plugins that need Apple silicon (MLX, Core ML, ONNX) are built for arm64 only and hidden on Intel Macs. |
| Plugins | First-party plugins are signed into `Contents/PlugIns`. Nothing is downloaded or loaded from outside the app bundle (guideline 2.5.2). |

## Layout

| Path | Purpose |
|---|---|
| `appstore-project.yml` | XcodeGen spec for `TypeWhisperAppStore.xcodeproj` (generated, not committed). |
| `AppStore/Config/AppStore.xcconfig` | Bundle ID, app group, versions. Local overrides go into `AppStore.local.xcconfig`. |
| `AppStore/Resources/` | Info.plist, entitlements, bundled plugin catalog, StoreKit configuration for local testing (not copied into the app). |
| `AppStore/Sources/` | Swift code that only exists in the App Store edition. |
| `AppStore/Tests/` | `TypeWhisperAppStoreTests`, unit tests hosted by the App Store app. |
| `scripts/appstore/` | Project generation, plugin catalog, audit and release scripts. |

## Build

All helpers live in `scripts/appstore/` and work from any checkout or worktree;
output goes to that checkout's `build/` folder.

```sh
# Build, sign with your Apple Development identity and launch the sandboxed app
scripts/appstore/build-dev.sh --run

# Same with fresh privacy permissions, in German, with Parakeet installed
scripts/appstore/build-dev.sh --run --reset-permissions --language de \
  --install-plugin com.typewhisper.parakeet

# Relaunch the last build without building
scripts/appstore/build-dev.sh --relaunch

# Fast unsigned compile check
scripts/appstore/build-dev.sh --check

# Universal Release build and App Store audit (what CI runs)
scripts/appstore/release-audit.sh

# Archive, sign and export for TestFlight on this Mac; --upload sends it
scripts/appstore/testflight-local.sh [--upload]
```

Local Debug builds are a separate variant, **TypeWhisper App Store Dev**
(`com.typewhisper.typewhisper-app.dev`), with their own privacy permissions,
container and keychain items. Release builds are **TypeWhisper**
(`com.typewhisper.typewhisper-app`).

`build-dev.sh` signs without a provisioning profile and therefore uses
`TypeWhisperAppStore-Local.entitlements`: iCloud, Sign in with Apple and real
purchases need a TestFlight build. Every worktree builds the same bundle ID, so
launching quits any running App Store Dev build first. `--language` and
`--install-plugin` apply to that launch only.

Run the unit tests in Xcode or with `xcodebuild ... test` on the generated
`TypeWhisperAppStore.xcodeproj`. After changing the plugin set in
`appstore-project.yml`, refresh the marketplace metadata with
`scripts/appstore/update_plugin_catalog.py`.

The audit checks bundle ID, Info.plist keys, bundled components against
`AppStorePluginCatalog.json`, linked frameworks, architectures and, for signed
builds, entitlements. Process-launch imports fail in plugins and are reported
as warnings for the host app.

## Release

The `appstore` job in `.github/workflows/build.yml` runs the unsigned universal
build and the audit for every pull request, so changes that break the sandboxed
edition fail in the pull request that introduces them.

`.github/workflows/appstore-testflight.yml` (manual or nightly at 02:30 UTC, `main` only) archives with
manual signing, audits the signed archive, exports a `.pkg` and uploads it to
App Store Connect app `6759319267` when `confirm_upload` is set. Nightly runs upload
to the internal TestFlight group whenever `main` changed since the last nightly
upload; TestFlight thus replaces the direct app's daily and release-candidate
channels (internal group: daily, external group: release candidates). It needs
these secrets in the `app-store` environment:

| Secret | Content |
|---|---|
| `MACOS_SIGNING_P12` | Base64 `.p12` with the Apple Distribution and Mac Installer Distribution identities |
| `MACOS_SIGNING_PASSWORD` | Password of that `.p12` |
| `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_P8` | App Store Connect API key (App Manager) |

Both the workflow and `scripts/appstore/testflight-local.sh` create
`MAC_APP_STORE` profiles for the app, the widget and the Finder action with
`scripts/appstore/create_app_store_profile.rb`.

## Plugins

The marketplace lists the bundled plugins from
`AppStore/Resources/AppStorePluginCatalog.json`. Installing a plugin marks it as
installed and loads the bundled copy; plugins that are not installed are never
loaded. Apple Speech is installed on first launch, as in the direct app.

| Status | Plugins |
|---|---|
| Bundled | AssemblyAI, Cartesia, Cerebras, Claude, Cohere, Deepgram, ElevenLabs, Fireworks, Gemini, Gladia, Google Cloud STT, Groq, Meta, Microsoft AI, OpenAI, OpenAI Compatible, OpenRouter, Smallest AI, Soniox, Speechmatics, Vercel AI Gateway, xAI, WhisperKit, Parakeet, Apple Speech, Qwen3, Local LLM, Supertonic, System TTS, Filler Words, Live Transcript, File Memory, OpenAI Vector Memory, Webhook, Linear, Obsidian, MCP Client, Mistral AI, Cloudflare ASR, Reson8 |
| Not included by policy | Community plugins (MemPalace, R2T2), SaluteSpeech (sanctions), and the niche local models Canary, Granite and Voxtral (each adds its own MLX copy, about 46 MB) |
| Not possible | Authenticated CLI, Script, File Job Script, Web Link, R2T2, Cohere Transcribe (Local): they run external programs or downloaded binaries |

Some bundled plugins are reduced in the App Store edition (`#if APPSTORE`):

| Plugin | App Store edition |
|---|---|
| OpenAI | API key only. The ChatGPT login (localhost OAuth callback, Codex login import) is not compiled in. |
| System TTS | Speaks in-process with `NSSpeechSynthesizer` instead of launching `/usr/bin/say`. |
| Obsidian | The vault is picked in an open panel and kept as a security-scoped bookmark; no auto-detection from Obsidian's config. |
| MCP Client | Streamable HTTP servers only; the stdio transport is not compiled in. |

`update_plugin_catalog.py` overrides the marketplace text of OpenAI and MCP Client
accordingly.

## Premium

`AppStorePremiumService` sells and restores Premium with StoreKit 2 and is the
single source of truth for Premium access in this edition. Access comes from an
active App Store purchase or from a verified entitlement of the signed-in
TypeWhisper account, and is mirrored into `LicenseService`, so all commercial
gates (meeting automation, learning from corrections, automatic fallback,
commercial term packs) and cloud sync follow it.

- Buying and restoring need only the Apple Account (guideline 5.1.1(v)). Sign in
  with Apple is optional and connects devices for cloud sync.
- An active lifetime purchase always wins over a subscription, so an expired or
  refunded subscription never removes lifetime access.
- While signed in, production transactions are linked to the account with
  `POST /v1/entitlements/storekit/sync` with `"app": "ios"`, the shared App
  Store record, and the `X-TypeWhisper-Platform: macos` header. Sandbox and Xcode
  transactions are not sent.
- The License page, Polar license keys, supporter tiers, the Discord claim, the
  welcome and post-update license prompts and the work-usage card are not part
  of this edition (guideline 3.1.1). Purchases happen on the Premium page.
- The scheme uses `AppStore/Resources/TypeWhisperAppStore.storekit` for local
  StoreKit testing in Xcode.

## Host app differences

| Area | App Store edition |
|---|---|
| Updates | No Sparkle; updates come from the App Store. |
| Media pause | MediaRemote is private API and stays disabled (`MediaPlaybackService`). |
| CLI | Not shipped; the local HTTP API stays available (`network.server`). |
| Keychain | Own service names (`com.typewhisper.typewhisper-app.*`), never the direct app's items. |
| Licensing | StoreKit Premium instead of Polar license keys and supporter tiers. |
| iCloud | The app uses the iCloud container directly instead of the iCloud bridge XPC service. |
| Browser URL | No AppleScript or `osascript`: browsers report no URL and no open tabs, so the Website workflow trigger is hidden and meeting detection relies on native apps. |

## Input and permissions

The sandbox allows two TCC services for input (`AppStoreInputAccess`):

| Service | System Settings | Used for |
|---|---|---|
| PostEvent (`CGRequestPostEventAccess`) | Accessibility | Pasting with Cmd+V, Cmd+C for selected text, Auto Enter |
| ListenEvent (`CGRequestListenEventAccess`) | Input Monitoring | Fn, modifier-only, double-tap and mouse-button shortcuts, Esc and push-to-talk interruption in other apps |

Shortcuts with a regular key (with or without modifiers) are Carbon hotkeys and need no permission.
Neither permission is required: without PostEvent the text is copied to the clipboard with a
notice, and without Input Monitoring only Carbon shortcuts work.

`TYPEWHISPER_APPSTORE_AUTOPASTE` in `AppStore/Config/AppStore.xcconfig` (Info.plist key
`TypeWhisperAutoPasteEnabled`) switches synthetic paste off. A `NO` build never posts events
and never asks for Accessibility.

Differences to the direct app, which uses the Accessibility API and an event-suppressing tap:

| Feature | App Store edition |
|---|---|
| Insertion | Always clipboard + Cmd+V, never a direct Accessibility write. The previous clipboard is restored as before. Paste verification is unavailable, so restores use the unverified delays. |
| Selected text | Prompt palette and text workflows copy the selection with Cmd+C. Dictation does not read the selection at start. |
| Hotkey events | Not suppressed: Fn, modifier-only, double-tap and mouse-button presses also reach the frontmost app. Set "Press 🌐 key to" to "Do Nothing" when using Fn. Shortcuts with a regular key are Carbon hotkeys and are consumed. |
| Esc | Cancels as configured, but also reaches the frontmost app. Outside TypeWhisper it needs Input Monitoring. |
| Enter during dictation | The "When I press Enter during dictation" Auto Enter mode is hidden and behaves like "Never". |
| Live transcript in the text field, correction learning, undo/restore of the last dictation, caret-relative indicator placement | Unavailable; they read or write other apps' text fields through Accessibility. |
| Hotkey recorder | Records only while the settings window is active (no global key monitor). |

## Open work

1. Test text insertion, hotkeys and permissions in a sandboxed build ([checklist](manual-test-checklist.md)).
2. Test purchase, restore, trial and refund in Sandbox and TestFlight, including the account sync of Mac transactions with `app.typewhisper.com`.
3. Test iCloud sync, the widget and the Finder action with a provisioned build.
4. First signed TestFlight upload (workflow, audit and universal Release build are in place).
5. App size: each MLX plugin links its own copy of MLX.
6. App Store Connect: add the macOS platform to app `6759319267`, Mac screenshots, review notes.

## Before submission

- Premium devices: a signed-in Mac registers with its own device ID and the
  `macos` platform and counts as one of the three Premium devices, like an iPad.
  Update the device wording in the App Review notes of both apps (iOS:
  `docs/app-store/premium-sync-review-notes.md`, "up to three iPhone or iPad
  activations") and the in-app purchase descriptions to include the Mac.
- Confirm that the contributor agreement covers all code compiled into the App Store edition. The public repository is GPLv3; the App Store build is distributed under the commercial license.
- Ask Apple about the "identifier configuration" issue that currently keeps the iOS app off Apple silicon Macs.
