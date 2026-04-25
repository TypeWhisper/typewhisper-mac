# TypeWhisper Support Matrix

This matrix describes the officially supported direct-download path for the current stable macOS release. The public runtime support floor remains `macOS 14+`.

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
| System-wide dictation | Yes | Yes | Yes | Core workflow in the current stable release |
| File transcription | Yes | Yes | Yes | Core workflow in the current stable release |
| Workflow processing | Yes | Yes | Yes | Core workflow in the current stable release |
| Workflows, History, Dictionary, Snippets | Yes | Yes | Yes | Core workflow in the current stable release |
| Notch, Overlay, and Minimal indicators | Yes | Yes | Yes | User-facing status surfaces in `1.3` |
| Widgets | Yes | Yes | Yes | Supported advanced surface |
| HTTP API | Yes | Yes | Yes | Loopback-only, disabled by default |
| CLI | Yes | Yes | Yes | Requires the local API server to be running |
| Apple Translate integration | No | Yes | Yes | Advanced surface |
| Apple Intelligence provider | No | No | Yes | Optional provider surface |
| SpeechAnalyzer engine | No | No | Yes | Optional engine surface |

## Engine Notes

| Surface | Support in the current stable release | Notes |
| --- | --- | --- |
| Local engines | Yes | Recommended default path |
| Cloud engines | Yes | Require valid API keys |
| Bundled MLX engines | Yes | Qwen3, Granite, Voxtral, and Gemma 4 are bundled. Qwen3, Granite, and Voxtral support an optional HuggingFace token for higher download rate limits. Gemma 4 prompt processing is currently limited to the E2B/E4B 4-bit variants |
| Bundled plugins | Yes | Part of the tested product path |
| External third-party plugins | Best effort | Not a stable-release blocker for the current stable release |

## Automation Notes

| Surface | Status in the current stable release |
| --- | --- |
| HTTP API `/v1/*` | Stable in the current stable release |
| `typewhisper` CLI | Stable in the current stable release |
| Plugin SDK | Stable in the current stable release |
