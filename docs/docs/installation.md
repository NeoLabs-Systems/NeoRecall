---
sidebar_position: 1
title: Installation
---

# Install NeoRecall

NeoRecall requires Node.js 20 or newer, a supported 64-bit host, and enough free space for the local models — roughly 7 GB in total, of which about 5.2 GB is the language model that writes memories. The supported server target is a single machine with at least four modern CPU cores and 16 GB RAM. Everything runs on the CPU if it has to; a Metal, CUDA or Vulkan GPU is used automatically when one is present and makes memory generation several times faster. On a machine with 8 GB, point `LLM_MODEL_FILE` at a smaller model — nothing in the pipeline depends on the bundled one.

## npm and the user service

NeoRecall is not yet published to the npm registry; install the CLI globally straight from GitHub instead.

```bash
npm install --global github:NeoLabs-Systems/NeoRecall
neorecall install
neorecall setup
neorecall start
```

`setup` creates `~/.neorecall`, runs database migrations, downloads every pinned model from `models/manifest.json` — speech recognition, diarization, embeddings and the language model — verifies SHA-256 checksums, and probes sherpa-onnx, ffmpeg, sqlite-vec, the 384-dimensional embedding model, and the presence of the language model. Normal startup never downloads a model. The first download is the slow part of installation; budget time for it on a slow connection.

Open `http://localhost:4500` after `neorecall status` reports a running service. Use a reverse proxy with TLS before exposing the server outside a trusted network.

## Docker Compose

```bash
docker compose build
docker compose run --rm neorecall node bin/neorecall.js setup
docker compose up -d
```

The compose volume contains the database, models, logs, and temporary processing files — including the language model, which runs inside the container and needs no credentials. Only an operator who chooses to send generation to an external endpoint supplies anything sensitive, through a local `.env`; nothing of the sort is baked into the image.

## Service commands

```bash
neorecall status
neorecall logs
neorecall stop
neorecall reset-password USERNAME NEW_SECURE_PASSWORD
```

macOS uses a LaunchAgent and Linux uses a systemd user service when available. On unsupported service managers, `neorecall start` launches the supervisor directly.
