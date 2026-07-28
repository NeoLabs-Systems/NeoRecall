# Reviewed DRC mechanical markers

The checked-in `reports/final-drc.json` contains no shorts, ordinary electrical-clearance failures, crossing tracks, dangling tracks, or unconnected items. Its remaining nine markers are bounded footprint/edge constructions. `tools/verify_release.py` fails if their types, counts, or referenced parts change.

KiCad's library-copy mismatch check is disabled because the board generator intentionally moves footprint silkscreen graphics to fabrication layers on this unusually dense board. Schematic parity is checked independently, and `tools/verify_design.py` checks every critical custom pad number and position; the final KiCad 10 report has zero schematic-parity issues.

## T5848 acoustic ports — 6 markers

Each bottom-port TDK T5848 uses the manufacturer-required 1.0 mm non-plated acoustic opening inside its grounded annular land. KiCad therefore reports one pad-to-NPTH clearance, one GND-entry-track-to-NPTH clearance, and one solder-mask bridge for each of MK1 and MK2. Copper from every non-ground net remains clear of both ports.

## Connector and edge geometry — 3 markers

J1 shell tabs S3 and S4 intentionally meet the routed board edge because Molex 216990-0003 is a mid-mount connector. J2's outer mechanical land likewise reaches the boundary at the tightly packed side-entry connector. All signal traces, including BQ_TS, retain at least 0.20 mm routed-edge clearance. The BQ_TS/J2.3 corridor uses 0.10 mm trace width, a 0.10 mm local pad-clearance rule, and 0.1125 mm actual trace-to-pad clearance, within the selected advanced-process rule set.

These reviewed markers are not blanket waivers and are not a substitute for board-house DFM, 1:1 footprint checks, assembly trials, or electrical qualification.
