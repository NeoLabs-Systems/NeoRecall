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

`TRANSCRIPTION_PROVIDER=sherpa` (the default) selects the native CPU pipeline, running Whisper large-v3 fully on-device through `sherpa-onnx`. `NEORECALL_SHERPA_THREADS` controls native inference threads. An OpenAI-compatible transcription endpoint can be selected with `TRANSCRIPTION_PROVIDER=openai-compatible`, `TRANSCRIPTION_API_BASE_URL`, and an optional key; this is separate from the language model and is intended for self-hosted or remote speech servers, and defaults to requesting `whisper-large-v3` unless `TRANSCRIPTION_API_MODEL` overrides it.

The embedding model must produce exactly 384 dimensions. `neorecall install` downloads and verifies every local model, including the ASR model, with no manual step; `neorecall setup` re-runs the same download/verify pass on demand (for example after switching release channel). Model files and their revisions are pinned in `models/manifest.json`.

When the recogniser does not label a segment's language itself, a statistical detector fills in — but only above `NEORECALL_LANGUAGE_DETECTION_MIN_CHARACTERS`. Below it there is not enough text to decide, and the detector answers anyway: three hours of real council audio produced "Gentlemen." labelled Afrikaans and "Uh" labelled Klingon. A segment shorter than the threshold is left with no language, which is honest, rather than a confident wrong one that reaches both the interface and the consolidation prompt. Set it to `0` to trust every detection.

## The language model

`AI_PROVIDER=llama` is the default and runs the model inside the NeoRecall process through llama.cpp. Nothing about a request leaves the machine, there is no account and no key, and `neorecall setup` downloads the weights alongside the speech models. The default is Gemma 4 E4B Instruct at q4_0 — about 5.2 GB on disk, pinned by revision and SHA-256 in `models/manifest.json`, and replaceable with `LLM_MODEL_FILE` (inside the managed models directory) or `LLM_MODEL_PATH` (anywhere on disk). It is the quantization-aware trained build, so the 4-bit weights were trained at 4 bits rather than rounded down afterwards and lose little against the full-precision model.

`LLM_GPU_LAYERS` defaults to `auto`, which offloads as many layers as the detected Metal, CUDA or Vulkan device has memory for and runs on the CPU when there is none — one default that works on a laptop and on a headless box with a GPU. `LLM_THREADS=0` lets llama.cpp choose a thread count. `LLM_TEMPERATURE` defaults to `0.2`: this is structured extraction, not prose, and near-greedy decoding keeps the model on the evidence.

`LLM_CONTEXT_SIZE` is how much the model may hold at once, in tokens, and it is the single number that decides how much memory it needs beyond its weights. The default of 16 384 keeps the key–value cache of a 4B model well under a gigabyte. Consolidation splits longer transcripts to fit it, so raising it buys fewer and wider passes rather than deciding what can be processed at all.

`LLM_IDLE_UNLOAD_MS` is how long the weights stay resident after the last request. The scheduler produces work in bursts, so holding the model briefly turns a burst into one load instead of one load per job, while an idle recorder gives the memory back.

### Sending generation elsewhere

`AI_PROVIDER=openai_compatible` sends the same requests to an endpoint you choose: another machine on the LAN with a GPU, an Ollama or llama-server instance you already run, or a hosted service. Set `AI_API_BASE_URL`, `AI_API_MODEL` and, if the endpoint requires one, `AI_API_KEY`. Whether that endpoint is private is your decision, which is why the local provider is the default and this has to be configured deliberately. `LLM_CONTEXT_SIZE` still describes how much the endpoint can read at once, and windowing still respects it.

## Memory consolidation

Because generation costs seconds of your own machine rather than money, the gates that used to ration it are off by default and remain available for a machine that cannot keep up with its own recordings.

`NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS` defaults to `0`, so a conversation is consolidated on the scheduler tick after it closes. `NEORECALL_MIN_AI_AUDIO_MS` and `NEORECALL_MIN_NEW_MATERIAL_CHARS` default to `0` and `1`: a thirty-second exchange is worth describing as soon as it ends. `NEORECALL_MAX_CONSOLIDATION_LATENCY_MS` defaults to `0`, so nothing waits for a batch to fill. Raising any of them restores the old behaviour exactly — `NEORECALL_MIN_AI_AUDIO_MS` in particular is still a hard floor rather than a heuristic: at one minute, a recording of a minute or less reaches no model at all, not through consolidation, not through a live preview, and not by asking for one by hand.

`NEORECALL_MAX_CONSOLIDATION_CONVERSATIONS` defaults to `1`. Batching several conversations into one request used to amortize a per-request price; it also asked the model to hold several unrelated occasions in mind at once, which is the harder job and the one it does worse. One conversation per run is the accurate unit — it is what a memory is anchored to — and the next run starts on the next tick, so a backlog still drains continuously.

`NEORECALL_MIN_MEMORY_EVIDENCE_MS` and `NEORECALL_MIN_MEMORY_EVIDENCE_CHARS` are unchanged and are what keeps short speech off the timeline as a memory *card* (defaults: two minutes of speech **and** 400 transcript characters). Below either floor the section still receives a title and summary, but it is not memory-worthy: atomic facts and tasks belong in mini-memories under a larger worthy occasion. The consolidation prompt states the same bar; the floors enforce it when the model over-promotes short speech.

