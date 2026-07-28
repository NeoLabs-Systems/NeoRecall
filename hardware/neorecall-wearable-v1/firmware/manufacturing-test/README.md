# NeoRecall Rev C manufacturing test

This ESP-IDF application is a real first-article test image for the reviewed Rev C pin map. It checks the regulator power-good input, tied GPIO0/GPIO9 button inputs, calibrated battery ADC, both stereo T5848 slots, and a synchronized microSD write/read/compare cycle. It then isolates the SPI pins before removing card power, exactly matching the board's back-powering requirement. A long button hold arms deep sleep; releasing and pressing the button again verifies GPIO0 wake on the next boot.

It intentionally does not format a card. Insert a known-good FAT32 microSDHC card, connect the intended protected 1S pack with 10 kΩ NTC, and connect the board through native USB before running it.

```bash
source "$HOME/esp/esp-idf/export.sh"
idf.py set-target esp32c6
idf.py build
idf.py -p /dev/your-usb-device flash monitor
```

Passing this image proves digital connectivity on the assembled unit. It does not qualify RF range, USB signal margin, microphone SNR, charger current/temperature behavior, power-transient margin, ESD, or long-term reliability; those remain physical EVT gates in `ASSEMBLY.md` and `ELECTRICAL_AUDIT.md`.
