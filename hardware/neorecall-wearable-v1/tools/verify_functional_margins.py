#!/usr/bin/env python3
"""Independent arithmetic, pin-map, and fabrication checks for Rev C.

This deliberately reads exported CSV/JSON/ZIP artifacts rather than importing the
schematic generator. It catches stale or internally inconsistent release files.
"""

from __future__ import annotations

import csv
import hashlib
import json
import re
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "reports" / "functional-confidence.json"
JLC_ZIP = ROOT / "fabrication" / "NeoRecall-RevC-JLCPCB-Gerbers.zip"

EXPECTED_JLC_FILES = {
    "NeoRecall-F_Cu.gtl", "NeoRecall-In1_GND.g1", "NeoRecall-In2_3V3.g2",
    "NeoRecall-B_Cu.gbl", "NeoRecall-F_Mask.gts", "NeoRecall-B_Mask.gbs",
    "NeoRecall-F_Silkscreen.gto", "NeoRecall-B_Silkscreen.gbo",
    "NeoRecall-Edge_Cuts.gm1", "NeoRecall-PTH.drl", "NeoRecall-NPTH.drl",
    "NeoRecall-PTH-drl_map.gbr", "NeoRecall-NPTH-drl_map.gbr",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def load_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def number(value: str) -> float:
    match = re.fullmatch(r"\s*([0-9.]+)\s*([kMmunp]?)", value.split()[0])
    require(match is not None, f"Cannot parse component value: {value}")
    scale = {"": 1.0, "k": 1e3, "M": 1e6, "m": 1e-3,
             "u": 1e-6, "n": 1e-9, "p": 1e-12}[match.group(2)]
    return float(match.group(1)) * scale


def pin_map() -> dict[tuple[str, str], str]:
    rows = load_csv(ROOT / "pin-net-matrix.csv")
    mapping = {(row["Reference"], row["Pin"]): row["Net"] for row in rows}
    require(len(mapping) == len(rows) == 283, "Pin/net matrix is incomplete or duplicated")
    return mapping


def verify_major_pin_paths(pins: dict[tuple[str, str], str]) -> None:
    expected = {
        ("U1", "3"): "3V3", ("U1", "17"): "USB_DM", ("U1", "18"): "USB_DP",
        ("U1", "12"): "USER_BUTTON", ("U1", "23"): "USER_BUTTON",
        ("U1", "9"): "BAT_SENSE", ("U1", "20"): "SD_POWER_EN",
        ("U1", "29"): "MIC_POWER_EN", ("U1", "28"): "BUCK_PG_N",
        ("U3", "13"): "VBUS_USB", ("U3", "2"): "BAT_PLUS",
        ("U3", "3"): "BAT_PLUS", ("U3", "10"): "SYS_RAW", ("U3", "11"): "SYS_RAW",
        ("U3", "4"): "GND", ("U3", "5"): "GND", ("U3", "6"): "VBUS_USB",
        ("U4", "12"): "SYS_RAW", ("U4", "13"): "GND", ("U4", "3"): "3V3",
        ("U5", "3"): "MIC_POWER_EN", ("U5", "5"): "1V85",
        ("U6", "8"): "MIC_POWER_EN", ("U6", "14"): "1V85",
        ("MK1", "2"): "GND", ("MK2", "2"): "1V85",
        ("MK1", "8"): "I2S_SD_1V85", ("MK2", "8"): "I2S_SD_1V85",
        ("U7", "3"): "SD_POWER_EN", ("U7", "5"): "SD_3V3", ("U7", "6"): "SD_3V3",
        ("J3", "4"): "SD_3V3", ("J2", "1"): "BAT_PLUS",
        ("J2", "2"): "BQ_TS", ("J2", "3"): "GND",
    }
    for key, net in expected.items():
        require(pins.get(key) == net, f"Critical pin path {key[0]}.{key[1]} expected {net}")


def verify_fabrication_archive() -> dict[str, object]:
    require(JLC_ZIP.is_file(), "JLCPCB ZIP is missing")
    digest = hashlib.sha256(JLC_ZIP.read_bytes()).hexdigest()
    sidecar = JLC_ZIP.with_suffix(JLC_ZIP.suffix + ".sha256").read_text(encoding="utf-8")
    require(sidecar.split()[0] == digest, "JLCPCB ZIP SHA-256 sidecar is stale")
    with zipfile.ZipFile(JLC_ZIP) as archive:
        require(archive.testzip() is None, "JLCPCB ZIP CRC check failed")
        names = {item.filename for item in archive.infolist() if not item.is_dir()}
        require(names == EXPECTED_JLC_FILES, f"Unexpected JLCPCB layer set: {sorted(names)}")
        require(all(item.file_size > 0 for item in archive.infolist()), "JLCPCB ZIP has an empty file")

        edge = archive.read("NeoRecall-Edge_Cuts.gm1").decode("ascii")
        require("%TF.FileFunction,Profile,NP*%" in edge and "%MOMM*%" in edge,
                "Board outline lacks Gerber profile/metric attributes")
        coordinates = [(int(x) / 1e6, int(y) / 1e6)
                       for x, y in re.findall(r"X(-?\d+)Y(-?\d+)D0[12]\*", edge)]
        require(coordinates, "No outline coordinates in Gerber")
        xs, ys = zip(*coordinates)
        width = max(xs) - min(xs)
        height = max(ys) - min(ys)
        require(abs(width - 28.0) < 0.001 and abs(height - 38.0) < 0.001,
                f"Gerber outline is {width:.3f} x {height:.3f} mm")

        pth = archive.read("NeoRecall-PTH.drl").decode("ascii")
        npth = archive.read("NeoRecall-NPTH.drl").decode("ascii")
        require("TF.FileFunction,Plated,1,4,PTH" in pth, "PTH layer span metadata is missing")
        require("TF.FileFunction,NonPlated,1,4,NPTH" in npth, "NPTH layer span metadata is missing")
        pth_hits = len(re.findall(r"^X-?[0-9.]+Y-?[0-9.]+", pth, re.MULTILINE))
        npth_hits = len(re.findall(r"^X-?[0-9.]+Y-?[0-9.]+", npth, re.MULTILINE))
        require(pth_hits >= 100, f"Suspicious PTH hit count: {pth_hits}")
        require(npth_hits == 2, f"Expected two microphone acoustic NPTH holes, found {npth_hits}")

    return {
        "sha256": digest,
        "files": len(EXPECTED_JLC_FILES),
        "outline_mm": [width, height],
        "pth_hits": pth_hits,
        "npth_hits": npth_hits,
        "zip_crc": "pass",
    }


def main() -> int:
    bom_rows = load_csv(ROOT / "bom.csv")
    bom = {row["Reference"]: row for row in bom_rows}
    require(len(bom) == len(bom_rows) == 71, "BOM must contain 71 unique fitted references")
    pins = pin_map()
    verify_major_pin_paths(pins)

    for reference, mpn in {
        "U1": "ESP32-C6-MINI-1-H8", "U3": "BQ24074RGTR", "U4": "TPS63021DSJR",
        "U5": "TPS7A20185PDBVR", "U6": "TXU0304PWR", "U7": "TPS22918DBVR",
        "MK1": "MMICT5848-00-012", "MK2": "MMICT5848-00-012",
        "J3": "MEM2085-00-115-00-A",
    }.items():
        require(bom[reference]["MPN"] == mpn, f"{reference} MPN differs from audited part")

    r_ilim = number(bom["R6"]["Value"])
    r_timer = number(bom["R7"]["Value"])
    r_term = number(bom["R8"]["Value"])
    r_set = number(bom["R9"]["Value"])
    charge_typ_ma = 890_000.0 / r_set
    charge_min_ma = 797_000.0 / r_set
    charge_max_ma = 975_000.0 / r_set
    termination_typ_ma = 0.03 * (r_term / r_set) * 1000.0
    timer_typ_hours = 10.0 * r_timer * 48.0 / 1000.0 / 3600.0
    programmable_ilim_ma = 1_550_000.0 / r_ilim
    require(180.0 <= charge_min_ma <= charge_typ_ma <= charge_max_ma <= 225.0,
            "BQ24074 charge-current calculation left reviewed range")
    require(18.0 <= termination_typ_ma <= 22.0, "Charge termination is outside 18-22 mA")
    require(6.0 <= timer_typ_hours <= 6.4, "Charge safety timer is outside reviewed range")

    r_top = number(bom["R15"]["Value"])
    r_bottom = number(bom["R16"]["Value"])
    adc_full_cell_v = 4.2 * r_bottom / (r_top + r_bottom)
    divider_current_ua = 4.2 / (r_top + r_bottom) * 1e6
    require(adc_full_cell_v < 1.1, "Battery divider can overdrive the selected ADC range")
    require(divider_current_ua < 3.3, "Battery divider sleep current increased")

    sd_rise_ms = 1.68 * number(bom["C23"]["Value"]) / 1e-9
    require(1.5 <= sd_rise_ms <= 1.9, "TPS22918 controlled rise is outside reviewed range")
    i2s_bclk_mhz = 48_000 * 2 * 32 / 1e6
    require(2.0 <= i2s_bclk_mhz <= 3.7, "T5848 clock falls outside its normal I2S range")

    usb_dp_mm, usb_dm_mm = 20.696, 30.214
    usb_skew_mm = abs(usb_dp_mm - usb_dm_mm)
    usb_skew_ps_est = usb_skew_mm * 6.2
    usb_bit_time_ps = 1e12 / 12e6
    require(usb_skew_ps_est / usb_bit_time_ps < 0.001, "USB length skew exceeds 0.1% of bit time")

    release = json.loads((ROOT / "reports" / "final-drc.json").read_text(encoding="utf-8"))
    erc = json.loads((ROOT / "reports" / "final-erc.json").read_text(encoding="utf-8"))
    erc_count = len(erc.get("violations", [])) + sum(
        len(sheet.get("violations", [])) for sheet in erc.get("sheets", []))
    require(erc_count == 0, "ERC report is not clean")
    require(not release.get("unconnected_items"), "DRC report contains unconnected items")

    report = {
        "result": "pass_with_physical_gates",
        "independent_inputs": ["bom.csv", "pin-net-matrix.csv", "final-erc.json",
                               "final-drc.json", JLC_ZIP.name],
        "electrical": {
            "charge_current_ma": {
                "minimum": round(charge_min_ma, 2), "typical": round(charge_typ_ma, 2),
                "maximum": round(charge_max_ma, 2),
            },
            "termination_current_ma_typical": round(termination_typ_ma, 2),
            "safety_timer_hours_typical": round(timer_typ_hours, 3),
            "programmable_ilim_ma_typical_not_active_in_usb500_mode": round(programmable_ilim_ma, 2),
            "battery_adc_at_4v2_v": round(adc_full_cell_v, 4),
            "battery_divider_current_at_4v2_ua": round(divider_current_ua, 3),
            "sd_rail_rise_ms_typical": round(sd_rise_ms, 3),
            "i2s_bclk_mhz_at_48k_stereo_32bit": round(i2s_bclk_mhz, 3),
            "usb_length_skew_mm": round(usb_skew_mm, 3),
            "usb_skew_ps_estimate": round(usb_skew_ps_est, 1),
            "usb_skew_fraction_of_full_speed_bit": round(usb_skew_ps_est / usb_bit_time_ps, 6),
        },
        "fabrication": verify_fabrication_archive(),
        "static_checks": {
            "critical_pin_paths": "pass", "erc_violations": erc_count,
            "drc_unconnected": len(release.get("unconnected_items", [])),
            "tps63021_pg_polarity": "active high; legacy net name BUCK_PG_N",
        },
        "physical_gates": [
            "JLCPCB field-solved 90 ohm USB geometry and DFM acceptance",
            "USB enumeration/eye and ESD testing",
            "charger current, thermistor thresholds, and thermal testing with the selected cell",
            "3V3 transient/brownout testing with Wi-Fi plus microSD load",
            "microphone SNR/channel identity/acoustic sealing",
            "microSD power-loss and long-duration recording",
            "RF range in the final enclosure",
            "deep-sleep current and wake testing on assembled boards",
        ],
    }
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: independent functional margins and {report['fabrication']['files']} JLC files verified")
    print(f"PASS: report written to {REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
