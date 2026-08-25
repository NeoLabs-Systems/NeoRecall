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

## External inference providers

NeoRecall does not install or run a transcription or language model. Provider settings can come from `.env` or from encrypted live overrides on the admin **Providers** page. Admin API keys are never returned to the browser, and resetting the page restores `.env` as the source of truth.

For transcription, choose `openai`, `groq`, `deepgram`, `assemblyai`, or `openai-compatible`. Set `TRANSCRIPTION_API_BASE_URL`, `TRANSCRIPTION_API_MODEL`, and the selected provider's API key. The generic OpenAI-compatible adapter accepts either a version root ending in `/v1` or the full `/audio/transcriptions` URL, sends the audio as multipart field `file`, and supports optional `TRANSCRIPTION_API_LANGUAGE` plus `TRANSCRIPTION_API_RESPONSE_FORMAT`. A model is optional for custom endpoints that route it server-side.

For generation, choose `openai`, `anthropic`, `google`, `groq`, `mistral`, `xai`, `deepseek`, `openrouter`, `together`, or `openai_compatible`. Set `AI_API_MODEL` and either the provider-specific key from `.env.example` or `AI_API_KEY`. Custom OpenAI-compatible endpoints also require `AI_API_BASE_URL`.

The admin dashboard fetches each provider's current model catalog through its API instead of shipping a fixed model list. Providers without a model-list endpoint may route automatically, and custom compatible endpoints remain manually editable if they do not implement `GET /models`.

`LLM_CONTEXT_SIZE` describes how much the configured external model can read at once. Consolidation splits longer transcripts to fit it, so raising it buys fewer and wider passes rather than deciding what can be processed at all. The embedding model used for local semantic search remains pinned and verified by `neorecall setup`; it is not a generation model.

## Memory consolidation

Processing gates are off by default and remain available when an external deployment cannot keep up or a hosted provider needs tighter request limits.

`NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS` defaults to `0`, so a conversation is consolidated on the scheduler tick after it closes. `NEORECALL_MIN_AI_AUDIO_MS` and `NEORECALL_MIN_NEW_MATERIAL_CHARS` default to `0` and `1`: a thirty-second exchange is worth describing as soon as it ends. `NEORECALL_MAX_CONSOLIDATION_LATENCY_MS` defaults to `0`, so nothing waits for a batch to fill. Raising any of them restores the old behaviour exactly — `NEORECALL_MIN_AI_AUDIO_MS` in particular is still a hard floor rather than a heuristic: at one minute, a recording of a minute or less reaches no model at all, not through consolidation, not through a live preview, and not by asking for one by hand.

`NEORECALL_MAX_CONSOLIDATION_CONVERSATIONS` defaults to `1`. Batching several conversations into one request used to amortize a per-request price; it also asked the model to hold several unrelated occasions in mind at once, which is the harder job and the one it does worse. One conversation per run is the accurate unit — it is what a memory is anchored to — and the next run starts on the next tick, so a backlog still drains continuously.

`NEORECALL_MIN_MEMORY_EVIDENCE_MS` and `NEORECALL_MIN_MEMORY_EVIDENCE_CHARS` are unchanged and are what keeps short speech off the timeline as a memory *card* (defaults: two minutes of speech **and** 400 transcript characters). Below either floor the section still receives a title and summary, but it is not memory-worthy: atomic facts and tasks belong in mini-memories under a larger worthy occasion. The consolidation prompt states the same bar; the floors enforce it when the model over-promotes short speech.

A consolidation retries only failures that say nothing about its input — no message content, a timeout, a transport error — bounded by `AI_MAX_RETRIES`. An answer that violates the contract is never resent unchanged, because resending reproduces it; narrowing and quarantine handle that case instead. Ask uses its own `NEORECALL_ASK_MAX_PER_HOUR` database quota and minute burst limiter so one client cannot overwhelm the configured provider while recordings are still arriving.

### The day's summary

