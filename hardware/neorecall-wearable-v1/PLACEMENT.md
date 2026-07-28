# Placement and mechanical plan

## Board stack

- Outline: 28.0 mm × 38.0 mm, portrait.
- PCB: four copper layers, 0.80 mm finished thickness.
- Locked stack: L1 35 µm components/high-speed, 0.10 mm prepreg, L2 18 µm uninterrupted ground, 0.494 mm core, L3 18 µm 3V3/slow control, 0.10 mm prepreg, L4 35 µm storage/low-speed; ENIG finish.
- Use controlled 90 Ω differential impedance for USB D+/D− and have the fabricator adjust dielectric/trace geometry if its qualified process differs.
- Minimum practical rules: 0.10 mm track/space, 0.20 mm finished via with 0.45 mm pad, 0.10 mm solder-mask dam. Confirm these with the selected fabricator.

## Coordinate convention

Origin is the upper-left board corner, X increases right, and Y increases downward. Front is the component/button side. Coordinates below are footprint centers and are intended as the first PCB placement pass.

| Reference | Side | X (mm) | Y (mm) | Placement constraint |
|---|---:|---:|---:|---|
| U1 ESP32-C6-MINI-1 | Front | 14.0 | 8.3 | Antenna end flush with top edge; no copper, trace, component, or battery in antenna keepout on any layer. |
| MK1 | Front | 3.0 | 19.0 | Acoustic port to 1.00 mm non-plated PCB hole; enclosure port directly below with gasket. |
| MK2 | Front | 25.0 | 19.0 | Same acoustic construction; gives about 22 mm microphone spacing. |
| SW1 | Front | 14.0 | 19.0 | Exact board center; actuator faces enclosure center opening. |
| J1 USB-C | Front/mid-mount | 14.0 | 34.1 | Centered on bottom edge; mating face extends through the routed board edge. |
| J2 battery | Front | 3.2 | 35.2 | Side-facing keyed JST-SH; pin 1 BAT+, pin 2 pack 10 kΩ NTC, pin 3 GND. |
| J3 microSD | Rear | 20.2 | 27.9 | Rotated so the complete socket/card envelope stays inside the board; service access is from inside the enclosure. |
| U3 charger | Front | 6.0 | 29.5 | Close to USB VBUS, battery connector, and local input/battery/system capacitors. |
| U4 buck-boost | Front | 23.0 | 28.7 | C4–C7/C20/C21 surround the regulator and its short power loops. |
| L1 | Front | 23.0 | 33.3 | Rotated for two direct 3.793 mm, via-free switch-node routes. |
| U5 audio LDO | Front | 7.0 | 23.0 | Kept away from the buck switch nodes and beside the gated microphone domain. |
| U6 I²S translator | Front | 14.0 | 23.8 | Between MCU and microphones, outside the switch-node field. |

The coordinates describe the routed Rev C production candidate. The KiCad renders visualize both sides from the actual board file.

## RF rules

1. Put the ESP32-C6 module antenna at the board edge as shown.
2. Respect the exact Espressif module antenna keepout on all four copper layers.
3. Do not place the LiPo, microSD metal shell, USB cable path, enclosure metal, or a ground pour in front of/under the antenna.
4. Route USB and the switching regulator away from the antenna zone.
5. Verify conducted power, reconnect behavior, and real enclosure range on the assembled prototype; the enclosure changes antenna tuning.

## Acoustic rules

1. Use one 1.00 mm non-plated hole under each T5848 sound port. This stays inside TDK's 0.5–1.0 mm recommendation and preserves almost all of the specified 1.025 mm inner land opening.
2. Do not place copper, mask, paste, glue, or conformal coating in the acoustic hole.
3. Use a thin closed-cell gasket from PCB underside to enclosure port so sound cannot leak between the two microphone cavities.
4. Keep L1/U4 and microSD clock traces away from both microphone supply and sound-port regions.
5. Never clean the populated microphones ultrasonically or direct compressed air/liquid through the ports.

## Thickness budget

The enclosure must not stack the battery behind the PCB. Use the three-wire cable to place the cell beside the board.

| Item | Height from PCB surface |
|---|---:|
| Center PTS810 button | 2.50 mm front |
| ESP32-C6-MINI-1 module | 2.40 mm front |
| XFL4020 inductor | 2.10 mm front |
| T5848 microphones | 0.98 mm front |
| MEM2085 microSD socket | 1.15 mm rear |
| TPS22918 load switch | 1.45 mm rear |
| PCB | 0.80 mm |

The bounding component stack is therefore 2.50 + 0.80 + 1.45 = **4.75 mm**. That leaves only 0.25 mm inside a 5.00 mm external target for adhesive, enclosure walls, tolerances, and air gaps, so a truly sub-5-mm finished enclosure is not realistic with protective shells on both sides. The **populated PCB** is under 5 mm; the finished wearable will need a locally pocketed enclosure or a slightly higher external thickness target.
