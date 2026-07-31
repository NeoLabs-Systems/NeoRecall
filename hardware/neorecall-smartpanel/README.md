# NeoRecall Smart Panel

Firmware for the **Waveshare ESP32-S3-Touch-LCD-4B** ("Smart 86 Box" — 4"
480×480 RGB touch panel) that turns it into an always-on NeoRecall room
recorder with a beautiful dashboard.

It does two things at once:

1. **Records the room 24/7** and streams the audio to your NeoRecall backend
   using the *exact same* durable ingest protocol as the Flutter apps, so the
   panel shows up as just another device in the same transcribe → diarize →
   consolidate flow. **No backend changes are required.**
2. **Shows a useful, gorgeous dashboard** in the NeoRecall visual language —
   large clock, weekday, date and live weather — that you can happily leave on a
   shelf or wall.

The design mirrors the NeoRecall app: a near-black forest-green canvas
(`#0E1511`), cream text (`#ECEFE5`), a single warm gold accent (`#E1B052`), and
rose (`#D98AA6`) reserved for the live-recording state.

---

## Features

- **Never stops recording.** Capture begins at boot — before the network or even
  the clock are up — and only ever pauses when *you* pause it. Every gap in
  audio (pause, a mic fault, a reboot, storage pressure) is declared to the
  backend as a truthful capture gap; nothing is silently dropped.
- **The reliability invariant.** Audio is released and deleted locally *only*
  after the server returns a terminal receipt proving the transcript is
  persisted and the server's own audio copy was deleted — identical to the
  Flutter client's contract.
- **Memory-first spool.** Because this board has no SD card and only 16 MB of
  flash, chunks live in PSRAM and upload straight from RAM in the common case;
  they spill to a LittleFS partition only during a network/backend outage, so
  24/7 operation does not wear the flash.
- **Dashboard**: clock (12/24 h), weekday + date, and keyless weather with an
  animated equalizer that comes alive while recording.
- **Bottom-left pause/resume** button, exactly as requested. The pause state is
  persisted, so it survives a reboot.
- **Everything is configured on the device itself** (touchscreen) — no phone, no
  hotspot. Swipe up or tap the gear to open Settings: pick a Wi-Fi network from a
  live scan and type its password, enter the backend URL and API key, set the
  location, °C/°F, 12/24 h, day/night brightness, and a **night schedule** that
  dims or fully blanks the screen between two times (with tap-to-wake). On first
  boot the setup screen opens automatically.
- **Keyless weather & location**: Open-Meteo for weather (one HTTPS call also
  yields the local UTC offset) and ipwho.is for first-boot geolocation. No API
  keys, and the backend is never involved in weather/location.

---

## Hardware (verified)

Waveshare **ESP32-S3-Touch-LCD-4B**, ESP32-S3-WROOM-1-**N16R8** (16 MB flash,
8 MB **octal** PSRAM):

| Subsystem | Part | Notes |
|---|---|---|
| Display | ST7701 480×480 IPS, 16-bit RGB565 | init over TCA9554 3-wire SPI |
| Touch | GT911 (I²C `0x5D`) | 5-point capacitive |
| IO expander | TCA9554 (I²C `0x20`) | LCD CS/SDA/SCL/RST + speaker enable |
| Microphones | 2× analog MEMS → **ES7210** ADC (I²C `0x40`) | I²S RX on GPIO15 |
| Speaker | ES8311 → NS4150B | unused by this firmware |
| PMU | AXP2101 (I²C `0x34`) | left at power-on defaults |
| Power | USB-C 5 V (or Li-battery) | run it from USB-C for 24/7 use |

Every pin lives in [`main/board/board_config.h`](main/board/board_config.h).

---

## Build & flash

Requires **ESP-IDF 5.1+** (Waveshare ships demos against 5.1.4; 5.2/5.3 also
work). Managed components (ST7701, GT911, LVGL, TCA9554, LittleFS) are pulled
automatically on first configure.

```bash
cd hardware/neorecall-smartpanel
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/YOUR-USB-PORT flash monitor
```

Use the **USB-C port wired to the ESP32-S3 native USB** (H1/OTG) for flashing.

---

## First-time setup (all on the touchscreen)

