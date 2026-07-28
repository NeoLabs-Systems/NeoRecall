#!/usr/bin/env python3
"""Verify the checked-in ERC/DRC reports and reviewed mechanical markers."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / "reports"

def descriptions(violation: dict) -> list[str]:
    return [item["description"] for item in violation.get("items", [])]


def main() -> int:
    erc = json.loads((REPORTS / "final-erc.json").read_text())
    drc = json.loads((REPORTS / "final-drc.json").read_text())
    erc_violations = list(erc.get("violations", []))
    for sheet in erc.get("sheets", []):
        erc_violations.extend(sheet.get("violations", []))
    if erc_violations:
        raise RuntimeError(f"ERC has {len(erc_violations)} violation(s)")
    if drc.get("unconnected_items"):
        raise RuntimeError(f"PCB has {len(drc['unconnected_items'])} unconnected item(s)")
    if drc.get("schematic_parity"):
        raise RuntimeError(f"PCB has {len(drc['schematic_parity'])} schematic parity issue(s)")

    by_type: dict[str, list[dict]] = {}
    for violation in drc.get("violations", []):
        by_type.setdefault(violation["type"], []).append(violation)
    expected_counts = {
        "hole_clearance": 4,
        "copper_edge_clearance": 3,
        "solder_mask_bridge": 2,
    }
    actual_counts = {kind: len(items) for kind, items in by_type.items()}
    if actual_counts != expected_counts:
        raise RuntimeError(f"Unexpected DRC signature: {actual_counts}")

    edge_text = "\n".join(sum((descriptions(item) for item in by_type["copper_edge_clearance"]), []))
    for marker in ("Pad S3 [/GND] of J1", "Pad S4 [/GND] of J1",
                   "Pad MP [<no net>] of J2"):
        if marker not in edge_text:
            raise RuntimeError(f"Reviewed connector-edge marker missing: {marker}")
    if "Track [/BQ_TS]" in edge_text:
        raise RuntimeError("Battery temperature-sense copper no longer clears the routed edge")

    mic_text = "\n".join(sum((descriptions(item) for kind in ("hole_clearance", "solder_mask_bridge")
                                 for item in by_type[kind]), []))
    for reference in ("MK1", "MK2"):
        if f"NPTH pad of {reference}" not in mic_text or f"Pad 3 [/GND] of {reference}" not in mic_text:
            raise RuntimeError(f"Microphone waiver signature changed for {reference}")

    print("Release reports verified: ERC 0, unconnected 0, 9 reviewed geometry markers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
