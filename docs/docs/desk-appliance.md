---
sidebar_position: 6
title: NeoRecall Desk
---

# NeoRecall Desk

A small box that sits between your laptop and your ears and records both sides of
the conversation.

Plug it in with one USB cable. Your laptop sees an ordinary sound card — speakers
and a microphone — with no driver, no installer, and nothing to configure. Sound
from the laptop comes out of the box's speakers or your Bluetooth headphones; the
room goes back to the laptop as a microphone. Press its button, and NeoRecall
records the whole call.

Everything else happens in the NeoRecall app.

## What you need

- A Raspberry Pi Zero 2 W with a Waveshare WM8960 Audio HAT
- A microSD card, 16 GB or larger
- A USB **data** cable from your computer to the socket labelled `USB` on the Pi
  — the one next to the mini-HDMI, not `PWR IN` at the end of the board. A
  charge-only cable powers the device and carries no sound.

Bluetooth headphones are optional.

## Setting it up

Building the box is a one-off job at a keyboard. Everything after it happens in
the app.

1. Write **Raspberry Pi OS Lite (64-bit)** to the card with Raspberry Pi Imager.
   Use Imager's customisation settings: give it a hostname, create a user, enter
   your Wi-Fi, and turn on SSH.

   The 64-bit part matters. On 32-bit none of the software the box needs is
   available ready-built, so it has to be compiled on the device and the first
   start takes most of an hour instead of a few minutes.

2. Put the card in, plug the device into your computer, and wait a minute for it
   to join your network. Then run one line on it:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/NeoLabs-Systems/NeoRecall/beta/hardware/neorecall-desk/install.sh | sudo bash
   ```

   When it says to, restart the device with `sudo reboot`. The audio HAT and the
   USB sound device only exist after a restart.

3. In the app, open **Record**, find **NeoRecall Desk** below the app's own
   capture sources, and tap **Set up**. The box appears there.

4. When the app asks, **press the button on the device**. There is no screen to
   show a pairing code, so the press is what proves somebody is standing next to
   it.

5. Pick your Wi-Fi network and type its password — in the app, not on the device.

From here on you never see an access key, never type a server address, and never
open a terminal again. The box keeps itself up to date on its own, and it will
not interrupt a recording to do it.

To set it up again later — a new network, a different account — hold the button
for five seconds. Three short beeps mean it is ready to pair again.

## Using it

On your computer, choose **NeoRecall Desk** as both the output and the input
device. That is the only thing that happens on the computer.

| What you do | What happens |
| --- | --- |
| Short press on the button | Start or stop recording. Rising tone for start, falling for stop. |
| Five-second hold | Setup mode. Three short beeps. |

On **Record**, open the device under **NeoRecall Desk** to see whether it is
recording, how long for, where sound is going, and which headphones are
connected. The recording state is deliberately hard to miss — the same orb and
the same colour the app's own record control uses.

## Bluetooth headphones

Open the Desk from **Record** and connect them there. By default they play sound
at full quality and recording uses the microphones in the box.

You can switch to the headset's own microphone in the device settings. The app
warns you when you do, because it is a real trade: a Bluetooth headset that is
using its microphone drops playback to narrowband. That is how Bluetooth works,
not something NeoRecall can improve on. If your headphones have no microphone the
device can use, it says so rather than quietly doing nothing.

## Recording and sending

The device records to its own card first and sends afterwards. While a recording
is running its Wi-Fi is switched off, so Bluetooth sound has the airwaves to
itself; when you stop, the network comes back and the queue empties.

Nothing is deleted from the card until the server confirms both that the
transcript is stored and that its own copy of the audio is gone. A power cut, a
server that is down for a day, an unplugged cable — none of them lose a
recording. If something cannot be sent, the Desk control on Record says so in
words.

## What it records

Both sides: what your computer is playing, and what the microphones hear. In
speaker mode the device removes its own speaker output from the microphone
signal, so the other person is not transcribed twice.

It records only when you tell it to, and only to the NeoRecall server you set it
up with. Place it and ask for consent accordingly — see
[Privacy and consent](privacy-and-consent).

## If something is wrong

The device says what it needs in the app, in plain words: no network, recordings
waiting, headphones not connected, or "set this device up again" if it lost
access to your account. There is no console to read and nothing to log into.

If it does not appear when you add it, check that it is plugged into the data
port and has beeped, then hold its button for five seconds and look again.
