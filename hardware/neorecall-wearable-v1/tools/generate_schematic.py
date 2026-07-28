#!/usr/bin/env python3
"""Generate the NeoRecall Wearable v1 KiCad schematic and review artifacts.

The component definitions and pin-to-net matrix in this file are the electrical
source of truth.  The generated schematic embeds every custom symbol and can be
opened without this script.  Generation uses kicad-sch-api only to serialize a
native KiCad schematic; no circuit decisions are hidden in the library.
"""

from __future__ import annotations

import csv
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple

os.environ.setdefault(
    "KICAD_SYMBOL_DIR",
    str(Path(__file__).resolve().parents[1] / "lib"),
)

try:
    import kicad_sch_api as ksa
except ImportError:  # pcbnew's bundled Python imports this module for PARTS only
    ksa = None


ROOT = Path(__file__).resolve().parents[1]
LIB_DIR = ROOT / "lib"
SYMBOL_LIBRARY = LIB_DIR / "NeoRecall_Wearable.kicad_sym"
SCHEMATIC = ROOT / "neorecall-wearable-v1.kicad_sch"
BOM = ROOT / "bom.csv"
NETLIST = ROOT / "pin-net-matrix.csv"
SUMMARY = ROOT / "design-summary.json"


@dataclass(frozen=True)
class Pin:
    number: str
    name: str
    electrical_type: str
    side: str


@dataclass(frozen=True)
class Part:
    reference: str
    symbol: str
    value: str
    footprint: str
    manufacturer: str
    mpn: str
    datasheet: str
    position: Tuple[float, float]
    pin_nets: Dict[str, str]
    note: str = ""
    populated: bool = True


def pins(*rows: Tuple[str, str, str, str]) -> Tuple[Pin, ...]:
    return tuple(Pin(*row) for row in rows)


ESP_PINS: List[Pin] = [
    Pin("1", "GND", "power_in", "left"),
    Pin("2", "GND", "power_in", "left"),
    Pin("3", "3V3", "power_in", "left"),
    Pin("4", "NC", "no_connect", "left"),
    Pin("5", "GPIO2", "bidirectional", "left"),
    Pin("6", "GPIO3", "bidirectional", "left"),
    Pin("7", "NC", "no_connect", "left"),
    Pin("8", "EN", "input", "left"),
    Pin("9", "GPIO4", "bidirectional", "left"),
    Pin("10", "GPIO5", "bidirectional", "left"),
    Pin("11", "GND", "power_in", "left"),
    Pin("12", "GPIO0", "bidirectional", "left"),
    Pin("13", "GPIO1", "bidirectional", "left"),
    Pin("14", "GND", "power_in", "left"),
    Pin("15", "GPIO6", "bidirectional", "left"),
    Pin("16", "GPIO7", "bidirectional", "left"),
    Pin("17", "GPIO12/USB_D-", "bidirectional", "left"),
    Pin("18", "GPIO13/USB_D+", "bidirectional", "left"),
    Pin("19", "GPIO14", "bidirectional", "left"),
    Pin("20", "GPIO15", "bidirectional", "left"),
    Pin("21", "NC", "no_connect", "left"),
    Pin("22", "GPIO8", "bidirectional", "right"),
    Pin("23", "GPIO9", "bidirectional", "right"),
    Pin("24", "GPIO18", "bidirectional", "right"),
    Pin("25", "GPIO19", "bidirectional", "right"),
    Pin("26", "GPIO20", "bidirectional", "right"),
    Pin("27", "GPIO21", "bidirectional", "right"),
    Pin("28", "GPIO22", "bidirectional", "right"),
    Pin("29", "GPIO23", "bidirectional", "right"),
    Pin("30", "GPIO17/U0RXD", "bidirectional", "right"),
    Pin("31", "GPIO16/U0TXD", "bidirectional", "right"),
    Pin("32", "NC", "no_connect", "right"),
    Pin("33", "NC", "no_connect", "right"),
    Pin("34", "NC", "no_connect", "right"),
    Pin("35", "NC", "no_connect", "right"),
]
ESP_PINS.extend(Pin(str(number), "GND", "power_in", "right") for number in range(36, 54))


