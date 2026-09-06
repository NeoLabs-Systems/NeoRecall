---
sidebar_position: 1
title: Installation
---

# Install NeoRecall

NeoRecall requires Node.js 20 or newer and a supported 64-bit host. It does not install or run speech-recognition or language-model weights. Before processing recordings, configure a hosted provider or separately deploy compatible transcription and language-model endpoints.

## Repository installer

NeoRecall is no longer published to the npm registry. The repository installer
clones NeoRecall from GitHub, links the global `neorecall` command to that
checkout, and runs the guided install:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/NeoLabs-Systems/NeoRecall/main/install.sh)
```

It asks for two things:

- **Install directory** — defaults to `~/NeoRecall`. The directory must be empty
  or already be a NeoRecall checkout.
- **Release channel** — `stable` tracks the `main` branch, `beta` tracks `beta`.
  The choice is written to `~/.neorecall/.env` and reused by later updates.

Git, Node.js 20 or newer, and npm are required. The checkout ships the built web
client, so the Flutter SDK is only needed to develop the clients, not to run the
server.

The install then creates `~/.neorecall`, runs database migrations, downloads and
verifies the small models NeoRecall runs itself — multilingual search embeddings,
a voice-activity detector, and speaker diarization, about 165 MB in total — and
probes ffmpeg and sqlite-vec. Speech recognition and language models are never
downloaded or started; configure those services through `.env` or the admin
dashboard after installation.

Open `http://localhost:4500` after `neorecall status` reports a running service.
Use a reverse proxy with TLS before exposing the server outside a trusted
network.

## Install from the desktop app

The macOS and Windows apps can perform the whole setup without a terminal.
On the server screen, choose **Set up NeoRecall on this computer**: the app
checks for Git, Node.js, and npm, clones the selected channel, installs
dependencies, links the CLI, starts the service, and connects to it — showing
each step as it runs. If a prerequisite is missing, the app names it and links to
the download instead of failing silently.

It then asks for the two services NeoRecall does not run itself: the
transcription service and the language model that writes memories. Pick a
provider, paste a key, let the app list the available models, and press **Save
and test** — the test transcribes a bundled sample recording and asks the model
for a one-word answer, reporting each leg separately. These settings are stored
encrypted in the database and can be changed later under **Settings → Services**.

That step works because the install creates an administrator API key in
`~/.neorecall/.env` and keeps it in the app's secure storage. To read or create
that key yourself:

```bash
neorecall admin-key
```

Servers this app did not install have no stored key; configure their providers
from the admin dashboard at `/admin` instead.

## Manual checkout

```bash
git clone --branch main https://github.com/NeoLabs-Systems/NeoRecall.git ~/NeoRecall
cd ~/NeoRecall
npm install --omit=dev
npm link
neorecall channel stable
neorecall install
```

## Updating

```bash
neorecall update            # latest commit on the configured channel
neorecall update beta       # switch channel and update
```

`update` fetches the channel branch, discards local changes to tracked files,
backs up runtime data, reinstalls dependencies, re-verifies the local models, and
restarts the service. An older global package installation is migrated to a Git
checkout on the first `neorecall update`; runtime data in `~/.neorecall` is kept.

## Docker Compose

```bash
docker compose build
docker compose run --rm neorecall node bin/neorecall.js setup
docker compose up -d
```

The compose volume contains the database, local search model, logs, and temporary processing files. Provider credentials come from a local `.env` or encrypted admin settings; no credentials are baked into the image.

## Service commands

```bash
neorecall status
neorecall logs
neorecall stop
neorecall channel
neorecall reset-password USERNAME NEW_SECURE_PASSWORD
```

macOS uses a LaunchAgent and Linux uses a systemd user service when available. On unsupported service managers, `neorecall start` launches the supervisor directly.
