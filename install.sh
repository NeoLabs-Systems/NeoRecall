#!/usr/bin/env bash
# NeoRecall installer: downloads the neorecall binary for this computer from the
# latest GitHub release and runs `neorecall install`. Existing data, including a
# Node.js installation's, is backed up and kept. The steps live in the shared
# NeoLabs installer; this only names the app.
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/NeoLabs-Systems/NeoRecall/main/install.sh)

set -euo pipefail

export APP_NAME=NeoRecall
export APP_CMD=neorecall
export APP_REPO=NeoLabs-Systems/NeoRecall
export APP_ENV=NEORECALL
export APP_DATA=data/neorecall.sqlite3
export APP_TARGETS="macos-x64 macos-arm64 linux-x64 linux-arm64"

SHARED="https://raw.githubusercontent.com/NeoLabs-Systems/neolabs-go/851626c3fb469a8bca9cee8aaa0e05aa30777df9/scripts/install-cli.sh"
if ! INSTALLER="$(curl -fsSL "$SHARED")" || [[ -z "$INSTALLER" ]]; then
  echo "Could not download the installer. Check the network and try again." >&2
  exit 1
fi
exec bash -c "$INSTALLER" neorecall-install
