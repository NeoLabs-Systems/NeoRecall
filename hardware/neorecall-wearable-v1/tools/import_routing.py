#!/usr/bin/env python3
"""Import a Freerouting session into the generated KiCad board and fill planes."""

from pathlib import Path
import sys

import wx

APP = wx.App(False)
import pcbnew  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
BOARD_PATH = ROOT / "neorecall-wearable-v1.kicad_pcb"
DEFAULT_SESSION_PATH = ROOT / "routing" / "neorecall-wearable-v1.ses"


def mm(value: float) -> int:
    return pcbnew.FromMM(value)


def add_ground_plane(board: pcbnew.BOARD) -> None:
    net = board.FindNet("GND") or board.FindNet("/GND")
    if net is None:
        raise RuntimeError("GND net is missing")
    for existing in list(board.Zones()):
        if (not existing.GetIsRuleArea()
                and existing.GetNetname().lstrip("/") == "GND"
                and existing.GetLayer() == pcbnew.In1_Cu):
            board.Remove(existing)
    zone = pcbnew.ZONE(board)
    zone.SetLayer(pcbnew.In1_Cu)
    zone.SetNet(net)
    zone.SetLocalClearance(mm(0.15))
    zone.SetMinThickness(mm(0.10))
    zone.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)
    zone.SetAssignedPriority(1)
    zone.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    outline = zone.Outline()
    outline.NewOutline()
    for x, y in [(100.25, 100.25), (127.75, 100.25), (127.75, 137.75), (100.25, 137.75)]:
        outline.Append(mm(x), mm(y))
    board.Add(zone)


def add_3v3_plane(board: pcbnew.BOARD) -> None:
    """Add the low-impedance 3V3 distribution pour on the second inner layer."""
    net = board.FindNet("3V3") or board.FindNet("/3V3")
    if net is None:
        raise RuntimeError("3V3 net is missing")
    for existing in list(board.Zones()):
        if (not existing.GetIsRuleArea()
                and existing.GetNetname().lstrip("/") == "3V3"
                and existing.GetLayer() == pcbnew.In2_Cu):
            board.Remove(existing)
    zone = pcbnew.ZONE(board)
    zone.SetLayer(pcbnew.In2_Cu)
    zone.SetNet(net)
    zone.SetLocalClearance(mm(0.15))
    zone.SetMinThickness(mm(0.10))
    zone.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)
    zone.SetAssignedPriority(1)
    zone.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    outline = zone.Outline()
    outline.NewOutline()
    for x, y in [(100.25, 100.25), (127.75, 100.25), (127.75, 137.75), (100.25, 137.75)]:
        outline.Append(mm(x), mm(y))
    board.Add(zone)
    board.SetLayerName(pcbnew.In2_Cu, "3V3 plane / slow signals")


def main() -> int:
    session_path = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_SESSION_PATH
    board = pcbnew.LoadBoard(str(BOARD_PATH))
    if board is None:
        raise RuntimeError(f"Cannot load {BOARD_PATH}")
    if not session_path.is_file():
        raise RuntimeError(f"Missing {session_path}")
    if not pcbnew.ImportSpecctraSES(board, str(session_path)):
        raise RuntimeError("KiCad could not import the Specctra session")
    add_ground_plane(board)
    add_3v3_plane(board)
    board.BuildConnectivity()
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.BuildConnectivity()
    pcbnew.SaveBoard(str(BOARD_PATH), board)
    print(f"Imported {session_path}")
    print(f"Saved routed board {BOARD_PATH}")
    print(f"Tracks and vias: {len(list(board.GetTracks()))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
