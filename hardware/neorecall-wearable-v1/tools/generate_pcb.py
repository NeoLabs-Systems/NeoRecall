#!/usr/bin/env python3
"""Generate the placed four-layer NeoRecall Wearable PCB from the reviewed schematic source.

Run this with KiCad's bundled Python so the pcbnew bindings match the board format.
Routing is performed from the emitted Specctra DSN and imported separately; this file
owns placement, layer stack, net assignment, board outline, RF/acoustic keepouts, and
power-plane definitions.
"""

from __future__ import annotations

import os
import math
import sys
from dataclasses import dataclass
from pathlib import Path

import wx

APP = wx.App(False)
import pcbnew  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_schematic as schematic  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
BOARD_PATH = ROOT / "neorecall-wearable-v1.kicad_pcb"
DSN_PATH = ROOT / "routing" / "neorecall-wearable-v1.dsn"
CUSTOM_FOOTPRINTS = ROOT / "lib" / "NeoRecall_Wearable.pretty"

BOARD_X = 100.0
BOARD_Y = 100.0
BOARD_WIDTH = 28.0
BOARD_HEIGHT = 38.0


@dataclass(frozen=True)
class Placement:
    x: float
    y: float
    side: str = "F"
    rotation: float = 0.0


# Component centers in millimetres from the upper-left board corner. Critical
# decouplers sit beside their IC pins rather than in arbitrary rows.
PLACEMENTS = {
    "U1": Placement(14.0, 8.30),
    "SW1": Placement(14.0, 19.0),
    "MK1": Placement(3.0, 19.0, rotation=90),
    "MK2": Placement(25.0, 19.0, rotation=0),
    "J1": Placement(14.0, 34.10),
    "J2": Placement(3.2, 35.2, rotation=90),
    "U2": Placement(13.5, 30.0, "B", 90),
    "R1": Placement(14.25, 17.1, "B", 90),
    "R2": Placement(12.75, 17.1, "B", 90),
    "R3": Placement(5.0, 36.0, "B", 90),
    "R4": Placement(26.5, 36.5),
    "D1": Placement(7.0, 36.0, "B", 90),
    "C1": Placement(9.0, 30.0, "B", 90),
    "U3": Placement(6.0, 29.5),
    "R6": Placement(3.0, 29.5, "B"),
    "R7": Placement(2.5, 33.5, "B"),
    "R8": Placement(3.0, 24.5, "B"),
    "R9": Placement(2.5, 26.5, "B"),
    "R10": Placement(22.0, 13.5, "B"),
    "R11": Placement(22.0, 15.5, "B"),
    "C2": Placement(5.8, 32.0, "B"),
    "C3": Placement(9.5, 33.5, "B"),
    "U4": Placement(23.0, 28.7),
    # Rotate the two-terminal inductor so each switch node exits straight into
    # the matching TPS63021 side; the unrotated orientation forces the two
    # high-di/dt nodes to cross and more than doubles their copper length.
    "L1": Placement(23.0, 33.3, rotation=180),
    "C4": Placement(26.5, 27.3, rotation=90),
    "C5": Placement(26.5, 30.4, rotation=90),
    "C6": Placement(21.0, 24.6, rotation=90),
    "C7": Placement(19.1, 27.6, rotation=90),
    "C20": Placement(16.6, 28.5, rotation=90),
    "C21": Placement(19.0, 24.0, rotation=90),
    "R30": Placement(25.5, 25.0),
    "R12": Placement(7.0, 12.0, "B", 90),
    "C8": Placement(7.0, 15.0, "B", 90),
    "C9": Placement(9.5, 15.5, "B"),
    "C10": Placement(13.5, 14.5, "B"),
    "R13": Placement(17.5, 18.0, "B"),
    "R14": Placement(19.0, 16.0, "B"),
    "R15": Placement(4.8, 14.0, "B", 90),
    "R16": Placement(4.8, 17.0, "B", 90),
    "C11": Placement(4.8, 20.0, "B", 90),
    "R17": Placement(13.0, 27.5),
    "D2": Placement(13.0, 29.1),
    "R18": Placement(20.0, 18.7),
    "D3": Placement(20.0, 20.2),
    "TP1": Placement(3.0, 13.0, "B"),
    "TP2": Placement(3.0, 15.0, "B"),
    "TP3": Placement(25.0, 13.0, "B"),
    "TP4": Placement(23.0, 18.0, "B"),
    "TP5": Placement(25.2, 16.2, "B"),
    "U5": Placement(7.0, 23.0, rotation=90),
    "C12": Placement(4.2, 22.5, rotation=90),
    "C13": Placement(4.2, 25.5, rotation=90),
    "U6": Placement(14.0, 23.8),
    "C14": Placement(9.5, 18.5, rotation=90),
    "C15": Placement(9.0, 26.8, rotation=90),
    "R31": Placement(23.5, 14.5),
    "C16": Placement(2.5, 22.5, rotation=90),
    "C17": Placement(23.5, 22.5, rotation=90),
    "R19": Placement(22.5, 20.8, "B"),
    "U7": Placement(10.5, 24.8, "B", 90),
    "R32": Placement(7.5, 24.8, "B", 90),
    "C22": Placement(13.5, 24.8, "B", 90),
    "C23": Placement(5.3, 27.3, "B"),
    "J3": Placement(20.2, 27.9, "B", 90),
    "R20": Placement(8.0, 20.5, "B", 90),
    "R21": Placement(10.0, 20.5, "B", 90),
    "R22": Placement(12.0, 20.5, "B", 90),
    "R23": Placement(14.0, 20.5, "B", 90),
    "R24": Placement(26.3, 28.5, "B", 90),
    "R25": Placement(27.0, 25.5, "B", 90),
    "R26": Placement(27.0, 22.5, "B", 90),
    "R27": Placement(5.5, 24.5, "B", 90),
    "R28": Placement(25.2, 24.2, "B", 90),
    "R29": Placement(26.3, 31.5, "B", 90),
    "C18": Placement(26.3, 34.5, "B", 90),
    "C19": Placement(23.5, 36.0, "B"),
}


