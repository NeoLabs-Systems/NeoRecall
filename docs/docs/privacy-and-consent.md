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

In the default configuration, nowhere. Speech recognition, diarization,
embeddings, search and the language model that writes memories, previews and Ask
answers all run on the machine you installed NeoRecall on. There is no account to
create and no credential to supply, so there is nothing to disable.

The one exception is deliberate: setting `AI_PROVIDER=openai_compatible` sends
memory consolidation, live conversation previews and Ask requests as text to the
endpoint you name in `AI_API_BASE_URL`. Whether that endpoint is another machine
in your home or a hosted service is your decision and NeoRecall cannot tell the
difference. Audio is never sent in either configuration. Ask sends retrieved text
context and returns cited sources.

## Account isolation

Every domain query is scoped to the authenticated user. Cross-user object probes return `404`, avoiding both content and existence disclosure. Admin endpoints expose operational counts and state, not transcript, memory, entity, or speaker content.