The daily summary is written by its own small request once the transcript has been read, not by the pass that reads it. With windowing no single pass sees the day, so asking one to summarise it asks it to write about material it was never shown. The separate request reads only the titles and summaries of the memory-worthy sections the run produced.

Which local date that summary covers, and in which timezone, are derived from the conversations the run selected rather than read back from the model. The server already knows both, so asking the model to restate them only created a way for the answer to disagree with the evidence — and that disagreement used to fail an otherwise correct consolidation.

### Windowing a long transcript

A four-hour lecture does not fit in a typical model context, and it must still become one memory. Consolidation therefore splits the transcript into windows that each fit `LLM_CONTEXT_SIZE`, cut on segment boundaries and processed in order. Each window after the first is told what the occasion looked like when the previous window stopped and marks the section — and the memory built from it — that carries on, so the two are folded back into one. A transcript that fits is exactly one request and behaves as it always did.

`NEORECALL_CONSOLIDATION_WINDOW_CHARACTERS` is how much transcript one window carries, and it is sized against the *answer* rather than against the context. Those are different quantities, and the answer is the one that fails: a full contract for dense speech runs to roughly one output token per five input characters, so a window sized to fill a 16 384-token context — nearly thirty thousand characters — asks for several times more answer than `AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` allows and arrives truncated. The default of 8 000 characters is five to eight minutes of speech and leaves the answer a fourfold margin. Raising it lets the model see more of an occasion at once; lowering it is the first thing to try if `AI_OUTPUT_TRUNCATED` appears. It is clamped to whatever the context can hold, so it can never exceed `LLM_CONTEXT_SIZE` minus the output budget.

`AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` bounds the answer for one window and shares the context budget with the prompt, so it cannot be raised without raising `LLM_CONTEXT_SIZE` too. `NEORECALL_MAX_CONSOLIDATION_INPUT_CHARS` still bounds what one *run* may carry before windowing splits it.

### When the context runs out anyway

`LLM_CONTEXT_SIZE` is a claim about somebody else's server, so it can be wrong. Set it larger than the endpoint really allows and every request overflows — and an overflow is not a transport fault: it produces the identical rejection however many times it is sent. Treated as transient it would be retried, fail the run without narrowing or quarantining anything, re-enter the candidate set on the next scheduler tick, and repeat indefinitely without ever producing a memory.

NeoRecall therefore reads the rejection rather than only its status code. Every vendor words it differently — `context_length_exceeded`, *maximum context length is…*, *prompt is too long*, *exceeds the available context* — and any of them becomes `AI_CONTEXT_EXCEEDED`, which is sent once, never retried, and narrows the batch exactly like any other input the model could not handle. An ordinary bad request (a rejected key, a rate limit) is untouched and still retried.

The error names the two settings that fix it. Lower `LLM_CONTEXT_SIZE` to what the endpoint actually allows; that alone re-sizes every window. If the endpoint is small enough that the output budget no longer leaves room for a prompt, the server refuses to start rather than sending requests that cannot fit, and `AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` has to come down with it.

Every other path that builds a prompt is bounded the same way. Ask trims retrieved evidence to fit, dropping the weakest matches first, because search returns its results best-first and answering from slightly less evidence beats being refused. The day's summary trims the occasions it reads, which matters because a long recording produces many sections. Live previews already cut to a budget, falling back to the next refresh for whatever did not fit.

### What one request may return

The contract caps a single pass at three memories, eight mini-memories per memory and sixteen entities. Without those bounds a model handed a dense transcript can emit one mini-memory per utterance until it exhausts its token budget.

The caps bound a *window*, not an occasion. A three-hour lecture is read in many windows whose results merge, so it still accumulates as many mini-memories as it deserves while no single request grows without limit. Conversation sections are deliberately uncapped: they have to partition the whole input.

