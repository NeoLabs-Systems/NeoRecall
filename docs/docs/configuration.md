---
sidebar_position: 3
title: Configuration
---

# Configuration

NeoRecall reads `~/.neorecall/.env` and process environment variables. See the commented `.env.example` for the complete list.

## Essential server values

| Variable | Purpose | Default |
|---|---|---|
| `NEORECALL_HOST` | Listen address | `127.0.0.1` |
| `NEORECALL_PORT` | HTTP port | `4500` |
| `NEORECALL_TRUST_PROXY` | Trust one reverse-proxy hop | `false` |
| `MAX_UPLOAD_BYTES` | Maximum live chunk upload | `33554432` |
| `NEORECALL_REQUIRE_VECTOR` | Fail without the tested sqlite-vec extension | production: `true` |

## Local inference

`TRANSCRIPTION_PROVIDER=sherpa` selects the native CPU pipeline. `NEORECALL_SHERPA_THREADS` controls native inference threads. An OpenAI-compatible transcription endpoint can be selected with `TRANSCRIPTION_PROVIDER=openai_compatible`, `TRANSCRIPTION_API_BASE_URL`, and an optional key; this is separate from OpenRouter and is intended for self-hosted speech servers.

The embedding model must produce exactly 384 dimensions. Setup probes it before startup. Model files and their revisions are pinned in `models/manifest.json`.

When the recogniser does not label a segment's language itself, a statistical detector fills in — but only above `NEORECALL_LANGUAGE_DETECTION_MIN_CHARACTERS`. Below it there is not enough text to decide, and the detector answers anyway: three hours of real council audio produced "Gentlemen." labelled Afrikaans and "Uh" labelled Klingon. A segment shorter than the threshold is left with no language, which is honest, rather than a confident wrong one that reaches both the interface and the consolidation prompt. Set it to `0` to trust every detection.

## Memory consolidation

Set `OPENROUTER_API_KEY` to enable memory generation. `AI_DEFAULT_MODEL` defaults to `deepseek/deepseek-v4-flash-0731`, chosen because it accepts a strict JSON schema, has enough context for a bounded consolidation input, and is cheap enough for a recorder that runs continuously; any OpenRouter model that supports `response_format: json_schema` can replace it.

`NEORECALL_MIN_AI_AUDIO_MS` is the least audio that may cause an outbound request at all, and it is a hard floor rather than a heuristic: at its default of one minute, a recording of a minute or less never reaches a language model — not through consolidation, not through a live preview, and not by asking for one by hand. Character thresholds cannot make that promise, because a fast speaker clears them in forty seconds.

Because cost is per request rather than per conversation, the floor gates what may *start* a request. A short conversation is still carried along in a request that longer material already justified, where including it costs nothing extra. Set the floor to `0` to disable it.

`NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS` is the environment-enforced interval floor; a user can request a longer interval but never a shorter one. It defaults to five minutes so a finished conversation becomes a memory while it is still recent. `NEORECALL_MIN_NEW_MATERIAL_CHARS` prevents calls for trivial new material, and `NEORECALL_MAX_CONSOLIDATION_LATENCY_MS` bounds how long material may wait below that threshold before it is consolidated anyway — without it, a short conversation could stay a transcript indefinitely. Neither of those overrides the audio floor.

A consolidation retries only failures that say nothing about its input — no message content, a timeout, a transport error — bounded by `AI_MAX_RETRIES`. An answer that violates the contract is never resent unchanged, because resending reproduces it; narrowing and quarantine handle that case instead. The retry exists because measurement demanded it: against a live model, two of seven real consolidation requests failed on the first attempt for transient reasons, and without a retry each one costs a paid request and postpones every memory to the next scheduler tick. Ask uses its own `NEORECALL_ASK_MAX_PER_HOUR` database quota and minute burst limiter.

`AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` provides a hard completion budget for that one request. Conversation titles, summaries, and topic arrays are also schema-bounded, while redundant model-generated timestamps and conversation IDs are omitted and derived from cited segments on the server.