SYMBOLS: Dict[str, Tuple[Pin, ...]] = {
    "ESP32_C6_MINI_1": tuple(ESP_PINS),
    "BQ24074": pins(
        ("1", "TS", "input", "left"),
        ("2", "BAT", "power_out", "left"),
        ("3", "BAT", "passive", "left"),
        ("4", "CE", "input", "left"),
        ("5", "EN2", "input", "left"),
        ("6", "EN1", "input", "left"),
        ("7", "PGOOD", "open_collector", "left"),
        ("8", "VSS", "power_in", "left"),
        ("9", "CHG", "open_collector", "right"),
        ("10", "OUT", "power_out", "right"),
        ("11", "OUT", "passive", "right"),
        ("12", "ILIM", "input", "right"),
        ("13", "IN", "power_in", "right"),
        ("14", "TMR", "input", "right"),
        ("15", "ITERM", "input", "right"),
        ("16", "ISET", "input", "right"),
        ("17", "EP", "power_in", "right"),
    ),
    "TPS63021": pins(
        ("1", "VINA", "power_in", "left"),
        ("2", "GND", "power_in", "left"),
        ("3", "FB", "input", "left"),
        ("4", "VOUT", "power_out", "left"),
        ("5", "VOUT", "passive", "left"),
        ("6", "L2", "passive", "left"),
        ("7", "L2", "passive", "left"),
        ("8", "L1", "passive", "right"),
        ("9", "L1", "passive", "right"),
        ("10", "VIN", "power_in", "right"),
        ("11", "VIN", "power_in", "right"),
        ("12", "EN", "input", "right"),
        ("13", "PS/SYNC", "input", "right"),
        ("14", "PG", "open_collector", "right"),
        ("15", "EP/PGND", "power_in", "right"),
    ),
    "TXU0304": pins(
        ("1", "VCCA", "power_in", "left"),
        ("2", "A1", "input", "left"),
        ("3", "A2", "input", "left"),
        ("4", "A3", "input", "left"),
        ("5", "A4Y", "output", "left"),
        ("6", "NC", "no_connect", "left"),
        ("7", "GND", "power_in", "left"),
        ("8", "OE", "input", "right"),
        ("9", "NC", "no_connect", "right"),
        ("10", "B4", "input", "right"),
        ("11", "B3Y", "output", "right"),
        ("12", "B2Y", "output", "right"),
        ("13", "B1Y", "output", "right"),
        ("14", "VCCB", "power_in", "right"),
    ),
    "T5848": pins(
        ("1", "WS", "input", "left"),
        ("2", "LR", "input", "left"),
        ("3", "GND", "power_in", "left"),
        ("4", "WAKE", "passive", "left"),
        ("5", "THSEL", "input", "right"),
        ("6", "SCK", "input", "right"),
        ("7", "VDD", "power_in", "right"),
        ("8", "SD", "tri_state", "right"),
    ),
    "TPS7A20_DBV": pins(
        ("1", "IN", "power_in", "left"),
        ("2", "GND", "power_in", "left"),
        ("3", "EN", "input", "left"),
        ("4", "NC", "no_connect", "right"),
        ("5", "OUT", "power_out", "right"),
    ),
    "TPS22918_DBV": pins(
        ("1", "VIN", "power_in", "left"),
        ("2", "GND", "power_in", "left"),
        ("3", "ON", "input", "left"),
        ("4", "CT", "input", "right"),
        ("5", "QOD", "passive", "right"),
        ("6", "VOUT", "power_out", "right"),
    ),
    "USB_C_16": pins(
        ("A1_B12", "GND", "power_out", "left"),
        ("A4_B9", "VBUS", "power_out", "left"),
        ("A5", "CC1", "bidirectional", "left"),
        ("A6", "D+", "bidirectional", "left"),
        ("A7", "D-", "bidirectional", "left"),
        ("A8", "SBU1", "no_connect", "left"),
        ("B1_A12", "GND", "power_in", "right"),
        ("B4_A9", "VBUS", "passive", "right"),
        ("B5", "CC2", "bidirectional", "right"),
        ("B6", "D+", "bidirectional", "right"),
        ("B7", "D-", "bidirectional", "right"),
        ("B8", "SBU2", "no_connect", "right"),
        ("S1", "SHIELD", "power_in", "right"),
        ("S2", "SHIELD", "power_in", "right"),
        ("S3", "SHIELD", "power_in", "right"),
        ("S4", "SHIELD", "power_in", "right"),
    ),
    "USBLC6_2SC6": pins(
        ("1", "I/O1", "passive", "left"),
        ("2", "GND", "power_in", "left"),
        ("3", "I/O2", "passive", "left"),
        ("4", "I/O2", "passive", "right"),
        ("5", "VBUS", "power_in", "right"),
        ("6", "I/O1", "passive", "right"),
    ),
    "MICROSD_MEM2085": pins(
        ("1", "DAT2", "bidirectional", "left"),
        ("2", "DAT3/CS", "bidirectional", "left"),
        ("3", "CMD/MOSI", "input", "left"),
        ("4", "VDD", "power_in", "left"),
        ("5", "CLK", "input", "right"),
        ("6", "VSS", "power_in", "right"),
        ("7", "DAT0/MISO", "output", "right"),
        ("8", "DAT1", "bidirectional", "right"),
        ("CD", "CARD_DETECT", "switch", "right"),
    ),
    "R": pins(("1", "~", "passive", "left"), ("2", "~", "passive", "right")),
    "C": pins(("1", "~", "passive", "left"), ("2", "~", "passive", "right")),
    "L": pins(("1", "~", "passive", "left"), ("2", "~", "passive", "right")),
    "LED": pins(("1", "K", "passive", "left"), ("2", "A", "passive", "right")),
    "DIODE": pins(("1", "K", "passive", "left"), ("2", "A", "passive", "right")),
    "SW_PUSH": pins(("1", "A", "passive", "left"), ("2", "B", "passive", "right")),
    "CONN_2": pins(("1", "PIN1", "passive", "left"), ("2", "PIN2", "passive", "right")),
    "CONN_3": pins(
        ("1", "BAT+", "passive", "left"),
        ("2", "NTC", "passive", "left"),
        ("3", "GND", "passive", "right"),
    ),
    "TESTPOINT": pins(("1", "TP", "passive", "left"),),
}


DATASHEETS = {
    "esp": "https://documentation.espressif.com/esp32-c6-mini-1_mini-1u_datasheet_en.html",
    "charger": "https://www.ti.com/lit/ds/symlink/bq24074.pdf",
    "buckboost": "https://www.ti.com/lit/ds/symlink/tps63021.pdf",
    "translator": "https://www.ti.com/lit/ds/symlink/txu0304.pdf",
    "mic": "https://www.mouser.com/catalog/specsheets/TDK_7302024_DS_000479_T5848_Datasheet_v1_0.pdf",
    "ldo": "https://www.ti.com/lit/ds/symlink/tps7a20.pdf",
    "usb": "https://www.molex.com/en-us/products/part-detail/2169900003",
    "esd": "https://www.st.com/resource/en/datasheet/usblc6-2.pdf",
    "microsd": "https://gct.co/files/drawings/mem2085.pdf",
    "switch": "https://www.ckswitches.com/media/1476/pts810.pdf",
    "inductor": "https://www.coilcraft.com/en-us/products/power/shielded-inductors/molded-inductor/xfl/xfl4020/",
}


FP = {
    "r": "Resistor_SMD:R_0603_1608Metric",
    "c": "Capacitor_SMD:C_0603_1608Metric",
    "led": "LED_SMD:LED_0603_1608Metric",
    "sod323": "Diode_SMD:D_SOD-323",
    "tp": "TestPoint:TestPoint_Pad_D1.0mm",
}


