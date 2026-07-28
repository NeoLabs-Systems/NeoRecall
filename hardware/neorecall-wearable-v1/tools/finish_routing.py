#!/usr/bin/env python3
"""Finish reviewed microphone and dense connector escape geometry."""

from pathlib import Path

import wx

APP = wx.App(False)
import pcbnew  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
BOARD_PATH = ROOT / "neorecall-wearable-v1.kicad_pcb"


def mm(value: float) -> int:
    return pcbnew.FromMM(value)


def point(x: float, y: float) -> pcbnew.VECTOR2I:
    return pcbnew.VECTOR2I(mm(x), mm(y))


def track(board: pcbnew.BOARD, net: pcbnew.NETINFO_ITEM, layer: int,
          start: tuple[float, float], end: tuple[float, float], width: float) -> None:
    item = pcbnew.PCB_TRACK(board)
    item.SetNet(net)
    item.SetLayer(layer)
    item.SetWidth(mm(width))
    item.SetStart(point(*start))
    item.SetEnd(point(*end))
    board.Add(item)


def finish_battery_ts_escape(board: pcbnew.BOARD) -> None:
    """Fit BQ_TS between J2.3 and the edge at JLCPCB-capable rules."""
    ts = board.FindNet("BQ_TS") or board.FindNet("/BQ_TS")
    if ts is None:
        raise RuntimeError("BQ_TS net is missing")
    coordinate_updates = {
        (100.1922, 132.7501): (100.2625, 132.7501),
        (100.1922, 134.5924): (100.2625, 134.7000),
    }

    def key(position: pcbnew.VECTOR2I) -> tuple[float, float]:
        return round(pcbnew.ToMM(position.x), 4), round(pcbnew.ToMM(position.y), 4)

    for item in board.GetTracks():
        if item.GetNetCode() != ts.GetNetCode() or isinstance(item, pcbnew.PCB_VIA):
            continue
        item.SetWidth(mm(0.10))
        if key(item.GetStart()) in coordinate_updates:
            item.SetStart(point(*coordinate_updates[key(item.GetStart())]))
        if key(item.GetEnd()) in coordinate_updates:
            item.SetEnd(point(*coordinate_updates[key(item.GetEnd())]))

    connector = board.FindFootprintByReference("J2")
    ground_pads = [pad for pad in connector.Pads() if pad.GetNumber() == "3"]
    if len(ground_pads) != 1:
        raise RuntimeError("Expected one J2 ground pad")
    # JLCPCB publishes 0.10 mm advanced trace-to-pad capability.  The local
    # override leaves 0.1125 mm physical clearance while preserving >=0.20 mm
    # copper-to-routed-edge clearance for the low-current thermistor trace.
    ground_pads[0].SetLocalClearance(mm(0.10))


def main() -> int:
    board = pcbnew.LoadBoard(str(BOARD_PATH))
    if board is None:
        raise RuntimeError(f"Cannot load {BOARD_PATH}")

    gnd = board.FindNet("GND") or board.FindNet("/GND")
    if gnd is None:
        raise RuntimeError("GND net is missing")

    finish_battery_ts_escape(board)

    # Manufacturer bottom-port land: pad 3 surrounds the NPTH acoustic hole.
    track(board, gnd, pcbnew.F_Cu, (101.9500, 117.5270), (103.0000, 118.2920), 0.20)
    # MK2 is rotated so its word-select pad faces the routable board interior;
    # pad 4 and the annular pad 3 therefore use this transformed land geometry.
    track(board, gnd, pcbnew.F_Cu, (126.4730, 117.9500), (125.7080, 119.0000), 0.20)

    board.BuildConnectivity()
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.BuildConnectivity()
    pcbnew.SaveBoard(str(BOARD_PATH), board)
    print(f"Finished microphone annuli and JLCPCB-safe battery TS escape in {BOARD_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