A consolidation retries only failures that say nothing about its input — no message content, a timeout, a transport error — bounded by `AI_MAX_RETRIES`. An answer that violates the contract is never resent unchanged, because resending reproduces it; narrowing and quarantine handle that case instead. Ask uses its own `NEORECALL_ASK_MAX_PER_HOUR` database quota and minute burst limiter; those limits no longer protect a bill, they keep one client from queueing more generation than the machine can work through while recordings are still arriving.

### Windowing a long transcript

A four-hour lecture does not fit in any local context, and it must still become one memory. Consolidation therefore splits the transcript into windows that each fit `LLM_CONTEXT_SIZE`, cut on segment boundaries and processed in order. Each window after the first is told what the occasion looked like when the previous window stopped and marks the section — and the memory built from it — that carries on, so the two are folded back into one. A transcript that fits is exactly one request and behaves as it always did.

`NEORECALL_CONSOLIDATION_WINDOW_CHARACTERS` is how much transcript one window carries, and it is sized against the *answer* rather than against the context. Those are different quantities, and the answer is the one that fails: a full contract for dense speech runs to roughly one output token per five input characters, so a window sized to fill a 16 384-token context — nearly thirty thousand characters — asks for several times more answer than `AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` allows and arrives truncated. The default of 8 000 characters is five to eight minutes of speech and leaves the answer a fourfold margin. Raising it lets the model see more of an occasion at once; lowering it is the first thing to try if `AI_OUTPUT_TRUNCATED` appears. It is clamped to whatever the context can hold, so it can never exceed `LLM_CONTEXT_SIZE` minus the output budget.

`AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` bounds the answer for one window and shares the context budget with the prompt, so it cannot be raised without raising `LLM_CONTEXT_SIZE` too. `NEORECALL_MAX_CONSOLIDATION_INPUT_CHARS` still bounds what one *run* may carry before windowing splits it.

### When an answer does not fit the contract

The local provider compiles each JSON contract into a sampling grammar, so the model is only ever allowed to emit tokens that keep the answer valid. Missing fields, invented enum values and prose around the JSON are structurally impossible rather than validated after the fact. Two things a grammar cannot express are checked afterwards: a length bound on prose, which is trimmed with an ellipsis rather than rejected, and a date pattern, which is validated.

What remains is a completion that runs out of budget, reported as `AI_OUTPUT_TRUNCATED`, and a request whose prompt does not fit the context at all, reported as `AI_CONTEXT_EXCEEDED` *before* generation starts — llama.cpp would otherwise begin discarding the start of the transcript to make room, and losing evidence silently is worse than refusing. Both narrow the next run.

Candidates are built oldest-first, so a conversation the model cannot partition would otherwise reappear in every later run. After a validation failure the next run carries a single conversation, and `NEORECALL_CONSOLIDATION_MAX_FAILURES` bounds how often one conversation may fail before it is quarantined. A quarantined conversation keeps its transcript and stays readable but no longer blocks memory generation.

## Live conversation previews

A conversation that is still being recorded gets a provisional title, summary and topics so it can be read before it ends. `AI_PREVIEW_MAX_OUTPUT_TOKENS` bounds the completion; a preview answer is three short fields, and the default model does not spend tokens thinking first.

Preview work is bounded by transcript growth rather than by elapsed time: `NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS` is how much transcript the first preview needs, `NEORECALL_CONVERSATION_PREVIEW_REFRESH_CHARACTERS` how much new transcript each refresh needs, and `NEORECALL_CONVERSATION_PREVIEW_MIN_INTERVAL_MS` the minimum spacing between two previews of the same conversation. They now sit close to the scheduler tick — 300 characters, 600 characters, one minute — because a description that is a minute old is the thing worth avoiding when the model is your own CPU. Raise them if the machine falls behind. The interval is measured from the last attempt rather than the last success, so a model that cannot satisfy the contract costs one request per interval instead of one per scheduler tick.

Beyond `NEORECALL_CONVERSATION_PREVIEW_FULL_CHARACTERS` a refresh sends the previous description plus only the speech recorded since, so a conversation that runs all day takes the same work per refresh instead of re-reading its whole history. A request is finally cut to what the model can read at once; when that bites, the description continues on the next refresh instead of the request failing. Any drift those rolling summaries accumulate is corrected when the conversation closes and consolidation reads the full transcript.

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

## Live meeting bot

Meet / Zoom / Teams joins use Playwright + Chrome on the NeoRecall host. Users
configure everything from the Sources screen (meeting link + optional account
sign-in); no admin OAuth client registration is required.

| Variable | Purpose |
|---|---|
| `NEORECALL_MEETING_JOIN_TIMEOUT_MS` | How long the bot may wait in the lobby before giving up (default 5 minutes) |
| `NEORECALL_MEETING_LEAVE_GRACE_MS` | Quiet period after the call ends before tearing down capture (default 30 seconds) |
| `NEORECALL_MEETING_SIGNIN_IDLE_TIMEOUT_MS` | Idle timeout for the live per-user account sign-in relay (default 10 minutes) |

Install Chrome for Playwright (`npx playwright install chrome`) so Google Meet
joins are reliable; Chromium is used as a fallback.

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