def power_section() -> List[Part]:
    return [
        Part("J1", "USB_C_16", "USB-C 2.0", "NeoRecall_Wearable:Molex_2169900003", "Molex", "216990-0003", DATASHEETS["usb"], (35.56, 45.72), {
            "A1_B12": "GND", "A4_B9": "VBUS_USB", "A5": "USB_CC1", "A6": "USB_DP_CONN", "A7": "USB_DM_CONN",
            "A8": "NC", "B1_A12": "GND", "B4_A9": "VBUS_USB", "B5": "USB_CC2", "B6": "USB_DP_CONN",
            "B7": "USB_DM_CONN", "B8": "NC", "S1": "GND", "S2": "GND", "S3": "GND", "S4": "GND",
        }, "Mid-mount; intended for 0.8 mm PCB"),
        Part("U2", "USBLC6_2SC6", "USBLC6-2SC6", "Package_TO_SOT_SMD:SOT-23-6", "STMicroelectronics", "USBLC6-2SC6", DATASHEETS["esd"], (71.12, 45.72), {
            "1": "USB_DP_CONN", "2": "GND", "3": "USB_DM_CONN", "4": "USB_DM_ESD", "5": "VBUS_USB", "6": "USB_DP_ESD",
        }),
        Part("R1", "R", "22R 1%", "Resistor_SMD:R_0402_1005Metric", "Yageo", "RC0402FR-0722RL", "https://www.yageo.com/en/ProductSearch/PartDetail?partNo=RC0402FR-0722RL", (91.44, 41.91), {"1": "USB_DP_ESD", "2": "USB_DP"}, "Place immediately at the ESP32 USB D+ pin; 0402 permits matched side-by-side breakout"),
        Part("R2", "R", "22R 1%", "Resistor_SMD:R_0402_1005Metric", "Yageo", "RC0402FR-0722RL", "https://www.yageo.com/en/ProductSearch/PartDetail?partNo=RC0402FR-0722RL", (91.44, 49.53), {"1": "USB_DM_ESD", "2": "USB_DM"}, "Place immediately at the ESP32 USB D- pin; 0402 permits matched side-by-side breakout"),
        Part("R3", "R", "5.1k 1%", FP["r"], "Yageo", "RC0603FR-075K1L", "https://www.yageo.com/", (53.34, 35.56), {"1": "USB_CC1", "2": "GND"}),
        Part("R4", "R", "5.1k 1%", FP["r"], "Yageo", "RC0603FR-075K1L", "https://www.yageo.com/", (53.34, 55.88), {"1": "USB_CC2", "2": "GND"}),
        Part("D1", "DIODE", "PESD5V0S1BA", FP["sod323"], "Nexperia", "PESD5V0S1BA,115", "https://assets.nexperia.com/documents/data-sheet/PESD5V0S1BA.pdf", (53.34, 66.04), {"1": "VBUS_USB", "2": "GND"}),
        Part("C1", "C", "4.7u 10V X7R", FP["c"], "Murata", "GRM188Z71A475KE15D", "https://www.murata.com/en-us/products/productdetail?partno=GRM188Z71A475KE15D", (68.58, 66.04), {"1": "VBUS_USB", "2": "GND"}),
        Part("U3", "BQ24074", "BQ24074RGTR", "Package_DFN_QFN:VQFN-16-1EP_3x3mm_P0.5mm_EP1.45x1.45mm", "Texas Instruments", "BQ24074RGTR", DATASHEETS["charger"], (124.46, 45.72), {
            "1": "BQ_TS", "2": "BAT_PLUS", "3": "BAT_PLUS", "4": "GND", "5": "GND", "6": "VBUS_USB",
            "7": "CHARGER_PGOOD_N", "8": "GND", "9": "CHARGER_CHG_N", "10": "SYS_RAW", "11": "SYS_RAW",
            "12": "BQ_ILIM", "13": "VBUS_USB", "14": "BQ_TMR", "15": "BQ_ITERM", "16": "BQ_ISET", "17": "GND",
        }, "201 mA charge, 20 mA termination, USB500 input mode"),
        Part("R6", "R", "3.09k 1%", FP["r"], "Yageo", "RC0603FR-073K09L", "https://www.yageo.com/", (147.32, 30.48), {"1": "BQ_ILIM", "2": "GND"}),
        Part("R7", "R", "46.4k 1%", FP["r"], "Yageo", "RC0603FR-0746K4L", "https://www.yageo.com/", (157.48, 38.10), {"1": "BQ_TMR", "2": "GND"}),
        Part("R8", "R", "2.94k 1%", FP["r"], "Yageo", "RC0603FR-072K94L", "https://www.yageo.com/", (157.48, 45.72), {"1": "BQ_ITERM", "2": "GND"}),
        Part("R9", "R", "4.42k 1%", FP["r"], "Yageo", "RC0603FR-074K42L", "https://www.yageo.com/", (157.48, 53.34), {"1": "BQ_ISET", "2": "GND"}),
        Part("R10", "R", "10k 1%", FP["r"], "Yageo", "RC0603FR-0710KL", "https://www.yageo.com/", (142.24, 63.50), {"1": "3V3", "2": "CHARGER_CHG_N"}),
        Part("R11", "R", "10k 1%", FP["r"], "Yageo", "RC0603FR-0710KL", "https://www.yageo.com/", (142.24, 71.12), {"1": "3V3", "2": "CHARGER_PGOOD_N"}),
        Part("C2", "C", "10u 6.3V X7R", FP["c"], "Murata", "GRM188R60J106ME47D", "https://www.murata.com/", (111.76, 68.58), {"1": "BAT_PLUS", "2": "GND"}),
        Part("C3", "C", "10u 6.3V X7R", FP["c"], "Murata", "GRM188R60J106ME47D", "https://www.murata.com/", (124.46, 68.58), {"1": "SYS_RAW", "2": "GND"}),
        Part("J2", "CONN_3", "Protected 1S LiPo + 10k NTC", "Connector_JST:JST_SH_SM03B-SRSS-TB_1x03-1MP_P1.00mm_Horizontal", "JST", "SM03B-SRSS-TB(LF)(SN)", "https://www.jst-mfg.com/product/index.php?series=231", (96.52, 68.58), {"1": "BAT_PLUS", "2": "BQ_TS", "3": "GND"}, "Mating pack must be protected and use pin 1 BAT+, pin 2 10k NTC to GND at 25 C, pin 3 GND"),
        Part("U4", "TPS63021", "TPS63021DSJR", "NeoRecall_Wearable:TI_DSJ_VSON14_3x4mm", "Texas Instruments", "TPS63021DSJR", DATASHEETS["buckboost"], (198.12, 45.72), {
            "1": "SYS_RAW", "2": "GND", "3": "3V3", "4": "3V3", "5": "3V3", "6": "BUCK_L2",
            "7": "BUCK_L2", "8": "BUCK_L1", "9": "BUCK_L1", "10": "SYS_RAW", "11": "SYS_RAW",
            "12": "SYS_RAW", "13": "GND", "14": "BUCK_PG_N", "15": "GND",
        }, "Fixed 3.3 V; power-save enabled; sized for Wi-Fi and microSD transient load"),
        Part("L1", "L", "1.5uH 4.1A Isat(min)", "NeoRecall_Wearable:Coilcraft_XFL4020", "Coilcraft", "XFL4020-152MEC", DATASHEETS["inductor"], (172.72, 45.72), {"1": "BUCK_L1", "2": "BUCK_L2"}),
        Part("C4", "C", "10u 6.3V X5R", FP["c"], "Murata", "GRM188R60J106ME47D", "https://www.murata.com/", (177.80, 66.04), {"1": "SYS_RAW", "2": "GND"}),
        Part("C5", "C", "10u 6.3V X5R", FP["c"], "Murata", "GRM188R60J106ME47D", "https://www.murata.com/", (187.96, 66.04), {"1": "SYS_RAW", "2": "GND"}),
        Part("C6", "C", "100n 10V X7R", FP["c"], "Murata", "GRM188R71A104KA01D", "https://www.murata.com/", (198.12, 66.04), {"1": "SYS_RAW", "2": "GND"}),
        Part("C7", "C", "22u 6.3V X5R", "Capacitor_SMD:C_0805_2012Metric", "Murata", "GRM21BR60J226ME39L", "https://www.murata.com/", (208.28, 66.04), {"1": "3V3", "2": "GND"}),
        Part("C20", "C", "22u 6.3V X5R", "Capacitor_SMD:C_0805_2012Metric", "Murata", "GRM21BR60J226ME39L", "https://www.murata.com/", (218.44, 66.04), {"1": "3V3", "2": "GND"}),
        Part("C21", "C", "22u 6.3V X5R", "Capacitor_SMD:C_0805_2012Metric", "Murata", "GRM21BR60J226ME39L", "https://www.murata.com/", (228.60, 66.04), {"1": "3V3", "2": "GND"}),
        Part("R30", "R", "100k 1%", FP["r"], "Yageo", "RC0603FR-07100KL", "https://www.yageo.com/", (228.60, 45.72), {"1": "3V3", "2": "BUCK_PG_N"}),
    ]