def mm(value: float) -> int:
    return pcbnew.FromMM(value)


def point(x: float, y: float) -> pcbnew.VECTOR2I:
    return pcbnew.VECTOR2I(mm(BOARD_X + x), mm(BOARD_Y + y))


def find_kicad_share() -> Path:
    configured = os.environ.get("KICAD10_SHARE")
    candidates = [
        Path(configured) if configured else Path("/__missing__"),
        Path("/Applications/KiCad/KiCad.app/Contents/SharedSupport"),
        Path("/tmp/neorecall-kicad-mount/KiCad/KiCad.app/Contents/SharedSupport"),
    ]
    for candidate in candidates:
        if (candidate / "footprints").is_dir():
            return candidate
    raise RuntimeError("KiCad 10 footprint libraries not found; set KICAD10_SHARE")


def footprint_from_library(identifier: str, share: Path) -> pcbnew.FOOTPRINT:
    library, name = identifier.split(":", 1)
    path = CUSTOM_FOOTPRINTS if library == "NeoRecall_Wearable" else share / "footprints" / f"{library}.pretty"
    footprint = pcbnew.FootprintLoad(str(path), name)
    if footprint is None:
        raise RuntimeError(f"Cannot load footprint {identifier} from {path}")
    return footprint


def add_outline(board: pcbnew.BOARD) -> None:
    corners = [point(0, 0), point(BOARD_WIDTH, 0), point(BOARD_WIDTH, BOARD_HEIGHT), point(0, BOARD_HEIGHT)]
    for start, end in zip(corners, corners[1:] + corners[:1]):
        edge = pcbnew.PCB_SHAPE(board)
        edge.SetShape(pcbnew.SHAPE_T_SEGMENT)
        edge.SetStart(start)
        edge.SetEnd(end)
        edge.SetLayer(pcbnew.Edge_Cuts)
        edge.SetWidth(mm(0.05))
        board.Add(edge)


def polygon(zone: pcbnew.ZONE, vertices: list[tuple[float, float]]) -> None:
    outline = zone.Outline()
    outline.NewOutline()
    for x, y in vertices:
        outline.Append(point(x, y))


def layer_set(*layers: int) -> pcbnew.LSET:
    result = pcbnew.LSET()
    for layer in layers:
        result.AddLayer(layer)
    return result


