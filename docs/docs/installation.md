---
sidebar_position: 1
title: Installation
slug: /
---

# Install NeoRecall

NeoRecall requires Node.js 20 or newer, a supported 64-bit host, and enough free space for the local speech models. The supported v1 server target is a single machine with at least four modern CPU cores and 8 GB RAM.

## npm and the user service

```bash
npm install --global neorecall
neorecall install
neorecall setup
neorecall start
```

`setup` creates `~/.neorecall`, runs database migrations, downloads every pinned model from `models/manifest.json`, verifies SHA-256 checksums, and probes sherpa-onnx, ffmpeg, sqlite-vec, and the 384-dimensional embedding model. Normal startup never downloads a model.

Open `http://localhost:4500` after `neorecall status` reports a running service. Use a reverse proxy with TLS before exposing the server outside a trusted network.

## Docker Compose

```bash
docker compose build
docker compose run --rm neorecall node bin/neorecall.js setup
docker compose up -d
```

The compose volume contains the database, models, logs, and temporary processing files. Supply OpenRouter configuration through a local `.env`; credentials are not included in the image.

## Service commands

```bash
neorecall status
neorecall logs
neorecall stop
neorecall reset-password USERNAME NEW_SECURE_PASSWORD
```

macOS uses a LaunchAgent and Linux uses a systemd user service when available. On unsupported service managers, `neorecall start` launches the supervisor directly.