def controller_section() -> List[Part]:
    esp_nets = {str(number): "GND" for number in [1, 2, 11, 14, *range(36, 54)]}
    esp_nets.update({
        "3": "3V3", "4": "NC", "5": "I2S_SD_3V3", "6": "I2S_BCLK_3V3", "7": "NC", "8": "ESP_EN",
        "9": "BAT_SENSE", "10": "SD_MISO_MCU", "12": "USER_BUTTON", "13": "I2S_WS_3V3",
        "15": "SD_CLK_MCU", "16": "SD_MOSI_MCU", "17": "USB_DM", "18": "USB_DP", "19": "NC",
        "20": "SD_POWER_EN", "21": "NC", "22": "GPIO8_STRAP", "23": "USER_BUTTON", "24": "SD_CS_MCU",
        "25": "SD_CARD_DETECT", "26": "CHARGER_PGOOD_N", "27": "CHARGER_CHG_N", "28": "BUCK_PG_N",
        "29": "MIC_POWER_EN", "30": "UART_RX", "31": "UART_TX", "32": "NC", "33": "NC", "34": "NC", "35": "NC",
    })
    return [
        Part("U1", "ESP32_C6_MINI_1", "ESP32-C6-MINI-1-H8", "NeoRecall_Wearable:ESP32-C6-MINI-1", "Espressif Systems", "ESP32-C6-MINI-1-H8", DATASHEETS["esp"], (71.12, 119.38), esp_nets, "Integrated PCB antenna; antenna end must be at board edge with full all-layer keepout"),
        Part("R12", "R", "10k 1%", FP["r"], "Yageo", "RC0603FR-0710KL", "https://www.yageo.com/", (30.48, 96.52), {"1": "3V3", "2": "ESP_EN"}),
        Part("C8", "C", "1u 6.3V X7R", FP["c"], "Murata", "GRM188R60J105KA01D", "https://www.murata.com/", (30.48, 104.14), {"1": "ESP_EN", "2": "GND"}),
        Part("C9", "C", "10u 6.3V X7R", FP["c"], "Murata", "GRM188R60J106ME47D", "https://www.murata.com/", (30.48, 111.76), {"1": "3V3", "2": "GND"}),
        Part("C10", "C", "100n 10V X7R", FP["c"], "Murata", "GRM188R71A104KA01D", "https://www.murata.com/", (30.48, 119.38), {"1": "3V3", "2": "GND"}),
        Part("SW1", "SW_PUSH", "USER / BOOT", "Button_Switch_SMD:SW_SPST_PTS810", "C&K", "PTS810SJM250SMTRLFS", DATASHEETS["switch"], (30.48, 132.08), {"1": "USER_BUTTON", "2": "GND"}, "Place at exact PCB center (14.0 mm, 19.0 mm)"),
        Part("R13", "R", "10k 1%", FP["r"], "Yageo", "RC0603FR-0710KL", "https://www.yageo.com/", (30.48, 139.70), {"1": "3V3", "2": "USER_BUTTON"}),
        Part("R14", "R", "10k 1%", FP["r"], "Yageo", "RC0603FR-0710KL", "https://www.yageo.com/", (30.48, 147.32), {"1": "3V3", "2": "GPIO8_STRAP"}),
        Part("R15", "R", "1M 1%", FP["r"], "Yageo", "RC0603FR-071ML", "https://www.yageo.com/", (111.76, 96.52), {"1": "BAT_PLUS", "2": "BAT_SENSE"}),
        Part("R16", "R", "330k 1%", FP["r"], "Yageo", "RC0603FR-07330KL", "https://www.yageo.com/", (111.76, 104.14), {"1": "BAT_SENSE", "2": "GND"}),
        Part("C11", "C", "100n 10V X7R", FP["c"], "Murata", "GRM188R71A104KA01D", "https://www.murata.com/", (111.76, 111.76), {"1": "BAT_SENSE", "2": "GND"}),
        Part("R17", "R", "1k 1%", FP["r"], "Yageo", "RC0603FR-071KL", "https://www.yageo.com/", (111.76, 124.46), {"1": "MIC_POWER_EN", "2": "RECORD_LED_A"}, "Hardware-binds the red indicator to microphone-domain power; firmware cannot power the microphones with the indicator off"),
        Part("D2", "LED", "RED recording", FP["led"], "Wurth Elektronik", "150060RS75000", "https://www.we-online.com/components/products/datasheet/150060RS75000.pdf", (111.76, 132.08), {"1": "GND", "2": "RECORD_LED_A"}, "Must be visibly on whenever audio capture is active; no covert mode"),
        Part("R18", "R", "1k 1%", FP["r"], "Yageo", "RC0603FR-071KL", "https://www.yageo.com/", (111.76, 139.70), {"1": "3V3", "2": "CHARGE_LED_A"}),
        Part("D3", "LED", "AMBER charging", FP["led"], "Wurth Elektronik", "150060YS75000", "https://www.we-online.com/components/products/datasheet/150060YS75000.pdf", (111.76, 147.32), {"1": "CHARGER_CHG_N", "2": "CHARGE_LED_A"}),
        Part("TP1", "TESTPOINT", "UART_TX / GPIO16", FP["tp"], "", "", "~", (157.48, 101.60), {"1": "UART_TX"}, "ENIG pogo/solder pad; GPIO16 may be reassigned after boot", populated=False),
        Part("TP2", "TESTPOINT", "UART_RX / GPIO17", FP["tp"], "", "", "~", (157.48, 109.22), {"1": "UART_RX"}, "ENIG pogo/solder pad; GPIO17 may be reassigned after boot", populated=False),
        Part("TP3", "TESTPOINT", "ESP_EN test pad", FP["tp"], "", "", "~", (157.48, 116.84), {"1": "ESP_EN"}, "ENIG pogo/solder pad; no component fitted", populated=False),
        Part("TP4", "TESTPOINT", "3V3 test pad", FP["tp"], "", "", "~", (157.48, 124.46), {"1": "3V3"}, "ENIG pogo/solder pad; no component fitted", populated=False),
        Part("TP5", "TESTPOINT", "GND test pad", FP["tp"], "", "", "~", (157.48, 132.08), {"1": "GND"}, "ENIG pogo/solder pad; no component fitted", populated=False),
    ]


