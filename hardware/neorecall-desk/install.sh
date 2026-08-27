#!/bin/bash
# NeoRecall Desk — installer and updater.
#
#   curl -fsSL https://neorecall.dev/desk | sudo bash
#
# One script for both jobs. Installing and updating differ only in what is
# already there, so making them one code path means the update route is exercised
# every single time anyone installs — rather than being the path nobody runs
# until it matters.
#
# It is safe to re-run at any time. Every step is idempotent, and a recording in
# progress blocks nothing except the service restart at the end.
#
# Trust model: the manifest is fetched over HTTPS from a pinned GitHub release,
# and the source tarball is verified against the SHA-256 in that manifest before
# a single file is unpacked. A tarball that does not match is refused.
set -uo pipefail

REPO="${NEORECALL_REPO:-NeoLabs-Systems/NeoRecall}"
CHANNEL="${NEORECALL_CHANNEL:-desk-latest}"
MANIFEST_URL="${NEORECALL_MANIFEST:-https://github.com/$REPO/releases/download/$CHANNEL/manifest.json}"

ROOT=/usr/local/lib/neorecall-desk
SRC="$ROOT/src"
VENV="$ROOT/venv"
STATE=/var/lib/neorecall-desk
BOOT=/boot/firmware
LOG=/var/log/neorecall-desk-install.log

MODE=install
[ "${1:-}" = "--update" ] && MODE=update

# Set by any step whose effect only exists after a restart.
REBOOT_NEEDED=0

# --------------------------------------------------------------------- output

# Always print; append to the log only when it is writable. Running this without
# sudo should produce one clear sentence, not a permission error about a log file
# nobody asked about.
_say() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$1"; [ -w "$LOG" ] && printf '%s  %s\n' "$(date '+%H:%M:%S')" "$1" >> "$LOG"; return 0; }
log()  { _say "$*"; }
warn() { _say "WARNING: $*" >&2; }
die()  { _say "ERROR: $*" >&2; exit 1; }

# Never abort the whole run for one optional step: a box that records but has no
# Bluetooth is worth more than no box, and the note says which it is.
step() {
    local label="$1"; shift
    if "$@" >>"$LOG" 2>&1; then
        log "ok    $label"
        return 0
    fi
    warn "failed: $label"
    return 1
}

# ---------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || die "run this with sudo:  curl -fsSL https://raw.githubusercontent.com/NeoLabs-Systems/NeoRecall/beta/hardware/neorecall-desk/install.sh | sudo bash"
mkdir -p "$(dirname "$LOG")" "$STATE"
touch "$LOG" 2>/dev/null

ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [ "$ARCH" != "arm64" ]; then
    # Not fatal, but worth saying plainly: on 32-bit ARM none of the Python
    # dependencies ship a wheel, so this will compile them and take far longer.
    warn "this is $ARCH, not arm64. Everything will be built from source and the install will take much longer. A 64-bit Raspberry Pi OS is strongly recommended."
fi

log "NeoRecall Desk $MODE starting (arch $ARCH)"

# ------------------------------------------------------------------- fetch

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch_release() {
    log "reading $MANIFEST_URL"
    curl -fsSL "$MANIFEST_URL" -o "$TMP/manifest.json" || return 1

    VERSION="$(python3 -c "import json;print(json.load(open('$TMP/manifest.json'))['version'])" 2>/dev/null)"
    TARBALL="$(python3 -c "import json;print(json.load(open('$TMP/manifest.json'))['url'])" 2>/dev/null)"
    WANT_SHA="$(python3 -c "import json;print(json.load(open('$TMP/manifest.json'))['sha256'])" 2>/dev/null)"
    [ -n "$VERSION" ] && [ -n "$TARBALL" ] && [ -n "$WANT_SHA" ] || return 1

    INSTALLED="$(cat "$ROOT/VERSION" 2>/dev/null || echo none)"
    if [ "$MODE" = update ] && [ "$VERSION" = "$INSTALLED" ]; then
        log "already on $VERSION; nothing to do"
        exit 0
    fi

    log "fetching $VERSION"
    curl -fsSL "$TARBALL" -o "$TMP/source.tar.gz" || return 1

    local got
    got="$(sha256sum "$TMP/source.tar.gz" | cut -d' ' -f1)"
    if [ "$got" != "$WANT_SHA" ]; then
        die "the downloaded source does not match the checksum in the manifest. Refusing to install it."
    fi
    log "checksum verified"
    return 0
}

