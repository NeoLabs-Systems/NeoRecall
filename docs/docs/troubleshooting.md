---
sidebar_position: 5
title: Troubleshooting
---

# Troubleshooting

## `/ready` reports models unavailable

Run `neorecall setup` and inspect `neorecall logs`. Setup verifies every downloaded SHA-256 and will resume incomplete downloads. Normal startup intentionally refuses to fetch missing model files.

The response separates them: `models` covers the speech pipeline and `languageModel` the model that writes memories, previews and Ask answers. Both gate readiness, because a server that transcribes but cannot write a memory looks healthy while producing nothing you installed it for. If `languageModel` is false with `AI_PROVIDER=openai_compatible`, it means `AI_API_BASE_URL` or `AI_API_MODEL` is unset — it does not test whether the endpoint answers.

## Memory generation is slow or falls behind

Generation runs on this machine, so it costs CPU or GPU time. Check the admin dashboard for queue depth. `LLM_GPU_LAYERS=auto` already offloads what a detected GPU can hold; on a CPU-only host the fastest fixes are a smaller quantization or a smaller model through `LLM_MODEL_FILE`, and then raising `NEORECALL_CONVERSATION_PREVIEW_MIN_INTERVAL_MS` and `NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS` so the machine is asked for less. `NEORECALL_MIN_AI_AUDIO_MS` keeps short recordings away from the model entirely.

## `AI_CONTEXT_EXCEEDED`

A single request did not fit in `LLM_CONTEXT_SIZE`. Consolidation windows its input to fit, so this means one indivisible piece of evidence — a single recognized utterance — is larger than a whole window. Raise `LLM_CONTEXT_SIZE` (which costs memory) or lower `AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` to leave more room for input.

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
