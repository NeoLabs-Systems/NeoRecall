# NeoRecall Desk

A Raspberry Pi Zero 2 W appliance that appears to a laptop as an output-only
USB audio device ("NeoRecall Audio"), passing audio through to Bluetooth
headphones or a WM8960 HAT, and — only on a deliberate on-screen action —
recording that audio (and optionally the room, via the HAT's onboard mics)
through NeoRecall's existing `system`/`microphone` ingest sources.

No laptop software, driver, or meeting-bot is required or present. This is
**not** a covert recorder: recording is manual and unmistakably indicated.

## Status

This workspace currently implements and fully tests the **platform-
independent core** — the parts of the design that own no PipeWire session,
no BlueZ connection, no Slint UI, and no USB gadget state, and therefore
build and test on any host (this was verified on macOS arm64 in addition to
the Linux target):

| Crate | What it owns | Tests |
| --- | --- | --- |
| `nrd-config` | Layered/validated TOML config: hardware profile, chunk policy, power/storage/network tunables, the supported OS/kernel matrix | 28 |
| `nrd-ledger` | SQLite WAL ledger, the chunk state machine, atomic blob writes, and crash recovery for every boundary in the design doc | 35 |
| `nrd-proto` | The NeoRecall wire client: auth, devices, meta, sessions, chunk upload, and the `Receipt::proves_safe_audio_release` gate | 20 |
| `nrd-audio` | The DSP with no hardware dependency: the anti-aliasing FIR decimator (48 kHz stereo → 16 kHz mono), the chunker's overlap/timeline bookkeeping, WAV encoding | 19 |
| `nrd-power` | Throttle/undervoltage decoding and the mute-recovery debounce policy | 10 |

**112 tests, all passing**, plus a clean `cargo clippy --workspace --all-targets -- -D warnings` and `cargo fmt --check`. Run them yourself:

```bash
cd hardware/neorecall-desk
cargo test --workspace
```

### The reliability invariant, enforced in code

`AGENTS.md`: *a client may release audio only after a terminal receipt
proves transcript persistence and server-side audio deletion.* Concretely:

- `nrd-proto::Receipt::proves_safe_audio_release()` is the single predicate
  that checks this (state ∈ `{transcribed, silent}` **and** `persistedAt`,
  `serverAudioDeletedAt`, `transcriptSha256` all present) — tested against
  absent-vs-null fields and every non-terminal state.
- `nrd-ledger`'s chunk state machine makes `Terminal` reachable **only**
  through that proof (`chunk_state::apply` returns `Err` for any other
  path), and `Released` reachable only from `Terminal`.
- `nrd-ledger::recovery` reconciles every crash boundary between "audio
  written" and "audio released" by retaining the file, never by discarding
  it — covered by dedicated tests for a truncated `.partial`, an orphan
  file, a chunk stuck at `Terminal` with its file still present, and a
  `Released` row whose unlink didn't complete.

### What is not yet built, and why

The remaining crates in the design (`nrd-core`'s orchestration, `nrd-audio`'s
PipeWire graph and AEC, `nrd-power`'s live sysfs polling loop, `nrd-enroll`'s
UI-driven state machine, `nrd-ui`'s Slint screens, and `nrd-setup`'s USB
gadget configfs/systemd work) all require either real Linux audio/display
hardware or the armv7 cross-compilation container described as Risk R5 in
the project plan — neither is available in this environment. Rather than
write PipeWire/Slint/BlueZ code that cannot be compiled or exercised here
(which this repo's `AGENTS.md` rules out: "do not add fake implementations
or unfinished placeholder behavior"), that work is left for the hardware-
in-the-loop phase, where it can be built and verified for real. The crates
above were deliberately chosen because they are exactly the design's own
recommended starting point — see "Build order" in the project plan — and
because getting the reliability invariant right here is the part that
matters most before any hardware exists to test against.

`profiles/pi-zero2w-wm8960-elegoo480x320.toml` is the shipped hardware
profile referenced by `nrd-config`'s own tests. Its USB `id_vendor` is the
pid.codes open-source shared Vendor ID; `id_product` is an unregistered
placeholder — see the comment in that file before building real hardware.

## Server-side changes

Landed alongside this workspace, in the main NeoRecall server:

- `server/db/migrations/023_device_kind_appliance.js` — adds `appliance` to
  the `devices.kind` enum.
- `server/routes/devices.js` — accepts `kind: "appliance"`.
- `server/routes/api_keys.js` — `DELETE /api/v1/api-keys/self`, letting an
  API key revoke itself during on-device sign-out without an interactive
  session.
- `flutter_app/lib/main_devices.dart` — a distinct icon and a `REVOKED`
  badge for appliance devices in the existing device list.

Covered by `test/api/appliance.test.js` (7 cases) and
`flutter_app/test/devices_panel_test.dart` (2 cases).
