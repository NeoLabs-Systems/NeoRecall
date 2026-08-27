#!/bin/bash
# Runs as the very first userspace process, before systemd, via `init=` on the
# kernel command line. Raspberry Pi's own imaging tool uses this same hook.
#
# It exists because everything above it had already failed: the Pi booted and
# resized its filesystem but never reached a network, and its logs live in an
# ext4 filesystem that a Mac cannot read. This runs earlier than anything that
# could be broken, writes what it finds onto the FAT partition that any computer
# can read, and configures the network itself rather than trusting the layer
# that did not work.
#
# Two rules, because a mistake here means a Pi that does not boot at all:
#   * nothing may fail the script - no `set -e`, every command tolerant;
#   * it always ends by handing control to the real init.
set +e

BOOT=/boot/firmware
[ -d "$BOOT" ] || BOOT=/boot
OUT="$BOOT/RESCUE"

# The rootfs arrives read-only at this point.
mount -o remount,rw / 2>/dev/null
mount -o remount,rw "$BOOT" 2>/dev/null
mkdir -p "$OUT" 2>/dev/null

say() { echo "$*" >> "$OUT/report.txt" 2>/dev/null; }

say "===== NeoRecall rescue firstrun ====="
say "started: $(date -u 2>/dev/null)  (a Pi with no clock reports its image date)"
say "kernel: $(uname -a 2>/dev/null)"
say "cmdline: $(cat /proc/cmdline 2>/dev/null)"

# ---- did the previous boot's userspace get anywhere at all? ----
say ""
say "--- previous boot ---"
say "cloud-init present: $([ -x /usr/bin/cloud-init ] && echo yes || echo NO)"
say "NetworkManager present: $([ -x /usr/sbin/NetworkManager ] && echo yes || echo NO)"
say "netplan present: $([ -x /usr/sbin/netplan ] && echo yes || echo NO)"
for f in /var/log/cloud-init.log /var/log/cloud-init-output.log; do
    if [ -f "$f" ]; then
        say "$f: $(wc -l < "$f" 2>/dev/null) lines"
        cp "$f" "$OUT/$(basename "$f")" 2>/dev/null
    else
        say "$f: MISSING - cloud-init never ran"
    fi
done
say ""
say "--- what cloud-init rendered, if anything ---"
ls -la /etc/netplan/ >> "$OUT/report.txt" 2>&1
ls -la /etc/NetworkManager/system-connections/ >> "$OUT/report.txt" 2>&1
cp /etc/netplan/*.yaml "$OUT/" 2>/dev/null

# ---- the radio itself ----
say ""
say "--- radio ---"
say "network interfaces: $(find /sys/class/net -maxdepth 1 -mindepth 1 -printf '%f ' 2>/dev/null)"
say "brcmfmac loaded: $(grep -c brcmfmac /proc/modules 2>/dev/null)"
say "brcm firmware: $(find /lib/firmware/brcm -maxdepth 1 -name 'brcmfmac434*' -printf '%f ' 2>/dev/null)"
rfkill list >> "$OUT/report.txt" 2>&1
dmesg 2>/dev/null | grep -iE "brcmfmac|cfg80211|wlan|regulatory|firmware" | tail -40 >> "$OUT/report.txt" 2>&1

dmesg > "$OUT/dmesg.txt" 2>/dev/null

# ---- configure the network ourselves ----
# A NetworkManager keyfile is what Raspberry Pi OS itself writes, and it does not
# depend on cloud-init, netplan, or anything that has already failed once.
say ""
say "--- writing a NetworkManager profile ---"
NM_DIR=/etc/NetworkManager/system-connections
if [ -d "$NM_DIR" ]; then
    mkdir -p "$NM_DIR" 2>/dev/null
    cat > "$NM_DIR/neorecall.nmconnection" <<'PROFILE'
[connection]
id=neorecall
uuid=8f2c1d64-3b7a-4e15-9a0c-6d4f2e8b1a37
type=wifi
interface-name=wlan0
autoconnect=true
autoconnect-priority=100

[wifi]
mode=infrastructure
ssid=__SSID__

[wifi-security]
key-mgmt=wpa-psk
psk=__PSK__

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default
PROFILE
    # The SSID carries a comma, so it is substituted rather than interpolated
    # into the heredoc, where quoting rules would be one more thing to get wrong.
    sed -i "s|__SSID__|$(cat "$BOOT/RESCUE-SSID" 2>/dev/null)|" "$NM_DIR/neorecall.nmconnection" 2>/dev/null
    sed -i "s|__PSK__|$(cat "$BOOT/RESCUE-PSK" 2>/dev/null)|" "$NM_DIR/neorecall.nmconnection" 2>/dev/null
    chmod 600 "$NM_DIR/neorecall.nmconnection" 2>/dev/null
    chown root:root "$NM_DIR/neorecall.nmconnection" 2>/dev/null
    say "written: $NM_DIR/neorecall.nmconnection"
else
    say "NetworkManager is not installed - cannot write a profile"
fi

# The radio is soft-blocked until a country is set, and an unset country is a
# silent way to have no Wi-Fi at all.
if [ -x /usr/bin/raspi-config ]; then
    raspi-config nonint do_wifi_country DE >> "$OUT/report.txt" 2>&1
    say "wifi country set to DE"
fi
rfkill unblock wifi 2>/dev/null
rfkill unblock all 2>/dev/null

# ---- make sure we can be reached ----
systemctl enable ssh >> "$OUT/report.txt" 2>&1
touch /boot/firmware/ssh /boot/ssh 2>/dev/null
[ -f /etc/hostname ] && echo neorecall > /etc/hostname 2>/dev/null

# ---- take ourselves off the command line ----
# Without this the Pi runs this script on every boot instead of booting normally.
CMDLINE="$BOOT/cmdline.txt"
if [ -f "$CMDLINE" ]; then
    cp "$CMDLINE" "$OUT/cmdline-before.txt" 2>/dev/null
    sed -i 's| init=/boot/firmware/rescue-firstrun\.sh||; s| init=/boot/rescue-firstrun\.sh||' "$CMDLINE" 2>/dev/null
    say "removed init= from cmdline.txt"
fi

say ""
say "===== handing over to the real init ====="
sync
sleep 1

exec /sbin/init "$@"
