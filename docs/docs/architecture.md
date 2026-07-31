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
  -> hourly OpenRouter consolidation when eligible
```

Every native or browser ledger session carries its owning NeoRecall user ID.
The upload pump only reads sessions and chunks for the account bound to the
current authenticated token. Device identifiers are also generated per
account, so signing into another account on the same physical client cannot
redirect queued audio.

## Process boundaries

`server/supervisor.js` owns the HTTP and worker-manager processes. The worker manager renews SQLite leases and heartbeats while `inference_host.js` owns synchronous sherpa native models. Speech inference defaults to one concurrent job per host so multi-gigabyte models are loaded once and CPU pressure stays predictable.

Routes contain HTTP translation only. Business logic lives in `server/services`, inference adapters in `server/transcription`, and all SQL is parameterized through `better-sqlite3`. Numbered migrations run before serving traffic.

Source processing is sequence-ordered. A missing sequence blocks later inference unless an explicit capture-gap record covers that sequence; sync-state responses distinguish declared loss from audio that still needs upload.

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
participant. The user signs in once, by hand, in an ordinary Chrome window that
the server opens on its own machine — deliberately *not* an automated browser,
because providers block sign-in in one they can see is driven. NeoRecall never
receives the password; it keeps only the browser profile Chrome writes, under
`meeting_profiles/` in the runtime home, and reads it for cookie names and hosts
only. No per-service API key or OAuth application is involved.

Every join gets a throwaway clone of that profile, so concurrent meetings cannot
fight over Chrome's single-instance lock and a crashed bot cannot damage the
signed-in original. A refused join reports which of the two situations it was —
an anonymous bot the meeting will not accept, or a signed-in account that was
not invited — because the fixes are different.

## Processing pipeline

Each logical audio channel is decoded to 16 kHz mono PCM. Silero VAD removes silence, Parakeet generates timestamped multilingual text, pyannote segmentation identifies speaker turns, and WeSpeaker embeddings support local clusters and optional cross-recording identities. Before source deletion, clean non-overlapping turns can be combined into a bounded 16 kHz mono preview for that recurring speaker. Time-constrained token alignment removes overlap and cross-channel leakage without phrase lists.

Boundary detection is hybrid. The continuous, token-free path uses hard and soft time gaps plus contextual embedding valleys to create provisional conversations without relying on keywords or speaker changes. Configurable duration and character ceilings prevent an uninterrupted 24/7 stream from creating an unbounded model input. Short fragments join their semantically closest neighbor.

## Memory and token budget

The SQLite budget gate is per user and survives restarts. A consolidation is eligible only after the effective interval, sufficient complete material, and OpenRouter configuration. The same single structured response refines provisional boundaries, writes a title and summary for every final conversation, and creates English episodic memories, atomic mini-memories, entities, importance values, and an incremental daily summary. The model may split a long provisional conversation or merge adjacent provisional conversations from the same recording stream.

Refinement is evidence-addressed and transactional. The model must partition every input segment exactly once into chronological, contiguous, single-stream sections. Server-side validation rejects missing, duplicated, reordered, invented, or cross-device segment references before any conversation is changed. Segment membership, conversation speakers, summaries, topics, memories, and source links then commit together or roll back together.

## Search

Every search runs Unicode FTS5 BM25 and multilingual-e5-small sqlite-vec KNN. Reciprocal Rank Fusion combines them. Memories add configurable relevance, exponential recency, and importance terms; transcript evidence remains relevance-first. Ask is a separate, rate-limited retrieval-augmented OpenRouter request with result citations.

## NeoAgent boundary

NeoAgent is an OAuth client of NeoRecall, not another processing worker. It
receives seven read-only tools for on-demand local search and evidence access.
Audio, voice embeddings, ingest, settings, memory mutation, consolidation, and
Ask remain inside NeoRecall. This avoids duplicated memory stores and prevents
an otherwise unnecessary second OpenRouter request.
