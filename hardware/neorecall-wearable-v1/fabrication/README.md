# Rev C EVT fabrication package

This directory is generated from `neorecall-wearable-v1.kicad_pcb`. It is an EVT/DFM package, not a production qualification.

- Board: 28.0 mm × 38.0 mm, four copper layers, 0.80 mm finished thickness.
- Stackup encoded in the board: 35 µm outer copper, 0.10 mm prepreg, 18 µm In1, 0.494 mm core, 18 µm In2, 0.10 mm prepreg, 35 µm outer copper. The fabricator must confirm finished 0.80 mm thickness and impedance before substitution.
- Finish: ENIG recommended for the 0.40/0.50 mm-pitch parts and microphone lands.
- Solder mask: both sides; use the supplied mask plots without board-house expansion.
- Minimum routed track/space: 0.15 mm / 0.10 mm; minimum finished via drill 0.20 mm.
- The two 1.0 mm T5848 acoustic openings are NPTH and must remain unplated and unobstructed.
- J1 is mid-mounted. Its shell tabs intentionally intersect the board edge.
- In1 is an uninterrupted GND reference plane. In2 carries the 3V3 distribution plane plus slow signals.
- Do not place copper, panel tabs, tooling, or metal enclosure parts in the ESP32 antenna keepout.
- Drill/Gerber/PnP exports share the auxiliary origin at the board's upper-left corner. KiCad's placement CSV uses negative Y downward; do not mirror or renormalize it independently of the Gerbers.
- The assembly BOM and placement file contain 71 fitted references. TP1–TP5 are bare no-fit ENIG pads and must not be quoted or assembled as components.

Before ordering, provide the fabricator with `DRC_WAIVERS.md`, request a DFM report, confirm the 0.80 mm stack, and field-solve USB for 90 Ω differential impedance. The J2 thermistor escape intentionally uses JLCPCB's 0.10 mm advanced trace/clearance capability while retaining at least 0.20 mm copper-to-edge clearance. Use the first boards for controlled EVT bring-up before electrical, RF, acoustic, battery, environmental, and compliance evidence authorizes a larger build.
