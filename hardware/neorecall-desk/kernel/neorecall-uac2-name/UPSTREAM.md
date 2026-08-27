# Pinned Raspberry Pi kernel source

The GPL-2.0 kernel sources in this directory are copied from
`drivers/usb/gadget/function` in Raspberry Pi Linux commit
`8c74b839debd96d0d7a441abc35d36b20fdda278` (`rpi-6.18.y`):

https://github.com/raspberrypi/linux/commit/8c74b839debd96d0d7a441abc35d36b20fdda278

NeoRecall changes only the four AudioStreaming alternate-setting strings in
`f_uac2.c`. Both states of each stream use the existing ConfigFS
`function_name`, which the gadget configuration sets to `NeoRecall Desk`.

The module keeps the upstream name `usb_f_uac2` so DKMS installs it in
`updates/dkms` as a higher-priority replacement for the kernel package's stock
module. The stock module is not modified or removed.
