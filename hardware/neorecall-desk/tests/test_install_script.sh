#!/bin/bash
# Checks on install.sh that do not need a Raspberry Pi.
#
# The installer is the least testable and most consequential part of this
# project, and its failures have been expensive: a guard that never fired
# rebuilt a kernel module on every run, a batch apt call let one renamed package
# take fifteen others down, and a text substitution that silently did not apply
# left a service installed but never started. These are the cheap checks that
# would have caught them.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/install.sh"
FAILURES=0

check() {
    local label="$1"; shift
    if "$@"; then
        printf '  ok    %s\n' "$label"
    else
        printf '  FAIL  %s\n' "$label"
        FAILURES=$((FAILURES + 1))
    fi
}

# grep is line-based, and this script wraps long commands across continuations.
# Join them first, or a check silently tests the wrong thing — which is the exact
# class of bug these checks exist to catch.
JOINED="$(mktemp)"
trap 'rm -f "$JOINED"' EXIT
sed -e :a -e '/\\$/N; s/\\\n */ /; ta' "$SCRIPT" > "$JOINED"

matches() { grep -qE "$1" "$JOINED"; }
absent()  { ! grep -qE "$1" "$JOINED"; }
before() {
    local first second
    first="$(grep -nE "$1" "$JOINED" | head -1 | cut -d: -f1)"
    second="$(grep -nE "$2" "$JOINED" | head -1 | cut -d: -f1)"
    [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]
}

echo "install.sh checks"

check "it parses" bash -n "$SCRIPT"

# The module is snd_soc_wm8960_soundcard; the short name never matches, and a
# guard that never matches means a fifteen-minute rebuild on every install.
check "the codec guard matches the real module name" \
    matches 'snd_soc_wm8960_soundcard'
# dkms can call a driver "installed" after a build that was interrupted halfway.
# Asking the kernel whether it has the module is the question that matters.
# A module file that exists is not a sound card. A kernel upgrade leaves exactly
# that behind: DKMS built against the kernel that was running at the time.
check "the codec guard checks for the card, not for a file" \
    matches '/proc/asound/cards'
check "the codec guard also requires the module to be loaded" \
    matches '\^snd_soc_wm8960_soundcard.*/proc/modules|/proc/modules'
# modinfo may still appear — it explains *why* a rebuild is happening — but it
# must never be what decides.
check "modinfo does not decide whether to rebuild" absent 'if modinfo'
check "a rebuild after a kernel upgrade explains itself" matches 'kernel upgrade'
check "the uninterruptible build says so before it starts" \
    matches 'must not be interrupted'

# One renamed package must never take the rest of the install with it.
check "packages are retried one at a time" matches 'install_candidate'
check "kernel headers have alternatives" matches 'linux-headers.*\|raspberrypi-kernel-headers'

# The macOS-visible name comes from a module override. It must be maintained by
# DKMS across kernel updates, and failure must leave the stock audio module in
# place rather than turn a cosmetic fix into a dead sound card.
# shellcheck disable=SC2016 # The patterns intentionally match literal shell variables.
check "the UAC2 name override is added to DKMS" \
    matches 'dkms add -m "\$UAC2_DKMS_NAME"'
check "the UAC2 name override is built for the running kernel" \
    matches 'dkms build -m "\$UAC2_DKMS_NAME".*uname -r'
check "the UAC2 name override is installed for the running kernel" \
    matches 'dkms install --force -m "\$UAC2_DKMS_NAME"'
check "a UAC2 build failure explicitly retains the stock driver" \
    matches 'stock driver remains available'
check "the relay stops before the active UAC2 module is released" \
    before 'stop neorecall-desk-relay\.service' 'modprobe -r usb_f_uac2'
check "diagnostics require the selected DKMS path" \
    grep -q '/updates/dkms/' "$HERE/src/neorecall_desk/audio/selftest.py"

# apt refuses instantly when another process holds the lock.
check "it waits for the package manager" matches 'wait_for_package_manager'
check "it lets apt wait for the dpkg lock" matches 'DPkg::Lock::Timeout'

# A silent step is indistinguishable from a hang.
check "the slow apt step is not silenced with -qq" \
    absent 'apt_with_retry install -y -qq'

# Every service the installer lays down has to be started, not merely enabled.
for unit in neorecall-desk neorecall-desk-relay; do
    check "$unit is started" matches "enable --now +${unit}\\.service"