Because the caps make the largest possible answer arithmetic rather than a guess — three memories with eight mini-memories each, sixteen entities and the sections around them come to roughly five and a half thousand tokens — `AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` can be sized to cover it. Its default of 8 000 does, with margin; measured runs of a dense 8 000-character window landed between 2 400 and 3 900.

### Throughput

Provider latency depends on the selected deployment and model. `AI_REQUEST_TIMEOUT_MS` defaults to thirty minutes and `NEORECALL_JOB_LEASE_MS` matches it: the timeout has to outlast the slowest legitimate answer, and a lease shorter than the job would let a second worker start the same run while the first is still writing.

All of it is background work, but preview intervals and per-run conversation limits still determine provider load.

### When an answer does not fit the contract

NeoRecall requests structured JSON and validates every response before changing memory state. Missing fields, invented enum values, invalid references, and prose around the JSON fail validation. A completion that reaches its provider token limit is reported as `AI_OUTPUT_TRUNCATED`; both truncation and contract failures narrow the next run rather than silently dropping evidence.

Candidates are built oldest-first, so a conversation the model cannot partition would otherwise reappear in every later run. After a validation failure the next run carries a single conversation, and `NEORECALL_CONSOLIDATION_MAX_FAILURES` bounds how often one conversation may fail before it is quarantined. A quarantined conversation keeps its transcript and stays readable but no longer blocks memory generation.

## Live conversation previews

A conversation that is still being recorded gets a provisional title, summary and topics so it can be read before it ends. `AI_PREVIEW_MAX_OUTPUT_TOKENS` bounds the completion; a preview answer is three short fields, and the default model does not spend tokens thinking first.

Preview work is bounded by transcript growth rather than by elapsed time: `NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS` is how much transcript the first preview needs, `NEORECALL_CONVERSATION_PREVIEW_REFRESH_CHARACTERS` how much new transcript each refresh needs, and `NEORECALL_CONVERSATION_PREVIEW_MIN_INTERVAL_MS` the minimum spacing between two previews of the same conversation. They sit close to the scheduler tick — 300 characters, 600 characters, one minute. Raise them if the provider falls behind. The interval is measured from the last attempt rather than the last success, so a model that cannot satisfy the contract costs one request per interval instead of one per scheduler tick.

Beyond `NEORECALL_CONVERSATION_PREVIEW_FULL_CHARACTERS` a refresh sends the previous description plus only the speech recorded since, so a conversation that runs all day takes the same work per refresh instead of re-reading its whole history. A request is finally cut to what the model can read at once; when that bites, the description continues on the next refresh instead of the request failing. Any drift those rolling summaries accumulate is corrected when the conversation closes and consolidation reads the full transcript.

Previews never create memories; consolidation replaces the insight and marks it final when the conversation closes. A quarantined conversation is the exception: consolidation will never describe it, so previews keep it readable instead of leaving an unlabelled transcript in the timeline.

`NEORECALL_SCHEDULER_INTERVAL_MS` is how often the worker looks for work, and therefore the coarsest term in how long after crossing a threshold a result appears.

`NEORECALL_IMPORT_SESSION_CONTINUITY_MS` is how large a gap may be between two imports from one device before they stop counting as the same recording stream. It has to comfortably exceed the client's device-sync poll and its failure backoff.

## Speech detection and speaker identity

These two run on the audio itself, in the NeoRecall process, and they are the
only inference it still does. The reason is not size but capability: a
transcription service returns what was said, never who said it. The best it
offers is a speaker label valid inside the single request that produced it, and
since every chunk is its own request, that label cannot be carried across a chunk
boundary. A voice embedding can — it is what makes a speaker the same person in a
recording made next week.

They are cheap enough for that to be uncontroversial: a 640 KB voice-activity
detector and 31 MB of segmentation and speaker-embedding weights, against the
gigabytes recognition and generation would need. `neorecall setup` installs them
with everything else.

