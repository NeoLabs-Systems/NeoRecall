#!/bin/bash
# Dump everything worth knowing about this appliance.
#
#   sudo /usr/local/lib/neorecall-desk/diagnostics.sh            # write a report
#   sudo /usr/local/lib/neorecall-desk/diagnostics.sh boot -     # print it here
#
# The report is written to the FAT boot partition as well as being printed,
# because that partition is readable from any computer by pulling the card. When
# the network is the thing that is broken, that is the only channel left.
#
# It never fails and never blocks a boot: `set +e`, every command tolerant, and
# a hard exit 0 at the end.
set +e
B=/boot/firmware
D=$B/DIAG
mkdir -p "$D" 2>/dev/null
TAG="${1:-run}"
# A second argument of "-" also prints the report, which is what makes this
# useful over SSH rather than only after pulling the card.
ECHO_TO_STDOUT="${2:-}"
N=0; while [ -e "$D/$TAG-$N.txt" ]; do N=$((N+1)); done
OUT="$D/$TAG-$N.txt"

NEO_UID="$(id -u neorecall 2>/dev/null)"
STATE=/var/lib/neorecall-desk

s() { echo; echo "===== $* ====="; }

# Run a command as the appliance account, with its user bus. Most of what
# matters — the audio graph, the appliance service — lives in that session and
# is invisible from root.
asneo() {
    [ -n "$NEO_UID" ] || { echo "(no neorecall account)"; return; }
    runuser -u neorecall -- env \
        "XDG_RUNTIME_DIR=/run/user/$NEO_UID" \
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$NEO_UID/bus" \
        "$@" 2>&1
}