def audio_section() -> List[Part]:
    return [
        Part("U5", "TPS7A20_DBV", "1.85V TPS7A20185PDBVR", "Package_TO_SOT_SMD:SOT-23-5", "Texas Instruments", "TPS7A20185PDBVR", DATASHEETS["ldo"], (45.72, 190.50), {"1": "3V3", "2": "GND", "3": "MIC_POWER_EN", "4": "NC", "5": "1V85"}),
        Part("C12", "C", "1u 6.3V X7R", FP["c"], "Murata", "GRM188R60J105KA01D", "https://www.murata.com/", (25.40, 182.88), {"1": "3V3", "2": "GND"}),
        Part("C13", "C", "1u 6.3V X7R", FP["c"], "Murata", "GRM188R60J105KA01D", "https://www.murata.com/", (25.40, 190.50), {"1": "1V85", "2": "GND"}),
        Part("U6", "TXU0304", "TXU0304PWR", "Package_SO:TSSOP-14_4.4x5mm_P0.65mm", "Texas Instruments", "TXU0304PWR", DATASHEETS["translator"], (91.44, 190.50), {
            "1": "3V3", "2": "I2S_BCLK_3V3", "3": "I2S_WS_3V3", "4": "GND", "5": "I2S_SD_3V3", "6": "NC", "7": "GND",
            "8": "MIC_POWER_EN", "9": "NC", "10": "I2S_SD_1V85", "11": "NC", "12": "I2S_WS_1V85", "13": "I2S_BCLK_1V85", "14": "1V85",
        }, "A1/A2 translate clocks 3.3V to 1.85V; B4/A4Y translate microphone data to 3.3V"),
        Part("C14", "C", "100n 10V X7R", FP["c"], "Murata", "GRM188R71A104KA01D", "https://www.murata.com/", (71.12, 208.28), {"1": "3V3", "2": "GND"}),
        Part("C15", "C", "100n 10V X7R", FP["c"], "Murata", "GRM188R71A104KA01D", "https://www.murata.com/", (81.28, 208.28), {"1": "1V85", "2": "GND"}),
        Part("R31", "R", "100k 1%", FP["r"], "Yageo", "RC0603FR-07100KL", "https://www.yageo.com/", (106.68, 208.28), {"1": "MIC_POWER_EN", "2": "GND"}, "Keeps microphone LDO and level translator disabled while the ESP32 GPIO is high impedance at reset"),
        Part("MK1", "T5848", "T5848 LEFT", "NeoRecall_Wearable:T5848_LGA8_BottomPort", "TDK InvenSense", "MMICT5848-00-012", DATASHEETS["mic"], (139.70, 182.88), {
            "1": "I2S_WS_1V85", "2": "GND", "3": "GND", "4": "GND", "5": "NC", "6": "I2S_BCLK_1V85", "7": "1V85", "8": "I2S_SD_1V85",
        }, "Left I2S slot; bottom acoustic port uses a 1.0 mm non-plated PCB hole"),
        Part("MK2", "T5848", "T5848 RIGHT", "NeoRecall_Wearable:T5848_LGA8_BottomPort", "TDK InvenSense", "MMICT5848-00-012", DATASHEETS["mic"], (139.70, 200.66), {
            "1": "I2S_WS_1V85", "2": "1V85", "3": "GND", "4": "GND", "5": "NC", "6": "I2S_BCLK_1V85", "7": "1V85", "8": "I2S_SD_1V85",
        }, "Right I2S slot; bottom acoustic port uses a 1.0 mm non-plated PCB hole"),
        Part("C16", "C", "100n 10V X7R", FP["c"], "Murata", "GRM188R71A104KA01D", "https://www.murata.com/", (172.72, 182.88), {"1": "1V85", "2": "GND"}),
        Part("C17", "C", "100n 10V X7R", FP["c"], "Murata", "GRM188R71A104KA01D", "https://www.murata.com/", (172.72, 200.66), {"1": "1V85", "2": "GND"}),
        Part("R19", "R", "100k 1%", FP["r"], "Yageo", "RC0603FR-07100KL", "https://www.yageo.com/", (195.58, 190.50), {"1": "I2S_SD_1V85", "2": "GND"}),
    ]


