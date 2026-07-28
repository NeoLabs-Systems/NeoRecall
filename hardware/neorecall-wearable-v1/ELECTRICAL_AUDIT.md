# Electrical, sourcing, and fault audit

Audit date: 2026-07-17. This is a design-file audit for EVT, not a claim that unbuilt hardware is production-qualified. ERC, DRC, parity, geometry, connectivity, values, footprints, and manufacturing outputs can be checked deterministically; power integrity, RF, acoustics, USB eye margin, thermal behavior, battery safety, and component variation require physical boards.

The independent release pass is recorded in `reports/functional-confidence.json`. Unlike the generator-based structural test, it consumes the exported BOM, pin matrix, ERC/DRC reports, and final JLCPCB ZIP directly. The first-article application in `firmware/manufacturing-test` also compiles and links for the ESP32-C6 under ESP-IDF 5.4.2; running it on assembled boards is still required.

TPS63021 pin 14 `PG` is active high despite the routed legacy net name `BUCK_PG_N`: R30 pulls the signal high when the open-drain output indicates good regulation, and the regulator pulls it low on failure. The manufacturing firmware tests the actual active-high behavior.

The center button also drives GPIO9, but ESP32-C6 deep-sleep wake produces a core reset while the boot-strapping latches are sampled on chip reset. The intended GPIO0 wake path is therefore technically consistent; the manufacturing firmware still makes a real sleep/wake cycle a mandatory first-article test because holding the same button during a power-on or hardware reset intentionally requests download boot.

## Design-file conclusion

No schematic error was found that is known to prevent basic operation. KiCad 10 reports zero ERC violations, zero unconnected PCB items, zero shorts, zero ordinary clearance/crossing errors, and zero schematic-parity issues. The nine remaining reviewed geometry markers are bounded in `DRC_WAIVERS.md`. The board remains an EVT candidate until the physical release matrix below passes.

The board is 28 mm × 38 mm, four-layer, and 0.8 mm thick. Its size is set primarily by the ESP32 module/antenna keepout, internal microSD socket, side microphone ports, and edge connectors. A smaller center switch does not reduce those constraints, so the common C&K PTS810 was retained. Five formerly BOM-listed “test-point components” were corrected to no-fit ENIG pads, reducing the fitted count from 76 to 71 without losing access.

## Power path and charger

