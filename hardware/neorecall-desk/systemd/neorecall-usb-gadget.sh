#!/bin/sh
# Present the appliance to the laptop as a standard USB audio device.
#
# This is the whole reason no software has to be installed on the laptop: USB
# Audio Class 2 is part of Windows 10 and later, macOS and Linux, so the laptop
# sees a sound card it already knows how to drive.
#
# Both directions are declared at 48 kHz stereo — not because the recording needs
# it, but because it is the format every host accepts without argument. PipeWire
# resamples to what the recorder actually wants.
set -eu

GADGET=/sys/kernel/config/usb_gadget/neorecall
SERIAL_SOURCE=/proc/device-tree/serial-number

case "${1:-start}" in
start)
    modprobe libcomposite
    [ -d /sys/kernel/config/usb_gadget ] || mount -t configfs none /sys/kernel/config

    # Rebuild rather than skip. Exiting early when the directory already exists
    # meant an updated configuration — a corrected device name, a different
    # sample rate — silently never reached the host, because a teardown that
    # failed halfway leaves the directory behind and looks identical to a
    # gadget that is already correct.
    if [ -d "$GADGET" ]; then
        "$0" stop || true
    fi

    mkdir -p "$GADGET"
    cd "$GADGET"

    # Linux Foundation's vendor id with the multifunction composite product id.
    # These are the identifiers the kernel ships for exactly this purpose.
    echo 0x1d6b > idVendor
    echo 0x0104 > idProduct
    echo 0x0100 > bcdDevice
    echo 0x0200 > bcdUSB

    mkdir -p strings/0x409
    echo "NeoRecall" > strings/0x409/manufacturer
    echo "NeoRecall Desk" > strings/0x409/product
    if [ -r "$SERIAL_SOURCE" ]; then
        tr -d '\0' < "$SERIAL_SOURCE" > strings/0x409/serialnumber
    else
        echo "0000000000000000" > strings/0x409/serialnumber
    fi

    mkdir -p configs/c.1/strings/0x409
    echo "Audio" > configs/c.1/strings/0x409/configuration
    echo 250 > configs/c.1/MaxPower

    mkdir -p functions/uac2.usb0
    # c_* is what the laptop sends us; it appears here as an ALSA capture device.
    echo 3     > functions/uac2.usb0/c_chmask
    echo 48000 > functions/uac2.usb0/c_srate
    echo 2     > functions/uac2.usb0/c_ssize
    # p_* is what we send the laptop; the laptop sees it as a microphone.
    echo 3     > functions/uac2.usb0/p_chmask
    echo 48000 > functions/uac2.usb0/p_srate
    echo 2     > functions/uac2.usb0/p_ssize

    # macOS prefers the AudioStreaming interface strings over the USB product
    # string. NeoRecall's DKMS override makes all four streaming states reuse
    # function_name, while the other attributes keep the same name on hosts that
    # prefer terminal/control descriptors. A failed DKMS build safely falls back
    # to the stock module, where macOS may still display Playback/Capture
    # Inactive. Not every kernel exposes every attribute, so write only those
    # that exist.
    for attribute in c_it_name c_ot_name p_it_name p_ot_name \
                     function_name if_ctrl_name; do
        [ -f "functions/uac2.usb0/$attribute" ] &&
            echo "NeoRecall Desk" > "functions/uac2.usb0/$attribute"
    done
    [ -f functions/uac2.usb0/c_it_ch_name ] &&
        echo "Room" > functions/uac2.usb0/c_it_ch_name
    [ -f functions/uac2.usb0/p_it_ch_name ] &&
        echo "Computer" > functions/uac2.usb0/p_it_ch_name

    ln -s functions/uac2.usb0 configs/c.1/

    # Binding to the controller is what makes the device appear on the laptop.
    # Failing loudly here matters: an empty UDC file leaves a gadget that exists
    # in configfs and is invisible on the other end of the cable, which looks
    # exactly like a broken cable.
    udc=""
    for candidate in /sys/class/udc/*; do
        [ -e "$candidate" ] || continue
        udc=$(basename "$candidate")
        break
    done
    if [ -z "$udc" ]; then
        echo "no USB device controller found; is dwc2 loaded?" >&2
        exit 1
    fi
    printf '%s\n' "$udc" > UDC
    ;;
stop)
    [ -d "$GADGET" ] || exit 0
    cd "$GADGET"

    # Unbind first and give the controller a moment. Removing a function that is
    # still bound fails with EBUSY, and every rmdir after it fails too — which is
    # how a "stopped" gadget ends up still present.
    echo "" > UDC 2>/dev/null || true
    sleep 1

    rm -f configs/c.1/uac2.usb0 2>/dev/null || true
    rmdir configs/c.1/strings/0x409 2>/dev/null || true
    rmdir configs/c.1 2>/dev/null || true
    rmdir functions/uac2.usb0 2>/dev/null || true
    rmdir strings/0x409 2>/dev/null || true
    cd /
    rmdir "$GADGET" 2>/dev/null || true

    # Say so rather than exit 0 on a lie: a gadget that survives its own teardown
    # is the difference between a configuration change that lands and one that
    # does not.
    if [ -d "$GADGET" ]; then
        echo "warning: the USB gadget could not be fully removed" >&2
    fi
    ;;
*)
    echo "usage: $0 start|stop" >&2
    exit 64
    ;;
esac
