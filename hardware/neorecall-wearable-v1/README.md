# NeoRecall Wearable v1 hardware

This directory contains the concrete KiCad 10 schematic, PCB layout, and reviewed component set for a 28 mm × 38 mm NeoRecall recorder. It is a four-layer, 0.8 mm design with two TDK T5848 I²S microphones, Wi-Fi 6/BLE 5.3, removable 16 GB storage, protected three-wire LiPo support with a 10 kΩ pack thermistor, USB-C charging/flashing, and a center user/boot/wake button.

## What is complete

- Native KiCad schematic with exact part numbers, footprints, pin mapping, net names, and manufacturing notes.
- USB-C 5 V input, ESD protection, native ESP32-C6 USB, BQ24074 power-path charging, and a TPS63021 3.3 V buck-boost supply.
- Two independently selectable T5848 microphones on one stereo I²S bus at 1.85 V.
- SPI microSD with card detection, series damping, pull resistors, and local bulk capacitance.
- Visible recording and charging indicators, battery measurement, five zero-height UART/power/test pads, and monitored charger/regulator status.
- Manufacturer-drawing-derived footprints for the ESP32-C6-MINI-1, T5848, TPS63021 DSJ package, XFL4020 inductor, MEM2085 socket, and Molex USB-C socket.
- Machine-readable BOM, complete pin-to-net matrix, and electrical invariant checks.
- Four-layer fully connected PCB, locked symmetric ENIG stackup, all-layer antenna keepout, uninterrupted In1 GND plane, In2 3V3 distribution plane, and real KiCad 3D renders.
- Hardware power gates for both the microphone domain and microSD domain, with pull-downs that default both domains off during reset/deep sleep.
- Internal rear-side microSD socket whose complete body/card envelope stays inside the PCB outline.
- Hardware-bound recording indicator: powering the microphone domain necessarily lights the red LED.

The board is a **Rev C production candidate**, not production-qualified hardware. ERC, schematic parity, opens, shorts, ordinary copper clearance, and track-crossing checks are zero. The remaining nine DRC markers are the exact reviewed acoustic-port and connector-edge constructions in `DRC_WAIVERS.md`. The BQ_TS escape was narrowed locally to 0.10 mm and now retains at least 0.20 mm routed-edge clearance for JLCPCB. The package is for EVT/DFM, not unattended volume release.

## Files

- `neorecall-wearable-v1.kicad_sch` — generated KiCad schematic.
- `neorecall-wearable-v1.kicad_pro` — KiCad project.
- `neorecall-wearable-v1.kicad_pcb` — actual four-layer PCB layout.
- `renders/neorecall-top.png`, `renders/neorecall-bottom.png`, and `renders/neorecall-usb.png` — KiCad board and connector renders.
- `../../output/pdf/neorecall-wearable-v1-schematic.pdf` — rendered one-page A2 schematic PDF.
- `bom.csv` — one row per populated component with manufacturer part numbers.
- `pin-net-matrix.csv` — auditable pin-level connectivity.
- `design-summary.json` — dimensions and power/storage configuration.
- `PLACEMENT.md` — concrete PCB placement and thickness plan.
- `ASSEMBLY.md` — hand-assembly, bring-up, and battery-safety procedure.
- `SOURCES.md` — primary manufacturer sources used for electrical and mechanical decisions.
- `tools/generate_schematic.py` — electrical source of truth and deterministic generator.
- `tools/verify_design.py` — offline structural and electrical verification.
- `tools/verify_release.py` — verifies ERC/DRC reports and the exact mechanical-waiver signature.
- `tools/verify_functional_margins.py` — independently rechecks critical pin paths, charger/ADC/audio/storage arithmetic, and the complete JLC ZIP without importing the generator.
- `tools/verify_layout.py` — verifies board geometry, planes, antenna keepout, internal card envelope, switch nodes, power widths, and USB routing metrics with pcbnew.
- `tools/export_jlcpcb.sh` — generates the conventional four-layer Gerber/drill ZIP for direct JLCPCB upload.
- `firmware/manufacturing-test/` — build-tested ESP-IDF first-article firmware for power status, battery ADC, stereo microphones, microSD write/read/isolation, button, and deep-sleep wake.
- `fabrication/` — current EVT Gerber/drill/placement package and fab notes.
- `ELECTRICAL_AUDIT.md` — calculations, fault scenarios, sourcing review, and physical qualification matrix.

## Generate and verify

