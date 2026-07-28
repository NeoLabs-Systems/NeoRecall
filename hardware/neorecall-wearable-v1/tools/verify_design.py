#!/usr/bin/env python3
"""Offline structural and electrical verification for NeoRecall Wearable v1."""

from __future__ import annotations

import csv
import json
import re
import sys
from pathlib import Path

import generate_schematic as design


ROOT = Path(__file__).resolve().parents[1]
FOOTPRINT_DIR = ROOT / "lib" / "NeoRecall_Wearable.pretty"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def balanced_sexpr(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    depth = 0
    in_string = False
    escaped = False
    for character in text:
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            require(depth >= 0, f"{path}: closing parenthesis without opening parenthesis")
    require(not in_string, f"{path}: unterminated quoted string")
    require(depth == 0, f"{path}: unbalanced S-expression (depth {depth})")


def footprint_pads(name: str) -> set[str]:
    path = FOOTPRINT_DIR / f"{name}.kicad_mod"
    require(path.is_file(), f"Missing custom footprint {path}")
    balanced_sexpr(path)
    return {match for match in re.findall(r'\(pad\s+"([^"]*)"', path.read_text(encoding="utf-8")) if match}


def footprint_pad_position(name: str, pad: str) -> tuple[float, float]:
    text = (FOOTPRINT_DIR / f"{name}.kicad_mod").read_text(encoding="utf-8")
    match = re.search(rf'\(pad\s+"{re.escape(pad)}".*?\(at\s+(-?[0-9.]+)\s+(-?[0-9.]+)', text, re.DOTALL)
    require(match is not None, f"{name}: missing positioned pad {pad}")
    return float(match.group(1)), float(match.group(2))


def part(reference: str) -> design.Part:
    return next(item for item in design.PARTS if item.reference == reference)


def verify_connectivity() -> None:
    design.validate_design()

    require(part("D1").pin_nets == {"1": "VBUS_USB", "2": "GND"}, "VBUS TVS polarity is reversed")
    require(part("J2").pin_nets == {"1": "BAT_PLUS", "2": "BQ_TS", "3": "GND"},
            "Battery/temperature connector pinout changed")
    require(part("SW1").pin_nets == {"1": "USER_BUTTON", "2": "GND"}, "Center boot/user switch changed")

    usb = part("J1").pin_nets
    require(usb["A4_B9"] == usb["B4_A9"] == "VBUS_USB", "USB-C VBUS contacts are not tied")
    require(usb["A6"] == usb["B6"] == "USB_DP_CONN", "USB-C D+ orientation contacts are not tied")
    require(usb["A7"] == usb["B7"] == "USB_DM_CONN", "USB-C D- orientation contacts are not tied")
    require(part("R3").value == part("R4").value == "5.1k 1%", "USB-C CC pull-down values changed")
    require(part("R3").pin_nets == {"1": "USB_CC1", "2": "GND"}, "CC1 pull-down wiring changed")
    require(part("R4").pin_nets == {"1": "USB_CC2", "2": "GND"}, "CC2 pull-down wiring changed")

    charger = part("U3")
    require(charger.pin_nets["13"] == "VBUS_USB", "Charger input is not on USB VBUS")
    require(charger.pin_nets["2"] == charger.pin_nets["3"] == "BAT_PLUS", "Charger battery path changed")
    require(charger.pin_nets["10"] == charger.pin_nets["11"] == "SYS_RAW", "Charger power-path output changed")
    require(charger.pin_nets["4"] == charger.pin_nets["5"] == "GND" and charger.pin_nets["6"] == "VBUS_USB",
            "BQ24074 enable/input-current mode changed")
    for reference, value, net in [
        ("R6", "3.09k 1%", "BQ_ILIM"),
        ("R7", "46.4k 1%", "BQ_TMR"),
        ("R8", "2.94k 1%", "BQ_ITERM"),
        ("R9", "4.42k 1%", "BQ_ISET"),
    ]:
        require(part(reference).value == value, f"{reference}: charger programming value changed")
        require(part(reference).pin_nets == {"1": net, "2": "GND"},
                f"{reference}: charger programming connection changed")

    regulator = part("U4")
    require(regulator.mpn == "TPS63021DSJR", "Main regulator is not the transient-capable TPS63021")
    expected_regulator = {
        "1": "SYS_RAW", "2": "GND", "3": "3V3", "4": "3V3", "5": "3V3",
        "6": "BUCK_L2", "7": "BUCK_L2", "8": "BUCK_L1", "9": "BUCK_L1",
        "10": "SYS_RAW", "11": "SYS_RAW", "12": "SYS_RAW", "13": "GND",
        "14": "BUCK_PG_N", "15": "GND",
    }
    require(regulator.pin_nets == expected_regulator, "TPS63021 fixed-3.3 V wiring differs from reviewed circuit")
    require(part("R30").pin_nets == {"1": "3V3", "2": "BUCK_PG_N"}, "Power-good pull-up missing")

    require(part("MK1").pin_nets["2"] == "GND", "Left microphone LR selection is not low")
    require(part("MK2").pin_nets["2"] == "1V85", "Right microphone LR selection is not high")
    require(part("MK1").pin_nets["4"] == part("MK2").pin_nets["4"] == "GND",
            "T5848 WAKE must remain low when AAD is unused")
    require(part("MK1").pin_nets["5"] == part("MK2").pin_nets["5"] == "NC",
            "T5848 THSEL must remain unconnected when AAD is unused")
    require(part("MK1").pin_nets["8"] == part("MK2").pin_nets["8"] == "I2S_SD_1V85", "Microphones do not share stereo data bus")
    require(part("U6").pin_nets["11"] == "NC", "Unused TXU0304 output must not be shorted")
    require(part("U6").pin_nets["8"] == "MIC_POWER_EN", "TXU0304 must be disabled with microphone power")
    require(part("R31").pin_nets == {"1": "MIC_POWER_EN", "2": "GND"}, "Microphone power enable lacks reset pull-down")
    microphone_footprint = (FOOTPRINT_DIR / "T5848_LGA8_BottomPort.kicad_mod").read_text(encoding="utf-8")
    require(re.search(r'\(pad "" np_thru_hole circle\s+\(at [^)]+\)\s+\(size 1(?:\.0+)? 1(?:\.0+)?\)\s+\(drill 1(?:\.0+)?\)', microphone_footprint) is not None,
            "T5848 acoustic aperture changed")

    require(part("U1").pin_nets["17"] == "USB_DM", "ESP native USB D- mapping changed")
    require(part("U1").pin_nets["18"] == "USB_DP", "ESP native USB D+ mapping changed")
    require(part("U1").pin_nets["6"] == "I2S_BCLK_3V3",
            "I2S BCLK must use the routable GPIO3 assignment")
    require(part("U1").pin_nets["19"] == "NC", "Reserved GPIO14 mapping changed")
    require(part("U1").pin_nets["12"] == part("U1").pin_nets["23"] == "USER_BUTTON",
            "Boot/user switch must reach both GPIO0 deep-sleep wake and GPIO9 boot inputs")
    require(part("TP1").pin_nets == {"1": "UART_TX"} and part("TP2").pin_nets == {"1": "UART_RX"},
            "UART/GPIO expansion pads changed")
    require(part("R17").pin_nets == {"1": "MIC_POWER_EN", "2": "RECORD_LED_A"},
            "Recording indicator is not hardware-bound to microphone-domain power")
    require(part("U1").pin_nets["28"] == "BUCK_PG_N", "Regulator power-good is not monitored")
    require(part("U1").pin_nets["20"] == "SD_POWER_EN", "GPIO15 no longer controls microSD power")
    require(part("R15").value == "1M 1%" and part("R16").value == "330k 1%",
            "Low-leakage battery divider values changed")
    require(part("R15").pin_nets == {"1": "BAT_PLUS", "2": "BAT_SENSE"}
            and part("R16").pin_nets == {"1": "BAT_SENSE", "2": "GND"},
            "Battery measurement divider wiring changed")
    require(part("U7").pin_nets == {
        "1": "3V3", "2": "GND", "3": "SD_POWER_EN", "4": "SD_SLEW_CT", "5": "SD_3V3", "6": "SD_3V3",
    }, "MicroSD load switch differs from reviewed low-leakage circuit")
    require(part("C23").value == "1n 25V X7R"
            and part("C23").pin_nets == {"1": "SD_SLEW_CT", "2": "GND"},
            "MicroSD controlled-rise capacitor changed")
    require(part("R32").pin_nets == {"1": "SD_POWER_EN", "2": "GND"}, "MicroSD power enable lacks reset pull-down")
    require(part("J3").pin_nets["4"] == "SD_3V3", "MicroSD is not on the switched supply")
    for reference in ("R24", "R25", "R26", "R27", "R28", "C18", "C19", "C22"):
        require("SD_3V3" in part(reference).pin_nets.values(), f"{reference}: storage support is not on switched power")
    require(part("R28").footprint == "Resistor_SMD:R_0402_1005Metric"
            and part("R28").mpn == "RC0402FR-0747KL", "R28 compact common-source part changed")
    require(part("R29").pin_nets == {"1": "3V3", "2": "SD_CARD_DETECT"},
            "Card-detect must remain defined while the storage rail is off")

    custom_footprints = {
        "U1": "ESP32-C6-MINI-1",
        "J1": "Molex_2169900003",
        "U4": "TI_DSJ_VSON14_3x4mm",
        "L1": "Coilcraft_XFL4020",
        "MK1": "T5848_LGA8_BottomPort",
        "MK2": "T5848_LGA8_BottomPort",
        "J3": "GCT_MEM2085",
    }
    for reference, footprint_name in custom_footprints.items():
        require(set(part(reference).pin_nets).issubset(footprint_pads(footprint_name)), f"{reference}: footprint lacks a symbol pin")

    module_footprint = (FOOTPRINT_DIR / "ESP32-C6-MINI-1.kicad_mod").read_text(encoding="utf-8")
    require(len(re.findall(r'\(pad\s+"49"', module_footprint)) == 9, "ESP32 module exposed ground pad array is incomplete")
    require("ANTENNA / ALL-LAYER KEEPOUT" in module_footprint, "ESP32 module antenna keepout marking is missing")

    # TI's DSJ top view has pins 1..7 down the left and 8..14 up the right.
    require(footprint_pad_position("TI_DSJ_VSON14_3x4mm", "1") == (-1.65, -1.50), "TPS63021 pad 1 orientation changed")
    require(footprint_pad_position("TI_DSJ_VSON14_3x4mm", "7") == (-1.65, 1.50), "TPS63021 pad 7 orientation changed")
    require(footprint_pad_position("TI_DSJ_VSON14_3x4mm", "8") == (1.65, 1.50), "TPS63021 pad 8 orientation changed")
    require(footprint_pad_position("TI_DSJ_VSON14_3x4mm", "14") == (1.65, -1.50), "TPS63021 pad 14 orientation changed")

    require(footprint_pad_position("GCT_MEM2085", "8") == (-3.42, -3.545), "MEM2085 P8 location changed")
    require(footprint_pad_position("GCT_MEM2085", "5") == (-0.62, -3.545), "MEM2085 P5 location changed")
    require(footprint_pad_position("GCT_MEM2085", "4") == (1.08, -3.545), "MEM2085 center contact gap changed")
    require(footprint_pad_position("GCT_MEM2085", "1") == (3.18, -3.545), "MEM2085 P1 location changed")

    require(footprint_pad_position("Molex_2169900003", "S1") == (-4.60, -1.00), "USB-C upper shell land changed")
    require(footprint_pad_position("Molex_2169900003", "S3") == (-4.60, 3.00), "USB-C lower shell land changed")
    usb_footprint = (FOOTPRINT_DIR / "Molex_2169900003.kicad_mod").read_text(encoding="utf-8")
    require("np_thru_hole" not in usb_footprint, "USB-C manufacturer layout has no locator drill")


def verify_generated_artifacts() -> None:
    for path in [design.SCHEMATIC, design.SYMBOL_LIBRARY]:
        require(path.is_file() and path.stat().st_size > 1000, f"Missing or empty generated file {path}")
        balanced_sexpr(path)

    with design.BOM.open(newline="", encoding="utf-8") as handle:
        bom = list(csv.DictReader(handle))
    populated = [item for item in design.PARTS if item.populated]
    require(len(bom) == len(populated), "BOM row count differs from populated source parts")
    require({row["Reference"] for row in bom} == {item.reference for item in populated}, "BOM references differ")
    for row in bom:
        require(row["MPN"].strip(), f"{row['Reference']}: missing manufacturer part number")
        require(row["Datasheet"].startswith("https://"), f"{row['Reference']}: non-HTTPS source")
        combined = " ".join(row.values()).lower()
        require(not any(word in combined for word in ("placeholder", "tbd", "todo")), f"{row['Reference']}: unfinished BOM data")

    with design.NETLIST.open(newline="", encoding="utf-8") as handle:
        matrix = list(csv.DictReader(handle))
    require(len(matrix) == sum(len(item.pin_nets) for item in design.PARTS), "Pin/net matrix is incomplete")

    summary = json.loads(design.SUMMARY.read_text(encoding="utf-8"))
    require(summary["board"] == {"height_mm": 38.0, "layers": 4, "max_assembled_thickness_mm": 4.75, "thickness_mm": 0.8, "width_mm": 28.0}, "Mechanical target changed")
    require(summary["battery"]["connector_poles"] == 3, "Battery connector is not three-pole")
    require(summary["battery"]["temperature_sensing"] is True, "Battery temperature sensing is missing")
    require(summary["regulator"]["power_good_monitored"] is True, "Regulator power-good monitoring missing")
    require(summary["storage"]["recommended_capacity_gb"] == 16, "Storage capacity target changed")
    require(summary["parts"] == len(populated), "Populated part count changed")
    require(summary["pcb_features"] == len(design.PARTS) - len(populated), "PCB feature count changed")


def verify_kicad_round_trip() -> None:
    schematic = design.ksa.Schematic.load(design.SCHEMATIC)
    require(schematic is not None, "KiCad schematic parser could not reload generated file")
    stats = schematic.get_statistics()
    component_count = stats.get("components") if isinstance(stats, dict) else None
    if component_count is not None:
        require(component_count == len(design.PARTS), "Reloaded KiCad component count differs")
    issues = schematic.validate()
    errors = [issue for issue in issues if getattr(getattr(issue, "level", None), "value", "") == "error"]
    require(not errors, f"KiCad API validation reported errors: {errors}")


def main() -> int:
    verify_connectivity()
    verify_generated_artifacts()
    verify_kicad_round_trip()
    print(f"PASS: {sum(item.populated for item in design.PARTS)} populated parts, "
          f"{sum(not item.populated for item in design.PARTS)} PCB features, and "
          f"{sum(len(item.pin_nets) for item in design.PARTS)} pins verified")
    print("PASS: power, USB, stereo audio, power-gated storage, custom footprints, and 4.75 mm stack invariants verified")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, ValueError, RuntimeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
