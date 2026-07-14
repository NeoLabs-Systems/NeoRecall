---
sidebar_position: 4
title: Privacy and consent
---

# Privacy and consent

NeoRecall is designed for explicit, authorized recording. It does not determine whether a recording is lawful. Private speech can receive strong legal protection—for example, Germany's §201 StGB restricts unauthorized recording of privately spoken words. Obtain informed consent and follow workplace, venue, and local rules.

## What the server stores

- original-language transcript segments and timestamps;
- anonymous speaker turns and optional user-named voiceprint centroids;
- conversations, English memories, mini-memories, and daily summaries;
- local search vectors and metadata;
- operational audit, job, and AI-request records.

The server does not keep audio after successful transcription. No API returns audio, and audio is never stored as a SQLite BLOB. Temporary files have restrictive permissions and are excluded from backups.

## Deletion receipt invariant

Transcript persistence and audio removal are intentionally separate crash-safe phases. A terminal receipt is issued only after transcript rows are durable under SQLite `synchronous=FULL` and the temporary audio path has been removed. A crash between phases leaves the client copy intact while the startup sweeper completes server cleanup.

## Voiceprints and OpenRouter

Recurring speaker matching stores biometric-like embeddings per user. It can be disabled without disabling anonymous diarization. Users can name, merge, or correct recurring identities.

Only eligible memory consolidation and explicit Ask operations send text to OpenRouter. Audio is never sent. Ask sends retrieved text context and returns cited sources. OpenRouter access can be disabled completely by leaving its credentials unset.

## Account isolation

Every domain query is scoped to the authenticated user. Cross-user object probes return `404`, avoiding both content and existence disclosure. Admin endpoints expose operational counts and state, not transcript, memory, entity, or speaker content.
