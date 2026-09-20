# Confucius4-R2T2 Plugin

Transcription engine plugin that streams microphone audio to a local
[audio.cpp](https://github.com/0xShug0/audio.cpp) `audiocpp_server` running the
[Confucius4-R2T2](https://github.com/netease-youdao/Confucius4-R2T2) GGUF on Metal, and returns
its append-only transcript. Supports batch transcription, progress streaming, and TypeWhisper
live sessions. Runs fully on-device; no GPU server needed.

## Server

Build audio.cpp with Metal (the Homebrew bottle may predate R2T2 support):

```sh
git clone --recurse-submodules https://github.com/0xShug0/audio.cpp
cd audio.cpp && scripts/build_metal.sh --build-type Release --deployment-build
```

Get the GGUF (Q8_0 or F16; lower quantizations are rejected by audio.cpp) and make sure the
file the server opens is named `*.gguf`. HuggingFace cache symlinks resolve to extension-less
blobs, which audio.cpp cannot identify, so hardlink or copy it:

```sh
hf download davidxifeng/Confucius4-R2T2-gguf r2t2-q8_0.gguf
ln "$(readlink -f ~/.cache/huggingface/hub/models--davidxifeng--Confucius4-R2T2-gguf/snapshots/*/r2t2-q8_0.gguf)" \
   models/Confucius4-R2T2-GGUF/r2t2-q8_0.gguf
```

Server config (`server.json`):

```json
{
  "host": "127.0.0.1", "port": 8488, "backend": "metal", "lazy_load": true,
  "models": [{
    "id": "r2t2", "family": "confucius4_r2t2", "task": "asr", "mode": "streaming",
    "path": "/abs/path/models/Confucius4-R2T2-GGUF/r2t2-q8_0.gguf",
    "session_options": { "confucius4_r2t2.chunk_size_ms": "320" }
  }]
}
```

```sh
build/macos-metal-release/bin/audiocpp_server --config server.json
```

## Settings

| Setting | Default | Notes |
|---|---|---|
| Server URL | `http://127.0.0.1:8488` | `https://` also works |
| Model ID | `r2t2` | Must match a model entry with `mode: "streaming"` |

Test Connection checks `/v1/models` for the configured id and mode.

## Protocol

`POST /v1/audio/transcriptions/live?model=<id>&sample_rate=16000&channels=1&sample_format=s16le[&language=<Name>]`
with a `Transfer-Encoding: chunked` PCM16LE body. The server answers on the same connection with a
chunked `text/event-stream`: `transcript.text.delta` events (append-only), one
`transcript.text.done` with the full transcript, then `[DONE]`. Errors arrive as
`{"type":"error","error":{"message":...}}`.

URLSession cannot read a response while it is still uploading the body, so the plugin speaks
HTTP/1.1 directly over `NWConnection`. Batch transcription reuses the same path: send all PCM,
then the terminating chunk.

Language hints are mapped from ISO codes to the canonical names the model prompt expects
(`en` → `English`, `zh` → `Chinese`, …); unknown codes leave detection to the model.

## Performance (M-series, Q8_0, 320 ms chunks)

A 14 s English clip streams in about 6.5 s warm, with first text after roughly 0.9 s.
