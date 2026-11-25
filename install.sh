#!/usr/bin/env bash
# NeoRecall installer: downloads the neorecall binary for this computer from the
# latest GitHub release and runs `neorecall install`. Existing runtime data under
# $NEORECALL_HOME (or ~/.neorecall) is preserved.
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/NeoLabs-Systems/NeoRecall/main/install.sh)

set -euo pipefail

REPOSITORY="NeoLabs-Systems/NeoRecall"

if [[ -t 1 ]]; then
  BOLD='\033[1m'; RESET='\033[0m'; RED='\033[1;31m'; GRN='\033[1;32m'
  CYN='\033[1;36m'; DIM='\033[2m'
else
  BOLD=''; RESET=''; RED=''; GRN=''; CYN=''; DIM=''
fi

ok()   { echo -e "  ${GRN}✓${RESET}  $*"; }
info() { echo -e "  ${CYN}→${RESET}  $*"; }
err()  { echo -e "  ${RED}✗${RESET}  $*" >&2; }

echo -e "${CYN}${BOLD}NeoRecall installer${RESET}"
echo

case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
  *) err "This installer supports macOS and Linux. On Windows, use the desktop app installer."; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  ARCH="x64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) err "NeoRecall is not available for this processor ($(uname -m))."; exit 1 ;;
esac
command -v curl &>/dev/null || { err "curl is required."; exit 1; }

CHANNEL="${NEORECALL_RELEASE_CHANNEL:-}"
if [[ -z "$CHANNEL" && -r /dev/tty && -t 1 ]]; then
  echo -ne "  ${CYN}?${RESET}  Release channel (stable/beta) ${DIM}[stable]${RESET} "
  read -r CHANNEL </dev/tty || true
fi
CHANNEL="$(echo "${CHANNEL:-stable}" | tr '[:upper:]' '[:lower:]')"
[[ "$CHANNEL" == "beta" ]] || CHANNEL="stable"
ok "Channel: ${CHANNEL}"

RUNTIME_DIR="${NEORECALL_HOME:-$HOME/.neorecall}"
if [[ -f "$RUNTIME_DIR/data/neorecall.sqlite3" || -f "$RUNTIME_DIR/.env" ]]; then
  info "Existing NeoRecall data found at ${RUNTIME_DIR}; it will be preserved."
fi

info "Looking up the latest release..."
RELEASES="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${REPOSITORY}/releases?per_page=20")"
read -r URL DIGEST < <(printf '%s\n' "$RELEASES" | awk -v channel="$CHANNEL" -v want="neorecall-cli-${OS}-${ARCH}" '
  /"tag_name":/ { draft = 0; pre = 0; digest = "" }
  /"draft": true/ { draft = 1 }
  /"prerelease": true/ { pre = 1 }
  /"digest":/ { split($0, d, "\""); digest = d[4] }
  /"browser_download_url":/ {
    split($0, u, "\""); url = u[4]; n = split(url, parts, "/"); name = parts[n]
    if (!draft && (channel == "beta" || !pre) && index(name, want) == 1 && name !~ /\.(sig|json)$/) {
      print url, (digest == "" ? "-" : digest); exit
    }
    digest = ""
  }')
if [[ -z "${URL:-}" ]]; then
  err "No NeoRecall ${CHANNEL} release has a binary for ${OS}-${ARCH} yet."
  exit 1
fi

BIN_DIR="${NEORECALL_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
TMP="$(mktemp "${BIN_DIR}/.neorecall.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
info "Downloading ${URL##*/}..."
curl -fSL --proto '=https' --progress-bar -o "$TMP" "$URL"
if [[ "$DIGEST" == sha256:* ]]; then
  if command -v sha256sum &>/dev/null; then SUM="$(sha256sum "$TMP" | awk '{print $1}')"; else SUM="$(shasum -a 256 "$TMP" | awk '{print $1}')"; fi
  if [[ "sha256:${SUM}" != "$DIGEST" ]]; then
    err "The download did not match its published checksum; nothing was installed."
    exit 1
  fi
  ok "Checksum verified"
fi
chmod 755 "$TMP"
if [[ "$OS" == "macos" ]]; then
  xattr -d com.apple.quarantine "$TMP" 2>/dev/null || true
fi
mv -f "$TMP" "$BIN_DIR/neorecall"
trap - EXIT
ok "Installed ${BIN_DIR}/neorecall"

# Remove any stale npm symlink from the previous Node.js CLI so it cannot shadow Go.
OLD_CLI="$(command -v neorecall 2>/dev/null || true)"
if [[ -n "$OLD_CLI" && "$OLD_CLI" != "$BIN_DIR/neorecall" && -L "$OLD_CLI" ]]; then
  case "$(readlink "$OLD_CLI")" in
    *bin/neorecall.js) rm -f "$OLD_CLI"; info "Removed the legacy Node.js neorecall command at ${OLD_CLI}" ;;
  esac
fi

case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *)
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      if [[ -f "$rc" || "$rc" == "$HOME/.bashrc" ]] && ! grep -qs "${BIN_DIR}" "$rc"; then
        printf '\n# Added by the neorecall installer\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$rc"
      fi
    done
    if [[ -d "$HOME/.config/fish" ]]; then
      mkdir -p "$HOME/.config/fish/conf.d"
      printf 'fish_add_path %s\n' "$BIN_DIR" > "$HOME/.config/fish/conf.d/neorecall.fish"
    fi
    export PATH="${BIN_DIR}:$PATH"
    info "Added ${BIN_DIR} to PATH (open a new terminal to use neorecall there)"
    ;;
esac
hash -r

echo
exec "$BIN_DIR/neorecall" install
