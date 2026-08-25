---
sidebar_position: 5
title: Troubleshooting
---

# Troubleshooting

## `/ready` reports providers unavailable

Inspect the admin **Providers** page and `neorecall logs`. Both transcription and language generation require an external provider, endpoint, and any credentials that provider needs. Use **Fetch models** to verify credentials and select a current model.

The response separates them: `models` covers the configured transcription provider and `languageModel` the provider that writes memories, previews, and Ask answers. Both gate readiness. Readiness checks configuration locally; model discovery is the explicit network check.

`neorecall setup` only verifies the pinned semantic-search embedding model. It never downloads or starts speech or language models.

## Memory generation is slow or falls behind

Check the admin dashboard for queue depth and provider failures. Choose a faster external model or deployment, or raise `NEORECALL_CONVERSATION_PREVIEW_MIN_INTERVAL_MS` and `NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS` so the provider receives less work. `NEORECALL_MIN_AI_AUDIO_MS` keeps short recordings away from the model entirely.

## `AI_CONTEXT_EXCEEDED`

A single request did not fit in `LLM_CONTEXT_SIZE`. Consolidation windows its input to fit, so this means one indivisible piece of evidence — a single recognized utterance — is larger than a whole window. Set `LLM_CONTEXT_SIZE` to the external model's real context limit or lower `AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` to leave more room for input.

## A chunk remains cleanup-pending

The transcript is already persisted, but the server has not yet issued a terminal receipt. Keep the client running and do not remove its local audio. The cleanup job and startup sweeper retry the unlink; the state then advances without retranscribing or duplicating segments.

## System audio is unavailable in a browser

Start device-audio capture from the Record screen and choose a share target that offers audio. Browser and operating-system support varies. NeoRecall displays microphone-only fallback rather than pretending system audio is active. Reloading always requires a new display-capture gesture.

## Recording stopped because storage is full

Free local space, reopen NeoRecall, and let the upload queue drain. Pending chunks are not discarded automatically. On the web, grant persistent browser storage if offered and review the quota indicator.

## Search misses semantic matches

Confirm `/ready` reports the vector extension and models ready. Newly transcribed segments are indexed by a worker job, so a large backlog may delay embeddings while exact FTS results remain available. The admin dashboard shows queue depth and oldest job age.

## Logs differ from the running deployment

NeoRecall is often operated on a separate server. Always collect logs and readiness output from the host handling the recording upload, not from a development checkout on another machine.
