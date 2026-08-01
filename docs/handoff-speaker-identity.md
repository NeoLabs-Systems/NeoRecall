# Handoff: speaker identity does not survive chunk boundaries

Fix speaker identification in NeoRecall (`/Users/neo/NeoRecall`). Read `AGENTS.md`,
`GUIDELINES.md` and `docs/docs/architecture.md` first.

## The defect, with evidence

Three hours of a real city council meeting (16 kHz mono, uploaded as 362 chunks of
30 s through the normal ingest path) produced 980 transcript segments and **29
speaker clusters**. One uninterrupted speech by a single member of the public was
split across **five** cluster ids:

```
4efbefbd  My name is Sumner Tilton.
dc6432ee  770 Salisbury Street, which is Salisbury West, a condominium…
0d16005f  But tonight I come uh to address
0d16005f  the Council… as the Chairman of the Board of Choose Worcester.
9a3668eb  convince a company to choose Worcester, partly because…
4eb1eeb9  Um it's it's a tough job to talk to corporations…
```

`4efbefbd` is also the cluster that said "City Council meeting is now called to
order" ninety minutes earlier — the chair's cluster was reused for a member of the
public. So there is both over-fragmentation and cross-attribution.

## Where it lives

- `server/transcription/diarization.js` — pyannote segmentation, run **per chunk**
  in `SherpaProvider.transcribe` (`server/transcription/providers/sherpa_provider.js`),
  so no chunk sees the one before it.
- `server/transcription/speaker_embeddings.js` — WeSpeaker embeddings per turn.
- `server/transcription/speaker_matching.js` — `resolveCluster` / `resolveVoiceprint`,
  the only thing carrying identity across chunks.
- Thresholds: `speakerClusterThreshold` (0.65), `voiceMatchThreshold` (0.72),
  `voiceMatchMargin` (0.05) in `server/config.js`, tunable via
  `server/services/settings/processing_settings_service.js`.

## What to deliver

Speaker identity that holds across chunk boundaries for a continuous speaker, and
does not merge distinct speakers. Judge it on real audio, not fixtures: a single
speaker's uninterrupted turn must keep one cluster id across the 30 s boundaries
it crosses.

Reproduce with `test/fixtures/de_en_two_speakers.wav` for the fast loop, and with a
long public-domain recording for the real one — e.g.
`https://archive.org/download/worcester_cc_2008-11-25_audio/worcester_cc_2008-11-25_64kb.mp3`
(public domain, 3 h). `scripts/e2e_live_smoke.js` shows how to drive chunks
through the real ingest API.

## Constraints

- Transcription stays local and CPU-only. No cloud speech services.
- `GUIDELINES.md`: language and speaker behaviour must be model-driven. No phrase
  lists, no scenario-specific branches. Tunable numbers belong in validated
  configuration, not inline.
- Do not weaken the ingest reliability invariant: a chunk's terminal receipt still
  requires the transcript to be durable and the server audio unlinked.
- Chunk duration is configurable (`NEORECALL_CHUNK_TARGET_MS`, default 30 s), so a
  fix must not assume any particular chunk length.

## Worth knowing

Memory quality currently survives this defect: the consolidation model attributes
actions using the **names spoken in the transcript** ("Councillor Clancy requested
a report…"), not the cluster ids. So this hurts the transcript view, speaker
filters and voiceprint matching — not memory attribution. Prioritise accordingly.
