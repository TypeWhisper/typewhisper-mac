# Confucius4-R2T2 Plugin

Transcription engine plugin that streams microphone audio to a self-hosted
[Confucius4-R2T2](https://github.com/netease-youdao/Confucius4-R2T2) WebSocket server
(`ws_server.py`) and returns its append-only transcript. Supports batch transcription,
progress streaming, and TypeWhisper live sessions.

## Server

R2T2 needs a CUDA GPU with vLLM; run the reference server on a Linux box and point the
plugin at it:

```sh
./run_start_server.sh start --model_path /path/to/Confucius4-R2T2 --port 8272
```

The reference server accepts only the secret keys listed in `secret_key_list` in
`ws_server.py` (default `test0102`). Change both when exposing the server beyond localhost.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Server URL | `ws://localhost:8272/asr_stream_api_v1` | `http(s)://` is rewritten to `ws(s)://`; missing path defaults to `/asr_stream_api_v1` |
| Secret Key | `test0102` | Stored in the Keychain |
| Server-side VAD | off | Enables the FireRedVAD segmenting in the server; upstream says it may reduce quality |

TypeWhisper's Info.plist allows local networking only (`NSAllowsLocalNetworking`). Plain
`ws://` works for localhost and LAN hosts; a remote server must be reachable via `wss://`.

## Protocol

1. Text frame: JSON header `{channels, sample_rate, requestId, language, use_vad, secret_key, mode}`
2. Binary frames: 16 kHz mono PCM16LE
3. Text frame: `YOUDAO_ONETIME_ASR_STREAM_EOS`
4. Server replies: `{"status":"connected"}`, `{}` keep-alives, `{"status":"success","msg":{"text":"<delta>","reset":Bool}}`, then closes after the final delta.

Language hints are mapped from ISO codes to the canonical names the model prompt expects
(`en` → `English`, `zh` → `Chinese`, …); unknown codes fall back to `zhen` (auto).
