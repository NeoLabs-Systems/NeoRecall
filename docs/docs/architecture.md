---
sidebar_position: 1
title: Architecture
---

# Architecture

NeoRecall is a single-host Express and SQLite service with separate HTTP, worker-manager, and persistent inference-host processes. Flutter clients support web, macOS, and Windows.

```text
Flutter durable ledger
  -> idempotent chunk ingest
  -> SQLite job lease
  -> configured external transcription endpoint
  -> FULL transcript transaction
  -> temporary audio unlink
  -> terminal receipt/outbox event
  -> local embeddings and boundaries
  -> provisional external-model preview while a conversation is still open
  -> final external-model consolidation once a conversation closes
```

Nothing in that chain waits for a recording to end. Chunks upload during capture,
each one is transcribed as it arrives, and boundary detection reruns on every
terminal chunk, so a device can record continuously and still produce results
minutes behind the microphone.

Every native or browser ledger session carries its owning NeoRecall user ID.
The upload pump only reads sessions and chunks for the account bound to the
current authenticated token. Device identifiers are also generated per
account, so signing into another account on the same physical client cannot
redirect queued audio.

## Process boundaries

`server/supervisor.js` owns the HTTP and worker-manager processes. The worker manager renews SQLite leases and heartbeats while `inference_host.js` isolates outbound transcription requests. It periodically re-reads provider configuration so admin changes become active without leasing audio work before a provider is ready.

Routes contain HTTP translation only. Business logic lives in `server/services`, inference adapters in `server/transcription`, and all SQL is parameterized through `better-sqlite3`. Numbered migrations run before serving traffic.

Source processing is sequence-ordered. A missing sequence blocks later inference unless an explicit capture-gap record covers that sequence; sync-state responses distinguish declared loss from audio that still needs upload.

Job selection is strict priority, and transcription outranks everything it feeds. While a large synced backlog drains, the search index and conversation detection therefore lag behind the transcript rather than keeping pace with it. Ordering the work this way is what keeps a single source's chunks in sequence and avoids re-running boundary detection hundreds of times over a growing segment set; the cost is that a device syncing hours of stored audio surfaces its memories at the end of the drain rather than during it.

Multiple devices under one account declare independent device, session, source,
and sequence identities. A failed declaration blocks only that session's chunk
uploads; other devices continue synchronizing.

## Client process lifetime

Android uses a process-owned Flutter engine plus a visible foreground service.
The engine owns capture, durable chunk writes, Bluetooth reconnect, device
storage sync, and upload, so dismissing the Activity does not detach those
components. A durable capture intent creates a new interrupted/recovered session
after process recreation.

The host is claimed through *background holds* rather than a single capture
mode. `microphoneCapture` and `wearableCapture` cover live audio,
`wearableLink` keeps a paired wearable connected while nothing is recording, and
`wearableSync` is taken only for the duration of a transfer off a device. The
service derives its foreground service types from the union of active holds
(microphone, connectedDevice) and holds a wake lock only for holds whose work
the CPU sleeping would stretch — never for an idle link. Any combination is
therefore one service and one notification, and a paired wearable keeps
reconnect, on-device sync, and upload running with the app swiped away.

The notification Stop action releases every hold — capture ends, the wearable is
unlinked, the host stops — after final chunk and session persistence. Opening
the app re-arms it.

`BOOT_COMPLETED` restores only holds that may legally start from the
background. Android denies microphone access to a process with no UI, so a
microphone capture intent is preserved and reported instead of resumed; wearable
holds are restored, so device recordings still sync after a restart.

iOS background audio and Bluetooth modes can keep an authorized active session
alive while the app is backgrounded, but iOS does not permit an app to continue
or relaunch after the user force-quits it. NeoRecall does not represent that OS
restriction as a recoverable guarantee.

## Device storage sync

Wearables that record on their own give no signal when a new file appears, so
every client polls on a short interval and drains through the same durable
import pipeline; nothing is deleted from a device before its import is accepted.

