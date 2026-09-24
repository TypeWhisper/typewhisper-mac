# Importing local speech models

Open **Settings → Integrations → Installed → your plugin → Settings → Import Model…**.
The import button is next to the model list in the plugin settings window.
Choose either a Hugging Face model repository (`owner/model` or its HTTPS URL) or a
local folder containing `config.json`, tokenizer assets and `.safetensors` weights.
For private or gated repositories, supply a Hugging Face token with access to the
model. The import dialog does not save the token.

The selected plugin reads the configuration and checks that it supports the model
architecture before downloading weights. The current import providers are:

| Model architecture (`model_type`) | Plugin |
| --- | --- |
| `canary` | Canary ASR |
| `qwen3_asr` | Qwen3 ASR |
| `granite_speech` | Granite Speech |
| `voxtral_realtime` | Voxtral |

The files must be compatible with the plugin's MLX loader. The engine loads the
model before accepting the import, so matching `model_type` alone does not
establish compatibility. A failed import is removed and the previous model stays
available. Before native validation, the previous runtime is unloaded to avoid
holding two large models in memory. If validation fails, select/load the previous
model again. Canary checks cancellation between shards and individual tensor
loads; an in-progress native tensor read must finish before cancellation returns.
Importing a model does not add support for a new architecture.
Canary, including `KIEFERSA/Sophea-Canary-ASR-mlx`, is supported by the Canary ASR
plugin. Select an explicit source language in Dictation settings: **Greek** for
Greek Sophea audio and **English** for English audio. The Canary plugin does not
automatically detect languages or expose translation. Core ML WhisperKit/Parakeet
models cannot use this MLX import path. Longer Canary recordings use roughly
20-second chunks, searching nearby low-energy pauses for boundaries.

On success, the model is loaded and appears in the plugin's model list. Select the
engine in Dictation settings to use it for dictation. The imported entry survives
restarts and unloading. Remove it from the plugin's downloaded-model list in
Integrations when it is no longer needed.

Remote repository metadata and configurations are limited to 4 MiB while streaming,
including responses without a Content-Length header. Safetensors index JSON is read
through a bounded reader and limited to 16 MiB. Abandoned staging folders
are recovered in the background when a plugin activates; operating-system file leases protect active
imports, including imports in another process. Imports stay hidden and marked pending
until native validation finishes, so recovery also removes abandoned validation attempts.
Duplicate detection and final publication
share the same lock, so concurrent imports cannot publish the same revision twice.

Local files are copied in cancellable chunks into the plugin's `custom-models` directory. Removing an
import deletes only that copy. Hugging Face imports pin configuration and data
files to the same repository commit. Repository scripts are neither downloaded
nor executed. A repository root is required; links to branches, individual files
or subfolders are not accepted.

## Plugin integration

`PluginModelImportButton(importer:bundle:)` provides the shared dialog inside
each plugin’s own settings view. It validates against that plugin’s supported
architectures and uses the plugin bundle for its UI translations.

`PluginCustomModelImporting` is an optional SDK protocol. Existing plugins need
no changes unless they want to provide import support. New import-capable bundles
declare `sdkCompatibilityVersion: "v1-model-import"`. The next Daily or RC containing
this change accepts both this marker and existing `v1` plugins. Older hosts only
accept `v1`, so they neither offer nor load the new bundles even when their
marketing version is also 1.7.0. Publish the updated plugins only after that host
is available and the release workflow validates their symbols against its SDK
with `allow_prerelease_host`. Official capability releases also enter the combined
`plugins-community-v1.json` feed read by the app; older compatible releases remain
available there. The stable host minimum remains 1.7.0.

The shared `PluginCustomModelStore` stages copies/downloads, checks the model
configuration, required files, indexed shards and safetensors headers, then
records a stable custom model ID. The engine performs final loader validation,
rolls back failures, and handles its usual selection/restoration notifications.
Unloading or a newer explicit load request invalidates pending imports, so they
cannot later replace the requested engine state. Generic restoration is cancelled
when an explicit load takes over. Canary releases the MLX allocator cache after
inference becomes idle when unloading or deactivating. Incomplete imported copies remain
listed for removal through the model manager.

## Verification

The SDK regression suite includes local copy ownership, reopening and removal,
architecture mismatch, changed configurations, missing tokenizer/shards, truncated
weights, Git LFS pointers, symlinked snapshots, duplicate imports, cancellation,
HTTP authentication failures, pinned remote downloads, interrupted downloads and
cancellation during a large local file copy. Explicit model-load entry points are
covered for imported models in all four engines and for a fresh Canary install.
Regression tests also cover simultaneous duplicate imports, auto-unload while an
import waits for native loading, superseding explicit requests, interrupted native
validation, removal of incomplete imports, and Canary chunk boundaries without lost samples.

```sh
swift test --package-path TypeWhisperPluginSDK --filter PluginCustomModelImportTests
python3 scripts/check_localization_completeness.py
git diff --check
```

Native validation on Apple Silicon also exercised Qwen3-ASR-1.7B-4bit from a local
snapshot and Qwen3-ASR-0.6B-4bit from Hugging Face: import, model loading, a synthetic
English transcription, plugin restart/restoration, repeated transcription and
removal while preserving the local source. Sophea Canary was validated with its
BF16 weights, synthetic Greek and English speech (including a 61-second English
recording spanning multiple chunks), explicit-language validation,
plugin restart/restoration and repeated Greek transcription. Both Qwen3 and
Sophea were also exercised through the explicit model-load entry point after
auto-unload and with deactivation from the import-completion notification; the
interrupted import returned cancellation and removed its files. The Canary loader
handles NeMo preprocessing buffers and subsampling convolution layouts, and checks
that all model parameters are present with the expected shapes. Regression tests
cover those conversions without changing already-native MLX layouts in the Xcode
app-test target, where Metal resources are bundled. The SwiftPM suite covers the
remaining Canary checks without initializing the MLX runtime. The dev app's
Hugging Face import dialog was also exercised with the original Sophea URL
(revision `1d0827f8f869dfad40f6b6980434cf34b1987963`): it completed with the
"Imported and loaded" confirmation.

Granite and Voxtral were build-checked; their custom models were not run through
inference in that validation.
