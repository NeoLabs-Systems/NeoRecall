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
care as the installation itself. The live database is already page-encrypted;
the backup snapshot is encrypted again with the key in
`~/.neorecall/data/secret.key` before it leaves the process. Copying artifacts
somewhere without that key means they cannot be restored, and copying the key
alongside them means the outer encryption protects nothing.

## Nextcloud copies

Each account can connect its own self-hosted Nextcloud instance under
**Settings → Integrations**. After signing in on that instance, the owner can
opt in to two write-only copies:

- **recordings** — while a recording is still open, transcribed chunks are
  copied aside locally. When that recording ends, NeoRecall joins them into
  one audio file, PUTs that file to Nextcloud, and deletes the local copies
  as usual;
- **this account's data** — a periodic (and manual) zip of that user's
  transcripts, conversations, memories, summaries, notes, named speakers,
  entities, settings and device metadata. It is not a snapshot of the server
  and it does not include other users. The same zip is available in the app
  under **Settings → Security → Your data**.

Nothing is read back. Nextcloud is not a restore path. The copies leave this
machine because the account asked them to, and they are written as ordinary
files — a playable recording or a readable zip — not sealed NeoRecall blobs.
A failed Nextcloud upload never delays a terminal receipt.

## Deleting an account

**Settings → Security → Danger zone** deletes an account permanently. It requires
the account password, an authenticator code when two-factor is enabled, and the
username typed out in full.

Deletion cascades through every table the account owns: transcripts,
conversations, memories, entities, search vectors, devices, sessions, security
keys, voiceprints and speaker previews. Temporary audio files belonging to the
account are unlinked, and the app erases anything still spooled on the device
before signing out. Audit rows that mentioned the account keep their
operational action, but lose the account identifier, IP address, and metadata.
It cannot be undone, and it does not reach backup artifacts taken before the
deletion, files already copied to Nextcloud, or data already sent to a
configured provider.

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
separately sealed: they carry no durable identity and are deleted with the
session, and they live inside the same page-encrypted database as everything
else.

The SQLite file itself is encrypted at rest with that installation key
(ChaCha20-Poly1305 page encryption). Transcripts, memories, search tokens,
vectors, and settings are ciphertext on disk. A process that has `secret.key`
decrypts pages in memory so search, matching, and generation keep working
without a new password or a change in the product. Temporary audio, import
parts, context originals, and pending Nextcloud copies are sealed with
AES-256-GCM while they sit on disk; they are opened only for the job that
needs the bytes. Clients seal pending capture audio the same way, with a key
held in the device keychain or secure storage.

A stolen database file or support directory without `secret.key` (or the
device keystore) is not readable speech. Copying the key next to the files
means the encryption protects nothing; keep `secret.key` on the host and
back it up separately from encrypted artifacts. Encrypt the host's disk as
well when the machine is not physically controlled.

## Where text goes

NeoRecall sends uploaded audio to the configured transcription provider. It sends
transcript text and retrieved context to the configured language-model provider
for memory consolidation, live previews, summaries, and Ask. Either provider may
be a hosted API or a compatible service deployed elsewhere on a private network;
NeoRecall cannot infer the privacy policy of that endpoint.

Embeddings and search remain on the NeoRecall host. Provider API keys supplied
through the admin dashboard are encrypted at rest and never returned to clients.
Ask sends only its retrieved text context and returns cited sources.

## Downloading a copy

**Settings → Security → Your data** downloads a zip of the signed-in account:
transcripts, conversation titles and summaries, memories, notes and extracted
context text, named speakers, entities, settings, and device metadata. It does
not include audio, voice embeddings, other accounts, or server secrets. The
same file is what Nextcloud receives when that account enables data copies.

## Account isolation

Every domain query is scoped to the authenticated user. Cross-user object probes return `404`, avoiding both content and existence disclosure. Admin endpoints expose operational counts and state, not transcript, memory, entity, or speaker content.