Sizing it needs measurement rather than intuition. Three hours of real council audio — 980 transcript segments, 63 116 prompt tokens — produced **24 315 completion tokens**, half again as much as a careful estimate suggested.

On a reasoning model most of that is not the answer at all. One observed call spent **12 307 of 15 979 completion tokens thinking** before writing any JSON, and reasoning length varies from call to call: an earlier attempt at the very same input ran out of budget and truncated. The budget must therefore cover reasoning *and* the answer, with real headroom rather than a tight fit. Headroom that goes unused is not charged; reasoning tokens are.

A truncated completion arrives as HTTP 200 with a body whose JSON simply stops. NeoRecall reads `finish_reason` and reports `AI_OUTPUT_TRUNCATED` rather than letting it surface as a parse error, because a parse error points at none of the things that would fix it. Truncation then narrows the next run, since the input asked for more answer than the budget allows.

Candidates are built oldest-first, so a conversation the model cannot partition would otherwise reappear in every later run. After a validation failure the next run carries a single conversation, and `NEORECALL_CONSOLIDATION_MAX_FAILURES` bounds how often one conversation may fail before it is quarantined. A quarantined conversation keeps its transcript and stays readable but no longer blocks memory generation.

## Live conversation previews

A conversation that is still being recorded gets a provisional title, summary and topics so it can be read before it ends. `AI_PREVIEW_MODEL` defaults to `AI_DEFAULT_MODEL` and `AI_PREVIEW_MAX_OUTPUT_TOKENS` bounds the completion. The default is far larger than the answer itself because reasoning models bill their internal tokens against the same limit — one observed call spent over 12 000 tokens thinking before writing a three-line answer, and a budget sized to the answer alone would truncate every preview.

Preview cost is bounded by transcript growth rather than by elapsed time: `NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS` is how much transcript the first preview needs, `NEORECALL_CONVERSATION_PREVIEW_REFRESH_CHARACTERS` how much new transcript each refresh needs, and `NEORECALL_CONVERSATION_PREVIEW_MIN_INTERVAL_MS` the minimum spacing between two previews of the same conversation. The interval is measured from the last attempt rather than the last success, so a model that cannot satisfy the contract costs one request per interval instead of one per scheduler tick.

Beyond `NEORECALL_CONVERSATION_PREVIEW_FULL_CHARACTERS` a refresh sends the previous description plus only the speech recorded since, so a conversation that runs all day costs the same per refresh instead of re-paying for its whole history. Any drift those rolling summaries accumulate is corrected when the conversation closes and consolidation reads the full transcript.

Previews never create memories; consolidation replaces the insight and marks it final when the conversation closes. A quarantined conversation is the exception: consolidation will never describe it, so previews keep it readable instead of leaving an unlabelled transcript in the timeline.

`NEORECALL_SCHEDULER_INTERVAL_MS` is how often the worker looks for work, and therefore the coarsest term in how long after crossing a threshold a result appears.

`NEORECALL_IMPORT_SESSION_CONTINUITY_MS` is how large a gap may be between two imports from one device before they stop counting as the same recording stream. It has to comfortably exceed the client's device-sync poll and its failure backoff.

## Speaker identity across chunk boundaries

Diarization runs independently on every audio chunk, so a continuous speaker
crossing a chunk boundary is re-segmented from scratch and can drift below the
plain matching threshold even though nothing about the voice changed. When the
new chunk's first speech for an audio component starts within
`NEORECALL_SPEAKER_CONTINUITY_GAP_MS` of where that component's last known
speaker turn ended, that cluster may be kept at the relaxed
`NEORECALL_SPEAKER_CLUSTER_CONTINUITY_THRESHOLD` instead of minting a new one.
This only ever breaks a near-tie: it never overrides a cluster that clearly
scores higher, so a genuine speaker change right at the boundary still resolves
on its own. It works the same regardless of `NEORECALL_CHUNK_TARGET_MS`, since
it compares actual segment timestamps rather than counting chunks.

Outside continuity, a cluster match also needs `NEORECALL_SPEAKER_CLUSTER_MARGIN`
over the runner-up, mirroring the margin cross-recording voice matching already
applies — a single fixed threshold with no margin can otherwise let a distinct
new speaker's embedding score just above it against some unrelated existing
cluster purely by chance, misattributing their speech.