def add_antenna_keepout(board: pcbnew.BOARD) -> None:
    keepout = pcbnew.ZONE(board)
    keepout.SetIsRuleArea(True)
    keepout.SetLayerSet(layer_set(pcbnew.F_Cu, pcbnew.In1_Cu, pcbnew.In2_Cu, pcbnew.B_Cu))
    keepout.SetDoNotAllowZoneFills(True)
    keepout.SetDoNotAllowTracks(True)
    keepout.SetDoNotAllowVias(True)
    keepout.SetDoNotAllowPads(False)
    # The ESP32 module itself necessarily overlaps this rule area; all other
    # copper, tracks and vias remain prohibited by the all-layer keepout.
    keepout.SetDoNotAllowFootprints(False)
    polygon(keepout, [(7.15, 0.0), (20.85, 0.0), (20.85, 5.55), (7.15, 5.55)])
    board.Add(keepout)


def add_inner_ground_track_keepout(board: pcbnew.BOARD) -> None:
    """Reserve In1 as an uninterrupted reference plane during autorouting."""
    keepout = pcbnew.ZONE(board)
    keepout.SetIsRuleArea(True)
    keepout.SetLayer(pcbnew.In1_Cu)
    keepout.SetDoNotAllowZoneFills(False)
    keepout.SetDoNotAllowTracks(True)
    keepout.SetDoNotAllowVias(False)
    keepout.SetDoNotAllowPads(False)
    keepout.SetDoNotAllowFootprints(False)
    polygon(keepout, [(0.25, 0.25), (27.75, 0.25), (27.75, 37.75), (0.25, 37.75)])
    board.Add(keepout)


def add_plane(board: pcbnew.BOARD, net: pcbnew.NETINFO_ITEM, layer: int, clearance: float, priority: int) -> None:
    zone = pcbnew.ZONE(board)
    zone.SetLayer(layer)
    zone.SetNet(net)
    zone.SetLocalClearance(mm(clearance))
    zone.SetMinThickness(mm(0.10))
    zone.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)
    zone.SetAssignedPriority(priority)
    zone.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    polygon(zone, [(0.25, 0.25), (27.75, 0.25), (27.75, 37.75), (0.25, 37.75)])
    board.Add(zone)


def configure_rules(board: pcbnew.BOARD) -> None:
    settings = board.GetDesignSettings()
    settings.SetBoardThickness(mm(0.80))
    settings.SetAuxOrigin(point(0.0, 0.0))
    settings.SetCopperLayerCount(4)
    settings.m_CopperEdgeClearance = mm(0.20)
    settings.m_HoleClearance = mm(0.20)
    settings.m_HoleToHoleMin = mm(0.20)
    settings.m_MinClearance = mm(0.10)
    settings.m_TrackMinWidth = mm(0.10)
    settings.m_ViasMinSize = mm(0.45)
    settings.m_MinThroughDrill = mm(0.20)

    board.SetCopperLayerCount(4)
    board.SetLayerName(pcbnew.In1_Cu, "GND plane")
    board.SetLayerName(pcbnew.In2_Cu, "3V3 / slow signals")
    board.SetLayerType(pcbnew.In1_Cu, pcbnew.LT_POWER)
    board.SetLayerType(pcbnew.In2_Cu, pcbnew.LT_SIGNAL)

    default = settings.m_NetSettings.GetDefaultNetclass()
    default.SetClearance(mm(0.10))
    default.SetTrackWidth(mm(0.15))
    default.SetViaDiameter(mm(0.45))
    default.SetViaDrill(mm(0.20))
    default.SetDiffPairWidth(mm(0.15))
    default.SetDiffPairGap(mm(0.15))

    power = pcbnew.NETCLASS("Power")
    power.SetClearance(mm(0.15))
    # 0.20 mm is the minimum feeder width accepted for this dense hand-
    # assemblable board. High-current regulator loops are replaced with local
    # copper geometry after autorouting; the global width keeps the router from
    # silently falling back to 0.15 mm on battery and switched-power rails.
    power.SetTrackWidth(mm(0.30))
    power.SetViaDiameter(mm(0.50))
    power.SetViaDrill(mm(0.25))
    settings.m_NetSettings.SetNetclass("Power", power)
    for pattern in (
        "GND", "3V3", "1V85", "VBUS_USB", "BAT_PLUS", "SYS_RAW",
        "BUCK_L1", "BUCK_L2", "SD_3V3",
    ):
        settings.m_NetSettings.SetNetclassPatternAssignment(f"/{pattern}", "Power")
    settings.m_NetSettings.RecomputeEffectiveNetclasses()


