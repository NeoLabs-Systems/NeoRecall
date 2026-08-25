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

## The endpoint cannot compile the response schema

`neorecall logs` shows a 400 with wording like `failed to parse grammar` or `unsupported schema`. Some llama.cpp-derived builds convert `response_format: json_schema` into a grammar and reject schemas they cannot express.

NeoRecall recovers on its own: it retries the same request asking for plain JSON, and the reply is validated against the same contract before anything is stored. You lose nothing but one extra round trip. The warning is logged as **The endpoint could not compile the response schema; asking for plain JSON instead** so the cause stays visible; upgrading the endpoint removes the extra call.

## Responses stop halfway

A reasoning model spends the output budget on its thinking block and the JSON never closes. NeoRecall retries once with thinking disabled, and the admin **Providers** page exposes the same switch as **Skip the model's thinking step**. If it still truncates, raise `AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` and `AI_PREVIEW_MAX_OUTPUT_TOKENS`.

## A request fails after about five minutes with no reason given

A model that answers slowly used to be cut off by a hidden five-minute ceiling in the HTTP client and reported only as `fetch failed`. Requests now run until `AI_REQUEST_TIMEOUT_MS` (default thirty minutes) without a response, so a local model that needs ten minutes for a long conversation is left to finish. A genuine stall is reported as `AI_TIMEOUT`, naming the wait.

## Memory generation is waiting

After a failed run, NeoRecall backs off — 60 seconds, doubling to a 30 minute ceiling — instead of retrying against a provider that is down. `neorecall logs` states **Memory generation is waiting** once when it starts and **Memory generation is running again** once when it resumes; it does not repeat the line every tick. Fixing the provider and requesting memory generation by hand skips the wait.

## Transcripts appear but memories do not

This is the intended split: recordings are transcribed and searchable even when the language provider is unreachable, and the app keeps showing them without the AI write-up. The conversations stay queued; when the provider recovers they are written up in order. If they fail repeatedly they are set aside rather than retried forever, and the app tells the user in plain language that some conversations still need to be written up. No audio and no transcript is discarded at any point.

## Several cards describe the same lesson or meeting

One real-world occasion should be one card. When a long occasion arrives as several stretches of recording, each run is shown the recent cards from the same recording and asked, as part of the same request, whether the new material is the same occasion. A card it identifies is extended rather than duplicated, and several fragments it identifies together are absorbed into the oldest one, keeping every transcript source and highlight.

Nothing merges on resemblance: a repeated lesson, a weekly meeting, or an identical title stays separate unless the model identifies the event itself as continuing. Each candidate is presented with how many minutes passed and whether the recording ran on without stopping, and the model must write one sentence of reasoning before it may claim anything — `neorecall logs` at debug level records that sentence for any card that was extended. `NEORECALL_MAX_MEMORY_CONTINUATION_CANDIDATES` only bounds how many recent cards are offered for the judgement.

Cards that already exist from before this behaviour are left as they are. Select them in Memories and merge them by hand once; new recordings will not add to the pile.

Two things are deliberately left alone. A card you renamed or gave your own emoji keeps your wording when it is extended — only its summary grows. A card you archived is never offered as somewhere to file new material, so later recordings appear as a card you can see rather than disappearing into one you put away.

## Writing one moment up again

Expanding a moment in the timeline offers **Write up again**. It rebuilds only what the model produced — that moment's title, summary and memory — and never touches the transcript. The memory it replaces is removed first so the moment is not described twice; a memory that also covers other conversations is left alone, because those are not being redone. With no language model configured the request is refused and nothing is removed.

## Merging memories does not wait for the model

Merging combines evidence, highlights and sources at once and the merged card appears immediately, with a description joined from the cards it replaced. Rewording that description is a queued background job, so a slow or unreachable language provider never holds the app open; the wording updates on a later refresh. If the merged card is renamed or merged again in the meantime, what is on screen wins and the queued rewording is dropped.

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
