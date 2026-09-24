# Importing local speech models

Open **Settings → Dictation → Import Model…** or **Integrations → Import Model…**.
Choose either a Hugging Face model repository (`owner/model` or its HTTPS URL) or a
local folder containing `config.json`, tokenizer assets and `.safetensors` weights.
For private or gated repositories, supply a Hugging Face token with access to the
model. The import dialog does not save the token.

TypeWhisper reads the configuration and chooses an enabled engine that supports
that architecture. The current import providers are:

| Model architecture (`model_type`) | Plugin |
| --- | --- |
| `canary` | Canary ASR |
| `qwen3_asr` | Qwen3 ASR |
| `granite_speech` | Granite Speech |
| `voxtral_realtime` | Voxtral |

The files must be compatible with the plugin's MLX loader. The engine loads the
model before accepting the import, so matching `model_type` alone does not
establish compatibility. A failed import is removed and the previous model stays
available. Importing a model does not add support for a new architecture.
Canary, including `KIEFERSA/Sophea-Canary-ASR-mlx`, is supported by the Canary ASR
plugin. Select an explicit source language in Dictation settings: **Greek** for
Greek Sophea audio and **English** for English audio. The Canary plugin does not
automatically detect languages or expose translation. Core ML WhisperKit/Parakeet
models cannot use this MLX import path.

On success, the model is loaded and appears in the plugin's model list. Select the
engine in Dictation settings to use it for dictation. The imported entry survives
restarts and unloading. Remove it from the plugin's downloaded-model list in
Integrations when it is no longer needed.

Local files are copied into the plugin's `custom-models` directory. Removing an
import deletes only that copy. Hugging Face imports pin configuration and data
files to the same repository commit. Repository scripts are neither downloaded
nor executed. A repository root is required; links to branches, individual files
or subfolders are not accepted.

## Plugin integration

`PluginCustomModelImporting` is an optional SDK protocol. Existing plugins need
no changes unless they want to provide import support. New import-capable bundles
require a host that exports this SDK capability; they must not be released for
older hosts merely because those hosts share the same marketing version.

The shared `PluginCustomModelStore` stages copies/downloads, checks the model
configuration, required files, indexed shards and safetensors headers, then
records a stable custom model ID. The engine performs final loader validation,
rolls back failures, and handles its usual selection/restoration notifications.

## Verification

The SDK regression suite includes local copy ownership, reopening and removal,
architecture mismatch, changed configurations, missing tokenizer/shards, truncated
weights, Git LFS pointers, symlinked snapshots, duplicate imports, cancellation,
HTTP authentication failures, pinned remote downloads and interrupted downloads.

```sh
swift test --package-path TypeWhisperPluginSDK --filter PluginCustomModelImportTests
python3 scripts/check_localization_completeness.py
git diff --check
```

Native validation on Apple Silicon also exercised Qwen3-ASR-1.7B-4bit from a local
snapshot and Qwen3-ASR-0.6B-4bit from Hugging Face: import, model loading, a synthetic
English transcription, plugin restart/restoration, repeated transcription and
removal while preserving the local source. Sophea Canary was validated with its
BF16 weights, synthetic Greek and English speech, explicit-language validation,
plugin restart/restoration and repeated Greek transcription. The Canary loader
handles NeMo preprocessing buffers and subsampling convolution layouts, and checks
that all model parameters are present with the expected shapes. Regression tests
cover those conversions without changing already-native MLX layouts. The dev app's
Hugging Face import dialog was also exercised with the original Sophea URL
(revision `1d0827f8f869dfad40f6b6980434cf34b1987963`): it completed with the
"Imported and loaded" confirmation.

Granite and Voxtral were build-checked; their custom models were not run through
inference in that validation.