def assign_nets_and_parts(board: pcbnew.BOARD, share: Path) -> dict[str, pcbnew.NETINFO_ITEM]:
    net_names = sorted({net for part in schematic.PARTS for net in part.pin_nets.values()} - {"NC"})
    nets: dict[str, pcbnew.NETINFO_ITEM] = {}
    for name in net_names:
        # Root-sheet local labels are canonically named /LABEL by KiCad.
        net = pcbnew.NETINFO_ITEM(board, f"/{name}")
        board.Add(net)
        nets[name] = net

    references = {part.reference for part in schematic.PARTS}
    if references != set(PLACEMENTS):
        raise RuntimeError(f"Placement mismatch; missing={sorted(references - set(PLACEMENTS))}, extra={sorted(set(PLACEMENTS) - references)}")

    for part in schematic.PARTS:
        placement = PLACEMENTS[part.reference]
        footprint = footprint_from_library(part.footprint, share)
        footprint.SetReference(part.reference)
        footprint.SetValue(part.value)
        footprint.SetFPIDAsString(part.footprint)
        footprint.SetField("Datasheet", part.datasheet)
        footprint.SetPosition(point(placement.x, placement.y))
        board.Add(footprint)
        if placement.side == "B":
            footprint.Flip(footprint.GetPosition(), pcbnew.FLIP_DIRECTION_LEFT_RIGHT)
        footprint.SetOrientationDegrees(placement.rotation)
        footprint.Reference().SetVisible(False)
        footprint.Value().SetVisible(False)
        # This density cannot support useful per-part silkscreen outlines.
        # Preserve them on Fab for assembly drawings instead of allowing the
        # board house to clip dozens of ambiguous silk fragments.
        for graphic in footprint.GraphicalItems():
            if graphic.GetLayer() == pcbnew.F_SilkS:
                graphic.SetLayer(pcbnew.F_Fab)
            elif graphic.GetLayer() == pcbnew.B_SilkS:
                graphic.SetLayer(pcbnew.B_Fab)
        pads_by_number: dict[str, list[pcbnew.PAD]] = {}
        for pad in footprint.Pads():
            pads_by_number.setdefault(pad.GetNumber(), []).append(pad)
        pin_names = {pin.number: pin.name for pin in schematic.SYMBOLS[part.symbol]}
        for number, net_name in part.pin_nets.items():
            if net_name == "NC":
                net_name = f"unconnected-({part.reference}-{pin_names[number]}-Pad{number})"
                if net_name not in nets:
                    item = pcbnew.NETINFO_ITEM(board, net_name)
                    board.Add(item)
                    nets[net_name] = item
            matching = pads_by_number.get(number, [])
            if not matching:
                raise RuntimeError(f"{part.reference} pad {number} not present in {part.footprint}")
            for pad in matching:
                pad.SetNet(nets[net_name])
    return nets


def add_track(board: pcbnew.BOARD, net: pcbnew.NETINFO_ITEM, layer: int,
              start: pcbnew.VECTOR2I, end: pcbnew.VECTOR2I, width: float) -> None:
    track = pcbnew.PCB_TRACK(board)
    track.SetNet(net)
    track.SetLayer(layer)
    track.SetWidth(mm(width))
    track.SetStart(start)
    track.SetEnd(end)
    board.Add(track)


def add_via(board: pcbnew.BOARD, net: pcbnew.NETINFO_ITEM,
            position: pcbnew.VECTOR2I, diameter: float = 0.55, drill: float = 0.25) -> None:
    via = pcbnew.PCB_VIA(board)
    via.SetNet(net)
    via.SetPosition(position)
    via.SetWidth(mm(diameter))
    via.SetDrill(mm(drill))
    via.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
    board.Add(via)


