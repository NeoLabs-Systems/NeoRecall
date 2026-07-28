#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARD="$ROOT/neorecall-wearable-v1.kicad_pcb"
OUT="$ROOT/fabrication"
CLI="${KICAD_CLI:-kicad-cli}"

python3 "$ROOT/tools/apply_stackup.py"

rm -rf "$OUT/gerbers" "$OUT/assembly"
mkdir -p "$OUT/gerbers" "$OUT/assembly"

"$CLI" pcb export gerbers --output "$OUT/gerbers" \
  --layers "F.Cu,In1.Cu,In2.Cu,B.Cu,F.Mask,B.Mask,F.Silkscreen,B.Silkscreen,Edge.Cuts" \
  --subtract-soldermask --check-zones --use-drill-file-origin "$BOARD"
"$CLI" pcb export drill --output "$OUT/gerbers" --format excellon \
  --drill-origin plot --excellon-units mm --excellon-separate-th --generate-map \
  --map-format gerberx2 --generate-report --report-path "$OUT/drill-report.txt" "$BOARD"
"$CLI" pcb export pos --output "$OUT/assembly/positions.csv" \
  --side both --format csv --units mm --smd-only --use-drill-file-origin "$BOARD"
cp "$ROOT/bom.csv" "$OUT/assembly/bom.csv"

(cd "$OUT/gerbers" && zip -q -FS "$OUT/neorecall-wearable-v1-gerbers.zip" ./*)
(cd "$OUT" && shasum -a 256 neorecall-wearable-v1-gerbers.zip > SHA256SUMS)
echo "Exported prototype fabrication package to $OUT"