Speech detection earns its place twice. A chunk it finds no speech in is never
sent to the transcription service at all, so an idle microphone costs nothing —
which on a recorder running all day is most of the day. `NEORECALL_VAD_THRESHOLD`
sets that bar; raise it to send less, lower it if quiet speech is being missed.
`NEORECALL_VAD_MIN_SPEECH_SECONDS` and `NEORECALL_VAD_MIN_SILENCE_SECONDS` decide
how readily it opens and closes a span.

`NEORECALL_DIARIZATION_ENABLED=false` turns both off. Every chunk then goes to
the service, silence included, and transcripts arrive with no speaker labels.
`NEORECALL_SHERPA_THREADS` bounds the native threads; the models run per chunk on
a handful of seconds of audio, so the default of two is deliberate.

### Testing it end to end

The admin **Providers** page has a **Test end to end** button. It sends a bundled
eighteen-second sample of real two-speaker speech to the configured transcription
service, runs the local speech-detection and diarization pass over the same
sample, and makes one structured request to the language model — then reports the
three legs separately, with the words that came back.

Separately on purpose: a transcript that never arrives, a transcript with no
speakers, and a model that refuses the JSON contract need three different fixes,
and a single "failed" would hide which. The language-model leg uses the same
budget a live preview gets, so it measures the pipeline rather than a stricter
version of it. Transport failures name their cause rather than reporting
`fetch failed`, so a wrong port reads as a wrong port.

### Models that think before answering

A reasoning model bills its internal deliberation against the same output budget
as its answer, and spends it *first*. A request for a three-line preview can
therefore exhaust the budget mid-thought and return nothing usable — which arrives
looking exactly like a model that cannot follow the contract, and sends you to
rewrite prompts instead of raising a number. `AI_OUTPUT_TRUNCATED` now reports the
reasoning share when the endpoint provides it, so the cause is visible.

Two remedies. Raise `AI_PREVIEW_MAX_OUTPUT_TOKENS` and
`AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` — headroom is free, since `max_tokens` is a
ceiling rather than a target and a model that answers briefly still stops briefly.
Or switch the thinking off, usually the better trade on a small local model where
deliberating costs minutes per request. That field is not standardised, so it goes
through `AI_API_EXTRA_BODY`, a JSON object merged into every request:

```
AI_API_EXTRA_BODY={"chat_template_kwargs":{"enable_thinking":false}}
```

Qwen-family servers accept that spelling; others differ, which is why this is a
passthrough rather than a setting per vendor. It merges last, so it can override
anything NeoRecall sets.

The admin **Providers** page carries the same thing without the typing: a **Skip
the model's thinking step** checkbox that writes exactly that payload into the
**Extra request JSON** field under Advanced. The checkbox is a view of one key
rather than a separate setting — ticking it alongside JSON you wrote yourself adds
the key, and clearing it removes only that key. Saved there it is stored with the
rest of the provider settings and takes effect without a restart.

You should rarely need it, because a truncated completion rescues itself: when a
request runs out of budget mid-thought, NeoRecall retries it once with the
thinking step off. That is deliberately narrow. It happens only after a real
truncation, only once, and only when you have not set the field yourself, so a
provider that has never heard of `chat_template_kwargs` is never sent it
speculatively — and if the retry is itself rejected, the original truncation is
what gets reported, since that is the fault worth fixing.

The rescue matters most where truncation hurts most. Consolidation treats a
truncated answer as the input's fault: it narrows the batch, and after enough
failures quarantines the conversation. Without the retry, a model that always
deliberates would work through an entire backlog that way, quarantining
recordings that were never the problem.

### How a transcript gets a speaker

The local pass and the service work on the same seconds of audio and meet on the
same timeline. Diarization produces speaker turns with an embedding each; the
service returns timestamped text for the whole chunk; every segment takes the
turn it overlaps most, and that turn's embedding with it. A segment with a second
voice talking across more than a fifth of it is marked as overlapping rather than
quietly credited to one person.

