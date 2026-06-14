# GeminiSTTPlugin

Speech-to-text via **Google Gemini** (AI Studio direct — no proxy). Adds a
`TranscriptionEnginePlugin` that calls `generativelanguage.googleapis.com`
directly, with an editable **system prompt** and **glossary** in settings.

## Why this exists (vs. the other Gemini plugins)

| Plugin | Role | Uses audio? | Editable prompt? |
|---|---|---|---|
| `GeminiPlugin` (existing) | LLM text provider | No — text in, text out | No |
| `OpenRouterPlugin` (existing) | LLM text provider via OpenRouter | No | No |
| **`GeminiSTTPlugin` (this one)** | **Transcription engine** | **Yes — inline WAV → text** | **Yes** |

## Benchmark that motivated this

On a 4-file technical-dictation set (ML/AI jargon, Swift internals, infra
configs), using the default system prompt + glossary shipped with the plugin:

| Engine | Key-term accuracy | Median latency | Cost/hr |
|---|---|---|---|
| Groq Whisper Large v3 | 60.5 % | 1.4 s | $0.111 |
| Gemini Flash-Lite via OpenRouter | 100 % | 3.2 s | $0.058 |
| **Gemini Flash-Lite via Google direct (this plugin)** | **100 %** | **2.6 s** | **$0.058** |

## Build & install (no Xcode required)

Plain `swiftc` against the installed TypeWhisper.app's embedded
`TypeWhisperPluginSDK.framework`. No SPM, no `project.pbxproj` edits, ~3s
rebuilds.

```bash
cd Plugins/GeminiSTTPlugin
./build-bundle.sh            # build + sign → dist/GeminiSTTPlugin.bundle
./build-bundle.sh --install  # same, plus copy to ~/Library/Application Support/TypeWhisper/Plugins/
./build-bundle.sh --debug    # -Onone + -g (faster builds, larger binary)
./build-bundle.sh --app-path /path/to/TypeWhisper.app   # override framework source
```

**Prerequisites**:
- Swift 6 toolchain (`xcode-select --install` is enough — Xcode.app GUI is NOT
  needed, just the command-line tools).
- `TypeWhisper.app` installed at `/Applications/` (or pass `--app-path`). The
  build links against its embedded `TypeWhisperPluginSDK.framework`.

### Project layout

```
Plugins/GeminiSTTPlugin/
├── Sources/GeminiSTTPlugin/
│   └── GeminiSTTPlugin.swift   # plugin class + settings view (~500 lines)
├── manifest.json               # TypeWhisper plugin metadata (principalClass, etc.)
├── build-bundle.sh             # two-step swiftc compile + bundle wrap + codesign
└── README.md                   # this file
```

### How the build works (two-step swiftc)

The shipped `TypeWhisperPluginSDK.framework` is binary-only (no `.swiftmodule`
for the Swift compiler to consume), so we can't `import TypeWhisperPluginSDK`
from it directly. We instead:

1. **Rebuild the SDK's `.swiftmodule` from source** at
   `../../TypeWhisperPluginSDK/Sources/` — produces just the module interface
   (not a dylib). Cached in `build/sdk/`.
2. **Compile + link the plugin** with `-I build/sdk` (for `import` resolution)
   plus `-F /Applications/TypeWhisper.app/Contents/Frameworks -framework
   TypeWhisperPluginSDK` (for link-time symbol binding against the exact SDK
   version the host app loads).
3. **Wrap as `.bundle`** — move the dylib to `Contents/MacOS/GeminiSTTPlugin`,
   `install_name_tool -id` it, write `Contents/Info.plist` and
   `Contents/Resources/manifest.json`, strip xattrs, ad-hoc sign
   (`codesign -s -`).

The final dylib's `LC_LOAD_DYLIB` for the SDK reads
`@rpath/TypeWhisperPluginSDK.framework/Versions/A/TypeWhisperPluginSDK` — the
exact same install name TypeWhisper.app has in its dyld cache, so when
`Bundle.load()` runs, dyld reuses the already-loaded image. This is the same
pattern the existing `STTFixerPlugin` uses in production.

### After install

Launch TypeWhisper → **Settings → Integrations** → enable **Gemini STT** →
click the gear icon → paste your AI Studio API key.

## Configuration

- **API Key** — get one free at
  [aistudio.google.com/apikey](https://aistudio.google.com/apikey). Stored in
  Keychain, scoped to the plugin ID.
- **Model** — defaults to `gemini-3.1-flash-lite` (fastest + most
  accurate in our tests). `gemini-3-flash-preview` is available as a
  higher-quality fallback.
- **System Prompt** — full template, editable. Use `{GLOSSARY}` as the token
  that gets replaced with your glossary at request time.
- **Glossary** — comma-separated terms. Merged with per-rule dictionary terms
  that TypeWhisper passes via the `prompt` parameter.
- **Temperature** (under Advanced) — defaults to `0.2`. Higher values add
  creativity you probably don't want for transcription.

## Network / latency notes

- Endpoint: `generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`
- Auth: `x-goog-api-key` header
- `thinkingConfig.thinkingBudget: 0` is set on every request (critical for
  Flash-Lite — otherwise the model silently "thinks" and adds seconds of
  latency).
- Audio is sent inline as base64 in `inlineData`. Safe for anything under
  ~20 MB (a 50-second 16 kHz mono WAV is ~1.6 MB).
- Uses `PluginHTTPClient` (fresh ephemeral session per request — avoids stale
  HTTP/2 channels after sleep/wake).

## Known limitations (v1.0.0)

- `supportsTranslation` is `false`. Gemini can translate, but we haven't wired
  the `translate` flag through to a second prompt variant. Easy to add.
- `supportsStreaming` is `false`. Benchmarks showed streaming doesn't actually
  help for short transcription outputs — TTFT ≈ E2E for this workload.
- No "Test transcription" button in settings. API-key validation only.
- No Vertex AI / OAuth path. AI Studio API key only. Regional endpoints don't
  support Gemini 3 preview models anyway.
