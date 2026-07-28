#!/usr/bin/env python3
"""Lock the reviewed symmetric 0.8 mm four-layer fabrication stackup."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BOARD = ROOT / "neorecall-wearable-v1.kicad_pcb"

STACKUP = '''\t\t(stackup
\t\t\t(layer "F.SilkS" (type "Top Silk Screen"))
\t\t\t(layer "F.Paste" (type "Top Solder Paste"))
\t\t\t(layer "F.Mask" (type "Top Solder Mask") (color "Green") (thickness 0.01))
\t\t\t(layer "F.Cu" (type "copper") (thickness 0.035))
\t\t\t(layer "dielectric 1" (type "prepreg") (thickness 0.1) (material "FR4") (epsilon_r 4.2) (loss_tangent 0.02))
\t\t\t(layer "In1.Cu" (type "copper") (thickness 0.018))
\t\t\t(layer "dielectric 2" (type "core") (thickness 0.494) (material "FR4") (epsilon_r 4.2) (loss_tangent 0.02))
\t\t\t(layer "In2.Cu" (type "copper") (thickness 0.018))
\t\t\t(layer "dielectric 3" (type "prepreg") (thickness 0.1) (material "FR4") (epsilon_r 4.2) (loss_tangent 0.02))
\t\t\t(layer "B.Cu" (type "copper") (thickness 0.035))
\t\t\t(layer "B.Mask" (type "Bottom Solder Mask") (color "Green") (thickness 0.01))
\t\t\t(layer "B.Paste" (type "Bottom Solder Paste"))
\t\t\t(layer "B.SilkS" (type "Bottom Silk Screen"))
\t\t\t(copper_finish "ENIG")
\t\t\t(dielectric_constraints yes)
\t\t)
'''


def main() -> int:
    content = BOARD.read_text(encoding="utf-8")
    if "\n\t\t(stackup\n" in content:
        print(f"Stackup already present in {BOARD}")
        return 0
    marker = "\t(setup\n"
    if marker not in content:
        raise RuntimeError(f"Cannot find setup section in {BOARD}")
    BOARD.write_text(content.replace(marker, marker + STACKUP, 1), encoding="utf-8")
    print(f"Applied 0.8 mm four-layer stackup to {BOARD}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