done

# --global enables a user unit for *every* account, so an administrator's SSH
# login silently started a second supervisor competing for the button, the codec
# and the Bluetooth adapter. Found on hardware; it must not come back.
check "the appliance is not enabled for every account" \
    absent 'global enable +neorecall-desk'
check "an earlier global enablement is undone" \
    matches 'global disable neorecall-desk\.service neorecall-desk-relay\.service'

# `systemctl start` on an active RemainAfterExit unit does nothing at all.
check "the USB gadget is torn down before being rebuilt" \
    matches 'neorecall-usb-gadget.sh" stop'

# Echo cancellation was promised in the README for months while nothing
# implemented it. The backend it needs must not drift back into "optional".
# ESSENTIAL lists packages bare; OPTIONAL quotes them because its entries carry
# "a|b" alternatives. So an unquoted entry is exactly the required form.
check "the echo canceller's backend is required" \
    matches '(^| )libspa-0\.2-modules($| )'
check "the echo canceller's backend is not merely optional" \
    absent '"libspa-0\.2-modules"'

# The installer is one half of the fix; the units themselves are the half that
# still holds if somebody enables them by hand.
for unit in neorecall-desk.service neorecall-desk-relay.service; do
    if grep -q '^ConditionUser=neorecall$' "$HERE/systemd/$unit"; then
        echo "  ok    $unit refuses to run for another account"
    else
        echo "  FAIL  $unit is missing ConditionUser=neorecall"
        FAILURES=$((FAILURES + 1))
    fi
done

# The hourly report has to be able to tell a working microphone from a dead one,
# and it has to do it without making a sound: an appliance that beeps at a room
# once an hour to reassure itself is worse than one that stays quiet.
if grep -q "s MICROPHONE_HEALTH" "$HERE/diagnostics.sh"; then
    echo "  ok    the report checks the microphone"
else
    echo "  FAIL  the report never checks whether audio reaches the codec"
    FAILURES=$((FAILURES + 1))
fi
if grep -qE "pw-play|pw-cat --playback" "$HERE/diagnostics.sh"; then
    echo "  FAIL  the periodic report plays audible sound"
    FAILURES=$((FAILURES + 1))
else
    echo "  ok    the report stays silent"
fi

# The updater runs install.sh out of the tarball CI builds. A path the installer
# reads but the tarball omits is not a build failure — it is a broken appliance,
# delivered automatically, to every device.
WORKFLOW="$HERE/../../.github/workflows/build-appliance.yml"
if [ -f "$WORKFLOW" ]; then
    SHIPPED=$(sed -n '/tar czf/,/SHA=/p' "$WORKFLOW")
    MISSING=""
    for path in $(grep -o '\$SRC/[a-zA-Z0-9_./-]*' "$HERE/install.sh" \
                  | sed 's|\$SRC/||' | cut -d/ -f1 | sort -u); do
        [ -n "$path" ] || continue
        case "$SHIPPED" in *"$path"*) ;; *) MISSING="$MISSING $path" ;; esac
    done
    if [ -z "$MISSING" ]; then
        echo "  ok    the update tarball ships everything the installer reads"
    else
        echo "  FAIL  the update tarball omits:$MISSING"
        FAILURES=$((FAILURES + 1))
    fi
fi

# Reaching another account's user manager needs root; without sudo these
# checks reported FAIL on a healthy device on every deploy.
for probe in pipewire neorecall-desk; do
    if grep -q "sudo -n systemctl --user -M neorecall@ is-active ${probe}.service" "$HERE/deploy.sh"; then
        echo "  ok    the $probe check runs with the privilege it needs"
    else
        echo "  FAIL  the $probe check would report a false failure"
        FAILURES=$((FAILURES + 1))
    fi
done

# Without this the Bluetooth monitor never starts on a device nobody logs in
# to, and paired headphones are refused with "br-connection-profile-unavailable".
check "the headless audio profile is installed" \
    matches '40-neorecall-headless\.conf'
if grep -q 'monitor.bluez.seat-monitoring = disabled' "$HERE/pipewire/40-neorecall-headless.conf"; then
    echo "  ok    Bluetooth audio does not wait for a login session"
else
    echo "  FAIL  Bluetooth audio still waits for a login session"
    FAILURES=$((FAILURES + 1))
fi

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES check(s) failed."
    exit 1
fi
echo "All install.sh checks passed."