Because that poll is short, one conversation arrives as many files. Consecutive
drains from the same device therefore extend the previous import session as a new
source rather than starting a new session: a session is one recording stream and
conversations are detected inside it, while nothing downstream may merge across
streams. Without that, an hour-long meeting recorded to on-board storage would
become one conversation — and one memory — per sync sweep. A device that
timestamps its files is placed by those timestamps; one that does not is assumed
to continue where the previous sweep ended, which is what a drained ring buffer
is. A gap longer than the configured continuity window starts a fresh stream.
One scheduler owns that timing on all platforms, web included, so the periodic
poll, the reconnect trigger, the app-resumed trigger, and the manual button
share a single policy. Repeated failures back off instead of hammering a device
that is out of range or busy, and an unattended poll stays silent — it reports
only when it transfers something or keeps failing.

## Live capture sources

Discord voice uses a **live notetaker bot** that joins while people are present
and streams audio into the ordinary ingest pipeline.

- **Discord** — each user pastes their own bot token and trigger usernames.
  When a listed person joins a voice channel, the bot joins and records every
  speaker until they leave.

Plaud Note Pro and NotePin S pair as wearables on iOS and Android through Plaud
Embedded: the phone binds the pin over BLE, drains finished files, and runs them
through the ordinary ingest pipeline. Handshake tokens are minted on the
NeoRecall server; audio is not uploaded to Plaud. Binding a device unbinds the
consumer Plaud app. Desktop and the browser cannot complete Plaud's encrypted
handshake — there is no Plaud SDK for those platforms.

## Processing pipeline

Each independently decodable audio chunk is first read locally. A 640 KB
voice-activity detector decides whether it contains speech at all — if it does
not, the chunk is silence, no request is made, and the receipt is terminal
without anything leaving the machine. When there is speech, a diarization model
and a speaker-embedding model produce speaker turns with a voice fingerprint
each.

The chunk is then sent unchanged to the configured transcription service.
OpenAI-compatible endpoints receive multipart form data with a `file` field plus
the configured `model`, `language`, and `response_format` fields; native Deepgram
and AssemblyAI adapters normalize their responses into the same timestamped
transcript-segment contract. Because both passes describe the same chunk on the
same timeline, each returned segment is joined to the speaker turn it overlaps
most and inherits that turn's embedding.

That split is deliberate and is drawn by capability rather than by size. Speech
recognition and language generation are gigabytes and are exactly what an
external service does well, so NeoRecall installs and runs neither. Speech
detection and diarization are 31 MB and produce the one thing no service returns:
a voice fingerprint, which is what identifies the same person in a recording made
weeks later. The native runtime for them is an optional dependency — where it is
unavailable, transcripts arrive without speaker labels rather than not at all.

The normalized segments are deduplicated by time and multilingual token
similarity, then persisted in one transaction. Audio deletion remains strictly
after transcript persistence: a failed provider request cannot produce a
terminal receipt, and a client must retain its local audio until that receipt
also proves server-side unlink.

Provisional boundary detection is time-driven: hard and soft silence gaps split a
stream into conversations, and configurable duration and character ceilings
prevent an uninterrupted 24/7 stream from creating an unbounded model input.
Short fragments join their semantically closest neighbor.

An embedding-valley path exists alongside the gaps but is conservative by
design, and on real continuous speech it effectively never fires: measured over
three hours of a real meeting, no adjacent-segment similarity came within 0.2 of
the shipping threshold, and the deepest valleys sat mid-sentence — the signal
tracks VAD fragmentation, not topic shifts. Do not tune the threshold up to
"activate" it; that splits sentences, not topics. Topic-level splitting is the
refinement model's job: consolidation may split or merge provisional
conversations with full transcript context, which is where within-stream topic
boundaries actually come from.

## Conversation lifecycle

A conversation is the unit of both display and memory, and it has two states a
model may write to.

While it is still growing it is *open*, and boundary detection reruns over it
whenever new speech lands. Rerunning never mints a new identity: the group that
still contains the conversation's earliest segment keeps its id, so a client
reference and a live insight survive a recording that runs for hours. An open
conversation receives *provisional* insight — a title, a summary and topics
describing the transcript so far — so a user can look into a conversation before
it ends. A provisional pass creates no memories: anchoring durable memories to a
transcript that is still growing would only produce duplicates the final pass has
to undo.

Once the conversation is quiet long enough it is *closed*, and consolidation
produces the authoritative result: refined boundaries, a final insight that
replaces whatever the preview wrote, and the memories. One real-world occasion
therefore yields exactly one memory however long it ran, while a device left
recording all day yields one memory per occasion it captured.