{
  echo "NeoRecall Desk diagnostic   tag=$TAG   $(date -u 2>/dev/null)"
  echo "uptime: $(cat /proc/uptime 2>/dev/null)"

  s IDENTITY
    uname -a
    cat /proc/device-tree/model 2>/dev/null; echo
    echo "serial: $(tr -d '\0' </proc/device-tree/serial-number 2>/dev/null)"
    echo "arch:   $(dpkg --print-architecture 2>/dev/null)"
    cat /etc/os-release 2>/dev/null | head -4

  s INSTALL_RESULT
    cat "$D/install-result.txt" 2>/dev/null || echo "(the install has not run yet)"

  s BREADCRUMBS
    cat "$D/breadcrumb.txt" 2>/dev/null

  s CMDLINE
    cat /proc/cmdline

  s CONFIG_TXT
    grep -vE '^\s*(#|$)' $B/config.txt 2>&1

  s OVERLAYS_APPLIED
    dtoverlay -l 2>&1
    vcgencmd get_config int 2>&1 | grep -iE 'audio|i2c|i2s|spi' 

  # ---- the WM8960 audio HAT ----
  s SOUND_CARDS
    cat /proc/asound/cards 2>&1
    echo "--- playback:"; aplay -l 2>&1
    echo "--- capture:";  arecord -l 2>&1
  s WM8960_DRIVER
    dmesg 2>&1 | grep -iE 'wm8960|i2s|bcm2835-i2s|simple-card|asoc' | tail -40
    ls -l /proc/asound/ 2>&1
  s I2C_BUS
    i2cdetect -y 1 2>&1
  s ALSA_MIXER
    # The WM8960 ships with its speaker outputs muted, so this section is the
    # difference between "no sound" and "no idea why there is no sound". The
    # previous parse of /proc/asound/cards produced nothing at all, which is why
    # this now walks the card directories instead.
    for card in /proc/asound/card[0-9]*; do
      [ -d "$card" ] || continue
      index="${card##*card}"
      echo "--- card $index ($(cat "$card/id" 2>/dev/null))"
      # Not truncated. A WM8960 has around forty controls, and cutting the dump
      # short is how the routing switches that decide whether anything is
      # audible went unnoticed in the first place.
      amixer -c "$index" scontents 2>&1
    done

  # ---- the USB gadget: what the laptop sees ----
  s USB_GADGET
    echo "--- controllers:"; ls -l /sys/class/udc/ 2>&1
    echo "--- configfs:";    ls -l /sys/kernel/config/usb_gadget/ 2>&1
    if [ -d /sys/kernel/config/usb_gadget/neorecall ]; then
      echo "--- bound UDC: $(cat /sys/kernel/config/usb_gadget/neorecall/UDC 2>&1)"
      for f in /sys/kernel/config/usb_gadget/neorecall/functions/uac2.usb0/*; do
        [ -f "$f" ] && echo "$(basename "$f")=$(cat "$f" 2>/dev/null)"
      done
    else
      echo "(the gadget has not been created)"
    fi
    echo "--- service:"; systemctl status neorecall-usb-gadget.service --no-pager -l 2>&1 | head -30
    echo "--- journal:";  journalctl -u neorecall-usb-gadget.service --no-pager -n 60 2>&1
  s USB_KERNEL
    echo "--- selected usb_f_uac2 module:"
    /usr/sbin/modinfo -n usb_f_uac2 2>&1
    echo "--- DKMS status:"
    /usr/sbin/dkms status neorecall-uac2-name 2>&1
    lsmod 2>&1 | grep -iE 'dwc2|libcomposite|usb_f_uac2|udc'
    dmesg 2>&1 | grep -iE 'dwc2|gadget|uac2|udc|usb' | tail -60

  # ---- the audio graph ----
  s PIPEWIRE_SERVICES
    asneo systemctl --user --no-pager status pipewire.service wireplumber.service | head -60

  s AUDIO_RELAY
    # The relay is what carries laptop audio to the speakers and the room back to
    # the laptop. When it is not running, the box is silent in both directions
    # and everything else still looks healthy.
    asneo systemctl --user --no-pager status neorecall-desk-relay.service | head -30
    if [ -n "$NEO_UID" ]; then
      journalctl _UID="$NEO_UID" -b --no-pager 2>&1 | grep -i "relay:" | tail -20
    fi
    echo "--- host USB speaker controls:"
    for card in /proc/asound/card[0-9]*; do
      [ -f "$card/id" ] || continue
      card_id="$(cat "$card/id" 2>/dev/null)"
      case "${card_id,,}" in
        *uac2*|*gadget*)
          amixer -c "$card_id" cget name="PCM Capture Volume" 2>&1
          amixer -c "$card_id" cget name="PCM Capture Switch" 2>&1
          ;;
      esac
    done
  s MICROPHONE_HEALTH
    # Silent on purpose. The appliance's acoustic self-test plays a tone, which
    # is fine on demand from the app and unacceptable from an hourly timer in a
    # room with people in it. This listens instead, and that is enough to catch
    # the failure that cost the most during bring-up: the codec's input mixer
    # disconnected, so the ADC delivered DC drift and nothing else while every
    # other check looked healthy.
    if [ -n "$NEO_UID" ]; then
      MIC_WAV=$(mktemp /tmp/neorecall-mic-XXXXXX.wav)
      MIC_NODE=$(asneo pw-dump 2>/dev/null | python3 -c '
import json, sys
try:
    objects = json.load(sys.stdin)
except Exception:
    sys.exit()
for entry in objects:
    props = (entry.get("info") or {}).get("props") or {}
    if "Audio/Source" not in str(props.get("media.class", "")):
        continue
    haystack = " ".join(
        str(props.get(key, "")) for key in ("node.name", "node.description", "alsa.card_name")
    ).lower()
    if "wm8960" in haystack:
        print(props.get("node.name", ""))
        break
' 2>/dev/null)
      echo "microphone node: ${MIC_NODE:-<not found>}"
      if [ -n "$MIC_NODE" ]; then
        asneo timeout 12 pw-record --target "$MIC_NODE" \
            --rate 16000 --channels 1 --format s16 "$MIC_WAV" >/dev/null 2>&1
        python3 - "$MIC_WAV" <<'MICPY'
import struct
import sys
import wave

try:
    with wave.open(sys.argv[1]) as handle:
        frames = handle.getnframes()
        data = handle.readframes(frames)
except Exception as error:
    print(f"could not read the capture: {error}")
    raise SystemExit

if not data:
    print("FAIL  the microphone delivered no audio at all")
    raise SystemExit

samples = struct.unpack(f"<{len(data) // 2}h", data)
count = len(samples)
mean = sum(samples) / count
peak = max(abs(value) for value in samples)
rms = (sum((value - mean) ** 2 for value in samples) / count) ** 0.5

print(f"seconds:   {count / 16000:.2f}")
print(f"peak:      {peak}")
print(f"dc offset: {mean:.1f}")
print(f"rms (dc removed): {rms:.1f}")

# A live microphone in a quiet room still moves. A dead input path is either
# flat or pure offset, and both look like "audio" to anything counting bytes.
if peak == 0:
    print("FAIL  silence at the sample level: the input path is dead")
elif rms < 2.0:
    print("FAIL  no variation once the offset is removed: the input mixer is "
          "probably disconnected, so the ADC is recording drift")
else:
    print("ok    the microphone is delivering audio through the codec")
MICPY
      fi
      rm -f "$MIC_WAV"
    fi
  s PIPEWIRE_NODES
    asneo wpctl status
  s PIPEWIRE_LINKS
    # Which nodes are actually joined. A loopback whose target was not found
    # falls back to the default device without complaining, so the node existing
    # says nothing about where its audio goes.
    asneo pw-link -l

  s PIPEWIRE_OBJECTS
    asneo pw-cli ls Node | grep -iE 'node.name|node.description|media.class' | head -80
  s PIPEWIRE_CARDS
    asneo pactl list cards short
    asneo pactl list sinks short
    asneo pactl list sources short
  s PIPEWIRE_MODULES
    asneo pactl list modules short

  s PIPEWIRE_CONFIGURATION
    # Whether the drop-ins are on disk at all, and whether PipeWire read them.
    # A config that is present but silently ignored looks exactly like a config
    # that works, right up until nothing plays.
    echo "--- drop-ins:"
    ls -la /etc/pipewire/pipewire.conf.d/ /etc/wireplumber/wireplumber.conf.d/ 2>&1
    echo "--- versions:"
    pipewire --version 2>&1
    wireplumber --version 2>&1
    echo "--- echo-cancel implementation available?"
    find /usr/lib -maxdepth 4 -name 'libspa-aec*' 2>/dev/null
    find /usr/lib -maxdepth 4 -name 'libpipewire-module-echo-cancel*' -o \
         -maxdepth 4 -name 'libpipewire-module-loopback*' 2>/dev/null
    echo "--- what PipeWire said while starting:"
    if [ -n "$NEO_UID" ]; then
      journalctl _UID="$NEO_UID" -b --no-pager 2>&1 |
        grep -iE 'conf|module|error|neorecall\.' | tail -60
    fi

  # ---- Bluetooth ----
  s BLUETOOTH
    systemctl status bluetooth --no-pager -l 2>&1 | head -20
    rfkill list 2>&1
    hciconfig -a 2>&1
    bluetoothctl show 2>&1
    echo "--- paired:"; bluetoothctl devices Paired 2>&1
    echo "--- version:"; bluetoothd --version 2>&1; dpkg -l bluez 2>&1 | tail -2
  s BLUETOOTH_JOURNAL
    journalctl -u bluetooth --no-pager -n 80 2>&1

  # ---- network ----
  s NETWORK
    nmcli general status 2>&1
    nmcli device status 2>&1
    nmcli radio 2>&1
    ip -brief addr 2>&1
    echo "--- reachable:"; getent hosts deb.debian.org >/dev/null 2>&1 && echo yes || echo no

  # ---- the appliance itself ----
  s APPLIANCE_SERVICE
    asneo systemctl --user --no-pager status neorecall-desk.service | head -40
  s APPLIANCE_JOURNAL
    if [ -n "$NEO_UID" ]; then
      journalctl _UID="$NEO_UID" --no-pager -n 400 2>&1
    fi
  s APPLIANCE_STATE
    ls -la "$STATE" 2>&1
    echo "--- queued audio: $(find "$STATE/pending_audio" -type f 2>/dev/null | wc -l) files"
    du -sh "$STATE" 2>&1
  s APPLIANCE_CONFIG
    # Secrets are redacted: this file lands on a FAT partition that anyone who
    # holds the card can read, and it carries an account access key.
    sed -E 's/("(api_key|apiKey)": *")[^"]*/\1<redacted>/' "$STATE/config.json" 2>&1
  s APPLIANCE_LEDGER
    if [ -f "$STATE/ledger.sqlite3" ]; then
      sqlite3 "$STATE/ledger.sqlite3" \
        "select 'sessions', count(*) from sessions
         union all select 'chunks', count(*) from chunks
         union all select 'gaps', count(*) from gaps;" 2>&1
      sqlite3 "$STATE/ledger.sqlite3" \
        "select state, count(*) from chunks group by state;" 2>&1
      sqlite3 "$STATE/ledger.sqlite3" \
        "select id, status, final_sequence, declared, closed_on_server from sessions
         order by started_at desc limit 5;" 2>&1
    else
      echo "(no ledger yet — nothing has been recorded)"
    fi
  s APPLIANCE_IMPORT_CHECK
    /usr/local/lib/neorecall-desk/venv/bin/python - <<'PY' 2>&1
import importlib, sys
print("python", sys.version)
for name in ("numpy", "requests", "cbor2", "dbus_fast", "gpiod", "neorecall_desk"):
    try:
        module = importlib.import_module(name)
        print(f"  ok      {name} {getattr(module, '__version__', '')}")
    except Exception as error:
        print(f"  MISSING {name}: {error}")
PY

  # ---- the box itself ----
  s GPIO
    gpioinfo 2>&1 | head -60
  s POWER_AND_HEAT
    vcgencmd get_throttled 2>&1
    vcgencmd measure_temp 2>&1
    vcgencmd measure_volts 2>&1
  s STORAGE_AND_MEMORY
    df -h 2>&1
    free -h 2>&1
    # A Zero 2 W has 512 MB and this box runs PipeWire, Python and numpy. If
    # memory turns out to be the constraint, the display stack in config.txt is
    # the first thing worth reclaiming.
    vcgencmd get_mem arm 2>&1; vcgencmd get_mem gpu 2>&1
    echo "--- top by RSS:"; ps -eo rss,comm --sort=-rss 2>/dev/null | head -15
    mount | grep -E 'boot|root' 2>&1

  # ---- anything that went wrong ----
  s FAILED_UNITS
    systemctl --failed --no-pager 2>&1
    asneo systemctl --user --failed --no-pager
  s DMESG_ERRORS
    dmesg --level=err,warn,crit 2>&1 | tail -80
  s CLOUD_INIT
    cloud-init status --long 2>&1
    tail -80 /var/log/cloud-init-output.log 2>&1
} > "$OUT" 2>&1

# Whole files, not excerpts: the summary above is for reading, these are for
# grepping when the summary was not enough.
dmesg > "$D/dmesg-$TAG-$N.txt" 2>/dev/null
journalctl --no-pager -b > "$D/journal-$TAG-$N.txt" 2>/dev/null
cp /var/log/cloud-init-output.log "$D/cloud-init-output.log" 2>/dev/null
cp /var/log/neorecall-desk-install.log "$D/install.log" 2>/dev/null

# Keep the card from filling up with history nobody will read. Newest 60 stay.
find "$D" -maxdepth 1 -name '*.txt' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | tail -n +60 | cut -d' ' -f2- | xargs -r rm -f 2>/dev/null

[ "$ECHO_TO_STDOUT" = "-" ] && cat "$OUT"

sync
exit 0
