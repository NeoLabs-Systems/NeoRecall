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
- user-added recording context, including retained originals and derived text
  or image descriptions;
- local search vectors and metadata;
- operational audit, job, and AI-request records.

The server does not keep original recording chunks after successful
transcription. Before deleting a chunk, it can derive a mono speaker preview
from non-overlapping diarized turns. That account-scoped WAV is the only
intentionally retained audio and exists solely so the user can identify and
name a recurring speaker. Temporary source files have restrictive permissions,
and neither they nor any audio are included in a NeoRecall backup, which
snapshots the database only.

Context originals are different from recording audio: the account intentionally
attaches them as memory sources. They are retained for seven days by default.
Each user can choose 1–365 days in Settings; shortening the period applies
retroactively. Expiry removes the original file but keeps extracted text and AI
analysis so an existing memory does not silently lose its evidence. Deleting a
context item removes both its original and its derived content.

## Backups

The server takes a scheduled snapshot of its database, encrypts it, and writes it
to the configured destination — by default a private directory on the same host.
Snapshots use SQLite's online backup API, so an artifact is a complete database
rather than a copy taken mid-write. Old artifacts are pruned on a retention
count. See [Configuration](configuration.md) for the schedule, destinations and
the restore command.

A backup contains everything the database holds. Treat an artifact with the same
care as the installation itself, and note that it is encrypted with the key in
`~/.neorecall/data/secret.key` — copying artifacts somewhere without that key
means they cannot be restored, and copying the key alongside them means the
encryption protects nothing.

## Deleting an account

**Settings → Security → Danger zone** deletes an account permanently. It requires
the account password, an authenticator code when two-factor is enabled, and the
username typed out in full.

Deletion cascades through every table the account owns: transcripts,
conversations, memories, entities, search vectors, devices, sessions, security
keys, voiceprints and speaker previews. Temporary audio files belonging to the
account are unlinked, and the app erases anything still spooled on the device
before signing out. It cannot be undone, and it does not reach backup artifacts
taken before the deletion or data already sent to a configured provider.

## Deletion receipt invariant

Transcript persistence and audio removal are intentionally separate crash-safe phases. A terminal receipt is issued only after transcript rows are durable under SQLite `synchronous=FULL` and the temporary audio path has been removed. A crash between phases leaves the client copy intact while the startup sweeper completes server cleanup.

## Voiceprints

Recurring speaker matching stores biometric-like embeddings and the clean
preview per user. It can be disabled without disabling anonymous diarization.
Users can listen to, name, merge, or correct recurring identities.

Because those two things — the embedding and the preview clip — are the only
records that would let someone reading the database file recognise a voice, they
are encrypted at rest with the installation key, the same AES-256-GCM treatment
given to provider credentials. Anonymous per-session speaker clusters are not
encrypted: they carry no identity and are deleted with the session.

Everything else the server stores, including transcripts and memories, is held
unencrypted in SQLite under a private directory. Encrypt the host's disk if the
machine is not physically controlled.

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
