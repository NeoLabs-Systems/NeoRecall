---
sidebar_position: 1
title: Installation
---

# Install NeoRecall

NeoRecall is a single program for macOS (x64, ARM64), Linux (x64, ARM64) and Windows (x64). It does not install or run speech-recognition or language-model weights. Before processing recordings, configure a hosted provider or separately deploy compatible transcription and language-model endpoints.

## What the release bundle brings

The signed runtime for each platform carries, next to the server binary, the
sherpa-onnx and ONNX Runtime libraries (local search embeddings, voice-activity
detection, speaker identity) and a static `ffmpeg` with its license. Each is
pinned to an upstream release and checked by SHA-256 when the bundle is built.

- **macOS**: the ONNX Runtime library needs macOS 15.5 or newer. On older
  versions local embeddings and speaker identity do not work.
- **Linux**: a glibc distribution with `libstdc++`. Alpine (musl) is not
  supported.
- **Windows**: needs the Microsoft Visual C++ Redistributable (x64).
- **Without the bundle** (built from source, or just the CLI binary): install
  `ffmpeg` yourself, and fetch the libraries into a folder named by
  `NEORECALL_RUNTIME_DIR`:

  ```bash
  go run ./cmd/neorecall-release native-libs --platform macos --arch arm64 --output ./native
  ```

`neorecall doctor` looks for `ffmpeg` on your `PATH` only, so it can report it
missing while the service uses the bundled one.

## Repository installer

On macOS and Linux, the installer downloads the `neorecall` binary for this
computer from the newest release on the chosen channel, checks its published
SHA-256, puts it in `~/.local/bin` (or `NEORECALL_BIN_DIR`) and runs
`neorecall install`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/NeoLabs-Systems/NeoRecall/main/install.sh)
```

It asks for the **release channel**: `stable` or `beta` (set
`NEORECALL_RELEASE_CHANNEL` to skip the question). The choice is written to
`~/.neorecall/.env` and reused by later updates. Neither Git nor Node.js is
needed.

The install then creates `~/.neorecall`, runs database migrations, downloads and
verifies the small models NeoRecall runs itself — multilingual search embeddings,
a voice-activity detector, and speaker diarization, about 165 MB in total — and
probes ffmpeg and sqlite-vec. Speech recognition and language models are never
downloaded or started; configure those services through `.env`, or in the app
under **Admin › Providers** after installation. The first account created on a
server is its admin.

Open `http://localhost:4500` after `neorecall status` reports a running service.
Use a reverse proxy with TLS before exposing the server outside a trusted
network.

## Install from the desktop app

The desktop apps can perform the whole setup without a terminal. On the server
screen, choose **Set up NeoRecall on this computer** and pick a channel: the app
downloads the signed server runtime, verifies its signature and checksum, runs
`neorecall install` from it, waits for the service and connects, showing each
step as it runs. If setup fails, the previous version is put back. The runtime
lives under `~/.neorecall`; desktop installs do not put `neorecall` on your
`PATH`.

Next it asks you to create your account. The first account on a server is its
admin, so right after signing up the app opens **Admin › Providers** for the two
services NeoRecall does not run itself: the transcription service and the
language model that writes memories. Pick a provider, paste a key, let the app
list the available models, and press **Save and test** — the test transcribes a
bundled sample recording and asks the model for a one-word answer, reporting
each leg separately. These settings are stored encrypted in the database and can
be changed later on the same page.

## Admins

Admin is a role on an ordinary account, not a separate login. The first account
created on a server becomes its admin and sees an **Admin** page in the app:
overview, users and usage limits, jobs, AI requests, the audit log, backups,
providers and processing thresholds, with a search box across all of them.
Admin routes accept only a signed-in session — API keys and OAuth tokens never
reach them — and the role is re-read on every request, so a change applies at
once.

```bash
neorecall admin                   # list admin accounts
neorecall admin grant <username>  # make an account an admin
neorecall admin revoke <username> # remove admin from an account
```

`NEORECALL_ADMIN_USERS` (comma-separated usernames) grants admin to those
accounts on every start, which suits Docker deployments. Register the accounts
first, then list them: the list only grants admin to accounts that already
exist, and a listed name that has no account yet is reserved — nobody can
register it until it is removed from the list. The list is additive: removing a
name does not revoke it, and an account revoked with the CLI stays revoked.
Every start logs which accounts are admins.

Admin accounts can't delete themselves or be disabled from the app; revoke
admin first. Installs from before this change keep their first account as
admin — check the start-up log or `neorecall status` after upgrading. The old
`ADMIN_USERNAME`, `ADMIN_PASSWORD` and `ADMIN_API_KEY` values grant nothing and
are removed from `~/.neorecall/.env` on the next start. Scripts that called the
old admin API with `ADMIN_API_KEY` sign in as an admin account instead
(`POST /api/v1/auth/login`) and send its session token to `/api/v1/admin/*`;
API keys and OAuth tokens are refused there. Because an admin session can
change where recordings are sent for transcription, turn on two-factor
authentication for admin accounts.

## Updating

```bash
neorecall update --notes    # say whether a newer version is ready, without installing it
neorecall update            # newest release on the configured channel
neorecall update beta       # switch channel and update
```

`update` backs up your data, downloads and verifies the signed release, and
restarts the service. If the new version does not start, it puts the previous one
back. When you are already on the latest version it says so. `--check` and
`--json` report the same information as JSON; none of the three changes anything,
and an unknown option is refused.

## Moving from the Node.js version

Updating a Node.js installation hands over to the binary by itself on macOS and
Linux. You can also run the repository installer: it backs up the data, migrates
the database and keeps `~/.neorecall`.

The signed runtime, with the native libraries and `ffmpeg`, is installed along
the way. An installation migrated earlier without it gets it from the next
`neorecall update`.

`neorecall` on its own shows a menu of the common actions; `neorecall status
--details` adds the install folder, data folder, versions and port, and
`neorecall help` lists every command.

## Docker Compose

```bash
docker compose build
docker compose run --rm neorecall neorecall setup
docker compose up -d
```

The compose volume contains the database, local search model, logs, and temporary processing files. Provider credentials come from a local `.env` or encrypted admin settings; no credentials are baked into the image. The image includes `ffmpeg` and the native libraries.

The server runs as uid 1000. The container starts as root only to hand the data
volume to that user, then drops privileges; `docker exec … neorecall` drops them
too. If you set `user:` yourself, the volume must already belong to that user.

### Upgrading from the Node.js image

Stop the old container cleanly first (`docker compose down`), so the encrypted
database has no pending write-ahead log: the new image cannot replay one. Back up
the volume, then use the new `compose.yaml` and run `docker compose up -d`.
The same named volume now mounts at `/data` instead of `/root/.neorecall`, and
its root-owned files are handed to uid 1000 on the first start. If you run the
image with `docker run`, change the mount to `-v <volume>:/data`; the container
refuses to start when it finds data still mounted at `/root/.neorecall`.

## Service commands

```bash
neorecall status
neorecall logs
neorecall stop
neorecall channel
neorecall reset-password USERNAME
neorecall reset-password USERNAME --password-file PATH
```

macOS uses a LaunchAgent and Linux uses a systemd user service when available. On unsupported service managers, `neorecall start` launches the supervisor directly.
