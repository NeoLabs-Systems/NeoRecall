---
sidebar_position: 2
title: Recording
---

# Recording and offline sync

The web client supports microphone capture in modern browsers. Chrome and Edge can also request display/system audio. That permission must begin from a user action and is requested again after a reload; unsupported or lost system audio is shown explicitly while microphone capture continues.

The macOS 13+ and Windows 10/11 x64 clients combine microphone and system audio into separate logical channels. Desktop is the v1 reference client for uninterrupted recording because browsers can suspend tabs and evict non-persistent storage.

The desktop mixer waits for both selected sources rather than consuming a
temporarily late channel as silence. If a source actually stops, its aligned
tail is finalized and the remaining source continues. Windows loopback audio is
resampled from the active output-device format to 16 kHz mono before mixing.

## Desktop quick capture

After sign-in, the desktop client opens as a compact always-on-top recorder in
the lower-right corner. Microphone and device audio are selected together by
default in both quick capture and the full recorder. **Open notes library**
expands it into the same Record, Timeline, Memories, Search, Speakers, Sources,
and Settings structure used by the web app. Closing either view hides NeoRecall
to the tray so upload recovery and meeting detection can keep running; **Quit**
in the tray menu exits it completely.

While the tray process is running, NeoRecall watches for newly launched meeting
sessions from Zoom, Microsoft Teams, Webex, and FaceTime. A stable process
transition surfaces the recorder; it never starts recording by itself. The user
must acknowledge consent and press **Record meeting**, which captures microphone
and device audio together. When the meeting process exits, an active recorder
asks the user to finish instead of cutting audio off automatically.

This detector reads process metadata only—it does not monitor idle audio or
record in the background. Browser-only meeting tabs cannot be identified from
the operating-system process list, so Google Meet and other browser calls still
use **Quick capture** from the tray.

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

Local pending-audio totals, sessions, and uploads are account-scoped. Logging
out first finalizes an active recording and never hands its queued chunks to a
subsequently signed-in account.

## Mobile capture foundation

Android phone-microphone capture uses a visible foreground service, an
unbounded active wake lock, and a process-owned Flutter engine. Swipe-away does
not destroy the recording engine. If Android later recreates the process while
capture is still requested, NeoRecall closes the interrupted session and starts
a new recovery session using the durable local intent. Network requests have
bounded timeouts, and queued chunks remain on disk through offline periods.

Bluetooth support is transport- and device-adapter based. Adapters normalize
PCM, connection states, battery state, and physical start/stop/standby/wake
events. Reconnect uses bounded exponential backoff. No Bluetooth protocol is
enabled in the default registry until that device's audio framing and control
semantics have been validated.

Android cannot override a user Force stop, revoked permissions, exhausted
storage, or some vendor battery-management policies. iOS cannot continue after
a user force-quit. Those operating-system actions are shown as limitations,
not described as guaranteed background execution.

## Importing existing audio

Choose **Import audio** on the Record screen. Large files use the multipart import protocol and enter the same VAD, transcription, diarization, search, and memory pipeline as live capture. Selecting the same file again after an interrupted transfer resumes its missing parts for the same account and server. Failed imports expire according to the server TTL because a browser may no longer retain access to the original file.
