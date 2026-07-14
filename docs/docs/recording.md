---
sidebar_position: 2
title: Recording
---

# Recording and offline sync

The web client supports microphone capture in modern browsers. Chrome and Edge can also request display/system audio. That permission must begin from a user action and is requested again after a reload; unsupported or lost system audio is shown explicitly while microphone capture continues.

The macOS 13+ and Windows 10/11 x64 clients combine microphone and system audio into separate logical channels. Desktop is the v1 reference client for uninterrupted recording because browsers can suspend tabs and evict non-persistent storage.

## Consent and indicators

NeoRecall shows a first-run recording notice and a persistent recording state. It has no covert mode. Before recording, obtain the consent required in your jurisdiction and organization. Pause immediately when consent changes or sensitive material should not be retained.

## Durable chunks

Capture uses independently decodable WAV chunks, normally 30 seconds long with a short leading overlap. The client keeps every unacknowledged chunk in its local ledger. When connectivity returns it:

1. recreates the device, session, and source declarations idempotently;
2. uploads chunks in source order with an idempotency key and SHA-256;
3. polls terminal receipts if SSE is unavailable;
4. deletes local audio only after the receipt includes transcript persistence, checksum, and server-audio-deletion timestamps.

NeoRecall never removes pending audio merely to satisfy a storage cap. If storage is exhausted, recording stops visibly and records a gap.
Capture-gap records carry both monotonic time offsets and the exact missing sequence range. Later chunks remain blocked until every preceding sequence is terminal or explicitly covered by one of those gaps.

## Importing existing audio

Choose **Import audio** on the Record screen. Large files use the multipart import protocol and enter the same VAD, transcription, diarization, search, and memory pipeline as live capture. Selecting the same file again after an interrupted transfer resumes its missing parts for the same account and server. Failed imports expire according to the server TTL because a browser may no longer retain access to the original file.
