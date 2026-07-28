#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARD="$ROOT/neorecall-wearable-v1.kicad_pcb"
OUT="$ROOT/fabrication/jlcpcb"
ZIP="$ROOT/fabrication/NeoRecall-RevC-JLCPCB-Gerbers.zip"
CLI="${KICAD_CLI:-kicad-cli}"

python3 "$ROOT/tools/apply_stackup.py"
rm -rf "$OUT"
rm -f "$ZIP" "$ZIP.sha256"
mkdir -p "$OUT"

"$CLI" pcb export gerbers --output "$OUT" \
  --layers "F.Cu,In1.Cu,In2.Cu,B.Cu,F.Mask,B.Mask,F.Silkscreen,B.Silkscreen,Edge.Cuts" \
  --subtract-soldermask --check-zones --precision 6 "$BOARD"

"$CLI" pcb export drill --output "$OUT" --format excellon \
  --drill-origin absolute --excellon-units mm --excellon-zeros-format decimal \
  --excellon-oval-format alternate --excellon-separate-th --generate-map \
  --map-format gerberx2 "$BOARD"

mv "$OUT/neorecall-wearable-v1-F_Cu.gtl" "$OUT/NeoRecall-F_Cu.gtl"
mv "$OUT/neorecall-wearable-v1-GND plane.g1" "$OUT/NeoRecall-In1_GND.g1"
mv "$OUT/neorecall-wearable-v1-3V3 plane _ slow signals.g2" "$OUT/NeoRecall-In2_3V3.g2"
mv "$OUT/neorecall-wearable-v1-B_Cu.gbl" "$OUT/NeoRecall-B_Cu.gbl"
mv "$OUT/neorecall-wearable-v1-F_Mask.gts" "$OUT/NeoRecall-F_Mask.gts"
mv "$OUT/neorecall-wearable-v1-B_Mask.gbs" "$OUT/NeoRecall-B_Mask.gbs"
mv "$OUT/neorecall-wearable-v1-F_Silkscreen.gto" "$OUT/NeoRecall-F_Silkscreen.gto"
mv "$OUT/neorecall-wearable-v1-B_Silkscreen.gbo" "$OUT/NeoRecall-B_Silkscreen.gbo"
mv "$OUT/neorecall-wearable-v1-Edge_Cuts.gm1" "$OUT/NeoRecall-Edge_Cuts.gm1"
mv "$OUT/neorecall-wearable-v1-PTH.drl" "$OUT/NeoRecall-PTH.drl"
mv "$OUT/neorecall-wearable-v1-NPTH.drl" "$OUT/NeoRecall-NPTH.drl"
mv "$OUT/neorecall-wearable-v1-PTH-drl_map.gbr" "$OUT/NeoRecall-PTH-drl_map.gbr"
mv "$OUT/neorecall-wearable-v1-NPTH-drl_map.gbr" "$OUT/NeoRecall-NPTH-drl_map.gbr"
rm -f "$OUT/neorecall-wearable-v1-job.gbrjob"

(cd "$OUT" && zip -q -FS "$ZIP" ./*)
shasum -a 256 "$ZIP" > "$ZIP.sha256"
echo "Exported JLCPCB upload archive: $ZIP"