1. Power the panel. With nothing configured, the **Settings** screen opens
   automatically (the dashboard's status line also reads "Einrichtung nötig").
2. Under **WLAN**, tap *"Netzwerke suchen"*, pick your network from the list, and
   type its password on the on-screen keyboard.
3. Under **BACKEND**, enter the **NeoRecall backend URL** (origin only, e.g.
   `https://recall.example.com` — the firmware appends `/api/v1`) and your
   **API key**. Tick *"TLS-Zertifikat nicht prüfen"* only for a self-hosted
   server with a self-signed certificate.
4. Tap **"Speichern & verbinden"**. The panel joins Wi-Fi, syncs the clock, and
   starts recording.

Open Settings any time by swiping up or tapping the gear. *"Erneut verbinden"*
re-applies the Wi-Fi credentials.

### Creating the API key in NeoRecall

Create an API key with at least the **`ingest:write`** scope (that scope also
permits the one-time device registration). In the NeoRecall app/admin this is
the standard "API keys" flow; the key looks like `nrk_ab12cd_…`. Paste it into
the panel's setup page. The panel then appears in your NeoRecall device list as
a **wearable** named "NeoRecall Panel".

---

## How recording maps onto the NeoRecall protocol

The panel speaks the same endpoints as `flutter_app/lib/src/api_client.dart`:

- `POST /api/v1/devices` — registers itself (kind `wearable`).
- `POST /api/v1/ingest/sessions` — declares a session with one `microphone`
  source, `mono`, `16000` Hz, `pcm_s16le`.
- `PUT …/sources/{id}/chunks/{seq}` — uploads 16 kHz mono **WAV** chunks
  (~30 s, 2 s overlap) as multipart, with `Idempotency-Key`, `X-Chunk-Sha256`,
  duration/overlap/offset headers — matching `capture_pipeline.dart` exactly.
- `POST /api/v1/ingest/chunks/status` → on a terminal `transcribed`/`silent`
  receipt (with `serverAudioDeletedAt`), `POST …/chunks/released` and the local
  copy is deleted.
- `POST …/sessions/{id}/gaps` — pauses, mic faults, storage-full drops and
  reboots are declared as `user_paused` / `capture_error` / `storage_full` /
  `device_shutdown` gaps.

The chunk timeline, overlap semantics and the terminal-receipt release contract
are ported 1:1 from the Flutter client so processing behaves identically.

---

## Over-the-air updates

The panel updates itself from GitHub:

1. [`.github/workflows/build-firmware.yml`](../../.github/workflows/build-firmware.yml)
   builds this firmware with ESP-IDF on every change to its folder and, on
   `beta`, publishes a rolling **`firmware-latest`** pre-release with the `.bin`
   plus a `manifest.json` (version, download URL, sha256).
2. On the device, **Settings → Software-Update (OTA)**: enable "Automatische
   Updates" and paste the manifest URL
   `https://github.com/<owner>/<repo>/releases/download/firmware-latest/manifest.json`.
3. The panel checks every 6 h (and once shortly after boot); if the manifest
   version differs from the running one it downloads via `esp_https_ota`,
   verifies the image and reboots. A bad image is rolled back automatically by
   the bootloader (rollback enabled), and a healthy boot is confirmed after a
   60 s grace period. The repo/release must be public so the device can fetch it
   without credentials.

## Board bring-up (verified working)

Built with **ESP-IDF v5.4.2** and confirmed running on real hardware. The
display config matches Waveshare's official `esp32_s3_touch_lcd_4b` BSP. The
non-obvious essentials (all in [`nr_board.c`](main/board/nr_board.c)):

- **I2C uses the new `i2c_master` driver** — the legacy `driver/i2c.h` cannot
  coexist with the managed touch/expander components (`driver_ng` conflict).
- **ST7701 COLMOD = RGB666** (`panel_dev_config.bits_per_pixel = 18`, init array
  `0x3A = 0x66`) even though the framebuffer is 16-bit RGB565 on a 16-wire bus —
  this is the fix for washed-out/red colours. Inversion is done by **INVON
  (`0x21`)** inside the init array, not `esp_lcd_panel_invert_color()`.
- **No drift/shimmer:** `num_fbs = 1` + a 20-line bounce buffer, and the LVGL
  port runs with `avoid_tearing = false` (partial draw buffers), `swap_bytes =
  false`, blue-first `data_gpio_nums`.
- **GT911 touch** is reset through the TCA9554 (INT low at reset → address
  `0x5D`); **AXP2101 PMU is left at power-on defaults**; mic gain is
  `ES7210_MIC_GAIN` in [`nr_mic.c`](main/board/nr_mic.c).

German UI text renders via custom LVGL fonts (Montserrat + FontAwesome symbols +
Latin-1) generated with `lv_font_conv` into [`main/ui/fonts/`](main/ui/fonts/) —
the built-in Montserrat fonts are ASCII-only. Regenerate them (or swap in
Geist/Geist Mono for a pixel-match to the app) with the same tool.

---

## Layout

```
main/
  app_main.c              boot orchestration
  config/nr_config.*      NVS-backed settings (thread-safe snapshot)
  net/nr_time.*           SNTP + ISO-8601 + local time
  net/nr_http.*           TLS HTTP helper + streaming multipart WAV PUT
  net/nr_wifi.*           station reconnect + on-device network scan
  net/nr_ota.*            esp_https_ota client (manifest poll + rollback confirm)
  ingest/nr_spool.*       durable memory-first chunk/session/gap store
  ingest/nr_ingest.*      the upload pump (protocol state machine)
  ingest/nr_recorder.*    24/7 capture → WAV chunker → spool
  board/nr_board.*        I2C, ST7701 panel, GT911 touch, backlight, LVGL
  board/nr_mic.*          ES7210 + I2S microphone capture
  services/nr_weather.*   Open-Meteo weather
  services/nr_geo.*       ipwho.is geolocation + IANA→POSIX timezones
  ui/nr_ui.*              dashboard + night mode
  ui/ui_settings.*        settings app
```

---

## Privacy

The panel records continuously; place it and configure consent responsibly. It
only ever sends audio to the backend URL you configure, and it deletes local
audio as soon as the backend confirms the transcript is safely stored. Weather
and location calls go to Open-Meteo / ipwho.is and never carry your audio.
