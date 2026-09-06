#!/bin/bash
# Deploy a working copy of the appliance to a Pi and prove it came up.
#
#   ./deploy.sh neo@neorecall.local
#
# The developer loop for this device: package, copy, install, reboot, wait, and
# then actually check — rather than assuming that "the installer printed ok"
# means the hardware is there. Everything it verifies is something that has
# already gone wrong at least once.
#
# Needs key-based SSH. Set one up once with:
#   ssh-copy-id -i ~/.ssh/neorecall_desk.pub neo@neorecall.local
set -uo pipefail

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "usage: $0 user@host" >&2; exit 64; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="${NEORECALL_SSH_KEY:-$HOME/.ssh/neorecall_desk}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[ -f "$KEY" ] && SSH+=(-i "$KEY")

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31m  FAIL  %s\033[0m\n' "$*"; FAILURES=$((FAILURES + 1)); }
pass() { printf '\033[32m  ok    %s\033[0m\n' "$*"; }
FAILURES=0

remote() { "${SSH[@]}" "$TARGET" "$@"; }

say "Checking access"
if ! remote true 2>/dev/null; then
    cat >&2 <<NOTE
  Cannot reach $TARGET without a password.

  This script deliberately does not handle passwords. Install a key once:

      ssh-copy-id -i ${KEY}.pub $TARGET

  After that everything below runs unattended.
NOTE
    exit 1
fi
pass "connected"

# Unattended means unattended. Raspberry Pi OS gives its first user passwordless
# sudo, but an account made through Imager's customisation does not always get
# it — and `sudo -n` below fails instantly without saying why.
if ! remote 'sudo -n true' 2>/dev/null; then
    cat >&2 <<NOTE
  $TARGET can be reached, but sudo there asks for a password.

  This script does not handle passwords, so grant that one account passwordless
  sudo — once, on the Pi:

      echo "\$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/010_\$USER-nopasswd
      sudo chmod 440 /etc/sudoers.d/010_\$USER-nopasswd

  Then re-run this script. Everything after that is unattended.
NOTE
    exit 1
fi
pass "sudo without a password"

say "Packaging"
TARBALL="$(mktemp -t neorecall-desk).tar.gz"
trap 'rm -f "$TARBALL"' EXIT
tar czf "$TARBALL" -C "$HERE" \
    --exclude='__pycache__' --exclude='*.pyc' \
    --exclude='.pytest_cache' --exclude='.ruff_cache' --exclude='tests' \
    src pyproject.toml systemd pipewire overlays kernel install.sh diagnostics.sh README.md
pass "$(du -h "$TARBALL" | cut -f1)"

say "Copying and installing"
scp "${SSH[@]:1}" -q "$TARBALL" "$TARGET:/tmp/neorecall-desk.tar.gz" || { fail "copy"; exit 1; }
# shellcheck disable=SC2016  # $PWD is expanded on the Pi, not here
remote 'rm -rf ~/neorecall-desk && mkdir -p ~/neorecall-desk &&
        tar xzf /tmp/neorecall-desk.tar.gz -C ~/neorecall-desk &&
        cd ~/neorecall-desk && sudo -n NEORECALL_SOURCE=$PWD bash install.sh' || fail "install"

say "Rebooting"
# The audio HAT and the USB gadget are device-tree settings. Nothing below is
# meaningful until the Pi has come back with them applied.
remote 'sudo -n systemctl reboot' >/dev/null 2>&1
sleep 20
WAITED=0
until remote true 2>/dev/null; do
    WAITED=$((WAITED + 5))
    [ "$WAITED" -ge 180 ] && { fail "the Pi did not come back within three minutes"; exit 1; }
    sleep 5
done
pass "back after ${WAITED}s"

# SSH answers well before the neorecall account's user session exists, and the
# checks below live inside that session. Without this wait the script reported
# "PipeWire FAIL, appliance FAIL" on a machine that was merely still starting —
# a false alarm is worse than no check, because the next real one is ignored.
SESSION=0
while [ "$SESSION" -lt 90 ]; do
    remote 'sudo -n systemctl --user -M neorecall@ is-active neorecall-desk.service' \
        >/dev/null 2>&1 && break
    SESSION=$((SESSION + 5))
    sleep 5
done
[ "$SESSION" -ge 90 ] || pass "the appliance session came up after ${SESSION}s"

say "Verifying the hardware"
# Each of these is a thing that has to exist for the appliance to work at all,
# and each is checked on the device rather than inferred from an installer log.
check() {
    local label="$1" command="$2"
    if remote "$command" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}
check "WM8960 sound card"        "grep -qi wm8960 /proc/asound/cards"
check "microphones"              "arecord -l | grep -qi wm8960"
check "speakers"                 "aplay -l | grep -qi wm8960"
check "USB gadget controller"    "test -n \"\$(ls /sys/class/udc 2>/dev/null)\""
check "USB audio device"         "test -d /sys/kernel/config/usb_gadget/neorecall"
check "USB audio name override"  "/usr/sbin/modinfo -n usb_f_uac2 | grep -q /updates/dkms/"
# sudo, because reaching another account's user manager over the machine
# transport is a privileged operation. Without it these two reported FAIL on a
# perfectly healthy device, every single deploy — and a check that cries wolf is
# worse than no check, because the next real failure is read as noise too.
check "PipeWire"                 "sudo -n systemctl --user -M neorecall@ is-active pipewire.service"
check "the appliance service"    "sudo -n systemctl --user -M neorecall@ is-active neorecall-desk.service"
check "Bluetooth"                "systemctl is-active bluetooth"
check "automatic updates armed"  "systemctl is-enabled neorecall-desk-update.timer"

say "Diagnostics"
remote 'sudo -n /usr/local/lib/neorecall-desk/diagnostics.sh deploy -' > "$HERE/last-deploy-report.txt" 2>&1
pass "written to $HERE/last-deploy-report.txt"

echo
if [ "$FAILURES" -eq 0 ]; then
    printf '\033[32mEverything came up. Add the device in the NeoRecall app.\033[0m\n'
else
    printf '\033[31m%d check(s) failed. The report above says why.\033[0m\n' "$FAILURES"
fi
exit "$FAILURES"
