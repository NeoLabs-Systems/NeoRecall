---
slug: /
title: NeoRecall documentation
sidebar_label: Overview
---

# NeoRecall documentation

NeoRecall is a self-hosted audio memory service. It records from web, desktop,
and wearable clients, keeps its durable database and search index on the server
you install, and sends inference to transcription and language-model services
you configure separately. NeoRecall does not download or run either model.

NeoRecall is beta software. Install it on a machine you administer and read
the privacy guide before recording anyone else.

## 🚀 Start here

```bash
npm install -g github:NeoLabs-Systems/NeoRecall
neorecall install
neorecall setup
neorecall start
```

Open `http://localhost:4500` and `/app/` when setup finishes. Continue with:

- [Install and complete the first run](installation.md)
- [Understand privacy and consent](privacy-and-consent.md)
- [Configure the server](configuration.md)

Configure both inference providers before recording; the server intentionally
has no bundled transcription or generation fallback.

## 🧭 User guide

| Guide | Use it for |
|---|---|
| [Installation](installation.md) | Host requirements, npm and Docker install, service commands |
| [Recording](recording.md) | Web, macOS, and Windows capture behavior and offline sync |
| [Configuration](configuration.md) | Environment variable reference |
| [Privacy and consent](privacy-and-consent.md) | What the server stores and how to record responsibly |
| [Troubleshooting](troubleshooting.md) | Diagnosing setup, sync, and startup issues |

## 🛠️ Developer guide

The developer guide explains the implementation rather than the product
setup. Start with [Architecture](architecture.md).

Contributors must also follow
[GUIDELINES.md](https://github.com/NeoLabs-Systems/NeoRecall/blob/beta/GUIDELINES.md),
[AGENTS.md](https://github.com/NeoLabs-Systems/NeoRecall/blob/beta/AGENTS.md), and
[CONTRIBUTING.md](https://github.com/NeoLabs-Systems/NeoRecall/blob/beta/CONTRIBUTING.md).