The only Python dependency is small; no KiCad application or model download is needed to regenerate the schematic.

```bash
python3 -m venv .venv-hardware
.venv-hardware/bin/pip install -r hardware/neorecall-wearable-v1/tools/requirements.txt
.venv-hardware/bin/python hardware/neorecall-wearable-v1/tools/generate_schematic.py
# Run sync_board.py with KiCad 10's bundled Python/pcbnew after regenerating.
.venv-hardware/bin/python hardware/neorecall-wearable-v1/tools/verify_design.py
.venv-hardware/bin/python hardware/neorecall-wearable-v1/tools/verify_release.py
.venv-hardware/bin/python hardware/neorecall-wearable-v1/tools/verify_functional_margins.py
# Run verify_layout.py with KiCad's bundled Python/pcbnew environment.
```

Open `hardware/neorecall-wearable-v1/neorecall-wearable-v1.kicad_pro` in KiCad 10 or newer. Run ERC and DRC again after any hand edit. Before ordering a PCB, select the actual 0.8 mm board-house stackup, solve USB D+/D− for 90 Ω differential impedance, and compare 1:1 footprint prints against physical parts.

The assembly BOM is now 71 fitted parts. TP1–TP5 are bare ENIG pogo/solder pads, excluded from the BOM and pick-and-place data: GPIO16/UART TX, GPIO17/UART RX, ESP_EN, 3V3, and GND. GPIO16/17 can be reassigned by firmware after boot, providing a compact two-signal expansion/debug interface without a connector, board-area increase, or assembly height.

## Fixed electrical decisions

- MCU/radio: `ESP32-C6-MINI-1-H8`, integrated antenna and 8 MB flash.
- Storage: `MEM2085-00-115-00-A` low-profile microSD socket with a genuine 16 GB high-endurance card.
- Microphones: two `MMICT5848-00-012`, one LR pin low and one high.
- Charger: `BQ24074RGTR`, approximately 201 mA cell charge, 500 mA USB input mode, power-path enabled.
- Main supply: fixed 3.3 V `TPS63021DSJR` with `XFL4020-152MEC` and 66 µF nominal output capacitance.
- Microphone supply: switchable 1.85 V `TPS7A20185PDBVR` plus `TXU0304PWR` level translation.
- Storage supply: switchable 3.3 V `TPS22918DBVR` with a 1 nF CT capacitor for an approximately 1.68 ms rail rise; firmware must unmount the card, disable SPI pins, then drive `SD_POWER_EN` low before deep sleep.
- Battery: protected 1S LiPo only, keyed three-pole JST-SH: pin 1 BAT+, pin 2 pack 10 kΩ NTC to GND at 25 °C, pin 3 GND.

The pack thermistor gives the BQ24074 real charge-temperature qualification. It is not a substitute for a protected, reputable cell, a locked mating-cable pinout, or enclosure thermal validation.

## Deep-sleep design

- `MIC_POWER_EN` removes the microphone LDO/translator domain; `R31` keeps it off through reset.
- `SD_POWER_EN` removes microSD and all card pull-up current; `R32` keeps it off through reset.
- TPS63021 power-save mode remains enabled so the always-on 3.3 V rail is efficient at light load.
- The battery divider is 1 MΩ + 330 kΩ, approximately 3.2 µA at a full 4.2 V cell.
- The center button reaches both GPIO0 (deep-sleep-capable wake) and GPIO9 (ROM boot strap); firmware must configure both as inputs and use GPIO0 for deep-sleep wake. There is intentionally no covert always-recording mode.

The estimated board-level deep-sleep budget is a design estimate, not a guaranteed measurement. Regulator, charger, MCU, divider, load-switch, translator, card leakage, temperature, and assembly contamination must be measured on at least three assembled boards before an endurance claim is published.

## Size and sourcing decision

The active outline remains 28 mm × 38 mm. The RF module antenna keepout, internal microSD envelope, opposed microphone ports, and edge-mounted USB and battery connectors set the usable geometry; shrinking the center PTS810 switch does not reduce the outline. Replacing it with a less common, less hand-reworkable switch would trade usability and sourcing resilience for no board-size win. The retained active ICs are current manufacturer parts, while the five incorrectly BOM-listed test-point components have been removed. The 1.85 V microphone rail and level translator remain electrically necessary because T5848 operates from 1.62–1.98 V; the obsolete 3.3 V ICS-43434 is not a valid consolidation substitute.