def _point_segment_distance(px: float, py: float, ax: float, ay: float,
                            bx: float, by: float) -> float:
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def _candidate_clear(board: pcbnew.BOARD, selected: pcbnew.PAD,
                     origin: pcbnew.VECTOR2I, destination: pcbnew.VECTOR2I) -> bool:
    """Conservative copper-clearance test for a 0.55 mm via and 0.30 mm dogbone."""
    edge = mm(0.60)
    if not (mm(BOARD_X) + edge <= destination.x <= mm(BOARD_X + BOARD_WIDTH) - edge
            and mm(BOARD_Y) + edge <= destination.y <= mm(BOARD_Y + BOARD_HEIGHT) - edge):
        return False
    # Preserve the certified module antenna's all-layer no-copper region.
    if mm(BOARD_X + 7.15) <= destination.x <= mm(BOARD_X + 20.85) and destination.y <= mm(BOARD_Y + 5.55):
        return False

    via_margin = mm(0.275 + 0.18)
    trace_margin = mm(0.150 + 0.18)
    for fp in board.GetFootprints():
        for other in fp.Pads():
            if other.GetParentFootprint().GetReference() == selected.GetParentFootprint().GetReference() \
                    and other.GetNumber() == selected.GetNumber():
                continue
            if other.GetNetCode() == selected.GetNetCode():
                continue
            box = other.GetBoundingBox()
            left, right = box.GetLeft(), box.GetRight()
            top, bottom = box.GetTop(), box.GetBottom()
            if left - via_margin <= destination.x <= right + via_margin \
                    and top - via_margin <= destination.y <= bottom + via_margin:
                return False
            # Sample the short dogbone densely; this is intentionally conservative.
            steps = max(2, math.ceil(math.hypot(destination.x - origin.x, destination.y - origin.y) / mm(0.10)))
            for index in range(1, steps + 1):
                x = origin.x + (destination.x - origin.x) * index / steps
                y = origin.y + (destination.y - origin.y) * index / steps
                if left - trace_margin <= x <= right + trace_margin \
                        and top - trace_margin <= y <= bottom + trace_margin:
                    return False
    for item in board.GetTracks():
        if not isinstance(item, pcbnew.PCB_VIA):
            continue
        if item.GetNetCode() == selected.GetNetCode():
            continue
        minimum = (item.GetWidth() + mm(0.55)) / 2 + mm(0.18)
        if math.hypot(destination.x - item.GetPosition().x, destination.y - item.GetPosition().y) < minimum:
            return False
    return True


def add_power_plane_dogbones(board: pcbnew.BOARD, net: pcbnew.NETINFO_ITEM) -> None:
    """Connect isolated 3V3 islands to In2 before the autorouter runs."""
    selections = [
        ("U1", "3"), ("R10", "1"),
        ("R30", "1"),
        ("U4", "3"),
    ]
    board_center = point(BOARD_WIDTH / 2, BOARD_HEIGHT / 2)
    for reference, number in selections:
        fp = board.FindFootprintByReference(reference)
        pads = [candidate for candidate in fp.Pads() if candidate.GetNumber() == number]
        if not pads:
            raise RuntimeError(f"Missing power pad {reference}.{number}")
        pad = pads[0]
        origin = pad.GetPosition()
        dx = origin.x - fp.GetPosition().x
        dy = origin.y - fp.GetPosition().y
        if math.hypot(dx, dy) < mm(0.20):
            dx = origin.x - board_center.x
            dy = origin.y - board_center.y
        preferred = math.atan2(dy, dx)
        destination = None
        for radius_mm in (0.72, 0.95, 1.20, 1.50, 1.85, 2.20, 2.60, 3.00):
            for offset_degrees in (0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180):
                angle = preferred + math.radians(offset_degrees)
                candidate = pcbnew.VECTOR2I(
                    round(origin.x + mm(radius_mm) * math.cos(angle)),
                    round(origin.y + mm(radius_mm) * math.sin(angle)),
                )
                board_margin = mm(0.50)
                if not (mm(BOARD_X) + board_margin <= candidate.x <= mm(BOARD_X + BOARD_WIDTH) - board_margin
                        and mm(BOARD_Y) + board_margin <= candidate.y <= mm(BOARD_Y + BOARD_HEIGHT) - board_margin):
                    continue
                if _candidate_clear(board, pad, origin, candidate):
                    destination = candidate
                    break
            if destination is not None:
                break
        if destination is None:
            raise RuntimeError(f"No DRC-safe plane dogbone location for {reference}.{number}")
        layer = pcbnew.F_Cu if pad.IsOnLayer(pcbnew.F_Cu) else pcbnew.B_Cu
        add_track(board, net, layer, origin, destination, 0.30)
        add_via(board, net, destination)


