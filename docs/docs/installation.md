---
sidebar_position: 1
title: Installation
---

# Install NeoRecall

NeoRecall requires Node.js 20 or newer and a supported 64-bit host. It does not install or run speech-recognition or language-model weights. Before processing recordings, configure a hosted provider or separately deploy compatible transcription and language-model endpoints.

## npm and the user service

NeoRecall is not yet published to the npm registry; install the CLI globally straight from GitHub instead.

```bash
npm install --global github:NeoLabs-Systems/NeoRecall
neorecall install
neorecall setup
neorecall start
```

`setup` creates `~/.neorecall`, runs database migrations, downloads and verifies the small multilingual embedding model used by local semantic search, and probes ffmpeg and sqlite-vec. Speech and language-model services are never downloaded or started by NeoRecall. Configure them through `.env` or the admin dashboard after installation.

Open `http://localhost:4500` after `neorecall status` reports a running service. Use a reverse proxy with TLS before exposing the server outside a trusted network.

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
neorecall reset-password USERNAME NEW_SECURE_PASSWORD
```

macOS uses a LaunchAgent and Linux uses a systemd user service when available. On unsupported service managers, `neorecall start` launches the supervisor directly.
