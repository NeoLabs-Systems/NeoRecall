---
sidebar_position: 5
title: Troubleshooting
---

# Troubleshooting

## `/ready` reports models unavailable

Run `neorecall setup` and inspect `neorecall logs`. Setup verifies every downloaded SHA-256 and will resume incomplete downloads. Normal startup intentionally refuses to fetch missing model files.

## A chunk remains cleanup-pending

The transcript is already persisted, but the server has not yet issued a terminal receipt. Keep the client running and do not remove its local audio. The cleanup job and startup sweeper retry the unlink; the state then advances without retranscribing or duplicating segments.

## System audio is unavailable in a browser

Start device-audio capture from the Record screen and choose a share target that offers audio. Browser and operating-system support varies. NeoRecall displays microphone-only fallback rather than pretending system audio is active. Reloading always requires a new display-capture gesture.

## Recording stopped because storage is full

Free local space, reopen NeoRecall, and let the upload queue drain. Pending chunks are not discarded automatically. On the web, grant persistent browser storage if offered and review the quota indicator.

## Search misses semantic matches

Confirm `/ready` reports the vector extension and models ready. Newly transcribed segments are indexed by a worker job, so a large backlog may delay embeddings while exact FTS results remain available. The admin dashboard shows queue depth and oldest job age.

## Logs differ from the running deployment

NeoRecall is often operated on a separate server. Always collect logs and readiness output from the host handling the recording upload, not from a development checkout on another machine.
