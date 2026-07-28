# Primary design sources

The design decisions and custom footprints use manufacturer documentation rather than marketplace listings.

- [ESP32-C6-MINI-1 datasheet](https://documentation.espressif.com/esp32-c6-mini-1_mini-1u_datasheet_en.html)
- [ESP32-C6-MINI-1 official PCB-footprint DXF](https://www.espressif.com/sites/default/files/modules-dxf/ESP32-C6-MINI-1%20PCB%20Footprint.dxf)
- [ESP32-C6 PCB layout guidelines](https://docs.espressif.com/projects/esp-hardware-design-guidelines/en/latest/esp32c6/pcb-layout-design.html)
- [ESP32-C6 schematic checklist](https://docs.espressif.com/projects/esp-hardware-design-guidelines/en/latest/esp32c6/schematic-checklist.html)
- [TDK InvenSense T5848 product page](https://www.invensense.tdk.com/en-us/products/microphone/t5848/)
- [TDK T5848 datasheet DS-000479](https://www.invensense.tdk.com/wp-content/uploads/2024/04/DS-000479-T5848-Datasheet-v1.0.pdf)
- [TI BQ24074 charger/power-path datasheet](https://www.ti.com/lit/ds/symlink/bq24074.pdf)
- [TI TPS63021 buck-boost datasheet](https://www.ti.com/lit/ds/symlink/tps63021.pdf)
- [Coilcraft XFL4020 series](https://www.coilcraft.com/en-us/products/power/shielded-inductors/molded-inductor/xfl/xfl4020/)
- [TI TPS7A20 LDO datasheet](https://www.ti.com/lit/ds/symlink/tps7a20.pdf)
- [TI TXU0304 level-translator datasheet](https://www.ti.com/lit/ds/symlink/txu0304.pdf)
- [TI TPS22918 load-switch datasheet](https://www.ti.com/lit/ds/symlink/tps22918.pdf)
- [ST USBLC6-2SC6 USB ESD datasheet](https://www.st.com/resource/en/datasheet/usblc6-2.pdf)
- [Molex 216990-0003 product record](https://www.molex.com/en-us/products/part-detail/2169900003)
- [Molex 216990 series PCB drawing](https://www.molex.com/content/dam/molex/molex-dot-com/products/automated/en-us/salesdrawingpdf/216/216990/2169900001_sd.pdf?inline=)
- [GCT MEM2085 product record and PCB resources](https://gct.co/connector/mem2085)
- [GCT MEM2085 official three-page drawing](https://gct.co/files/drawings/mem2085.pdf)
- [C&K PTS810 switch datasheet](https://www.ckswitches.com/media/1476/pts810.pdf)

## Existing-board decision

No finished board found satisfies all constraints simultaneously.

- [Omi Consumer hardware](https://docs.omi.me/doc/hardware/consumer/electronics) is closest electrically: two microphones, BLE/Wi-Fi and 8 GB NAND in a very small design. It uses fine-pitch/WLCSP parts, a separate magnetic charging dock, and SWD programming, so it does not meet the self-solderable USB-C requirement.
- [Seeed XIAO ESP32-S3 Sense](https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/) provides Wi-Fi/BLE, USB-C and battery support, but the camera/sense expansion is thick and supplies only one microphone; removable storage also increases the stack.
- [Waveshare ESP32-S3-AUDIO-Board](https://www.waveshare.com/esp32-s3-audio-board.htm) has dual microphones, wireless connectivity, TF storage, battery management and USB-C, but is far larger than the 28 mm × 38 mm target.

That is why this design uses a module for the RF-critical part while keeping the charger, audio, storage and user interface on the custom PCB.