A voice is fingerprinted from everything it said in the chunk, weighted by how
long each turn lasted — not from a single turn. That matters more than any
threshold. Measured against two known-different voices: with one second of speech
per fingerprint the same voice scored anywhere from 0.20 to 0.87 while two
different voices reached 0.77, so the two populations are indistinguishable. With
two seconds they separate cleanly — the same voice never below 0.55, different
voices never above 0.50. `NEORECALL_SPEAKER_CLUSTER_THRESHOLD` sits at 0.52,
inside that gap, and `NEORECALL_SPEAKER_MINIMUM_TURN_MS` refuses to found a new
speaker on less than two seconds of pooled speech. Below that bar a turn may still
join a voice that already exists; it cannot invent one, so a half-second of noise
never becomes a person.

A match needs `NEORECALL_SPEAKER_CLUSTER_MARGIN` over the runner-up only when that
runner-up is itself *below* the threshold — the case the margin exists for, where a
new speaker grazes the bar against an unrelated cluster and both readings are
equally weak. When two clusters both match strongly they are not an ambiguity to
refuse but one person split earlier, so the best match wins and the two are merged
if their centroids are at least `NEORECALL_SPEAKER_CLUSTER_MERGE_THRESHOLD` alike.
Refusing both used to mint a third copy, which made the next turn more ambiguous
still — a loop that could turn one familiar voice into a dozen entries.

Diarization restarts on every chunk, so a speaker crossing a boundary can drift
below the plain threshold with nothing about the voice having changed: when a
component's first speech begins within `NEORECALL_SPEAKER_CONTINUITY_GAP_MS` of
where its last known turn ended, that cluster may be kept at the relaxed
`NEORECALL_SPEAKER_CLUSTER_CONTINUITY_THRESHOLD`. That only ever breaks a near-tie,
so a genuine speaker change at the boundary still resolves on its own.

If one person still appears as several, lower `NEORECALL_SPEAKER_CLUSTER_THRESHOLD`;
if different people are being merged, raise it. Note that
`NEORECALL_DIARIZATION_CLUSTER_DISTANCE`, which groups voices *inside* a chunk,
points the other way — it is a distance, so raising it yields fewer speakers. They
were one setting until they were found to be pulling in opposite directions.

Consolidation then identifies people from the transcript — a self-introduction,
or another speaker naming them — and names that speaker's voiceprint from the
same response, at no extra request. It never overwrites a name set by hand.

### When it is unavailable

The native runtime ships prebuilt binaries for the common platforms and is an
optional dependency, so an install on a platform it does not cover has no audio
models. That is survivable and deliberately not fatal: chunks are transcribed
exactly as before and segments simply carry no speaker. The server reports this
as `speakerIdentityAvailable`, `/ready` still passes, and the clients show the
speaker settings switched off with the reason rather than offering choices that
would change nothing.

## Operational thresholds

The admin dashboard can safely tune boundary, deduplication, speaker matching, and consolidation material thresholds. Values are validated and stored in SQLite. Environment defaults remain the source of truth until an administrator explicitly overrides a value.

Conversation boundaries expose separate controls for hard and soft silence gaps, contextual embedding similarity and valley prominence, the number of neighboring segments used as semantic context, and maximum duration/character safety ceilings. `NEORECALL_CONVERSATION_MAXIMUM_CHARACTERS` must not exceed `NEORECALL_MAX_CONSOLIDATION_INPUT_CHARS`, ensuring one provisional conversation always fits in a bounded consolidation request.

The character ceiling is deliberately set above what `NEORECALL_CONVERSATION_MAXIMUM_MS` can produce, so duration rather than transcript length is what ends a conversation. A lower ceiling would split a long lecture or meeting into several conversations and therefore several memories purely because it ran long. Lowering it to suit a small-context model is supported, but `AI_CONSOLIDATION_MAX_OUTPUT_TOKENS` must stay large enough for the sections and memories a full-size input justifies — a completion cut off mid-JSON is indistinguishable from a validation failure.

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
