# Local LLM (llama.cpp)

LLM provider plugin that runs GGUF models on the Mac with
[llama.cpp](https://github.com/ggml-org/llama.cpp) and Metal. Workflows, prompts and the
LLM fallback list use it like any other provider; text never leaves the Mac.

Plugin ID `com.typewhisper.local-llm-llamacpp`, provider ID `Local LLM (llama.cpp)`,
minimum host 1.8.0, Apple silicon only. The Windows plugin with the same ID offers the same
catalog with a bundled CPU runtime.

## Models

The catalog uses the same GGUF files, revisions and SHA-256 checksums as the Windows plugin:

| Model | Repository | Size | RAM |
| --- | --- | --- | --- |
| Gemma 4 E2B (Q4_K_M) | `unsloth/gemma-4-E2B-it-GGUF` | 3.1 GB | 8 GB+ |
| Gemma 4 E4B (Q4_K_M) | `unsloth/gemma-4-E4B-it-GGUF` | 5.0 GB | 16 GB+ |
| Gemma 4 E4B (Q8_0) | `unsloth/gemma-4-E4B-it-GGUF` | 8.2 GB | 16 GB+ |
| Gemma 4 26B-A4B (Q4_K_M, MoE), experimental | `unsloth/gemma-4-26B-A4B-it-GGUF` | 16.9 GB | 32 GB+ |
| Qwen3.5 2B (Q4_K_M), experimental | `unsloth/Qwen3.5-2B-GGUF` | 1.3 GB | 8 GB+ |
| LFM2.5 2.6B (Q4_K_M), experimental | `LiquidAI/LFM2.5-2.6B-GGUF` | 1.7 GB | 8 GB+ |

The settings recommend Gemma 4 E2B or E4B based on the Mac's memory.

**Your Models** adds any other model:

- **Hugging Face:** enter `owner/repo`, `owner/repo:Q4_K_M` or a huggingface.co link and pick a
  file. The plugin pins the file to the repository's current commit and checks size and SHA-256
  after the download. Projector files (`mmproj-*.gguf`) and models split into several files
  are not offered. Private and gated repositories need a saved Hugging Face token.
- **File:** import a `.gguf` file. It is copied into the plugin's data folder; when the file is on
  the same APFS volume, the copy is a clone and takes no extra space. The original file stays
  where it is.

Custom models are stored in `custom-models.json` in the plugin data directory.

## Runtime

The first load downloads `llama-<build>-bin-macos-arm64.tar.gz` from the pinned
[llama.cpp release](https://github.com/ggml-org/llama.cpp/releases), checks its size and
SHA-256 and extracts it to `Runtime/llama-<build>/`. Models live in `Models/<model id>/`
with a `.<file>.verified` marker, so later loads compare size and modification date instead
of hashing again.

`llama-server` starts with the loaded model on `127.0.0.1` and a random port, with a random
API key passed in `LLAMA_API_KEY`. It runs with `--offline`, one slot, an 8,192-token context,
all layers on Metal, thinking turned off (`--reasoning off` and
`chat_template_kwargs.enable_thinking = false`) and no prompt cache in host memory. Inherited
`LLAMA_*` environment variables are removed. A small shell supervisor stops the server when
TypeWhisper exits or crashes. The chat template comes from the GGUF file, so models without
code in this plugin work as long as their file contains a template.

Unloading, auto-unload and removing the model stop the server. Prompts after an auto-unload
or an unexpected server exit start it again.

### Raising the llama.cpp version

Change `LlamaCppRuntimeRelease.pinned` in `LlamaCppRuntime.swift`: build tag, version, archive
size and SHA-256 of the macOS arm64 archive (`gh release view <build> --repo
ggml-org/llama.cpp --json assets`). The new build installs next to the old one with the next
model load and removes it afterwards. Run the live test below with the new build.

## Multimodal projectors

`LlamaCppModelDefinition.projector` names an optional `mmproj` file that is downloaded and
verified like the weights and passed to `llama-server` with `--mmproj`. The catalog and the
settings do not use it yet. It is the basis for audio models such as LFM3-Audio, which need a
projector and a llama.cpp build that supports them, and for a transcription capability next
to the LLM provider.

## Tests

```sh
swift test --package-path TypeWhisperPluginSDK --filter LlamaCppPluginTests
```

The live test starts the real server. It is skipped unless both variables are set:

```sh
TYPEWHISPER_LLAMACPP_LIVE_RUNTIME=/path/to/llama-b11669 \
TYPEWHISPER_LLAMACPP_LIVE_MODEL=/path/to/Qwen3.5-2B-Q4_K_M.gguf \
swift test --package-path TypeWhisperPluginSDK --filter LlamaCppLiveServerTests
```

## Licenses

llama.cpp is MIT licensed; its `LICENSE` ships in the downloaded archive. Gemma 4 and Qwen3.5
use Apache 2.0. LFM2.5 uses the LFM Open License v1.0, which allows free commercial use only
below USD 10 million annual revenue. Custom models keep the license of their repository.
