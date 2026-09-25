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
downloaded or started; configure those services through `.env`, or in the app
under **Admin › Providers** after installation. The first account created on a
server is its admin.

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
neorecall reset-password USERNAME
neorecall reset-password USERNAME --password-file PATH
```

macOS uses a LaunchAgent and Linux uses a systemd user service when available. On unsupported service managers, `neorecall start` launches the supervisor directly.