- U3 is BQ24074 with EN2 low and EN1 tied to VBUS, selecting USB500 whenever input power exists without depending on the downstream 3V3 rail. R6 is 3.09 kΩ, giving the intended approximately 500 mA input limit. R9 is 4.42 kΩ for approximately 201 mA fast charge, R8 is 2.94 kΩ for approximately 20 mA termination, and R7 is 46.4 kΩ for approximately 6.2 hours of safety-timer duration. These values follow the programming equations and mode table in the [BQ24074 datasheet](https://www.ti.com/lit/ds/symlink/bq24074.pdf).
- The charger power-path output feeds SYS_RAW, so the product can operate from USB with no battery. This must be demonstrated across plug-in, unplug, a deeply discharged protected cell, protection-FET trip, and a weak/collapsing USB source.
- J2 has BAT+, BQ_TS, and GND conductors. The locked pack must present a 10 kΩ NTC from TS to GND at 25 °C so the charger can inhibit charging outside its qualified temperature window. A protected, polarity-locked pack and enclosure thermal test remain mandatory.
- U4 TPS63021 produces the always-on 3.3 V rail from SYS_RAW. The design uses the specified 1.5 µH inductor, about 20 µF nominal input capacitance, and 66 µF nominal output capacitance. Both switch-node routes are 3.793 mm, at least 0.30 mm wide, and have no vias; the three output reservoirs were moved beside U4 and In2 now distributes 3V3. This follows the close-loop placement intent in the [TPS63021 datasheet](https://www.ti.com/lit/ds/symlink/tps63021.pdf), but oscilloscope load-step and ringing measurements remain required.
- ESP32-C6 guidance calls for a 3.3 V source capable of at least 500 mA with local bulk decoupling. The selected regulator is suitable on paper; simultaneous Wi-Fi transmit, microSD write, both microphones, and LED load is the worst normal transient to qualify. See the [ESP32-C6 schematic checklist](https://docs.espressif.com/projects/esp-hardware-design-guidelines/en/latest/esp32c6/schematic-checklist.html).
- MIC_POWER_EN and SD_POWER_EN each have 100 kΩ pull-downs, making both high-drain peripheral domains default off while the MCU is high-impedance. Power-save mode remains selected on the main converter. Sleep current is a measurement, not a sum-of-typicals guarantee.

## USB-C and ESD

- J1 exposes USB 2.0 device mode with independent 5.1 kΩ CC1/CC2 pull-downs, VBUS TVS, USBLC6-2SC6 data ESD, and 22 Ω source-series resistors at the ESP32 pins. Both connector orientations are joined correctly.
- The complete copper paths measure 20.696 mm for D+ and 30.214 mm for D−, a 9.517 mm mismatch, with symmetric via counts and 0.15 mm minimum width. The absolute full-speed paths remain short, but the geometry is not yet impedance- or eye-qualified and the skew should be reviewed during DFM.
- Espressif specifies 90 Ω ±10% differential impedance, parallel/equal-length routing, a continuous reference plane, minimal vias, and nearby ground return vias at layer transitions. This board has a continuous In1 ground plane, but the nearest ground vias to the data transitions are approximately 4.2–5.8 mm away and the length mismatch is not ideal. The chosen board-house stack must be field-solved and EVT must pass repeated A-to-C and C-to-C enumeration plus signal-integrity testing. See the [ESP32-C6 PCB-layout guidance](https://docs.espressif.com/projects/esp-hardware-design-guidelines/en/latest/esp32c6/pcb-layout-design.html).
- Test ESD at the exposed USB shell, contacts, button, charging cable, microphone ports, and enclosure seams. Check both recoverable reset and permanent-damage behavior; schematic protection parts alone do not establish system-level immunity.

## ESP32-C6 boot and expansion

- The relevant strap pins are GPIO4, GPIO5, GPIO8, GPIO9, and GPIO15. GPIO9 has a 10 kΩ pull-up and the center button pulls it low, providing ROM download entry. GPIO8 has a 10 kΩ pull-up, giving the valid joint download-mode condition when the button is held at reset.
- GPIO15 drives SD_POWER_EN and has a 100 kΩ pull-down, so it is never left floating. Its reset-low value selects pad JTAG only if the related eFuse configuration enables that selection; production firmware/eFuse programming must be validated before locking security settings.
- GPIO4 is battery ADC and GPIO5 is SD MISO. Their attached circuits must not force an invalid boot strap at reset; test with card absent/present, every qualified card, battery absent/full/low, and USB connected/disconnected. The definitive strap behavior is in the [ESP32-C6 datasheet](https://documentation.espressif.com/esp32-c6_datasheet_en.html?q=ESP32-C6).
- GPIO0 and GPIO9 both connect to the center button: GPIO0 provides a deep-sleep-capable wake source and GPIO9 retains ROM-download boot control. GPIO14 remains unconnected. TP1 and TP2 expose GPIO16/TX and GPIO17/RX as remappable post-boot signals; TP3–TP5 expose ESP_EN, 3V3, and GND. These pads cost no fitted parts or connector height.

## Audio and storage domains

- Both T5848 microphones are current 1.62–1.98 V I²S parts, one left-slot and one right-slot. U5 provides a switched 1.85 V rail and U6 TXU0304 has fixed directions matching BCLK/WS toward the microphones and shared data toward the ESP32. TXU0304 supplies partial-power-down isolation as described in the [TXU0304 datasheet](https://www.ti.com/lit/ds/symlink/txu0304.pdf).
- The red recording LED is powered from the microphone enable domain: the microphones cannot be intentionally powered without energizing the indicator circuit. This is a useful hardware binding, not a safety proof—a shorted LED, open LED, blocked lens, solder fault, or malicious external power fault must be considered.
- The bottom-port microphones require clear NPTH acoustic openings, correct gasket geometry, and no solder/paste contamination. Verify channel selection, BCLK/WS timing, DC silence, acoustic SNR, cross-talk, RF demodulation, wind, sweat, and blocked-port behavior.
- U7 removes microSD power. C23 on CT controls the 3.3 V rise to approximately 1.68 ms, reducing card-capacitor inrush. Firmware must finish writes, sync/unmount the filesystem, put SPI pins in a non-back-powering state, and only then deassert SD_POWER_EN. At startup it must tolerate absent, slow, corrupt, unsupported, counterfeit, read-only, full, worn, and unexpectedly removed cards.
- R29 keeps card detect on the always-on 3.3 V domain. Exercise card insertion/removal while SD power is both on and off, and interrupt power at every filesystem-operation boundary.

## Component availability and consolidation

The active IC choices were checked against manufacturer lifecycle information and broad-distributor listings on the audit date. TDK lists T5848 as a production product, and current distributor stock is substantial ([TDK product page](https://www.invensense.tdk.com/en-us/products/microphone/t5848/), [Mouser listing](https://www.mouser.com/ProductDetail/TDK-InvenSense/MMICT5848-00-012?qs=tlsG%2FOw5FFiltxCTf6WOrw%3D%3D)). TI lists TPS63021 as active, and BQ24074/TXU0304 are stocked catalog parts ([TPS63021](https://www.ti.com/mx/lit/gpn/tps63021), [BQ24074 distributor listing](https://www.mouser.com/ProductDetail/Texas-Instruments/BQ24074RGTR?qs=ZV%2Fxhq4oszp2Nll7fIx5wg%3D%3D), [TXU0304 distributor listing](https://www.mouser.de/ProductDetail/Texas-Instruments/TXU0304PWR?qs=QNEnbhJQKvZVYXIKZoXs0A%3D%3D)). The USB connector, inductor, and PTS810 switch also have current distribution ([Molex 216990-0003](https://www.mouser.com/ProductDetail/Molex/216990-0003?qs=DRkmTr78QASn0GILUGAYCA%3D%3D), [XFL4020-152MEC](https://www.trustedparts.com/en/part/coilcraft/XFL4020-152MEC), [PTS810](https://www.trustedparts.com/en/part/ck-switches/PTS810%20SJM%20250%20SMTR%20LFS)).

No active part was replaced solely to reduce line count. Removing the 1.85 V LDO or translator would violate the T5848 supply range; the superficially convenient 3.3 V ICS-43434 is officially end-of-life ([TDK ICS-43434 status](https://www.invensense.tdk.com/en-us/products/microphone/ics-43434)). Approved alternates should be qualified by electrical limits, lifecycle, footprint, acoustic response, firmware protocol, and actual supply—not by name similarity. Commodity 0603 passives may use exact-spec second sources after voltage, dielectric, tolerance, temperature coefficient, pulse behavior, and package are matched.

## Physical fault and qualification matrix

| Area | Scenarios to force | Passing evidence |
|---|---|---|
| USB power | Battery absent, full, low, protection-tripped, attached/reversed test fixture; A-to-C and C-to-C; cable resistance; weak source; hot plug/unplug during every mode | No damage or latch-up; bounded inrush; stable SYS_RAW/3V3; correct charge state; repeatable recovery |
| Charger/battery | Charge from empty to termination; recharge threshold; safety timer; system load during charge; minimum/maximum allowed ambient; enclosed operation; pack disconnect | Current/voltage within programmed limits; safe component/cell temperatures; no oscillation; documented pack qualification |
| Main rail | Wi-Fi transmit + SD write + stereo capture + both LEDs; burst and sustained loads; brownout; battery-to-USB handoff | 3V3 stays inside every load limit; acceptable overshoot/ripple/ringing; reset cause and data recovery correct |
| Boot/reset | Every power-source combination; button held/tapped/bouncing; EN pulse; watchdog; brownout at each firmware state; secure-boot/eFuse configuration | Correct normal/download boot; no strap-dependent intermittent failure; deterministic recovery |
| USB data | Both plug orientations, cable qualities/lengths, hubs, OS hosts, repeated reset/enumeration, ESD, chosen stackup | Enumeration stress pass and acceptable eye/waveform with no unexplained disconnects |
| microSD | Absent, known-good variants, slow/bad/counterfeit, full, read-only, corrupt, worn, hot removal; power cut at every write/unmount boundary | No rail back-power; bounded recovery; filesystem remains recoverable; clear user-visible failure; no silent loss |
| Audio | Each mic open/short, clock/data fault, blocked/wet port, RF transmit, vibration, loud/quiet signals, temperature | Correct slots; required SNR/bandwidth; no destructive fault; failure is detected and reported |
| RF | Battery/enclosure/body/clip positions, USB cable attached, SD activity, wet enclosure, channel extremes | Required Wi-Fi/BLE range and coexistence; no reset, audio corruption, or prohibited emissions |
| Sleep/wake | Minimum/maximum temperature and battery voltage; card inserted/absent; contamination; long soak; every wake source | Measured current meets the product budget; reliable wake; no powered-down-domain leakage |
| Mechanical/environment | Drop, bend, sweat/humidity, dust at ports, button/USB/card cycles, ESD/immunity, thermal cycling | No exposed battery hazard, intermittent joints, connector damage, port blockage, or loss of function |
| Manufacturing | AOI/microscope, X-ray exposed pads, bed-of-nails access, fixture misalignment, open/short injection, multiple component lots | Repeatable programming and test coverage; traceable failures; no untested safety-critical path |

## Data-retention invariant

Hardware and firmware qualification must preserve the system reliability invariant under every reset, brownout, card, network, and server-failure injection: the client may release its local audio only after a terminal receipt proves both transcript persistence and server-side audio deletion. A network acknowledgement, upload completion, transcription start, or local queue update is not sufficient. Tests must interrupt power/process/network at every state transition, retry idempotently, and prove that neither premature deletion nor permanent duplicate processing occurs.

## EVT release gate

1. Obtain independent schematic/layout review and board-house DFM; print every custom footprint 1:1 against purchased parts.
2. Have the fabricator accept or adjust the locked symmetric 0.8 mm four-layer stack, field-solve the USB pair, and review return-current transitions and the locally constrained J2 thermistor escape.
3. Build at least three boards from at least two component lots when practical; use current-limited bring-up and thermal inspection.
4. Record rail startup, load steps, switch-node ringing, USB waveforms, charge cycles, sleep current, RF range, and calibrated acoustic results across voltage and temperature.
5. Execute the fault matrix and the data-retention interruption campaign. Preserve raw traces, firmware versions, BOM lots, board serials, and pass/fail criteria.
6. Complete applicable battery, EMC, radio, product-safety, and environmental compliance before series release.
