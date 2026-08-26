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

## Recording context

Once capture starts, the idle source picker is replaced by one active-recording
workspace. It contains the single live timer and stop control plus one action
each for a highlight, typed note, photo, or file. Context is durably queued on
the device alongside recording metadata, so adding it also works while offline.

Highlights emphasize the nearby transcript. Notes can supply names or details
the audio may miss. NeoRecall extracts text from plain text, Markdown, CSV,
JSON, PDF, and DOCX files, and asks a vision-capable configured model to describe
JPEG, PNG, and WebP images. Other files remain attached and are reported as
unsupported instead of being discarded. During consolidation, each item is
associated with the closest transcript moment, so recordings that produce
several memories do not attach every source to every memory.

The same Context section appears on a finished memory. Adding or removing a
source there queues an in-place AI rewrite: the memory identity, pin/archive
state, and explicit importance override remain intact while generated prose and
mini-memories are replaced atomically.

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

## Android home-screen widgets

Five widgets are available from the Android widget picker. All of them are
configurable: long-press a placed widget and choose the gear, or use the
settings screen shown while placing one. Every option previews live before it is
saved.

| Widget | Shows | Configure |
| --- | --- | --- |
| **Recorder** | Start capture, stop it again, and the elapsed recording time | What the button does while recording; appearance |
| **Capture status** | The current pipeline stage, its progress, queued audio, and any issue holding it up | Where a tap opens; appearance |
| **Commitments** | Open tasks and promises with their due dates | Which commitments to show; whether to show the source conversation; appearance |
| **Memories** | Recent memories with their summaries | Which memories to show; whether to show summaries; appearance |
| **Today** | One headline number against the last seven days, or the week ahead | Which number to headline; appearance |

Widgets render in the launcher's process, so they cannot reach the server or
the local database. The app publishes one snapshot of what a widget may show,
and the widget renders only that. A widget therefore shows the state as of the
last time NeoRecall ran, which on Android is whenever capture, a wearable link,
or sync is active.

Two actions do not open the app: stopping a recording, and ticking a commitment
done. Both are recorded on disk before anything else happens, so a tap survives
a cold start; a ticked commitment disappears from the widget immediately and is
sent to the server the next time the app runs. Starting phone-microphone capture
still opens NeoRecall, because Android refuses microphone access to a process
with no attached UI.

Signing out clears every widget: they fall back to asking for a sign-in rather
than continuing to show the previous account's memories.

## Importing existing audio

Choose **Import audio** on the Record screen. Large files use the multipart import protocol and enter the same VAD, transcription, diarization, search, and memory pipeline as live capture. Selecting the same file again after an interrupted transfer resumes its missing parts for the same account and server. Failed imports expire according to the server TTL because a browser may no longer retain access to the original file.
