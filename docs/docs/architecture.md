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
  -> inference host (VAD, ASR, diarization)
  -> FULL transcript transaction
  -> optional clean speaker-preview derivation
  -> temporary audio unlink
  -> terminal receipt/outbox event
  -> local embeddings and boundaries
  -> provisional OpenRouter preview while a conversation is still open
  -> final OpenRouter consolidation once a conversation closes
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

`server/supervisor.js` owns the HTTP and worker-manager processes. The worker manager renews SQLite leases and heartbeats while `inference_host.js` owns synchronous sherpa native models. Speech inference defaults to one concurrent job per host so multi-gigabyte models are loaded once and CPU pressure stays predictable.

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

## Meeting sources

A meeting link is recorded by a bot that joins the call in a real browser and
taps the WebRTC audio streams, feeding the same ingest pipeline as any other
source. Nothing is injected into the page before the bot is admitted, so the
join is fingerprinted on a clean page.

Joining as an anonymous guest is the exception, not the rule: Google Meet, Zoom
and Teams all refuse guests whenever the host restricts a meeting, and no amount
of browser tuning changes that. The bot therefore joins as a signed-in
participant, connected once per user rather than configured per meeting.

That connection step cannot assume anyone has access to the machine NeoRecall
runs on — in a real deployment (Docker, a remote box) nobody does. So the
browser that renders the sign-in page runs headless and isolated per user on
the server, and is never displayed there: its screen is streamed live to the
user's own browser tab over a WebSocket (`signin_relay.js`, CDP
`Page.startScreencast`), and the user's clicks and keystrokes are relayed back
the same way (`Input.dispatch*`). The user is, in effect, looking at and typing
into their own private browser window the entire time — it just happens to be
rendered on the server and piped through their device rather than opened as a
window on it. The WebSocket is authorized by a one-time ticket minted by an
already-authenticated REST call, since a browser `WebSocket` cannot carry a
bearer token itself; the ticket is single-use and expires in a minute, so a
leaked URL is worthless shortly after. NeoRecall never receives the password as
text — it is typed into the provider's real page inside that stream — and keeps
only the resulting browser profile under `meeting_profiles/` in the runtime
home, read afterward for cookie names and hosts only. No per-service API key or
OAuth application is involved.

Every actual meeting join gets a throwaway clone of that profile, so concurrent
meetings cannot fight over Chrome's single-instance lock and a crashed bot
cannot damage the signed-in original. A refused join reports which of two
situations it was — an anonymous bot the meeting will not accept, or a
signed-in account that was not invited — because the fixes are different.

## Processing pipeline

Each logical audio channel is decoded to 16 kHz mono PCM. Silero VAD removes silence, Parakeet generates timestamped multilingual text, pyannote segmentation identifies speaker turns, and WeSpeaker embeddings support local clusters and optional cross-recording identities. Before source deletion, clean non-overlapping turns can be combined into a bounded 16 kHz mono preview for that recurring speaker. Time-constrained token alignment removes overlap and cross-channel leakage without phrase lists.

Diarization runs independently per chunk, so a session-scoped speaker cluster is the only thing carrying voice identity across chunk boundaries, and it does so by embedding similarity alone: the resolver keeps the cluster active at the end of the previous chunk for the same audio component when the new speech starts soon enough after it and still resembles that cluster reasonably well, but never when some other cluster clearly matches better — so continuity narrows fragmentation and cross-attribution without ever forcing a boundary-adjacent segment onto whoever spoke last. Outside that continuity case, a cluster match additionally needs a margin over its runner-up, the same discipline cross-recording voice matching already applies, closing the case where a fixed threshold alone would let a distinct speaker's embedding pass for an unrelated existing cluster by chance.

Consolidation's person entities can carry the speaker label the transcript identifies them by (a self-introduction, or being named by another speaker); when present, that link names the corresponding voiceprint directly from the consolidation response already made, giving automatic speaker naming with no dedicated model call. A name set this way never overrides one the user set manually, and is corrected the same way any speaker name is.

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

Preview cost is bounded by transcript growth rather than elapsed time — a first
preview needs a minimum amount of transcript, each refresh needs a minimum amount
of *new* transcript, and two previews of one conversation stay a minimum interval
apart — so an uninterrupted stream cannot spend without producing anything new.

## Memory and token budget

No amount of recorded audio below a configured floor may cause an outbound
request. The floor is checked before every other gate, so neither the live
preview, nor the waiting-material sweep, nor an explicit request by hand can
send a one-minute recording to a model. It bounds what may *start* a request
rather than what a request may contain: a short conversation is still carried
along in a request that longer material already justified, because cost is per
request and including it there is free.

The SQLite budget gate is per user and survives restarts. A consolidation is eligible only after the effective interval, sufficient complete material, and OpenRouter configuration. Material that stays under the character threshold is consolidated anyway once it has waited past a configured latency bound, so a short conversation cannot be stranded as a transcript with no memory.

Consolidation candidates are ordered oldest-first, which makes an unpartitionable conversation a hazard in permanent operation: it would re-enter every later run and stop memory generation for good. A validation failure therefore narrows the next run to a single conversation, and a conversation that keeps failing is quarantined — still readable, no longer a candidate. The same single structured response refines provisional boundaries, writes a title and summary for every final conversation, and creates English episodic memories, atomic mini-memories, entities, importance values, and an incremental daily summary. The model may split a long provisional conversation or merge adjacent provisional conversations from the same recording stream.

Refinement is evidence-addressed and transactional. The model must partition every input segment exactly once into chronological, contiguous, single-stream sections. Server-side validation rejects missing, duplicated, reordered, invented, or cross-device segment references before any conversation is changed. Segment membership, conversation speakers, summaries, topics, memories, and source links then commit together or roll back together.

A validation failure records the specific reason it failed, not only a code, so a real occurrence is diagnosable from its stored row instead of requiring a fresh paid request to see the same answer again. A worker process that dies mid-run — a crash, an out-of-memory kill, a deploy — leaves a run marked `running` with nothing left alive to fail it; a periodic sweep reconciles any such run past a bounded age, so one interrupted process cannot permanently block a user's memory generation. That reconciliation is deliberately excluded from the narrowing and quarantine policy: a crash says nothing about whether the input itself was consolidatable.

## Search

Every search runs Unicode FTS5 BM25 and multilingual-e5-small sqlite-vec KNN. Reciprocal Rank Fusion combines them. Memories add configurable relevance, exponential recency, and importance terms; transcript evidence remains relevance-first. Ask is a separate, rate-limited retrieval-augmented OpenRouter request with result citations.

## NeoAgent boundary

NeoAgent is an OAuth client of NeoRecall, not another processing worker. It
receives seven read-only tools for on-demand local search and evidence access.
Audio, voice embeddings, ingest, settings, memory mutation, consolidation, and
Ask remain inside NeoRecall. This avoids duplicated memory stores and prevents
an otherwise unnecessary second OpenRouter request.