if [ -n "${NEORECALL_SOURCE:-}" ]; then
    # Bring-up and development: install from a local tree or tarball instead of a
    # release. Nothing else about the run changes.
    log "installing from $NEORECALL_SOURCE"
    mkdir -p "$TMP/unpacked"
    if [ -d "$NEORECALL_SOURCE" ]; then
        cp -R "$NEORECALL_SOURCE/." "$TMP/unpacked/"
    else
        tar xzf "$NEORECALL_SOURCE" -C "$TMP/unpacked"
    fi
    VERSION="local-$(date +%s)"
elif fetch_release; then
    mkdir -p "$TMP/unpacked"
    tar xzf "$TMP/source.tar.gz" -C "$TMP/unpacked"
else
    die "could not fetch the release. Check the network, or set NEORECALL_SOURCE to a local copy."
fi

[ -f "$TMP/unpacked/pyproject.toml" ] || die "the downloaded source does not look like the appliance."

# ----------------------------------------------------- do not interrupt a take

if [ "$MODE" = update ] && [ -f "$STATE/ledger.sqlite3" ]; then
    ACTIVE="$(sqlite3 "$STATE/ledger.sqlite3" \
        "select count(*) from sessions where status='active'" 2>/dev/null || echo 0)"
    if [ "${ACTIVE:-0}" -gt 0 ]; then
        # Restarting mid-recording would cut a conversation in half for a version
        # bump nobody asked for right now. The timer comes back in an hour.
        log "a recording is in progress; postponing this update"
        exit 0
    fi
fi

# ---------------------------------------------------------------- packages

# Two lists, and alternatives, because Debian renames things between releases
# and a name that vanished must not take the whole install down with it.
#
# Essential: without these the appliance cannot record or be controlled.
# Optional: diagnostics and the hardware button. Nice to have, never fatal.
ESSENTIAL=(
    python3-venv python3-pip python3-numpy python3-cbor2 python3-requests
    python3-dbus python3-gi
    pipewire pipewire-pulse wireplumber libspa-0.2-bluetooth
    # Carries the WebRTC echo canceller. Without it the canceller module loads,
    # reports nothing wrong, and subtracts no echo at all — so it is required
    # rather than optional, even though PipeWire happens to pull it in today.
    libspa-0.2-modules
    bluez alsa-utils network-manager sqlite3 curl avahi-daemon
)
# "a|b" means: try a, fall back to b. Trixie renamed the PipeWire metapackage and
# moved libgpiod to a new soname; Bookworm still has the older names.
OPTIONAL=(
    "pipewire-audio|pipewire-audio-client-libraries"
    "bluez-tools" "i2c-tools" "usbutils"
    "gpiod" "libgpiod3|libgpiod2" "python3-libgpiod"
)

have() { dpkg -s "$1" >/dev/null 2>&1; }

# Wait until nothing else is using the package manager.
#
# This is not defensive padding. A freshly booted cloud-init system is usually
# still installing packages of its own, and two apt processes cannot share the
# dpkg lock — the second one fails instantly. That is exactly what happened the
# first time this installer ran on real hardware: `apt update` succeeded, and
# `apt install` failed two seconds later.
wait_for_package_manager() {
    if command -v cloud-init >/dev/null 2>&1; then
        log "waiting for cloud-init to finish its own work"
        timeout 600 cloud-init status --wait >/dev/null 2>&1
    fi
    if ! command -v flock >/dev/null 2>&1; then
        # Nothing to wait with. cloud-init --wait above covers the usual cause,
        # and apt_with_retry covers the rest.
        return 0
    fi
    local waited=0
    while ! flock -n /var/lib/dpkg/lock-frontend true 2>/dev/null; do
        [ "$waited" -eq 0 ] && log "another package manager is running; waiting for it"
        if [ "$waited" -ge 600 ]; then
            warn "the package manager has been busy for ten minutes; carrying on anyway"
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    [ "$waited" -gt 0 ] && log "ok    the package manager is free after ${waited}s"
    return 0
}

