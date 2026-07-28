#!/usr/bin/env python3
"""Verify production-candidate geometry and routing invariants with pcbnew.

Run with KiCad's bundled Python so this script uses the same board parser and
units as the application that produces the manufacturing files.
"""

from pathlib import Path
import math
import re

import wx

APP = wx.App(False)
import pcbnew  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
BOARD_PATH = ROOT / "neorecall-wearable-v1.kicad_pcb"


def tracks_for(board: pcbnew.BOARD, net_name: str) -> list:
    net = board.FindNet(net_name) or board.FindNet(f"/{net_name}")
    if net is None:
        raise RuntimeError(f"Missing required net {net_name}")
    return [item for item in board.GetTracks() if item.GetNetCode() == net.GetNetCode()]


def route_metrics(board: pcbnew.BOARD, net_name: str) -> tuple[float, int, float]:
    items = tracks_for(board, net_name)
    segments = [item for item in items if not isinstance(item, pcbnew.PCB_VIA)]
    if not segments:
        raise RuntimeError(f"Net {net_name} has no routed segments")
    return (
        sum(pcbnew.ToMM(item.GetLength()) for item in items),
        sum(isinstance(item, pcbnew.PCB_VIA) for item in items),
        min(pcbnew.ToMM(item.GetWidth()) for item in segments),
    )


def assert_close(actual: float, expected: float, tolerance: float, label: str) -> None:
    if abs(actual - expected) > tolerance:
        raise RuntimeError(f"{label}: expected {expected}, got {actual:.4f}")


