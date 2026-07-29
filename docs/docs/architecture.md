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
The engine owns capture, durable chunk writes, Bluetooth reconnect, and upload,
so dismissing the Activity does not detach those components. A durable capture
intent creates a new interrupted/recovered session after process recreation.
The notification Stop action waits for final chunk and session persistence
before releasing the service.

iOS background audio and Bluetooth modes can keep an authorized active session
alive while the app is backgrounded, but iOS does not permit an app to continue
or relaunch after the user force-quits it. NeoRecall does not represent that OS
restriction as a recoverable guarantee.

## Processing pipeline

Each logical audio channel is decoded to 16 kHz mono PCM. Silero VAD removes silence, Parakeet generates timestamped multilingual text, pyannote segmentation identifies speaker turns, and WeSpeaker embeddings support local clusters and optional cross-recording identities. Time-constrained token alignment removes overlap and cross-channel leakage without phrase lists.

Boundary detection is token-free: hard time gaps, speaker-set changes, and embedding-similarity valleys create candidate conversations. Short fragments join their semantically closest neighbor. Every conversation remains visible even when the consolidation model marks it as not memory-worthy.

## Memory and token budget

The SQLite budget gate is per user and survives restarts. A consolidation is eligible only after the effective interval, sufficient complete material, and OpenRouter configuration. One structured response creates English episodic memories, atomic mini-memories, entities, importance values, and an incremental daily summary. Zod validation and source-ID checks prevent partial or unsupported records.

## Search

Every search runs Unicode FTS5 BM25 and multilingual-e5-small sqlite-vec KNN. Reciprocal Rank Fusion combines them. Memories add configurable relevance, exponential recency, and importance terms; transcript evidence remains relevance-first. Ask is a separate, rate-limited retrieval-augmented OpenRouter request with result citations.

## NeoAgent boundary

NeoAgent is an OAuth client of NeoRecall, not another processing worker. It
receives seven read-only tools for on-demand local search and evidence access.
Audio, voice embeddings, ingest, settings, memory mutation, consolidation, and
Ask remain inside NeoRecall. This avoids duplicated memory stores and prevents
an otherwise unnecessary second OpenRouter request.