Consolidation identifies people from evidence in the transcript, and when it can
tell which speaker label a person's voice belongs to — a self-introduction, or
another speaker naming them — it names that speaker's voiceprint from the same
response, at no extra AI request. It never overwrites a name set manually
through the Speakers screen, and an incorrect automatic name remains correctable
through the same rename/merge flow as any other speaker.

## Operational thresholds

The admin dashboard can safely tune boundary, deduplication, speaker matching, and consolidation material thresholds. Values are validated and stored in SQLite. Environment defaults remain the source of truth until an administrator explicitly overrides a value.

Conversation boundaries expose separate controls for hard and soft silence gaps, contextual embedding similarity and valley prominence, the number of neighboring segments used as semantic context, and maximum duration/character safety ceilings. `NEORECALL_CONVERSATION_MAXIMUM_CHARACTERS` must not exceed `NEORECALL_MAX_CONSOLIDATION_INPUT_CHARS`, ensuring one provisional conversation always fits in a bounded consolidation request.

The character ceiling is deliberately set above what `NEORECALL_CONVERSATION_MAXIMUM_MS` can produce, so duration rather than transcript length is what ends a conversation. A lower ceiling would split a long lecture or meeting into several conversations and therefore several memories purely because it ran long. Lowering it to suit a small-context model is supported, but `AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` must stay large enough for the sections and memories a full-size input justifies — a completion cut off mid-JSON is indistinguishable from a validation failure.

## Meeting cloud-recording OAuth

Meeting platforms import cloud recordings through official APIs rather than
joining live calls. An administrator registers an OAuth app with each provider
and sets:

| Variable | Purpose |
|---|---|
| `NEORECALL_PUBLIC_URL` | Public base URL used to build OAuth redirect URIs |
| `GOOGLE_MEET_OAUTH_CLIENT_ID` / `GOOGLE_MEET_OAUTH_CLIENT_SECRET` | Google Cloud OAuth client (Meet + Drive Meet scopes) |
| `ZOOM_OAUTH_CLIENT_ID` / `ZOOM_OAUTH_CLIENT_SECRET` | Zoom OAuth app with `recording:read` and `user:read` |
| `MICROSOFT_TEAMS_OAUTH_CLIENT_ID` / `MICROSOFT_TEAMS_OAUTH_CLIENT_SECRET` | Entra app for Graph meeting recordings |
| `MICROSOFT_TEAMS_OAUTH_TENANT` | Entra tenant (`common` by default) |

Register these redirect URIs with each provider:

```text
{NEORECALL_PUBLIC_URL}/api/v1/sources/oauth/google_meet/callback
{NEORECALL_PUBLIC_URL}/api/v1/sources/oauth/zoom/callback
{NEORECALL_PUBLIC_URL}/api/v1/sources/oauth/microsoft_teams/callback
```

Users connect their own accounts from the Sources screen. Tokens are stored per
user on the source row and never echoed back by the API. Platforms without
server credentials appear as unavailable in the catalog.

`NEORECALL_SPEAKER_PREVIEW_MIN_MS` and
`NEORECALL_SPEAKER_PREVIEW_MAX_MS` bound the derived clean-speaker sample.
Both are validated within the product's 5–10 second preview contract.

## NeoAgent connection

NeoAgent connects through NeoRecall's companion OAuth flow. In NeoAgent, open
**Integrations**, select **NeoRecall**, and enter this server's base URL. The
browser then returns to NeoRecall for sign-in and explicit consent.

The issued access is limited to `search:read`, `memories:read`, and
`recordings:read`. PKCE is mandatory, refresh tokens rotate on every use, and
the authorization page shows the exact NeoAgent callback URL. NeoAgent cannot
upload audio, change memories, start consolidation, or call NeoRecall Ask.

Set `NEORECALL_PUBLIC_URL` to the externally reachable HTTPS origin when
NeoRecall is behind a reverse proxy. Local HTTP URLs remain suitable when both
services run on a trusted private host.
