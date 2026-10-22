# OpenAI Compatible plugin

The OpenAI Compatible plugin supports standard OpenAI-style endpoints and
provider-specific deployment-scoped batch transcription routes.

## Batch transcription endpoint styles

- **Standard v1** sends multipart requests to
  `/v1/audio/transcriptions`.
- **Deployment-scoped** sends multipart requests to
  `/deployments/{selected-model}/audio/transcriptions` and requires a dated
  API version.

The selected transcription model is included in the multipart `model` field.
The plugin keeps Standard v1 as the default for existing profiles.

## Batch upload format

Each batch profile has an **Upload Format** setting:

- **Auto** (default) compresses audio as M4A and falls back to WAV if encoding
  fails or the server rejects the audio format, including llama.cpp's
  `Failed to load image or audio file` response.
- **WAV** sends WAV directly, without AAC encoding or an initial M4A request.
  Use this for servers that do not accept M4A.

The setting applies to batch transcription and translation on both endpoint
styles, including requests with an API version. Long recordings still use the
same chunking limits. Realtime transcription is unaffected.

The llama.cpp fallback is implemented in the host SDK. Update the host app
together with the plugin to receive this fix. On older hosts, select **WAV**
to bypass the rejected M4A upload.

## Transcript previews

Batch profiles submit transcription after recording stops, without repeatedly
uploading audio for interim previews. This also applies when Auto selects a
batch model, and each additional profile uses its own transport setting.
Realtime profiles continue to support native live transcript previews.

## Azure OpenAI and Microsoft Foundry

Some Azure offline transcription deployments require the deployment-scoped
route rather than the OpenAI v1 route. Configure a dedicated profile with:

- Base URL: the resource endpoint ending in `/openai`
- API Version: the dated version supported by the deployment, such as
  `2025-03-01-preview`
- Transcription Model: the Azure deployment name
- Transcription Transport: `Batch` or `Auto` for a batch model
- Batch Transcription Endpoint: `Deployment-scoped`

For realtime transcription, select the `Realtime` transport and configure the
API version required by the provider's `/v1/realtime` endpoint. Realtime
requests always use `/v1/realtime` and ignore the Batch Transcription Endpoint
setting. A separate profile is recommended when batch and realtime endpoints
require different API versions.

## Ollama model discovery

Set **Server Kind** to `Ollama` on a profile pointing at an Ollama server
(e.g. `http://localhost:11434`) to list installed models through the server's
native `/api/tags` endpoint. Model names are shown exactly as reported,
including tags (`llama3.1:8b`). If native discovery fails, the profile falls
back to the OpenAI-compatible `/v1/models` endpoint, and manual model entry
remains available. Generic profiles never send Ollama-specific requests.

## Reasoning effort

Profiles that use the **Responses** LLM API have a **Reasoning Effort**
setting. **Provider Default** omits `reasoning`; the other levels send
`reasoning: { effort: ... }` to `/v1/responses` and leave out the temperature.

A workflow or an entry in the global LLM fallback list can pick its own effort
for a Responses profile (Low, Medium, High, X High or Max). Its **Provider
Default** uses the profile's setting. Each profile is a separate provider with
its own setting. Chat Completions profiles never send an effort, whatever the
server kind, so workflows show no effort picker for them.
