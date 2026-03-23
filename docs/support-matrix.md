# TypeWhisper Support Matrix

This matrix describes the officially supported `1.0` path for direct-download releases.

## Platform

| Area | Support |
| --- | --- |
| Base support | macOS 14+ |
| Recommended hardware | Apple Silicon |
| Intel | Smoke-test before releases as long as Universal Binary support is advertised |

## Feature Matrix by macOS Version

| Feature | macOS 14 | macOS 15 | macOS 26+ | Notes |
| --- | --- | --- | --- | --- |
| System-wide dictation | Yes | Yes | Yes | Core workflow for `1.0` |
| File transcription | Yes | Yes | Yes | Core workflow for `1.0` |
| Prompt processing | Yes | Yes | Yes | Core workflow for `1.0` |
| Profiles, History, Dictionary, Snippets | Yes | Yes | Yes | Core workflow for `1.0` |
| Widgets | Yes | Yes | Yes | Not part of the core path |
| HTTP API | Yes | Yes | Yes | Loopback-only, disabled by default |
| CLI | Yes | Yes | Yes | Requires the local API server to be running |
| Apple Translate integration | No | Yes | Yes | Advanced surface |
| Improved settings UI | No | Yes | Yes | Optional usability improvement |
| Apple Intelligence provider | No | No | Yes | Optional, not part of the core path |
| SpeechAnalyzer engine | No | No | Yes | Optional, not part of the core path |

## Engine Notes

| Engine Type | Support in 1.0 | Notes |
| --- | --- | --- |
| Local engines | Yes | Recommended default path |
| Cloud engines | Yes | Require valid API keys |
| Bundled plugins | Yes | Part of the tested product path |
| External third-party plugins | Best effort | Not a launch blocker for `1.0` |

## Automation Notes

| Surface | Status in 1.0 |
| --- | --- |
| HTTP API `/v1/*` | Stable for `1.x` |
| `typewhisper` CLI | Stable for `1.0.x` |
| Plugin SDK | Stable for `1.x` |
