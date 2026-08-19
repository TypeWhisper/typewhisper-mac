---
name: Release checklist
about: Track manual smoke checks for a release candidate or stable release
title: "[Release] "
labels: ""
assignees: ""
---

# Release checklist

Release:
Candidate tag or commit:
Previous stable version:
Test owner:

## Automated evidence

Link the successful runs instead of repeating checks already enforced by CI.

- Release workflow:
- PR or preflight validation:
- Other relevant CI:

## Readiness

- [ ] The latest release candidate ran on representative real machines for multiple days without open P0/P1 blockers.
- [ ] Release notes and user-facing documentation match the candidate.
- [ ] Upgrade from the previous stable version preserves History, Workflows, Dictionary, Snippets, hotkeys, enabled plugins, and the update channel.

## Recording and insertion

- [ ] A clean install completes microphone and accessibility permission setup; revoked permissions recover correctly; the first dictation succeeds.
- [ ] App-aware insertion works in plain text, mid-sentence, terminal, rich-text, and TaskForge preserve-clipboard targets.
- [ ] Fn press-and-release and press-and-hold, hybrid modifier delayed-toggle and non-Control single-tap, remapped Hyperkey, and mouse-button shortcuts work.
- [ ] Audio preview and recording survive AirPods/Bluetooth route changes, virtual audio inputs, and FaceTime built-in microphone capture without crashing.
- [ ] Media pauses and resumes around recording; very short and no-speech clips behave correctly; final transcription failures are visible.
- [ ] File transcription completes and exports successfully.
- [ ] System Audio Recorder keeps final transcription and live preview as separate controls and records separate tracks correctly.

## Workflows, history, and automation

- [ ] Workflow matching works for app + URL, URL-only, app-only, direct hotkey, and global fallback triggers.
- [ ] Workflow output formats, Pages workflow hotkeys, prompt actions, and auto-submit behavior work.
- [ ] Inherited LLM fallbacks advance after unavailable-provider, restore, rate-limit, network/API, and empty-result failures; cancellation inserts no text; explicit providers remain strict.
- [ ] History edit/export works and entries show both source transcription and processed text where applicable.
- [ ] The local HTTP API and CLI expose `status`, `models`, and `transcribe`; per-request engine and model selection reaches the selected provider.

## Integrations and models

- [ ] Installed, Discover, and Manual integration paths work at desktop and compact window sizes, including enable/disable, search, filters, manual bundle installation, updates, and incompatibility notices.
- [ ] Official and community entries show correct source, hosting, and capability metadata; community term packs download and apply.
- [ ] Cloud ASR uploads use compressed M4A with WAV fallback where required, especially for Groq and OpenAI-Compatible providers.
- [ ] Dictionary terms reach streaming providers such as AssemblyAI, Soniox, and SpeechAnalyzer without breaking the session.
- [ ] Local MLX models unload when idle, restore lazily, and expose stalled-download recovery; model-license acceptance still gates the first required download.
- [ ] Spoken feedback can be enabled, configured, and disabled and remains limited to transcription readback.

## UI, dictionary, and localization

- [ ] The Fastlane macOS screenshot release lane completed, and the Free and Premium fixture sets were visually reviewed in English, German, Japanese, and Simplified Chinese.
- [ ] Notch, Overlay, Minimal, and fullscreen indicators render correctly; the fullscreen menu-bar strip and top overlay behave correctly; transcript preview toggles independently.
- [ ] Sound feedback can be enabled, disabled, and replaced with custom sounds.
- [ ] Dictionary JSON import/export, localized term packs, learned-correction visibility, scrolling, and per-term CTC controls work.
- [ ] Multilingual language hints preserve search, selection order, and fallback behavior.
- [ ] Japanese dictation and settings localization work; built-in term-pack metadata renders correctly in English and German.

## Distribution surfaces

- [ ] Release-candidate and daily builds remain prereleases on their own Sparkle channels and do not update Homebrew or stable website messaging.
- [ ] For a stable release, the public GitHub assets, canonical appcast, Homebrew cask, and website advertise the exact released version.

## Sign-off

- [ ] All failures are linked to issues or explicitly accepted.
- [ ] The release is approved to ship.
