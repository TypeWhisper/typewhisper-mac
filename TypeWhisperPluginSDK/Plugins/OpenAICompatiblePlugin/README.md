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
