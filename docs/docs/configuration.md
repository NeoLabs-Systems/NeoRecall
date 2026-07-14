---
sidebar_position: 3
title: Configuration
---

# Configuration

NeoRecall reads `~/.neorecall/.env` and process environment variables. See the commented `.env.example` for the complete list.

## Essential server values

| Variable | Purpose | Default |
|---|---|---|
| `NEORECALL_HOST` | Listen address | `127.0.0.1` |
| `NEORECALL_PORT` | HTTP port | `4500` |
| `NEORECALL_TRUST_PROXY` | Trust one reverse-proxy hop | `false` |
| `MAX_UPLOAD_BYTES` | Maximum live chunk upload | `33554432` |
| `NEORECALL_REQUIRE_VECTOR` | Fail without the tested sqlite-vec extension | production: `true` |

## Local inference

`TRANSCRIPTION_PROVIDER=sherpa` selects the native CPU pipeline. `NEORECALL_SHERPA_THREADS` controls native inference threads. An OpenAI-compatible transcription endpoint can be selected with `TRANSCRIPTION_PROVIDER=openai_compatible`, `TRANSCRIPTION_API_BASE_URL`, and an optional key; this is separate from OpenRouter and is intended for self-hosted speech servers.

The embedding model must produce exactly 384 dimensions. Setup probes it before startup. Model files and their revisions are pinned in `models/manifest.json`.

## Memory consolidation

Set `OPENROUTER_API_KEY` and `AI_DEFAULT_MODEL` to enable memory generation. `NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS` is the environment-enforced floor; a user can request a longer interval but never a shorter one. `NEORECALL_MIN_NEW_MATERIAL_CHARS` prevents calls for trivial new material.

Every consolidation attempt, including a timeout, consumes its interval. It performs one outbound request with no LLM repair retry. Ask uses its own `NEORECALL_ASK_MAX_PER_HOUR` database quota and minute burst limiter.

## Operational thresholds

The admin dashboard can safely tune boundary, deduplication, speaker matching, and consolidation material thresholds. Values are validated and stored in SQLite. Environment defaults remain the source of truth until an administrator explicitly overrides a value.

## NeoAgent connection

NeoAgent connects through NeoRecall's companion OAuth flow. In NeoAgent, open
**Integrations**, select **NeoRecall**, and enter this server's base URL. The
browser then returns to NeoRecall for sign-in and explicit consent.

The issued access is limited to `search:read`, `memories:read`, and
`recordings:read`. PKCE is mandatory, refresh tokens rotate on every use, and
the authorization page shows the exact NeoAgent callback URL. NeoAgent cannot
upload audio, change memories, start consolidation, or call NeoRecall Ask.

Set `NEORECALL_PUBLIC_URL` to the externally reachable HTTPS origin when
NeoRecall is behind a reverse proxy. Local HTTP URLs remain suitable when both
services run on a trusted private host.
