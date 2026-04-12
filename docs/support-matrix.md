# TypeWhisper Support Matrix

This matrix describes the officially supported `1.x` direct-download path. For the current `1.2.0-rc*` preview line, the public runtime support floor remains `macOS 14+`.

## Platform

| Area | Support |
| --- | --- |
| Runtime floor | macOS 14+ |
| Recommended hardware | Apple Silicon |
| Intel | Smoke-test before every final release as long as Universal Binary support is advertised |
| Distribution | Stable via direct download and Homebrew, preview builds via direct download only |

## Feature Matrix by macOS Version

| Feature | macOS 14 | macOS 15 | macOS 26+ | Notes |
| --- | --- | --- | --- | --- |
| System-wide dictation | Yes | Yes | Yes | Core workflow for `1.x` |
| File transcription | Yes | Yes | Yes | Core workflow for `1.x` |
| Prompt processing | Yes | Yes | Yes | Core workflow for `1.x` |
| Profiles, History, Dictionary, Snippets | Yes | Yes | Yes | Core workflow for `1.x` |
| Notch, Overlay, and Minimal indicators | Yes | Yes | Yes | User-facing status surfaces in `1.2` |
| Widgets | Yes | Yes | Yes | Supported advanced surface |
| HTTP API | Yes | Yes | Yes | Loopback-only, disabled by default |
| CLI | Yes | Yes | Yes | Requires the local API server to be running |
| Apple Translate integration | No | Yes | Yes | Advanced surface |
| Apple Intelligence provider | No | No | Yes | Optional provider surface |
| SpeechAnalyzer engine | No | No | Yes | Optional engine surface |

## Engine Notes

| Surface | Support in `1.x` | Notes |
| --- | --- | --- |
| Local engines | Yes | Recommended default path |
| Cloud engines | Yes | Require valid API keys |
| Bundled MLX engines | Yes | Qwen3, Granite, and Voxtral support an optional HuggingFace token for higher download rate limits |
| Bundled plugins | Yes | Part of the tested product path |
| External third-party plugins | Best effort | Not a stable-release blocker for `1.x` |

## Automation Notes

| Surface | Status in `1.x` |
| --- | --- |
| HTTP API `/v1/*` | Stable for `1.x` |
| `typewhisper` CLI | Stable for `1.x` |
| Plugin SDK | Stable for `1.x` |