Preview work is bounded by transcript growth rather than elapsed time — a first
preview needs a minimum amount of transcript, each refresh needs a minimum amount
of *new* transcript, and two previews of one conversation stay a minimum interval
apart — so an uninterrupted stream cannot occupy the model without producing
anything new.

## Generation

Language-model requests always go to the configured external provider. The
provider may be a hosted API or a compatible service the operator deployed on a
different machine. NeoRecall stores request state and validates responses, but
does not install, load, or execute generation weights.

Every request asks for structured JSON, and the returned value is checked
against the same server-owned schema before it can change durable state. Prose
around the JSON, a missing field, and an invented enum value are caught after
generation. Length bounds on prose and date patterns have no grammar form and are
still checked afterwards: an over-long field is trimmed, an invalid date rejected.

A model context holds a fixed number of tokens, and a four-hour lecture does not
fit in one. Consolidation therefore reads a long transcript in windows cut on
segment boundaries and processed in order, each window told what the occasion
looked like when the previous one stopped. The model marks the section — and the
memory built from it — that carries on, and the windows are folded back into one
answer, so a long occasion still yields exactly one section and one memory. A
transcript that fits is a single request and behaves as it always did. A prompt
that cannot fit at all is refused before generation rather than silently losing
the beginning of the transcript to a context shift.

## Memory scheduling

The gates that ration outbound requests are configurable. A conversation is
consolidated on the scheduler tick after it closes and one conversation is read
per run — the unit a memory is anchored to — rather than batching unrelated
conversations. Operators can raise the time, evidence, or audio floors to
control request volume and provider cost; the audio floor remains a hard gate
that no path can bypass.

A consolidation is eligible only after the effective interval, sufficient complete
material, and an available model. The per-user SQLite gate survives restarts.

Consolidation candidates are ordered oldest-first, which makes an unpartitionable conversation a hazard in permanent operation: it would re-enter every later run and stop memory generation for good. A validation failure therefore narrows the next run to a single conversation, and a conversation that keeps failing is quarantined — still readable, no longer a candidate. One structured response per window refines provisional boundaries, writes a title and summary for every final conversation, and creates English episodic memories, atomic mini-memories, entities and importance values; the model may split a long provisional conversation or merge adjacent provisional conversations from the same recording stream. The incremental daily summary is a separate small request made afterwards, because no single window sees the day, and the local date it covers is derived from the evidence rather than read back from the model.

One pass may only return a bounded answer — four memories, eight mini-memories each, sixteen entities. Without those limits a model handed a dense transcript can emit one mini-memory per utterance until its token budget runs out, which arrives as truncation. The bounds apply per window, so a long occasion still accumulates evidence across its windows while no single request grows without limit.

Refinement is evidence-addressed and transactional. The model must partition every input segment exactly once into chronological, contiguous, single-stream sections. Server-side validation rejects missing, duplicated, reordered, invented, or cross-device segment references before any conversation is changed. Segment membership, conversation speakers, summaries, topics, memories, and source links then commit together or roll back together.

A validation failure records the specific reason it failed, not only a code, so a real occurrence is diagnosable from its stored row instead of requiring the same minutes of generation again just to see the answer. A worker process that dies mid-run — a crash, an out-of-memory kill, a deploy — leaves a run marked `running` with nothing left alive to fail it; a periodic sweep reconciles any such run past a bounded age, so one interrupted process cannot permanently block a user's memory generation. That reconciliation is deliberately excluded from the narrowing and quarantine policy: a crash says nothing about whether the input itself was consolidatable.

## Search

Every search runs Unicode FTS5 BM25 and multilingual-e5-small sqlite-vec KNN. Reciprocal Rank Fusion combines them. Memories add configurable relevance, exponential recency, and importance terms; transcript evidence remains relevance-first. Ask is a separate, rate-limited retrieval-augmented request to the configured external language model, with result citations.

## NeoAgent boundary

NeoAgent is an OAuth client of NeoRecall, not another processing worker. It
receives seven read-only tools for on-demand local search and evidence access.
Ingest, settings, memory mutation, consolidation orchestration, and Ask remain
inside NeoRecall; only the explicitly configured inference endpoints receive
audio or transcript text. This avoids duplicated memory stores and prevents an
otherwise unnecessary second round of generation.
