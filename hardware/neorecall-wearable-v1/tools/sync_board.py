#!/usr/bin/env python3
"""Synchronize the routed board with the generated schematic source.

Run with KiCad 10's bundled Python.  This preserves routed copper while fixing
schematic/PCB metadata, canonical root-sheet net names, no-fit test-pad flags,
and NeoLabs silkscreen branding.
"""

from pathlib import Path

import wx

APP = wx.App(False)
import pcbnew  # noqa: E402

import generate_schematic as design  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
BOARD_PATH = ROOT / "neorecall-wearable-v1.kicad_pcb"
BOARD_ORIGIN = (100.0, 100.0)
BRANDING = {
    "NEOLABS": ((14.0, 8.2), 1.0),
    "NeoRecall v1": ((14.0, 9.7), 0.80),
}
CUSTOM_MODELS = {
    "Coilcraft_XFL4020": ("coilcraft-xfl4020.wrl", 0.0),
    "ESP32-C6-MINI-1": ("esp32-c6-mini-1.wrl", 0.0),
    "GCT_MEM2085": ("micro-sd-holder.wrl", 0.0),
    "Molex_2169900003": ("usb-c-midmount.wrl", 180.0),
    "T5848_LGA8_BottomPort": ("t5848.wrl", 0.0),
    "TI_DSJ_VSON14_3x4mm": ("ti-vson-3x4.wrl", 0.0),
}


def mm(value: float) -> int:
    return pcbnew.FromMM(value)


def point(relative: tuple[float, float]) -> pcbnew.VECTOR2I:
    return pcbnew.VECTOR2I(
        mm(BOARD_ORIGIN[0] + relative[0]),
        mm(BOARD_ORIGIN[1] + relative[1]),
    )


def canonical(name: str) -> str:
    if name.startswith("unconnected-("):
        return name
    return name if name.startswith("/") else f"/{name}"


def net(board: pcbnew.BOARD, logical_name: str) -> pcbnew.NETINFO_ITEM:
    result = board.FindNet(canonical(logical_name))
    if result is None:
        result = pcbnew.NETINFO_ITEM(board, canonical(logical_name))
        board.Add(result)
    return result


def sync_nets(board: pcbnew.BOARD) -> None:
    for item in board.GetNetInfo().NetsByNetcode().values():
        name = item.GetNetname()
        if name and not name.startswith("/"):
            item.SetNetname(canonical(name))
    for logical_name in {value for part in design.PARTS for value in part.pin_nets.values()} - {"NC"}:
        net(board, logical_name)


def sync_footprint_metadata(board: pcbnew.BOARD) -> None:
    by_reference = {part.reference: part for part in design.PARTS}
    for footprint in board.GetFootprints():
        reference = footprint.GetReference()
        part = by_reference.get(reference)
        if part is None:
            continue
        footprint.SetValue(part.value)
        footprint.SetFPIDAsString(part.footprint)
        footprint.SetField("Datasheet", part.datasheet)
        if not part.populated:
            footprint.SetAttributes(
                footprint.GetAttributes()
                | pcbnew.FP_EXCLUDE_FROM_BOM
                | pcbnew.FP_EXCLUDE_FROM_POS_FILES
            )


def sync_custom_models(board: pcbnew.BOARD) -> None:
    for footprint in board.GetFootprints():
        item_name = str(footprint.GetFPID().GetLibItemName())
        model_spec = CUSTOM_MODELS.get(item_name)
        if model_spec is None:
            continue
        filename, rotation_z = model_spec
        expected = f"${{KIPRJMOD}}/models3d/{filename}"
        if any(model.m_Filename == expected for model in footprint.Models()):
            continue
        model = pcbnew.FP_3DMODEL()
        model.m_Filename = expected
        model.m_Rotation.z = rotation_z
        footprint.Models().append(model)


def assign_no_connect_nets(board: pcbnew.BOARD) -> None:
    for part in design.PARTS:
        pin_names = {pin.number: pin.name for pin in design.SYMBOLS[part.symbol]}
        footprint = board.FindFootprintByReference(part.reference)
        if footprint is None:
            raise RuntimeError(f"Missing footprint {part.reference}")
        pads = {}
        for pad in footprint.Pads():
            pads.setdefault(pad.GetNumber(), []).append(pad)
        for number, logical_name in part.pin_nets.items():
            if logical_name != "NC":
                continue
            pseudo_name = f"unconnected-({part.reference}-{pin_names[number]}-Pad{number})"
            target_net = net(board, pseudo_name)
            for pad in pads.get(number, []):
                pad.SetNet(target_net)


def add_branding(board: pcbnew.BOARD) -> None:
    existing = {
        drawing.GetText(): drawing
        for drawing in board.GetDrawings()
        if isinstance(drawing, pcbnew.PCB_TEXT) and drawing.GetText() in BRANDING
    }
    for label, (location, size) in BRANDING.items():
        item = existing.get(label)
        if item is None:
            item = pcbnew.PCB_TEXT(board)
            board.Add(item)
        item.SetText(label)
        item.SetPosition(point(location))
        item.SetLayer(pcbnew.B_SilkS)
        item.SetMirrored(True)
        item.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size)))
        item.SetTextThickness(mm(max(0.10, size * 0.16)))
        item.SetHorizJustify(pcbnew.GR_TEXT_H_ALIGN_CENTER)


def main() -> int:
    board = pcbnew.LoadBoard(str(BOARD_PATH))
    if board is None:
        raise RuntimeError(f"Cannot load {BOARD_PATH}")
    sync_nets(board)
    assign_no_connect_nets(board)
    sync_footprint_metadata(board)
    add_branding(board)
    board.BuildConnectivity()
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.BuildConnectivity()
    # Keep model appends last: KiCad's SWIG vector retains borrowed objects and
    # can invalidate later board traversals if those objects leave Python scope.
    sync_custom_models(board)
    pcbnew.SaveBoard(str(BOARD_PATH), board)
    print("Synchronized routed board with schematic metadata")
    print("Marked no-fit UART/GPIO expansion pads and added NeoLabs branding")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
