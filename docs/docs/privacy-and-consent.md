---
sidebar_position: 4
title: Privacy and consent
---

# Privacy and consent

NeoRecall is designed for explicit, authorized recording. It does not determine whether a recording is lawful. Private speech can receive strong legal protection—for example, Germany's §201 StGB restricts unauthorized recording of privately spoken words. Obtain informed consent and follow workplace, venue, and local rules.

## What the server stores

- original-language transcript segments and timestamps;
- anonymous speaker turns, optional user-named voiceprint centroids, and one
  derived 5–10 second clean voice preview per recurring speaker;
- conversations, English memories, mini-memories, and daily summaries;
- local search vectors and metadata;
- operational audit, job, and AI-request records.

The server does not keep original recording chunks after successful
transcription. Before deleting a chunk, it can derive a mono speaker preview
from non-overlapping diarized turns. That account-scoped WAV is the only
intentionally retained audio and exists solely so the user can identify and
name a recurring speaker. Temporary source files have restrictive permissions
and are excluded from backups.

## Deletion receipt invariant

Transcript persistence and audio removal are intentionally separate crash-safe phases. A terminal receipt is issued only after transcript rows are durable under SQLite `synchronous=FULL` and the temporary audio path has been removed. A crash between phases leaves the client copy intact while the startup sweeper completes server cleanup.

## Voiceprints

Recurring speaker matching stores biometric-like embeddings and the clean
preview per user. It can be disabled without disabling anonymous diarization.
Users can listen to, name, merge, or correct recurring identities.

## Where text goes

NeoRecall sends uploaded audio to the configured transcription provider. It sends
transcript text and retrieved context to the configured language-model provider
for memory consolidation, live previews, summaries, and Ask. Either provider may
be a hosted API or a compatible service deployed elsewhere on a private network;
NeoRecall cannot infer the privacy policy of that endpoint.

Embeddings and search remain on the NeoRecall host. Provider API keys supplied
through the admin dashboard are encrypted at rest and never returned to clients.
Ask sends only its retrieved text context and returns cited sources.

## Account isolation

Every domain query is scoped to the authenticated user. Cross-user object probes return `404`, avoiding both content and existence disclosure. Admin endpoints expose operational counts and state, not transcript, memory, entity, or speaker content.