def add_ground_stitching(board: pcbnew.BOARD, net: pcbnew.NETINFO_ITEM) -> None:
    """Provide RF/return-current stitching into the solid In1 ground plane."""
    for x, y in [
        (1.3, 6.4), (26.7, 6.4), (1.3, 11.0), (26.7, 11.0),
        (1.3, 17.0), (26.7, 17.0), (1.3, 24.0), (26.7, 24.0),
        (1.3, 31.0), (26.7, 31.0), (8.5, 36.6), (19.5, 36.6),
    ]:
        requested = point(x, y)
        # Ground stitching is free copper, so use a synthetic zero-size pad-like
        # origin and search the local grid when a component occupies the target.
        placed = False
        for radius_mm in (0.0, 0.5, 1.0, 1.5):
            for angle_degrees in range(0, 360, 45):
                candidate = pcbnew.VECTOR2I(
                    round(requested.x + mm(radius_mm) * math.cos(math.radians(angle_degrees))),
                    round(requested.y + mm(radius_mm) * math.sin(math.radians(angle_degrees))),
                )
                board_margin = mm(0.50)
                if not (mm(BOARD_X) + board_margin <= candidate.x <= mm(BOARD_X + BOARD_WIDTH) - board_margin
                        and mm(BOARD_Y) + board_margin <= candidate.y <= mm(BOARD_Y + BOARD_HEIGHT) - board_margin):
                    continue
                blocked = False
                for fp in board.GetFootprints():
                    for other in fp.Pads():
                        if other.GetNetname().lstrip("/") == "GND":
                            continue
                        box = other.GetBoundingBox()
                        margin = mm(0.275 + 0.18)
                        if box.GetLeft() - margin <= candidate.x <= box.GetRight() + margin \
                                and box.GetTop() - margin <= candidate.y <= box.GetBottom() + margin:
                            blocked = True
                            break
                    if blocked:
                        break
                if not blocked:
                    add_via(board, net, candidate, 0.50, 0.25)
                    placed = True
                    break
            if placed:
                break
        if not placed:
            raise RuntimeError(f"No DRC-safe ground stitching location near {x},{y}")


def add_board_labels(board: pcbnew.BOARD) -> None:
    for text, x, y, layer, size in [
        ("NEOLABS", 14.0, 8.2, pcbnew.B_SilkS, 1.00),
        ("NeoRecall v1", 14.0, 9.7, pcbnew.B_SilkS, 0.80),
    ]:
        item = pcbnew.PCB_TEXT(board)
        item.SetText(text)
        item.SetPosition(point(x, y))
        item.SetLayer(layer)
        item.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size)))
        item.SetTextThickness(mm(max(0.10, size * 0.16)))
        item.SetHorizJustify(pcbnew.GR_TEXT_H_ALIGN_CENTER)
        if layer == pcbnew.B_SilkS:
            item.SetMirrored(True)
        board.Add(item)


def main() -> int:
    share = find_kicad_share()
    board = pcbnew.BOARD()
    configure_rules(board)
    nets = assign_nets_and_parts(board, share)
    add_outline(board)
    add_antenna_keepout(board)
    add_board_labels(board)
    board.SynchronizeNetsAndNetClasses(True)
    board.BuildConnectivity()

    BOARD_PATH.parent.mkdir(parents=True, exist_ok=True)
    DSN_PATH.parent.mkdir(parents=True, exist_ok=True)
    pcbnew.SaveBoard(str(BOARD_PATH), board)
    if not pcbnew.ExportSpecctraDSN(board, str(DSN_PATH)):
        raise RuntimeError("KiCad failed to export the Specctra routing file")
    print(f"Generated {BOARD_PATH}")
    print(f"Generated {DSN_PATH}")
    print(f"Placed {len(schematic.PARTS)} footprints on a four-layer {BOARD_WIDTH:.0f} x {BOARD_HEIGHT:.0f} mm board")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
