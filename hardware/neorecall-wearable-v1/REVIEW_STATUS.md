# Rev C production-candidate review status

## Safe conclusion

The KiCad files are a fully routed **production candidate**, not production-qualified hardware. They are suitable for controlled EVT fabrication and independent DFM/review. Series release still requires assembled-board measurements, environmental testing, compliance work, and a locked battery/enclosure BOM.

## Verified in the design files

- 71 populated references, five no-fit PCB test pads, and 283 mapped pins pass deterministic connectivity and component-value invariants.
- KiCad ERC reports zero violations. PCB DRC reports zero unconnected items, shorts, electrical clearance failures, crossing tracks, or dangling tracks.
- The only nine DRC markers exactly match `DRC_WAIVERS.md`: six acoustic-port geometry markers and three intentional connector-edge markers. No short, ordinary clearance, track-crossing, courtyard, dangling-track, or signal-trace edge marker remains.
- The board is 28 mm × 38 mm nominal, four copper layers, and 0.80 mm thick. The assembled PCB envelope is 4.75 mm before enclosure tolerances.
- In1 contains no tracks and is the continuous GND reference plane; In2 includes the 3V3 distribution plane. The ESP32 antenna has one keepout spanning all four copper layers. The symmetric 0.8 mm ENIG stackup is encoded in the board.
- J3 is rear-mounted and its complete MEM2085 mechanical envelope remains inside the board outline; the microSD card is an internal/service item and does not protrude.
- J1 is a real Molex 216990-0003 mid-mount USB-C receptacle at the bottom edge, with both CC pull-downs, orientation-duplicated D+/D− contacts, VBUS TVS, USB data ESD, and native ESP32-C6 USB.
- Total routed USB copper is 20.696 mm for D+ and 30.214 mm for D−: 9.517 mm mismatch, with symmetric via count and 0.15 mm minimum width. Final 90 Ω differential geometry and the skew must still be reviewed with the chosen fabricator stackup.
- TPS63021 switch nodes are each 3.793 mm long, at least 0.30 mm wide, and use no vias. Primary VBUS, battery, system, 3.3 V, 1.85 V, and switched-microSD routes are at least 0.30 mm wide.
- Both high-drain peripheral domains default off through 100 kΩ pull-downs. The recording LED is hardware-bound to `MIC_POWER_EN`, so the microphone domain cannot be powered without a visible red indicator.
- The TPS22918 pinout follows TI: CT has 1 nF for an approximately 1.68 ms rise, QOD is tied to the switched rail, and VOUT drives `SD_3V3`.
- `tools/verify_functional_margins.py` independently parses the exported BOM, 283-pin matrix, ERC/DRC JSON, and JLCPCB ZIP. It re-derives the charger, battery-divider, I²S-clock, storage-rise, and USB-skew numbers and verifies the 13 fabrication files, SHA-256/CRC, 28 mm × 38 mm outline, 112 PTH hits, and two acoustic NPTH holes.
- `firmware/manufacturing-test` compiles and links for ESP32-C6 with ESP-IDF 5.4.2. On first articles it exercises the regulator/status inputs, GPIO0/GPIO9 button net, calibrated battery ADC, both T5848 I²S slots, synchronized microSD write/read/compare, safe SPI isolation before card power-off, and GPIO0 deep-sleep wake.
- TPS63021 `PG` is active high: its open-drain output releases R30 to pull the MCU input high when 3.3 V is good and pulls low on failure. The routed net retains the legacy name `BUCK_PG_N`, so firmware must not infer polarity from that name.
- BQ24074 EN1 is asserted from VBUS rather than the downstream 3V3 rail. J2 is a keyed three-wire protected-pack connection with a real 10 kΩ NTC input. GPIO0 and GPIO9 share the center button for deep-sleep wake plus ROM boot.
- R29 pulls card detect to always-on 3.3 V so insertion state remains defined while card power is off.
- Gerber/drill outputs, BOM, position data, schematic PDF, and 3D renders are regenerated from the final files.
- Schematic-to-PCB parity is zero. All project, board, schematic, symbol, and custom-footprint files have been rewritten in KiCad 10 format.

## Qualification blockers before series release

1. Have the board house accept or adjust the encoded 0.8 mm stack, field-solve USB for 90 Ω differential impedance, review the 9.517 mm skew and locally constrained J2 thermistor escape, and pass repeated enumeration plus signal-integrity testing.
2. Lock a protected 1S three-wire LiPo pack whose polarity, 10 kΩ NTC curve, capacity, continuous current, 201 mA charge rating, pouch construction, and regulatory documents are known.
3. Assemble EVT units and measure regulator load steps, switch-node ringing/EMI, charger full-cycle temperature, battery current, deep-sleep current, Wi-Fi/microSD simultaneous burst behavior, and all brownout/reset paths.
4. Qualify microphone SNR, clock coupling, acoustic gaskets, port contamination resistance, wind performance, and the final enclosure.
5. Qualify Wi-Fi/BLE range and antenna detuning with the real battery, body position, enclosure, and clip/strap.
6. Run microSD endurance, removal/power-loss, filesystem recovery, bad-card, full-card, and long-backlog tests using the locked high-endurance card SKU.
7. Complete ESD, radiated/conducted emissions, immunity, thermal, drop, sweat/humidity, USB mechanical-cycle, button-cycle, and charging safety tests.

## EVT release gate

Run `tools/verify_design.py`, `tools/verify_release.py`, and `tools/verify_layout.py`; print critical footprints at 1:1; obtain independent schematic/layout and board-house DFM reviews; then build at least three EVT units under current-limited bring-up. Execute the fault matrix in `ELECTRICAL_AUDIT.md`. No design-only review can honestly guarantee 100% physical operation.