def storage_section() -> List[Part]:
    return [
        Part("U7", "TPS22918_DBV", "TPS22918DBVR", "Package_TO_SOT_SMD:SOT-23-6", "Texas Instruments", "TPS22918DBVR", "https://www.ti.com/lit/ds/symlink/tps22918.pdf", (35.56, 238.76), {
            "1": "3V3", "2": "GND", "3": "SD_POWER_EN", "4": "SD_SLEW_CT", "5": "SD_3V3", "6": "SD_3V3",
        }, "Low-leakage microSD power gate; controlled rise time limits card-rail inrush and QOD discharges the rail when disabled"),
        Part("R32", "R", "100k 1%", FP["r"], "Yageo", "RC0603FR-07100KL", "https://www.yageo.com/", (35.56, 246.38), {"1": "SD_POWER_EN", "2": "GND"}, "Keeps microSD power disabled during reset and deep sleep"),
        Part("C22", "C", "1u 6.3V X7R", FP["c"], "Murata", "GRM188R60J105KA01D", "https://www.murata.com/", (35.56, 254.00), {"1": "SD_3V3", "2": "GND"}),
        Part("C23", "C", "1n 25V X7R", "Capacitor_SMD:C_0402_1005Metric", "Murata", "GRM155R71E102KA01D", "https://www.murata.com/en-us/products/productdetail?partno=GRM155R71E102KA01D", (50.80, 254.00), {"1": "SD_SLEW_CT", "2": "GND"}, "Programs an approximately 1.68 ms 3.3 V load-switch rise time to limit microSD capacitor inrush"),
        Part("J3", "MICROSD_MEM2085", "microSD 16GB", "NeoRecall_Wearable:GCT_MEM2085", "GCT", "MEM2085-00-115-00-A", DATASHEETS["microsd"], (63.50, 254.00), {
            "1": "SD_DAT2_UNUSED", "2": "SD_CS_CARD", "3": "SD_MOSI_CARD", "4": "SD_3V3", "5": "SD_CLK_CARD",
            "6": "GND", "7": "SD_MISO_CARD", "8": "SD_DAT1_UNUSED", "CD": "SD_CARD_DETECT",
        }, "Rear side; use a genuine 16GB high-endurance microSDHC card"),
        Part("R20", "R", "33R 1%", FP["r"], "Yageo", "RC0603FR-0733RL", "https://www.yageo.com/", (101.60, 238.76), {"1": "SD_CLK_MCU", "2": "SD_CLK_CARD"}),
        Part("R21", "R", "33R 1%", FP["r"], "Yageo", "RC0603FR-0733RL", "https://www.yageo.com/", (101.60, 246.38), {"1": "SD_MOSI_MCU", "2": "SD_MOSI_CARD"}),
        Part("R22", "R", "33R 1%", FP["r"], "Yageo", "RC0603FR-0733RL", "https://www.yageo.com/", (101.60, 254.00), {"1": "SD_MISO_MCU", "2": "SD_MISO_CARD"}),
        Part("R23", "R", "33R 1%", FP["r"], "Yageo", "RC0603FR-0733RL", "https://www.yageo.com/", (101.60, 261.62), {"1": "SD_CS_MCU", "2": "SD_CS_CARD"}),
        Part("R24", "R", "10k 1%", FP["r"], "Yageo", "RC0603FR-0710KL", "https://www.yageo.com/", (132.08, 238.76), {"1": "SD_3V3", "2": "SD_CS_CARD"}),
        Part("R25", "R", "47k 1%", FP["r"], "Yageo", "RC0603FR-0747KL", "https://www.yageo.com/", (132.08, 246.38), {"1": "SD_3V3", "2": "SD_MOSI_CARD"}),
        Part("R26", "R", "47k 1%", FP["r"], "Yageo", "RC0603FR-0747KL", "https://www.yageo.com/", (132.08, 254.00), {"1": "SD_3V3", "2": "SD_MISO_CARD"}),
        Part("R27", "R", "47k 1%", FP["r"], "Yageo", "RC0603FR-0747KL", "https://www.yageo.com/", (132.08, 261.62), {"1": "SD_3V3", "2": "SD_DAT1_UNUSED"}),
        Part("R28", "R", "47k 1%", "Resistor_SMD:R_0402_1005Metric", "Yageo", "RC0402FR-0747KL", "https://www.yageo.com/", (132.08, 269.24), {"1": "SD_3V3", "2": "SD_DAT2_UNUSED"}, "0402 fits the card-pad escape corridor while remaining a widely stocked standard value"),
        Part("R29", "R", "47k 1%", FP["r"], "Yageo", "RC0603FR-0747KL", "https://www.yageo.com/", (162.56, 238.76), {"1": "3V3", "2": "SD_CARD_DETECT"}, "Card-detect remains defined while the microSD power domain is off"),
        Part("C18", "C", "100n 10V X7R", FP["c"], "Murata", "GRM188R71A104KA01D", "https://www.murata.com/", (162.56, 254.00), {"1": "SD_3V3", "2": "GND"}),
        Part("C19", "C", "22u 6.3V X5R", "Capacitor_SMD:C_0805_2012Metric", "Murata", "GRM21BR60J226ME39L", "https://www.murata.com/", (162.56, 261.62), {"1": "SD_3V3", "2": "GND"}),
    ]