# apt can still lose a race in the moment between the check above and the call
# below, so a refusal is retried rather than believed the first time.
apt_with_retry() {
    local attempt
    for attempt in 1 2 3; do
        if env DEBIAN_FRONTEND=noninteractive apt-get \
            -o DPkg::Lock::Timeout=300 "$@" >>"$LOG" 2>&1; then
            return 0
        fi
        [ "$attempt" -lt 3 ] && { log "apt was busy; retrying in 15s"; sleep 15; }
    done
    return 1
}

apt_install_one() {
    apt_with_retry install -y --no-install-recommends "$1"
}

# Try each candidate in an "a|b" alternative until one works.
install_candidate() {
    local spec="$1" candidate
    while IFS= read -r candidate; do
        [ -z "$candidate" ] && continue
        have "$candidate" && return 0
        apt_install_one "$candidate" && return 0
    done < <(printf '%s\n' "${spec//|/$'\n'}")
    return 1
}

NEEDED=0
for spec in "${ESSENTIAL[@]}" "${OPTIONAL[@]}"; do
    have "${spec%%|*}" || NEEDED=1
done

if [ "$NEEDED" -eq 1 ]; then
    wait_for_package_manager
    step "apt update" apt_with_retry update -qq
    # The batch first, because one transaction is much faster than thirty. If it
    # fails, fall back to one at a time so a single bad name costs one package
    # rather than all of them — and so the log names it.
    log "downloading and installing ${#ESSENTIAL[@]} packages — this is the slow part"
    log "      watch it with: tail -f $LOG"
    if ! apt_with_retry install -y --no-install-recommends "${ESSENTIAL[@]}"; then
        warn "the batch install failed; retrying one package at a time"
    fi

    MISSING_ESSENTIAL=()
    for package in "${ESSENTIAL[@]}"; do
        install_candidate "$package" || MISSING_ESSENTIAL+=("$package")
    done
    MISSING_OPTIONAL=()
    for spec in "${OPTIONAL[@]}"; do
        install_candidate "$spec" || MISSING_OPTIONAL+=("${spec%%|*}")
    done

    if [ ${#MISSING_ESSENTIAL[@]} -gt 0 ]; then
        warn "these are missing and the appliance needs them: ${MISSING_ESSENTIAL[*]}"
        warn "the end of $LOG says why"
    else
        log "ok    all essential packages present"
    fi
    [ ${#MISSING_OPTIONAL[@]} -gt 0 ] && \
        log "note  not available on this Debian: ${MISSING_OPTIONAL[*]}"
else
    log "ok    all packages already present"
fi

# ----------------------------------------------------------------- account

if ! id neorecall >/dev/null 2>&1; then
    step "create the neorecall account" \
        adduser --system --group --home "$STATE" --shell /usr/sbin/nologin neorecall
fi
for group in audio bluetooth netdev gpio video render plugdev; do
    adduser neorecall "$group" >/dev/null 2>&1 || true
done
mkdir -p "$STATE/pending_audio"
chown -R neorecall:neorecall "$STATE"
chmod 0700 "$STATE"
step "enable lingering" loginctl enable-linger neorecall

# ------------------------------------------------------------------ sources

rm -rf "$SRC"
mkdir -p "$SRC"
cp -R "$TMP/unpacked/." "$SRC/"

# ------------------------------------------------------- USB audio name driver
# macOS gives AudioStreaming's iInterface string precedence over the USB product
# name. The upstream UAC2 function hardcodes those four strings as Playback /
# Capture Active / Inactive, so ConfigFS cannot correct them by itself. This
# small DKMS override retains the upstream module and changes only those strings
# to the function_name already configured by neorecall-usb-gadget.sh.
UAC2_DKMS_NAME=neorecall-uac2-name
UAC2_DKMS_VERSION=1.0.0
UAC2_DKMS_SOURCE="$SRC/kernel/$UAC2_DKMS_NAME"
UAC2_DKMS_TARGET="/usr/src/$UAC2_DKMS_NAME-$UAC2_DKMS_VERSION"
UAC2_DKMS_INSTALLED=0

wait_for_package_manager
UAC2_BUILD_TOOLS_MISSING=()
for spec in dkms build-essential \
    "linux-headers-$(uname -r)|raspberrypi-kernel-headers|linux-headers-rpi-v8|linux-headers-rpi-2712"; do
    install_candidate "$spec" || UAC2_BUILD_TOOLS_MISSING+=("${spec%%|*}")
done

if [ ${#UAC2_BUILD_TOOLS_MISSING[@]} -gt 0 ]; then
    warn "the USB audio name override cannot be built; missing: ${UAC2_BUILD_TOOLS_MISSING[*]}"
    warn "USB audio will use the stock driver, so macOS may show Playback/Capture Inactive"
elif [ ! -f "$UAC2_DKMS_SOURCE/dkms.conf" ]; then
    warn "the release does not contain the USB audio name driver; using the stock driver"
elif [ -d "$UAC2_DKMS_TARGET" ] &&
     diff -qr "$UAC2_DKMS_SOURCE" "$UAC2_DKMS_TARGET" >/dev/null 2>&1 &&
     dkms status -m "$UAC2_DKMS_NAME" -v "$UAC2_DKMS_VERSION" \
         -k "$(uname -r)" 2>/dev/null | grep -q 'installed'; then
    UAC2_DKMS_INSTALLED=1
    log "ok    USB audio name override already installed for $(uname -r)"
else
    # Replacing our own version is deliberate and scoped. The Raspberry Pi
    # kernel package's module is never removed, so it remains the fallback even
    # when add/build/install below cannot complete.
    dkms remove -m "$UAC2_DKMS_NAME" -v "$UAC2_DKMS_VERSION" --all \
        >>"$LOG" 2>&1 || true
    rm -rf /usr/src/neorecall-uac2-name-1.0.0
    install -d "$UAC2_DKMS_TARGET"
    cp -R "$UAC2_DKMS_SOURCE/." "$UAC2_DKMS_TARGET/"
    if dkms add -m "$UAC2_DKMS_NAME" -v "$UAC2_DKMS_VERSION" >>"$LOG" 2>&1 &&
       dkms build -m "$UAC2_DKMS_NAME" -v "$UAC2_DKMS_VERSION" \
           -k "$(uname -r)" >>"$LOG" 2>&1 &&
       dkms install --force -m "$UAC2_DKMS_NAME" -v "$UAC2_DKMS_VERSION" \
           -k "$(uname -r)" >>"$LOG" 2>&1; then
        depmod -a "$(uname -r)" >>"$LOG" 2>&1
        UAC2_DKMS_INSTALLED=1
        log "ok    USB audio name override built and installed for $(uname -r)"
    else
        warn "the USB audio name override did not build; the stock driver remains available"
        warn "USB audio will keep working, but macOS may show Playback/Capture Inactive"
        depmod -a "$(uname -r)" >>"$LOG" 2>&1 || true
    fi
fi

# ------------------------------------------------------------------- python

[ -x "$VENV/bin/python" ] || step "create the virtualenv" \
    python3 -m venv --system-site-packages "$VENV"
step "install the appliance" "$VENV/bin/pip" install --no-cache-dir --upgrade "$SRC"

# Optional, and separate on purpose: a missing wheel costs one feature, never
# the whole install.
"$VENV/bin/pip" install --no-cache-dir "${SRC}[bluetooth]" >>"$LOG" 2>&1
if "$VENV/bin/python" -c "import dbus_fast" 2>/dev/null; then
    log "ok    Bluetooth support"
else
    warn "no dbus-fast: the appliance will record but the app cannot control it"
fi
"$VENV/bin/pip" install --no-cache-dir "${SRC}[gpio]" >>"$LOG" 2>&1
if "$VENV/bin/python" -c "import gpiod" 2>/dev/null; then
    log "ok    hardware button"
else
    warn "no gpiod: the hardware button is disabled, the app still works"
fi

# ------------------------------------------------------------- configuration

install -d /etc/wireplumber/wireplumber.conf.d
install -m 0644 "$SRC/pipewire/40-neorecall-headless.conf" /etc/wireplumber/wireplumber.conf.d/
install -m 0644 "$SRC/pipewire/50-neorecall-bluetooth.conf" /etc/wireplumber/wireplumber.conf.d/
# The relay and the echo canceller used to live in /etc/pipewire/pipewire.conf.d.
# On hardware those drop-ins were silently ignored — right place, right modules,
# no error, no nodes — so they are a supervised service now. Remove them rather
# than leave files behind that look like they are doing something.
rm -f /etc/pipewire/pipewire.conf.d/20-neorecall-echo-cancel.conf \
      /etc/pipewire/pipewire.conf.d/30-neorecall-relay.conf \
      /etc/wireplumber/wireplumber.conf.d/10-neorecall-names.conf
log "ok    audio graph"

install -d /etc/systemd/user /etc/polkit-1/rules.d /etc/dbus-1/system.d
install -m 0755 "$SRC/systemd/neorecall-usb-gadget.sh" "$ROOT/neorecall-usb-gadget.sh"
install -m 0644 "$SRC/systemd/neorecall-usb-gadget.service" /etc/systemd/system/
install -m 0644 "$SRC/systemd/neorecall-desk.service" /etc/systemd/user/
install -m 0644 "$SRC/systemd/neorecall-desk-relay.service" /etc/systemd/user/
install -m 0644 "$SRC/systemd/neorecall-desk.tmpfiles" /etc/tmpfiles.d/neorecall-desk.conf
# Renamed: the rules cover the appliance's own units as well as the network now.
# Removing the old file matters — polkit reads every file in the directory, and
# two rule sets for the same account is a question about which one wins.
rm -f /etc/polkit-1/rules.d/10-neorecall-network.rules
install -m 0644 "$SRC/systemd/10-neorecall.rules" /etc/polkit-1/rules.d/
install -m 0644 "$SRC/systemd/neorecall-desk.dbus.conf" /etc/dbus-1/system.d/neorecall-desk.conf
install -m 0644 "$SRC/systemd/neorecall-desk-update.service" /etc/systemd/system/
install -m 0644 "$SRC/systemd/neorecall-desk-update.timer" /etc/systemd/system/
install -m 0755 "$SRC/install.sh" "$ROOT/install.sh"
install -m 0755 "$SRC/diagnostics.sh" "$ROOT/diagnostics.sh"
# A device with no screen cannot ask "did that sound right?", so it checks its
# own speakers by listening for its own tone.
ln -sf "$VENV/bin/neorecall-desk-selftest" /usr/local/bin/neorecall-desk-selftest 2>/dev/null || true
install -m 0644 "$SRC/systemd/neorecall-desk-diagnostics.service" /etc/systemd/system/
install -m 0644 "$SRC/systemd/neorecall-desk-diagnostics.timer" /etc/systemd/system/
printf 'dwc2\nlibcomposite\n' > /etc/modules-load.d/neorecall-desk.conf
log "ok    services and permissions"

install -d /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-neorecall.conf <<'JOURNAL'
[Journal]
Storage=persistent
SystemMaxUse=200M
JOURNAL

# --------------------------------------------------- the WM8960 codec driver
# Raspberry Pi OS ships a `wm8960-soundcard` overlay, and it is tempting to stop
# there: the card enumerates, ALSA negotiates a rate, playback reports success.
# It is also silent, because `simple-audio-card` never configures the codec's
# PLL — the DAC has no system clock, so it accepts samples and converts nothing.
# Every mixer control can be set correctly and the room stays quiet.
#
# Waveshare's own driver is a machine driver that does configure the clock, which
# is why their installation procedure builds it rather than relying on the
# overlay. Pinned to a commit, because a build that changes underneath a fleet is
# not a build anybody can support.
WM8960_REPO="https://github.com/waveshareteam/WM8960-Audio-HAT"
WM8960_COMMIT="d63599e885121b0a41e7c82c9158b92281e454e8"

# The module is called snd_soc_wm8960_soundcard, not wm8960_soundcard. Matching
# the wrong name meant this guard never fired and the driver was rebuilt from
# scratch on every single install — fifteen minutes of DKMS each time, for
# nothing. Match the module, and fall back to asking dkms, so a driver that is
# built but not currently loaded also counts.
# Ask whether the sound card is *there*, not whether a file is.
#
# Every weaker version of this check has already failed. `lsmod` only says what
# is loaded right now. `dkms status` calls a driver installed after a build that
# was interrupted halfway. And `modinfo` finds a module that exists but will not
# load — which is exactly what a kernel upgrade leaves behind, because DKMS built
# against the kernel that was running at the time.
#
# The card in /proc/asound is the only evidence that the driver is doing its job.
if grep -qi wm8960 /proc/asound/cards 2>/dev/null &&
   grep -q "^snd_soc_wm8960_soundcard" /proc/modules 2>/dev/null; then
    log "ok    the WM8960 sound card is present and driven by its own module"
elif [ "${NEORECALL_SKIP_CODEC_DRIVER:-0}" = "1" ]; then
    log "note  skipping the WM8960 driver at your request"
else
    # Only to explain the rebuild, never to decide it: a module that exists but
    # produces no sound card is the signature of a kernel upgrade, because DKMS
    # built against whichever kernel was running at the time.
    STALE_MODULE=""
    modinfo -n snd_soc_wm8960_soundcard >/dev/null 2>&1 && STALE_MODULE=yes
    if [ -n "$STALE_MODULE" ]; then
        log "note  a WM8960 module exists but the card is not there — rebuilding it"
        log "      (a kernel upgrade to $(uname -r) is the usual reason)"
    fi
    wait_for_package_manager
    # One at a time, with alternatives. The kernel headers package has been
    # renamed across Raspberry Pi OS releases, and a batch install would let that
    # one name take dkms, git and the compiler down with it — which is exactly
    # what happened the first time this ran.
    CODEC_TOOLS_MISSING=()
    for spec in dkms git build-essential \
        "linux-headers-$(uname -r)|raspberrypi-kernel-headers|linux-headers-rpi-v8|linux-headers-rpi-2712"; do
        install_candidate "$spec" || CODEC_TOOLS_MISSING+=("${spec%%|*}")
    done
    if [ ${#CODEC_TOOLS_MISSING[@]} -gt 0 ]; then
        warn "missing build tools for the codec driver: ${CODEC_TOOLS_MISSING[*]}"
    else
        log "ok    build tools for the codec driver"
    fi

    CODEC_SRC="$ROOT/wm8960-driver"
    if ! command -v git >/dev/null 2>&1 || ! command -v dkms >/dev/null 2>&1; then
        warn "git or dkms is missing, so the codec driver cannot be built. Without it the WM8960 enumerates but stays silent."
        CODEC_SRC=""
    elif [ ! -d "$CODEC_SRC/.git" ]; then
        rm -rf "$CODEC_SRC"
        step "fetch the WM8960 driver" git clone --quiet "$WM8960_REPO" "$CODEC_SRC"
    fi
    if [ -n "$CODEC_SRC" ] && [ -d "$CODEC_SRC/.git" ]; then
        ( cd "$CODEC_SRC" && git fetch --quiet --all && git checkout --quiet "$WM8960_COMMIT" ) \
            >>"$LOG" 2>&1 || warn "could not pin the driver to $WM8960_COMMIT"
        # Their installer appends its own overlay lines to config.txt; ours are
        # already there and identical in effect, so the duplicates are harmless.
        # Do not interrupt this. The vendor's installer removes the existing
        # driver before compiling the replacement, so a build stopped halfway
        # leaves a device with no working codec at all — worse than where it
        # started. Measured on a Zero 2 W: about three minutes, or fifteen when
        # the kernel headers still have to be downloaded.
        log "building the codec driver — a few minutes, and it must not be interrupted"
        if ( cd "$CODEC_SRC" && ./install.sh ) >>"$LOG" 2>&1; then
            log "ok    WM8960 machine driver built and installed"
            REBOOT_NEEDED=1
        else
            warn "the WM8960 driver did not build — see the end of $LOG. The box will run, but its speakers and microphones will stay silent."
        fi
    fi
fi

# ------------------------------------------------------------------- mixer
# The WM8960 is a codec, not a sound card with sensible defaults. Nothing in this
# installer used to touch its mixer at all — the levels that were found on the
# first device happened to be usable, which is luck, not a design. Set them
# explicitly and store them so they survive a reboot.
if command -v amixer >/dev/null 2>&1; then
    CARD=""
    for candidate in /proc/asound/card[0-9]*; do
        [ -f "$candidate/id" ] || continue
        case "$(cat "$candidate/id" 2>/dev/null)" in
            *wm8960*) CARD="${candidate##*card}"; break ;;
        esac
    done
    if [ -n "$CARD" ]; then
        # The two switches that decide whether anything is audible at all. The
        # WM8960 driver leaves them off, so the DAC output never reaches the
        # output mixer: ALSA accepts audio, negotiates a rate, reports success,
        # and the room stays silent. Waveshare ships them enabled in the ALSA
        # state their vendor driver installs, which is why the HAT works with
        # that driver and not with the mainline overlay alone.
        for switch in "Left Output Mixer PCM" "Right Output Mixer PCM"; do
            amixer -c "$CARD" sset "$switch" on >>"$LOG" 2>&1 || true
        done
        # The class-D speaker amplifier's bias. At zero it produces nothing.
        amixer -c "$CARD" sset "Speaker AC" 4 >>"$LOG" 2>&1 || true
        amixer -c "$CARD" sset "Speaker DC" 4 >>"$LOG" 2>&1 || true

        for control in Speaker Headphone Playback; do
            amixer -c "$CARD" sset "$control" 80% unmute >>"$LOG" 2>&1 || true
        done
        # The microphone path, and it is the same story as the speakers: the
        # driver leaves the input mixer disconnected, so the ADC records its own
        # DC drift instead of the room. Measured before and after — a full-scale
        # tone went from inaudible to 49 dB above the noise floor. These are the
        # values Waveshare ships in the ALSA state their vendor driver installs.
        for switch in "Left Boost Mixer LINPUT1" "Right Boost Mixer RINPUT1" \
                      "Left Input Mixer Boost" "Right Input Mixer Boost"; do
            amixer -c "$CARD" sset "$switch" on >>"$LOG" 2>&1 || true
        done
        amixer -c "$CARD" sset "Left Input Boost Mixer LINPUT1" 3 >>"$LOG" 2>&1 || true
        amixer -c "$CARD" sset "Right Input Boost Mixer RINPUT1" 3 >>"$LOG" 2>&1 || true

        # Capture level from the same source. The microphones feed a recorder,
        # and gain applied here cannot be undone later.
        amixer -c "$CARD" sset Capture 39 cap >>"$LOG" 2>&1 || true

        # Persist, so a reboot does not put the box back to silence.
        command -v alsactl >/dev/null 2>&1 && alsactl store >>"$LOG" 2>&1
        log "ok    audio routed and levels set on the WM8960 (card $CARD)"
    else
        warn "no WM8960 card found; its mixer was left untouched"
    fi
fi

# ----------------------------------------------------------- boot overlays

CONFIG_TXT="$BOOT/config.txt"
[ -f "$CONFIG_TXT" ] || CONFIG_TXT=/boot/config.txt
if ! grep -q '>>> NeoRecall Desk >>>' "$CONFIG_TXT" 2>/dev/null; then
    # The HAT and the USB gadget are device-tree level: they exist only after a
    # reboot, which is the one thing this install cannot do for the user.
    cp "$CONFIG_TXT" "$CONFIG_TXT.bak-neorecall" 2>/dev/null
    sed -i -E '/^\s*dtparam=(audio|i2c_arm|i2s)=/d' "$CONFIG_TXT"
    printf '\n' >> "$CONFIG_TXT"
    cat "$SRC/overlays/neorecall-desk.txt" >> "$CONFIG_TXT"
    REBOOT_NEEDED=1
    log "ok    boot overlays added (a reboot is needed for the audio HAT)"
else
    log "ok    boot overlays already present"
fi

CMDLINE="$BOOT/cmdline.txt"
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt
if ! grep -q 'modules-load=dwc2' "$CMDLINE" 2>/dev/null; then
    sed -i 's/$/ modules-load=dwc2/' "$CMDLINE"
    sed -i -e :a -e 'N;$!ba' -e 's/\n\+$//' "$CMDLINE"
    REBOOT_NEEDED=1
fi

# --------------------------------------------------------------------- start

echo "$VERSION" > "$ROOT/VERSION"

systemctl daemon-reload
systemd-tmpfiles --create >/dev/null 2>&1
systemctl restart systemd-journald >/dev/null 2>&1
systemctl reload dbus >/dev/null 2>&1
systemctl enable neorecall-usb-gadget.service >>"$LOG" 2>&1
if [ -n "$(ls /sys/class/udc 2>/dev/null)" ]; then
    # Tear it down explicitly first. The gadget script exits early when the
    # gadget already exists, so a restart alone can silently keep whatever an
    # older version built — including the terminal names a laptop displays, which
    # is how a device ends up called "Playback Inactive" in somebody's sound
    # settings.
    # The relay can keep the ALSA gadget card open. Stop it before asking the
    # kernel to release usb_f_uac2; it is started again below with PipeWire.
    systemctl --user -M neorecall@ stop neorecall-desk-relay.service \
        >>"$LOG" 2>&1 || true
    systemctl stop neorecall-usb-gadget.service >>"$LOG" 2>&1 || true
    "$ROOT/neorecall-usb-gadget.sh" stop >>"$LOG" 2>&1 || true
    if [ "$UAC2_DKMS_INSTALLED" -eq 1 ]; then
        if modprobe -r usb_f_uac2 >>"$LOG" 2>&1; then
            log "ok    released the previous USB audio module"
        else
            warn "the active USB audio module is busy; the name override takes effect after reboot"
            REBOOT_NEEDED=1
        fi
    fi
    step "start the USB gadget" systemctl start neorecall-usb-gadget.service
else
    # Not a failure: dwc2 is a device-tree setting and there is no USB controller
    # to bind to until the reboot below. Calling this "failed" would teach people
    # to ignore the word.
    log "ok    USB gadget enabled (starts after the reboot)"
fi
UAC2_MODULE_PATH="$(modinfo -n usb_f_uac2 2>/dev/null || true)"
case "$UAC2_MODULE_PATH" in
    */updates/dkms/*)
        log "ok    usb_f_uac2 resolves to the DKMS override"
        ;;
    *)
        warn "usb_f_uac2 resolves to ${UAC2_MODULE_PATH:-no module}; USB audio uses the stock display names"
        ;;
esac
step "enable automatic updates" systemctl enable --now neorecall-desk-update.timer
step "enable diagnostics" systemctl enable --now neorecall-desk-diagnostics.timer
if [ -f /usr/lib/systemd/user/pipewire.service ]; then
    step "enable the audio graph" systemctl --global enable \
        pipewire.service pipewire-pulse.service wireplumber.service
else
    warn "PipeWire is not installed, so there is no audio graph to enable"
fi
# Deliberately *not* --global: that enables the appliance for every account on
# the box, so an administrator opening an SSH session starts a second supervisor
# alongside the real one. It is enabled for the neorecall account further down,
# once that account's user manager is up. The disable undoes earlier installs
# that did use --global.
systemctl --global disable neorecall-desk.service neorecall-desk-relay.service \
    >>"$LOG" 2>&1 || true

NEORECALL_UID="$(id -u neorecall)"
for _ in $(seq 1 30); do
    [ -S "/run/user/$NEORECALL_UID/bus" ] && break
    sleep 1
done
as_neorecall() {
    runuser -u neorecall -- env \
        "XDG_RUNTIME_DIR=/run/user/$NEORECALL_UID" \
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$NEORECALL_UID/bus" "$@"
}
step "reload the user manager" as_neorecall systemctl --user daemon-reload
if [ -f /usr/lib/systemd/user/pipewire.service ]; then
    step "start the audio graph" as_neorecall systemctl --user restart \
        pipewire.service wireplumber.service
fi
sleep 3
# The relay first: it is what carries laptop audio to the speakers and the room
# back to the laptop, and it is useful even to somebody who never sets NeoRecall
# up at all.
step "start the audio relay" as_neorecall systemctl --user enable --now \
    neorecall-desk-relay.service
as_neorecall systemctl --user restart neorecall-desk-relay.service >>"$LOG" 2>&1
step "start the appliance" as_neorecall systemctl --user enable --now neorecall-desk.service
as_neorecall systemctl --user restart neorecall-desk.service >>"$LOG" 2>&1

log "NeoRecall Desk $VERSION is installed"

if [ "$REBOOT_NEEDED" -eq 1 ]; then
    cat <<'NOTE'

  ────────────────────────────────────────────────────────────────
   Reboot now to finish: the audio HAT and the USB sound device are
   device-tree settings that only exist after a restart.

       sudo reboot

   After that, open NeoRecall on your phone and add the device.
  ────────────────────────────────────────────────────────────────
NOTE
else
    echo
    echo "  Open NeoRecall on your phone and add the device."
fi
exit 0