def main() -> int:
    board = pcbnew.LoadBoard(str(BOARD_PATH))
    if board is None:
        raise RuntimeError(f"Cannot load {BOARD_PATH}")

    edges = board.GetBoardEdgesBoundingBox()
    assert_close(pcbnew.ToMM(edges.GetWidth()), 28.05, 0.01, "board bounding width")
    assert_close(pcbnew.ToMM(edges.GetHeight()), 38.05, 0.01, "board bounding height")
    assert_close(pcbnew.ToMM(board.GetDesignSettings().GetBoardThickness()), 0.8, 0.001,
                 "board thickness")
    if board.GetCopperLayerCount() != 4:
        raise RuntimeError(f"Expected four copper layers, got {board.GetCopperLayerCount()}")
    if any(item.GetLayer() == pcbnew.In1_Cu for item in board.GetTracks()):
        raise RuntimeError("In1.Cu must remain free of signal tracks")

    ground_planes = [
        zone for zone in board.Zones()
        if not zone.GetIsRuleArea() and zone.GetLayer() == pcbnew.In1_Cu
        and zone.GetNetname().lstrip("/") == "GND"
    ]
    if len(ground_planes) != 1:
        raise RuntimeError("Expected exactly one continuous In1.Cu GND plane")
    power_planes = [
        zone for zone in board.Zones()
        if not zone.GetIsRuleArea() and zone.GetLayer() == pcbnew.In2_Cu
        and zone.GetNetname().lstrip("/") == "3V3"
    ]
    if len(power_planes) != 1:
        raise RuntimeError("Expected exactly one In2.Cu 3V3 distribution plane")
    antenna_keepouts = [
        zone for zone in board.Zones()
        if zone.GetIsRuleArea()
        and {pcbnew.F_Cu, pcbnew.In1_Cu, pcbnew.In2_Cu, pcbnew.B_Cu}
        <= set(zone.GetLayerSet().Seq())
    ]
    if len(antenna_keepouts) != 1:
        raise RuntimeError("Expected one all-copper-layer antenna keepout")

    center = board.FindFootprintByReference("SW1").GetPosition()
    assert_close(pcbnew.ToMM(center.x), 114.0, 0.01, "center button X")
    assert_close(pcbnew.ToMM(center.y), 119.0, 0.01, "center button Y")
    for reference, net_name in (("TP1", "UART_TX"), ("TP2", "UART_RX"), ("TP3", "ESP_EN"),
                                ("TP4", "3V3"), ("TP5", "GND")):
        expansion = board.FindFootprintByReference(reference)
        pads = list(expansion.Pads()) if expansion is not None else []
        if len(pads) != 1 or pads[0].GetNetname().lstrip("/") != net_name:
            raise RuntimeError(f"{reference} is not connected to {net_name}")

    def pad_net(reference: str, number: str) -> str:
        footprint = board.FindFootprintByReference(reference)
        pads = [pad for pad in footprint.Pads() if pad.GetNumber() == number]
        if not pads:
            raise RuntimeError(f"Missing {reference}.{number}")
        return pads[0].GetNetname().lstrip("/")

    if [pad_net("J2", number) for number in ("1", "2", "3")] != ["BAT_PLUS", "BQ_TS", "GND"]:
        raise RuntimeError("Battery connector must be BAT+ / 10k-NTC / GND")
    if pad_net("U3", "6") != "VBUS_USB":
        raise RuntimeError("BQ24074 EN1 must be asserted directly whenever USB VBUS is present")
    if pad_net("U1", "12") != pad_net("U1", "23") or pad_net("U1", "12") != "USER_BUTTON":
        raise RuntimeError("User button must reach both GPIO0 deep-sleep wake and GPIO9 boot inputs")
    if pad_net("U7", "4") != "SD_SLEW_CT" or pad_net("C23", "1") != "SD_SLEW_CT":
        raise RuntimeError("MicroSD controlled-rise network is incomplete")
    ts_items = tracks_for(board, "BQ_TS")
    ts_segments = [item for item in ts_items if not isinstance(item, pcbnew.PCB_VIA)]
    if not ts_segments or min(pcbnew.ToMM(item.GetWidth()) for item in ts_segments) < 0.099:
        raise RuntimeError("Battery temperature-sense escape is narrower than 0.10 mm")
    left_edge = pcbnew.ToMM(board.GetBoardEdgesBoundingBox().GetLeft())
    ts_edge_clearance = min(
        min(pcbnew.ToMM(item.GetStart().x), pcbnew.ToMM(item.GetEnd().x))
        - pcbnew.ToMM(item.GetWidth()) / 2 - left_edge
        for item in ts_segments
    )
    if ts_edge_clearance < 0.199:
        raise RuntimeError(f"BQ_TS copper-to-edge clearance is only {ts_edge_clearance:.3f} mm")
    card = board.FindFootprintByReference("J3")
    if not card.IsFlipped():
        raise RuntimeError("The microSD socket must be mounted on the rear")
    card_box = card.GetBoundingBox()
    board_box = board.GetBoardEdgesBoundingBox()
    if not (card_box.GetLeft() >= board_box.GetLeft()
            and card_box.GetRight() <= board_box.GetRight()
            and card_box.GetTop() >= board_box.GetTop()
            and card_box.GetBottom() <= board_box.GetBottom()):
        raise RuntimeError("The microSD socket envelope must remain fully inside the PCB outline")

    for net_name in ("VBUS_USB", "BAT_PLUS", "SYS_RAW", "3V3", "1V85", "SD_3V3"):
        _, _, minimum_width = route_metrics(board, net_name)
        if minimum_width < 0.299:
            raise RuntimeError(f"Power net {net_name} is narrower than 0.30 mm")

    buck = {name: route_metrics(board, name) for name in ("BUCK_L1", "BUCK_L2")}
    for name, (length, vias, minimum_width) in buck.items():
        if length > 4.0 or vias != 0 or minimum_width < 0.199:
            raise RuntimeError(
                f"{name} violates switch-node limit: {length:.3f} mm, {vias} vias, "
                f"{minimum_width:.3f} mm minimum width"
            )

    dp_nets = ("USB_DP_CONN", "USB_DP_ESD", "USB_DP")
    dm_nets = ("USB_DM_CONN", "USB_DM_ESD", "USB_DM")
    dp = [route_metrics(board, name) for name in dp_nets]
    dm = [route_metrics(board, name) for name in dm_nets]
    dp_length = sum(item[0] for item in dp)
    dm_length = sum(item[0] for item in dm)
    # At USB full-speed the measured board skew is electrically small, but it
    # remains bounded here and is documented for fabricator impedance review.
    if abs(dp_length - dm_length) > 10.0:
        raise RuntimeError(
            f"USB pair mismatch exceeds 10 mm: D+ {dp_length:.3f}, D- {dm_length:.3f}"
        )
    if sum(item[1] for item in dp) != sum(item[1] for item in dm):
        raise RuntimeError("USB D+ and D- must use the same number of vias")
    if any(item[2] < 0.149 for item in dp + dm):
        raise RuntimeError("USB data routing is narrower than 0.15 mm")

    print("Layout verified")
    print("  28 x 38 mm nominal, 0.8 mm, four copper layers")
    stackup = BOARD_PATH.read_text(encoding="utf-8")
    if '(thickness 0.8)' not in stackup or '(copper_finish "ENIG")' not in stackup:
        raise RuntimeError("Locked 0.8 mm ENIG stackup is missing")
    for layer, material_type, thickness in (("dielectric 1", "prepreg", "0.1"),
                                             ("dielectric 2", "core", "0.494"),
                                             ("dielectric 3", "prepreg", "0.1")):
        pattern = rf'\(layer "{re.escape(layer)}".*?\(type "{material_type}"\).*?\(thickness {thickness}\)'
        if re.search(pattern, stackup, re.DOTALL) is None:
            raise RuntimeError(f"Locked stackup definition missing for {layer}")

    regulator = board.FindFootprintByReference("U4").GetPosition()
    for reference in ("C7", "C20", "C21"):
        capacitor = board.FindFootprintByReference(reference).GetPosition()
        distance = math.hypot(pcbnew.ToMM(capacitor.x - regulator.x),
                              pcbnew.ToMM(capacitor.y - regulator.y))
        if distance > 6.6:
            raise RuntimeError(f"{reference} is {distance:.2f} mm from U4; output reservoir moved too far")

    print("  In1.Cu continuous GND reference; In2.Cu 3V3 plane; all-layer antenna keepout")
    print("  microSD rear-mounted and fully inside the board envelope")
    print("  no-fit UART/GPIO16/GPIO17, reset, 3V3, and GND expansion pads present")
    print(f"  buck switch nodes: {buck['BUCK_L1'][0]:.3f}/{buck['BUCK_L2'][0]:.3f} mm, no vias")
    print(f"  USB D+/D-: {dp_length:.3f}/{dm_length:.3f} mm, "
          f"{abs(dp_length - dm_length):.3f} mm mismatch, symmetric via count")
    print("  primary power routes have >= 0.30 mm width")
    print("  0.8 mm symmetric ENIG stackup and critical regulator reservoir placement locked")
    print(f"  battery TS escape has {ts_edge_clearance:.3f} mm copper-to-edge clearance")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
