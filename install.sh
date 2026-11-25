#!/usr/bin/env bash
# NeoRecall installer: downloads the neorecall binary for this computer from the
# latest GitHub release and runs `neorecall install`. Existing Node.js or Go
# installations under $NEORECALL_HOME (or ~/.neorecall) keep all data and are
# automatically backed up and migrated.
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
  *) err "This installer supports macOS and Linux. On Windows, download neorecall-cli-windows-x64.exe from the release page."; exit 1 ;;
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
  info "Existing NeoRecall data found at ${RUNTIME_DIR}; it will be backed up and preserved."
fi

info "Looking up the latest release..."
if ! RELEASES="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${REPOSITORY}/releases?per_page=50")"; then
  err "Could not fetch releases from GitHub (network error or API rate limit). Wait a minute and try again."
  exit 1
fi
read -r URL DIGEST < <(printf '%s\n' "$RELEASES" | awk -v channel="$CHANNEL" -v want="neorecall-cli-${OS}-${ARCH}" '
  function trim_v(s) { sub(/^v/, "", s); return s }
  function is_semver(t) { return t ~ /^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$/ }
  function parse_ver(raw,    core_pre, core, pre, parts, n) {
    raw = trim_v(raw)
    n = index(raw, "-")
    if (n > 0) {
      core = substr(raw, 1, n - 1)
      pre = substr(raw, n + 1)
    } else {
      core = raw
      pre = ""
    }
    split(core, parts, ".")
    maj = parts[1] + 0; min = parts[2] + 0; pat = parts[3] + 0
    is_pre = (pre != "")
    pre_num = -1
    if (pre ~ /^beta\.[0-9]+$/) {
      pre_num = substr(pre, 6) + 0
    }
  }
  function cmp_ver(a, b,    amaj, amin, apat, apre, aprenum, bmaj, bmin, bpat, bpre, bprenum) {
    if (b == "") return 1
    parse_ver(a); amaj = maj; amin = min; apat = pat; apre = is_pre; aprenum = pre_num
    parse_ver(b); bmaj = maj; bmin = min; bpat = pat; bpre = is_pre; bprenum = pre_num
    if (amaj != bmaj) return (amaj > bmaj) ? 1 : -1
    if (amin != bmin) return (amin > bmin) ? 1 : -1
    if (apat != bpat) return (apat > bpat) ? 1 : -1
    if (!apre && bpre) return 1
    if (apre && !bpre) return -1
    if (aprenum >= 0 && bprenum >= 0 && aprenum != bprenum) return (aprenum > bprenum) ? 1 : -1
    if (a == b) return 0
    return (a > b) ? 1 : -1
  }
  function flush_release() {
    if (tag != "" && is_semver(tag) && !draft && (channel == "beta" || !pre) && cand_url != "") {
      if (cmp_ver(tag, best_tag) > 0) {
        best_tag = tag
        best_url = cand_url
        best_digest = (cand_digest == "" ? "-" : cand_digest)
      }
    }
  }
  /"tag_name":/ {
    flush_release()
    split($0, t, "\""); tag = t[4]
    draft = 0; pre = 0; digest = ""; cand_url = ""; cand_digest = ""
  }
  /"draft": true/ { draft = 1 }
  /"prerelease": true/ { pre = 1 }
  /"digest":/ { split($0, d, "\""); digest = d[4] }
  /"browser_download_url":/ {
    split($0, u, "\""); url = u[4]; n = split(url, parts, "/"); name = parts[n]
    if (index(name, want) == 1 && name !~ /\.(sig|json)$/) {
      cand_url = url
      cand_digest = digest
    }
    digest = ""
  }
  END {
    flush_release()
    if (best_url != "") {
      print best_url, best_digest
    }
  }') || true
if [[ -z "${URL:-}" ]]; then
  err "No NeoRecall ${CHANNEL} release has a CLI binary for ${OS}-${ARCH} yet."
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
    *bin/neo*call.js|*bin/neorecall.js) rm -f "$OLD_CLI"; info "Removed the legacy Node.js neorecall command at ${OLD_CLI}" ;;
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
exec "$BIN_DIR/neorecall" install --channel "$CHANNEL"