PARTS: List[Part] = power_section() + controller_section() + audio_section() + storage_section()


PIN_TYPE_MAP = {
    "input": "input",
    "output": "output",
    "bidirectional": "bidirectional",
    "tri_state": "tri_state",
    "passive": "passive",
    "power_in": "power_in",
    "power_out": "power_out",
    "open_collector": "open_collector",
    "no_connect": "no_connect",
    "switch": "passive",
}


def escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def property_block(name: str, value: str, y: float, hidden: bool = False) -> str:
    hide = "\n\t\t\t(hide yes)" if hidden else ""
    return (
        f'\t\t(property "{escape(name)}" "{escape(value)}"\n'
        f"\t\t\t(at 0 {y:.2f} 0)\n"
        "\t\t\t(effects\n\t\t\t\t(font (size 1.27 1.27))"
        f"{hide}\n\t\t\t)\n\t\t)\n"
    )


def symbol_text(name: str, symbol_pins: Sequence[Pin]) -> str:
    left = [pin for pin in symbol_pins if pin.side == "left"]
    right = [pin for pin in symbol_pins if pin.side == "right"]
    rows = max(len(left), len(right), 2)
    height = max(5.08, (rows - 1) * 2.54 / 2 + 2.54)
    body_left = -5.08
    body_right = 5.08
    outer_left = -7.62
    outer_right = 7.62

    def y_positions(count: int) -> Iterable[float]:
        start = (count - 1) * 2.54 / 2
        return (start - index * 2.54 for index in range(count))

    result = [
        f'\t(symbol "{name}"\n',
        "\t\t(pin_names (offset 0.508))\n",
        f"\t\t(exclude_from_sim no)\n\t\t(in_bom {'no' if name == 'TESTPOINT' else 'yes'})\n\t\t(on_board yes)\n",
        property_block("Reference", name[0] if name not in {"T5848"} else "MK", -height - 2.54),
        property_block("Value", name, height + 2.54),
        property_block("Footprint", "", 0, True),
        property_block("Datasheet", "~", 0, True),
        property_block("Description", f"NeoRecall Wearable symbol for {name}", 0, True),
        f'\t\t(symbol "{name}_0_1"\n',
        "\t\t\t(rectangle\n",
        f"\t\t\t\t(start {body_left} {-height:.2f})\n\t\t\t\t(end {body_right} {height:.2f})\n",
        "\t\t\t\t(stroke (width 0) (type default))\n\t\t\t\t(fill (type background))\n\t\t\t)\n",
        "\t\t)\n",
        f'\t\t(symbol "{name}_1_1"\n',
    ]
    for pin, y in zip(left, y_positions(len(left))):
        result.append(
            f"\t\t\t(pin {PIN_TYPE_MAP[pin.electrical_type]} line\n"
            f"\t\t\t\t(at {outer_left} {y:.2f} 0)\n\t\t\t\t(length 2.54)\n"
            f'\t\t\t\t(name "{escape(pin.name)}" (effects (font (size 1.0 1.0))))\n'
            f'\t\t\t\t(number "{escape(pin.number)}" (effects (font (size 1.0 1.0))))\n'
            "\t\t\t)\n"
        )
    for pin, y in zip(right, y_positions(len(right))):
        result.append(
            f"\t\t\t(pin {PIN_TYPE_MAP[pin.electrical_type]} line\n"
            f"\t\t\t\t(at {outer_right} {y:.2f} 180)\n\t\t\t\t(length 2.54)\n"
            f'\t\t\t\t(name "{escape(pin.name)}" (effects (font (size 1.0 1.0))))\n'
            f'\t\t\t\t(number "{escape(pin.number)}" (effects (font (size 1.0 1.0))))\n'
            "\t\t\t)\n"
        )
    result.extend(["\t\t)\n", "\t)\n"])
    return "".join(result)


def write_symbol_library() -> None:
    LIB_DIR.mkdir(parents=True, exist_ok=True)
    content = [
        "(kicad_symbol_lib\n",
        "\t(version 20251024)\n",
        '\t(generator "neorecall_wearable_generator")\n',
        '\t(generator_version "10.0")\n',
    ]
    for name, symbol_pins in SYMBOLS.items():
        content.append(symbol_text(name, symbol_pins))
    content.append(")\n")
    SYMBOL_LIBRARY.write_text("".join(content), encoding="utf-8")


def validate_design() -> None:
    references = set()
    for part in PARTS:
        if part.reference in references:
            raise ValueError(f"Duplicate reference {part.reference}")
        references.add(part.reference)
        defined = {pin.number: pin for pin in SYMBOLS[part.symbol]}
        unknown = set(part.pin_nets) - set(defined)
        if unknown:
            raise ValueError(f"{part.reference}: unknown pins {sorted(unknown)}")
        missing = set(defined) - set(part.pin_nets)
        if missing:
            raise ValueError(f"{part.reference}: unmapped pins {sorted(missing)}")
        for number, net in part.pin_nets.items():
            is_nc = defined[number].electrical_type == "no_connect"
            if is_nc and net != "NC":
                raise ValueError(
                    f"{part.reference}.{number}: NC mismatch (type={defined[number].electrical_type}, net={net})"
                )

    net_members: Dict[str, List[str]] = {}
    for part in PARTS:
        for number, net in part.pin_nets.items():
            if net != "NC":
                net_members.setdefault(net, []).append(f"{part.reference}.{number}")
    singletons = {net: members for net, members in net_members.items() if len(members) < 2}
    allowed_singletons = {
        "SD_DAT1_UNUSED", "SD_DAT2_UNUSED"
    }
    unexpected = set(singletons) - allowed_singletons
    if unexpected:
        raise ValueError(f"Unexpected single-pin nets: {sorted(unexpected)}")


def write_review_files() -> None:
    with BOM.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["Reference", "Quantity", "Value", "Manufacturer", "MPN", "Footprint", "Datasheet", "Assembly note"])
        for part in (item for item in PARTS if item.populated):
            writer.writerow([part.reference, 1, part.value, part.manufacturer, part.mpn, part.footprint, part.datasheet, part.note])

    with NETLIST.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["Reference", "Pin", "Pin name", "Electrical type", "Net"])
        for part in PARTS:
            pin_lookup = {pin.number: pin for pin in SYMBOLS[part.symbol]}
            for number, net in sorted(part.pin_nets.items(), key=lambda item: item[0]):
                pin = pin_lookup[number]
                writer.writerow([part.reference, number, pin.name, pin.electrical_type, net])

    net_counts: Dict[str, int] = {}
    for part in PARTS:
        for net in part.pin_nets.values():
            net_counts[net] = net_counts.get(net, 0) + 1
    SUMMARY.write_text(
        json.dumps(
            {
                "board": {"width_mm": 28.0, "height_mm": 38.0, "layers": 4, "thickness_mm": 0.8, "max_assembled_thickness_mm": 4.75},
                "parts": sum(item.populated for item in PARTS),
                "pcb_features": sum(not item.populated for item in PARTS),
                "schematic_symbols": len(PARTS),
                "pins": sum(len(part.pin_nets) for part in PARTS),
                "nets": dict(sorted(net_counts.items())),
                "charging": {"input_limit_ma": 500, "charge_current_ma_typ": 201, "termination_current_ma_typ": 20, "safety_timer_hours": 6.2},
                "regulator": {"part": "TPS63021DSJR", "output_v": 3.3, "inductor": "XFL4020-152MEC", "power_good_monitored": True},
                "battery": {"type": "protected 1S LiPo with 10k NTC", "connector_poles": 3, "temperature_sensing": True},
                "storage": {"interface": "microSD SPI", "recommended_capacity_gb": 16, "socket": "MEM2085-00-115-00-A"},
                "recording_indicator": {"hardware_bound_to_microphone_power": True},
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def create_schematic() -> None:
    if ksa is None:
        raise RuntimeError(
            "Install the pinned generator dependency first: "
            "python3 -m pip install -r hardware/neorecall-wearable-v1/tools/requirements.txt"
        )
    # kicad-sch-api merges into an existing destination on save.  The generator
    # is authoritative, so always start from a genuinely empty output file.
    SCHEMATIC.unlink(missing_ok=True)
    cache = ksa.get_symbol_cache()
    cache.add_library_path(SYMBOL_LIBRARY)
    schematic = ksa.Schematic.create(
        name="NeoRecall Wearable v1",
        version="20260306",
        generator="neorecall_wearable_generator",
        generator_version="10.0",
        paper="A2",
    )

    schematic.add_text(
        text="NeoRecall Wearable v1 — 28 x 38 mm target, 4-layer 0.8 mm PCB, 4.75 mm populated-board envelope",
        position=(297.0, 15.0),
        size=2.5,
    )
    schematic.add_text(
        text="BATTERY SAFETY: use only a protected 1S LiPo pack with 10k NTC; J2 pinout is BAT+ / NTC / GND.",
        position=(297.0, 400.0),
        size=1.5,
    )

    # Wide deterministic grid avoids coincident pin endpoints.  Net labels are
    # the intentional interconnect, so unrelated symbol pins must never touch.
    regular_parts = [part for part in PARTS if part.reference != "U1"]
    schematic_positions = {
        part.reference: (30.0 + (index % 12) * 40.0, 50.0 + (index // 12) * 50.0)
        for index, part in enumerate(regular_parts)
    }
    schematic_positions["U1"] = (550.0, 155.0)

    for part in PARTS:
        requested_position = schematic_positions[part.reference]
        placed_position = tuple(round(value / 1.27) * 1.27 for value in requested_position)
        component = schematic.components.add(
            lib_id=f"NeoRecall_Wearable:{part.symbol}",
            reference=part.reference,
            value=part.value,
            position=placed_position,
            footprint=part.footprint,
            Datasheet=part.datasheet,
        )
        component.in_bom = part.populated
        for pin_number, net in part.pin_nets.items():
            symbol_pins = SYMBOLS[part.symbol]
            pin = next((candidate for candidate in symbol_pins if candidate.number == pin_number), None)
            if pin is None:
                raise RuntimeError(f"Cannot resolve {part.reference}.{pin_number}")
            side_pins = [candidate for candidate in symbol_pins if candidate.side == pin.side]
            index = side_pins.index(pin)
            local_y = (len(side_pins) - 1) * 2.54 / 2 - index * 2.54
            corrected_position = (
                placed_position[0] - 7.62 if pin.side == "left" else placed_position[0] + 7.62,
                placed_position[1] - local_y,
            )
            if net == "NC":
                schematic.no_connects.add(position=corrected_position)
            else:
                schematic.add_label(text=net, position=corrected_position)

    schematic.save(SCHEMATIC)


def main() -> int:
    validate_design()
    write_symbol_library()
    write_review_files()
    create_schematic()
    print(f"Generated {SCHEMATIC}")
    print(f"Generated {BOM}")
    print(f"Generated {NETLIST}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
